#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────
# test/lab-setup.test.sh — bash test harness for the lab-setup module.
# Zero live deps: runs the real module against the in-memory fake adapter.
# No framework: assert_*, a tiny pass/fail counter, exit 1 on any failure.
#
# Usage:  bash test/lab-setup.test.sh    (from the plugin scripts/ dir)
# ──────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0; FAIL=0
assert() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    PASS=$((PASS+1)); printf '  ✓ %s\n' "$label"
  else
    FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$label" >&2
  fi
}
assert_file() {
  assert "$1" test -f "$2"
}
assert_grep() {
  local label="$1" pattern="$2" file="$3"
  assert "$label" grep -qE "$pattern" "$file"
}

# ──────────────────────────────────────────────────────────────────────────
# 1. Happy path — all defaults, both confirms answered.
#    Source the whole wizard (the BASH_SOURCE guard keeps it from executing),
#    which loads the fixed wizard library + module. Then run the flow with
#    the fake adapter selected before sourcing.
# ──────────────────────────────────────────────────────────────────────────
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

export ENV_FILE="$WORK/lab.env"
printf 'ORG_ALIAS=dev2\nORG_URL=https://test.salesforce.com\n' > "$ENV_FILE"
export LAB_SF_ADAPTER=fake
export FAKE_SF_USERNAME="kossi@dev2.example.com"
export FAKE_SF_IS_SANDBOX=true
export FAKE_SF_SMOKE_REPLY="Sunny, 24°C at the resort."
export FAKE_SF_LOG="$WORK/sf.log"

# Ask ORG_ALIAS (Enter=keeps dev2), ORG_URL (keeps), pause->Enter,
# AGENT_PROJECT (Enter=default AgentLab), confirm agent-user (y), confirm deploy (y).
ANSWERS=$'\n\n\n\n\ny\ny'

source "$SCRIPTS_DIR/setup-sandbox.sh"   # wizard lib (guard keeps it from executing)
source "$SCRIPTS_DIR/lib/lab-setup.sh"   # the module (lab_setup_run)
lab_setup_run <<< "$ANSWERS"

printf '\n── happy path ──\n'
assert_grep "ORG_ALIAS preserved" '^ORG_ALIAS=dev2$' "$ENV_FILE"
assert_grep "ORG_URL preserved" '^ORG_URL=https://test.salesforce.com$' "$ENV_FILE"
assert_grep "SF_USERNAME set" '^SF_USERNAME=kossi@dev2.example.com$' "$ENV_FILE"
assert_grep "AGENT_PROJECT set" '^AGENT_PROJECT=AgentLab$' "$ENV_FILE"

AGENT_FILE="$WORK/AgentLab/force-app/main/default/aiAuthoringBundles/Local_Info_Agent/Local_Info_Agent.agent"
assert_file "agent file scaffolded" "$AGENT_FILE"
assert_grep "default_agent_user rewritten" 'default_agent_user: "kossi@dev2.example.com"' "$AGENT_FILE"

LEDGER="$WORK/sf.log"
assert_grep "ledger has login"   "^login dev2"        "$LEDGER"
assert_grep "ledger has username" "^username dev2"    "$LEDGER"
assert_grep "ledger has sandbox" "^sandbox dev2"      "$LEDGER"
assert_grep "ledger has deploy"  "^deploy dev2"       "$LEDGER"
assert_grep "ledger has smoke"   "^smoke dev2 Local_Info_Agent" "$LEDGER"
assert "ledger order: login first" bash -c "head -1 \"\$1\" | grep -qE '^login'" _ "$LEDGER"
assert "ledger order: deploy before smoke" bash -c "
  d=\"\$(grep -nE '^deploy' \"\$1\" | head -1 | cut -d: -f1)\"
  s=\"\$(grep -nE '^smoke' \"\$1\" | head -1 | cut -d: -f1)\"
  [[ -n \"\$d\" && -n \"\$s\" && \"\$d\" -lt \"\$s\" ]]
" _ "$LEDGER"

# ──────────────────────────────────────────────────────────────────────────
# 2. Re-run idempotency — project dir already exists → no scaffold call.
# ──────────────────────────────────────────────────────────────────────────
printf '\n── re-run idempotency ──\n'
lab_setup_run <<< "$ANSWERS"   # adapter re-sourced (truncates sf.log); no scaffold in this run
assert "re-run: no scaffold op" bash -c "! grep -qE '^scaffold' \"\$1\"" _ "$WORK/sf.log"
assert_grep "AGENT_PROJECT still set" '^AGENT_PROJECT=AgentLab$' "$ENV_FILE"

# ──────────────────────────────────────────────────────────────────────────
# 3. Non-sandbox: gate declined → exits 1, stops before scaffold.
# ──────────────────────────────────────────────────────────────────────────
printf '\n── non-sandbox declined gate ──\n'
rm -rf "$WORK/NonSandbox"
unset FAKE_SF_IS_SANDBOX
export FAKE_SF_IS_SANDBOX=false
if lab_setup_run <<< $'\n\n\nn\n' >/dev/null 2>&1; then
  FAIL=$((FAIL+1)); printf '  ✗ expected non-sandbox decline to exit 1\n' >&2
else
  PASS=$((PASS+1)); printf '  ✓ non-sandbox decline exits 1\n'
fi
assert "gate decline stops before scaffold" bash -c "! grep -qE '^scaffold' \"\$1\"" _ "$WORK/sf.log"

# ──────────────────────────────────────────────────────────────────────────
# 4. --dry-run: fake adapter selected, runs unattended to completion.
# ──────────────────────────────────────────────────────────────────────────
printf '\n── --dry-run ──\n'
cd "$WORK"
unset FAKE_SF_IS_SANDBOX FAKE_SF_USERNAME FAKE_SF_SMOKE_REPLY
export FAKE_SF_IS_SANDBOX=true FAKE_SF_USERNAME="tester@agentlab.example.com"
export LAB_SF_ADAPTER=fake LAB_SMOKE=1
lab_setup_run --dry-run </dev/null
printf '  ✓ dry-run completed\n'
assert_file "dry-run .env written" "$ENV_FILE"
assert_grep "dry-run uses fake username" '^SF_USERNAME=tester@agentlab.example.com$' "$ENV_FILE"

# ──────────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────────
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]