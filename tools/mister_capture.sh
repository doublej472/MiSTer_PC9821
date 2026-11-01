#!/usr/bin/env bash
# Capture the core's debug UART on the MiSTer, safely, and decode it.
#
# The debug-instrument framework (build_profile.py --dbg-*, --cdrom-log) writes its records to
# the debug UART, which is /dev/ttyS1 on the HPS at 115200 8N1 (docs/mister-testing.md "The
# debug UART"). Reading it is a plain `cat`, and every way of doing that carelessly has bitten:
#
#   * TWO READERS SPLIT THE STREAM - each gets alternate bytes and neither capture decodes. A reader
#     left over from an earlier run (the SSH session that started it dropped) is the usual cause, so
#     `start` finds every process holding the tty open (through /proc/<pid>/fd) and kills the stale
#     `cat`s BY PID, refusing to touch anything that is not a `cat`.
#   * `pkill -f cat /dev/ttyS1` MATCHES THE SHELL RUNNING IT (the pattern is in its own command
#     line) and ends the session. Nothing here uses pkill or pgrep -f.
#   * THE READER MUST OUTLIVE THE SSH SESSION: it is started with nohup, stdin/stdout/stderr
#     detached, and its PID is written to a pidfile that `stop` verifies (/proc/<pid>/fd must still
#     point at the tty) before it signals anything.
#   * A tty left in cooked mode turns 0x0D into 0x0A and eats XON/XOFF bytes, corrupting a binary
#     stream: `start` sets it raw and refuses to go on if that fails on a real tty.
#
# Usage:
#   tools/mister_capture.sh start  [TAG]            kill stale readers, set the tty raw, begin a capture
#   tools/mister_capture.sh stop   [TAG]            end it (verifies the PID), report the size
#   tools/mister_capture.sh fetch  [TAG] [DIR]      copy it to DIR (default .build/dbglog/TAG.bin)
#   tools/mister_capture.sh status                  who holds the tty, and the captures on the card
#   tools/mister_capture.sh decode [TAG] [ARGS...]  tools/decode_dbglog.py on the fetched capture
#   tools/mister_capture.sh run TAG SECONDS         start, wait, stop, fetch, decode --summary
#   tools/mister_capture.sh shots TAG COUNT SECS    COUNT screenshots, SECS apart, fetched into
#                                                   .build/dbglog/TAG-shots/ (then contact_sheet.py)
#   tools/mister_capture.sh --selftest              the whole start/stop/fetch cycle, locally
#
# TAG defaults to "cap". Environment: MISTER_HOST (ssh destination, default root@MiSTer; a bare
# host name gets root@), MISTER_PASS (default 1, the stock root password, through sshpass -e; empty = ssh keys;
# fetches use scp -O because the card's sshd has no sftp), MISTER_TTY (/dev/ttyS1),
# MISTER_TMP (/tmp, where the card keeps the capture and its pidfile), MISTER_SHOT_DIR
# (/media/fat/screenshots/PC9821). MISTER_CAPTURE_LOCAL=DIR runs the same remote script on THIS
# machine with DIR as the card's /tmp - the selftest, and a way to try a change without the card.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${MISTER_HOST:-root@MiSTer}"
case $HOST in *@*) ;; *) HOST=root@$HOST ;; esac
# Authentication: password "1" (the stock MiSTer root password) by default, through sshpass -e (it reads
# SSHPASS from the environment, so the password never appears on a command line).
SSHPASS_CMD=()
MISTER_PASS="${MISTER_PASS-1}"   # the stock MiSTer root password; MISTER_PASS= (empty) uses ssh keys
if [ -n "$MISTER_PASS" ]; then export SSHPASS="$MISTER_PASS"; SSHPASS_CMD=(sshpass -e); fi
TTY_DEV="${MISTER_TTY:-/dev/ttyS1}"
CARD_TMP="${MISTER_TMP:-/tmp}"
SHOT_DIR="${MISTER_SHOT_DIR:-/media/fat/screenshots/PC9821}"
LOCAL="${MISTER_CAPTURE_LOCAL:-}"
OUT_DIR="${DBGLOG_DIR:-$REPO/.build/dbglog}"

# The script that runs ON THE CARD (BusyBox sh): `sh -s -- ACTION TAG TTY TMPDIR`.
remote_body() {
cat <<'REMOTE'
act=$1; tag=$2; tty=$3; tmpd=$4
out=$tmpd/dbg-$tag.bin; pidf=$tmpd/dbg-$tag.pid
is_tty() { [ -c "$tty" ]; }
# every pid with the tty open, except this shell
holders() {
  for d in /proc/[0-9]*; do
    p=${d#/proc/}
    [ "$p" = "$$" ] && continue
    for fd in "$d"/fd/*; do
      if [ "$(readlink "$fd" 2>/dev/null)" = "$tty" ]; then echo "$p"; break; fi
    done
  done
}
comm_of() { cat "/proc/$1/comm" 2>/dev/null || echo "?"; }
alive() { [ -d "/proc/$1" ]; }
term() {  # TERM, then KILL if it is still there
  kill "$1" 2>/dev/null || return 0
  n=0; while alive "$1" && [ $n -lt 20 ]; do sleep 0.1; n=$((n+1)); done
  alive "$1" && kill -9 "$1" 2>/dev/null
  return 0
}
case $act in
start)
  for p in $(holders); do
    if [ "$(comm_of "$p")" = cat ]; then echo "killing stale reader pid $p (cat on $tty)"; term "$p"
    else echo "WARNING: pid $p ($(comm_of "$p")) holds $tty and is not a cat: left alone"; fi
  done
  if is_tty; then
    stty -F "$tty" 115200 raw -echo -hupcl || { echo "ERROR: could not set $tty raw 115200"; exit 1; }
  else
    echo "note: $tty is not a character device (a test?): no stty"
  fi
  : > "$out"
  nohup sh -c "exec cat '$tty' > '$out'" </dev/null >/dev/null 2>&1 &
  pid=$!
  echo "$pid" > "$pidf"
  sleep 1
  alive "$pid" || { echo "ERROR: the reader (pid $pid) is not running"; exit 1; }
  mine=$(for p in $(holders); do echo "$p"; done | tr '\n' ' ')
  case " $mine " in *" $pid "*) ;; *) echo "ERROR: pid $pid does not hold $tty"; exit 1;; esac
  echo "capturing $tty -> $out (pid $pid)" ;;
stop)
  [ -f "$pidf" ] || { echo "ERROR: no $pidf: nothing started under tag '$tag'"; exit 1; }
  pid=$(cat "$pidf")
  if alive "$pid" && [ "$(comm_of "$pid")" = cat ] && [ "$(readlink "/proc/$pid/fd/1" 2>/dev/null)" = "$out" ]; then
    term "$pid"; echo "stopped pid $pid"
  else
    echo "pid $pid is not our reader any more (exited, or the pid was reused): nothing signalled"
  fi
  rm -f "$pidf"
  echo "$out: $(wc -c < "$out") bytes" ;;
status)
  for p in $(holders); do echo "holder of $tty: pid $p ($(comm_of "$p"))"; done
  ls -l "$tmpd"/dbg-*.bin "$tmpd"/dbg-*.pid 2>/dev/null || echo "no captures under $tmpd" ;;
*) echo "unknown action $act"; exit 2 ;;
esac
REMOTE
}

SSH=("${SSHPASS_CMD[@]}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$HOST")
quiet() { grep -viE 'WARNING: (connection|post)|vulnerable|store now|upgraded|openssh.com/pq' || true; }

# run_remote ACTION TAG: the remote script, here or on the card
run_remote() {
  local act=$1 tag=$2
  if [ -n "$LOCAL" ]; then
    remote_body | sh -s -- "$act" "$tag" "$TTY_DEV" "$LOCAL" 9>&-
  else
    remote_body | "${SSH[@]}" sh -s -- "$act" "$tag" "$TTY_DEV" "$CARD_TMP" 2>&1 | quiet
  fi
}

# the card-side shell for a one-line command (screenshots)
card() { if [ -n "$LOCAL" ]; then sh -c "$1"; else "${SSH[@]}" "$1" 2>&1 | quiet; fi; }

fetch_file() {  # fetch_file REMOTE LOCAL
  if [ -n "$LOCAL" ]; then cp "$1" "$2"; else "${SSHPASS_CMD[@]}" scp -O -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$HOST:$1" "$2"; fi
}

cap_dir() { if [ -n "$LOCAL" ]; then echo "$LOCAL"; else echo "$CARD_TMP"; fi; }

cmd_fetch() {
  local tag=${1:-cap} dir=${2:-$OUT_DIR}
  mkdir -p "$dir"
  fetch_file "$(cap_dir)/dbg-$tag.bin" "$dir/$tag.bin"
  echo "fetched $dir/$tag.bin ($(wc -c < "$dir/$tag.bin") bytes)"
}

cmd_decode() {
  local tag=${1:-cap}; shift || true
  python3 "$REPO/tools/decode_dbglog.py" "$OUT_DIR/$tag.bin" "$@"
}

cmd_shots() {
  local tag=$1 count=$2 secs=$3 dest="$OUT_DIR/$tag-shots" before after i
  mkdir -p "$dest"
  before="$(card "ls '$SHOT_DIR' 2>/dev/null" || true)"
  for i in $(seq 1 "$count"); do
    card "echo screenshot > /dev/MiSTer_cmd" >/dev/null
    sleep "$secs"
  done
  sleep 2
  after="$(card "ls '$SHOT_DIR' 2>/dev/null" || true)"
  comm -13 <(echo "$before" | sort) <(echo "$after" | sort) | while read -r f; do
    [ -n "$f" ] && fetch_file "$SHOT_DIR/$f" "$dest/$f"
  done
  echo "screenshots in $dest: $(ls "$dest" | wc -l)  (python3 tools/contact_sheet.py $dest)"
}

selftest() {
  local d fifo got
  mkdir -p "$REPO/.build"; d="$(mktemp -d "$REPO/.build/mister-capture-selftest.XXXXXX")"
  fifo="$d/ttyS1"; mkfifo "$fifo"
  exec 9<>"$fifo"      # keep the FIFO open so a reader's open() does not block, as a tty's never does
  export MISTER_CAPTURE_LOCAL="$d" MISTER_TTY="$fifo" DBGLOG_DIR="$d/out"
  LOCAL="$d"; TTY_DEV="$fifo"; OUT_DIR="$d/out"
  # a stale reader of the same tty: start must kill it, and only it
  nohup sh -c "exec cat '$fifo' > '$d/stale.bin'" </dev/null >/dev/null 2>&1 &
  local stale=$!
  sleep 0.5
  # something that is NOT a cat holds the tty too: it must be left alone
  nohup sh -c "exec sleep 30 < '$fifo'" </dev/null >/dev/null 2>&1 &
  local bystander=$!
  sleep 0.5
  run_remote start t1 | sed 's/^/  /'
  kill -0 "$stale" 2>/dev/null && { echo "SELFTEST FAIL: the stale reader survived start"; kill "$stale" "$bystander" 2>/dev/null; exit 1; }
  kill -0 "$bystander" 2>/dev/null || { echo "SELFTEST FAIL: start killed a process that is not a cat"; exit 1; }
  kill "$bystander" 2>/dev/null || true
  # feed it a stream with every byte value, then stop
  python3 -c "import sys; sys.stdout.buffer.write(bytes(range(256))*4 + b'\xa5\x1f\x00\x01\x00\x00\x5a')" > "$d/feed.bin"
  (cat "$d/feed.bin" > "$fifo") &
  sleep 1
  run_remote stop t1 | sed 's/^/  /'
  cmd_fetch t1 "$d/out" >/dev/null
  cmp -s "$d/feed.bin" "$d/out/t1.bin" || { echo "SELFTEST FAIL: the fetched capture is not what was fed ($(wc -c < "$d/out/t1.bin") bytes)"; exit 1; }
  [ ! -f "$d/dbg-t1.pid" ] || { echo "SELFTEST FAIL: the pidfile survived stop"; exit 1; }
  # stop with a pid that is no longer our reader signals nothing
  echo 1 > "$d/dbg-t2.pid"; : > "$d/dbg-t2.bin"
  got="$(run_remote stop t2)"
  case "$got" in *"nothing signalled"*) ;; *) echo "SELFTEST FAIL: stop signalled a pid that is not the reader: $got"; exit 1;; esac
  python3 "$REPO/tools/decode_dbglog.py" "$d/out/t1.bin" --summary | head -1 | grep -q "^1 records" || { echo "SELFTEST FAIL: the capture does not decode"; exit 1; }
  exec 9>&-
  rm -rf "$d"
  echo "mister_capture.sh --selftest: PASS (stale cat killed, bystander left, every byte value round-tripped, stop verified the pid)"
}

case "${1:-}" in
  start)  run_remote start "${2:-cap}" ;;
  stop)   run_remote stop "${2:-cap}" ;;
  status) run_remote status "${2:-cap}" ;;
  fetch)  cmd_fetch "${2:-cap}" "${3:-$OUT_DIR}" ;;
  decode) shift; cmd_decode "$@" ;;
  shots)  [ $# -eq 4 ] || { sed -n '2,32p' "$0"; exit 2; }; cmd_shots "$2" "$3" "$4" ;;
  run)    [ $# -eq 3 ] || { sed -n '2,32p' "$0"; exit 2; }
          run_remote start "$2"; sleep "$3"; run_remote stop "$2"; cmd_fetch "$2"; cmd_decode "$2" --summary ;;
  --selftest) selftest ;;
  *)      sed -n '2,32p' "$0"; exit 2 ;;
esac
