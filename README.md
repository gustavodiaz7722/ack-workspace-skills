# ack-workspace-skills

Agent skills for AWS Controllers for Kubernetes (ACK) that are backed by the [`ack-workspace`](https://github.com/gustavodiaz7722/ack-workspace) CLI.

The distinction from `ack-dev-skills` is the dependency. Skills here delegate their mechanical, must-be-exact work to `ack-workspace` commands rather than carrying their own scripts, so the logic is compiled, unit-tested, and shared with the CLI instead of reimplemented in a skill.

## What's here

**`ack-reference-audit`** — audit ACK controllers for CRD fields that should be cross-resource references but carry no `references` block in `generator.yaml`, and wire up the ones that should. Backed by `ack-workspace candidates`.

## Prerequisite

The `ack-workspace` binary on `PATH`:

```bash
go build -o /usr/local/bin/ack-workspace .   # from an ack-workspace checkout
ack-workspace candidates --help
```

## Install

Point your agent's skills directory at this repo, or symlink an individual skill:

```bash
ln -s "$PWD/skills/ack-reference-audit" ~/.kiro/skills/ack-reference-audit
```

The roles, workflows, and agents directories sit at the repo root and are referenced by relative path from the skill, so keep the tree intact rather than copying `skills/` alone.

## Layout

```
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
