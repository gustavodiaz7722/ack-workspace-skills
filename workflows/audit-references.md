# Workflow: Audit Cross-Resource References

Audit one controller, or the whole fleet, for CRD fields that should be cross-resource references but aren't. Fans out one independent auditor per resource and merges the findings into a single report.

This is a **read-only audit**. It produces findings and proposed config; it changes nothing.

## Trigger

Invoked when asked to audit references / find missing `references` blocks / check a controller for reference gaps. Requires:

- **WORKSPACE_ROOT**: directory containing the controller repos
- **CONTROLLER**: controller alias, or `all`
- **RESOURCE**: resource Kind, or `all` (default `all`)
- **OUT_DIR**: where candidate indexes and the report are written (default `/tmp/ref-audit`)

Prerequisite: the `ack-workspace` binary on `PATH`. Phase 0 depends on it and there is no fallback — build it with `go build .` in the `ack-workspace` checkout if it is missing.

## Why Fan Out Per Resource

One resource is the natural unit: its candidate set is self-contained, findings don't interact across resources, and a wide controller like ec2 or sagemaker would otherwise blow a single context. Auditing 20 resources in one conversation degrades badly toward the end — the last resources get a fraction of the attention the first ones did, and nothing in the output reveals that. Independent auditors get uniform attention per resource, and a failure is isolated to one resource instead of truncating the rest.

## Phase 0: Build the Candidate Indexes (deterministic, do this first)

**Do not skip this and let auditors derive their own field lists.** The index is what makes parallel auditing both cheap and reproducible: every auditor starts from identical, already-narrowed input, and two runs over an unchanged repo produce the same candidate set.

One command builds every index, for one controller or the whole fleet:

```bash
OUT_DIR=${OUT_DIR:-/tmp/ref-audit}

ack-workspace candidates "${CONTROLLER:-all}" \
  --resource "${RESOURCE:-all}" \
  --out-dir "$OUT_DIR" \
  --workspace-root "$WORKSPACE_ROOT" \
  2> "$OUT_DIR/phase0.log"
```

It writes `$OUT_DIR/<alias>/<Resource>.jsonl` per resource and everything else — the per-resource progress lines, the model name it resolved, suppression notes, degradation warnings — to stderr, captured above so Phase 2 can cite it.

There is nothing to fetch by hand. The command resolves `sdk_names.model_name` itself (`documentdb` → `docdb`, `cognitoidentityprovider` → `cognito-identity-provider`), fetches and decodes each model once per controller, and needs no AWS credentials, git, or GitHub identity. Do not build the indexes any other way; the field paths it emits come from the same name transform the code-generator uses, and a hand-rolled equivalent will not line up with the CRD.

**Read `phase0.log` before dispatching. Three lines in it change what an auditor may conclude:**

| Line | Meaning | Consequence |
|------|---------|-------------|
| `SKIP` | Declared in `generator.yaml` but no generated CRD | The resource enters the report as `NOT_ASSESSED`. It is not audited and not passing. |
| `note: <alias>: model … unavailable` | Nested fields have no description or pattern | Every resource of that controller is judgeable by field name alone. Say so in the report; do not present those as thorough passes. |
| `note: <alias>: N identifier-looking field(s) suppressed` | `ignore.field_paths` removes those fields from the CRD | They can never appear in any index, and a suppression can hide a reference. Carry the list into the report so an empty gap list is not read as clean. |

For the full fleet expect 268 indexes across 70 controllers, in about 20 seconds. A count well below that means controllers were missed — check `--workspace-root`.

## Phase 1: Dispatch Auditors in Bounded Waves

For each resource index, dispatch one **Reference Auditor** (`roles/reference-auditor.md`):

> Execute the Reference Auditor role at roles/reference-auditor.md.
> CONTROLLER_DIR={CONTROLLER_DIR} RESOURCE={Kind}
> PHASE0_LOG={OUT_DIR}/phase0.log
> CANDIDATE_INDEX={OUT_DIR}/{alias}/{Kind}.jsonl
> Produce a per-resource finding following roles/schemas/reference-audit-output.md.

An auditor needs no model path: the index already carries the resolved description and pattern for every candidate, along with `model_join` saying how each was matched.

**Dispatch in waves rather than all at once.** The orchestrator is the practical concurrency bound: neither Claude Code nor Kiro documents a sub-agent cap, and a 268-way fan-out is hard to monitor and expensive to redo if the batch is wrong. Launch a wave, collect it, launch the next. Suggested sizing:

| Scope | Resources | Suggested wave |
|-------|-----------|----------------|
| One resource | 1 | 1 |
| One controller | 1–28 | 4–8 |
| Whole fleet | ~268 | 8, batched per controller |

Batch fleet runs **by controller**, so a partial run still yields complete controllers rather than a scattering of half-audited ones, and so a controller's model-unavailable warning applies uniformly to the wave it affects.

### Collecting Results

For each auditor, record the finding **and** whether it returned usably. Three outcomes, all of which must survive into the report:

| Outcome | Record as |
|---------|-----------|
| Structured finding, `PASS` or `FAIL` | that verdict |
| Structured finding, `NOT_ASSESSED` | `NOT_ASSESSED` with the auditor's stated reason |
| Failed, timed out, or unparseable | `NOT_ASSESSED` with the failure reason |

**A missing or failed result is never a pass.** An auditor that crashed tells you nothing about the resource, and recording it as clean is a false negative on a resource nobody examined. Retry a failed auditor at most once; if it fails again, record `NOT_ASSESSED` and continue — one bad resource must not abort the batch.

## Phase 2: Merge

Assemble the merged report per `roles/schemas/reference-audit-output.md`:

1. Verdict counts, including `NOT_ASSESSED`.
2. Gaps pooled across resources, grouped by confidence, highest first.
3. The `Not Assessed` table — mandatory whenever any resource did not complete.
4. Per-resource findings verbatim.
5. Recommended sequencing, batched by target service (each cross-service target adds one `go.mod` dependency, so one PR per target service keeps dependency changes reviewable).

Write to `$OUT_DIR/reference-audit-report.md`.

The orchestrator aggregates; it does not re-judge. Do not upgrade or downgrade a confidence level you did not investigate yourself.

## Phase 3: Report

Give the user:

1. **Scope and totals** — resources audited, PASS/FAIL/NOT_ASSESSED counts, total gaps by confidence
2. **The highest-confidence gaps** — a handful, not the whole table
3. **What was not assessed, and why** — state this plainly rather than burying it
4. **Report path**
5. **Suggested next step** — which gap batch to implement first, and that implementing it means editing `generator.yaml`, regenerating, and verifying per `skills/ack-reference-audit/references/cross-resource-references.md`

Do not offer to implement gaps as part of this workflow. Auditing and implementing are separate; a reviewer should see the audit before code changes land.

## Claude Code Execution

Each dispatch maps to spawning the `ack-reference-auditor` subagent (`agents/ack-reference-auditor.md`) with the resource's index path. The main session holds the wave loop and the collected findings.

Keep the fan-out one level deep: orchestrator → N auditors. Do not build a per-controller orchestrator that itself fans out per resource; flatten to a single dispatch loop over `(controller, resource)` pairs.

## Kiro Execution

Kiro runs sub-agents in parallel, each with its own isolated context, and the main agent waits for the batch to finish. No custom agent is required — dispatch with the Phase 1 prompt above and name the role SOP by path, one sub-agent per resource:

```text
Execute the Reference Auditor role at <repo>/roles/reference-auditor.md,
following the schema at <repo>/roles/schemas/reference-audit-output.md.
CONTROLLER_DIR=... RESOURCE=Nodegroup CANDIDATE_INDEX=/tmp/ref-audit/eks/Nodegroup.jsonl
```

Delegation is model-driven from the prompt rather than a CLI flag, so state the unit of work ("one sub-agent per resource, in parallel") explicitly.

Three things to get right:

- **Sub-agents inherit the parent's permissions** but isolate conversation history and context. Auditors only read the index and grep/jq over it — Phase 0 is the orchestrator's job, not theirs — so pre-approve reads plus `grep`/`jq`. A non-interactive sub-agent that hits an approval prompt fails fast rather than waiting.
- **Supervised mode prompts before actions**, so a wide fan-out there is prompt-heavy. Autopilot is the practical mode for a fleet run, though nothing restricts sub-agents to it.
- Kiro's docs do not specify a sub-agent concurrency cap, so treat the wave sizes above as prudence rather than a documented limit, and batch fleet runs per controller regardless.

Wrapping the role as a Kiro custom agent in `~/.kiro/agents/` would save repeating the SOP path, but it is an optimization, not a prerequisite: note that Kiro custom agents load no skills by default, so such a definition needs an explicit `skill://` resource or it runs without the ACK guidance its SOP depends on.

## Serial Execution (no sub-agent support)

If you are running somewhere without delegation, the fan-out becomes a serial loop, and two things change:

1. **Re-read `roles/reference-auditor.md` before each resource** and treat each as a fresh audit. The role's scope boundary is doing real work — it stops resource N's findings from bleeding into resource N+1.
2. **Cap the batch.** Serial auditing degrades as context fills. Audit at most 5–8 resources per session, write the findings out, then start a new session. A session that tries to audit all 20 ec2 resources produces thorough findings for the first few and increasingly thin ones after, with nothing in the output revealing it.

The candidate indexes are files on disk, so a batch interrupted at any point resumes cleanly — Phase 0 does not need repeating.

## Notes

- Phase 0 needs network access for model enrichment. Without it the audit still runs, but nested fields lose their documentation and every finding on a nested field drops in confidence. Record `Model enrichment: no` in the report rather than pretending the coverage is equivalent.
- The audit is idempotent and read-only. Re-running after a `generator.yaml` change is the intended way to verify a fix: the fixed field flips to `is_reference: true` in the index and leaves the gap list.
- This workflow finds fields that *should* be references. Verifying that references *added* by a PR actually resolve on a live cluster is a separate, post-implementation activity with its own live-cluster pass criteria.
