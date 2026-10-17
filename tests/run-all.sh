#!/usr/bin/env bash
# Run every layer bottom-up and stop explaining at the FIRST failing layer:
# a red L3 makes every result above it meaningless.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
results=()
first_fail=""
for t in 00-platform 10-edge 20-routing 30-canary 40-mtls 50-waypoint; do
  if bash "./$t.sh"; then results+=("PASS  $t"); else results+=("FAIL  $t"); [[ -z "$first_fail" ]] && first_fail=$t; fi
done
printf '\n================ SUMMARY ================\n'
printf '  %s\n' "${results[@]}"
if [[ -n "$first_fail" ]]; then
  printf '\n  Lowest failing layer: %s  -> fix that first (docs/MASTER-TROUBLESHOOTING.md)\n' "$first_fail"
  exit 1
fi
printf '\n  All layers green.\n'
