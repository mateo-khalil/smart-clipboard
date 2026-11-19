#!/bin/zsh
# Counts how many quick image copies survive, which is what a missed read loses.
# Usage: race.sh <large.png> [copies]. Overwrites the clipboard, then restores plain text.
set -uo pipefail

here=${0:A:h}
image=${1:?usage: race.sh <large.png> [copies]}
copies=${2:-60}
work=$(mktemp -d)
sdk=$(xcrun --sdk macosx --show-sdk-path)
saved=$(pbpaste; print -n x); saved=${saved%x}

cleanup() {
    pkill -x SmartClipboard 2>/dev/null
    [[ -n "$saved" ]] && print -rn -- "$saved" | pbcopy
    rm -rf "$work"
}
trap cleanup EXIT

swiftc -O -sdk "$sdk" "$here/poke.swift" -o "$work/poke" 2>&1 | grep error
pkill -x SmartClipboard 2>/dev/null
sleep 0.5
open -n /Applications/SmartClipboard.app --args --data-dir "$work/data"
sleep 2
pid=$(pgrep -x SmartClipboard | head -1)

cp "$image" "$work/varied.png"
for (( round = 1; round <= copies; round++ )); do
    print -n "$round" >> "$work/varied.png"
    "$work/poke" image "$work/varied.png"
    sleep 0.75
done
sleep 3
db="file:$work/data/history.sqlite?mode=ro"
echo "captured $(/usr/bin/sqlite3 "$db" "select count(*) from items") of $copies"
echo "with thumbnail $(/usr/bin/sqlite3 "$db" "select count(*) from thumbs")"
echo "footprint $(footprint $pid 2>/dev/null | sed -n '2p' | sed -E 's/.*Footprint: ([0-9.]+ [KMG]B).*/\1/')"
echo "leftover staging entries $(ls "$work/data/staging" | wc -l | tr -d ' ')"
