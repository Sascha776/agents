# ──────────────────────────────────────────────────────────────────────────
# test/lib/sf-fake.sh — adapter #2 for the sf seam: an in-memory fake used by
# tests and --dry-run. Satisfies the same sf_v* contract as lib/sf-real.sh
# but touches nothing live: no org, no network, no browser.
#
# Config (environment):
#   FAKE_SF_USERNAME     username sf_username reports (default tester@agentlab.example.com)
#   FAKE_SF_IS_SANDBOX   "true"|"false" sf_is_sandbox reports (default true)
#   FAKE_SF_FAIL         comma-list of verbs to make fail: login,username,
#                        sandbox,scaffold,deploy,smoke (default empty)
#   FAKE_SF_SMOKE_REPLY  canned reply text (default "It's sunny and clear at the resort today.")
#   FAKE_SF_LOG          file to append each call as "verb arg..." for tests
#                        that want a durable sequence check. Optional.
#
# Behavior notes:
#   - sf_generate materializes a real project tree on disk (minimal but
#     faithful: a Local_Info_Agent.agent with a placeholder default_agent_user)
#     so stage 4 (the real sed edit) is exercised end-to-end. Only sf is faked;
#     the filesystem side of the flow is real.
#   - Ledger stays in-process as FAKE_SF_CALLS (one entry per call) so an
#     in-process test can assert on it without a file.
# ──────────────────────────────────────────────────────────────────────────

FAKE_SF_CALLS=()
FAKE_SF_LOG="${FAKE_SF_LOG:-${TMPDIR:-/tmp}/agentforce-sf-fake.log}"
: > "$FAKE_SF_LOG"

# _fake_log VERB ARG... — record a call both in-process (FAKE_SF_CALLS) and
# to FAKE_SF_LOG. Subshells (command substitution, ( cd ... )) can't mutate
# the in-process array, so the file is the durable ledger; it is truncated on
# re-source so each run starts fresh.
_fake_log() {
  FAKE_SF_CALLS+=("$*")
  printf '%s\n' "$*" >> "$FAKE_SF_LOG"
}

# _fake_should_fail VERB — true if VERB is listed in FAKE_SF_FAIL.
_fake_should_fail() {
  [[ ",${FAKE_SF_FAIL:-}," == *",$1,"* ]]
}

sf_probe() {
  command -v python3 >/dev/null 2>&1
}

sf_login() {
  local alias="$1" url="$2"
  _fake_log login "$alias" "$url"
  ! _fake_should_fail login
}

sf_username() {
  local alias="$1"
  _fake_log username "$alias"
  _fake_should_fail username && return 1
  printf '%s\n' "${FAKE_SF_USERNAME:-tester@agentlab.example.com}"
}

sf_is_sandbox() {
  local alias="$1"
  _fake_log sandbox "$alias"
  _fake_should_fail sandbox && return 1
  printf '%s\n' "${FAKE_SF_IS_SANDBOX:-true}"
}

sf_generate() {
  local name="$1"
  _fake_log scaffold "$name"
  _fake_should_fail scaffold && return 1
  local bundle="${LAB_AGENT_BUNDLE:-Local_Info_Agent}"
  mkdir -p "$name/force-app/main/default/aiAuthoringBundles/$bundle"
  cat > "$name/force-app/main/default/aiAuthoringBundles/$bundle/$bundle.agent" <<AGENT
config:
    default_agent_user: "UPDATE_WITH_YOUR_DEFAULT_AGENT_USER"
AGENT
}

sf_deploy() {
  local alias="$1"
  _fake_log deploy "$alias"
  ! _fake_should_fail deploy
}

sf_smoke() {
  local alias="$1" bundle="$2" utterance="$3"
  local default_reply="It's sunny and clear at the resort today."
  _fake_log smoke "$alias" "$bundle" "$utterance"
  _fake_should_fail smoke && return 1
  printf '%s\n' "${FAKE_SF_SMOKE_REPLY:-$default_reply}"
}