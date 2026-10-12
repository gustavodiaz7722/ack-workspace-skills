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

Symlinks rather than copies, so an edit in a checkout takes effect immediately and there is no second copy to drift.

### It installs sibling repositories' skills too

Which skills get installed comes from [`scripts/skill-sources`](scripts/skill-sources), a list of directories that hold skill directories. It ships with this repo's `skills/` plus `../ack-dev-skills/skills`, so one command installs and health-checks all four ACK skills.

Listing a sibling repo here rather than adding a script to it is deliberate. `ack-dev-skills` is a fork of an upstream repo, and `ack-workspace refresh` does `ResetHard` + `Clean` + `ResetHardTo upstream` on the default branch — so anything committed to that fork's `main` is destroyed by a routine refresh, taking the protection with it precisely when you'd want it. Keeping the source list here means the fork stays byte-identical to upstream and its skills are still covered.

A listed source that isn't cloned is reported and skipped, not an error. Two sources offering the same skill name is an error, because which one won would otherwise depend on file order.

### Re-run it after the checkout moves

A symlink records an absolute path, so moving the checkout breaks every link — and a broken skill symlink raises no error, the skill just stops appearing. Nothing tells you the guidance is gone.

That is not a hypothetical if this repo lives under a **gvm-managed GOPATH**: the pkgset directory carries the Go version (`.gvm/pkgsets/go1.26/global`), so `gvm use` on a different toolchain invalidates every link at once.

```bash
./scripts/install-skills.sh --check      # exits 1 on anything missing, broken, stale, or copied
./scripts/install-skills.sh              # idempotent; repairs whatever --check reported
```

`--check` is worth wiring into a shell startup file or a `SessionStart` hook if you switch Go versions often. Installing over a real directory is refused rather than silently destroying it — pass `--force` once you've confirmed it is not a hand-maintained skill that exists nowhere else.

The durable fix is to keep the checkout outside GOPATH entirely. These are module-based repos, so nothing requires the GOPATH location; `ack-workspace` only *defaults* its workspace root there. Drop a `.ack-workspace/config` file in the new root — `cd <root> && ack-workspace config set --local` — and every command resolves to it from anywhere inside the tree, with no `--workspace-root` and no environment variables. Two workspaces can coexist that way, each with its own config file, which is also how you migrate off a gvm pkgset path without cutting over in one step.

### Links must not climb out of a skill

A harness reads an installed skill through its link and resolves `..` lexically from there. Kiro reports the skill directory as `~/.kiro/skills/<name>`, so a link to `../../workflows/x.md` reads as `~/.kiro/workflows/x.md`, not the file in this repository. It fails as quietly as a broken skill link: the agent just reports the file missing. So every skill here keeps everything it links to inside its own directory, and names another skill's files rather than linking them.

`ack-dev` does link out, to `../../references/` in its own repository, and the fork has to stay byte-identical to upstream. The script handles that by linking the directory beside the skills directory, so `~/.kiro/references` points at `ack-dev-skills/references`. That only works where the harness doesn't own the name. `~/.kiro/agents` is Kiro's own agent configuration, so a skill that climbed to `../../agents` could never be served. `--check` follows every relative link the way an agent does, and reports a link that does not resolve, a shared directory that is missing or stale, and one that is blocked.

## Layout

```
scripts/
├── install-skills.sh           # symlink skills into a Kiro skills dir; --check verifies
└── skill-sources               # directories holding the skills to install

skills/ack-workspace/           # CLI reference
└── SKILL.md

skills/ack-reference-audit/     # Agent Skill directory; everything it links to lives inside it
├── SKILL.md                    # Entry point: prerequisite, the two tasks, what makes an audit wrong
├── references/
│   ├── cross-resource-references.md   # Identifying gaps, and remediating them
│   └── pr-template.md                 # PR body for a reference-adding change
├── workflows/
│   └── audit-references.md     # Build indexes → fan out one auditor per resource → merge per controller
├── roles/                      # Tool-agnostic role SOPs
│   ├── reference-auditor.md    # Per-resource audit methodology and obligations
│   └── schemas/
│       └── reference-audit-output.md  # Finding, per-controller report, and fleet index shapes
├── scripts/
│   └── merge-reference-findings.sh    # Assemble audit reports from findings, one per controller
└── agents/
    └── ack-reference-auditor.md       # Claude Code subagent definition
```

## Separation of concerns

The reference doc carries knowledge, the role SOP carries an auditor's obligations, the schema carries the shape of a finding, and the workflow carries orchestration. A finding's verdict vocabulary is deliberately three-valued: `NOT_ASSESSED` is distinct from `PASS`, so a failed or partial audit is never recorded as a clean resource.

## License

Apache 2.0. See [LICENSE](LICENSE).
