#!/usr/bin/env bash
# Upload the PC-9821 z486 core to the MiSTer and load it, using MiSTer's command
# FIFO (load_core) -- no OSD interaction.
#
# ONE JOB: this is the tool that PROVISIONS the card. It writes the RBF, the firmware
# packs (each verified against your dumps first), the MGLs and the disk image, then
# starts the core. Its three neighbours each do something else and none of them
# provision:
#   tools/deploy_mister.sh  stages the same set into mister_deploy/ for a manual copy
#                           to the card; it never opens a connection
#   tools/mister_packs.sh   manages the pack files already ON the card (list, stash,
#                           switch); it never builds or verifies one
#   tools/run_on_mister.sh  starts the core and reads its telemetry; it writes no file
#
# One core, one MGL per firmware set. The RBF is shared; each MGL points at its own
# pack, so the menu offers each machine's firmware as its own entry:
#
#   _Computer/PC9821Z486.rbf          the core (one file)
#   PC9821Z486.mgl                    the default set (xe10)
#   PC9821Z486-xe.mgl                 the other set
#   games/PC9821/pc98pack-xe10.bin    the packs, from your own dumps
#   games/PC9821/pc98pack-xe.bin
#
# Nothing is copied to Scripts/: no script is installed on the MiSTer (the image converters
# run on a computer).
#
#   tools/mister_load.sh                 # default set: RBF + pack + MGL + image, load
#   tools/mister_load.sh --both          # both sets' packs and MGLs
#   tools/mister_load.sh --machine xe    # select the other set
#   tools/mister_load.sh --packs-only    # packs and MGLs only, without the RBF
#   tools/mister_load.sh --no-copy       # reload the installed core
#   tools/mister_load.sh --no-image      # deploy without a disk entry
#   tools/mister_load.sh --fdd0 A.d88 --fdd1 B.d88
#                                        # also list a floppy per DRIVE in the MGL
#                                        # (hps_io slots 1 and 2); the OSD's own S1/S2
#                                        # entries mount either drive at any time
#   tools/mister_load.sh --hdd2 B.img    # also list a second hard disk (hps_io slot 3) in
#                                        # the MGL; it is IDE bank 1's master only while the
#                                        # OSD's "IDE bank 1" field says HDD2 (status[67],
#                                        # PC9821.CFG byte 8 bit 3), which an MGL cannot set
#   tools/mister_load.sh --pack          # replace the pack already on the card
#   tools/mister_load.sh --dumps DIR     # where the machine dumps live (see below)
#   tools/mister_load.sh --skip-pack-check   # do NOT verify the local pack against
#                                            # the dumps (for hosts without them)
#   tools/mister_load.sh --allow-stale-pack  # accept a card pack that differs from
#                                            # the local build instead of failing
#   tools/mister_load.sh --allow-marginal-hdmi
#                                            # deploy an RBF whose framework pll_hdmi
#                                            # setup slack is below the deploy floor
#                                            # (see "THE HDMI DEPLOY FLOOR" below)
#   tools/mister_load.sh --clean-stale       # ALSO delete the other PC9821*.rbf cores and
#                                            # the PC9821*.mgl files this run does not write
#                                            # (see "NOTHING IS DELETED UNLESS ASKED" below)
#
# NOTHING IS DELETED UNLESS ASKED. A card is a shared device: it holds the owner's main core,
# its backups and the owner's own MGLs beside whatever this script deploys. This script used
# to delete every /media/fat/_Computer/PC9821*.rbf except the one it deployed and every
# PC9821*.mgl it did not write, on every run; on a shared test card that removes the main core
# and its backups. Now it only LISTS those files, and deletes them only with --clean-stale.
#
# A TEST CORE TOUCHES ONLY TEST FILES. When MISTER_CORE contains "zreg" (any case; the test
# name docs/mister-testing.md gives every test build, e.g. MISTER_CORE=PC9821Z486-zreg), every
# file this script writes or deletes on the card has "zreg" in its name: the RBF and the MGLs
# are named after the core; the disk image and any floppy must be zreg-named copies (MISTER_IMG,
# --hdd2, --fdd0/--fdd1; the card's own hdd.img is never mounted, use --no-image for none); the pack is
# never written (the card's pack is checked read-only: --pack is refused); and --clean-stale removes only zreg-named PC9821 cores and MGLs.
#
# The local pack (build/pc98pack-<machine>.bin) is verified against the dumps with
# tools/check_pack.py BEFORE it is deployed, and a pack already on the card that
# differs from that verified build is a hard failure: the transfer check can only
# prove the card got the local file's bytes, never that the local file is the
# dumps. That gap is what let a stale pc98pack-xe10.bin (0xF8000 window missing
# BANK7.BIN) sit on the card while every deploy printed "verified", and the guest
# showed ROM SUM ERROR. The dumps are found at $PC98_DUMPS (or $BIOS_DIR), the
# machine's own subdirectory first: <base>/<machine>/BANK4.BIN, else <base>/BANK4.BIN.
#
#   env: MISTER_HOST (ssh destination, default root@MiSTer; a bare host name gets root@),
#        MISTER_PASS (default 1, the stock root password, through sshpass -e; empty = ssh keys),
#        MISTER_CORE (default PC9821Z486),
#        PC98_DUMPS / BIOS_DIR (default ./bios),
#        MISTER_IMG  (path to a PC-98 .img to upload+mount; default: mount
#                     hdd.img if it is already on the card),
#        MISTER_FDD0 / MISTER_FDD1 (floppy images to upload and list for drive 0
#                     and drive 1; the same as --fdd0/--fdd1)
#        MISTER_HDD2 (a second hard-disk image to upload and list; the same as --hdd2)
set -eu
cd "$(dirname "$0")/.."

HOST=${MISTER_HOST:-root@MiSTer}
case $HOST in *@*) ;; *) HOST=root@$HOST ;; esac
RBF=output_files/z486_mister.rbf
CORE=${MISTER_CORE:-PC9821Z486}
DEST=/media/fat/_Computer/$CORE.rbf
# The MGL's <setname> is what MiSTer names the core's per-core CONFIG file after, so this
# one value decides BOTH the MGL written below and the config path inspected below it. It
# is NOT the RBF name: the card's config directory is keyed by setname (it holds
# Genesis.CFG, SNES.CFG and MegaCD.CFG for those cores), so this core's is PC9821.CFG and
# PC9821Z486.CFG has never existed. A config test built on the RBF name silently inspects
# nothing and reports 'none needed' whatever the card holds, which defeats the warning this
# script exists to give; tools/check_mister_layout.py fails if the two ever disagree.
SETNAME=PC9821
GAMES=/media/fat/games/PC9821
IMG=${MISTER_IMG:-}
IMGNAME=${IMG:+$(basename "$IMG")}
IMGNAME=${IMGNAME:-hdd.img}
# The two floppy drives' images, one hps_io slot each. They are OPTIONAL: the OSD's
# S1/S2 entries can mount either drive at any time, and these only list one in the MGL
# so the guest finds it on its first access instead of needing a menu visit.
FDD0=${MISTER_FDD0:-}
FDD1=${MISTER_FDD1:-}
# The second hard disk's image (hps_io slot 3), OPTIONAL in the same way.
HDD2=${MISTER_HDD2:-}

# Authentication: password "1" (the stock MiSTer root password) by default, through sshpass -e (it reads
# SSHPASS from the environment, so the password never appears on a command line).
SSHP=""
MISTER_PASS="${MISTER_PASS-1}"   # the stock MiSTer root password; MISTER_PASS= (empty) uses ssh keys
if [ -n "$MISTER_PASS" ]; then export SSHPASS="$MISTER_PASS"; SSHP="sshpass -e"; fi
SSHO="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"

machine=xe10
both=0
copy=1
packs_only=0
mount_image=1
force_pack=0
skip_pack_check=0
allow_stale_pack=0
allow_marginal_hdmi=0
clean_stale=0
selftest=0
dumps_base=${PC98_DUMPS:-${BIOS_DIR:-bios}}
# A while/shift loop: an option's value (--machine xe) is its own word, which a `for` over "$@"
# would visit next as an unknown option.
while [ $# -gt 0 ]; do
  arg=$1
  case "$arg" in
    --machine)  machine=${2:?--machine needs a name}; shift ;;
    --machine=*) machine=${arg#*=} ;;
    --both)     both=1 ;;
    --packs-only) packs_only=1 ;;
    --no-copy)  copy=0 ;;
    --no-image) mount_image=0 ;;
    --fdd0)     FDD0=${2:?--fdd0 needs a path}; shift ;;
    --fdd0=*)   FDD0=${arg#*=} ;;
    --fdd1)     FDD1=${2:?--fdd1 needs a path}; shift ;;
    --fdd1=*)   FDD1=${arg#*=} ;;
    --hdd2)     HDD2=${2:?--hdd2 needs a path}; shift ;;
    --hdd2=*)   HDD2=${arg#*=} ;;
    --pack)     force_pack=1 ;;
    --dumps)    dumps_base=${2:?--dumps needs a directory}; shift ;;
    --dumps=*)  dumps_base=${arg#*=} ;;
    --skip-pack-check)  skip_pack_check=1 ;;
    --allow-stale-pack) allow_stale_pack=1 ;;
    --allow-marginal-hdmi) allow_marginal_hdmi=1 ;;
    --clean-stale) clean_stale=1 ;;
    --selftest) selftest=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
  shift
done

# The test-core rule (header, "A TEST CORE TOUCHES ONLY TEST FILES"): is this name zreg-named?
is_zreg() { case "$1" in *[zZ][rR][eE][gG]*) return 0 ;; *) return 1 ;; esac; }
zreg_mode=0
if is_zreg "$CORE"; then zreg_mode=1; fi

# THE HDMI DEPLOY FLOOR. The framework's `pll_hdmi` domain is ~2.4k ALMs of frozen scaler/OSD
# logic pinned to one quadrant and interleaved with our 84% of the die; its seed-to-seed spread
# is 0.11-0.41 ns and a bad draw can wedge the HDMI scaler on load (the card then cannot even
# screenshot the Menu core until a reboot). The hardware-confirmed wedge and every other
# bad-band placement sit below this floor; hardware-verified good ones reach -0.33 ns, so -0.35
# admits every known-good placement. tools/build.py writes the number beside the RBF in
# artifact-timing.json (tools/fit_metrics.py --write-artifact), with the RBF's own sha256. A
# below-floor margin, a record that cannot be parsed, or a record whose rbf_sha256 is another
# RBF's refuses the deploy unless --allow-marginal-hdmi is passed; an absent record or an absent
# margin field is reported as unrecorded (it cannot be checked), not refused. The rule and its numbers:
# docs/fitting.md ("Timing and area facts") and docs/timing.md.
# The number lives once, in tools/fit_metrics.py (tools/seed_sweep.py and tools/fit_matrix.py
# import it); read it here so the loader cannot drift from the sweep that chose the seed.
HDMI_FLOOR=$(python3 tools/fit_metrics.py --print-hdmi-floor 2>/dev/null || echo -0.35)

# The gate itself: print the RBF's recorded margin and return 1 when it must be refused.
# $1 = the artifact-timing.json path, $2 = the RBF about to be deployed. An absent file or an
# absent margin field is a WARNING (a pre-guard build, or an RBF copied without its record): it
# cannot be checked, and the message says so rather than silently passing it as if it were
# verified. A record that cannot be parsed, or whose rbf_sha256 names a different RBF (one
# copied into output_files/ over another fit's record), is REFUSED like a below-floor margin.
hdmi_gate() {
    local timing=$1 rbf=${2:-} margin tns clock seed rsum fields
    if [ ! -f "$timing" ]; then
        echo "  no $timing: this RBF's pll_hdmi margin is NOT recorded"
        echo "    (a pre-guard build, or an RBF copied here without its timing record)"
        return 0
    fi
    # one field per tab-separated column, "-" for an absent one, so a missing value can never
    # shift the next one into its place
    fields=$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    assert isinstance(d, dict), "not a JSON object"
    v = d.get("hdmi_setup", d.get("other_setup"))
    t = d.get("hdmi_tns", d.get("other_tns"))
    f = lambda x: "-" if x is None else "%.3f" % float(x)
    s = lambda x: "-" if x in (None, "") else str(x).replace("\t", " ")
    print("\t".join(["ok", f(v), f(t), s(d.get("other_clock", "pll_hdmi")), s(d.get("seed")),
                     s(d.get("rbf_sha256"))]))
except Exception as e:
    print("bad\t" + str(e).replace("\t", " ").replace(chr(10), " ")[:120])' "$timing" 2>&1)
    if [ "${fields%%$'\t'*}" != "ok" ]; then
        echo "ERROR: $timing cannot be read (${fields#*$'\t'}): the RBF's pll_hdmi margin is unknown." >&2
        if [ "$allow_marginal_hdmi" = "1" ]; then
            echo "  WARNING: --allow-marginal-hdmi: deploying it unchecked" >&2
            return 0
        fi
        echo "       Refusing to deploy it (rewrite the record with tools/fit_metrics.py" >&2
        echo "       --write-artifact, or pass --allow-marginal-hdmi and say why)." >&2
        return 1
    fi
    IFS=$'\t' read -r _ margin tns clock seed rsum <<< "$fields"
    if [ "$rsum" != "-" ] && [ -n "$rbf" ]; then
        local have
        have=$(sha256sum "$rbf" | awk '{print $1}')
        if [ "$have" != "$rsum" ]; then
            echo "ERROR: $timing describes another RBF (rbf_sha256 $rsum," >&2
            echo "       $rbf is $have): its margin says nothing about this placement." >&2
            if [ "$allow_marginal_hdmi" = "1" ]; then
                echo "  WARNING: --allow-marginal-hdmi: deploying it unchecked" >&2
                return 0
            fi
            echo "       Refusing to deploy it. Copy the RBF together with its own" >&2
            echo "       artifact-timing.json, or pass --allow-marginal-hdmi and say why." >&2
            return 1
        fi
        echo "  timing record matches this RBF (sha256)"
    elif [ "$rsum" = "-" ]; then
        echo "  $timing does not name its RBF (no rbf_sha256): it is trusted to describe this one"
    fi
    if [ "$margin" = "-" ]; then
        echo "  $timing records no pll_hdmi margin: cannot check it"
        return 0
    fi
    [ "$tns" = "-" ] && tns="not recorded"
    [ "$seed" = "-" ] && seed="not recorded"
    echo "  pll_hdmi margin ${margin} ns (TNS ${tns} ns, ${clock};" \
         "seed ${seed}), deploy floor ${HDMI_FLOOR} ns"
    if ! awk -v v="$margin" -v f="$HDMI_FLOOR" 'BEGIN { exit !(v + 0 < f + 0) }'; then
        echo "  clears the ${HDMI_FLOOR} ns deploy floor"
        return 0
    fi
    if [ "$allow_marginal_hdmi" = "1" ]; then
        echo "  WARNING: --allow-marginal-hdmi: ${margin} ns is below the ${HDMI_FLOOR} ns" >&2
        echo "  deploy floor; this placement may wedge the HDMI scaler on load. Hardware-test" >&2
        echo "  it and record why it was accepted - do not widen the floor silently." >&2
        return 0
    fi
    echo "ERROR: this fit's framework pll_hdmi setup slack is ${margin} ns, below the" >&2
    echo "       ${HDMI_FLOOR} ns deploy floor. A seed in that band can wedge the scaler on" >&2
    echo "       load: the card then cannot screenshot even the Menu core until it is" >&2
    echo "       rebooted. Refusing to deploy it. Deploy a seed that clears the floor:" >&2
    echo "         python3 tools/seed_sweep.py --dir <sweep> --report --min-seeds 6" >&2
    echo "         cp <sweep>/seedNNN/output_files/z486_mister.rbf output_files/" >&2
    echo "         cp <sweep>/seedNNN/output_files/artifact-timing.json output_files/" >&2
    echo "         cp <sweep>/seedNNN/output_files/fit-source.sha256 output_files/" >&2
    echo "       or pass --allow-marginal-hdmi to deploy this one anyway (and say why)." >&2
    return 1
}

# Hardware-free checks of the deploy gate (planted margins; below the floor MUST be refused).
if [ "$selftest" = "1" ]; then
    tmp=$(mktemp -d)
    printf '{"other_setup": -0.100, "other_tns": 0.0, "other_clock": "pll_hdmi", "seed": 3}\n' > "$tmp/ok.json"
    printf '{"other_setup": -0.340}\n' > "$tmp/edge.json"
    printf '{"other_setup": -0.600, "other_tns": -23.1}\n' > "$tmp/bad.json"
    printf '{"note": "no timing"}\n' > "$tmp/none.json"
    fail=0
    hdmi_gate "$tmp/ok.json" >/dev/null 2>&1 || { echo "selftest FAIL: -0.100 must pass"; fail=1; }
    hdmi_gate "$tmp/edge.json" >/dev/null 2>&1 || { echo "selftest FAIL: -0.340 must pass"; fail=1; }
    if hdmi_gate "$tmp/bad.json" >/dev/null 2>&1; then
        echo "selftest FAIL: -0.600 must be refused"; fail=1
    fi
    allow_marginal_hdmi=1
    hdmi_gate "$tmp/bad.json" >/dev/null 2>&1 || { echo "selftest FAIL: the escape must override"; fail=1; }
    allow_marginal_hdmi=0
    hdmi_gate "$tmp/none.json" >/dev/null 2>&1 || { echo "selftest FAIL: no margin must warn, not refuse"; fail=1; }
    hdmi_gate "$tmp/missing.json" >/dev/null 2>&1 || { echo "selftest FAIL: absent file must warn"; fail=1; }
    # an unparsable record refuses (the escape overrides it)
    printf '{"other_setup": -0.1,' > "$tmp/broken.json"
    printf '[1, 2]\n' > "$tmp/list.json"
    printf '{"other_setup": "n/a"}\n' > "$tmp/text.json"
    for j in broken list text; do
        if hdmi_gate "$tmp/$j.json" >/dev/null 2>&1; then echo "selftest FAIL: an unreadable record ($j) must be refused"; fail=1; fi
    done
    allow_marginal_hdmi=1
    hdmi_gate "$tmp/broken.json" >/dev/null 2>&1 || { echo "selftest FAIL: the escape must override an unreadable record"; fail=1; }
    allow_marginal_hdmi=0
    # a missing setup value must not let the TNS slide into the margin's place
    printf '{"other_tns": 0.0, "other_clock": "pll_hdmi"}\n' > "$tmp/notns.json"
    out=$(hdmi_gate "$tmp/notns.json" 2>&1) || { echo "selftest FAIL: no setup value must warn, not refuse"; fail=1; }
    case $out in *"records no pll_hdmi margin"*) ;; *) echo "selftest FAIL: no setup value read as a margin: $out"; fail=1 ;; esac
    printf '{"other_tns": -23.1}\n' > "$tmp/negtns.json"
    out=$(hdmi_gate "$tmp/negtns.json" 2>&1)
    case $out in *"margin -23.100"*) echo "selftest FAIL: the TNS was read as the margin"; fail=1 ;; esac
    # the record must belong to the RBF being deployed
    printf 'rbf bytes' > "$tmp/a.rbf"
    sum=$(sha256sum "$tmp/a.rbf" | awk '{print $1}')
    printf '{"other_setup": -0.100, "rbf_sha256": "%s"}\n' "$sum" > "$tmp/mine.json"
    printf '{"other_setup": -0.100, "rbf_sha256": "%064d"}\n' 0 > "$tmp/other.json"
    hdmi_gate "$tmp/mine.json" "$tmp/a.rbf" >/dev/null 2>&1 || { echo "selftest FAIL: a record of this RBF must pass"; fail=1; }
    if hdmi_gate "$tmp/other.json" "$tmp/a.rbf" >/dev/null 2>&1; then
        echo "selftest FAIL: a record of another RBF must be refused"; fail=1
    fi
    allow_marginal_hdmi=1
    hdmi_gate "$tmp/other.json" "$tmp/a.rbf" >/dev/null 2>&1 || { echo "selftest FAIL: the escape must override a foreign record"; fail=1; }
    allow_marginal_hdmi=0
    hdmi_gate "$tmp/ok.json" "$tmp/a.rbf" >/dev/null 2>&1 || { echo "selftest FAIL: a record without rbf_sha256 must pass"; fail=1; }
    for n in PC9821Z486-zreg PC9821Z486-ZREG90 zreg-shmoo.img ZREG.mgl; do
        is_zreg "$n" || { echo "selftest FAIL: $n is zreg-named"; fail=1; }
    done
    for n in PC9821Z486 PC9821Z486-test hdd.img PC9821Z486_20261029.rbf; do
        if is_zreg "$n"; then echo "selftest FAIL: $n is not zreg-named"; fail=1; fi
    done
    rm -rf "$tmp"
    if [ "$fail" = "0" ]; then echo "mister_load selftest: PASS"; exit 0; fi
    echo "mister_load selftest: FAIL"; exit 1
fi

# The dumps for one machine: its own subdirectory of the base if that is how the
# base is laid out (bios/xe10, bios/xe), else the base itself (a flat bios/).
dumps_dir() {
    local m=$1
    if [ -f "$dumps_base/$m/BANK4.BIN" ]; then echo "$dumps_base/$m"
    elif [ -f "$dumps_base/BANK4.BIN" ]; then echo "$dumps_base"
    else echo ""
    fi
}

# Verify the LOCAL pack against the machine's dumps. The transfer check below can
# only prove the card has the local file's bytes; this is the check that proves the
# local file is the firmware the ITF will accept. tools/check_pack.py is run without
# --mem on purpose: the card consumes only the .bin, and there is no mirror beside a
# deployable pack.
verify_pack_against_dumps() {
    local m=$1 pack=$2 dir
    dir=$(dumps_dir "$m")
    if [ -z "$dir" ]; then
        echo "  no dumps for $m under $dumps_base (BANK4.BIN/BIOS.ROM/FONT.ROM/BANK3.BIN/" >&2
        echo "  BANK0..7.BIN): the pack cannot be verified against the dumps" >&2
        echo "  set PC98_DUMPS (or --dumps DIR), or pass --skip-pack-check to bypass" >&2
        return 1
    fi
    echo "  verifying $pack against the $m dumps ($dir)"
    python3 tools/check_pack.py --pack "$pack" \
        --itf "$dir/BANK4.BIN" --bios "$dir/BIOS.ROM" \
        --ide "$dir/BANK3.BIN" --font "$dir/FONT.ROM" --banks "$dir"
}

pack_name() { echo "pc98pack-$1.bin"; }
mgl_for()   { if [ "$1" = "xe10" ]; then echo "/media/fat/$CORE.mgl"; else echo "/media/fat/$CORE-$1.mgl"; fi; }

# The test-core preflight, before any connection: refuse anything that would write a file
# without "zreg" in its name.
if [ "$zreg_mode" = "1" ]; then
    echo "test core $CORE: only zreg-named files on the card are written or deleted"
    if [ "$force_pack" = "1" ]; then
        echo "ERROR: --pack would overwrite the card's pack; a zreg core uses the pack already" >&2
        echo "       on the card, read-only" >&2
        exit 2
    fi
    if [ "$mount_image" = "1" ] && ! is_zreg "$IMGNAME"; then
        echo "ERROR: the MGL would mount $IMGNAME, which is not a zreg-named copy. Upload a" >&2
        echo "       copy with MISTER_IMG=<path>/<something>-zreg.img, or pass --no-image" >&2
        exit 2
    fi
    for f in "$FDD0" "$FDD1" "$HDD2"; do
        if [ -n "$f" ] && ! is_zreg "$(basename "$f")"; then
            echo "ERROR: image $f is not a zreg-named copy" >&2; exit 2
        fi
    done
fi

# A fresh card has none of these directories (nothing has run a PC9821 core on it yet), and scp
# does not create them: make them before the first copy. mkdir -p is a no-op on a used card.
$SSHP ssh $SSHO $HOST "mkdir -p /media/fat/_Computer $GAMES /media/fat/config"

MACHINES=$machine
[ "$both" = "1" ] && MACHINES="xe10 xe"
[ "$packs_only" = "1" ] && copy=0

if [ "$copy" = "1" ]; then
    [ -f "$RBF" ] || { echo "$RBF not found; run the Quartus build first" >&2; exit 1; }

    # output_files/ IS A COPY DESTINATION, NOT A SOURCE OF TRUTH. A build that ran in a worktree
    # leaves its artefact in that worktree and never touches this tree's output_files/, so the file
    # here can be arbitrarily old -- it once held a core that predated several fixes.
    # fit-source.sha256 describes the RTL a fit was built FROM and cannot identify a bitstream,
    # so this reports what is known rather than pretending to verify it.
    echo "RBF to deploy:"
    echo "  $RBF  $(stat -c%s "$RBF") bytes"
    echo "  sha256 $(sha256sum "$RBF" | awk '{print $1}')"
    if [ -f output_files/fit-source.sha256 ]; then
        echo "  built in  $(sed -n 's/^tree: //p' output_files/fit-source.sha256)"
        echo "  rtl-hash  $(sed -n 's/^rtl-hash: //p' output_files/fit-source.sha256)"
        # The clock is not in the RTL hash and never was: a profile switch rewrites both the
        # localparam and the generated PLL. A bitstream that cannot name its clock is one you
        # cannot compare with another.
        echo "  profile   $(sed -n 's/^profile: //p' output_files/fit-source.sha256), clock $(sed -n 's/^clock: //p' output_files/fit-source.sha256) Hz"
        echo "  (that evidence describes the RTL, not this bitstream: if the RBF was copied here"
        echo "   by hand, confirm it came from the tree named above)"
    else
        echo "  no fit-source.sha256 beside it -- this RBF has no recorded provenance"
    fi

    # THE DEPLOY GATE. fit-source.sha256 above is SOURCE provenance; artifact-timing.json is
    # the PLACEMENT's own record (the seed and the pll_hdmi margin it drew), written after the
    # fit by tools/build.py. An RBF without it cannot be checked: say so, do not pretend.
    hdmi_gate output_files/artifact-timing.json "$RBF" || exit 1
    echo "copying RBF -> $DEST"
    $SSHP scp $SSHO "$RBF" $HOST:$DEST
    LOCAL_SUM=$(sha256sum "$RBF" | awk '{print $1}')
    REMOTE_SUM=$($SSHP ssh $SSHO $HOST "sha256sum '$DEST'" | awk '{print $1}')
    [ "$LOCAL_SUM" = "$REMOTE_SUM" ] || { echo "RBF checksum mismatch" >&2; exit 1; }
    echo "  RBF sha256 $LOCAL_SUM verified"
fi

# The packs are runtime inputs holding the user's own dumped firmware. Whatever goes
# on the card is verified against the dumps first, and a card pack that differs from
# the verified local build is a failure rather than a silent keep (see the header).
# WHICH LOCAL PACK, AND WHY THIS ORDER. 'make pack' writes build/pc98pack.bin; the older
# convention was one file per machine, build/pc98pack-<machine>.bin. This looked for ONLY the
# second, so the documented flow - make pack, then deploy - always printed "no local pack for
# xe10" and continued without deploying any firmware, after a 25-minute build. The card keeps a
# per-machine name because one card holds several machines' packs; the LOCAL file need not be
# per-machine, because verify_pack_against_dumps below proves which machine's dumps it is.
# PC98_PACK names a pack explicitly and wins, which is also what tools/run_on_mister.sh uses.
for m in $MACHINES; do
    PACK=$(pack_name "$m")
    LOCAL_PACK=""
    for candidate in "${PC98_PACK:-}" "build/$(pack_name "$m")" build/pc98pack.bin; do
        if [ -n "$candidate" ] && [ -f "$candidate" ]; then LOCAL_PACK="$candidate"; break; fi
    done
    if [ -z "$LOCAL_PACK" ]; then
        echo "no local pack for $m: looked for \${PC98_PACK:-<unset>}, build/$(pack_name "$m")" >&2
        echo "  and build/pc98pack.bin. Build one from a dump directory with:" >&2
        echo "    make pack PC98_DUMPS=/path/to/your/dumps" >&2
        continue
    fi
    echo "  pack for $m: $LOCAL_PACK"

    if [ "$skip_pack_check" = "1" ]; then
        echo "  WARNING: --skip-pack-check: $LOCAL_PACK is NOT being verified against the dumps" >&2
    elif ! verify_pack_against_dumps "$m" "$LOCAL_PACK"; then
        echo "  ERROR: the local pack for $m is not the dumps; refusing to deploy it." >&2
        echo "         rebuild it (tools/build_pack.py ... --out $LOCAL_PACK), or pass" >&2
        echo "         --skip-pack-check to bypass the check at your own risk." >&2
        exit 1
    fi

    if [ "$zreg_mode" = "1" ] && ! $SSHP ssh $SSHO $HOST "test -f '$GAMES/$PACK'"; then
        echo "ERROR: the card has no $GAMES/$PACK, and a zreg core never writes the pack" >&2
        echo "       (it is not a zreg file). Deploy the pack with a normal run first." >&2
        exit 1
    fi
    if [ "$force_pack" = "1" ] ||
       ! $SSHP ssh $SSHO $HOST "test -f '$GAMES/$PACK'"; then
        echo "copying pack ($m) -> $GAMES/$PACK"
        $SSHP scp $SSHO "$LOCAL_PACK" $HOST:$GAMES/$PACK
        LOCAL_SUM=$(sha256sum "$LOCAL_PACK" | awk '{print $1}')
        REMOTE_SUM=$($SSHP ssh $SSHO $HOST "sha256sum '$GAMES/$PACK'" | awk '{print $1}')
        # The loader cannot tell a truncated pack from a complete one, so the check
        # that a pack arrived intact has to happen here.
        [ "$LOCAL_SUM" = "$REMOTE_SUM" ] || {
            echo "pack ($m) checksum mismatch on the card" >&2; exit 1; }
        echo "  sha256 $LOCAL_SUM verified"
    else
        LOCAL_SUM=$(sha256sum "$LOCAL_PACK" | awk '{print $1}')
        REMOTE_SUM=$($SSHP ssh $SSHO $HOST "sha256sum '$GAMES/$PACK'" | awk '{print $1}')
        if [ "$LOCAL_SUM" = "$REMOTE_SUM" ]; then
            echo "keeping the pack already on the card -> $GAMES/$PACK"
            echo "  sha256 $REMOTE_SUM matches the local build"
        elif [ "$allow_stale_pack" = "1" ]; then
            echo "keeping the pack already on the card -> $GAMES/$PACK"
            echo "  WARNING: --allow-stale-pack: the card's pack ($REMOTE_SUM) differs from" >&2
            echo "  the verified local build ($LOCAL_SUM); the card runs the former" >&2
        else
            echo "ERROR: the card's pack ($REMOTE_SUM) differs from the verified local build" >&2
            echo "       ($LOCAL_SUM). The card would run firmware that was not the one just" >&2
            echo "       verified against the dumps -- how a stale pack caused the guest's" >&2
            echo "       ROM SUM ERROR. Refusing to continue." >&2
            echo "       Re-run with --pack to replace it, or --allow-stale-pack to accept it." >&2
            exit 1
        fi
    fi
done

if [ -n "$IMG" ] && [ "$copy" = "1" ]; then
    [ -f "$IMG" ] || { echo "image not found: $IMG" >&2; exit 1; }
    echo "copying image -> $GAMES/$IMGNAME"
    $SSHP scp $SSHO "$IMG" $HOST:$GAMES/$IMGNAME
fi

# The floppies go up the same way, into the same games folder, and a missing file is a
# hard failure BEFORE anything is written - exactly as the disk image's is. An MGL
# listing a path the card does not have mounts nothing, and the guest then sees an
# empty drive.
FDDNAME0=""; FDDNAME1=""
for pair in "0:$FDD0" "1:$FDD1"; do
    drv=${pair%%:*}; path=${pair#*:}
    if [ -z "$path" ]; then continue; fi
    [ -f "$path" ] || { echo "floppy image for drive $drv not found: $path" >&2; exit 1; }
    name=$(basename "$path")
    if [ "$copy" = "1" ]; then
        echo "copying FDD$drv image -> $GAMES/$name"
        $SSHP scp $SSHO "$path" $HOST:$GAMES/$name
    fi
    if [ "$drv" = "0" ]; then FDDNAME0=$name; else FDDNAME1=$name; fi
done
HDD2NAME=""
if [ -n "$HDD2" ]; then
    [ -f "$HDD2" ] || { echo "second hard-disk image not found: $HDD2" >&2; exit 1; }
    HDD2NAME=$(basename "$HDD2")
    if [ "$copy" = "1" ]; then
        echo "copying HDD2 image -> $GAMES/$HDD2NAME"
        $SSHP scp $SSHO "$HDD2" $HOST:$GAMES/$HDD2NAME
    fi
fi

# Other PC9821 cores and MGLs this run does not write: LISTED, and deleted only with
# --clean-stale (header, "NOTHING IS DELETED UNLESS ASKED"). For a test core the candidates are
# only zreg-named ones, so the owner's cores and MGLs are never even candidates.
if [ "$zreg_mode" = "1" ]; then
    RBF_GLOB='/media/fat/_Computer/PC9821*[zZ][rR][eE][gG]*.rbf'
    MGL_GLOB='/media/fat/PC9821*[zZ][rR][eE][gG]*.mgl'
else
    RBF_GLOB='/media/fat/_Computer/PC9821*.rbf'
    MGL_GLOB='/media/fat/PC9821*.mgl'
fi
if [ "$clean_stale" = "1" ]; then
    echo "--clean-stale: removing other cores/MGLs ($RBF_GLOB, $MGL_GLOB)"
    STALE_ACT='rm -f "$f" && echo "  removed $f"'
else
    echo "other cores/MGLs on the card (kept; --clean-stale removes them):"
    STALE_ACT='echo "  $f"'
fi
$SSHP ssh $SSHO $HOST "
  for f in $RBF_GLOB; do
    [ -e \"\$f\" ] || continue
    case \"\$f\" in '$DEST') continue ;; esac
    $STALE_ACT
  done
  for f in $MGL_GLOB; do
    [ -e \"\$f\" ] || continue
    case \"\$f\" in /media/fat/$CORE.mgl|/media/fat/$CORE-*.mgl) continue ;; esac
    $STALE_ACT
  done"

# The image entry comes BEFORE the pack entry: MGL file entries are processed in
# order and cpu_run is released by the pack download finishing, so an image listed
# second is mounted after the guest has already probed the drive and latched \"no disk\".
# THE FLOPPY ENTRIES FOLLOW THE SAME RULE, and an S entry's `index` IS the hps_io
# SLOT: 0 is the disk (CONF_STR S0), 1 is FDD0 (S1) and 2 is FDD1 (S2). Main_MiSTer
# passes it straight through to user_io_file_mount (menu.cpp's mount action) and
# hps_io answers with that slot's bit in img_mounted (sys/hps_io.sv:490 (img_mounted  <= io_din[VD:0] ? io_din[VD:0] : 1'b1;)).
if [ "$mount_image" = "1" ]; then
    IMG_LINE="	<file delay=\"1\" type=\"s\" index=\"0\" path=\"$IMGNAME\"/>"
else
    IMG_LINE=""
fi
FDD_LINE0=""
FDD_LINE1=""
if [ -n "$FDDNAME0" ]; then FDD_LINE0="	<file delay=\"1\" type=\"s\" index=\"1\" path=\"$FDDNAME0\"/>"; fi
if [ -n "$FDDNAME1" ]; then FDD_LINE1="	<file delay=\"1\" type=\"s\" index=\"2\" path=\"$FDDNAME1\"/>"; fi
# Slot 3 is the second hard disk (CONF_STR S3).
HDD2_LINE=""
if [ -n "$HDD2NAME" ]; then HDD2_LINE="	<file delay=\"1\" type=\"s\" index=\"3\" path=\"$HDD2NAME\"/>"; fi

# WHY THERE IS NOTHING TO INSTALL. MiSTer gives a CONF_STR option no default entry
# (MkDocs_MiSTer developer/conf_str.md: the `O` field names a range, a label and the
# choices, nothing else), so a card with no stored selection passes 0 for EVERY field.
# MiSTer loads /media/fat/config/<setname>.CFG at core start for CORE_TYPE_8BIT cores
# (Main_MiSTer user_io.cpp, "try to load config" -- this core's sys/sys_top.v declares
# core_type 'hA4), and the file is the 16-byte status blob. <setname> is the MGL's, so
# the file is PC9821.CFG -- not the RBF's name.
#
# WITH THE ROTATED OSD LISTS, A MISSING FILE IS CORRECT AND THE DEFAULT BLOB IS ALL
# ZEROS. The RAM Size field is a list POSITION, and the list was rotated so entry 0 is
# the wanted default: byte 7 bits 5..7 are status[63:61] and entry 0 is 16 MB. MiSTer uses
# index 0 for every field when no file exists, so a card with no .CFG boots 16 MB -
# exactly as a card with a zeroed file does. There is nothing to install.
#
# THAT IS THE POINT OF THE ROTATION. Before it, entry 0 was the ascending list's 1 MB,
# and a 1 MB guest cannot run the Xe10 BIOS at all: it froze with nothing
# on screen, which looks exactly like a broken core. This script used to install a
# .CFG to cover for that, which only helps when someone remembers - so the trap stayed
# for every card nobody ran this on, which is how it was found.
#
# A .CFG WRITTEN BEFORE THE ROTATION NOW MEANS SOMETHING ELSE, because the value that
# selected 16 MB then selects 1 MB now (entry 4 is where 16 MB moved from). So this
# script does not silently keep one: it prints the file and says what to do.
CFG=/media/fat/config/$SETNAME.CFG
if $SSHP ssh $SSHO $HOST "test -f '$CFG'"; then
    echo "$CFG exists - printing it, because a pre-rotation one is now WRONG:"
    BYTES=$($SSHP ssh $SSHO $HOST "od -An -tx1 '$CFG'")
    echo "$BYTES"
    case "$(echo "$BYTES" | tr -d ' \n')" in
        *[!0]*) echo
            echo "  ^ THIS FILE IS NOT ZERO, so it was written for the PRE-ROTATION lists"
            echo "    and selects a different size than it did. The RAM field is byte 7 bits"
            echo "    5..7: the old 16 MB value 0x80 is now entry 4, which is 1 MB."
            echo "    Fix it on the card - either is enough, they are equivalent:"
            echo "      ssh root@<mister> 'rm /media/fat/config/$SETNAME.CFG'"
            echo "      ssh root@<mister> 'dd if=/dev/zero of=/media/fat/config/$SETNAME.CFG bs=16 count=1'"
            echo "    or re-select the size in the OSD and choose Save settings, which rewrites the file." ;;
        *)  echo "  all zero: that IS the default now (16 MB). Nothing to do."
            echo "    One thing to know: before the rotation an all-zero file selected 1 MB, so"
            echo "    if this card was deliberately set to 1 MB it is now 16 MB. Re-select it in"
            echo "    the OSD if that was not what you wanted." ;;
    esac
else
    echo "no $CFG, and none needed: with the rotated OSD lists a missing file IS the"
    echo "  default - entry 0 is 16 MB of RAM."
fi

# The pack is listed last: the core holds the CPU in reset until it has downloaded, so the disks
# must already be mounted when the BIOS starts. delay="1" for the pack (was 4) boots fine on the
# MiSTer (2026-10-09) and reaches the BIOS ~3 s sooner.
for m in $MACHINES; do
    MGL=$(mgl_for "$m")
    PACK=$(pack_name "$m")
    echo "writing MGL ($m) -> $MGL"
    $SSHP ssh $SSHO $HOST "cat > $MGL <<'XML'
<mistergamedescription>
	<rbf>_Computer/$CORE</rbf>
	<setname>$SETNAME</setname>
$IMG_LINE
$HDD2_LINE
$FDD_LINE0
$FDD_LINE1
	<file delay=\"1\" type=\"f\" index=\"0\" path=\"$PACK\"/>
</mistergamedescription>
XML
cat $MGL"
done

LOAD_MGL=$(mgl_for "$machine")
echo "load_core via /dev/MiSTer_cmd ($LOAD_MGL)"
$SSHP ssh $SSHO $HOST "echo 'load_core $LOAD_MGL' > /dev/MiSTer_cmd && echo command_sent"
