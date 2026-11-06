#!/usr/bin/env bash
# One report on the app as the Apple TV has it: the TV's state, the installed
# app, the Top Shelf's shared data, recent crash and memory reports naming the
# app, and the signature's expiry. Read-only unless LIVE_SECONDS is set.
#
#   bash scripts/diagnose.sh                    # report into ~/Library/Application Support/AIOStreamsTVOS/diagnostics/
#   LIVE_SECONDS=60 bash scripts/diagnose.sh    # also relaunch the app and keep its log for 60 s
#                                               # (closes the app if it's open: not while someone watches)
#   DEVICE="<name>" bash scripts/diagnose.sh
set -uo pipefail

device="${DEVICE:-Front room}"
bundle="com.cachesleuth.aiostreams.tvos"
group="group.com.cachesleuth.aiostreams.tvos"
support="$HOME/Library/Application Support/AIOStreamsTVOS"
profiles="${PROFILES:-$support/profiles}"
out="$support/diagnostics/$(date +%Y-%m-%d-%H%M%S)"
mkdir -p "$out"
report="$out/summary.txt"
say() { echo "$*" | tee -a "$report"; }

say "AIOStreams diagnostics, $(date)"
say "Device: $device"
say ""

state="$(xcrun devicectl list devices 2>&1 | grep -F "$device" || true)"
say "== Apple TV"
say "${state:-not listed by devicectl (unpaired, or the Mac cannot see it)}"
if ! echo "$state" | grep -q 'available'; then
  say "The TV isn't reachable: wake it, or check it's on the same network. Stopping here."
  say "Report: $report"
  exit 1
fi
xcrun devicectl device info details --device "$device" 2>/dev/null | grep -E 'OS Version|OS Build' | tee -a "$report"
say ""

say "== App"
xcrun devicectl device info apps --device "$device" 2>&1 | grep -F "$bundle" | tee -a "$report" || say "not installed"
running="$(xcrun devicectl device info processes --device "$device" 2>&1 | grep -E 'AIOStreams(TopShelf)?(\.appex)?/AIOStreams' || true)"
say "Running: ${running:-no}"
say ""

say "== Top Shelf shared data ($group)"
xcrun devicectl device info files --device "$device" --domain-type appGroupDataContainer \
  --domain-identifier "$group" 2>&1 | grep -iE 'TopShelf/' | tee -a "$report" || say "no Top Shelf files"
if xcrun devicectl device copy from --device "$device" --domain-type appGroupDataContainer \
     --domain-identifier "$group" --source Library/Caches/TopShelf/asked.txt \
     --destination "$out/asked.txt" >/dev/null 2>&1; then
  say "Last asked by tvOS (time, titles shown): $(cat "$out/asked.txt")"
else
  say "asked.txt missing: tvOS hasn't run the Top Shelf extension, or it failed at launch."
fi
if xcrun devicectl device copy from --device "$device" --domain-type appGroupDataContainer \
     --domain-identifier "$group" --source Library/Caches/TopShelf/items.json \
     --destination "$out/items.json" >/dev/null 2>&1; then
  say "Saved list: $(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))), 'titles')" "$out/items.json" 2>/dev/null || echo unreadable)"
fi
say ""

say "== Crash and memory reports naming the app (last 14 days)"
mkdir -p "$out/crashes-all"
if xcrun devicectl device copy from --device "$device" --domain-type systemCrashLogs --source / \
     --destination "$out/crashes-all" >/dev/null 2>&1; then
  mkdir -p "$out/crashes"
  found=0
  while IFS= read -r f; do
    if grep -qiE 'AIOStreams' "$f"; then
      cp "$f" "$out/crashes/" && found=$((found + 1))
      say "$(basename "$f")"
    fi
  done < <(find "$out/crashes-all" -type f -name '*.ips' -mtime -14)
  [ "$found" -eq 0 ] && say "none"
  rm -rf "$out/crashes-all"
else
  say "couldn't copy the TV's crash reports"
fi
say ""

say "== Signature"
for p in "$profiles"/*.mobileprovision; do
  [ -f "$p" ] || { say "no profiles in $profiles"; break; }
  expiry="$(security cms -D -i "$p" 2>/dev/null | plutil -extract ExpirationDate raw -o - - 2>/dev/null)"
  say "$(basename "$p"): expires ${expiry:-unknown}"
done
say ""

if [ -n "${LIVE_SECONDS:-}" ]; then
  say "== Live log for ${LIVE_SECONDS}s (app relaunched)"
  xcrun devicectl device process launch --device "$device" --terminate-existing --console "$bundle" \
    > "$out/live.log" 2>&1 &
  pid=$!
  sleep "$LIVE_SECONDS"
  kill "$pid" 2>/dev/null
  grep -vE 'could not create directory|^[0-9]+ +0x|sandbox_extension' "$out/live.log" \
    | grep -E '\[(aether|web|top-shelf)\]|error|Error' | tail -40 | tee -a "$report"
  say "Full log: $out/live.log"
  say ""
fi

say "Report: $report"
