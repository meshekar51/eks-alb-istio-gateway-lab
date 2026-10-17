#!/usr/bin/env bash
# Test helpers: PASS/FAIL accounting + an HTTPS client that can bypass DNS.
# shellcheck disable=SC2034
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"
load_env

PASS=0; FAIL=0; WARNS=0
FAILED_CHECKS=()

pass() { PASS=$((PASS+1)); ok "$*"; }
fail() { FAIL=$((FAIL+1)); FAILED_CHECKS+=("$*"); bad "$*"; }
note() { WARNS=$((WARNS+1)); warn "$*"; }
section() { printf '\n%s── %s %s\n' "$C_CYN" "$*" "$C_OFF"; }

summary() {
  local name="${1:-tests}"
  printf '\n%s%s: %d passed, %d failed, %d warnings%s\n' \
    "$([[ $FAIL -eq 0 ]] && echo "$C_GRN" || echo "$C_RED")" "$name" "$PASS" "$FAIL" "$WARNS" "$C_OFF"
  if (( FAIL > 0 )); then
    printf '  failed:\n'; printf '   - %s\n' "${FAILED_CHECKS[@]}"
    printf '  next: make doctor   |   docs/MASTER-TROUBLESHOOTING.md\n'
  fi
  [[ $FAIL -eq 0 ]]
}

# ---------------------------------------------------------------- HTTPS client
# VIA=dns (default): normal DNS.  VIA=alb: force-connect to the ALB (isolates DNS problems).
# Automatically falls back to VIA=alb if the hostname does not resolve yet.
ALB_DNS="$(alb_hostname || true)"
_connect_args() {
  local host="$1" port="$2"
  if [[ "${VIA:-dns}" == "alb" ]] || ! getent hosts "$host" >/dev/null 2>&1; then
    [[ -n "$ALB_DNS" ]] && printf -- '--connect-to\n%s:%s:%s:%s\n' "$host" "$port" "$ALB_DNS" "$port"
  fi
}

# hget <host> <path> [curl args...]  -> writes body to $BODY, headers to $HDRS, code in $CODE
BODY=$(mktemp); HDRS=$(mktemp); trap 'rm -f "$BODY" "$HDRS"' EXIT
hget() {
  local host="$1" path="$2"; shift 2
  local -a ca; mapfile -t ca < <(_connect_args "$host" 443)
  CODE=$(curl -sS --max-time 15 "${ca[@]}" -o "$BODY" -D "$HDRS" -w '%{http_code}' \
    "$@" "https://${host}${path}" 2>/dev/null) || CODE="000"
}
hdr() { grep -i "^$1:" "$HDRS" | head -1 | cut -d: -f2- | tr -d '\r' | sed 's/^ *//'; }
podinfo_version() { jq -r '.version // empty' "$BODY" 2>/dev/null; }

# in-cluster curl from the `curl` Deployment of a namespace:
#   kcurl <client-ns> <url> [curl args]   -> sets CODE, BODY (file), KCURL_ERR (curl's error line)
kcurl() {
  local ns="$1" url="$2"; shift 2
  local out
  out=$(kubectl exec -n "$ns" deploy/curl -c curl -- \
      curl -sS --max-time 6 -w '\n__CODE__%{http_code}' "$@" "$url" 2>&1) || true
  CODE=$(sed -n 's/^.*__CODE__\([0-9]\{3\}\)$/\1/p' <<<"$out" | tail -1); CODE=${CODE:-000}
  KCURL_ERR=$(grep -m1 '^curl: (' <<<"$out" || true)
  sed '/__CODE__[0-9]\{3\}$/d; /^curl: (/d' <<<"$out" > "$BODY"
}
