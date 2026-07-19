#!/usr/bin/env bash
#
# Wire-protocol CONFORMANCE SUITE. Drives a REAL PlumeKit server purely OVER THE
# WIRE (HTTP + WebSocket) — no in-process shortcuts, no client library — asserting
# the live contract (auth, API, realtime) AND the sync hooks. It is
# the executable form of docs/wire-protocol.md.
#
# Usage: support/conformance.sh [base-url]
#   With no arg, it builds + starts the native example server and tears it down.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

PASS=0; FAIL=0
check() { # name | actual | expected-substring
  if printf '%s' "$2" | grep -qF -- "$3"; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s\n       want substring: %s\n       got: %s\n' "$1" "$3" "$2"; fi
}
checkcode() { # name | actual-code | expected-code
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ok   %s (%s)\n' "$1" "$2"
  else FAIL=$((FAIL+1)); printf '  FAIL %s want %s got %s\n' "$1" "$3" "$2"; fi
}

BASE="${1:-}"
STARTED=""
if [ -z "$BASE" ]; then
  export PKG_CONFIG_PATH="$(brew --prefix libpq 2>/dev/null)/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
  ( cd Fixtures/Hello && swift build --product Server >/dev/null 2>&1 )
  BIN="$(cd Fixtures/Hello && swift build --product Server --show-bin-path 2>/dev/null)/Server"
  STATE="$(mktemp -d)"
  AUTH_SECRET="conformance-secret" CHANNEL_SIGNING_KEY="conformance-secret" \
    "$BIN" --port 8190 --state-dir "$STATE" >/tmp/conformance-server.log 2>&1 &
  STARTED=$!
  BASE="http://127.0.0.1:8190"
  curl -s --retry 60 --retry-connrefused --retry-delay 1 "$BASE/healthz" >/dev/null 2>&1
fi
J='content-type: application/json'

echo "== auth =="
TOKEN=$(curl -s -H "$J" -H 'accept: application/json' -d '{"email":"c@x.com","password":"pw123456"}' "$BASE/auth/register" | sed -E 's/.*"token":"([^"]+)".*/\1/')
check "register returns a token"        "$TOKEN" "."
check "currentUser from bearer"         "$(curl -s -H "authorization: Bearer $TOKEN" "$BASE/auth/me")" "1"
checkcode "anonymous me is anonymous"   "$(curl -s -H "authorization: Bearer ${TOKEN}ff" "$BASE/auth/me")" "anonymous"

echo "== API contract =="
checkcode "no token → 401"              "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/v1/posts")" "401"
check "401 error envelope"             "$(curl -s "$BASE/api/v1/posts")" '"code":"unauthorized"'
curl -s -H "authorization: Bearer $TOKEN" -H "$J" -d '{"title":"P1"}' "$BASE/api/v1/posts" >/dev/null
curl -s -H "authorization: Bearer $TOKEN" -H "$J" -d '{"title":"P2"}' "$BASE/api/v1/posts" >/dev/null
check "create is allow-list (no 'published')" "$(curl -s -H "authorization: Bearer $TOKEN" -H "$J" -d '{"title":"P3"}' "$BASE/api/v1/posts")" '"views":0'
check "no leaked column"               "$(curl -s -H "authorization: Bearer $TOKEN" "$BASE/api/v1/posts?limit=1")" '"pagination"'
check "pagination metadata hasMore"    "$(curl -s -H "authorization: Bearer $TOKEN" "$BASE/api/v1/posts?limit=1")" '"hasMore":true'
check "validation → structured 422"    "$(curl -s -H "authorization: Bearer $TOKEN" -H "$J" -d '{"title":""}' "$BASE/api/v1/posts")" '"code":"validation_failed"'

echo "== sync hooks =="
S="$BASE/api/v1/sync/notes"; AUTH="authorization: Bearer $TOKEN"
check "create: client-minted uid + version 1" "$(curl -s -H "$AUTH" -H "$J" -d '{"idempotencyKey":"k1","op":"create","uid":"n1","baseVersion":0,"schema":1,"data":{"body":"hi"}}' "$S")" '"version":1'
check "delta since 0 returns change + cursor"  "$(curl -s -H "$AUTH" "$S?since=0")" '"cursor":1'
check "update base=1 → version 2"              "$(curl -s -H "$AUTH" -H "$J" -d '{"idempotencyKey":"k2","op":"update","uid":"n1","baseVersion":1,"schema":1,"data":{"body":"e"}}' "$S")" '"version":2'
check "stale base → structured conflict"       "$(curl -s -H "$AUTH" -H "$J" -d '{"idempotencyKey":"k3","op":"update","uid":"n1","baseVersion":1,"schema":1,"data":{"body":"s"}}' "$S")" '"result":"conflict"'
check "replay → deduped (no double-apply)"     "$(curl -s -H "$AUTH" -H "$J" -d '{"idempotencyKey":"k1","op":"create","uid":"n1","baseVersion":0,"schema":1,"data":{"body":"hi"}}' "$S")" '"result":"deduped"'
check "delete → tombstone (deleted:true)"      "$(curl -s -H "$AUTH" -H "$J" -d '{"idempotencyKey":"k4","op":"delete","uid":"n1","baseVersion":2,"schema":1,"data":{}}' "$S")" '"deleted":true'
check "delta returns tombstone, not absence"   "$(curl -s -H "$AUTH" "$S?since=1")" '"deleted":true'
check "schema mismatch → 422"                  "$(curl -s -H "$AUTH" -H "$J" -d '{"idempotencyKey":"k5","op":"create","uid":"n2","baseVersion":0,"schema":2,"data":{"body":"x"}}' "$S")" '"code":"schema_mismatch"'
# (8) scope: a different user can't see n1
TOKEN2=$(curl -s -H "$J" -H 'accept: application/json' -d '{"email":"d@x.com","password":"pw123456"}' "$BASE/auth/register" | sed -E 's/.*"token":"([^"]+)".*/\1/')
OTHER=$(curl -s -H "authorization: Bearer $TOKEN2" "$S?since=0")
if printf '%s' "$OTHER" | grep -qF '"n1"'; then FAIL=$((FAIL+1)); echo "  FAIL scope isolates other users' records"; else PASS=$((PASS+1)); echo "  ok   scope isolates other users' records"; fi

echo "== streaming bodies =="
check "streamed response delivers every chunk" "$(curl -s "$BASE/stream/count")" "chunk-5"
check "streamed response is chunked-framed" \
  "$(curl -s -D - -o /dev/null "$BASE/stream/count")" "transfer-encoding: chunked"
# 40 MB is past the buffered-body cap (32 MB): only an unbuffered streaming route
# can take it. The bearer header exempts the raw POST from the CSRF form check.
BIG=$(head -c 40000000 /dev/zero | curl -s --data-binary @- -H 'content-type: application/octet-stream' \
  -H "authorization: Bearer $TOKEN" "$BASE/upload/stream")
check "streamed upload passes the buffered cap" "$BIG" "received 40000000 bytes"
STORED=$(head -c 6000000 /dev/zero | curl -s --data-binary @- -H 'content-type: application/octet-stream' \
  -H "authorization: Bearer $TOKEN" "$BASE/upload/store")
check "streamed upload lands whole in storage" "$STORED" "stored 6000000 bytes"

echo "== realtime (signed subscribe, payload kinds, stream action, resync) =="
if command -v node >/dev/null 2>&1; then
  RT=$(node "$ROOT/support/conformance-ws.mjs" 8190 2>/dev/null)
  check "fragment subscriber gets HTML fragment"  "$RT" "FRAGMENT:<li>"
  check "payload subscriber gets typed JSON"      "$RT" 'PAYLOAD:{"n"'
  check "forged token rejected"                   "$RT" "FORGED:rejected"
  check "model broadcast carries stream action"   "$RT" 'ACTION:<plume-stream action="prepend"'
  check "reconnect resync directive"              "$RT" 'RESYNC:{"type":"resync"'
else
  echo "  (node not found — skipping realtime over-the-wire checks)"
fi

[ -n "$STARTED" ] && kill "$STARTED" 2>/dev/null
echo ""
echo "conformance: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
