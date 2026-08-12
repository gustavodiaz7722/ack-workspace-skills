# Workflow: Audit Cross-Resource References

Audit one controller, or the whole fleet, for CRD fields that should be cross-resource references but aren't. Fans out one independent auditor per resource, each writing its finding to a file, then merges those files mechanically into one report per controller plus a fleet index.

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
> FINDING_OUT={OUT_DIR}/findings/{alias}/{Kind}.md
> Write your complete finding to FINDING_OUT following roles/schemas/reference-audit-output.md.
> Reply with **only** the header block plus one `GAP: <path> | <target> | <signal> | <confidence>`
> line per gap. Do not reply with the document, the rejected candidates, or the discrepancies.

An auditor needs no model path: the index already carries the resolved description and pattern for every candidate, along with `model_join` saying how each was matched.

**The finding goes to a file and only a summary comes back.** This is the single constraint that makes a fleet run survivable, and it is not an optimization. A finding is long by design — quoted evidence, proposed config, path rationale, caveats — and an orchestrator that lets 268 of them into its context runs out of room before Phase 2 and starts truncating its own audit without saying so. Phase 2 reads the files with `grep`/`awk` instead, so the orchestrator pays for the summary and nothing more.

Create the finding directories before dispatching, so an auditor never fails on a missing path:

```bash
awk '{print $1}' <(cd "$OUT_DIR" && find . -mindepth 2 -maxdepth 2 -name '*.jsonl' \
  | sed 's|^\./||; s|/.*||') | sort -u | while read -r a; do mkdir -p "$OUT_DIR/findings/$a"; done
```

**Dispatch in waves rather than all at once.** The orchestrator is the practical concurrency bound: neither Claude Code nor Kiro documents a sub-agent cap, and a 268-way fan-out is hard to monitor and expensive to redo if the batch is wrong. Launch a wave, collect it, launch the next. Suggested sizing:

| Scope | Resources | Suggested wave |
|-------|-----------|----------------|
| One resource | 1 | 1 |
| One controller | 1–28 | 4–8 |
| Whole fleet | ~268 | 8, batched per controller |

Batch fleet runs **by controller**, so a partial run still yields complete controllers rather than a scattering of half-audited ones, and so a controller's model-unavailable warning applies uniformly to the wave it affects.

### Collecting Results

You do not need to track results yourself: **the presence of a finding file is the record.** Phase 2 derives every verdict and gap from the files, and a resource with a candidate index but no finding file is `NOT_ASSESSED` by construction. Read each auditor's summary to see how the wave went, then move on — do not transcribe the summaries into a running tally, and do not read the finding files to check them.

Three outcomes, all of which survive into the report without any bookkeeping:

| Outcome | How it lands in the report |
|---------|----------------------------|
| Finding written, `PASS` or `FAIL` | that verdict, parsed from the file |
| Finding written, `NOT_ASSESSED` | `NOT_ASSESSED` with the auditor's stated reason |
| Failed, timed out, or wrote nothing | `NOT_ASSESSED` — no file, so the merge reports the resource as unaudited |

**A missing or failed result is never a pass.** An auditor that crashed tells you nothing about the resource, and recording it as clean is a false negative on a resource nobody examined. Retry a failed auditor at most once; if it fails again, leave the file absent and continue — one bad resource must not abort the batch.

One case needs care: an auditor whose dispatch was interrupted may still have written a complete finding before it stopped. Do not assume either way. `merge-reference-findings.sh` treats any file whose header lacks a parsable verdict as `NOT_ASSESSED`, so a partial write cannot be counted as a pass — but a *complete* file from an interrupted auditor is real work and is included. If you interrupted a wave, check which files appeared:

```bash
comm -13 <(sort "$OUT_DIR/.merge/done.txt") <(cd "$OUT_DIR" && find . -mindepth 2 -maxdepth 2 \
  -name '*.jsonl' -not -path './findings/*' | sed 's|^\./||;s|\.jsonl$||' | sort)
```

## Phase 2: Merge (mechanical — do not read the findings)

One command, and it is the only supported way to merge:

```bash
<skills-repo>/scripts/merge-reference-findings.sh "$OUT_DIR"
```

It writes **one report per controller** plus a **thin fleet index**:

```
$OUT_DIR/reports/<alias>.md          per-controller report, findings verbatim
$OUT_DIR/reference-audit-index.md    fleet index: totals, coverage, gap tables, no findings
$OUT_DIR/.merge/                     intermediate TSVs, kept so the numbers are inspectable
```

**Per-controller, not per-fleet.** A single document containing every finding verbatim runs to tens of thousands of lines and nobody can navigate it; the controller is also the unit a fix ships in, since one `generator.yaml` and one `go.mod` belong to one controller. The fleet index carries the cross-controller view — coverage, pooled gap tables, sequencing by target — and deliberately contains no findings, so it stays readable at any scope.

**Do not read a finding to assemble this, and do not hand-write the tables.** Everything is derived by `grep`/`awk` over the files: verdicts and counts from the header block, gap rows from the numbered entries in the Gaps section, `NOT_ASSESSED` from indexes that have no finding file. Deriving it mechanically is what keeps the report from drifting from the findings, and it is what lets the merge cost nothing in context. The script takes the date from `date -u +%F` for the same reason: a model's sense of the current date is unreliable, and a report stamped with the wrong date is hard to place against the `generator.yaml` state it describes.

Two things to check in the output:

- **A parse warning means the tables are incomplete.** If findings declare more gaps in their headers than the merge could parse, some Gaps section does not follow the schema's numbered-entry form. The script says so in the index and on stderr. Fix the finding or note the discrepancy; do not publish the counts as if they reconciled.
- **Controllers with no findings appear in the index as `not audited`** with their full resource count under `NOT_ASSESSED`. That is the intended record of an incomplete run, not a defect.

The merge aggregates; it does not re-judge. No confidence level, target, or caveat is re-evaluated — those belong to the auditor that wrote them. If you want to add cross-cutting analysis (a recommended order across controllers, a defect that shows up in several findings), append it as prose under the index's sequencing section and say it is yours.

## Phase 3: Report

Give the user:

1. **Scope and totals** — resources audited out of total, PASS/FAIL/NOT_ASSESSED counts, gaps by confidence. Take these from the fleet index; do not recount.
2. **The highest-confidence clusters** — a handful of controllers or resources, not the whole table
3. **What was not assessed, and why** — state this plainly rather than burying it. If the run was partial, say so in the first line.
4. **Paths** — the fleet index, and the per-controller reports directory
5. **Suggested next step** — which gap batch to implement first, and that implementing it means editing `generator.yaml`, regenerating, and verifying per `skills/ack-reference-audit/references/cross-resource-references.md`

Do not offer to implement gaps as part of this workflow. Auditing and implementing are separate; a reviewer should see the audit before code changes land.

## Resuming a Partial Run

A stopped run resumes cleanly, because the candidate indexes and the finding files are both on disk. Phase 0 does not repeat, and completed resources are not re-audited.

```bash
# what is left to audit
comm -13 <(cd "$OUT_DIR" && find findings -mindepth 2 -name '*.md' | sed 's|findings/||;s|\.md$||' | sort) \
         <(cd "$OUT_DIR" && find . -mindepth 2 -maxdepth 2 -name '*.jsonl' -not -path './findings/*' \
             | sed 's|^\./||;s|\.jsonl$||' | sort)
```

Dispatch waves over that list, then re-run the merge — it is idempotent and rebuilds every report from whatever findings exist at the time. Prefer finishing a partially-audited controller before starting a new one, so a stopping point always leaves whole controllers behind.

## Claude Code Execution

Each dispatch maps to spawning the `ack-reference-auditor` subagent (`agents/ack-reference-auditor.md`) with the resource's index path and its `FINDING_OUT` path. The main session holds the wave loop only — the findings live on disk, not in the session.

Keep the fan-out one level deep: orchestrator → N auditors. Do not build a per-controller orchestrator that itself fans out per resource; flatten to a single dispatch loop over `(controller, resource)` pairs. Note that per-controller *reporting* is not per-controller *orchestration* — the merge groups by controller after the fact, from one flat dispatch loop.

## Kiro Execution

Kiro runs sub-agents in parallel, each with its own isolated context, and the main agent waits for the batch to finish. No custom agent is required — dispatch with the Phase 1 prompt above and name the role SOP by path, one sub-agent per resource:

```text
Execute the Reference Auditor role at <repo>/roles/reference-auditor.md,
following the schema at <repo>/roles/schemas/reference-audit-output.md.
CONTROLLER_DIR=... RESOURCE=Nodegroup CANDIDATE_INDEX=/tmp/ref-audit/eks/Nodegroup.jsonl
FINDING_OUT=/tmp/ref-audit/findings/eks/Nodegroup.md
Write the finding to FINDING_OUT and reply with only the header block plus GAP lines.
```

Delegation is model-driven from the prompt rather than a CLI flag, so state the unit of work ("one sub-agent per resource, in parallel") explicitly.

Four things to get right:

- **Sub-agents inherit the parent's permissions** but isolate conversation history and context. Auditors read the index, grep/jq over it, and write one file — Phase 0 is the orchestrator's job, not theirs — so pre-approve reads, `grep`/`jq`, and a write to `FINDING_OUT`. A non-interactive sub-agent that hits an approval prompt fails fast rather than waiting.
- **Supervised mode prompts before actions**, so a wide fan-out there is prompt-heavy. Autopilot is the practical mode for a fleet run, though nothing restricts sub-agents to it.
- Kiro's docs do not specify a sub-agent concurrency cap, so treat the wave sizes above as prudence rather than a documented limit, and batch fleet runs per controller regardless.
- **Do not call a file-reading tool on a finding.** This is the failure mode to watch for in Kiro specifically: reading the finding you just dispatched feels like verifying the work, and it is what exhausts the orchestrator. Verify a wave with `ls`/`wc -l` over `findings/` if you want confirmation the files landed, and leave the contents to Phase 2.

Wrapping the role as a Kiro custom agent in `~/.kiro/agents/` would save repeating the SOP path, but it is an optimization, not a prerequisite: note that Kiro custom agents load no skills by default, so such a definition needs an explicit `skill://` resource or it runs without the ACK guidance its SOP depends on.

## Notes

- **The orchestrator's context is the binding constraint on a fleet run, not the auditors'.** Auditors are independent and uniformly thorough however many there are; what fails is the session holding the loop. Both the write-to-file dispatch and the mechanical per-controller merge exist for that one reason. If a fleet run still runs short, stop at a controller boundary, merge, and resume — do not compensate by asking auditors for less depth.
- Phase 0 needs network access for model enrichment. Without it the audit still runs, but nested fields lose their documentation and every finding on a nested field drops in confidence. The merge reports `Model enrichment: N of N` per controller from the findings' own header blocks, so a degraded run is visible rather than implied.
- The audit is idempotent and read-only. Re-running after a `generator.yaml` change is the intended way to verify a fix: the fixed field flips to `is_reference: true` in the index and leaves the gap list.
- This workflow finds fields that *should* be references. Verifying that references *added* by a PR actually resolve on a live cluster is a separate, post-implementation activity with its own live-cluster pass criteria.
