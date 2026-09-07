# ──────────────────────────────────────────────────────────────────────────
# lib/lab-setup.sh — the module.
#
# One interface: lab_setup_run [--dry-run]. It drives the whole agentforce
# test-lab setup flow (login, sandbox check, scaffold, default_agent_user,
# deploy, smoke test) for whatever adapter is selected at source time.
#
# The two adapters (lib/sf-real.sh, the fake used by tests) satisfy the same
# seam: sf_<verb>. The module never invokes sf itself; it only calls the
# adapter functions. This file must be sourced from the wizard (setup-sandbox.sh)
# so the fixed wizard library (banner/stage/say/ask/confirm/pause/write_env/
# finish, ENV_FILE) is in scope.
#
# Config is environment, all with defaults (default-argument magic):
#   LAB_ORG_ALIAS       default "agentlab"
#   LAB_ORG_URL         default "https://login.salesforce.com"
#   LAB_AGENT_PROJECT   default "AgentLab"
#   LAB_AGENT_BUNDLE    default "Local_Info_Agent"
#   LAB_SF_ADAPTER      default "real"  ("real"|"fake")
#   LAB_SMOKE           default "1"     ("0" disables stage 6)
# Exit codes: 0 = completed (declined non-essential gates are not fatal);
# 1 = fatal (toolchain missing, login/display/query/scaffold/deploy failed).
# ──────────────────────────────────────────────────────────────────────────

# Adapter selection is read at source time so tests can set LAB_SF_ADAPTER
# before sourcing this file. Adapter files live next to this module.
_LAB_ADAPTER_DIR="$(dirname "${BASH_SOURCE[0]}")"

# in-place sed that works on both GNU and BSD (macOS).
_lab_edit() {
  local file="$1" expr="$2"
  if sed --version >/dev/null 2>&1; then sed -i "$expr" "$file"; else sed -i '' "$expr" "$file"; fi
}

# _lab_json KEY: read one field out of a JSON blob on stdin, stripping the
# control characters (\x00-\x1f) Salesforce emits. Prints the value (or empty).
_lab_json() {
  local key="$1"
  python3 -c "import json,sys,re; d=json.loads(re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f]','',sys.stdin.read())); v=d.get('result',{}).get('$key'); print('' if v is None else v)"
}

# ── Stage 1: log in to the org ─────────────────────────────────────────────
_lab_stage_login() {
  stage "Log in to the org"
  say "We'll authenticate to your Salesforce org. A browser window will open."
  ask ORG_ALIAS "Org alias (later commands use this):"
  ORG_ALIAS="${ORG_ALIAS:-$LAB_ORG_ALIAS}"
  ask ORG_URL "Org URL [https://login.salesforce.com]"
  ORG_URL="${ORG_URL:-$LAB_ORG_URL}"
  say "Running the CLI web login now. Complete it in the browser, then return."
  open_url "${ORG_URL%%/}"
  sf_login "$ORG_ALIAS" "$ORG_URL" || return 1
  pause "Logged in? (browser should say authorized — then press Enter)"
  SF_USERNAME=$(sf_username "$ORG_ALIAS") || return 1
  note "Detected username: $SF_USERNAME"
  write_env ORG_ALIAS "$ORG_ALIAS"
  write_env ORG_URL "$ORG_URL"
  write_env SF_USERNAME "$SF_USERNAME"
}

# ── Stage 2: verify it's a sandbox ─────────────────────────────────────────
_lab_stage_sandbox() {
  stage "Verify sandbox"
  say "Security tests must target a sandbox. Checking org type."
  IS_SANDBOX=$(sf_is_sandbox "$ORG_ALIAS") || {
    warn "Could not check org type (adapter reported failure)."
    confirm "Continue with a production org anyway?" || { say "Stopping — re-run with a sandbox."; return 1; }
    return 0
  }
  if [ "$IS_SANDBOX" = "true" ]; then
    note "✓ Sandbox confirmed."
  else
    warn "This does NOT look like a sandbox. Agentforce security testing is sandbox-only."
    confirm "Continue with a production org anyway?" || { say "Stopping — re-run with a sandbox."; return 1; }
  fi
}

# ── Stage 3: scaffold the agent project ────────────────────────────────────
_lab_stage_scaffold() {
  stage "Scaffold the agent project"
  say "Creating an SFDX project from the CLI's bundled 'agent' template"
  say "($LAB_AGENT_BUNDLE sample: weather, events, resort hours)."
  ask AGENT_PROJECT "Project directory name [$LAB_AGENT_PROJECT]"
  AGENT_PROJECT="${AGENT_PROJECT:-$LAB_AGENT_PROJECT}"
  if [ -d "$AGENT_PROJECT" ]; then
    warn "Directory '$AGENT_PROJECT' already exists — skipping scaffold."
  else
    sf_generate "$AGENT_PROJECT" || return 1
  fi
  write_env AGENT_PROJECT "$AGENT_PROJECT"
}

# ── Stage 4: set the default agent user ────────────────────────────────────
_lab_stage_agent_user() {
  stage "Set the default agent user"
  say "The template ships with a placeholder default_agent_user; replace it"
  say "with the username from stage 1 so the agent compiles."
  AGENT_FILE=$(find "$AGENT_PROJECT" -name "*.agent" -path "*aiAuthoringBundles*" | head -1)
  AGENT_FILE="${AGENT_FILE:-$AGENT_PROJECT/force-app/main/default/aiAuthoringBundles/$LAB_AGENT_BUNDLE/$LAB_AGENT_BUNDLE.agent}"
  note "File: $AGENT_FILE"
  if [ ! -f "$AGENT_FILE" ]; then
    warn "Agent file not found; edit default_agent_user manually after scaffolding."
    return 0
  fi
  CURRENT=$(grep -oE 'default_agent_user: "[^"]*"' "$AGENT_FILE" | head -1 | sed 's/.*: "//; s/"$//' || true)
  note "Current placeholder: ${CURRENT:-<none>}"
  if grep -q "default_agent_user: \"$SF_USERNAME\"" "$AGENT_FILE"; then
    note "✓ default_agent_user already correct."
    return 0
  fi
  confirm "Replace it with '$SF_USERNAME'?" || return 0
  _lab_edit "$AGENT_FILE" "s|default_agent_user: \"[^\"]*\"|default_agent_user: \"$SF_USERNAME\"|"
  if grep -q "default_agent_user: \"$SF_USERNAME\"" "$AGENT_FILE"; then
    note "✓ Updated."
  else
    warn "Auto-edit failed — fix the line manually."
  fi
}

# ── Stage 5: deploy metadata to the org (confirm gate) ─────────────────────
_lab_stage_deploy() {
  stage "Deploy metadata"
  say "Deploying the agent bundle, flow, Apex, prompt template, and permission"
  say "sets so live action targets (apex://, flow://, prompt://) exist."
  if ! confirm "Push these metadata components to '$ORG_ALIAS' now?"; then
    say "Skipped — live actions won't resolve until deployed."
    return 0
  fi
  ( cd "$AGENT_PROJECT" && sf_deploy "$ORG_ALIAS" ) || return 1
}

# ── Stage 6: smoke test the agent ──────────────────────────────────────────
_lab_stage_smoke() {
  stage "Smoke test (simulated actions)"
  say "Running one preview session against the local .agent file, with"
  say "actions simulated so nothing real executes."
  local reply
  if reply=$(cd "$AGENT_PROJECT" && sf_smoke "$ORG_ALIAS" "$LAB_AGENT_BUNDLE" "What's the weather at the resort today?"); then
    note "Agent reply: ${reply:0:200}"
  else
    warn "Smoke test failed — see the trace at .sfdx/agents/ for diagnosis."
  fi
}

lab_setup_run() {
  # Config: defaults fill any unset LAB_* env var at entry.
  LAB_ORG_ALIAS="${LAB_ORG_ALIAS:-agentlab}"
  LAB_ORG_URL="${LAB_ORG_URL:-https://login.salesforce.com}"
  LAB_AGENT_PROJECT="${LAB_AGENT_PROJECT:-AgentLab}"
  LAB_AGENT_BUNDLE="${LAB_AGENT_BUNDLE:-Local_Info_Agent}"
  LAB_SMOKE="${LAB_SMOKE:-1}"

  # --dry-run: the one obvious developer switch. Selects the fake adapter and
  # makes it fully unattended (stdin at EOF so ask/pause/confirm auto-advance
  # with the wizard's defaults, written to the log as drily-confirmed).
  if [ "${1:-}" = "--dry-run" ]; then
    LAB_SF_ADAPTER="${LAB_SF_ADAPTER:-fake}"
    exec </dev/null
  else
    LAB_SF_ADAPTER="${LAB_SF_ADAPTER:-real}"
  fi

  local adapter_file="$_LAB_ADAPTER_DIR/sf-$LAB_SF_ADAPTER.sh"
  if [ ! -f "$adapter_file" ]; then
    say "No adapter file at $adapter_file (LAB_SF_ADAPTER='$LAB_SF_ADAPTER')." >&2
    return 1
  fi
  source "$adapter_file"

  # Toolchain probe is done by the adapter (the fake passes trivially).
  if ! sf_probe; then
    warn "The Salesforce CLI (sf) is not installed."
    say "Install it, then re-run this wizard:"
    say "  npm install -g @salesforce/cli"
    return 1
  fi

  TOTAL_STAGES=6
  banner "Agentforce test-lab setup"

  _lab_stage_login  || return 1
  _lab_stage_sandbox || return 1
  _lab_stage_scaffold || return 1
  _lab_stage_agent_user || return 1
  _lab_stage_deploy   || return 1
  if [ "$LAB_SMOKE" = "1" ]; then
    _lab_stage_smoke || return 1
  else
    stage "Smoke test (skipped — LAB_SMOKE=0)"
    note "Skipped by request."
  fi

  finish
}