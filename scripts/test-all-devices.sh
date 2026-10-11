#!/bin/bash
# Runs the MilesProSync test suite on every iPhone model below (and its Pro / Pro Max / Plus
# variants), creating a simulator for any model that has a device type in the installed Xcode but
# no simulator yet. Models Xcode doesn't know about are reported as skipped, not failed.
#
# Usage: scripts/test-all-devices.sh [generations...]   e.g. scripts/test-all-devices.sh 16 17
set -u
cd "$(dirname "$0")/.."

GENERATIONS=("$@"); [ $# -eq 0 ] && GENERATIONS=(14 15 16 17 18 19)
SUFFIXES=("" " Plus" " Pro" " Pro Max")

resolve() { # name -> prints "udid" (creating the simulator if needed), or nothing
python3 - "$1" <<'PY'
import json, subprocess, sys
name = sys.argv[1]
def sh(*a): return subprocess.run(a, capture_output=True, text=True).stdout
devices = json.loads(sh("xcrun", "simctl", "list", "devices", "available", "-j"))["devices"]
for runtime, items in devices.items():
    for d in items:
        if d["name"] == name and d.get("isAvailable", True):
            print(d["udid"]); sys.exit(0)
types = json.loads(sh("xcrun", "simctl", "list", "devicetypes", "-j"))["devicetypes"]
dtype = next((t for t in types if t["name"] == name), None)
if not dtype: sys.exit(0)
runtimes = json.loads(sh("xcrun", "simctl", "list", "runtimes", "-j"))["runtimes"]
ios = [r for r in runtimes if r.get("isAvailable") and r["platform"] == "iOS"
       and any(s["identifier"] == dtype["identifier"] for s in r.get("supportedDeviceTypes", []))]
if not ios: sys.exit(0)
runtime = sorted(ios, key=lambda r: [int(x) for x in r["version"].split(".")])[-1]
print(sh("xcrun", "simctl", "create", name, dtype["identifier"], runtime["identifier"]).strip())
PY
}

passed=(); failed=(); skipped=()
for gen in "${GENERATIONS[@]}"; do
  for suffix in "${SUFFIXES[@]}"; do
    name="iPhone ${gen}${suffix}"
    udid=$(resolve "$name")
    if [ -z "$udid" ]; then skipped+=("$name"); echo "⏭  $name — no device type / runtime in this Xcode"; continue; fi
    echo "▶︎ $name ($udid)"
    log=$(mktemp)
    if xcodebuild test -project MilesProSync.xcodeproj -scheme MilesProSync \
         -destination "platform=iOS Simulator,id=$udid" CODE_SIGNING_ALLOWED=NO >"$log" 2>&1; then
      passed+=("$name"); echo "✅ $name"
    else
      failed+=("$name"); echo "❌ $name"; grep -E "error:|✘" "$log" | sort -u | head -15
    fi
    rm -f "$log"
  done
done

echo; echo "Passed (${#passed[@]}): ${passed[*]:-none}"
echo "Failed (${#failed[@]}): ${failed[*]:-none}"
echo "Skipped (${#skipped[@]}): ${skipped[*]:-none}"
[ ${#failed[@]} -eq 0 ] && [ ${#passed[@]} -gt 0 ]
