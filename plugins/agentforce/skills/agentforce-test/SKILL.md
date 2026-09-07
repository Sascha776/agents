---
name: agentforce-test
description: "Write, run, and analyze structured test suites for Agentforce agents — functional AND security. TRIGGER when: user writes or modifies test spec YAML (AiEvaluationDefinition); runs sf agent test create, run, run-eval, or results commands; asks about test coverage strategy, metric selection, or custom evaluations; interprets test results or diagnoses test failures; asks about batch testing, regression suites, or CI/CD test integration; requests security testing, OWASP LLM Top 10, red-teaming, penetration testing, prompt-injection tests, a security grade, or a vulnerability assessment of an agent. DO NOT TRIGGER when: user creates, modifies, previews, or debugs .agent files (use agentforce-generate); deploys or publishes agents; writes Agent Script code; uses sf agent preview for development iteration; analyzes production session traces (use agentforce-observe); performs a static safety review of .agent file content (use agentforce-generate Section 15)."
allowed-tools: Bash Read Write Edit Glob Grep
metadata:
  relatedSkills:
    - "agentforce-generate"
    - "agentforce-observe"
  version: "0.8"
  domains: ["Agentforce"]
  cliTools:
    - tool: ["curl"]
      semver: ">=7.0.0"
    - tool: ["jq"]
      semver: ">=1.6.0"
    - tool: ["python3"]
      semver: ">=3.10.0"
    - tool: ["sf"]
      semver: ">=2.121.7"
---

# ADLC Test

Automated testing for Agentforce agents: smoke tests, batch suites, and OWASP LLM Top 10 security testing. Functional correctness (right topic, right action) and security posture (resists attacks) are two dimensions of the same test suite — when you plan tests, plan security tests too. Security test-case generation is gated on explicit user confirmation (see `## Security gate`).

## Pick a mode

| You want... | Mode |
|---|---|
| Quick smoke test during authoring, or validate a fix | **Mode A** — `sf agent preview` |
| A persistent regression suite / CI/CD truth | **Mode B** — `sf agent test` (Testing Center) |
| A persistent, re-runnable security regression suite | **Mode C1** — security cases deployed like Mode B |
| Deep pre-sign-off red team with an A–F grade | **Mode C2** — security cases live over preview |

**Action execution** — direct REST invocation of a single Flow/Apex action, bypassing the agent runtime (see the `## Action execution gate` below).

## Run everything from the project directory

Shell examples are bash; on Windows use PowerShell/Git Bash equivalents and `python` for `python3`. The CLI requires `sfdx-project.json` in the working directory. `--authoring-bundle` compiles the local `.agent` file and must appear on `start`, `send`, and `end`; the action-mode flag (`--simulate-actions` / `--use-live-actions`) is valid on `start` **only**.

**Mode A — preview (one session per scenario):**
```bash
SID=$(sf agent preview start --json --authoring-bundle MyAgent --simulate-actions -o <org> 2>/dev/null | jq -r '.result.sessionId')
sf agent preview send --json --session-id "$SID" --utterance "test" --authoring-bundle MyAgent -o <org>
sf agent preview end --json --session-id "$SID" --authoring-bundle MyAgent -o <org>
```

**Mode B — batch:**
```bash
sf agent test create --json --spec tests/<AgentApiName>-testing-center.yaml --api-name <SuiteName> -o <org>
sf agent test run --json --api-name <SuiteName> --wait 10 --result-format json -o <org>
```

**Mode C — security** (content only after the `## Security gate` confirms):

- **C1-author** — write the spec and validate locally: `sf agent test create ... --preview -o <org>`. Nothing deploys, nothing executes.
- **C1-run** — `sf agent test create` (no `--preview`) then run exactly as Mode B. **No simulate mode exists on `test run`** — every case executes real Apex/Flows/Prompt Templates.
- **C2** — one fresh preview session per case, `--simulate-actions` by default: send the user turns only, judge each response, score A–F, report inline.

Present the plan first — never auto-run tests without showing what will be tested.

## Security gate (required)

Never generate or run security test cases without explicit user confirmation. Verify the org is a sandbox **before** presenting the gate; the full prompt template and option list live in `references/security-test-design.md`:

```bash
sf data query -q "SELECT IsSandbox, Name, OrganizationType FROM Organization LIMIT 1" -o <org> --json
```

Fail closed: a failed/missing query is treated as production; `IsSandbox: false` means stop, report the org type, and **do not offer C1-run or C2** — an override is a separate, explicit user ask. Proceed only as far as the option the user picks: `C1-author` does not authorize deploy, and neither it nor a bare "yes" authorizes `test run`.

## Action execution gate (required)

Before invoking any action over REST: confirm the org is a sandbox for production orgs (warn + require confirmation), warn on write operations (CREATE/UPDATE/DELETE), and use synthetic test data only — never real PII. Mechanics: `references/action-execution.md`.

## Verdicts are completion criteria

- **Mode A** ends with a **SAFETY VERDICT** — SAFE / UNSAFE / NEEDS_REVIEW. UNSAFE: prominent warning, fixes, flag not deployment-ready.
- **Mode C2** ends with the **grade line** (`Grade: X (n/100) — PASSED|FAILED — k critical, j high, i medium`) plus per-category subtotals; every FAIL carries severity, the surface exercised, a response excerpt, and remediation.
- **Mode B / C1** report each case's `output_validation`; guardrail runs ignore the empty `topic_assertion` FAILURE.
- Trace files land in `.sfdx/agents/{BundleName}/sessions/{sessionId}/traces/`. **Strip control characters before every JSON parse** (`python3` `re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f]', ...)`) — `jq` chokes on sf's raw output.

## References

- `references/preview-testing.md` — Mode A: case planning, preview execution, trace analysis, fix loop, voice-agent checks
- `references/batch-testing.md` — Mode B: full spec schema, key rules, deploy/run, result parsing, topic resolution, known bugs
- `references/security-test-design.md` — Mode C: read the `.agent`, name the domain, map surface to cases, write/validate the C1 spec, confirmation gate, C2 procedure
- `references/security-scoring-methodology.md` — A–F scoring, severity weights, thresholds, worked example
- `references/owasp-categories.md` — per-category judging guidance
- `references/security-troubleshooting.md` — C-mode runs: session issues, rate limits, INCONCLUSIVE, multi-turn context
- `references/remediation-guide.md` — fixing neutral-catalog failures by category
- `references/action-execution.md` — REST invocation, integration testing, debugging
- `references/test-report-format.md` — summary, coverage analysis, CI/CD, cross-skill integration with `/agentforce-observe`
- `references/troubleshooting.md` — CLI issues, defensive JSON parsing, dependencies (`sf` 2.131.0+ floor), exit codes