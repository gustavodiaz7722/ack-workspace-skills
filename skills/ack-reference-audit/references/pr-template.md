# PR Template: Adding Cross-Resource References

The PR body for a change that adds `references` blocks. Two things carry the review: **what fields were added**, and **the verification that each one resolves on a live cluster**.

Keep it to that. Reviewers need the field list to check the config, and the results table to trust the change was exercised — anything else belongs in the code or in a follow-up comment.

Fill it from the [pass criteria](cross-resource-references.md#pass-criteria) after step 7 of [Cutting the PR](cross-resource-references.md#cutting-the-pr). Every field in the PR appears in the results table, including ones verified in an earlier round.

The delta column is what distinguishes a real verification from a screenshot of the conditions right after create: three of the failure modes only recur across reconciles, so the count has to come from a deploy made with `--resync-period 60` and a window covering at least 3 resyncs.

---

## Template

````markdown
Adds cross-resource references to `<N>` field(s) on `<Resource>`(s) in `<svc>-controller`.

### Fields Added

| # | Field (`generator.yaml` path) | Target | `path` |
| --- | --- | --- | --- |
| 1 | `Nodegroup.NodeRole` | iam `Role` | `Status.ACKResourceMetadata.ARN` |
| 2 | `Nodegroup.ResourcesVpcConfig.SecurityGroupIds` | ec2 `SecurityGroup` | `Status.ID` |

<!-- Note any field needing more than a references block: set: ignore, late_initialize,
     skip_resource_state_validations. Say why. -->

### Verification

Deployed this branch to `<cluster>` (`<region>`) with a 60s resync period
(`ack-workspace deploy <svc> --resync-period 60`) and tested each field. PASS requires all four
conditions, held delta-free across at least 3 reconciles: `ACK.ReferencesResolved=True`,
`ACK.ResourceSynced=True`, concrete field absent from `.spec`, `*Ref` present in `.spec` with
the expected target.

| # | Resource.field | RefsResolved | Synced | Concrete absent | `*Ref` present | Deltas / 3 resyncs | Result |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | `Nodegroup.nodeRoleRef` | ✅ | ✅ | ✅ | ✅ | 0 | **PASS** |
| 2 | `Nodegroup.vpcConfig.securityGroupRefs` | ✅ | ✅ | ✅ | ✅ | 0 | **PASS** |

**Summary: <X>/<Y> PASS** — resync period 60s, delta-free across <N> reconciles (<N> ≥ 3).

<details>
<summary>Test manifest and observed state</summary>

```yaml
# the manifest used, with *Ref set and the concrete field omitted
```

```
# actual kubectl output: conditions, and .spec showing *Ref present / concrete absent
```

</details>

<!-- For a nested or server-defaulted field, add the input matrix you covered:
     *Ref supplied | concrete supplied | neither supplied | parent supplied, leaf omitted -->

### Checklist

- [ ] Workspace refreshed (runtime, code-generator, controller) before generating
- [ ] `service_name` omitted for same-service targets, set for cross-service
- [ ] `path` matches the form the resource's Describe response returns
- [ ] Regenerated with `ack-workspace build <svc>`; controller compiles
- [ ] Generated artifacts committed (`apis/`, `pkg/resource/`, `config/crd/`, `helm/`)
- [ ] `go.mod` updated and pinned (cross-service only)
- [ ] `ATTRIBUTION.md` regenerated (cross-service only)
- [ ] All fields verified against the four pass criteria, delta-free across ≥3 reconciles
````

---

## Rules

- **Actual output, never fabricated.** Paste from the terminal. A results table with no
  supporting output is an assertion, not evidence.
- **Every field in the PR appears in the table.** Not just the ones tested most recently — a
  reviewer cannot tell an untested field from an omitted row.
- **Report partial passes as partial.** Conditions 1, 3, 4 holding with `Synced=False` is
  reportable only when the AWS error proves the resolved value was sent and full sync needs
  infrastructure that cannot be provisioned. Name the error; do not round it up.
- **`FAIL` or `BLOCKED` means no release label.** Applying `/label release/minor` signals the
  change is verified — apply it only once the fields pass. Adding a reference is
  backward-compatible, so `release/minor` is the right label when they do.
- **One results comment per PR if you post results as a comment** — update it in place. Note that
  `gh pr comment` can succeed without printing a URL, so verify before re-running or you will
  create a duplicate.
