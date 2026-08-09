# Reference Audit Output Schema

Three documents, at three levels:

1. **Per-resource finding** — what one Reference Auditor writes for one resource. Written to a file; the auditor's reply is only a summary.
2. **Per-controller report** — one document per controller, carrying that controller's findings verbatim.
3. **Fleet index** — one navigation document per run, carrying totals and pooled gap tables and no findings.

Levels 2 and 3 are **generated**, not written by hand: `scripts/merge-reference-findings.sh` derives them from the finding files with `grep`/`awk`. The schemas below are therefore a description of that output and a contract the finding files must satisfy for it to parse — not a template anyone types.

This schema covers the **pre-implementation** audit: which fields *should* be references. It is not the post-implementation manual test report for a PR that *adds* references — that has its own PR-comment template and live-cluster pass criteria.

## Why the split

A run of any size produces findings that are long by design: each quotes its evidence, proposes config, justifies the `path`, and attaches caveats to the gap they qualify. That is the right shape for one resource and the wrong shape to accumulate.

- **The finding goes to a file.** An orchestrator that lets hundreds of findings into its context exhausts it before merging and truncates its own audit without saying so.
- **The report is per controller.** A fleet-wide document with every finding inline runs to tens of thousands of lines and is navigable by nobody. The controller is also the unit a fix ships in: one `generator.yaml`, one `go.mod`, one PR.
- **The index carries no findings.** It stays readable whether the run covered three resources or three hundred.

---

## Part 1: Per-Resource Finding

One auditor, one resource, one document, written to `FINDING_OUT`. Emit exactly this structure.

**Two parts of it are machine-parsed, so their form is load-bearing:** the header block (verdict and counts) and the numbered gap entries with their `Target:` / `Signal:` / `Confidence:` bullets (the gap tables). Deviate from either and the merge cannot see your work — a finding with an unparsable header is recorded as `NOT_ASSESSED` rather than as your verdict, and a gap written as prose is absent from every table. Everything else in the document is prose for a human reader and its wording is yours.

### Header

```
## Resource: <Controller>/<Kind>
- **Verdict:** PASS | FAIL | NOT_ASSESSED
- **Candidates examined:** N (from the candidate index)
- **Already configured:** N
- **Gaps found:** N
- **Model available:** yes | no
```

**Verdict rules — read these literally.**

| Verdict | When |
|---------|------|
| `PASS` | Every candidate was examined **and** no unconfigured field is judged to be a cross-resource reference. |
| `FAIL` | At least one unconfigured field is judged to be a cross-resource reference. |
| `NOT_ASSESSED` | The audit could not be completed: no candidate index, no CRD, the index was empty because the resource has no generated CRD, or the auditor ran out of budget partway. |

`NOT_ASSESSED` is **not** a pass. An audit that could not run must never be reported as a resource with nothing wrong — that is a silent false clean on a resource nobody actually looked at. If you examined only part of the candidate list, the verdict is `NOT_ASSESSED` and you must say which paths you did not reach.

An empty candidate index is `NOT_ASSESSED` when it is empty because the CRD is missing, and `PASS` only when the resource genuinely has no string-valued spec fields.

### Gaps

One entry per unconfigured field judged to be a reference. Omit the section when there are none.

```
### Gaps

1. `<ack.field.path>`
   - **Target:** <resource> in <service>   (or: unidentified)
   - **Signal:** arn_pattern | arn_suffix | id_suffix | doc_mention | name_suffix
   - **Confidence:** high | medium | low
   - **Evidence:** <the pattern, or the description sentence that establishes it — quote it>
   - **Proposed config:**
     ```yaml
     <GeneratorYaml.Field.Path>:
       references:
         resource: <Kind>
         service_name: <svc>   # omit for same-service
         path: <Status.ACKResourceMetadata.ARN | Status.<X>ID | Spec.Name>
     ```
   - **Path rationale:** <why that path matches the form the API echoes back>
   - **Caveats:** <omit when there are none — anything that makes this gap not a
     drop-in `references` block: a polymorphic target where only one Kind can be
     wired, a hand-written hook that would drop the `*Ref` companion, a
     code-generator limitation, or a prerequisite change in another repo>
```

Rules for gap entries:

- **`Caveats` belongs on the gap, not in `Discrepancies`.** A gap that is real but not fixable by adding a `references` block alone is the most expensive kind to mis-file: an implementer picks it up expecting a one-line change. Keeping the blocker attached to the entry means it cannot be read separately from the gap it qualifies.

- **Evidence must be quoted, not summarized.** "Description says it's an IAM role" is not evidence; the sentence is.
- **`service_name` must be omitted for same-service references.** Emitting it is a compile error, so a proposed config that includes it for a same-service target is itself a defect in the finding.
- **Confidence maps to the signal**, not to enthusiasm. An ARN pattern naming the target service is `high`. A bare `Name` suffix with a plausible-sounding description is `low`.
- **Order gaps by confidence, highest first.**

### Already Configured

A single line listing paths, for cross-checking. No detail needed.

```
### Already Configured
`spec.roleARN` → iam Role, `spec.subnets` → ec2 Subnet
```

### Rejected Candidates

Unconfigured candidates you examined and judged **not** to be references. This section is what makes a `PASS` verifiable — without it, a reviewer cannot tell a thorough audit from a lazy one.

```
### Rejected Candidates
- `spec.description` — free-form user text
- `spec.engineVersion` — version string, not a resource identifier
- `spec.clusterName` — this resource's own primary key
```

Group trivial rejections onto one line when there are many; spell out any rejection that was a close call.

### Discrepancies

Anything that needs a human eye, including index anomalies. Omit when empty.

```
### Discrepancies
- `egressRules.userIDGroupPairs.groupName` — a `groupRef` companion exists in the CRD
  but generator.yaml marks only `groupID`. Sibling fields collapse onto one companion
  name, so the CRD cannot say which of them is configured. Confirm whether groupName
  was intended to be reference-backed.
```

---

## Part 2: Per-Controller Report

`$OUT_DIR/reports/<alias>.md`, one per controller that had at least one finding. Generated.

```markdown
# Cross-Resource Reference Audit: <alias>

- **Controller:** `<alias>-controller`
- **Date:** <YYYY-MM-DD — from `date -u +%F`, not from memory>
- **Resources audited:** N of N
- **Model enrichment:** N of N audited resources

> **Coverage is incomplete for this controller.** N of N resources were not assessed.
> `NOT_ASSESSED` is not `PASS` — see the Not Assessed table.
  (emitted only when something was not assessed)

## Summary

| Verdict | Count |
|---------|-------|
| PASS | N |
| FAIL | N |
| NOT_ASSESSED | N |

**Total gaps:** N across N resources (high: N, medium: N, low: N)

| Resource | Verdict | Candidates | Configured | Gaps |
|---|---|---:|---:|---:|
| Nodegroup | FAIL | 34 | 3 | 2 |

## Gaps by Confidence

### High Confidence

| Resource | Field Path | Target | Signal |
|---|---|---|---|
| Nodegroup | `launchTemplate.id` | ec2 LaunchTemplate | id_suffix |

### Medium Confidence / ### Low Confidence
<same table>

## Not Assessed

| Resource | Reason |
|---|---|
| Bar | no auditor completed for this resource |

## Recommended Sequencing

| Target | Gaps | Referencing controllers |
|---|---:|---|
| Role in iam | 3 | eks |

## Per-Resource Findings

<the full per-resource documents, verbatim, alphabetical by Kind>
```

The per-resource findings are reproduced **verbatim**. The tables above them are navigation, not a replacement — a reader who wants the evidence for a gap scrolls to its finding in the same file.

## Part 3: Fleet Index

`$OUT_DIR/reference-audit-index.md`, one per run. Generated. **Contains no findings.**

```markdown
# Cross-Resource Reference Audit — Fleet Index

- **Date:** <YYYY-MM-DD>
- **Resources audited:** N of N across N controllers
- **Controller reports:** N (in `reports/`)

> **This run is incomplete.** N of N resources were not assessed. ...
  (emitted only when something was not assessed)

## Summary
<verdict counts; total gaps by confidence>

> **Parse warning:** findings declare N gaps in their headers but N gap entries were parsed. ...
  (emitted only on a mismatch — see Generation Rules)

## Coverage by Controller

| Controller | Audited | PASS | FAIL | NOT_ASSESSED | Gaps | Report |
|---|---:|---:|---:|---:|---:|---|
| eks | 8 of 8 | 6 | 2 | 0 | 5 | [`reports/eks.md`](reports/eks.md) |
| ec2 | 0 of 20 | 0 | 0 | 20 | — | _not audited_ |

## Fleet Gaps by Confidence
<the same three tables, with a Controller/Resource column>

## Fleet Sequencing by Target

| Target | Gaps | Referencing controllers |
|---|---:|---|
| Function in lambda | 21 | cognitoidentityprovider, bedrockagent, apigateway, ... |

## Phase 0
<index count, SKIP count, model-unavailable count, controllers with suppressed fields>

## How to read this
<states that numbers are derived mechanically and judgment belongs to the auditors>
```

A controller with no findings appears with `0 of N` and `_not audited_`. That is the record of an incomplete run and must not be omitted — a controller absent from this table would read as a controller with nothing wrong.

### Generation Rules

These are enforced by `merge-reference-findings.sh`; they are documented here because they determine what the reports can and cannot claim.

- **Never read a finding to assemble a report.** Everything is derived from the files by `grep`/`awk`. This is what keeps the reports from drifting from the findings, and what makes merging free in context.
- **Never synthesize a verdict for a resource that produced nothing.** A resource with a candidate index and no finding file is `NOT_ASSESSED`. A finding file whose header has no parsable verdict is also `NOT_ASSESSED` — a partial write cannot be promoted to a pass. Do not retry silently and report only the success.
- **Reconcile the gap count.** Gap rows are parsed from the numbered entries; the header blocks separately declare a gap count. If the two disagree, some finding does not follow Part 1's structure — emit the parse warning rather than publishing counts that do not add up.
- **Do not re-judge findings.** The merge aggregates and sequences; it does not upgrade or downgrade a confidence level, retarget a gap, or drop a caveat. Cross-cutting analysis added by the orchestrator is appended as prose and attributed as its own.
- **Count gaps, not fields.** One field with two plausible targets is one gap with the alternatives noted.
- **Take the date from `date -u +%F`.** A report stamped from memory is hard to place against the `generator.yaml` state it describes.
