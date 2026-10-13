#!/usr/bin/env bash
# Build, Developer ID sign, package, and optionally notarize Zurafa for macOS.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/build/Zurafa.app"
cert="${DEVELOPER_ID_APPLICATION:-Developer ID Application: Unique (Deutschland) GmbH (K8T3LW283A)}"
team_id="${TEAM_ID:-K8T3LW283A}"
version="${1:-}"
build_number="${BUILD_NUMBER:-}"
arch="$(uname -m)"
feed_origin="${SPARKLE_FEED_ORIGIN:-https://zurafa-website.vercel.app}"
sparkle_dir="$root/build/sparkle-appcast"
generate_appcast="$root/apps/macos/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"

usage() {
  cat <<USAGE
Usage: $0 [version]

Environment:
  DEVELOPER_ID_APPLICATION  Signing identity. Default: $cert
  TEAM_ID                   Apple team id. Default: $team_id
  BUILD_NUMBER              CFBundleVersion. Default: existing Info.plist value
  SPARKLE_FEED_ORIGIN       Website origin. Default: $feed_origin

Optional notarization, choose one:
  NOTARY_PROFILE            notarytool keychain profile name
  APPLE_ID                  Apple ID email
  APP_SPECIFIC_PASSWORD     App-specific password for APPLE_ID

Outputs:
  build/Zurafa.app
  build/Zurafa-<version>-macos-<arch>.zip
  build/Zurafa-<version>-macos-<arch>.dmg
  build/sparkle-appcast/appcast.xml
  website/dist/appcast.xml
  website/dist/releases/Zurafa-<version>-macos-<arch>.zip
  website/dist/releases/Zurafa-<version>-macos-<arch>.dmg
  website/dist/releases/*.delta when Sparkle generates delta updates
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

require() {
  command -v "$1" >/dev/null || { echo "missing required command: $1" >&2; exit 1; }
}

require codesign
require ditto
require hdiutil
require plutil
require xcrun

notary_args=()
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  notary_args=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${APPLE_ID:-}" && -n "${APP_SPECIFIC_PASSWORD:-}" ]]; then
  notary_args=(--apple-id "$APPLE_ID" --team-id "$team_id" --password "$APP_SPECIFIC_PASSWORD")
fi

notarize() {
  local file="$1"
  if [[ ${#notary_args[@]} -eq 0 ]]; then
    echo "notarization skipped for $file (set NOTARY_PROFILE or APPLE_ID + APP_SPECIFIC_PASSWORD)"
    return 1
  fi

  echo "notarizing $file"
  xcrun notarytool submit "$file" "${notary_args[@]}" --wait
}

sign_app() {
  echo "signing app with: $cert"
  if [[ -d "$app/Contents/Frameworks/Sparkle.framework" ]]; then
    codesign --force --deep --options runtime --timestamp --sign "$cert" "$app/Contents/Frameworks/Sparkle.framework"
  fi

  while IFS= read -r -d '' executable; do
    codesign --force --options runtime --timestamp --sign "$cert" "$executable"
  done < <(find "$app/Contents/MacOS" "$app/Contents/Resources" -type f -perm -111 -print0)

  codesign --force --options runtime --timestamp --sign "$cert" "$app"
  codesign --verify --deep --strict --verbose=2 "$app"
}

create_zip() {
  local output="$1"
  rm -f "$output"
  ditto -c -k --keepParent "$app" "$output"
  shasum -a 256 "$output" > "$output.sha256"
}

create_appcast() {
  [[ -x "$generate_appcast" ]] || { echo "missing Sparkle generate_appcast: $generate_appcast" >&2; return 0; }

  mkdir -p "$sparkle_dir"
  cp "$zip" "$sparkle_dir/$(basename "$zip")"
  local notes="$root/build/release-notes-v$version.md"
  if [[ -f "$notes" ]]; then
    cp "$notes" "$sparkle_dir/$(basename "${zip%.zip}.md")"
  fi

  "$generate_appcast" \
    --download-url-prefix "$feed_origin/releases/" \
    --link "$feed_origin/" \
    "$sparkle_dir"

  mkdir -p "$root/website/dist/releases"
  cp "$sparkle_dir/appcast.xml" "$root/website/dist/appcast.xml"
  if [[ -f "$sparkle_dir/$(basename "${zip%.zip}.md")" ]]; then
    cp "$sparkle_dir/$(basename "${zip%.zip}.md")" "$root/website/dist/"
  fi
  cp "$zip" "$root/website/dist/releases/$(basename "$zip")"
  if compgen -G "$sparkle_dir/*.delta" >/dev/null; then
    cp "$sparkle_dir"/*.delta "$root/website/dist/releases/"
  fi
}

create_dmg() {
  local output="$1"
  local dmg_root
  dmg_root="$(mktemp -d "$root/build/dmg-root.XXXXXX")"
  trap 'rm -rf "$dmg_root"' RETURN

  cp -R "$app" "$dmg_root/Zurafa.app"
  ln -s /Applications "$dmg_root/Applications"

  rm -f "$output"
  hdiutil create \
    -volname "Zurafa" \
    -srcfolder "$dmg_root" \
    -ov \
    -format UDZO \
    "$output"

  codesign --force --timestamp --sign "$cert" "$output"
  shasum -a 256 "$output" > "$output.sha256"
}

ZURAFA_BUILD_VARIANT=release "$root/scripts/bundle.sh"

if [[ -n "$version" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
else
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
fi

if [[ -n "$build_number" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app/Contents/Info.plist"
fi

sign_app

notary_zip="$root/build/Zurafa-notary.zip"
create_zip "$notary_zip"
if notarize "$notary_zip"; then
  xcrun stapler staple "$app"
fi
rm -f "$notary_zip" "$notary_zip.sha256"

zip="$root/build/Zurafa-$version-macos-$arch.zip"
dmg="$root/build/Zurafa-$version-macos-$arch.dmg"
create_zip "$zip"
create_appcast
create_dmg "$dmg"
if notarize "$dmg"; then
  xcrun stapler staple "$dmg"
  shasum -a 256 "$dmg" > "$dmg.sha256" # stapling rewrites the dmg
fi
cp "$dmg" "$root/website/dist/releases/$(basename "$dmg")"

codesign -dv --verbose=4 "$app" 2>&1 | grep -E 'Authority=|TeamIdentifier=|Runtime|Identifier=' || true
spctl --assess --type execute --verbose "$app" || true
spctl -a -vv -t open --context context:primary-signature "$dmg" || true

cat <<DONE

Release files:
  $app
  $zip
  $zip.sha256
  $dmg
  $dmg.sha256
  $sparkle_dir/appcast.xml
  $root/website/dist/appcast.xml
  $root/website/dist/$(basename "${zip%.zip}.md") if release notes are present
  $root/website/dist/releases/$(basename "$zip")
  $root/website/dist/releases/$(basename "$dmg")
  $root/website/dist/releases/*.delta if present
DONE
