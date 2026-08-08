# Cross-Resource References

How to find CRD fields that should be cross-resource references but aren't, and how to wire them up.

## Contents
- Why References Matter
- Part 1: Identifying Missing References
  - The Candidate Index
  - What the Index Already Handles
  - What the Index Does Not Handle
  - Signal Hierarchy
  - What the Index Is Built From
  - Drilling Into the Model
  - Nested Fields Are Where the Gaps Are
- Part 2: Remediating
  - The generator.yaml Config
  - References Inside a Custom Field
  - Choosing `path`
  - Same-Service vs Cross-Service
  - Cyclic References
  - Nested References Need More Than a `references` Block
  - What Gets Generated
  - Regenerate and Verify
- Gotchas

## Why References Matter

Without a reference, a user must hardcode an AWS identifier in their manifest:

```yaml
spec:
  roleARN: arn:aws:iam::123456789012:role/my-node-role
```

That ARN doesn't exist until the IAM Role is created, so the manifest can't be applied as one unit, can't be moved between accounts, and can't be ordered by the controller. With a `references` block the user points at the Kubernetes resource instead, and the controller resolves the identifier at reconcile time — after confirming the target exists and is `ACK.ResourceSynced=True`:

```yaml
spec:
  roleRef:
    from:
      name: my-node-role
```

A field that holds another AWS resource's identifier and lacks a `references` block is a real usability gap, not a cosmetic one.

## Part 1: Identifying Missing References

### The Candidate Index

`ack-workspace candidates` performs the mechanical narrowing deterministically and emits one compact JSON record per candidate field, so the field set never has to be re-derived by hand:

```bash
# One resource, records on stdout as JSON Lines.
ack-workspace candidates eks --resource Nodegroup

# Every resource of every controller, one <Resource>.jsonl per resource.
ack-workspace candidates all --resource all --out-dir /tmp/ref-audit
```

It reads each controller's CRDs and `generator.yaml` locally and fetches the service's API model itself, resolving `sdk_names.model_name` on the way (`documentdb` → `docdb`) and decoding each model once per controller. There is no separate download step to get wrong, and no AWS credentials, git, or GitHub identity are required. A model that cannot be fetched degrades the index and says so on stderr rather than failing the run — a model outage should cost you confidence on nested fields, not the whole audit.

Records go to stdout and every progress line, suppression note, and degradation warning to stderr, so a plain redirect yields a clean stream.

`--out-dir` is what makes a parallel per-resource audit cheap and reproducible: every auditor starts from identical, already-narrowed input, and two runs over an unchanged repository produce byte-identical files.

Each record carries `resource`, `path`, `type`, `description`, `description_source` (`crd` or `model`), `model_join`, `pattern`, `is_reference`, `reference_target`, `is_immutable`, `is_primary_key`, and — only when the model could not be fetched — `model_unavailable: true`.

Three fields need care:

- **`is_reference` comes only from `generator.yaml`** and is authoritative. The CRD's `*Ref` companions are *not* used to infer it, because sibling fields collapse onto the same companion name — `groupID` and `groupName` both reduce to `groupRef`, so crediting the companion would mark an unconfigured sibling as already done. When it is set, `reference_target` renders the configured target (`iam Role -> Status.ACKResourceMetadata.ARN`), so a wired field doubles as a worked example of the controller's own conventions.
- **`pattern`** is the validation constraint on the member's target shape. An ARN template here names the referenced service and resource type outright and is the strongest signal available.
- **`model_join`** records *how* the model's description and pattern reached the field, and is what tells you how far to trust them. Read the next section before leaning on a `member` join.

### How the Model Join Works, and Why It Matters

The model documentation is resolved by walking the shape graph, not by matching member names. The walk starts at the resource's `Create<Resource>` input, plus every operation a custom field sources `from` and every shape a `custom_field: {list_of: …}` grafts on; it descends structures, unions, and lists; it names each member with `names.New(...).CamelLower`, the same transform the code-generator uses for the CRD's JSON tag; and it applies `generator.yaml` renames scoped to the operation that declares them. A description or pattern reached this way is attributed to the member that actually declares it, and the record carries `model_join: path`.

That distinction is load-bearing, because member names are badly overloaded. Across the models measured, 39.6% of member names carry more than one meaning — `Description` appears with 99 distinct meanings, `State` with 112. A name-based join therefore attaches plausible, well-written, wrong documentation, and it fails silently: nothing in the output looks off. The same applies to `pattern`, which is worse, because an ARN template is the one signal an audit treats as near-conclusive.

Only fields the structural walk cannot reach fall back to the member-name index, and that fallback is restricted to names carrying a single meaning across the entire model, so it is never arbitrary. Those records are labeled `model_join: member`. Fleet-wide, 94.9% of model-contributed records resolve structurally and the remaining 5.1% are labeled.

A `member` join is not wrong, but the field's position did not confirm it. If a finding rests on one, read the real shape before writing it down.

### What the Index Already Handles

These exclusions are mechanical, and `candidates` applies them:

| Handled | How |
|---------|-----|
| Non-string fields | Dropped. An identifier is always a string or a list of strings, so objects, arrays of objects, and non-string scalars are never candidates. Their nested string *leaves* are kept. |
| Nested paths | Walked in full and emitted as dotted paths (`remoteAccess.sourceSecurityGroups`), so nesting is never a reason a field goes unexamined. |
| Document fields | Kept, and judged by you. A reference holds an identifier and a document holds a document, so a field marked `is_document` / `is_iam_policy` is almost never a reference — but dropping it would hide the case where one carries a `references` block anyway, which is a real misconfiguration worth seeing (sqs `Queue.Policy` and sns `Topic.Policy` both do). Reject them on the marking; note it if `is_reference` is also set. |
| Generated `*Ref` wrappers | Dropped. Recognized structurally (an object whose `from` carries `name`), not by name suffix. |
| Already-configured fields | Kept, and flagged `is_reference: true` with their target. They are worked examples of the controller's own conventions — the path form it uses, whether it sets `service_name`. |
| The three-source join | The CRD tree, `generator.yaml` markings, and the model's patterns and nested-member docs arrive already merged. |

### What the Index Does Not Handle

These four categories are not references, but the index cannot recognize them, so they survive into it:

| Not handled | Why it survives |
|-------------|-----------------|
| **Tags** | Modeled as a list of `{key,value}` structs, they appear as string leaves — ecr `Repository` yields `tags.key` and `tags.value`. They vanish only when tags are a `map[string]string`, which is an object. |
| **Enum fields** | ACK emits no enum constraints into the CRD at all — eks `Nodegroup.capacityType` carries only `description` and `type` in its schema — so enum-ness is invisible to the script. The description or the model is the only way to tell. |
| **The resource's own primary key** | `is_primary_key` is not a reliable tell for it: ecr `Repository.name` is flagged, eks `Nodegroup.name` is not, despite both being the resource's own name. Only meaning distinguishes them. |
| **Free-form strings** | `description`, `filter`, arbitrary user labels — indistinguishable from an identifier by type alone. |

**And one blind spot no index can close.** A field listed in `generator.yaml`'s `ignore.field_paths` never reaches the CRD, so it cannot appear in the candidate index however the index is built — and a suppression can be hiding a reference. mq suppresses `CreateBrokerInput.DataReplicationPrimaryBrokerArn`, a Broker→Broker reference; autoscaling suppresses `LaunchTemplate.LaunchTemplateId`, an ec2 LaunchTemplate reference. Across the fleet, 60 controllers use `ignore.field_paths` and 114 of those suppressed fields carry identifier-looking names.

`candidates` prints these to stderr as a `note:` after the per-resource progress lines. An index with no gaps alongside a suppressed ARN field is not a clean resource. Note also that a suppressed field is not fixable with a `references` block at all — un-ignoring it is a separate, larger change, since a reference cannot target a field absent from the CRD.

Two markings are **signals in favor** of a reference, not exclusions:

- **`is_immutable: true`** supports the case. A KMS key, IAM role, parent ID, or subnet is typically set once and cannot change.
- **`is_primary_key: true`** cuts both ways. The resource's own key is not a reference, but a **sub-resource's** primary key frequently is one pointing at its parent. eks `IdentityProviderConfig.ClusterName` carries `is_primary_key: true`, `is_immutable: true`, *and* a `references` block pointing at `Cluster` — all three at once.

### Signal Hierarchy

Ordered by how much confidence each justifies:

| # | Signal | What it looks like | Confidence |
|---|--------|--------------------|------------|
| 1 | **ARN validation pattern** | The API model constrains the field with a `smithy.api#pattern` that is an ARN template naming a service and resource type: `^arn:aws[a-z\-]*:iam::\d{12}:role/...$` | Highest — the pattern names the target outright |
| 2 | **`ARN` suffix + description** | `serviceAccountRoleARN`, described as "the IAM role that provides permissions for..." | High |
| 3 | **`ID` suffix + description** | `vpcID`, `subnetIDs`, described as "The ID of the VPC..." | High |
| 4 | **Description points at another API** | "Use the `DescribeSecurityGroups` API to obtain this value", or a description naming another service | Medium |
| 5 | **`Name` suffix + description** | `cacheSubnetGroupName`, described as naming a specific resource type | Lower — many `Name` fields are the resource's own name |

An ARN pattern is worth more than any name-based guess. When the pattern says `:iam::...:role/`, both `resource: Role` and `service_name: iam` are settled without further reading.

**Signal 1 is high-confidence but low-coverage.** ARN patterns are declared inconsistently across service models — sagemaker has 89 ARN-patterned shapes, lambda and ec2 have 3 each, eks and iam have none at all. **Zero pattern hits therefore carries no information about whether the resource has missing references**; it means only that this signal is unavailable and signals 2–5 are all that remain. Reading an empty pattern query as a clean bill of health is the most common route to a false negative.

**Do not rely on the `aws.api#arnReference` trait either.** It is absent from all but a handful of published service models, so its absence proves nothing.

### What the Index Is Built From

Knowing the provenance matters for weighing a record, and for recognizing a degraded index:

| Source | Path | Contributes |
|--------|------|-------------|
| **CRD** | `helm/crds/*.yaml` | The field tree in camelCase, including nested paths. This is the field set you can actually configure. |
| **generator.yaml** | `generator.yaml` | `is_reference` and its target, `is_immutable`, `is_primary_key`, and the document markings used to exclude. |
| **Smithy API model** | `aws-sdk-go-v2` → `codegen/sdk-codegen/aws-models/<model>.json` | Validation patterns, and **nested member documentation**. |

**The model is what documents nested fields.** ACK propagates descriptions into the CRD only for top-level spec fields; nested members arrive with none at all:

```yaml
remoteAccess:
  description: The remote access configuration to use with your node group...   # present
  properties:
    ec2SshKey:
      type: string                                                             # no description
    sourceSecurityGroups:
      items:
        type: string                                                           # no description
```

Nested fields are exactly where missing references concentrate, so an index built without the model leaves them judgeable only by field name. That is a materially weaker basis, not an equivalent one. `candidates` reports the degradation per controller on stderr and marks every affected record `model_unavailable: true`; treat a resource indexed that way as `NOT_ASSESSED` territory rather than a clean pass.

Do not read a missing `pattern` as the same thing. Whole services publish no ARN patterns — wafv2 constrains every ARN with nothing but `\S` — so signal 1 being unavailable is common and says nothing about enrichment.

**Model file name:** defaults to the controller alias, but `sdk_names.model_name` in `generator.yaml` overrides it — `documentdb-controller` uses `docdb.json`, `cognitoidentityprovider-controller` uses `cognito-identity-provider.json`. `candidates` resolves this itself and reports the name it used on stderr, so don't hand-derive it.

### Drilling Into the Model

The index gives you one description and one pattern per field. Two situations are worth going past it for:

- The record carries **`model_join: member`**, so the field's position did not confirm the description. Read the shape that actually declares the member.
- You need something the record does not carry — the member's `required` status, an enum's member list, a sibling that constrains the field's meaning, or which of several shapes a polymorphic value can name.

Fetch the model once (`candidates` caches its own copy, but a shell needs its own):

```bash
MODEL=$(ack-workspace candidates eks --resource Nodegroup 2>&1 >/dev/null | sed -n 's/.*model=\([a-z0-9-]*\).*/\1/p' | head -1)
curl -sfL "https://raw.githubusercontent.com/aws/aws-sdk-go-v2/main/codegen/sdk-codegen/aws-models/${MODEL}.json" \
  -o "/tmp/${MODEL}.json"
```

Then find the parent shape holding the member and read that member's own constraint and documentation. Match member names **case-insensitively**: models disagree on convention — sagemaker declares `ExecutionRoleArn`, eks declares `nodeRole` — so an exact-case `has()` silently returns nothing on half the fleet:

```bash
# Which parent shapes declare a member of this name?
jq -r --arg m 'noderole' '.shapes | to_entries[]
       | select([(.value.members // {}) | keys[] | ascii_downcase] | index($m))
       | .key' "/tmp/${MODEL}.json"

# For the parent you care about, read its members' targets and docs
jq -r '.shapes["com.amazonaws.eks#CreateNodegroupRequest"].members | to_entries[]
       | "\(.key)\t\(.value.target)\t\((.value.traits // {})["smithy.api#documentation"] // "(none)")"' \
       "/tmp/${MODEL}.json"

# Then the constraint on the target shape itself (patterns live on shapes, not members)
jq -r '.shapes["com.amazonaws.sagemaker#RoleArn"].traits["smithy.api#pattern"]' /tmp/sagemaker.json
```

`candidates` is unaffected by the casing split — it resolves members structurally and normalizes initialisms — but a hand-written `jq` query is not.

Everything else about the index — the candidate list, existing `references` config, nested-member docs, which fields are already wired up — is in the JSONL. Grep that rather than re-deriving it from the CRD; a name-based grep over `helm/crds/` misses nested string leaves whose names don't end in `ARN`/`ID`/`Name` and cannot tell a configured field from an unconfigured one.

### Nested Fields Are Where the Gaps Are

Top-level ARN fields are usually wired up already — they're visible in the CRD's first screen and someone hits them early. The gaps live in nested structures: `vpcConfig.subnetIDs`, `remoteAccess.sourceSecurityGroups`, `podIdentityAssociations.roleARN`.

A live example: cognitoidentityprovider's `UserPool.lambdaConfig` holds a dozen Lambda trigger fields — `createAuthChallenge`, `preSignUp`, `customEmailSender.lambdaARN` — every one of them a Lambda function ARN, every one a plain `type: string` with no description in the CRD, and the controller has no `references:` blocks at all. Nothing about the CRD alone flags these; you find them by reading the model's member documentation.

And "the obvious ones are surely handled" does not hold as an assumption: cognitoidentityprovider has no `references:` blocks anywhere, so in that controller even the top-level fields are unwired.

**A nested field is not harder to configure than a top-level one, including when its parent is a `custom_field`.** Don't discount a gap on feasibility grounds — see [References Inside a Custom Field](#references-inside-a-custom-field). Judge whether the field holds another resource's identifier; the wiring is the same either way.

## Part 2: Remediating

### The generator.yaml Config

```yaml
resources:
  Nodegroup:
    fields:
      NodeRole:
        references:
          resource: Role
          service_name: iam
          path: Status.ACKResourceMetadata.ARN
```

Use the **generator.yaml field path** (the API/Pascal naming, dot-separated for nested fields), not the CRD's camelCase:

```yaml
      ResourcesVpcConfig.SecurityGroupIds:
        references:
          resource: SecurityGroup
          service_name: ec2
          path: Status.ID
```

| Key | Required | Meaning |
|-----|----------|---------|
| `resource` | yes | The Kubernetes resource Kind to read (`Role`, `Cluster`, `Key`) |
| `path` | yes | Where in the target CR to read the identifier from |
| `service_name` | cross-service only | The referenced controller's service. **Omit for same-service.** |
| `skip_resource_state_validations` | rarely | Skip the "target exists and is synced" check. Cyclic references only. |

### References Inside a Custom Field

**A nested member of a `custom_field` can carry a reference, and the generator honors it.** This is worth stating outright because the config looks like it shouldn't work — the parent field is synthesized by ACK rather than lifted from an operation's input shape, so there's a reasonable intuition that field config beneath it has nothing to attach to. That intuition is wrong, and acting on it means declining a valid fix.

ec2's `RouteTable` is the clearest precedent. `Routes` is a custom field, and five of the members inside it are references:

```yaml
  RouteTable:
    fields:
      Routes:
        custom_field:
          list_of: CreateRouteInput
        compare:
          is_ignored: true        # ec2's delta handling for the custom field; unrelated to the references
      Routes.GatewayId:
        references:
          resource: InternetGateway
          path: Status.InternetGatewayID
      Routes.NatGatewayId:
        references:
          resource: NATGateway
          path: Status.NATGatewayID
      Routes.VPCPeeringConnectionID:
        references:
          resource: VPCPeeringConnection
          path: Status.VPCPeeringConnectionID
```

Three things this settles:

- **The key is `<CustomFieldName>.<Member>`**, using the custom field's own name as the root segment and the member name from the shape named in `list_of`.
- **Acronym casing is normalized, so either spelling resolves.** The block above mixes them — `Routes.GatewayId` in raw model casing and `Routes.VPCPeeringConnectionID` in ACK-normalized casing — and both generate. Don't burn time deciding between `RoleArn` and `RoleARN`.
- **Nesting depth is not a limit.** ec2 `SecurityGroup` puts references two levels down inside a custom field: `IngressRules` is `custom_field: {list_of: IpPermission}`, and `IngressRules.UserIDGroupPairs.GroupID` resolves.

The `*Ref` companion lands **inside the list item**, next to the concrete field, not at the top of the spec:

```yaml
spec:
  routes:
    - destinationCIDRBlock: 0.0.0.0/0
      gatewayRef:                 # sits alongside routes[].gatewayID
        from:
          name: my-igw
```

Verify with the resolver name, which is the field path joined by underscores and ACK-normalized:

```bash
grep -o "resolveReferenceFor[A-Za-z_]*" pkg/resource/route_table/references.go
# resolveReferenceForRoutes_GatewayID
# resolveReferenceForRoutes_VPCPeeringConnectionID
```

Fleet-wide there are 11 of these, across ec2 (`RouteTable.Routes.*`, `SecurityGroup.{Ingress,Egress}Rules.UserIDGroupPairs.*`, `NetworkAcl.Associations.SubnetID`) and route53resolver (`ResolverEndpoint.IPAddresses.SubnetID`). Two controllers only, which is why it reads as unprecedented if you go looking casually — but it is established, not experimental.

These subtrees are also the ones the candidate index has to work hardest for: because the parent is synthesized, its members are documented nowhere in the CRD, and `ack-workspace candidates` reaches them only by mounting the named shape onto the field's path prefix.

### Choosing `path`

Match the path to what the field holds:

| Field holds | `path` | Real example |
|-------------|--------|--------------|
| An ARN | `Status.ACKResourceMetadata.ARN` | eks `RoleArn` → iam `Role` |
| An AWS-assigned ID | `Status.<X>ID` | ec2 `Subnet.VpcId` → VPC `Status.VPCID`; lambda `VPCConfig.SubnetIDs` → ec2 Subnet `Status.SubnetID` |
| A user-supplied name | `Spec.Name` or `Spec.<X>Name` | eks `ClusterName` → `Spec.Name`; elasticache `CacheSubnetGroupName` → `Spec.CacheSubnetGroupName` |

Getting this wrong never fails code generation. It fails at runtime, in one of two ways:

- **The path is empty on the target** → `ResourceReferenceMissingTargetFieldFor`. Verify the path exists on the referenced resource's CRD.
- **The path resolves to a different *form* than the Describe response returns** → a delta on every reconcile, and the resource never converges. `ACK.ResourceSynced` stays `Unknown`/`False` while the controller loops issuing updates, even though the AWS resource is fine.

The second is the subtler one. memorydb `Cluster.kmsKeyRef` originally used `path: Status.KeyID`, which resolves to the bare KMS key ID, while `DescribeCluster` returns the full ARN:

```
"diff":[{"Path":{"Parts":["Spec","KMSKeyID"]},
  "A":"d06207a2-14fb-4320-b6b2-be745f6de49a",
  "B":"arn:aws:kms:us-west-2:123456789012:key/d06207a2-14fb-4320-b6b2-be745f6de49a"}]
```

It now uses `Status.ACKResourceMetadata.ARN`. When the target exposes both an ID and an ARN, pick the one the *referencing* resource's Describe echoes back, not whichever looks tidier.

### Same-Service vs Cross-Service

**Omit `service_name` for same-service references.** Setting it — even to the correct value — makes the generator emit an unresolved import alias (`<service>apitypes`) and the controller won't compile.

```yaml
# Same service (backup → backup): NO service_name
BackupPlanID:
  references:
    resource: BackupPlan
    path: Status.ID          # BackupPlan's status field is `id`, not `backupPlanID`

# Cross service (eks → iam): service_name required
RoleArn:
  references:
    service_name: iam
    resource: Role
    path: Status.ACKResourceMetadata.ARN
```

`service_name` is the referenced controller's **Go package name**, which is not always the obvious short form — `opensearchservice`, not `opensearch`.

**A cross-service reference adds a module dependency.** The generated code imports the other controller's `apis/<version>` package, so `go.mod` needs it:

```
github.com/aws-controllers-k8s/iam-controller v1.3.1
```

`make build-controller` does the `go mod tidy`, but the resolved version is a real dependency decision: pin a released tag, and know that you've now coupled this controller's release to that one's API package. RBAC is handled for you — the generator emits `+kubebuilder:rbac` markers granting `get;list` on the referenced resource and its `/status`.

### Cyclic References

When two resources reference each other, the "target must be synced" check deadlocks both: neither can sync until the other does. `skip_resource_state_validations: true` breaks the cycle.

The real case is ec2's `SecurityGroup`, whose rules can name another security group — including itself:

```yaml
  SecurityGroup:
    fields:
      IngressRules:
        custom_field:
          list_of: IpPermission
      IngressRules.UserIDGroupPairs.GroupID:
        references:
          resource: SecurityGroup
          path: Status.ID
          skip_resource_state_validations: true
```

(`IngressRules` is a custom field — this doubles as a precedent for [References Inside a Custom Field](#references-inside-a-custom-field). Don't read the reference here as working *because* the parent is an ordinary list.)

**This transfers an obligation to you.** With validation skipped, the reference resolves against a target that may not exist in AWS yet. You must amend `sdkCreate`/`sdkUpdate` (via hooks) to wait for the referenced resource's desired state before any API call that needs it. ec2-controller's `security_group` is the reference implementation. Don't reach for this flag to silence a sync error that isn't actually cyclic — see [community#2119](https://github.com/aws-controllers-k8s/community/issues/2119).

### Nested References Need More Than a `references` Block

A reference on a **nested** field — `encryptionConfiguration.kmsKey`, `computeConfig.nodeRole` — frequently needs two more pieces of config beyond `references:`. Without them the reference either silently disappears or the resource never converges. Three failure modes look alike (a diff that won't clear), so match the symptom:

| Symptom | Root cause | Fix |
|---------|-----------|-----|
| The `*Ref` vanishes from `.spec` after the first reconcile; the concrete field appears instead | The Create/Update response writes the nested parent struct back into the spec. That response carries the resolved concrete value but *not* the `*Ref`, so the write-back drops the reference. | `set: ignore` on Create and Update |
| `ACK.ResourceSynced` never stabilizes; repeated `desired resource state has changed` on the ref field, with `A` a bare ID and `B` an ARN (or vice versa) | The ref `path` resolves to a different *form* than the Describe response returns | Fix the `path` — almost always `Status.ACKResourceMetadata.ARN` |
| Perpetual diff on a field the user **omitted**, `A: null` vs `B:` an AWS default | A server-side default is read back by `sdkFind` but never captured into the spec | `late_initialize` with `skip_incomplete_check` |

**The first two fixes interact.** `set: ignore` stops the response from clobbering the ref — and by the same token stops AWS-assigned defaults from landing in the spec, which *introduces* the third symptom. Before `set: ignore`, the Create response happened to write the default in and hid the problem. So for a nested ref-backed struct with server defaults you generally need all of it together.

The merged, validated end state from [ecr-controller#158](https://github.com/aws-controllers-k8s/ecr-controller/pull/158):

```yaml
      # 1. Absorb the AWS-assigned default when the whole struct is omitted (nil-parent copy).
      EncryptionConfiguration:
        late_initialize:
          skip_incomplete_check: {}
        # 2. Stop the Create/Update response from clobbering the nested *Ref.
        set:
          - method: Create
            ignore: true
          - method: Update
            ignore: true
      # 3. Absorb the defaulted leaf when the struct is supplied but partial.
      EncryptionConfiguration.EncryptionType:
        late_initialize:
          skip_incomplete_check: {}
      # 4. Reference and late-init on the same field. Safe — see below.
      EncryptionConfiguration.KMSKey:
        late_initialize:
          skip_incomplete_check: {}
        references:
          service_name: kms
          resource: Key
          path: Status.ACKResourceMetadata.ARN
```

**Apply it to every resource carrying the nested ref.** ECR needed the identical block on both `Repository` and `RepositoryCreationTemplate`.

**Why `skip_incomplete_check`:** without it, the generated `incompleteLateInitialization` returns `true` whenever the late-init field is still nil, which requeues every 5s with `ACK.ResourceSynced=False`. For a field that can legitimately stay absent — where AWS returns no default — the resource would never sync. `skip_incomplete_check` drops the field from that check while still performing the copy in `lateInitializeFromReadOneOutput`.

Confirm both halves in the generated code after regenerating:

```bash
# set: ignore worked — sdkCreate must NOT write the struct back into the spec,
# while sdkFind still must (it observes the real value for delta comparison).
awk '/^func \(rm \*resourceManager\) sdkCreate/,/^func \(rm \*resourceManager\) newCreateRequestPayload/' \
  pkg/resource/<resource>/sdk.go | grep -c 'ko.Spec.<Struct> ='     # expect 0

# skip_incomplete_check worked — the field is copied but not gating sync.
grep -c '<Struct>' pkg/resource/<resource>/manager.go                # appears in lateInitializeFromReadOneOutput
sed -n '/func (rm \*resourceManager) incompleteLateInitialization/,/^}/p' \
  pkg/resource/<resource>/manager.go | grep -c '<Struct>'            # expect 0
```

Do not simplify the first check to "no `ko.Spec.<Struct> =` anywhere in `sdk.go`" — there legitimately is one in `sdkFind`, and its absence would be a different bug.

**Late-initializing a field that also has a reference is safe.** It looks like it should populate the concrete value next to the `*Ref` and trip `both resource reference wrapper and ID cannot be used together`. It doesn't, because of reconcile ordering: the runtime calls `ResolveReferences` before late-initialization (`reconciler.go`, `Sync`). When the user supplies the `*Ref`, the concrete field is already populated from the resolved reference by the time late-init runs, and the generated copy guard is `if observed != nil && latest == nil` — so it skips. When the user supplies neither the field nor the ref, `set: ignore` leaves it nil after Create and late-init absorbs the AWS default.

Validate all three inputs, over several reconciles rather than one:

| Input | Expected |
|-------|----------|
| `*Ref` supplied, concrete field absent | ref preserved in spec, concrete field absent, `ACK.ReferencesResolved=True`, no recurring delta |
| concrete value supplied, no ref | value kept as-is, no delta |
| neither supplied | AWS default absorbed via `late_initialize`, no delta, `ACK.ResourceSynced=True` and not stuck in incomplete late-init |

A single reconcile proves nothing here — all three symptoms above are recurring diffs that only show up across cycles. Shorten the resync period and count occurrences of `desired resource state has changed` for the resource; expect zero once converged.

### What Gets Generated

After regeneration, one `references` block produces:

- **A companion `*Ref` field** in the CRD spec, typed `*ackv1alpha1.AWSResourceReferenceWrapper` (or `[]*...` for lists). The name is the field name with its identifier suffix stripped, plus `Ref`/`Refs`: `RoleArn` → `RoleRef`, `SubnetIDs` → `SubnetRefs`, `ClusterName` → `ClusterRef`. A field named *only* an identifier suffix (a bare `ARN`) fails generation — there'd be no name left.
- **`pkg/resource/<resource>/references.go`** with `ResolveReferences`, `ClearResolvedReferences`, `validateReferenceFields`, and a per-field `resolveReferenceFor<Path>`.
- **Runtime validation** enforcing exactly one of the two forms is set: both → `ResourceReferenceAndIDNotSupportedFor`; neither, on a required field → `ResourceReferenceOrIDRequiredFor`.
- **Target state checks**: the target must exist and be `ACK.ResourceSynced=True`, else `ResourceReferenceNotSyncedFor` (requeue) or `ResourceReferenceTerminalFor` (terminal). An empty value at `path` gives `ResourceReferenceMissingTargetFieldFor`.
- **A relaxed CRD `required` list.** An API-required field with a reference is dropped from the OpenAPI `required` set, because either form is now acceptable; the either/or is enforced at reconcile time instead. Verify this happened — if the field is still in `required`, a manifest using only the `*Ref` form will be rejected by the API server.

### Regenerate and Verify

```bash
ack-workspace build <svc>       # or: cd ../code-generator && SERVICE=<svc> AWS_SDK_GO_VERSION=<ver> make build-controller
go build -o bin/controller ./cmd/controller
```

Then confirm each of these:

```bash
git diff apis/v1alpha1/                      # the *Ref field appeared, correct type and cardinality
git diff pkg/resource/<resource>/references.go # resolveReferenceFor<Path> exists for every new reference
git diff helm/crds/                          # *Ref in the CRD; the referenced field left the required list
git diff go.mod                              # cross-service dep added and pinned
```

A compile proves the code generated, not that the reference resolves. Resolution is exercised on a live cluster, not in the e2e suite: the suite installs only the controller under test, so a cross-service reference has no controller to manage its target and the referenced CR would never reach `ACK.ResourceSynced=True`.

Before opening the PR, confirm all of it landed:

```
[ ] references block added with the correct path for each field
[ ] service_name omitted for same-service, set for cross-service
[ ] Regenerated; controller compiles; *Ref fields and references.go present
[ ] Referenced field left the CRD required list
[ ] go.mod updated and pinned for cross-service references
[ ] Nested refs also carry set: ignore (Create/Update) + late_initialize/skip_incomplete_check
[ ] Resolution verified on a live cluster over several reconciles
```

## Gotchas

- **`service_name` on a same-service reference** breaks the build with an unresolved `<service>apitypes` import. The most common mistake, and the error message doesn't point at generator.yaml.
- **Wrong `path`** generates and compiles cleanly, then fails at runtime — empty on the target gives `ResourceReferenceMissingTargetFieldFor`, and the wrong *form* (bare ID where the API returns an ARN) gives a delta that never clears.
- **A nested reference usually needs more than a `references` block.** On its own it may vanish from the spec after one reconcile, or leave the resource in a permanent diff. Pair it with `set: ignore` on Create/Update and `late_initialize` with `skip_incomplete_check`.
- **A `custom_field` parent does not block a reference on its members.** Only ec2 and route53resolver do this today, so it looks unprecedented on a casual grep — it isn't. Nor does acronym casing in the key matter; both `Routes.GatewayId` and `Routes.VPCPeeringConnectionID` resolve.
- **A `Name`-suffixed field is usually the resource's own name.** Require a description that names a *different* resource type before treating it as a reference.
- **Don't add a reference to a document field.** `is_document`/`is_iam_policy` and `references` describe incompatible contents.
- **Immutability is not a disqualifier.** References are frequently immutable; that's a signal in favor.
- **A missing `aws.api#arnReference` trait means nothing.** Most service models never adopted it. Use `smithy.api#pattern` instead.
- **Cross-service references couple release timelines.** Each one pins a version of another controller's API module.

## Related

- [generator.yaml Reference](../../../references/generator-yaml-reference.md) — full field-level option list
- [Code Generation Deep Dive](code-generation.md) — wrapper fields, custom fields that can carry references
- [Testing](testing.md) — E2E test structure for the resource's own CRUD coverage (reference resolution is not covered there)
