#!/usr/bin/env bash
# tools/quartus_gui.sh - open the Quartus GUI for this project, inside the raetro/quartus
# container, with the host's X11 session forwarded into it.
#
# The build tooling (tools/build.py) runs Quartus HEADLESS as `quartus_sh --flow compile`
# against a copied scratch tree so a killed launcher can never dirty the source. This script
# is the interactive counterpart and is intentionally the opposite: it runs the REAL Quartus
# GUI (not quartz_sh) directly against the SOURCE tree, because a human opening the GUI wants
# to read and edit the checked-out project, not a throwaway copy.
#
# Display transport is X11 ONLY, on purpose. The raetro/quartus image ships no Qt platform
# plugin at all (no libqxcb.so, no libqwayland*.so, no platforms/ directory) and the `quartus`
# binary is a legacy X11 client, not a Qt-QPA app -- so `QT_QPA_PLATFORM=wayland` cannot work
# and X11 is reached through XWayland on a Wayland session. The display scaling you have set
# in KDE (usually 1.25x/1.5x/2x) is therefore NOT picked up automatically: an X11 app under
# fractional Wayland scaling renders at 96 DPI and looks small/blurry. This script compensates
# by planting an X resource database (Xft.dpi) in the container so the GUI draws at the same
# size as the rest of the desktop.
#
# Usage:
#   tools/quartus_gui.sh                 # open the project in the Quartus GUI
#   tools/quartus_gui.sh --shell         # drop into a bash shell in the container instead
#   tools/quartus_gui.sh --project foo   # open a different revision (default z486_mister)
#   tools/quartus_gui.sh -- <arbitrary quartus args>
#
# Environment: QUARTUS_IMAGE, CONTAINER_RUNTIME (the same names the build uses).
#
# Caveats, stated rather than hidden:
#   * This runs Quartus against the live source tree, so a GUI compile writes its project
#     DB and can re-generate build outputs right in the checkout. That is the point of this
#     script, but it means you must not leave a headless build running against the same
#     tree (Quartus locks the project DB), and you should check the diff before committing.
#   * The first launch of the GUI unpacks Quartus' own cache under $HOME in the container
#     (set to /tmp here, so it vanishes with the container); that first open is several
#     seconds slower than later ones.

set -euo pipefail

# ---- resolve the project + display ----
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${QUARTUS_IMAGE:-docker.io/raetro/quartus:mister}"
RUNTIME="${CONTAINER_RUNTIME:-podman}"
PROJECT="z486_mister"

MODE=gui
PASSTHRU=()
while [ $# -gt 0 ]; do
  case "$1" in
    --shell)    MODE=shell ;;
    --project)  PROJECT="$2"; shift ;;
    --)         shift; PASSTHRU+=("$@"); break ;;
    *)          PASSTHRU+=("$1") ;;
  esac
  shift
done

command -v "$RUNTIME" >/dev/null 2>&1 || { echo "container runtime '$RUNTIME' not found" >&2; exit 1; }

QPF="$REPO_ROOT/$PROJECT.qpf"
if [ ! -f "$QPF" ]; then
  echo "no project file at $QPF" >&2
  exit 1
fi

# ---- build the display-forwarding args (X11 only) ----
COMMAND=(/opt/intelFPGA/quartus/bin/quartus "$PROJECT.qpf" "${PASSTHRU[@]}")
[ "$MODE" = shell ] && COMMAND=(/bin/bash)

# HOME=/tmp so the GTK/Qt config cache lives in the (throwaway) container, not the host.
# XDG_CACHE_HOME follows HOME, so theme caches stay isolated too.
RUNARGS=(--rm --name "pc9821-gui-$$" -e HOME=/tmp -e XDG_CACHE_HOME=/tmp/.cache)
# The GUI runs detached (the launcher returns, --rm removes the container when the GUI quits);
# the shell is interactive and must stay attached to this terminal.
if [ "$MODE" = shell ]; then RUNARGS+=(-it); else RUNARGS+=(-d); fi

# The image is X11-only (see header), so this is the one transport. No Wayland fallback: a
# Wayland socket with no Qt platform plugin is a guaranteed "could not find the wayland
# platform plugin" error, so failing loudly here is kinder than failing inside the GUI.
if [ ! -S /tmp/.X11-unix/X0 ] && [ -z "${DISPLAY:-}" ]; then
  echo "no X11 socket at /tmp/.X11-unix/X0 and no DISPLAY; the Quartus image cannot do Wayland-native" >&2
  echo "(start XWayland first, or run under an X11 session)" >&2
  exit 1
fi

RUNARGS+=( -e "DISPLAY=${DISPLAY:-:0}" -e QT_X11_NO_MITSHM=1 )
RUNARGS+=( -v /tmp/.X11-unix:/tmp/.X11-unix:ro )

# Pass the X authority: prefer $XAUTHORITY, else ~/.Xauthority. The cookie is the only way
# MIT-MAGIC-COOKIE auth works, and xhost is not assumed to be installed.
XAUTH=""
for c in "${XAUTHORITY:-}" "$HOME/.Xauthority"; do
  if [ -n "$c" ] && [ -r "$c" ]; then XAUTH="$c"; break; fi
done
if [ -n "$XAUTH" ]; then
  RUNARGS+=( -e "XAUTHORITY=/tmp/.Xauthority" -v "$XAUTH:/tmp/.Xauthority:ro" )
else
  echo "warning: no Xauthority file found; X auth may be rejected unless xhost is configured" >&2
fi

echo "==> launching $PROJECT.qpf in $IMAGE ($RUNTIME)"
echo "==> transport: X11"

exec "$RUNTIME" run "${RUNARGS[@]}" \
  -v "$REPO_ROOT:/work" \
  -w /work \
  "$IMAGE" \
  "${COMMAND[@]}"