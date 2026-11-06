#!/usr/bin/env bash
# Weekly check, run by launchd (~/Library/LaunchAgents/com.cachesleuth.aiostreams-check.plist):
# what's new upstream (mickey2266's app, and the AIOStreams web app it bundles)
# since the last check, and whether the signature is within 30 days of expiring.
# Shows a notification when there's news; never builds or installs anything.
#
#   bash scripts/check-updates.sh        # check now
#   FORCE_NOTIFY=1 bash scripts/check-updates.sh     # notify even with nothing new
#   WARN_DAYS=400 bash scripts/check-updates.sh      # try the expiry warning
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

here="$(cd "$(dirname "$0")/.." && pwd)"
support="$HOME/Library/Application Support/AIOStreamsTVOS"
profiles="${PROFILES:-$support/profiles}"
state="$support/check-state"
mkdir -p "$support"
report="$support/last-check.txt"
: > "$report"
say() { echo "$*" >> "$report"; }
news=()

# Last seen values, one "key value" per line.
seen() { [ -f "$state" ] && awk -v k="$1" '$1 == k { print $2 }' "$state"; }

say "AIOStreams update check, $(date)"

# mickey2266's app: new commits on main and new release tags.
if git -C "$here" fetch -q upstream main --tags 2>>"$report"; then
  now_upstream="$(git -C "$here" rev-parse upstream/main)"
  last="$(seen upstream)"
  if [ -n "$last" ] && [ "$last" != "$now_upstream" ]; then
    count="$(git -C "$here" rev-list --count "$last..$now_upstream" 2>/dev/null || echo some)"
    news+=("$count new commits in the Apple TV app")
    say ""
    say "== New in mickey2266/AIOStreamsTVOS"
    git -C "$here" log --format='- %s' "$last..$now_upstream" 2>/dev/null | cut -c1-200 >> "$report"
  fi
  now_release="$(git -C "$here" tag -l 'v*' --sort=-v:refname | head -n 1)"
  last="$(seen release)"
  if [ -n "$now_release" ] && [ -n "$last" ] && [ "$last" != "$now_release" ]; then
    news+=("release $now_release")
    say "New release: $now_release (https://github.com/mickey2266/AIOStreamsTVOS/releases/tag/$now_release)"
  fi
else
  say "Couldn't fetch mickey2266/AIOStreamsTVOS."
fi

# The AIOStreams web app: compared with what the TV's build bundled.
web_now="$(git ls-remote https://github.com/Viren070/AIOStreams.git refs/heads/main 2>/dev/null | cut -f1)"
web_built="$(head -n 1 "$here/WebBuild/aiostreams-commit.txt" 2>/dev/null)"
if [ -n "$web_now" ]; then
  now_web="$web_now"
  last="$(seen web)"
  if [ -n "$last" ] && [ "$last" != "$web_now" ] && [ "$web_built" != "$web_now" ]; then
    ahead="$(gh api "repos/Viren070/AIOStreams/compare/${web_built:-$last}...$web_now" --jq .ahead_by 2>/dev/null || echo "")"
    news+=("${ahead:-new} AIOStreams web app changes")
    say ""
    say "== AIOStreams web app: ${ahead:-some} commits newer than the TV's build"
    gh api "repos/Viren070/AIOStreams/compare/${web_built:-$last}...$web_now" \
      --jq '.commits[-15:][] | "- " + (.commit.message | split("\n")[0])' 2>/dev/null | cut -c1-200 >> "$report"
  fi
else
  say "Couldn't reach Viren070/AIOStreams."
fi

# The signature: the app stops opening when the profiles expire.
for p in "$profiles"/*.mobileprovision; do
  [ -f "$p" ] || continue
  expiry="$(security cms -D -i "$p" 2>/dev/null | plutil -extract ExpirationDate raw -o - - 2>/dev/null)"
  [ -n "$expiry" ] || continue
  left=$(( ($(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$expiry" +%s) - $(date +%s)) / 86400 ))
  say "$(basename "$p"): expires $expiry ($left days)"
  if [ -z "${soonest:-}" ] || [ "$left" -lt "$soonest" ]; then soonest="$left"; fi
done
if [ -n "${soonest:-}" ] && [ "$soonest" -le "${WARN_DAYS:-30}" ]; then
  news+=("signature expires in $soonest days: renew the profiles, then run build-install.sh")
fi

# Remember what was seen, for next week.
{
  [ -n "${now_upstream:-}" ] && echo "upstream $now_upstream"
  [ -n "${now_release:-}" ] && echo "release $now_release"
  [ -n "${now_web:-}" ] && echo "web $now_web"
} > "$state"

if [ "${#news[@]}" -gt 0 ] || [ "${FORCE_NOTIFY:-0}" = "1" ]; then
  summary="nothing new"
  if [ "${#news[@]}" -gt 0 ]; then
    summary="$(printf '%s; ' "${news[@]}")"
    summary="${summary%; }"
  fi
  say ""
  say "Summary: $summary"
  osascript -e "display notification \"${summary//\"/}\" with title \"AIOStreams for Apple TV\" subtitle \"Details: last-check.txt\"" 2>/dev/null
fi
cat "$report"
