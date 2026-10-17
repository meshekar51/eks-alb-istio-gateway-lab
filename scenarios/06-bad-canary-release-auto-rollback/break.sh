#!/usr/bin/env bash
set -euo pipefail; source "$(dirname "$0")/../_lib.sh"
banner "v2 ships a bug: ~1/3 of its responses are errors (podinfo --random-error)"
kubectl patch deploy podinfo-v2 -n lab-apps --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/command/-","value":"--random-error"}]' >/dev/null
kubectl rollout status deploy/podinfo-v2 -n lab-apps --timeout=3m >/dev/null
echo "Now run the progressive rollout and watch the analysis stop it:  PAUSE=0 bash tools/canary.sh rollout"
