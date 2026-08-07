# Reference Audit Output Schema

Two documents, at two levels:

1. **Per-resource finding** — what one Reference Auditor returns for one resource. This is the handoff payload when audits run in parallel.
2. **Merged audit report** — what the orchestrator assembles from all per-resource findings.

This schema covers the **pre-implementation** audit: which fields *should* be references. It is not the post-implementation manual test report for a PR that *adds* references — that has its own PR-comment template and live-cluster pass criteria.

---

## Part 1: Per-Resource Finding

One auditor, one resource, one document. Emit exactly this structure.

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
```

Rules for gap entries:

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

## Part 2: Merged Audit Report

What the orchestrator assembles. One document per audit run, whatever its scope.

```markdown
# Cross-Resource Reference Audit

- **Scope:** <controller|all> / <resource|all>
- **Date:** <YYYY-MM-DD>
- **Resources audited:** N
- **Model enrichment:** N of N resources

## Summary

| Verdict | Count |
|---------|-------|
| PASS | N |
| FAIL | N |
| NOT_ASSESSED | N |

**Total gaps:** N across N resources (high: N, medium: N, low: N)

## Gaps by Confidence

### High Confidence

| Controller/Resource | Field Path | Target | Signal |
|---------------------|-----------|--------|--------|
| eks/Nodegroup | `launchTemplate.id` | ec2 LaunchTemplate | id_suffix |

### Medium Confidence
<same table>

### Low Confidence
<same table>

## Not Assessed

Resources whose audit did not complete, and why. **This section must never be omitted or
left empty when there are NOT_ASSESSED resources** — it is the record of what the run does
not tell you.

| Controller/Resource | Reason |
|---------------------|--------|
| foo/Bar | no generated CRD in helm/crds |

## Per-Resource Findings

<the full per-resource documents, in scope order>

## Recommended Sequencing

Group gaps into implementable units. Reference work batches naturally by target service,
because each cross-service target adds one `go.mod` dependency:

1. **<controller>: N gaps targeting iam Role** — one PR, adds `iam-controller` dep
2. **<controller>: N same-service gaps** — one PR, no new deps
```

### Orchestrator Rules

- **Never synthesize a verdict for a resource that returned nothing.** A sub-agent that failed, timed out, or came back unparseable is `NOT_ASSESSED` with the failure reason recorded. Do not retry silently and report only the success.
- **Do not re-judge findings.** The orchestrator aggregates and sequences; it does not upgrade or downgrade a confidence level it did not investigate.
- **Preserve per-resource documents verbatim.** The summary tables are navigation, not a replacement.
- **Count gaps, not fields.** One field with two plausible targets is one gap with the alternatives noted.
