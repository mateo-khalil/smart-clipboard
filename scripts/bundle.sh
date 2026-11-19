#!/bin/zsh
# Builds SmartClipboard.app and signs it.
#   --install   replaces the copy in /Applications
#   --release   builds for distribution: universal, hardened runtime, secure timestamp
#
# The signature must stay stable: macOS ties the Accessibility permission to it,
# so an ad-hoc build would lose that permission on every rebuild.
set -euo pipefail

root=${0:A:h:h}
cd "$root"

bundle_id="com.mateoduran.smartclipboard"
version="1.1.0"
# Default: the keychain's only "Apple Development" certificate, resolved to its hash.
development_identity() {
    local hashes=($(security find-identity -v -p codesigning | awk '/"Apple Development:/ { print $2 }'))
    if (( ${#hashes} > 1 )); then
        print -u2 "Several Apple Development certificates in the keychain; pick one with SIGN_IDENTITY."
        exit 1
    fi
    print -r -- "${hashes[1]:--}"
}
identity=${SIGN_IDENTITY:-}
out="$root/build/SmartClipboard.app"
export SDKROOT=$(xcrun --sdk macosx --show-sdk-path)

install=false
build_flags=()
sign_flags=(--timestamp=none)
for argument in "$@"; do
    case $argument in
        --install) install=true ;;
        --release)
            identity=${SIGN_IDENTITY:-"Developer ID Application"}
            build_flags=(--arch arm64 --arch x86_64)
            sign_flags=(--options runtime --timestamp)
            ;;
        *) print -u2 "unknown option: $argument"; exit 2 ;;
    esac
done

[[ -n $identity ]] || identity=$(development_identity)

# Without a certificate the app is signed ad hoc. It works, but macOS asks for
# Accessibility again after every rebuild.
if [[ $identity == "-" ]]; then
    print -u2 "warning: no Apple Development certificate in the keychain; signing ad hoc."
    print -u2 "         Create one in Xcode > Settings > Accounts to keep the Accessibility permission across builds."
fi

swift build -c release --product SmartClipboard $build_flags
swift build -c release --product cliphelper $build_flags
products=$(swift build -c release $build_flags --show-bin-path)

if [[ ! -f "$root/Resources/AppIcon.icns" ]]; then
    iconset=$(mktemp -d)/AppIcon.iconset
    swift scripts/make-icon.swift "$iconset"
    mkdir -p "$root/Resources"
    iconutil -c icns -o "$root/Resources/AppIcon.icns" "$iconset"
fi

rm -rf "$out"
mkdir -p "$out/Contents/MacOS" "$out/Contents/Resources"
cp "$products/SmartClipboard" "$out/Contents/MacOS/SmartClipboard"
cp "$products/cliphelper" "$out/Contents/MacOS/cliphelper"
cp "$root/Resources/AppIcon.icns" "$out/Contents/Resources/AppIcon.icns"
cat > "$out/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$bundle_id</string>
    <key>CFBundleName</key><string>SmartClipboard</string>
    <key>CFBundleDisplayName</key><string>SmartClipboard</string>
    <key>CFBundleExecutable</key><string>SmartClipboard</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Mateo Duran</string>
</dict>
</plist>
PLIST

# Inner binaries first: the outer signature seals them.
codesign --force --sign "$identity" $sign_flags "$out/Contents/MacOS/cliphelper"
codesign --force --sign "$identity" $sign_flags "$out"
codesign --verify --strict "$out"
echo "built $out ($(du -sh "$out" | cut -f1), binary $(stat -f %z "$out/Contents/MacOS/SmartClipboard") bytes)"

if $install; then
    pkill -x SmartClipboard 2>/dev/null || true
    rm -rf /Applications/SmartClipboard.app
    cp -R "$out" /Applications/SmartClipboard.app
    codesign --verify --strict /Applications/SmartClipboard.app
    echo "installed /Applications/SmartClipboard.app"
fi
