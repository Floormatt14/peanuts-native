#!/bin/sh
# A soak of a running game on the phone (android/TESTING.md "A soak"): sends camera moves and nothing else (no A, so a save's story does not advance), then says whether
# the same process stayed alive, kept presenting, and logged no new [RED] line. Every guard here came from a soak or a monitor pass that lied:
#   - a spin with no log growth and no [RED] passes a liveness-only test (Pokemon Violet sat at 96 % on one thread for 7 minutes that way): progress is frames, sampled
#     once a minute, and two samples without a new frame fail the soak;
#   - a game on a sleeping phone or behind another window soaks as "paused" (a 112 s init stall that was really focus): the app must be in the foreground to start;
#   - a process the framework killed looks like a clean exit: on failure, logcat says who ended it;
#   - a phone without free space truncates its log, which looks like a stall: the floor is checked before and after;
#   - a pass that cannot measure must not report success: exit 2, not 0 (no adb, no device, no log, not in the foreground).
#   nxsoak.sh [minutes] [title id]     minutes default 30; the title id names the log to watch (default: the newest)
# Exit: 0 clean, 1 measured failure (restart, new [RED], no progress, out of space), 2 could not tell. NX_SERIAL and NX_PKG as for nxctl.sh.
set -eu
PKG=${NX_PKG:-dev.nxnative.android}
FILES=/sdcard/Android/data/$PKG/files
A="adb${NX_SERIAL:+ -s $NX_SERIAL}"
minutes=${1:-30}
id=${2:-}
case $minutes in ''|*[!0-9]*) sed -n '2,13p' "$0"; exit 2;; esac
[ "$minutes" -ge 1 ] || { sed -n '2,13p' "$0"; exit 2; }
FLOOR_KB=1048576   # 1 GiB free on /sdcard, below which a log or a pack write can be cut short

newest_log() { $A shell "ls -t $FILES/logs/$id*.log 2>/dev/null | head -1" | tr -d '\r'; }
pid_of() { $A shell "pidof $PKG:game" 2>/dev/null | tr -d '\r '; }
frame_of() { $A shell "grep -a -o 'frame [0-9]*' '$1' 2>/dev/null | tail -1" | tr -d '\r' | tr -dc '0-9'; }
size_of() { $A shell "wc -c < '$1' 2>/dev/null" | tr -d '\r '; }
reds_of() { $A shell "grep -a -c '\[RED\]' '$1' 2>/dev/null" | tr -d '\r '; }
free_kb() { $A shell "df -k /sdcard 2>/dev/null | tail -1" | tr -d '\r' | awk '{print $4}'; }
focused() { $A shell "dumpsys window 2>/dev/null | grep -aE 'mCurrentFocus|mFocusedApp' | grep -c '$PKG'" | tr -d '\r '; }
ctl() { $A shell "f=$FILES/ctl.txt; echo '$1' >> \$f; chmod 666 \$f 2>/dev/null; true"; }
who_ended_it() {   # the framework's own record of a death, which the host's log cannot show
    $A shell "logcat -d -b all 2>/dev/null | grep -aE 'am_proc_died|am_kill|has died: fg|lowmemory|Watchdog' | tail -5" | tr -d '\r' >&2
}

# Could we measure at all? Exit 2, never 0, when we could not
$A shell true >/dev/null 2>&1 || { echo "no adb or no device ($A)" >&2; exit 2; }
LOG=$(newest_log)
[ -n "$LOG" ] || { echo "no log in $FILES/logs: nothing to measure" >&2; exit 2; }
PID=$(pid_of)
[ -n "$PID" ] || { echo "the game ($PKG:game) is not running: this soaks a run, it does not start one" >&2; exit 2; }
[ "$(focused)" -ge 1 ] || { echo "$PKG is not in the foreground: a soak of a paused game measures nothing (wake the phone, open the game)" >&2; exit 2; }
free0=$(free_kb)
[ -n "$free0" ] || { echo "could not read free space on /sdcard" >&2; exit 2; }
[ "$free0" -ge "$FLOOR_KB" ] || { echo "only $((free0 / 1024)) MiB free on the phone (needs $((FLOOR_KB / 1024)) MiB): a log or a pack write would be cut short" >&2; exit 2; }

reds0=$(reds_of "$LOG"); reds0=${reds0:-0}
frame0=$(frame_of "$LOG")
echo "soak: $minutes min, $PKG:game pid $PID, log $(basename "$LOG"), starting at frame ${frame0:-0}, $reds0 [RED] lines behind it, $((free0 / 1024)) MiB free"

n=0; total=$((minutes * 60)); verdict=OK; stalled=0; minute_frame=${frame0:-0}
while [ "$n" -lt "$total" ]; do
    # Camera moves only: a stick held for a moment, the direction cycling. Nothing that presses A, so the game's story stays where it is.
    case $((n / 10 % 4)) in
    0) ctl 'RLeft~0.35';; 1) ctl 'RDown~0.35';; 2) ctl 'RRight~0.35';; 3) ctl 'RUp~0.35';;
    esac
    sleep 5; n=$((n + 5))
    now=$(pid_of)
    if [ -z "$now" ]; then verdict="FAILED: the game stopped after $((n / 60)) min ${n}s (pid $PID gone)"; break; fi
    if [ "$now" != "$PID" ]; then verdict="FAILED: the game restarted after $((n / 60)) min ${n}s (pid $PID -> $now: a crash or a player left)"; break; fi
    if [ "$(newest_log)" != "$LOG" ]; then verdict="FAILED: a new log appeared after $((n / 60)) min ${n}s (the app restarted the game)"; break; fi
    frame=$(frame_of "$LOG"); frame=${frame:-0}; size=$(size_of "$LOG"); size=${size:-0}
    if [ $((n % 60)) -eq 0 ]; then
        [ "$frame" -gt "$minute_frame" ] && stalled=0 || stalled=$((stalled + 1))
        minute_frame=$frame
        reds=$(reds_of "$LOG"); reds=${reds:-0}
        printf '%s min: frame %s, log %s B, %s new [RED], %s MiB free\n' "$((n / 60))" "$frame" "$size" "$((reds - reds0))" "$(($(free_kb) / 1024))"
        if [ "$reds" -gt "$reds0" ]; then verdict="FAILED: $((reds - reds0)) new [RED] line(s)"; break; fi
        # Two minutes with no new frame is a spin, not a slow scene: a scene keeps presenting, it just costs more
        if [ "$stalled" -ge 2 ]; then verdict="FAILED: no new frame for $stalled min (frame $frame, log $size B, no [RED]: a spin in the game or the replay)"; break; fi
        if [ "$(free_kb)" -lt "$FLOOR_KB" ]; then verdict="FAILED: the phone ran out of space during the soak ($(($(free_kb) / 1024)) MiB free)"; break; fi
    fi
done
# A red line, a stopped frame or a full disk in the last seconds counts too
reds=$(reds_of "$LOG"); reds=${reds:-0}
frame1=$(frame_of "$LOG"); frame1=${frame1:-0}
[ "$verdict" = OK ] && [ "$reds" -gt "$reds0" ] && verdict="FAILED: $((reds - reds0)) new [RED] line(s)"
[ "$verdict" = OK ] && [ "$frame1" -le "${frame0:-0}" ] && verdict="FAILED: no frame advanced (the game never presented: frame $frame1)"
printf 'soak %s: %s min, pid %s %s, frames %s -> %s, %s new [RED]\n' \
    "$( [ "$verdict" = OK ] && echo OK || echo FAILED)" "$((n / 60))" "$PID" \
    "$( [ "$(pid_of)" = "$PID" ] && echo alive || echo gone)" "${frame0:-0}" "$frame1" "$((reds - reds0))"
if [ "$verdict" != OK ]; then
    echo "$verdict" >&2
    $A shell "grep -a '\[RED\]' '$LOG' | tail -5" | tr -d '\r' >&2
    who_ended_it
    exit 1
fi
exit 0
