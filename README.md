# ack-workspace-skills

Agent skills for AWS Controllers for Kubernetes (ACK) that are backed by the [`ack-workspace`](https://github.com/gustavodiaz7722/ack-workspace) CLI.

The distinction from `ack-dev-skills` is the dependency. Skills here delegate their mechanical, must-be-exact work to `ack-workspace` commands rather than carrying their own scripts, so the logic is compiled, unit-tested, and shared with the CLI instead of reimplemented in a skill.

## What's here

**`ack-workspace`** — reference guide to the CLI itself: every command, the global flags, configuration precedence, prerequisites, and which operations are destructive.

**`ack-reference-audit`** — audit ACK controllers for CRD fields that should be cross-resource references but carry no `references` block in `generator.yaml`, and wire up the ones that should. Backed by `ack-workspace candidates`.

## Prerequisite

The `ack-workspace` binary on `PATH`:

```bash
go build -o /usr/local/bin/ack-workspace .   # from an ack-workspace checkout
ack-workspace candidates --help
```

## Install

```bash
./scripts/install-skills.sh              # symlink every skill into ~/.kiro/skills
./scripts/install-skills.sh --dir DIR    # or into a workspace .kiro/skills
```

Symlinks rather than copies, so an edit in the checkout takes effect immediately and there is no second copy to drift.

### Re-run it after the checkout moves

A symlink records an absolute path, so moving the checkout breaks every link — and a broken skill symlink raises no error, the skill just stops appearing. Nothing tells you the guidance is gone.

That is not a hypothetical if this repo lives under a **gvm-managed GOPATH**: the pkgset directory carries the Go version (`.gvm/pkgsets/go1.26/global`), so `gvm use` on a different toolchain invalidates every link at once.

```bash
./scripts/install-skills.sh --check      # exits 1 on anything missing, broken, stale, or copied
./scripts/install-skills.sh              # idempotent; repairs whatever --check reported
```

`--check` is worth wiring into a shell startup file or a `SessionStart` hook if you switch Go versions often. Installing over a real directory is refused rather than silently destroying it — pass `--force` once you've confirmed it is not a hand-maintained skill that exists nowhere else.

The durable fix is to keep the checkout outside GOPATH entirely. These are module-based repos, so nothing requires the GOPATH location; `ack-workspace` only defaults its workspace root there and takes `--workspace-root` to point elsewhere.

The roles, workflows, and agents directories sit at the repo root and are referenced by relative path from the skill, so keep the tree intact rather than copying `skills/` alone.

## Layout

```
scripts/
└── install-skills.sh           # symlink skills into a Kiro skills dir; --check verifies

skills/ack-workspace/           # CLI reference
└── SKILL.md

skills/ack-reference-audit/     # Agent Skill directory
├── SKILL.md                    # Entry point: prerequisite, the two tasks, what makes an audit wrong
└── references/
    └── cross-resource-references.md   # Identifying gaps, and remediating them

workflows/
└── audit-references.md         # Build indexes → fan out one auditor per resource → merge report

roles/                          # Tool-agnostic role SOPs
├── reference-auditor.md        # Per-resource audit methodology and obligations
└── schemas/
    └── reference-audit-output.md      # Per-resource finding + merged report shape

agents/
└── ack-reference-auditor.md    # Claude Code subagent definition
```

## Separation of concerns

The reference doc carries knowledge, the role SOP carries an auditor's obligations, the schema carries the shape of a finding, and the workflow carries orchestration. A finding's verdict vocabulary is deliberately three-valued: `NOT_ASSESSED` is distinct from `PASS`, so a failed or partial audit is never recorded as a clean resource.

## License

Apache 2.0. See [LICENSE](LICENSE).
