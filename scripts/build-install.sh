#!/usr/bin/env bash
# Builds the app signed with your own team and installs it on a paired Apple TV.
# Run it again to update, or to renew the signature before its year is up.
#
#   bash scripts/build-install.sh                  # build, then install on "Front room"
#   DEVICE="Living Room" bash scripts/build-install.sh
#   SKIP_WEB=1 bash scripts/build-install.sh       # reuse the WebBuild already there
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
device="${DEVICE:-Front room}"

# Node 22 from nvm when it isn't on PATH already.
if ! command -v node >/dev/null 2>&1; then
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  # shellcheck disable=SC1091
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && nvm use 22 >/dev/null
fi

if [ "${SKIP_WEB:-0}" != "1" ] || [ ! -d WebBuild ]; then
  corepack enable >/dev/null 2>&1 || true
  bash scripts/fetch-web.sh
fi

xcodegen generate

# Built unsigned, as the CI does, then signed by hand below: Xcode has no Apple ID
# signed in, and xcodebuild won't take the API key for development signing.
xcodebuild build \
  -project AIOStreamsTV.xcodeproj \
  -scheme AIOStreamsTV \
  -configuration Release \
  -destination 'generic/platform=tvOS' \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""

app="build/Build/Products/Release-appletvos/AIOStreams.app"
shelf="$app/PlugIns/AIOStreamsTopShelf.appex"
test -d "$app" || { echo "No app at $app" >&2; exit 1; }

# tvOS development profiles made through the App Store Connect API (valid to
# 2027-11-06), for the Front room Apple TV and the "Apple Development: Created
# via API" certificate. No App Group yet: the API can't create one, so the Top
# Shelf has nothing to read until the group is added in the developer portal.
identity="${SIGN_IDENTITY:-Apple Development: Created via API (J3326UND22)}"
profiles="build/profiles"
sign() { # bundle, profile
  local ent
  ent="$(mktemp -t aio-ent).plist"
  security cms -D -i "$2" > "$ent.profile"
  /usr/libexec/PlistBuddy -x -c "Print :Entitlements" "$ent.profile" > "$ent"
  cp "$2" "$1/embedded.mobileprovision"
  codesign --force --sign "$identity" --entitlements "$ent" --timestamp=none "$1"
  rm -f "$ent" "$ent.profile"
}
for framework in "$app"/Frameworks/*; do
  codesign --force --sign "$identity" --timestamp=none "$framework"
done
sign "$shelf" "$profiles/topshelf.mobileprovision"
sign "$app" "$profiles/app.mobileprovision"
codesign --verify --deep --strict "$app"

xcrun devicectl device install app --device "$device" "$app"
echo "Installed on $device."
