#!/usr/bin/env bash
# Builds the AIOStreams web app's standalone build and copies it into WebBuild,
# which the app bundles. The patches in patches/web/ are applied for the build
# and taken out again after it, so the AIOStreams checkout is left as it was.
#
#   AIOSTREAMS_DIR=/path/to/AIOStreams bash scripts/fetch-web.sh   # use a local checkout as it is
#   AIOSTREAMS_REF=main bash scripts/fetch-web.sh                   # clone this branch or tag into .build/
#   AIOSTREAMS_PATCHES=0 bash scripts/fetch-web.sh                  # build without the patches
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
ref="${AIOSTREAMS_REF:-main}"
repo="${AIOSTREAMS_REPO:-https://github.com/Viren070/AIOStreams.git}"
src="${AIOSTREAMS_DIR:-}"

if [ -z "$src" ]; then
  src="$here/.build/AIOStreams"
  if [ -d "$src/.git" ]; then
    git -C "$src" fetch --depth 1 origin "$ref"
    # The app's own clone: anything a stopped build left in it goes.
    git -C "$src" checkout --force --detach FETCH_HEAD
  else
    git clone --depth 1 --branch "$ref" "$repo" "$src"
  fi
fi

if ! command -v pnpm >/dev/null 2>&1; then
  corepack enable
fi

# The web app's TV memory and scrolling changes, kept here rather than in a fork. A patch that no
# longer applies stops the build and is named, to be redone against the new code.
patches=()
if [ "${AIOSTREAMS_PATCHES:-1}" != "0" ]; then
  shopt -s nullglob
  patches=("$here"/patches/web/*.patch)
  shopt -u nullglob
fi
applied=()
unpatch() {
  local i
  for ((i = ${#applied[@]} - 1; i >= 0; i--)); do
    git -C "$src" apply -R "${applied[$i]}" || echo "Couldn't take $(basename "${applied[$i]}") out of $src" >&2
  done
}
trap unpatch EXIT
for patch in "${patches[@]}"; do
  if ! git -C "$src" apply --check "$patch"; then
    echo "$(basename "$patch") no longer applies to AIOStreams $(git -C "$src" rev-parse --short HEAD 2>/dev/null || echo "$ref")" >&2
    exit 1
  fi
  git -C "$src" apply "$patch"
  applied+=("$patch")
  echo "Applied $(basename "$patch")"
done

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
for patch in "${applied[@]}"; do
  echo "patched: $(basename "$patch")" >> "$out/aiostreams-commit.txt"
done
echo "Copied the web app into WebBuild ($(head -n 1 "$out/aiostreams-commit.txt" 2>/dev/null || echo 'unknown commit'), ${#applied[@]} patches)"
