---
name: ack-workspace
description: >-
  Guide for using the ack-workspace CLI, the tool that automates the fork-first
  contributor workflow for AWS Controllers for Kubernetes (ACK). Use when
  setting up an ACK workspace, adding or removing service controllers, syncing
  forks to upstream, cutting a controller release, regenerating a controller's
  code with the code-generator, building and deploying a controller to a
  cluster, checking repo status, regenerating a controller's ATTRIBUTION.md, or
  building the cross-resource-reference candidate index for a resource.
  Covers every command (init, add, remove, refresh, release, build, deploy,
  status, candidates, attribution, config), global flags, configuration,
  prerequisites, and safety behavior.
license: Apache-2.0
metadata:
  author: ACK Team
  version: "1.2.0"
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
- **Always preview with `--dry-run` before a destructive or bulk run.** It shows what would
  happen and changes nothing — no GitHub, git, filesystem, or cloud mutation. Read-only
  lookups still run (resolving your AWS account, checking whether the cluster exists) so the
  preview reflects reality. Dry-run always exits `0`.
- **The token is never persisted.** Provide it via `--token` or `GITHUB_TOKEN`; it is never
  written to the config file.
- **Forks are owned by you.** `remove` only ever deletes a fork under *your* identity; it
  refuses to touch the upstream org.
- **Fork naming:** forks are `<prefix><upstream-name>` (default prefix `ack-`, e.g.
  `ack-s3-controller`). The local checkout dir is the *unprefixed* name (`s3-controller`)
  so it matches the conventional ACK Go import path. The `upstream` remote always points at
  `aws-controllers-k8s/<upstream-name>`.

## Prerequisites

Requires Go 1.26+ to build. Every command declares what it needs and it is all verified
**before any work starts**; several missing things produce one error naming all of them.

| Command  | Executables on `PATH` | GitHub token | GitHub identity | Also needed (not pre-flighted) |
|----------|-----------------------|:------------:|:---------------:|--------------------------------|
| `init`   | `git` | yes | yes | — |
| `add`    | `git` | yes | yes | — |
| `remove` | `git` | yes | yes | — |
| `refresh`| `git` | yes¹ | yes | — |
| `release`| `git` | yes² | yes | code-generator in workspace + its build deps |
| `build`  | `git`, `make`, `go` | no | no | code-generator in workspace |
| `deploy` | `git`, `docker`, `aws`, `kubectl`, `helm`, `eksctl`³ | no | no | AWS creds (may create an EKS cluster); code-generator in workspace |
| `test`   | `git`, `kubectl`, `python3`⁵ | no | no | AWS creds; the controller already deployed on the cluster |
| `status` | `git` | no | no | — |
| `attribution` | `git` | no | no | AWS creds (CodeBuild, S3) |
| `candidates` | — | no | no | network access to the public API models⁴ |
| `config` | — | no | no | — |

¹ needs token + identity to sync your fork from upstream via the GitHub API.

² needs a token to open the upstream PR and identity to name the fork branch; `--skip-pr`
pushes the branch without opening a PR.

³ `eksctl` is required even though `deploy` only uses it when the cluster must be created —
better to know before a 20-minute image build than after.

⁴ `candidates` uses no AWS credentials and shells out to nothing. `GITHUB_TOKEN`, if present,
only raises the rate limit on the API model fetches.

⁵ `test` needs `git` because the suites pin `acktest` as a git URL that `pip` resolves by
cloning, and `python3` to build the virtual environment the suite runs from. `pytest` is not
checked: it lives inside that environment, not on your `PATH`.

**AWS credentials, and anything else needing a network round-trip, are not pre-flighted.** An
expired session surfaces when the command runs, not up front; keeping the check hermetic is
what makes it free to run every time.


## Configuration

Settings resolve with this precedence, highest first:

1. command-line flag
2. environment variable (where defined)
3. workspace-local config file (`<workspace-root>/.ack-workspace/config`)
4. global config file (`$HOME/.ack-workspace/config`)
5. built-in default

| Setting          | Flag                | Env            | Default                                      |
|------------------|---------------------|----------------|----------------------------------------------|
| GitHub identity  | `--github-user`     | `GITHUB_USER`  | _(none; required only by the commands that name a fork — see Prerequisites)_ |
| GitHub token     | `--token`           | `GITHUB_TOKEN` | _(none; required by the commands that call the GitHub API; never persisted)_ |
| Workspace root   | `--workspace-root`  | —              | the enclosing workspace-local config's directory, else `$GOPATH/src/github.com/aws-controllers-k8s` |
| Fork name prefix | `--prefix`          | —              | `ack-`                                       |
| Concurrency      | `--concurrency`     | —              | `4` (valid range `1`–`32`)                   |
| Preview mode     | `--dry-run`         | —              | `false`                                      |

Only the GitHub identity and token have environment variables. The workspace root, prefix,
and concurrency come from a flag or a config file — so a per-directory `.envrc` cannot set
them, and a wrapper that injects `--workspace-root` is not needed either now that
workspace-local config files exist.

Persist settings once so you don't repeat them:

```bash
export GITHUB_TOKEN=ghp_xxx
ack-workspace config set --github-user octocat
ack-workspace config get      # print resolved values and the file they came from
ack-workspace config path     # print the config file in effect here
```

### Several workspaces on one machine

The two layers are what let more than one workspace coexist. The global file holds what every
workspace shares — usually just your identity — and a workspace-local file overrides it for
work anywhere inside that tree. Commands run from any directory under a workspace pick up its
configuration automatically, with no `--workspace-root` on the command line.

Create one from the workspace root:

```bash
cd ~/ack-workspace
ack-workspace config set --local                      # inherit everything, just pin the root
ack-workspace config set --local --concurrency 8      # ...or override a value for this workspace
```

That writes `~/ack-workspace/.ack-workspace/config`. From then on, anywhere inside that tree:

```bash
cd ~/ack-workspace/s3-controller
ack-workspace config get
# workspace-root: /home/you/ack-workspace
# config-file:    /home/you/ack-workspace/.ack-workspace/config (workspace-local)
```

Rules worth knowing, because each one is load-bearing:

- **The file's location defines the workspace root.** A local file needs no `workspace_root`
  key, and `config set --local` deliberately omits it, so the workspace keeps working if the
  directory is moved or renamed. Set `workspace_root` explicitly only when a config has to
  describe a tree it does not live in.
- **The layers merge per value, not wholesale.** A local file setting only `concurrency` still
  inherits `github_user` and `repo_prefix` from the global file. A local file containing
  nothing but comments is valid and useful: its mere presence pins the root.
- **The local file's location outranks the global file's `workspace_root`.** Standing inside a
  workspace is the stronger signal, which is what makes a second workspace reachable without
  flags.
- **The nearest file wins** when directories nest, and `$HOME/.ack-workspace/config` is always
  the global layer — never treated as workspace-local, so running from `$HOME` does not make
  `$HOME` the workspace root. That check resolves symlinks, which matters when `$HOME`
  (`/home/you`) and its real path (`/local/home/you`) differ, as on cloud desktops.
- **`config get` names the file** the persisted values came from and tags it `global` or
  `workspace-local`. Reach for it whenever a command targets an unexpected tree.

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
next to the other core repos. For Kiro, install it with `scripts/install-skills.sh` from an
`ack-workspace-skills` checkout, not a bare `ln -s` of the skill directory: ack-dev links to
`../../references/`, which only resolves once the script has linked that directory beside the
skills directory.

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

Like `build`, step 3 **wires up the environment overrides** the release script otherwise
resolves relative to a workspace root literally named `aws-controllers-k8s`
(`ACK_GENERATE_BIN_PATH`, `TEMPLATES_DIR`), so a release cuts correctly from any
`--workspace-root`. Without them the script aborts immediately with `Unable to find an
ack-generate binary` even when the binary is present at
`<root>/code-generator/bin/ack-generate`. `--dry-run` prints the resolved overrides, which is
the quickest way to confirm they point into your workspace.

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

**Retrying a failed release means deleting its branch first.** The branch is created in step 2,
before the generation in step 3, so a failure from step 3 onwards leaves it behind — and the
next run then *skips* on `release branch "release-<version>" already exists` rather than
retrying. Confirm it carries no commits (`git log --oneline <base>..release-<version>`) and
delete it before re-running:

```bash
git -C <workspace-root>/<svc>-controller checkout <base>
git -C <workspace-root>/<svc>-controller branch -d release-<version>
```

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

Build a single controller from your **local checkout** and deploy it to the
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

**Steps 4 and 5 are skipped when the tag is already in ECR**, and the existing image is deployed
instead — see [Image reuse](#image-reuse) below.

By default the image is tagged with the controller's checked-out HEAD short SHA, so each build
is traceable to the exact local commit. Useful flags:

```bash
ack-workspace deploy ecr --dry-run                       # preview; changes nothing
ack-workspace deploy ecr --region us-west-2              # target a specific region
ack-workspace deploy ecr --resync-period 60             # resync every 60s instead of the chart's 10h
```

#### Fixed destination

The ECR repository (`<svc>-controller`), the namespace (`ack-system`), the Helm release
(`ack-<svc>-controller`), and the service account (`ack-controller`) are all fixed. **None is
selectable.**

The namespace and service account could not be flags even if they were wanted, because they are the
two halves of one key: a pod identity association is keyed on exactly one
`(namespace, serviceAccount)` pair with no wildcards, so credentials reach a controller only if its
install matches the association on both. One shared account is what lets a single association cover
every controller on the cluster; deployed under any other — including the per-service account the
chart creates by default — a controller starts with no credentials and exits with `unable to
determine account info`.

Fixing the repository and release removes a subtler failure: two deploys of one controller
disagreeing about where it lives, leaving a second ECR repository with a divergent image history or
a parallel Helm release.

#### Image reuse

A deploy is **identified by its commit**, and two rules with no opt-out make that true:

- The image tag is always the controller's checked-out HEAD short SHA. There is no tag override.
- The working tree must be clean. **A controller with uncommitted changes is refused** (exit `1`).

So the tag is a complete description of the image's source. A tag already in ECR therefore
*proves* an image built from exactly this source exists, and `deploy` **skips the build and push**
and installs it. Redeploying a commit — retrying after a failed `helm` step, or changing a chart
value like the resync period — costs a rollout instead of a full image build, with no flag to
remember.

```
ecr-controller  failed  ecr-controller has uncommitted changes; commit them so the deployed
                        image tag identifies the source it was built from
```

The refusal is the point, not an inconvenience. With a dirty tree the SHA names the commit and not
the edits on top of it, so a deploy would either bake unversioned source into a tag that claims to
be the commit, or — once that commit had been built before — reuse the older image and silently
validate code you had just changed. Both report success. Committing is the fix; there is
deliberately no force-rebuild flag, because a flag to work around the ambiguity is worse than not
having the ambiguity.

Two further consequences of deciding by fact rather than assumption:

- **A failed lookup stops the deploy.** Expired credentials or no network means build-or-reuse
  cannot be answered, and guessing either way would reintroduce exactly the silence this design
  removes. Only a definitive `ImageNotFoundException` or `RepositoryNotFoundException` counts as
  "absent".
- **`--dry-run` runs the lookup** (it is read-only) and reports which way it went, so a preview
  says either `build ... from local source, push it` or `reuse the existing image ... (already in
  ECR, no build or push)`. It refuses a dirty tree too, rather than printing a plan naming a tag
  that does not describe the tree.

**`--resync-period` sets the controller's reconcile cadence** (`reconcile.defaultResyncPeriod`
on the chart, in seconds). The chart default is 36000 — ten hours — which makes any behavior
that only appears *across* reconciles effectively unobservable in a test session: a
cross-resource reference whose resolved value differs in form from what the Describe response
returns, or a server-side default that is never captured into the spec, both manifest as a
delta that reappears on each resync. Shortening the period to 60 turns a ten-hour wait into
minutes, which is what makes "no delta after N reconciles" a check you can actually run.

It belongs on the deploy rather than a follow-up `helm upgrade` because deploy installs the
chart with its **default** values: an override applied beforehand is discarded by the install,
and one applied afterwards costs a second rollout. Omit the flag and the chart default stands;
a negative value is a usage error (exit `2`). Note that `0` is not accepted as "use the
default" — the chart guards the controller argument with `gt (int ...) 0`, so an explicit zero
would disable periodic resync entirely.

Keep it out of anything long-lived. A 60-second resync means every managed resource is
re-reconciled every minute, which multiplies AWS API calls and invites throttling once more
than a handful of resources exist.

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
  shared account lets a single association cover every controller on the cluster. This is why the
  account is fixed rather than selectable — see [Fixed destination](#fixed-destination).

**The cluster is meant to be long-lived.** Create it once and keep it. Every provisioning step
is idempotent, so each later deploy only fills in what is missing — which is also how you add
an association for a service account that lacks one — and skips the 15–25 minute creation
entirely, leaving just build, push, and install. Multiple controllers coexist on it, sharing
one namespace, service account, and association.

```bash
ack-workspace deploy ecr --dry-run               # preview, including any cluster creation
ack-workspace deploy ecr --cluster-version 1.34  # pin k8s version if the cluster is created
ack-workspace deploy ecr --cluster-policy-arn <arn>  # scope the role down
```

`--cluster-version` and `--cluster-policy-arn` apply only when the cluster (or its role) has
to be created, so they are ignored once it exists. Changing either afterwards means editing the
resource directly, or deleting it and letting the next deploy recreate it.

> **Caution:** the first deploy takes 15–25 minutes and creates billable AWS resources (EKS
> cluster, VPC, IAM role), and a long-lived cluster keeps costing while it runs — keep it in a
> development account you are happy to leave running. The role gets `AdministratorAccess` by
> default so any ACK controller works without further setup — scope it with
> `--cluster-policy-arn` anywhere shared.

Verify the association and that its credentials reached the pod. Read the injected variables
from the pod spec — the controller image is distroless, so `kubectl exec ... -- env` fails with
`"env": executable file not found`:

```bash
aws eks list-pod-identity-associations --cluster-name ack-dev-auto --region <region>
kubectl -n ack-system get pod -l app.kubernetes.io/instance=ack-<svc>-controller \
  -o jsonpath='{range .items[0].spec.containers[0].env[*]}{.name}{"\n"}{end}' | grep AWS_CONTAINER
```

To delete it, remove your custom resources first so the controllers clean up the AWS resources
they created (those do not go away with the cluster):

```bash
eksctl delete cluster --name ack-dev-auto --region us-west-2
```

#### Troubleshooting `deploy`

`deploy` builds and pushes the image **before** it runs `helm`. If a later step fails, the
image is already in ECR (tagged with the HEAD short SHA), so the cheapest fix is to just re-run
`deploy`: it finds the tag, skips the build and push, and goes straight to the rollout. Confirm
the push with
`aws ecr describe-images --repository-name <svc>-controller --image-ids imageTag=<sha>`.

**Helm cannot adopt existing CRDs.** When the cluster already has the service's CRDs installed
via `kubectl apply`, the `helm upgrade --install` step aborts with a field-manager conflict:

```
Error: failed to install CRD crds/...: conflict occurred while applying object ...
Kind=CustomResourceDefinition: Apply failed with 1 conflict:
conflict with "kubectl-client-side-apply" using apiextensions.k8s.io/v1: .spec.versions
```

The push already succeeded, so point the running Deployment at the built image directly. Select
it by label rather than by name: the chart names the Deployment
`ack-<svc>-controller-<svc>-chart` (release name plus chart name), not `ack-<svc>-controller`.
The container inside it *is* named `controller`, and `deploy` tags with the HEAD SHA:

```bash
SEL=app.kubernetes.io/instance=ack-<svc>-controller
TAG=$(git -C <workspace-root>/<svc>-controller rev-parse --short HEAD)
kubectl -n ack-system set image deployment -l "$SEL" \
  controller=<account>.dkr.ecr.<region>.amazonaws.com/<svc>-controller:$TAG
kubectl -n ack-system rollout status deploy -l "$SEL"
```

Do **not** `kubectl delete crd` to clear the conflict — deleting a CRD deletes every custom
resource of that kind on the cluster. To let helm own the CRDs instead, re-apply them
server-side first: `kubectl apply --server-side --force-conflicts -f <crds>`.

**`deploy` stops with `exec credential API client.authentication.k8s.io/v1alpha1`.** The
`aws` that resolves first on `PATH` is too old: AWS CLI v1 releases such as 1.18 write the
`v1alpha1` exec API into the kubeconfig, and their `aws eks get-token` emits it too, while
kubectl 1.24 and later only accept `v1beta1` or `v1`. Older ack-workspace builds missed this
and failed one step later with `exec plugin: invalid apiVersion
"client.authentication.k8s.io/v1alpha1"` from `kubectl create namespace`, or helm's `no kind
"ExecCredential" is registered for version ... v1alpha1`. Editing the kubeconfig does not
help, because `deploy` rewrites the entry every run. Put AWS CLI v2 first and re-run:

```bash
which -a aws                                   # e.g. /usr/bin/aws (v1) ahead of /usr/local/bin/aws (v2)
export PATH="/usr/local/bin:$PATH" && aws --version   # expect aws-cli/2.x
ack-workspace deploy <svc>
```

Agent shells are the usual cause: they rebuild `PATH` without your profile, so a system v1 in
`/usr/bin` can win even when your interactive shell finds v2. Note that `deploy` also selects
`ack-dev-auto` as the current context; switch back with `kubectl config use-context <previous>`
when you are done.

**The controller exits at startup with `unable to determine account info`.** It has no AWS
credentials, which under Pod Identity means the pod was admitted without the association's
env vars being injected — either no association covers its `(namespace, serviceAccount)` pair,
or the pod predates the association. Note that credentials are *not* static env vars here;
there is nothing to refresh.

Check whether the webhook acted on the pod:

```bash
SEL=app.kubernetes.io/instance=ack-<svc>-controller
kubectl -n ack-system get pod -l "$SEL" \
  -o jsonpath='{.items[0].metadata.labels.eks\.amazonaws\.com/pod-identity}{"\n"}'
```

`enabled` means the injection happened; empty means it did not. Then confirm the association
exists and which account it covers:

```bash
aws eks list-pod-identity-associations --cluster-name ack-dev-auto --region <region>
kubectl -n ack-system get deploy -l "$SEL" \
  -o jsonpath='{.items[0].spec.template.spec.serviceAccountName}{"\n"}'
```

If the association exists but the label is empty, the pod started first — restart it so the
webhook runs on a fresh pod. If no association covers `ack-system/ack-controller`, re-run
`deploy`: it ensures the association on every run, so a cluster missing one is repaired rather
than needing manual setup.

```bash
kubectl -n ack-system rollout restart deploy -l "$SEL"
```

**Reconciliation fails with `AccessDenied` while the controller is otherwise healthy.** The
credentials are reaching the pod; the pod identity role simply lacks permission for that
service's API. This is the expected outcome of scoping the role with `--cluster-policy-arn`.
Check what the role carries:

```bash
aws iam list-attached-role-policies --role-name ack-dev-auto-ack-system-controller
```

**Regenerating code before a deploy.** A change that touches `generator.yaml` or hook
templates needs the code-generator run before `deploy` picks it up. Use `ack-workspace build
<svc>` — it runs `make build-controller` and wires the `RUNTIME_CRD_DIR`,
`ACK_GENERATE_BIN_PATH`, and `TEMPLATES_DIR` overrides so the build works from any
`--workspace-root` (see the `build` command above). This replaces the manual env-override
recipe that was previously required here.

### `test` — run a controller's end-to-end suite

Run a single controller's `test/e2e` suite against the controller **already running** on the
development cluster: create the suite's AWS fixtures with `service_bootstrap.py`, run pytest
over the suite, then delete those fixtures with `service_cleanup.py`.

```bash
ack-workspace test acm
```

`test` is the follow-on to `deploy`, never a replacement: it does not build an image, create a
cluster, or install a controller. It confirms three things before running anything, and reports
what it found:

| Check | Not satisfied |
|-------|---------------|
| The kubeconfig selects `ack-dev-auto` | skipped, naming the `deploy` to run |
| The cluster answers a read | failed |
| The controller has a ready replica in `ack-system` | skipped, naming the `deploy` to run |

The cluster is not selectable, for the same reason it is not on `deploy`: where a suite ran is
the one thing its output cannot tell you afterwards, so a suite pointed at the wrong cluster
fails in ways that read like product bugs. The readiness check exists because without the
controller running, every test fails on a timeout and the report says nothing about why.

The service may be a bare alias (`acm`) or full form (`acm-controller`). Useful flags:

```bash
ack-workspace test acm --dry-run                # print the commands; provision nothing
ack-workspace test acm --methods test_invalid   # one test by name
ack-workspace test acm --markers canary         # by pytest marker
ack-workspace test acm --threads 4              # fewer xdist workers, when AWS throttles
ack-workspace test acm --region eu-west-1       # pin where the suite creates resources
ack-workspace test acm --skip-cleanup           # keep the fixtures to inspect a failure
```

Several `--markers` or `--methods` values become one pytest expression (`canary or slow`)
rather than repeated flags, which pytest resolves by keeping only the last.

**The Python environment lives outside the controller checkout**, at
`$HOME/.ack-workspace/venvs/<service>-controller`: created on the first run, reused after, and
reinstalled automatically when the suite repins its requirements (tracked by a digest of
`requirements.txt`). The documented ACK setup puts a `.venv` inside `test/e2e`, but a
controller's `.gitignore` does not cover it, so an in-checkout environment leaves untracked
files that `status` reports as dirty and `deploy` refuses outright. An existing
`test/e2e/.venv` **is** used when already present, so a hand-built environment is not
duplicated.

**The outcome is pytest's alone**, so a failure always means a test failed. Fixtures are torn
down even when tests fail, and after a failed bootstrap that may have created part of them; a
teardown that itself fails is reported in the summary, naming the AWS resources that may
remain, rather than folded into the outcome.

A suite that a repository does not have (around a tenth of the controllers carry no `test/e2e`
directory) is a skip, not a failure. A missing service identifier is a usage error (exit
code `2`).

> **Caution:** a suite creates real AWS resources in the account your credentials resolve to
> and deletes them on teardown — run it against a development account. `--skip-cleanup` leaves
> them behind, where they keep costing until deleted by hand.

**Why not `run-e2e-tests.sh`?** test-infra's entrypoint sources `kind.sh`,
`controller-setup.sh`, and `pytest-image-runner.sh` unconditionally, and each checks its own
binaries when sourced — so it will not start without `kind`, `kustomize`, `docker`, `jq`,
`uuidgen`, and `yq`, plus a `test_config.yaml` carrying an assumed-role ARN. All of that serves
the path that creates a KIND cluster and installs a controller, which `deploy` already owns and
`test` deliberately never takes. What remains is the three commands
`scripts/pytest-local-runner.sh` runs; the pytest invocation is kept identical to upstream's.

### `status` — inspect workspace state

Report the state of every managed repository (branch, dirty flag, ahead/behind vs. upstream)
as a table or JSON. Read-only; no token or identity needed.

```bash
ack-workspace status
ack-workspace status --json
```

Use `status` before `refresh`/`release` to see which repos are dirty or diverged, and after
bulk operations to confirm the end state. The `--json` output is machine-readable for scripts.

### `candidates` — emit the cross-resource-reference candidate index

Emit the deterministic candidate index a reference audit starts from: every string-valued
spec field of a resource's CRD, fused with the `generator.yaml` markings that bear on whether
it is a reference (`is_reference` and the configured target, `is_immutable`, `is_primary_key`)
and with the service API model's field documentation and validation patterns.

```bash
ack-workspace candidates eks --resource Nodegroup                     # records on stdout
ack-workspace candidates all --resource all --out-dir /tmp/ref-audit  # one file per resource
```

This is the mechanical half of a reference audit, separated from the judgment about which
candidates are genuine references: `candidates` produces the field set a reviewer decides
over — so an audit can be split across independent reviewers who all start from identical
input, and two runs over an unchanged repo produce byte-identical output.

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

Reads local repos and the public API models: no AWS credentials, git, or GitHub identity
required. A model that cannot be fetched degrades the index and says so rather than failing
the run.

### `attribution` — regenerate a controller's ATTRIBUTION.md

Regenerate `ATTRIBUTION.md` with the upstream
[`attribution-gen`](https://github.com/awslabs/attribution-gen) tool and write the result into
the local checkout. Accepts a bare alias, the full form, or `all`.

The generation runs on **ephemeral AWS CodeBuild compute**, and that is a requirement rather
than an optimization: building the document walks the module dependency graph and fetches every
dependency from the public Go module proxy, which is blocked from inside the Amazon corporate
network. CodeBuild runs the generator outside it.

```bash
ack-workspace attribution ecr                 # your fork, current branch
ack-workspace attribution ecr --ref pr/42     # a pull request head
ack-workspace attribution ecr --upstream      # the aws-controllers-k8s org
ack-workspace attribution all                 # every managed controller
```

By default the build clones **your fork** at the controller's checked-out branch, so push your
work first — the build reads the remote and cannot see unpushed commits. The command verifies
the ref is visible on the remote before starting any compute, so an unpushed branch fails fast
instead of as an opaque CodeBuild source error minutes later. A commit id is exempt from that
check, because `ls-remote` does not advertise arbitrary commits.

It provisions what it needs on first use (a CodeBuild project, an S3 staging bucket, an IAM
role) and reports anything it created. Useful flags:

```bash
ack-workspace attribution ecr --dry-run                  # preview; provisions nothing
ack-workspace attribution ecr --repo <url>               # clone a specific repository
ack-workspace attribution ecr --output /tmp/ATTR.md      # write elsewhere (single controller)
ack-workspace attribution ecr --go-version 1.24          # must exist in the CodeBuild image
ack-workspace attribution ecr --region us-west-2         # region for CodeBuild
ack-workspace attribution ecr --timeout 30m              # per-build wait
```

`--project`, `--role`, and `--bucket` override the provisioned resource names. An empty
identifier list is a usage error (exit code `2`).

### `config` — view and persist settings

```bash
ack-workspace config set --github-user octocat   # persist to the file in effect
ack-workspace config set --local                  # persist to ./.ack-workspace/config
ack-workspace config get                          # print resolved values + their source file
ack-workspace config path                         # print the config file in effect
```

Settings live in two layers: a global file at `$HOME/.ack-workspace/config` and an optional
workspace-local file at `<workspace-root>/.ack-workspace/config`, found by walking up from the
working directory. `set` writes to whichever is in effect; `--local` writes to the working
directory's own file, which is how a workspace-local config gets created. See
[Configuration](#configuration) for the precedence rules and the multi-workspace setup.

The GitHub token is never written to either file, regardless of how it was supplied.

---

## Global Flags

Available on all commands (subject to per-command relevance):

- `--dry-run` — preview without making changes (always exits `0`)
- `--github-user <name>` / `GITHUB_USER` — your GitHub identity
- `--token <token>` / `GITHUB_TOKEN` — GitHub token (never persisted)
- `--workspace-root <path>` — override the workspace root (rarely needed inside a workspace
  that has a local config file, which supplies its own root)
- `--prefix <prefix>` — fork name prefix (default `ack-`)
- `--concurrency <n>` — parallel worker count, `1`–`32` (default `4`); out of range is a
  usage error (exit `2`)

Repositories are processed in parallel with a bounded worker pool; one failing repository
never stops the batch.

## Exit Codes

- `0` — completed and no repository failed (dry-run always exits `0`).
- `1` — a pre-flight error occurred, or at least one repository failed.
- `2` — a usage/validation error (e.g. out-of-range `--concurrency`, `add` with no
  identifiers, missing/invalid `release` version, a missing service identifier).

---

## Common Workflows

**First-time setup:**
```bash
export GITHUB_TOKEN=ghp_xxx
ack-workspace config set --github-user <you>
ack-workspace init
ack-workspace add s3 sns          # or: add all --dry-run, then add all
```

**Add a second workspace alongside an existing one:**
```bash
ack-workspace init --workspace-root ~/other-workspace     # --workspace-root only while bootstrapping
ack-workspace add all --workspace-root ~/other-workspace
cd ~/other-workspace && ack-workspace config set --local  # pin the root; no more flags needed
cd ~/other-workspace/s3-controller && ack-workspace config get   # confirm which root resolves
```
Do the same in the original workspace so both are explicit, and leave the global file's
`workspace_root` as the fallback for commands run outside either tree. Existing forks are
detected and cloned rather than re-forked, so a second workspace does not duplicate anything on
GitHub — it is a second working tree over the same forks. Feature branches must be pushed to
show up in a fresh clone; uncommitted or unpushed work stays where it is.

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

**Test a local change on a cluster (creates `ack-dev-auto` on the first run, reuses it after):**
```bash
ack-workspace build <svc>             # regenerate code if generator.yaml/hooks changed
ack-workspace deploy <svc> --dry-run  # preview, including any cluster creation
ack-workspace deploy <svc>            # first run adds ~15-25 min for the cluster; later runs reuse it
ack-workspace test <svc>              # run the e2e suite against what you just deployed
```

**Iterate on a single failing e2e test:**
```bash
ack-workspace test <svc> --methods <test_name> --dry-run   # confirm the plan and the cluster
ack-workspace test <svc> --methods <test_name>             # one test, full bootstrap/teardown
ack-workspace test <svc> --methods <test_name> --skip-cleanup --log-level debug
```

**Cut a release:**
```bash
ack-workspace release <svc> --version v1.2.3 --dry-run
ack-workspace release <svc> --version v1.2.3
```

**Build the candidate index for a reference audit:**
```bash
ack-workspace candidates all --resource all --out-dir /tmp/ref-audit
```

**Reclaim disk / retire a fork:**
```bash
ack-workspace remove <svc> --keep-fork   # local only
ack-workspace remove <svc>               # local + fork (prompts)
```

## Safety Checklist

- Run `--dry-run` before any `remove`, `refresh`, `release`, `deploy`, or `test`.
- Run `ack-workspace build <svc>` and commit the regenerated artifacts before opening a PR
  whenever a change touches `generator.yaml`, hook templates, or anything affecting generated
  code.
- Commit or stash feature-branch work before `refresh` (uncommitted changes are discarded).
- For `deploy`, confirm your AWS credentials point at a development account: it creates an
  ECR repository when absent, and — when `ack-dev-auto` does not exist — an EKS cluster, a
  VPC, and an IAM role with `AdministratorAccess`. The cluster is expected to stay up between
  deploys, so it keeps costing until deleted; dry-run first in an account you are unsure about.
  Note that deploy also **rewrites your current kubeconfig context**.
- For `test`, remember the suite creates real AWS resources in the account your credentials
  resolve to. Teardown deletes them, but `--skip-cleanup` deliberately does not — reach for it
  only to inspect a failure, and delete what it leaves behind.
- For `remove`, prefer `--keep-fork` unless you truly want the fork deleted permanently.
- Never expect the token to be saved — always supply it via env/flag.
