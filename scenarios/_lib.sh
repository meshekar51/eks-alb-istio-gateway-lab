#!/usr/bin/env bash
# shared by scenarios/*/break.sh and fix.sh
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"
load_env
kctx_check
SCEN="$(basename "$(cd "$(dirname "$0")" && pwd)")"
banner() { printf '\n%s[scenario %s] %s%s\n' "$C_YEL" "$SCEN" "$*" "$C_OFF"; }
