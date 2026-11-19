#!/bin/zsh
# End-to-end test with real key and mouse events. Keep hands off for about 40 s.
# `run.sh slow` runs only the blocked-read check, which takes about 10 s.
# Builds a -DE2E copy signed like the real app, so it inherits the Accessibility
# permission, and uses a throwaway history. Overwrites the clipboard.
set -uo pipefail

root=${0:A:h:h:h}
here=${0:A:h}
cd "$root"
identity=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/"Apple Development:/ { print $2; exit }')}
[[ -n $identity ]] || { print -u2 "No Apple Development certificate; set SIGN_IDENTITY."; exit 1; }
export SDKROOT=$(xcrun --sdk macosx --show-sdk-path)
work=$(mktemp -d)
app="$root/build/e2e/SmartClipboard.app"
saved=$(pbpaste; print -n x); saved=${saved%x}

cleanup() {
    pkill -f "$work/target" 2>/dev/null
    [[ -n "$saved" ]] && print -rn -- "$saved" | pbcopy
    rm -rf "$work" "$root/build/e2e"
}
trap cleanup EXIT

swift build -c release --product SmartClipboard --build-path .build/e2e -Xswiftc -DE2E 2>&1 | grep -E 'error:|Compiling SmartClipboard|Build complete' | tail -1
swift build -c release --product cliphelper --build-path .build/e2e 2>&1 | grep -E 'error:'
swiftc -O -sdk "$SDKROOT" "$here/target.swift" -o "$work/target" 2>&1 | grep error
swiftc -O -sdk "$SDKROOT" "$here/poke.swift" -o "$work/poke" 2>&1 | grep error

mkdir -p "$app/Contents/MacOS"
cp .build/e2e/release/SmartClipboard .build/e2e/release/cliphelper "$app/Contents/MacOS/"
cp /Applications/SmartClipboard.app/Contents/Info.plist "$app/Contents/Info.plist"
codesign --force --sign "$identity" --timestamp=none "$app/Contents/MacOS/cliphelper"
codesign --force --sign "$identity" --timestamp=none "$app"

pkill -x SmartClipboard 2>/dev/null
sleep 0.5
"$work/target" "$work/pasted.txt" &
sleep 1.5
# Through LaunchServices, as in real use: from a shell, macOS would attribute
# the Accessibility check to the terminal instead of this app.
open -W -n "$app" --args --data-dir "$work/data" --e2e "$work/pasted.txt" "$work/report.txt" "$work/poke" ${1:-}
sleep 0.5
cat "$work/report.txt" 2>/dev/null || echo "no report written"
