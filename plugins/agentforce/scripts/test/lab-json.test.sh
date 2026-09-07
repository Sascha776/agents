#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────
# test/lab-json.test.sh — unit tests for the module's JSON de/serialization.
# The seam: the module's _lab_json helpers (the "JacksonTester" of this code-
# base) parse the sf CLI's JSON. Salesforces emits embedded control characters
# (\x00-\x1f) which the helpers must strip before parsing. Tests here mirror
# the @JsonTest discipline: deserialization paths, missing/null fields,
# malformed input, dirty output, round-trip, and a validation checkpoint.
#
# Usage:  bash test/lab-json.test.sh
# ──────────────────────────────────────────────────────────────────────────
set -euo pipefail
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPTS_DIR/lib/lab-setup.sh"   # defines _lab_json, _lab_json_record_field, _lab_json_last_message

PASS=0; FAIL=0
check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    PASS=$((PASS+1)); printf '  ✓ %s\n' "$label"
  else
    FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$label" >&2
  fi
}
# parse "json" (passed as a var — NUL-free only) through a helper.
parse() { printf '%s' "$1" | "$2" "${3:-}"; }

# ── Deserialization ───────────────────────────────────────────────────────
printf '── deserialization ──\n'
check "extract username" [ "$(parse '{"result":{"username":"alice@x.com"}}' _lab_json username)" = "alice@x.com" ]
check "extract sessionId" [ "$(parse '{"status":0,"result":{"sessionId":"abc123"}}' _lab_json sessionId)" = "abc123" ]
check "extract IsSandbox=true" [ "$(parse '{"result":{"records":[{"IsSandbox":true}]}}' _lab_json_record_field IsSandbox)" = "true" ]
check "extract IsSandbox=false" [ "$(parse '{"result":{"records":[{"IsSandbox":false}]}}' _lab_json_record_field IsSandbox)" = "false" ]
check "extract last message" [ "$(parse '{"result":{"messages":[{"message":"first"},{"message":"second"}]}}' _lab_json_last_message)" = "second" ]

# ── Missing / null fields ─────────────────────────────────────────────────
printf '── missing / null fields ──\n'
check "missing .result"     [ -z "$(parse '{}' _lab_json username)" ]
check "missing key"         [ -z "$(parse '{"result":{}}' _lab_json username)" ]
check "null username"       [ -z "$(parse '{"result":{"username":null}}' _lab_json username)" ]
check "null sandbox record" [ -z "$(parse '{"result":{"records":[]}}' _lab_json_record_field IsSandbox)" ]
check "null messages"       [ -z "$(parse '{"result":{"messages":[]}}' _lab_json_last_message)" ]
check "null message field"  [ -z "$(parse '{"result":{"messages":[{"message":null}]}}' _lab_json_last_message)" ]

# ── Control-character scrubbing ───────────────────────────────────────────
printf '── control-character scrubbing ──\n'
check "strip \\x1b inside username" [ "$(parse $'{"result":{"username":"alice\x1bx.com"}}' _lab_json username)" = "alicex.com" ]
# NUL bytes cannot live in a bash var; pipe them like real sf output does.
check "strip \\x00 inside sessionId"   [ "$(printf '{"result":{"sessionId":"a\000b"}}' | _lab_json sessionId)" = "ab" ]
check "strip \\x00 inside a token"     [ "$(printf '{"result":{"records":[{"IsSandbox":tru\000e}]}}' | _lab_json_record_field IsSandbox)" = "true" ]
check "strip \\x00 trailing control bytes" [ "$(printf '{"result":{"username":"clean"}}\000\001\n' | _lab_json username)" = "clean" ]
check "strip control inside message" [ "$(parse $'{"result":{"messages":[{"message":"hi\x1b there"}]}}' _lab_json_last_message)" = "hi there" ]

# ── Malformed input ───────────────────────────────────────────────────────
printf '── malformed input ──\n'
check "malformed object -> empty"   [ -z "$(parse '{not json' _lab_json username)" ]
check "malformed array -> empty"    [ -z "$(parse '[1,2' _lab_json username)" ]
check "malformed input -> quiet (no traceback)" [ -z "$(parse '{not json' _lab_json username 2>&1)" ]

# ── Round-trip: serialize (write) then parse (read) ───────────────────────
printf '── round-trip ──\n'
# The fake adapter "serializes" sf output (dirty JSON); the module parses it
# back. Emit the way sf_username would, then read with _lab_json.
serialized=$'{"result":{"username":"tester\x1b@agentlab.example.com"}}'
roundtrip=$(parse "$serialized" _lab_json username)
check "round-trip strips control chars" [ "$roundtrip" = "tester@agentlab.example.com" ]

# ── Validation checkpoint: an assertion that FAILS on wrong data ──────────
printf '── validation checkpoint ──\n'
# If a guard ever stopped stripping control chars, this must go red.
dirty=$'{"result":{"username":"a\x1bb"}}'
clean=$(parse "$dirty" _lab_json username)
if [ "$clean" = "a b" ] || [ "$clean" = "ab" ]; then
  PASS=$((PASS+1)); printf '  ✓ checkpoint: dirty control char caught (got clean "%s")\n' "$clean"
else
  FAIL=$((FAIL+1)); printf '  ✗ checkpoint: dirty control char NOT stripped (got "%s")\n' "$clean" >&2
fi

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]