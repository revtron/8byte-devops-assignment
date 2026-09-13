#!/usr/bin/env bash
# smoke-test.sh <base_url>
#
# Post-deploy smoke test run by Jenkins against the ALB:
#   staging: scripts/smoke-test.sh http://<alb-dns>:8080
#   prod:    scripts/smoke-test.sh http://<alb-dns>
#
# 1. GET /health must return 200 with "db":"ok" (retried: the ALB target can
#    take a few health-check intervals to go back to healthy after a deploy).
# 2. POST /api/todos creates a todo (201), GET /api/todos lists it,
#    DELETE /api/todos/:id removes it (204).
# Needs curl and jq. Exits non-zero on the first failure.
set -euo pipefail

BASE_URL="${1:-}"
if [[ -z "$BASE_URL" ]]; then
  echo "usage: $0 <base_url>" >&2
  exit 2
fi
BASE_URL="${BASE_URL%/}"

for tool in curl jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool is required" >&2; exit 2; }
done

HEALTH_RETRIES=12
HEALTH_SLEEP=5
BODY_FILE="$(mktemp)"
trap 'rm -f "$BODY_FILE"' EXIT

fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }

# request METHOD PATH [JSON_BODY] -> prints HTTP status; body lands in $BODY_FILE
request() {
  local method="$1" path="$2" data="${3:-}"
  local -a args=(-sS -o "$BODY_FILE" -w '%{http_code}' --max-time 15 -X "$method" -H 'Accept: application/json')
  if [[ -n "$data" ]]; then
    args+=(-H 'Content-Type: application/json' --data "$data")
  fi
  local code
  code="$(curl "${args[@]}" "$BASE_URL$path" 2>/dev/null)" || true
  printf '%s' "${code:-000}"
}

echo "==> smoke test against $BASE_URL"

# --- 1. /health ---------------------------------------------------------------
code="000"
for (( i = 1; i <= HEALTH_RETRIES; i++ )); do
  code="$(request GET /health)"
  if [[ "$code" == "200" ]]; then
    break
  fi
  echo "    /health -> $code (attempt $i/$HEALTH_RETRIES), retrying in ${HEALTH_SLEEP}s"
  sleep "$HEALTH_SLEEP"
done
[[ "$code" == "200" ]] || fail "/health did not return 200 after $HEALTH_RETRIES attempts (last: $code, body: $(cat "$BODY_FILE"))"

db_state="$(jq -r '.db // empty' "$BODY_FILE" 2>/dev/null || true)"
[[ "$db_state" == "ok" ]] || fail "/health db is '$db_state', expected 'ok' (body: $(cat "$BODY_FILE"))"
echo "    /health ok: $(jq -c . "$BODY_FILE")"

# --- 2. CRUD round trip ---------------------------------------------------------
title="smoke $(date -u +%Y-%m-%dT%H:%M:%SZ)"
payload="$(jq -cn --arg t "$title" '{title: $t}')"

code="$(request POST /api/todos "$payload")"
[[ "$code" == "201" ]] || fail "POST /api/todos returned $code, expected 201 (body: $(cat "$BODY_FILE"))"
id="$(jq -r '.id // empty' "$BODY_FILE")"
[[ -n "$id" ]] || fail "POST /api/todos response has no id (body: $(cat "$BODY_FILE"))"
echo "    created todo id=$id"

code="$(request GET /api/todos)"
[[ "$code" == "200" ]] || fail "GET /api/todos returned $code, expected 200"
if ! jq -e --argjson id "$id" 'map(select(.id == $id)) | length == 1' "$BODY_FILE" >/dev/null 2>&1 \
   && ! jq -e --arg id "$id" 'map(select((.id|tostring) == $id)) | length == 1' "$BODY_FILE" >/dev/null 2>&1; then
  fail "GET /api/todos does not contain id $id"
fi
echo "    todo id=$id present in list"

code="$(request DELETE "/api/todos/$id")"
[[ "$code" == "204" ]] || fail "DELETE /api/todos/$id returned $code, expected 204"
echo "    deleted todo id=$id"

echo "==> smoke test PASSED for $BASE_URL"
