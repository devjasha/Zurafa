#!/usr/bin/env bash
# Builds an ad-hoc signed local app bundle: the SwiftUI app plus zurafa-daemon next to it.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
variant="${ZURAFA_BUILD_VARIANT:-development}"
case "$variant" in
  development|dev|local)
    app_name="zurafa-development"
    executable_name="zurafa-development"
    bundle_identifier="app.zurafa.zurafa-development"
    app_support_name="ZurafaDevelopment"
    offers_cli_install="false"
    ;;
  release|production|prod)
    app_name="Zurafa"
    executable_name="Zurafa"
    bundle_identifier="app.zurafa.Zurafa"
    app_support_name="Zurafa"
    offers_cli_install="true"
    ;;
  *)
    echo "unknown ZURAFA_BUILD_VARIANT: $variant (expected development or release)" >&2
    exit 1
    ;;
esac
app="$root/build/$app_name.app"

(cd "$root/rust" && cargo build --release)
(cd "$root/apps/macos" && swift build -c release)
bin="$(cd "$root/apps/macos" && swift build -c release --show-bin-path)"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$bin/Zurafa" "$app/Contents/MacOS/$executable_name"
cp -R "$bin/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
if ! otool -l "$app/Contents/MacOS/$executable_name" | grep -q '@executable_path/../Frameworks'; then
  install_name_tool -add_rpath '@executable_path/../Frameworks' "$app/Contents/MacOS/$executable_name"
fi
cp -R "$root/apps/macos/Sources/Zurafa/Resources/light-icons" "$app/Contents/Resources/light-icons"
cp -R "$root/apps/macos/Sources/Zurafa/Resources/dark-icons" "$app/Contents/Resources/dark-icons"
cp "$root/apps/macos/Sources/Zurafa/Resources"/Lobe*.png "$app/Contents/Resources/"
cp "$root/apps/macos/Sources/Zurafa/Resources/SymbolsNerdFontMono-Regular.ttf" "$app/Contents/Resources/SymbolsNerdFontMono-Regular.ttf"
cp "$root/apps/macos/Sources/Zurafa/Resources/SymbolsNerdFont-LICENSE.txt" "$app/Contents/Resources/SymbolsNerdFont-LICENSE.txt"
cp "$root/apps/macos/.build/checkouts/SwiftTerm/LICENSE" "$app/Contents/Resources/SwiftTerm-LICENSE.txt"
cp "$root/rust/target/release/zurafa-daemon" "$app/Contents/MacOS/zurafa-daemon"
# Resources, not MacOS: a "zurafa" file there would collide with the "Zurafa" app
# executable on the case-insensitive APFS volumes macOS ships by default.
cp "$root/rust/target/release/zurafa" "$app/Contents/Resources/zurafa"

# The app loads AppIcon via Bundle.main, so the SwiftPM resource bundle is not needed (codesign rejects it at the .app root).
icon_work="$(mktemp -d)"
trap 'rm -rf "$icon_work"' EXIT
icon_source="$icon_work/AppIcon.png"
swift "$root/scripts/make-icon.swift" "$root/apps/macos/Sources/Zurafa/Resources/Zurafa-iOS-Default-512@1x.png" "$icon_source"
iconset="$icon_work/AppIcon.iconset"
mkdir "$iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$icon_source" --out "$iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$icon_source" --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$bundle_identifier</string>
  <key>CFBundleName</key><string>$app_name</string>
  <key>CFBundleDisplayName</key><string>$app_name</string>
  <key>CFBundleExecutable</key><string>$executable_name</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>SUFeedURL</key><string>https://zurafa-website.vercel.app/appcast.xml</string>
  <key>SUPublicEDKey</key><string>Ck60GZlfckjuZg1qeMfyvfWzsEVAHlkGHdDyX0hG630=</string>
  <key>ZURAFAApplicationSupportName</key><string>$app_support_name</string>
  <key>ZURAFAOffersCLIInstall</key><$offers_cli_install/>
</dict>
</plist>
PLIST

codesign --force --deep -s - "$app"
codesign --verify --deep --strict "$app"
echo "built $app"
