#!/usr/bin/env bash
# Downloads Streamyfin's MPVKit build into Vendor/MPVKit.xcframework: libmpv,
# FFmpeg and their dependencies as one static framework, with the
# vo_avfoundation video output that hands HDR10 and HLG to the TV. The same
# build the working aiostreams-tvos project uses. Checked against its SHA-256.
set -euo pipefail

version="0.41.0-av5"
sha256="80a79fbb34b1a3ae84744fe7bb9d365d2a006a5f617460933b7ce777251d3618"
url="https://github.com/streamyfin/MPVKit/releases/download/$version/MPVKit.xcframework.zip"

here="$(cd "$(dirname "$0")/.." && pwd)"
out="$here/Vendor/MPVKit.xcframework"
stamp="$here/Vendor/MPVKit.version"

if [ -d "$out" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$version" ]; then
  echo "MPVKit $version is already in Vendor/"
  exit 0
fi

cache="$here/.build/mpvkit"
zip="$cache/MPVKit-$version.zip"
mkdir -p "$cache"
if [ ! -f "$zip" ]; then
  echo "Downloading MPVKit ${version}..."
  curl -fL --retry 3 -o "$zip.part" "$url"
  mv "$zip.part" "$zip"
fi

actual="$(shasum -a 256 "$zip" | cut -d' ' -f1)"
if [ "$actual" != "$sha256" ]; then
  echo "MPVKit's SHA-256 is $actual, not $sha256" >&2
  rm -f "$zip"
  exit 1
fi

work="$cache/unzipped"
rm -rf "$work"
mkdir -p "$work"
unzip -q "$zip" -d "$work"
found="$(find "$work" -type d -name MPVKit.xcframework -prune | head -1)"
if [ -z "$found" ]; then
  echo "No MPVKit.xcframework in the download" >&2
  exit 1
fi

mkdir -p "$here/Vendor"
rm -rf "$out"
mv "$found" "$out"
echo "$version" > "$stamp"
rm -rf "$work"
echo "MPVKit $version is in Vendor/"
