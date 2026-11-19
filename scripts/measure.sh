#!/bin/zsh
# Measures the installed app against throwaway histories, without touching the
# real one. Usage: scripts/measure.sh [rows ...]   Quit SmartClipboard first.
set -uo pipefail

root=${0:A:h:h}
sizes=("$@")
(( ${#sizes} == 0 )) && sizes=(1000 10000 100000)
work=$(mktemp -d)
trap 'pkill -x SmartClipboard 2>/dev/null; rm -rf "$work"' EXIT

footprint_mb() {
    footprint "$1" 2>/dev/null | sed -n '2p' | sed -E 's/.*Footprint: ([0-9.]+ [KMG]B).*/\1/'
}

for rows in $sizes; do
    data="$work/$rows"
    "$root/.build/release/clipbench" --seed "$data" "$rows" >/dev/null
    open -n /Applications/SmartClipboard.app --args --data-dir "$data"
    # Past the 10,000 item cap the app first purges down to it, which takes a while.
    sleep $(( rows > 10000 ? 25 : 5 ))
    pid=$(pgrep -x SmartClipboard | head -1)
    idle=$(footprint_mb $pid)
    peak=$(footprint "$pid" 2>/dev/null | grep -E 'phys_footprint_peak' | sed -E 's/.*: *//')
    cpu=$(top -l 2 -s 1 -pid $pid -stats cpu 2>/dev/null | tail -1 | tr -d ' ')
    pkill -x SmartClipboard
    sleep 0.5
    echo "rows=$rows  idle=$idle  peak=$peak  cpu=${cpu}%"
done
