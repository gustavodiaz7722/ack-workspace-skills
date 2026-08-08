#!/usr/bin/env bash
#
# Install this repository's skills into a Kiro skills directory as symlinks, or
# check that an existing installation still resolves.
#
# Symlinks rather than copies, so an edit in the checkout takes effect
# immediately and there is no second copy to drift. The trade-off is that the
# link records an absolute path, and that path breaks if the checkout moves.
#
# That is not hypothetical when the checkout lives under a gvm-managed GOPATH:
# the pkgset directory carries the Go version (.gvm/pkgsets/go1.26/global), so
# `gvm use` on another toolchain silently invalidates every link. A broken skill
# symlink does not raise an error — the skill just stops appearing — which is
# why --check exists. Re-run without arguments after any move to repair.
#
# Usage:
#   ./scripts/install-skills.sh                 # install into ~/.kiro/skills
#   ./scripts/install-skills.sh --check         # verify, exit 1 if anything is wrong
#   ./scripts/install-skills.sh --dir DIR       # install somewhere else
#   ./scripts/install-skills.sh --force         # replace a real directory, not just a symlink

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TARGET_DIR="${HOME}/.kiro/skills"
MODE=install
FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE=check; shift ;;
    --force) FORCE=1; shift ;;
    --dir) TARGET_DIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ ! -d "$REPO_ROOT/skills" ]; then
  echo "error: no skills/ directory under $REPO_ROOT" >&2
  exit 1
fi

failures=0

for src in "$REPO_ROOT"/skills/*/; do
  src=${src%/}
  name=$(basename "$src")
  link="$TARGET_DIR/$name"

  if [ ! -f "$src/SKILL.md" ]; then
    printf '  %-24s SKIP    no SKILL.md\n' "$name"
    continue
  fi

  if [ "$MODE" = check ]; then
    if [ ! -e "$link" ] && [ ! -L "$link" ]; then
      printf '  %-24s MISSING not installed\n' "$name"
      failures=$((failures + 1))
    elif [ ! -L "$link" ]; then
      # A real directory is a copy that will drift out of sync with the checkout.
      printf '  %-24s COPY    not a symlink; edits here are invisible to git\n' "$name"
      failures=$((failures + 1))
    elif [ ! -f "$link/SKILL.md" ]; then
      printf '  %-24s BROKEN  -> %s\n' "$name" "$(readlink "$link")"
      failures=$((failures + 1))
    elif [ "$(cd "$link" && pwd -P)" != "$(cd "$src" && pwd -P)" ]; then
      printf '  %-24s STALE   -> %s\n' "$name" "$(readlink "$link")"
      failures=$((failures + 1))
    else
      printf '  %-24s ok\n' "$name"
    fi
    continue
  fi

  mkdir -p "$TARGET_DIR"

  # Never remove a real directory implicitly: it may be a hand-maintained skill
  # that exists nowhere else, and replacing it with a link would destroy it.
  if [ -d "$link" ] && [ ! -L "$link" ]; then
    if [ "$FORCE" -eq 0 ]; then
      printf '  %-24s REFUSED %s is a real directory; back it up, then re-run with --force\n' "$name" "$link"
      failures=$((failures + 1))
      continue
    fi
    rm -rf "$link"
  fi

  ln -sfn "$src" "$link"
  printf '  %-24s linked  -> %s\n' "$name" "$src"
done

if [ "$MODE" = check ]; then
  if [ "$failures" -gt 0 ]; then
    echo
    echo "$failures problem(s). Re-run ./scripts/install-skills.sh to repair." >&2
    exit 1
  fi
  echo
  echo "all skills installed and resolving"
fi
