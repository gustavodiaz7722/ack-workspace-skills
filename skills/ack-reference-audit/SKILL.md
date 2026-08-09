---
name: ack-reference-audit
description: Audit AWS Controllers for Kubernetes (ACK) service controllers for CRD fields that should be cross-resource references but are not configured with a references block, and wire up the ones that should be. Use when asked to audit a controller or the fleet for missing references, to check whether a field should be reference-backed, or to add a references block to generator.yaml. Requires the ack-workspace CLI.
license: Apache-2.0
metadata:
  author: ACK Team
  version: 1.0.0
---

# ACK Cross-Resource Reference Audit

An ACK cross-resource reference lets a user point one custom resource at another instead of hardcoding an ARN, ID, or name:

```yaml
spec:
  nodeRoleRef:
    from:
      name: my-node-role
```

A CRD field that holds another AWS resource's identifier and has no `references` block in `generator.yaml` forces the user to hardcode a value they cannot know until after the other resource exists. That is the gap this skill finds and closes.

## Prerequisite

This skill depends on the **`ack-workspace` CLI** being on `PATH`. Its `candidates` command builds the deterministic candidate index every audit starts from, and there is no fallback path — see [Why ack-workspace](#why-ack-workspace) for what it does that a standalone script cannot.

```bash
ack-workspace candidates --help
```

If it is missing, build it with `go build .` in the `ack-workspace` checkout.

## The Two Tasks

**Auditing** a resource for references it should have but doesn't, and **wiring one up**, are different jobs with different failure modes. Both live in [references/cross-resource-references.md](references/cross-resource-references.md):

- *Identifying* — the signal hierarchy, what survives the mechanical pre-filter and must be judged by hand, and the blind spots no index can close.
- *Remediating* — choosing `path`, the same-service `service_name` trap, cross-service `go.mod` coupling, cyclic references, references inside a custom field, the compound fix nested references need, and the end-to-end PR flow: `generator.yaml` → `ack-workspace build` → `attribution` → `deploy` → live-cluster validation against four pass criteria.

Read it before doing either. This file does not restate it.

The PR body for a reference-adding change is [references/pr-template.md](references/pr-template.md): the fields added, and the verification that each one resolves.

## Auditing One Resource

```bash
ack-workspace candidates eks --resource Nodegroup
```

Every string-valued spec field, fused with the `generator.yaml` markings that bear on whether it is a reference and with the API model's documentation and validation patterns. Records on stdout as JSON Lines; progress, resolved model name, and suppression notes on stderr.

Then judge each candidate against the signal hierarchy in the reference doc. `is_reference: false` on a field that holds another resource's identifier is the gap.

## Auditing at Scale

One resource at a time, in parallel. The [`audit-references`](../../workflows/audit-references.md) workflow builds every index in one command, fans out one auditor per resource in bounded waves, and merges the findings into one report per controller plus a fleet index. The per-resource unit matters: auditing twenty resources in one conversation degrades badly toward the end, and nothing in the output reveals that it did.

Two rules make a large run finish, and both are about the orchestrator rather than the auditors — auditors stay uniformly thorough however many there are; it is the session holding the loop that fails:

- **Auditors write their finding to a file and reply with a summary.** A finding is long by design, and hundreds of them will not fit in the session that has to merge them.
- **The merge is mechanical and per controller.** `scripts/merge-reference-findings.sh` derives every table from the finding files with `grep`/`awk`, so merging costs no context, and it emits one report per controller because a single fleet-wide document with every finding inline is navigable by nobody.

Findings and indexes are both files on disk, so a run stopped at any point resumes without repeating work — prefer stopping at a controller boundary.

- Auditor SOP: [roles/reference-auditor.md](../../roles/reference-auditor.md)
- Output schema: [roles/schemas/reference-audit-output.md](../../roles/schemas/reference-audit-output.md)
- Merge script: [scripts/merge-reference-findings.sh](../../scripts/merge-reference-findings.sh)
- Claude Code subagent: [agents/ack-reference-auditor.md](../../agents/ack-reference-auditor.md)

## Where the Gaps Actually Are

Top-level ARN fields are usually wired up already — they are visible in the CRD's first screen and someone hits them early. The gaps concentrate in **nested** fields: `vpcConfig.subnetIDs`, `remoteAccess.sourceSecurityGroups`, `lambdaConfig.preSignUp`.

Nested fields are also the ones ACK does not document: descriptions are propagated into the CRD only for top-level spec fields, so a nested member arrives as a bare `type: string`. That is why the audit needs the service's API model, and why the index resolves it for you.

## Three Things That Make an Audit Wrong

- **A resource that could not be indexed is not a passing resource.** `NOT_ASSESSED` and `PASS` are distinct verdicts, and conflating them records a clean bill of health for a resource nobody examined.
- **`generator.yaml` is authoritative for "already configured", not the CRD.** Sibling fields collapse onto one `*Ref` companion name — `groupID` and `groupName` both reduce to `groupRef` — so the CRD cannot tell you which sibling is wired.
- **A suppressed field can hide a reference.** `ignore.field_paths` removes fields from the CRD entirely, so they reach no index by any method. `candidates` reports the identifier-looking ones; carry them into the report, because an empty gap list next to a non-empty suppression list is not a clean resource.

## Why ack-workspace

The index is only as good as its join between a CRD field and the API model member that documents it.

`candidates` resolves that by **walking the model's shape graph** to each field path — starting from the resource's `Create` input plus every operation and shape a custom field draws from, naming members with the same transform the code-generator uses for the CRD's JSON tag, and applying `generator.yaml` renames scoped to their operation. A description or pattern matched this way is attributed to the member that actually declares it.

The alternative, matching on member name, looks equivalent and is not. Across the models measured, 39.6% of member names carry more than one meaning (`Description` appears with 99 distinct meanings, `State` with 112), so a name-based join attaches plausible, well-written, wrong documentation — and it fails silently. It is worse for `pattern`, because an ARN template is the one signal an audit treats as near-conclusive; attaching the wrong one manufactures evidence.

Fields the structural walk cannot reach fall back to a member-name index restricted to names that mean the same thing model-wide, and those records are labeled `model_join: member` so an auditor knows to verify before relying on them. Fleet-wide, 94.9% of model-contributed records resolve structurally.

`candidates` also reads the CRDs and `generator.yaml` locally, fetches and decodes each model once per controller, resolves `sdk_names.model_name` itself, and needs no AWS credentials, git, or GitHub identity.
