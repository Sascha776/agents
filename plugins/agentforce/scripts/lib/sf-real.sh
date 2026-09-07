# ──────────────────────────────────────────────────────────────────────────
# lib/sf-real.sh — adapter #1 for the sf seam. Satisfies the sf_v* contract
# by shelling out to the real Salesforce CLI (sf). Thin on purpose: it owns
# flag marshaling, --json, control-char stripping, and auth; the module owns
# policy and flow.
#
# Contract (shared by both adapters):
#   sf_probe            exit 0 iff sf + python3 available
#   sf_login ALIAS URL  authenticate; 0 on success
#   sf_username ALIAS   print the org username  (0 ok / 1 fail)
#   sf_is_sandbox ALIAS print "true"|"false"    (0 ok / 1 fail)
#   sf_generate NAME    create project NAME/    (0 ok / 1 fail)
#   sf_deploy ORG       deploy cwd as target ORG (0 ok / 1 fail)
#   sf_smoke ORG BUNDLE UTTERANCE REPLY_NAME    run start→send→end, set the
#                        var named REPLY_NAME to the final message; 0 ok / 1 fail
# ──────────────────────────────────────────────────────────────────────────

sf_probe() {
  command -v sf >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1
}

sf_login() {
  local alias="$1" url="$2"
  sf org login web --alias "$alias" --instance-url "$url" --set-default
}

# _real_username ORG: print .result.username, control chars stripped, from
# `sf org display --json`.
sf_username() {
  local alias="$1"
  sf org display --target-org "$alias" --json 2>/dev/null | _lab_json "username"
}

# _real_sandbox ORG: print "true"/"false" from the Organization SOQL query.
sf_is_sandbox() {
  local alias="$1"
  sf data query -q "SELECT IsSandbox, Name, OrganizationType FROM Organization LIMIT 1" \
    --target-org "$alias" --json 2>/dev/null \
    | python3 -c "import json,sys,re; d=json.loads(re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f]','',sys.stdin.read())); print(d.get('result',{}).get('records',[{}])[0].get('IsSandbox', False))" 2>/dev/null || echo false
}

sf_generate() {
  local name="$1"
  sf template generate project --name "$name" --template agent --default-package-dir force-app
}

sf_deploy() {
  local alias="$1"
  sf project deploy start --target-org "$alias" -w 5
}

sf_smoke() {
  local alias="$1" bundle="$2" utterance="$3"
  local session_id send_json final_message

  session_id=$(sf agent preview start --json --authoring-bundle "$bundle" \
    --simulate-actions --target-org "$alias" 2>/dev/null | _lab_json "sessionId")
  if [ -z "$session_id" ]; then
    return 1
  fi

  send_json=$(sf agent preview send --json --session-id "$session_id" \
    --authoring-bundle "$bundle" --utterance "$utterance" --target-org "$alias" 2>/dev/null)
  final_message=$(
    printf '%s' "$send_json" | python3 -c "
import json,sys,re
d=json.loads(re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f]','',sys.stdin.read()))
m=d.get('result',{}).get('messages',[])
print((m[-1].get('message','') if m else ''))
"
  )

  # Always end the session, even if send failed or produced no reply.
  sf agent preview end --json --session-id "$session_id" \
    --authoring-bundle "$bundle" --target-org "$alias" >/dev/null 2>&1 || true

  if [ -z "$final_message" ]; then
    return 1
  fi
  printf '%s\n' "$final_message"
}