#!/bin/zsh
# Builds the notarized DMG that anyone can install.
# Usage: scripts/release.sh [--dry-run] [destination]   (default destination: the Desktop)
#
# One-time setup on each Mac is in the README, under "Distribuir".
#
# --dry-run stops before notarizing and leaves the DMG in build/. It accepts any
# local certificate through SIGN_IDENTITY, so it checks the packaging but produces
# nothing that can be shipped.
set -euo pipefail

root=${0:A:h:h}
cd "$root"

profile=${NOTARY_PROFILE:-smartclipboard}
dry_run=false
if [[ "${1:-}" == "--dry-run" ]]; then
    dry_run=true
    shift
fi
destination=${1:-$HOME/Desktop}

# Resolved to a hash: codesign refuses a name that matches two certificates.
identity=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/"Developer ID Application/ && !hash { hash = $2 } END { print hash }')}
if [[ -z $identity ]]; then
    print -u2 "No Developer ID Application certificate in the keychain."
    print -u2 "Create it in Xcode > Settings > Accounts > Manage Certificates."
    exit 1
fi
if ! $dry_run && ! xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1; then
    print -u2 "No notarization credentials in the profile \"$profile\". Run:"
    print -u2 "  xcrun notarytool store-credentials $profile --apple-id <apple id> --team-id <team id>"
    exit 1
fi

SIGN_IDENTITY=$identity scripts/bundle.sh --release

app="$root/build/SmartClipboard.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
dmg="$root/build/SmartClipboard-$version.dmg"

work=$(mktemp -d)
mount="$work/mount"
trap '[[ -d "$mount" ]] && hdiutil detach -quiet "$mount" 2>/dev/null; rm -rf "$work"' EXIT

mkdir "$work/image"
ditto "$app" "$work/image/SmartClipboard.app"
ln -s /Applications "$work/image/Applications"
rm -f "$dmg"
hdiutil create -quiet -volname SmartClipboard -srcfolder "$work/image" -format UDZO "$dmg"
codesign --force --sign "$identity" --timestamp "$dmg"
codesign --verify --strict "$dmg"

if $dry_run; then
    echo "dry run: $dmg (not notarized, do not distribute)"
    exit 0
fi

# notarytool can exit 0 for a rejected submission, so the verdict is read from its report.
xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait --output-format json > "$work/notary.json" || true
verdict=$(plutil -extract status raw -o - "$work/notary.json" 2>/dev/null || echo "no response")
if [[ $verdict != Accepted ]]; then
    submission=$(plutil -extract id raw -o - "$work/notary.json" 2>/dev/null || true)
    [[ -n $submission ]] && xcrun notarytool log "$submission" --keychain-profile "$profile"
    print -u2 "Notarization failed: $verdict"
    exit 1
fi

xcrun stapler staple -q "$dmg"
xcrun stapler validate -q "$dmg"

# The same checks Gatekeeper runs on a downloaded copy, on the image and on the app inside it.
spctl --assess --type open --context context:primary-signature "$dmg"
mkdir "$mount"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mount" "$dmg"
spctl --assess --type execute "$mount/SmartClipboard.app"
hdiutil detach -quiet "$mount"
rmdir "$mount"

mkdir -p "$destination"
ditto "$dmg" "$destination/${dmg:t}"
echo "ready: $destination/${dmg:t}"
shasum -a 256 "$destination/${dmg:t}"
