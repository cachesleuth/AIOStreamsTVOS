#!/usr/bin/env bash
# Builds the AIOStreams web app's standalone build and copies it into WebBuild,
# which the app bundles. The AIOStreams repo itself is only read, never changed.
#
#   AIOSTREAMS_DIR=/path/to/AIOStreams bash scripts/fetch-web.sh   # use a local checkout as it is
#   AIOSTREAMS_REF=main bash scripts/fetch-web.sh                   # clone this branch or tag into .build/
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
ref="${AIOSTREAMS_REF:-main}"
repo="${AIOSTREAMS_REPO:-https://github.com/Viren070/AIOStreams.git}"
src="${AIOSTREAMS_DIR:-}"

if [ -z "$src" ]; then
  src="$here/.build/AIOStreams"
  if [ -d "$src/.git" ]; then
    git -C "$src" fetch --depth 1 origin "$ref"
    git -C "$src" checkout --detach FETCH_HEAD
  else
    git clone --depth 1 --branch "$ref" "$repo" "$src"
  fi
fi

if ! command -v pnpm >/dev/null 2>&1; then
  corepack enable
fi

(
  cd "$src"
  pnpm install --frozen-lockfile --filter '@aiostreams/web...'
  pnpm -F @aiostreams/web build:standalone
)

# Outside App/: macOS ignores case, so App/web would be App/Web, which holds Swift sources.
out="$here/WebBuild"
rm -rf "$out"
cp -R "$src/packages/web/dist-standalone" "$out"
git -C "$src" rev-parse HEAD > "$out/aiostreams-commit.txt" 2>/dev/null || true
echo "Copied the web app into WebBuild ($(cat "$out/aiostreams-commit.txt" 2>/dev/null || echo 'unknown commit'))"
