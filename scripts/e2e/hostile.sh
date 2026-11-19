#!/bin/zsh
# Feeds the installed app hostile copies and reports memory and what was stored.
# Uses a throwaway history. Overwrites the clipboard, restoring plain text at the end.
set -uo pipefail

here=${0:A:h}
work=$(mktemp -d)
sdk=$(xcrun --sdk macosx --show-sdk-path)
db="$work/data/history.sqlite"
saved=$(pbpaste; print -n x); saved=${saved%x}

cleanup() {
    pkill -x SmartClipboard 2>/dev/null
    [[ -n "$saved" ]] && print -rn -- "$saved" | pbcopy
    rm -rf "$work"
}
trap cleanup EXIT

swiftc -O -sdk "$sdk" "$here/poke.swift" -o "$work/poke" 2>&1 | grep -E 'error'
image=${1:-}
[[ -z "$image" ]] && { echo "usage: hostile.sh <large.png>"; exit 2; }

pkill -x SmartClipboard 2>/dev/null
sleep 0.5
open -n /Applications/SmartClipboard.app --args --data-dir "$work/data"
sleep 2.5
pid=$(pgrep -x SmartClipboard | head -1)

mem() {
    footprint "$pid" 2>/dev/null | sed -n '2p' | sed -E 's/.*Footprint: ([0-9.]+ [KMG]B).*/\1/'
}
peak() {
    footprint "$pid" 2>/dev/null | grep -E 'phys_footprint_peak' | sed -E 's/.*: *//'
}
count() {
    /usr/bin/sqlite3 "file:$db?mode=ro" "select count(*) from items$1" 2>/dev/null
}

echo "baseline            footprint=$(mem) peak=$(peak)"

"$work/poke" image "$image"
sleep 2
echo "image $(( $(stat -f %z "$image") / 1048576 )) MiB        footprint=$(mem) peak=$(peak) items=$(count '') thumbs=$(/usr/bin/sqlite3 "file:$db?mode=ro" "select count(*) from thumbs")"

cp "$image" "$work/varied.png"
for round in 1 2 3 4 5 6 7 8 9 10; do
    # A trailing byte makes each copy distinct, so none is treated as a repeat.
    print -n "$round" >> "$work/varied.png"
    "$work/poke" image "$work/varied.png"
    sleep 1
done
sleep 1
echo "10 more images      footprint=$(mem) peak=$(peak) items=$(count '')"

head -c 1073741824 /dev/zero | tr '\0' 'a' | pbcopy
sleep 6
echo "1 GiB text          footprint=$(mem) peak=$(peak) items=$(count '') (over the 64 MiB cap, must not be stored)"

"$work/poke" concealed "hunter2-do-not-store"
sleep 1.5
stored=$(/usr/bin/sqlite3 "file:$db?mode=ro" "select count(*) from search where raw like '%hunter2%'")
echo "concealed copy      stored=$stored (must be 0)"

mkdir "$work/files"; touch "$work/files/one.txt" "$work/files/two.txt"
"$work/poke" files "$work/files/one.txt" "$work/files/two.txt"
sleep 1.5
echo "two files           file items=$(count ' where kind=2') reps=$(/usr/bin/sqlite3 "file:$db?mode=ro" "select count(*) from reps where uti='public.file-url'")"

print -n "142999" | pbcopy
sleep 1.5
echo "hex color           color=$(/usr/bin/sqlite3 "file:$db?mode=ro" "select printf('%08X', color) from items where title='142999'") (must be 142999FF)"

print -n "same text" | pbcopy
sleep 1
print -n "other" | pbcopy
sleep 1
print -n "same text" | pbcopy
sleep 1.5
echo "repeat copy         copies=$(/usr/bin/sqlite3 "file:$db?mode=ro" "select copy_count from items where title='same text'") rows=$(count " where title='same text'") (must be 2 and 1)"

"$work/poke" slow 4 &
sleep 2
alive=$(ps -o state= -p "$pid" | tr -d ' ')
print -n "after slow provider" | pbcopy
sleep 4
echo "slow provider       state=$alive next copy stored=$(count " where title='after slow provider'") (must be 1)"
wait %2 2>/dev/null

sleep 2
echo "settled             footprint=$(mem) peak=$(peak)"
echo "disk                $(du -sh "$work/data" | cut -f1)"
