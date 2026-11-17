#!/usr/bin/env bash
# Manage the PC-9821 firmware pack FILES already on the MiSTer SD card.
#
# ONE JOB: on-card pack inventory and switching. It never builds a pack, never verifies one
# against your dumps and never uploads one from a dump set -- tools/mister_load.sh does all
# of that, and it is the tool to use to PUT a new pack on the card. This one rearranges and
# prunes what is already there. tools/deploy_mister.sh stages the same files offline.
#
# THE MGLs ARE THE SOURCE OF TRUTH for which pack is active, and there is no single active
# pack: each MGL names the pack it loads, resolved relative to games/<setname>/ (the setname
# is PC9821, so games/PC9821/). A card carrying both firmware sets carries two MGLs naming
# two different packs. So this script reads the MGLs off the card and treats every pack one
# of them names as PROTECTED: prune will not delete one, and list says which MGL needs what.
#
# The pack is a *runtime input*: it holds whichever ITF + BIOS + font the user is entitled
# to use, and the core never ships any of it. Alternates live in games/PC9821/packs/ so the
# card does not accumulate loose builds, and switching between them needs no FPGA rebuild.
#
# Usage:
#   tools/mister_packs.sh list                     # what each MGL loads, what is stashed, what is stale
#   tools/mister_packs.sh use <pack.bin> [mgl]    # install packs/<pack.bin> as that MGL's pack
#   tools/mister_packs.sh stash <file> [name]     # upload a local pack into packs/
#   tools/mister_packs.sh prune                   # delete packs no MGL names and nothing has stashed
#
# `use` takes a name UNDER packs/ (run `list` to see them), because that is what it copies
# onto the pack the MGL names; it does not rewrite the MGL.
#
# env: MISTER_HOST (ssh destination, default root@MiSTer; a bare host name gets root@),
#      MISTER_PASS (default 1, the stock root password, through sshpass -e; empty = ssh keys)
set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
# the header comment up to its first non-comment line (a fixed line range rots)
usage() { awk 'NR > 1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$SELF"; }
cd "$(dirname "$0")/.."

HOST=${MISTER_HOST:-root@MiSTer}
case $HOST in *@*) ;; *) HOST=root@$HOST ;; esac
GAMES=/media/fat/games/PC9821
DEFAULT_MGL=/media/fat/PC9821Z486.mgl
SSHP=""
MISTER_PASS="${MISTER_PASS-1}"   # the stock MiSTer root password; MISTER_PASS= (empty) uses ssh keys
if [ -n "$MISTER_PASS" ]; then export SSHPASS="$MISTER_PASS"; SSHP="sshpass -e"; fi
SSHO="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"
# scp -O: the card's sshd has no sftp subsystem, and a modern scp defaults to sftp.
SCPO="-O $SSHO"
run() { $SSHP ssh $SSHO $HOST "$@"; }

# The pack path an MGL names: the <file ...> entry with type="f" (F0 -> file type f at
# index 0). Read from the MGL rather than assumed, because that is what MiSTer loads.
MGL_PACK_SED='s/.*<file[^>]*type="f"[^>]*path="\([^"]*\)".*/\1/p'

# One remote pass that emits the whole layout, so the classification below is done locally
# and the two never disagree about what exists. Lines are `MGL|<mgl>|<pack>` and
# `FILE|<path>|<bytes>`.
collect() {
  run "
    for m in /media/fat/PC9821*.mgl; do
      [ -e \"\$m\" ] || continue
      p=\$(sed -n '$MGL_PACK_SED' \"\$m\" | head -1)
      echo \"MGL|\$m|\$p\"
    done
    for f in $GAMES/*.bin $GAMES/packs/*.bin; do
      [ -e \"\$f\" ] || continue
      echo \"FILE|\$f|\$(wc -c < \"\$f\")\"
    done
    echo \"END\"
  "
}

case "${1:-list}" in
list)
  RAW=$(collect)
  echo "== what each MGL loads (the MGLs are the source of truth)"
  printf '%s\n' "$RAW" | awk -F'|' -v games="$GAMES" '
    $1 == "MGL" {
      if ($3 == "") { printf "  %-28s NAMES NO PACK\n", $2; next }
      named[games "/" $3] = 1
      printf "  %-28s -> %s\n", $2, $3
      next
    }
    $1 == "FILE" { have[$2] = $3 }
    END {
      for (p in named) {
        if (p in have) printf "      present, %s bytes\n", have[p]
        else           printf "      MISSING FROM THE CARD - the core will not find it\n"
      }
    }'
  echo
  echo "== stashed alternates in $GAMES/packs/"
  printf '%s\n' "$RAW" | awk -F'|' '$1=="FILE" && $2 ~ /\/packs\// { printf "  %-40s %s bytes\n", $2, $3 }'
  printf '%s\n' "$RAW" | awk -F'|' '$1=="FILE" && $2 ~ /\/packs\// { found=1 } END { if (!found) print "  (none)" }'
  echo
  echo "== stale: in $GAMES but no MGL names it and nothing has stashed it"
  printf '%s\n' "$RAW" | awk -F'|' -v games="$GAMES" '
    $1 == "MGL"  { if ($3 != "") named[games "/" $3] = 1; next }
    $1 == "FILE" { if ($2 !~ /\/packs\// && !($2 in named)) printf "  %-40s %s bytes\n", $2, $3 }'
  printf '%s\n' "$RAW" | awk -F'|' -v games="$GAMES" '
    $1 == "MGL"  { if ($3 != "") named[games "/" $3] = 1; next }
    $1 == "FILE" { if ($2 !~ /\/packs\// && !($2 in named)) found=1 } END { if (!found) print "  (none)" }'
  ;;

use)
  name=${2:?usage: mister_packs.sh use <pack.bin> [mgl]  -- a name under packs/}
  mgl=${3:-$DEFAULT_MGL}
  run "test -f $GAMES/packs/'$name' || { echo \"no such stash: $GAMES/packs/$name\" >&2;
         echo 'available:' >&2; ls -1 $GAMES/packs/ >&2; exit 1; }
       test -f '$mgl' || { echo \"no such MGL: $mgl\" >&2; exit 1; }
       target=\$(sed -n '$MGL_PACK_SED' '$mgl' | head -1)
       [ -n \"\$target\" ] || { echo \"$mgl names no pack (type=f entry); not touching it\" >&2; exit 1; }
       cp -f $GAMES/packs/'$name' $GAMES/\"\$target\".tmp && mv -f $GAMES/\"\$target\".tmp $GAMES/\"\$target\"
       echo \"installed $name as \$target, which $mgl names\"
       echo -n '  sha256 '; sha256sum $GAMES/\"\$target\" | cut -c1-16"
  ;;

stash)
  file=${2:?usage: mister_packs.sh stash <file> [name]}
  name=${3:-$(basename "$file")}
  [ -f "$file" ] || { echo "no such file: $file" >&2; exit 1; }
  run "mkdir -p $GAMES/packs"
  $SSHP scp $SCPO "$file" $HOST:$GAMES/packs/$name >/dev/null
  run "wc -c < $GAMES/packs/'$name'" | sed 's/^/  stashed bytes: /'
  ;;

prune)
  # Only ever deletes what NO MGL names and nothing has stashed. The protected set is
  # recomputed on the card in the same breath as the deletion, so an MGL written between
  # the two cannot lose its pack.
  run "
    prot=''
    for m in /media/fat/PC9821*.mgl; do
      [ -e \"\$m\" ] || continue
      p=\$(sed -n '$MGL_PACK_SED' \"\$m\" | head -1)
      [ -n \"\$p\" ] && prot=\"\$prot $GAMES/\$p\"
    done
    kept=0; gone=0
    for f in $GAMES/*.bin; do
      [ -e \"\$f\" ] || continue
      case \" \$prot \" in *\" \$f \"*) echo \"  keep   \$f (an MGL names it)\"; kept=\$((kept+1)); continue;; esac
      rm -f \"\$f\" && { echo \"  remove \$f\"; gone=\$((gone+1)); }
    done
    echo \"  \$kept kept, \$gone removed\"
    echo 'remaining:'; ls -l --time-style=+%m-%d_%H:%M $GAMES/*.bin 2>/dev/null || true"
  ;;

*)
  usage; exit 1;;
esac
