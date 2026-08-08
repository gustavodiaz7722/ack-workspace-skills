---
name: ack-workspace
description: >-
  Guide for using the ack-workspace CLI, the tool that automates the fork-first
  contributor workflow for AWS Controllers for Kubernetes (ACK). Use when
  setting up an ACK workspace, adding or removing service controllers, syncing
  forks to upstream, cutting a controller release, regenerating a controller's
  code with the code-generator, building and deploying a controller to a
  cluster, checking repo status, scanning controllers for known issues, or
  building the cross-resource-reference candidate index for a resource.
  Covers every command (init, add, remove, refresh, release, build, deploy,
  status, scan, candidates, config), global flags, configuration,
  prerequisites, and safety behavior.
license: Apache-2.0
metadata:
  author: ACK Team
  version: "1.1.0"
---

# ack-workspace Guide

## Overview

`ack-workspace` is a command-line tool that automates the fork-based contributor
workflow for [AWS Controllers for Kubernetes (ACK)](https://github.com/aws-controllers-k8s).

ACK is spread across dozens of per-service controller repositories plus a few core
repositories, all hosted in the `github.com/aws-controllers-k8s` GitHub org. Contributors
work **fork-first**: fork each repo to a personal account, clone the fork into a Go source
path, and add an `upstream` remote pointing back at the org. `ack-workspace` mechanizes
this end-to-end so dozens of forks stay current without manual effort.

```
GitHub org (aws-controllers-k8s)
   │  fork          ack-workspace
   ▼                     │
your fork (ack-<name>) ──┤ clone → <workspace-root>/<name>/   (origin = your fork)
   ▲  merge-upstream     │                                     (upstream = org repo)
   └─────────────────────┘
```

## Golden Rules

These apply to every command. They are not repeated per section.

- **Destructive commands confirm first.** `refresh` and `remove` discard local state, so
  they require an interactive `yes` (or `--yes`). Work committed on *other* branches is
  left intact.
- **Always preview with `--dry-run` before a destructive or bulk run.** It shows exactly
  what would happen and touches nothing (GitHub, git, filesystem). Dry-run always exits `0`.
- **The token is never persisted.** Provide it via `--token` or `GITHUB_TOKEN`; it is never
  written to the config file.
- **Forks are owned by you.** `remove` only ever deletes a fork under *your* identity; it
  refuses to touch the upstream org.
- **Fork naming:** forks are `<prefix><upstream-name>` (default prefix `ack-`, e.g.
  `ack-s3-controller`). The local checkout dir is the *unprefixed* name (`s3-controller`)
  so it matches the conventional ACK Go import path. The `upstream` remote always points at
  `aws-controllers-k8s/<upstream-name>`.

## Prerequisites

Requires Go 1.26+ and a `git` executable on `PATH`. Each command fails fast with a clear
message if a prerequisite is missing.

| Command  | `git` | GitHub token | GitHub identity | Other |
|----------|:-----:|:------------:|:---------------:|-------|
| `init`   |  yes  |     yes      |       yes       | — |
| `add`    |  yes  |     yes      |       yes       | — |
| `remove` |  yes  |     yes      |       yes       | — |
| `release`|  yes  |     yes¹     |       yes       | code-generator in workspace |
| `deploy` |  yes  |      no      |       no        | AWS creds (may create an EKS cluster), `docker`/`aws`/`kubectl`/`helm`/`eksctl`; code-generator in workspace |
| `build`  |  yes  |      no      |       no        | `make`/`go` toolchain (+ code-generator build deps); code-generator in workspace |
| `refresh`|  yes  |     yes²     |       yes       | — |
| `status` |  yes  |      no      |       no        | — |
| `scan`   |  no³  |      no      |       no        | AWS creds (Bedrock), `grep` |
| `candidates` | no | no | no | network access to the public API models |
| `config` |  no   |      no      |       no        | — |

¹ needs a token to open the upstream PR and identity to name the fork branch; `--skip-pr`
pushes the branch without opening a PR.
² needs token + identity to sync your fork from upstream via the GitHub API.
³ `scan` uses AWS credentials for Bedrock (default credential chain). `GITHUB_TOKEN`, if
present, only raises the rate limit when listing Terraform provider docs.

## Configuration

Settings resolve with this precedence, highest first:

1. command-line flag
2. environment variable (where defined)
3. persisted config file (`$HOME/.ack-workspace/config`)
4. built-in default

| Setting          | Flag                | Env            | Default                                      |
|------------------|---------------------|----------------|----------------------------------------------|
| GitHub identity  | `--github-user`     | `GITHUB_USER`  | _(required)_                                 |
| GitHub token     | `--token`           | `GITHUB_TOKEN` | _(required for init/add; never persisted)_   |
| Workspace root   | `--workspace-root`  | —              | `$GOPATH/src/github.com/aws-controllers-k8s` |
| Fork name prefix | `--prefix`          | —              | `ack-`                                       |
| Concurrency      | `--concurrency`     | —              | `4` (valid range `1`–`32`)                   |
| Preview mode     | `--dry-run`         | —              | `false`                                      |

Persist settings once so you don't repeat them:

```bash
export GITHUB_TOKEN=ghp_xxx
ack-workspace config set --github-user octocat
ack-workspace config get      # print resolved values
ack-workspace config path     # print the config file path
```

---

## Command Reference

### `init` — set up the core repos

Fork, clone, and configure the four core ACK repositories: `runtime`, `code-generator`,
`test-infra`, and `ack-dev-skills`.

```bash
ack-workspace init
ack-workspace init --dry-run
```

`ack-dev-skills` packages the ACK development guidance as an Agent Skill and lands as a peer
next to the other core repos. For Kiro, install it:
`ln -s <workspace-root>/ack-dev-skills/skills/ack-dev ~/.kiro/skills/ack-dev`.

Run `init` before `add`, `release`, or `deploy` — those depend on the core repos (especially
`code-generator`) being present.

### `add` — add service controllers

Fork, clone, and configure one or more service controller repos. Accepts a bare service
alias or the full `<alias>-controller` form.

```bash
ack-workspace add s3 sns
ack-workspace add dynamodb-controller
```

Use the special `all` identifier to set up **every** controller in the ACK org. It discovers
all `*-controller` repos, skips archived ones, and forks/clones/configures each. When `all`
is given it supersedes any other identifiers. Always preview first:

```bash
ack-workspace add all --dry-run   # see the full list
ack-workspace add all
```

`add` with no identifiers is a usage error (exit code `2`).

### `remove` — delete controllers (DESTRUCTIVE)

The inverse of `add`: permanently delete a controller's local clone **and** its GitHub fork.
Accepts a bare alias, the full form, or `all` (every managed controller under the workspace
root). **A deleted fork is gone for good.**

```bash
ack-workspace remove s3
ack-workspace remove s3 sns-controller
ack-workspace remove all
```

Safeguards:
- Only deletes forks owned by **your** identity; never touches the upstream org.
- Prompts for `yes` before deleting. `--yes` skips the prompt (for scripts).
- Repos with uncommitted changes are skipped unless `--force`.
- `--keep-fork` deletes only the local clone, leaving the fork intact.
- `--dry-run` previews without touching anything.

```bash
ack-workspace remove all --dry-run     # preview
ack-workspace remove s3 --keep-fork    # local clone only
ack-workspace remove s3 --yes --force  # non-interactive, even if dirty
```

**Guidance:** always run `--dry-run` first for `remove all`. Prefer `--keep-fork` when you
only want to reclaim local disk. Only use `--force` when you are certain uncommitted changes
are disposable.

### `refresh` — reset repos to a clean upstream baseline (DESTRUCTIVE)

Reconcile managed repositories to a known-good baseline ready for development. For each repo,
`refresh`:

1. syncs your fork's `main` from upstream server-side (GitHub merge-upstream),
2. fetches all upstream tags into the local copy,
3. discards uncommitted changes and untracked files,
4. checks out `main`, and
5. resets `main` to exactly match upstream (and therefore your fork).

```bash
ack-workspace refresh                        # all repos (prompts to confirm)
ack-workspace refresh runtime s3-controller  # a subset
ack-workspace refresh --dry-run              # preview; touches nothing
ack-workspace refresh --yes                  # skip confirmation
```

End state per repo: `main` checked out, fork's `main` up to date with upstream, local `main`
matching both, every upstream tag present locally. This permanently discards uncommitted
changes / untracked files and resets a diverged local `main`, so it confirms unless
`--dry-run` or `--yes`. **Commit or stash work on feature branches first — those branches are
left intact, but uncommitted working-tree changes are discarded.**

### `release` — cut a controller release

Mechanize the ACK controller release workflow for a single service controller. The controller
and `code-generator` must already be in the workspace (`init` + `add` first).

```bash
ack-workspace release ecr --version v1.0.1
```

Steps performed on the controller:
1. update the base branch (`main` by default) from `upstream`,
2. create a branch `release-<version>` (e.g. `release-v1.0.1`),
3. regenerate artifacts via the code-generator's `./scripts/build-controller-release.sh <svc>`
   with `RELEASE_VERSION=<version>`,
4. commit artifacts as `Release artifacts for release <version>`,
5. push the branch to your fork (`origin`), and
6. open a PR against `aws-controllers-k8s/<svc>-controller`.

The service may be a bare alias (`ecr`) or full form (`ecr-controller`). The version is
normalized to carry a leading `v` (`1.0.1` and `v1.0.1` are equivalent). Useful flags:

```bash
ack-workspace release ecr --version v1.0.1 --dry-run                    # preview every step
ack-workspace release ecr --version v1.0.1 --skip-pr                    # push branch, no PR
ack-workspace release ecr --version v1.0.1 --base-branch release-1.x    # non-default base
ack-workspace release ecr --version v1.0.1 --pr-body "$(cat notes.md)"  # custom PR body
```

Safety: a controller with uncommitted changes is skipped; a base branch diverged from
upstream is reported as a failure (never force-updated); an existing `release-<version>`
branch is left untouched; a release that generates no changes is a no-op (no empty commit).

Missing service identifier or invalid version is a usage error (exit code `2`).

### `build` — regenerate a controller's code from local source

Regenerate a single controller's code from its **currently checked-out branch** by running
the code-generator's `make build-controller` target. Use this after editing a controller's
`generator.yaml` or hook templates to regenerate the API types, `delta.go`, controller
logic, CRDs, RBAC, and Helm chart. The controller and `code-generator` must already be in
the workspace (`init` + `add` first), and the `make`/`go` toolchain (plus the
code-generator's own build deps such as `controller-gen` and `helm`) must be on `PATH`.

```bash
ack-workspace build ecr
```

`build` runs `make build-controller SERVICE=<alias>` in the `code-generator` directory
against whatever the controller repo has checked out — it never switches branches or
touches git history. Crucially, it **wires up the environment overrides** the code-generator
scripts otherwise resolve relative to a workspace root literally named `aws-controllers-k8s`
(`RUNTIME_CRD_DIR`, `ACK_GENERATE_BIN_PATH`, `TEMPLATES_DIR`), so the full build succeeds
from any `--workspace-root`. This replaces the manual env-override workaround that used to be
needed for a non-standard workspace root.

The service may be a bare alias (`ecr`) or full form (`ecr-controller`). By default the
aws-sdk-go version is read from the controller's
`apis/<version>/ack-generate-metadata.yaml`; pin it with `--sdk-version`.

```bash
ack-workspace build ecr --dry-run              # print the command that would run; builds nothing
ack-workspace build ecr --sdk-version v1.41.0  # pin the aws-sdk-go version
```

**Run `ack-workspace build <svc>` before committing and opening a PR** whenever a change
touches `generator.yaml`, hook templates, or anything else that affects generated code. The
generated artifacts (API types, CRDs, RBAC, Helm chart) must be regenerated and committed
alongside your source edits, or the PR will be inconsistent. Note that a clean regen bumps
only the `build_date` in `ack-generate-metadata.yaml`; revert that one-line diff
(`git checkout -- apis/<version>/ack-generate-metadata.yaml`) if nothing else changed, to
keep the branch noise-free.

A missing service identifier is a usage error (exit code `2`).

### `deploy` — build and deploy a controller from local source

Build a single controller from its **local implementation branch** and deploy it to the
shared ACK development cluster, `ack-dev-auto`. Use this to test in-progress changes on a real
cluster. The controller and `code-generator` must be present; `docker`, `aws`, `kubectl`,
`helm`, and `eksctl` must be on `PATH`.

The target cluster is fixed and your current kubeconfig context is never used as-is — deploy
repoints the kubeconfig at `ack-dev-auto` every run, and creates the cluster when it is
absent. See [The development cluster](#the-development-cluster) below.

```bash
ack-workspace deploy ecr
```

Steps:
1. resolve your AWS account/region from active AWS credentials,
2. create `ack-dev-auto` if absent, repoint the kubeconfig at it, and ensure the controller's
   service account and pod identity association,
3. ensure an ECR repo (`<svc>-controller` by default) exists, **creating it when absent**,
4. build the image via the code-generator's `./scripts/build-controller-image.sh <svc>`,
   tagging it `<account>.dkr.ecr.<region>.amazonaws.com/<svc>-controller:<HEAD-sha>`,
5. push to ECR (`aws ecr get-login-password` → `docker login` → `docker push`), and
6. `helm upgrade --install ack-<svc>-controller <controller>/helm` into `ack-system`,
   pointing at the freshly pushed image.

By default the image is tagged with the controller's checked-out HEAD short SHA, so each build
is traceable to the exact local commit. Useful flags:

```bash
ack-workspace deploy ecr --dry-run                       # preview; changes nothing
ack-workspace deploy ecr --image-tag dev                 # fixed tag instead of HEAD SHA
ack-workspace deploy ecr --namespace ack-test            # different namespace
ack-workspace deploy ecr --repository my-ecr-controller  # override ECR repo name
ack-workspace deploy ecr --region us-west-2              # target a specific region
ack-workspace deploy ecr --service-account ack-ecr-controller  # bind creds to another account
```

> **Caution:** `deploy` may **create** an ECR repository in your AWS account when one is
> absent, and an EKS cluster when `ack-dev-auto` does not exist. Dry-run first in an account
> you are unsure about.

#### The development cluster

Every deploy targets `ack-dev-auto` in the region resolved from your AWS configuration. The
cluster is **not selectable** and the current kubeconfig context is never used as-is: deploy
repoints the kubeconfig at `ack-dev-auto` on every run, so a deploy cannot land on an
unintended cluster. When the cluster does not exist, deploy creates it first, making the first
run a one-time bootstrap.

What the bootstrap creates (via `eksctl create cluster` with a generated config):

- **EKS Auto Mode cluster** with the `general-purpose` and `system` node pools. Auto Mode
  makes compute, VPC CNI networking, EBS storage, load balancing and CoreDNS built-in
  capabilities, so there are no node groups or addons to maintain. The Pod Identity Agent is
  built in as well — do **not** install the `eks-pod-identity-agent` addon on such a cluster.
- **EKS Pod Identity association** for `ack-system/ack-controller`, bound to IAM role
  `<cluster>-<namespace>-controller`. Pod Identity injects
  `AWS_CONTAINER_CREDENTIALS_FULL_URI` and `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE`, which
  the AWS SDK picks up automatically. No static secret, and no `eks.amazonaws.com/role-arn`
  annotation (that is IRSA, a different mechanism).
- **The shared `ack-controller` service account**, which the controller runs under.
  Associations are keyed on `(namespace, serviceAccountName)` and support no wildcards, so one
  shared account lets a single association cover every controller on the cluster. Pass
  `--service-account` to use a different name and an association is created for that one.

Each step is idempotent: a later deploy only fills in what is missing, so this is also how you
add an association for a service account that lacks one.

```bash
ack-workspace deploy ecr --dry-run               # preview, including any cluster creation
ack-workspace deploy ecr --cluster-version 1.34  # pin k8s version if the cluster is created
ack-workspace deploy ecr --cluster-policy-arn <arn>  # scope the role down
```

`--cluster-version` and `--cluster-policy-arn` apply only when the cluster (or its role) has
to be created; they are ignored once it exists.

> **Caution:** creating the cluster takes 15–25 minutes and creates billable AWS resources
> (EKS cluster, VPC, IAM role). The role gets `AdministratorAccess` by default so any ACK
> controller works in a throwaway dev account — scope it with `--cluster-policy-arn`
> anywhere shared. Verify with
> `aws eks list-pod-identity-associations --cluster-name ack-dev-auto --region <region>` and
> `kubectl exec -n ack-system deploy/<deployment> -- env | grep AWS_CONTAINER`.

Tear down when finished, deleting your custom resources first so the controllers clean up
the AWS resources they created (those do not go away with the cluster):

```bash
eksctl delete cluster --name ack-dev-auto --region us-west-2
```

#### Troubleshooting `deploy`

`deploy` builds and pushes the image **before** it runs `helm`. If a later step fails, the
image is already in ECR (tagged with the HEAD short SHA), so finish the rollout by hand rather
than rebuilding. Confirm the push with
`aws ecr describe-images --repository-name <svc>-controller --image-ids imageTag=<sha>`.

**Helm cannot adopt existing CRDs.** When the cluster already has the service's CRDs installed
via `kubectl apply`, the `helm upgrade --install` step aborts with a field-manager conflict:

```
Error: failed to install CRD crds/...: conflict occurred while applying object ...
Kind=CustomResourceDefinition: Apply failed with 1 conflict:
conflict with "kubectl-client-side-apply" using apiextensions.k8s.io/v1: .spec.versions
```

The push already succeeded, so point the running Deployment at the built image directly (the
container is named `controller`; `deploy` tags with the HEAD SHA):

```bash
TAG=$(git -C <workspace-root>/<svc>-controller rev-parse --short HEAD)
kubectl -n ack-system set image deployment/ack-<svc>-controller \
  controller=<account>.dkr.ecr.<region>.amazonaws.com/<svc>-controller:$TAG
kubectl -n ack-system rollout status deployment/ack-<svc>-controller
```

Do **not** `kubectl delete crd` to clear the conflict — deleting a CRD deletes every custom
resource of that kind on the cluster. To let helm own the CRDs instead, re-apply them
server-side first: `kubectl apply --server-side --force-conflicts -f <crds>`.

**A freshly rolled pod crashes with `ExpiredToken`.** Some dev clusters run the controller with
*static* credentials injected as Deployment env vars
(`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_SESSION_TOKEN`) instead of IRSA. Those are
temporary session credentials; once they expire, any new pod fails at startup while the old pod
keeps running on credentials it cached at boot:

```
unable to determine account info: ... GetCallerIdentity ... api error ExpiredToken
```

Refresh them from your current session without echoing the secret values (the shell expands the
vars, so the values never appear in the command text or output):

```bash
eval "$(aws configure export-credentials --format env)"
kubectl -n ack-system set env deployment/ack-<svc>-controller \
  AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  AWS_SESSION_TOKEN="$AWS_SESSION_TOKEN"
```

**Regenerating code before a deploy.** A change that touches `generator.yaml` or hook
templates needs the code-generator run before `deploy` picks it up. Use `ack-workspace build
<svc>` — it runs `make build-controller` and wires the `RUNTIME_CRD_DIR`,
`ACK_GENERATE_BIN_PATH`, and `TEMPLATES_DIR` overrides so the build works from any
`--workspace-root` (see the `build` command above). This replaces the manual env-override
recipe that was previously required here.

### `status` — inspect workspace state

Report the state of every managed repository (branch, dirty flag, ahead/behind vs. upstream)
as a table or JSON. Read-only; no token or identity needed.

```bash
ack-workspace status
ack-workspace status --json
```

Use `status` before `refresh`/`release` to see which repos are dirty or diverged, and after
bulk operations to confirm the end state. The `--json` output is machine-readable for scripts.

### `scan` — investigate known issues with a Bedrock agent

Run an Amazon Bedrock, tool-using agent that investigates a known issue against a single
resource of a single controller and reports structured findings. Each `(controller, resource,
issue)` triple is one independent agent conversation; any dimension may be `all` to fan out
(conversations run in parallel, bounded by `--concurrency`).

```bash
ack-workspace scan sns --resource Subscription --issue 1   # one triple
ack-workspace scan sns --resource all --issue 1            # every SNS resource
ack-workspace scan all                                     # every issue/resource/controller
```

The agent works from a small sandboxed source set — a pre-filtered index of the resource's
CRD spec fields fused with its `generator.yaml` markings, plus the resource's Terraform
provider docs — searched with `grep`. Each issue defines its own pass/fail rule and reduced
summary:

```
sns/Topic  issue 1 (json-document-fields)  FAIL
    incorrectly marked: dataProtectionPolicy (is none, expected is_document)
    correctly marked: deliveryPolicy, policy
    terraform-only (no CRD field): archive_policy
```

Currently available issues:
- **Issue 1 (`json-document-fields`)** — find CRD fields holding a JSON/YAML or IAM policy
  document that are not marked `is_document` / `is_iam_policy` in `generator.yaml`.
- **Issue 2 (`missing-references`)** — find CRD fields holding an ARN, ID, or Name that
  points at another AWS resource but carry no `references` block in `generator.yaml`.
- **Issue 3 (`embedded-subresources`)** — find nested structures in a CRD that should be
  their own resource.

For issue 2, note the division of labour with [`candidates`](#candidates--emit-the-cross-resource-reference-candidate-index): `scan` decides which fields are references, `candidates` produces the field set it decides over. Use `candidates` when you want the field set itself — to audit it by hand, to split an audit across reviewers, or to diff two runs.

Useful flags:

```bash
ack-workspace scan sns --resource Topic --issue 1 --json                       # full findings
ack-workspace scan sns --resource Topic --issue 1 --debug                      # transcript on stderr (serial)
ack-workspace scan sns --issue 1 --model <bedrock-model-id> --region us-west-2 # pick model/region
```

`--json` emits full findings (each finding's `terraform_field` and `ack_field_path`);
`--debug` prints the complete conversation to stderr, leaving stdout clean. An unknown or
unparsable issue selector is a usage error (exit code `2`).

### `candidates` — emit the cross-resource-reference candidate index

Emit the deterministic candidate index a reference audit starts from: every string-valued
spec field of a resource's CRD, fused with the `generator.yaml` markings that bear on whether
it is a reference (`is_reference` and the configured target, `is_immutable`, `is_primary_key`)
and with the service API model's field documentation and validation patterns.

```bash
ack-workspace candidates eks --resource Nodegroup                     # records on stdout
ack-workspace candidates all --resource all --out-dir /tmp/ref-audit  # one file per resource
```

This is the mechanical half of a reference audit, separated from the judgment. `scan --issue 2`
runs an agent that decides which candidates are references; `candidates` just produces the
field set it decides over — so an audit can be split across independent reviewers who all
start from identical input, and two runs over an unchanged repo produce byte-identical output.

Records are JSON Lines on stdout; per-resource progress, the resolved model name, and the
`ignore.field_paths` suppression notes go to stderr, so a plain redirect gives a clean stream.
With `--out-dir` it writes `<dir>/<alias>/<Resource>.jsonl` instead, which is the form a
parallel audit consumes.

Model documentation is resolved by **walking the model's shape graph** to each field path,
naming members with the same transform the code-generator uses for the CRD's JSON tag. That
matters because nested fields are where reference gaps concentrate and ACK propagates
descriptions into the CRD only for top-level fields — and because member names are heavily
overloaded, so a name-based match attaches plausible, wrong documentation. Each record's
`model_join` says which happened: `path` (walked to that exact field) or `member` (recovered
from the model-wide fallback, which is restricted to names with a single meaning model-wide).

Three lines in the stderr output change what a finding may conclude:

| Line | Meaning |
|------|---------|
| `SKIP` | Declared in `generator.yaml` but no generated CRD — not indexable, so not assessable |
| `model … unavailable` | Nested fields have no description or pattern; records carry `model_unavailable: true` |
| `N identifier-looking field(s) suppressed` | `ignore.field_paths` hides them from every index, and a suppression can hide a reference |

Reads local repos and the public API models: no AWS credentials, git, or GitHub identity, so
unlike `scan` it needs no Bedrock. A model that cannot be fetched degrades the index and says
so rather than failing the run.

### `config` — view and persist settings

```bash
ack-workspace config set --github-user octocat   # persist a setting
ack-workspace config get                          # print resolved values
ack-workspace config path                         # print config file path
```

The config file lives at `$HOME/.ack-workspace/config`. The GitHub token is never written
there regardless of how it was supplied.

---

## Global Flags

Available on all commands (subject to per-command relevance):

- `--dry-run` — preview without making changes (always exits `0`)
- `--github-user <name>` / `GITHUB_USER` — your GitHub identity
- `--token <token>` / `GITHUB_TOKEN` — GitHub token (never persisted)
- `--workspace-root <path>` — override the workspace root
- `--prefix <prefix>` — fork name prefix (default `ack-`)
- `--concurrency <n>` — parallel worker count, `1`–`32` (default `4`); out of range is a
  usage error (exit `2`)

Repositories are processed in parallel with a bounded worker pool; one failing repository
never stops the batch.

## Exit Codes

- `0` — completed and no repository failed (dry-run always exits `0`).
- `1` — a pre-flight error occurred, or at least one repository failed.
- `2` — a usage/validation error (e.g. out-of-range `--concurrency`, `add` with no
  identifiers, missing/invalid `release` version, unknown `scan` issue selector).

---

## Common Workflows

**First-time setup:**
```bash
export GITHUB_TOKEN=ghp_xxx
ack-workspace config set --github-user <you>
ack-workspace init
ack-workspace add s3 sns          # or: add all --dry-run, then add all
```

**Start clean before new work:**
```bash
ack-workspace status              # spot dirty/diverged repos
ack-workspace refresh --dry-run   # preview the reset
ack-workspace refresh <repos>     # reset the ones you want
```

**Regenerate code after a `generator.yaml` or hook change (before committing / opening a PR):**
```bash
ack-workspace build <svc> --dry-run   # preview the make invocation
ack-workspace build <svc>             # regenerate types, CRDs, RBAC, Helm chart
git -C <workspace-root>/<svc>-controller status   # review + commit generated artifacts
```

**Test a local change on a cluster (creates `ack-dev-auto` on first run):**
```bash
ack-workspace build <svc>             # regenerate code if generator.yaml/hooks changed
ack-workspace deploy <svc> --dry-run  # preview, including any cluster creation
ack-workspace deploy <svc>            # ~15-25 min extra the first time
eksctl delete cluster --name ack-dev-auto --region us-west-2   # when finished with the cluster
```

**Cut a release:**
```bash
ack-workspace release <svc> --version v1.2.3 --dry-run
ack-workspace release <svc> --version v1.2.3
```

**Audit controllers for a known issue:**
```bash
ack-workspace scan all --issue 1 --json > findings.json
```

**Reclaim disk / retire a fork:**
```bash
ack-workspace remove <svc> --keep-fork   # local only
ack-workspace remove <svc>               # local + fork (prompts)
```

## Safety Checklist

- Run `--dry-run` before any `remove`, `refresh`, `release`, or `deploy`.
- Run `ack-workspace build <svc>` and commit the regenerated artifacts before opening a PR
  whenever a change touches `generator.yaml`, hook templates, or anything affecting generated
  code.
- Commit or stash feature-branch work before `refresh` (uncommitted changes are discarded).
- For `deploy`, confirm your AWS credentials point at a development account: it creates an
  ECR repository when absent, and — when `ack-dev-auto` does not exist — an EKS cluster, a
  VPC, and an IAM role with `AdministratorAccess`. Dry-run first, and delete the cluster when
  you are done with it. Note that deploy also **rewrites your current kubeconfig context**.
- For `remove`, prefer `--keep-fork` unless you truly want the fork deleted permanently.
- Never expect the token to be saved — always supply it via env/flag.
