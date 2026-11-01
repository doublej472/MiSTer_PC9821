# Testing on a real MiSTer

Everything below is done over ssh; no physical access is needed. The MiSTer is a DE10-Nano
running Main_MiSTer; its SD card is `/media/fat`.

## Hardware regression

A change to anything the guest can see also passes the scripted hardware regression on a real
MiSTer: `tools/mister_regress.py --go` runs the item set and checks each item's screenshots are not
frozen and reach a known frame. The items are `keymap`, `probe`, `probe-cda`, the game items
`doom`, `th05`, `rusty`, `policenauts`, `flamezap`, and `cpusuite` (the z486 test programs from
DOS). It deploys a test RBF under `zreg` names, boots a patched COPY of a disk image, and cleans
up after itself; the item definitions, pass checks and every input are in "The scripted
regression runner" below.

## Connecting

Every MiSTer tool takes the device from the environment:

- `MISTER_HOST` - the ssh destination, default `root@MiSTer` (a bare host name gets `root@`);
  `tools/mister_regress.py` also takes `--host`.
- Authentication defaults to the stock MiSTer root password, `1`, passed through `sshpass -e`
  (install `sshpass`). Set `MISTER_PASS` for a different password, or `MISTER_PASS=` (empty) to
  use ssh keys; `tools/mister_regress.py` also takes `--password`.
- Copy files by hand with `scp -O`: the card's sshd has no sftp subsystem, and a modern `scp`
  defaults to sftp.

## Deploying and loading a core

- `tools/mister_load.sh` provisions the card and loads the core: it copies
  `output_files/z486_mister.rbf` to `/media/fat/_Computer/PC9821Z486.rbf`, verifies the local pack
  against your dumps (`PC98_DUMPS`) and uploads it to `/media/fat/games/PC9821/`, writes the MGL
  (`/media/fat/PC9821Z486.mgl`), optionally uploads a disk image (`MISTER_IMG`, mounted as
  `hdd.img`) and floppies (`--fdd0`/`--fdd1`), then loads it. Flags: `--both`/`--machine xe`
  (firmware set), `--packs-only`, `--no-copy` (reload the installed core), `--no-image`, `--pack`,
  `--dumps DIR`, `--skip-pack-check`, `--allow-stale-pack`, `--allow-marginal-hdmi` (deploy an
  RBF whose recorded `pll_hdmi` margin is below the -0.35 ns floor); `MISTER_CORE` renames the
  deployed core (use it for test builds).
- **It deletes nothing unless asked.** Other `_Computer/PC9821*.rbf` cores and `PC9821*.mgl` files
  it does not write are listed and kept; `--clean-stale` deletes them (on your own card only: a
  shared card holds the owner's main core, its backups and the owner's MGLs).
- **A test core touches only test files.** With a `MISTER_CORE` containing `zreg`
  (`MISTER_CORE=PC9821Z486-zreg`), everything it writes or deletes is zreg-named: the RBF and the
  MGL are named after the core, the disk image and floppies must be zreg-named copies
  (`MISTER_IMG=.../<name>-zreg.img`, or `--no-image`; the card's `hdd.img` is never mounted), the
  pack already on the card is used read-only (`--pack` is refused), the Scripts-menu converter is
  not copied, and `--clean-stale` considers only zreg-named cores and MGLs. It takes no card lock:
  take `/tmp/zreg.lock` yourself (as the regression runner does) and delete the zreg files when
  done.
- `tools/deploy_mister.sh` (`make deploy`) stages the same set into `mister_deploy/` for a manual
  copy, without a connection. `tools/mister_packs.sh` lists, stashes and switches the pack files
  already on the card.
- The MGL's setname is `PC9821`: relative paths in it resolve under `/media/fat/games/PC9821/`,
  and the core's config file is `/media/fat/config/PC9821.CFG` (`tools/check_mister_layout.py`
  holds these names together).
- **Load the MGL, not the RBF:** the MGL carries the disk and the pack. The remote-control path is
  the FIFO Main_MiSTer creates:

  ```
  ssh "$MISTER_HOST" 'echo "load_core /media/fat/PC9821Z486.mgl" > /dev/MiSTer_cmd'
  ```

  `tools/run_on_mister.sh load` does the same; `tools/run_on_mister.sh state` shows what the card
  runs and holds.
- `output_files/` is a copy destination, not a source of truth: confirm the RBF you deploy is the
  one you built (`tools/run_on_mister.sh state` prints the local RBF's sha256, the tree and RTL
  hash recorded in `fit-source.sha256` beside it, and the card's copy's sha256).

## Screenshots

```
ssh "$MISTER_HOST" 'echo screenshot > /dev/MiSTer_cmd'
```

writes the core's 640x400 frame (no OSD) as a PNG under `/media/fat/screenshots/PC9821/`; fetch
it with `scp -O`. `tools/mister_capture.sh shots TAG COUNT SECS` takes COUNT screenshots SECS
apart into `.build/dbglog/TAG-shots/`, and `tools/contact_sheet.py` tiles them into one image.

**A screenshot reads the scaler, so "no screenshots" is a card-health signal before it is a
verdict on the core.** A fit whose framework `pll_hdmi` setup slack is badly negative (`other_setup`
in `metrics.json`; observed at -0.635 ns) can intermittently fail
the HDMI/scaler handshake on load and leave the card unable to screenshot *any* core, including the
stock Menu core, until it is rebooted - proving that a bad placement, not the guest, made headless
testing impossible. So when a run reports `only 0 screenshots came back`, reboot (or power-cycle,
if a reboot does not return the card), confirm a Menu-core screenshot works, and only then re-test;
a stuck `Main_MiSTer` scaler reads its header magic as anything but `01 01` (`scaler.cpp`). Select a
seed outside that band and hard-test the actual shipping bitstream: an unmodified, hardware-verified
`base` placement reaches mild values (e.g. -0.09 ns, -0.012 ns) and is fine, so do not reject every
negative `pll_hdmi` - the failing band seen is about -0.6 ns (merges that landed at -0.02..-0.23 ns
were not hardware-tested).

## Typing keys and clicking the mouse

The helpers in `tools/mister/` run ON the MiSTer and create a virtual input device through
`/dev/uinput` (Main_MiSTer forwards it to the core like a USB keyboard or mouse). Copy them to the
card (`scp -O tools/mister/ztype.py "$MISTER_HOST":/tmp/`) and run them there:

- `python3 /tmp/ztype.py [--layout us|jis] [--hold MS] [--gap MS] 'dir\n'` types a string as the
  PC-98 (JIS) keyboard types it: every symbol is sent on the key and shift state whose PC-98 BIOS key
  table entry is that symbol (`=` is shift+`-`, `*` is shift+`:`, `&` is shift+`6`, `_` is shift+the
  RO key). `--layout` names the core's OSD Keyboard setting (default `us`, the setting a card with no
  saved config runs); it decides the four layout keys: in `us`, `` ` `` sends `@`/`~`, `[` and `]` send
  `[{` and `]}`, and `\` is the YEN key; in `jis`, `[` sends `@`/`~`, `]` sends `[{`, the backslash
  key sends `]}` and KEY_YEN is the YEN key. `\n` is Enter, `~C` is Ctrl+C, `~U` `~D` `~L` `~R` are the
  arrow keys, `~E` is Esc, `~k<code>;` sends one raw Linux key code (`~k28;` = Enter), `~s<code>;` the
  same with Shift held, and `~w<ms>;` waits. An unmapped character aborts with `unmapped: ...`.
  `--hold` is how long each key stays down (default 40 ms; held past 500 ms the core's typematic
  repeat starts), `--gap` the pause after each release. `--dry` prints the events, `--list` the
  character table, and `--selftest` re-derives every character of both layouts through Main_MiSTer's
  set-2 table, `pc9821_kbd.sv`'s translation and the BIOS table, and checks that the default is the
  OSD's position 0. On a card, arrows reached NEC DOS's line
  editor (Left, Up for history) and a game menu at
  0, 5 and 40 ms holds. A game that drops input while it changes screens (a demo ending, a menu
  fading in) also drops keys sent in that window: wait for the screen first.
- `python3 /tmp/zclick.py [options] [dx dy]` optionally moves the mouse, then clicks. The bare
  relative form `dx dy` moves in ten steps of `dx//10, dy//10` (so `-114 -76` moves -120 -80),
  then left-clicks, as it always has. Options:
  - `--home`: first a large up-left move (2400 mickeys per axis in 40-mickey steps), so the guest's
    mouse driver clamps the cursor to the top-left corner of its range.
  - `--to X Y`: `--home`, then a move to the pixel `(X, Y)`: `X*SX, Y*SY` mickeys, split exactly
    into steps of at most 4 mickeys, 15 ms apart (small steps stay below a driver's acceleration
    threshold; the bus mouse latches at most +-127 per read).
  - `--scale SX SY`: mickeys per pixel for `--to` (default `1 1`). It depends on the guest's driver
    and the game's own settings: measure it per title with cursor probes (`--to` or a relative move
    with `--move-only`, then a screenshot).
  - `--move-only` (no click), `--right` (right button), `--double` (two clicks 150 ms apart),
    `--hold MS` (button hold, default 120), `--steps N` (the number of steps for the move).
  - `--dry` prints the event stream instead of opening `/dev/uinput`; `--selftest` checks the
    streams of a few command lines (both run anywhere, no device).

  The cursor position lives in the guest's driver, not in the uinput device, so each call may
  create a new device: `--home` gives every call a known starting point. Each call costs the 1.5 s
  wait below. `tools/mister_regress.py` passes a scenario `click` step's arguments through
  unchanged, so `["click", "--to", 320, 200]` works there too.

Two facts make them work at all: the MiSTer is 32-bit ARM, so `struct input_event` is
`@llHHi` (16 bytes) - a 64-bit timeval layout makes Main_MiSTer silently ignore every event - and
the first events after `UI_DEV_CREATE` are lost unless you wait about 1.5 s, which both helpers
do. There is no evdev module on the card; the ioctls are issued by hand.

## The debug UART

The core's debug UART is `/dev/ttyS1` on the HPS at 115200 8N1. It carries the `trace` profile's
telemetry or, in a `--dbg-*` build, the instrument records, while the OSD's UART mode is None (the
default): in MIDI the line is the MPU's, and in PPP, Console and Modem it idles, because a Linux
process reads it there. Use `tools/mister_capture.sh`, which
handles the traps (a second reader splits the stream; a cooked tty mangles binary bytes; a reader
must outlive the ssh session):

```
tools/mister_capture.sh start TAG      # kill stale readers by PID, set the tty raw, start capturing
tools/mister_capture.sh stop TAG       # stop it (PID verified) and report the size
tools/mister_capture.sh fetch TAG      # copy it to .build/dbglog/TAG.bin
tools/mister_capture.sh decode TAG --summary   # tools/decode_dbglog.py on the capture
tools/mister_capture.sh run TAG SECONDS        # start, wait, stop, fetch, decode
tools/mister_capture.sh status                 # who holds the tty; captures on the card
```

`tools/decode_dbglog.py CAPTURE` prints the records; `--summary`, `--bins`, `--hist`, `--trace`,
`--snoop-check` and `--gdcw OUT` select views. The CD log alone can also be read with
`tools/decode_cdlog.py`.

**The `trace` profile's telemetry** is line-based: a watchdog record per trigger plus `PRF` and
`GFX` counter lines, decoded by `tools/decode_telemetry.py` (record shapes held by
`tools/check_telemetry_contract.py`). `tools/run_on_mister.sh capture [s]`, `decode FILE` and
`boot [s]` (load, wait, capture, decode) wrap it. The byte before each watchdog record's LF says
which trigger fired, and it is the only reliable signal: `W` = a memory request is outstanding and
nothing has completed for 200 ms (the machine has stopped); `S` = no request at all for 200 ms
(halted or polling - check `T=`, `A=` and `EIP` before calling it wedged); `P` = the 2 s
heartbeat, which says nothing about progress on its own. Several fields are not what their
letters suggest; read them through the decoder. **`PRF`'s `MW` and `GFX`'s `DW` are
platform-cycle counts and are only meaningful at `CPU Speed = Full`**: the CPU's request is a
level that lasts the whole (throttled) CPU cycle, so both count disabled cycles too and scale
with the throttle ratio (`pc9821_perf_msg.sv`'s header states the rule and why it is documented
rather than re-based).

Never `pkill -f <pattern>` on the card or here: the pattern matches the shell running it. Kill by
PID.

## The scripted regression runner

`tools/mister_regress.py` deploys a test RBF under test names, boots a patched COPY of a disk
image, drives the guest by keyboard and mouse, takes screenshots, and deletes everything it
created.

- Without `--go` it prints the plan and touches nothing. With `--go` it takes a lock on the card
  (`mkdir /tmp/zreg.lock`, owner recorded in `/tmp/zreg.lock/owner`; an existing lock aborts the
  run and names its holder), uses only names containing `zreg` (`_Computer/PC9821Z486-zreg.rbf`,
  `/media/fat/ZREG.mgl`, `/tmp/zreg/`), and removes every file it created in a `finally`, verifying
  the removal. `--keep` skips the cleanup for debugging.
- Items (`--items`, comma-separated, default all): `keymap`, `probe` (runs `INTEG.COM` from
  `tools/hwprobe/integ` in the guest and checks HDD/floppy/CD files against manifests built on the
  host from the same images), `probe-cda` (the same while CD-DA plays; needs `--cd` and MSCDEX),
  and the game items `doom`, `th05`, `rusty`, `policenauts`, `flamezap` (EGC-heavy).
  `cpusuite` (~1.5 min with the boot) runs z486's own test programs from DOS (`tools/hwprobe/cpusuite`: the
  pack is generated from `src/z486/tests/programs`, the harness enters each program in the bench's
  start state and returns through the PC-98 CPU-reset path) and passes only if every packed program
  passes on every pass (`--cpusuite-passes N` loops the pack; `--cpusuite-timeout S`); it boots
  profile 0 (noemm) since the programs enter protected mode themselves. A CPU stress test for
  builds past timing closure; `gen_cpusuite.py --simcheck` proves the patched programs in the bench.
- Game items run the command list in `--scenarios FILE` (JSON; the shape is
  `tools/mister/regress_scenarios.example.json`: per item `boot_wait`, `steps` of
  `type`/`wait`/`click`/`key`, `run`, `shot_every`, `dense`, `max_static_s`, `min_changes`,
  `known_frame`, `config_default`). A step argument beginning with `?` marks a command not yet
  supplied: the item is skipped, never passed. Pass checks: the screen is not frozen (frame
  difference between consecutive screenshots) and a known frame is reached (difference to a
  reference PNG in `--refs DIR`: ANY shot taken inside the frame's `not_before_s`..`until_s`
  window may match; a `dense` window takes a shot every `every_s` seconds there, so a frame
  that lasts a second is caught whatever the launch jitter); `--record-refs` writes those
  references from a build known to work. Shot times come from the screenshots' own time
  stamps. Reference frames are game output and are never committed.
- The runner removes only what it made: test-named files, and the screenshots its own items
  caused (new files in `screenshots/PC9821/` named after the pack its MGL loads, stamped after
  the item began; Main_MiSTer names a screenshot `<date>_<time>-<last ROM file loaded>.png`).
  With `--uart` it kills only the `cat` reader whose PID it recorded when starting it.
- Inputs: `--rbf`, `--hdd-image` (with `--partition`, `--hdd-drive`, `--hdd-under`),
  `--fdd0`/`--fdd1`, `--cd` (`--cd-layout iso|pcd|raw`, `--cd-drive`), `--pack` (the pack already
  on the card), `--boot-wait`, `--probe-timeout`, `--uart` (capture `/dev/ttyS1` as well),
  `--out` (default `.build/mister-regress/<time>`). `--selftest` exercises the hardware-free logic.

## Game test sets

Every title in [`compatibility.md`](compatibility.md) belongs to the **extended test set**: it was run
on hardware and judged by eye from screenshots, and it is run again in an occasional sweep or when a
change touches what it exercises. A release validates on a **representative sample** of it instead
(the maintainer's standard since 2026-10-30): about 25 titles that cover every medium (hard disk, CD,
floppy), the mouse-driven and CD-audio titles, a 256-colour title, the titles a recent change could
affect, every open lead, and Windows 95. Every run keeps all of its screenshots, a contact sheet and
a thumbnail per title for review. A new title joins the extended set on its first run.

## Several MiSTers

Every tool takes its card from `MISTER_HOST` (or `--host`), password `MISTER_PASS` (default `1`,
empty = keys), uses no known_hosts state, and keeps its local scratch per card (`.build/mister/<host>/`
for `run_on_mister.sh`, `--out` per run for the regression runner), so two runs against two cards can
overlap. Fresh cards work: missing `games/PC9821`, `_Computer`, `config` and screenshots directories are
created or listed tolerantly. `tools/mister_regress.py --lock-wait S` waits for another run's card
lock; only the lock's holder ever cleans up. `tools/mister_multi.py --hosts a,b --mode split|repeat --
<regress args>` runs one regression on several cards at once (`split` deals the items out, `repeat`
runs every item on every card), one `--out` subdirectory per card and a combined `summary.txt`.

## Rules for testing on a MiSTer

- **Test on COPIES** of disk images, never the originals: deploy a test RBF under a new name
  (`MISTER_CORE=PC9821Z486-zreg`, a name containing `zreg`, which puts `tools/mister_load.sh` in
  test-core mode), boot a zreg-named copy of the image (`MISTER_IMG=.../<name>-zreg.img`), and
  let the guest write to the copy.
- **Clean up afterwards**: delete every test RBF, MGL, image copy and screenshot you created.
- **Restore any configuration you change** (the core's `PC9821.CFG`, the MGLs, the pack in use).
- A MiSTer is a shared device: use the regression runner's lock (or check for one) before driving
  it, and never leave a UART reader running.
- Attribute a hardware failure to timing margin only after a timing-met lower-clock build of the
  same source fails to reproduce it over several runs (a logic bug once passed for margin).
- **A wedged scaler is not a test result.** A badly negative framework `pll_hdmi` placement can
  leave the card unable to screenshot anything (any core, including Menu) until a reboot, so
  `only 0 screenshots came back` means "reboot and re-test", never "the core is black" - see
  Screenshots above. Prove a Menu screenshot works before trusting any screenshot verdict.
- **Look at the screenshots.** The runner's motion and known-frame checks cannot see ghosting,
  wrong colours, a missing layer or a timing difference; report a hardware result only after
  viewing the contact sheet and full-size key frames against the same shots of a known-good build.
- **Test on more than one board type.** Margin differs between DE10-Nano-class boards and SDRAM
  modules; a deploy candidate passes the load screen and the regression on every test card.
- **A change that flips a preset default** (a feature turned on in `base`) runs the full gate,
  including `check_lint`: the default build then compiles code the gates never saw.
- **Never edit a disk image you did not create** - not the originals, not the user's images on a
  card - and never change the card's `MiSTer.ini`; back up and restore `PC9821.CFG`.
