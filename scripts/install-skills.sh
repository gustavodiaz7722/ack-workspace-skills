#!/usr/bin/env bash
#
# Install skills into a Kiro skills directory as symlinks, or check that an
# existing installation still resolves.
#
# Which skills are installed comes from scripts/skill-sources, so a sibling
# repository's skills can be installed and health-checked from here without
# committing anything to that repository. That is the point for a fork:
# `ack-workspace refresh` does ResetHard + Clean + ResetHardTo upstream on the
# default branch, so a script committed to a fork's main is destroyed by a
# routine refresh — exactly when you would want it.
#
# Symlinks rather than copies, so an edit in a checkout takes effect immediately
# and there is no second copy to drift. The trade-off is that a link records an
# absolute path and breaks if the checkout moves. That is not hypothetical under
# a gvm-managed GOPATH: the pkgset directory carries the Go version
# (.gvm/pkgsets/go1.26/global), so `gvm use` on another toolchain invalidates
# every link at once. A broken skill symlink raises no error — the skill just
# stops appearing — so --check is how you find out, and a plain re-run repairs it.
#
# Usage:
#   ./scripts/install-skills.sh                 # install into ~/.kiro/skills
#   ./scripts/install-skills.sh --check         # verify, exit 1 if anything is wrong
#   ./scripts/install-skills.sh --dir DIR       # install somewhere else
#   ./scripts/install-skills.sh --force         # replace a real directory, not just a symlink

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SOURCES_FILE="$REPO_ROOT/scripts/skill-sources"
TARGET_DIR="${HOME}/.kiro/skills"
MODE=install
FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE=check; shift ;;
    --force) FORCE=1; shift ;;
    --dir) TARGET_DIR="$2"; shift 2 ;;
    --sources) SOURCES_FILE="$2"; shift 2 ;;
    -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ ! -f "$SOURCES_FILE" ]; then
  echo "error: no source list at $SOURCES_FILE" >&2
  exit 1
fi

failures=0
warnings=0
declare -A seen_from=()

# resolve_root turns a line from the source list into an absolute path. A
# relative path is resolved against the repository root rather than the caller's
# working directory, so the script behaves the same from anywhere.
resolve_root() {
  local raw="$1" expanded
  expanded=$(eval "printf '%s' \"$raw\"")   # expand ~ and $VARS
  case "$expanded" in
    /*) ;;
    *)  expanded="$REPO_ROOT/$expanded" ;;
  esac
  # Normalize away any embedded ".." so a link target reads as a real path in
  # `ls -l` and in --check output. Logical (pwd -L), not physical: resolving
  # symlinks here would bake a machine-specific mount point such as /local/home
  # into every link, where the path the user actually knows is /home.
  if [ -d "$expanded" ]; then
    (cd "$expanded" && pwd -L)
  else
    printf '%s' "$expanded"
  fi
}

install_one() {
  local src="$1" name="$2" link="$TARGET_DIR/$name"

  mkdir -p "$TARGET_DIR"

  # Never remove a real directory implicitly: it may be a hand-maintained skill
  # that exists nowhere else, and replacing it with a link would destroy it.
  if [ -d "$link" ] && [ ! -L "$link" ]; then
    if [ "$FORCE" -eq 0 ]; then
      printf '  %-24s REFUSED %s is a real directory; back it up, then re-run with --force\n' "$name" "$link"
      failures=$((failures + 1))
      return
    fi
    rm -rf "$link"
  fi

  ln -sfn "$src" "$link"
  printf '  %-24s linked  -> %s\n' "$name" "$src"
}

check_one() {
  local src="$1" name="$2" link="$TARGET_DIR/$name"

  if [ ! -e "$link" ] && [ ! -L "$link" ]; then
    printf '  %-24s MISSING not installed\n' "$name"
    failures=$((failures + 1))
  elif [ ! -L "$link" ]; then
    printf '  %-24s COPY    not a symlink; edits there are invisible to git\n' "$name"
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
}

while IFS= read -r line || [ -n "$line" ]; do
  line="${line%%#*}"
  line="$(printf '%s' "$line" | tr -d '[:space:]')"
  [ -z "$line" ] && continue

  root=$(resolve_root "$line")

  if [ ! -d "$root" ]; then
    # A sibling repo that is not cloned contributes no skills. Worth saying out
    # loud — otherwise its skills are silently absent, which is the failure mode
    # this script exists to surface — but not a failure of this installation.
    printf '  %-24s NO SOURCE %s\n' "($line)" "$root"
    warnings=$((warnings + 1))
    continue
  fi

  found=0
  for src in "$root"/*/; do
    src=${src%/}
    [ -f "$src/SKILL.md" ] || continue
    found=1
    name=$(basename "$src")

    # Two roots offering the same skill name would fight over one link, and which
    # won would depend on file order. Refuse rather than install a coin flip.
    if [ -n "${seen_from[$name]:-}" ]; then
      printf '  %-24s CONFLICT also provided by %s\n' "$name" "${seen_from[$name]}"
      failures=$((failures + 1))
      continue
    fi
    seen_from[$name]="$root"

    if [ "$MODE" = check ]; then
      check_one "$src" "$name"
    else
      install_one "$src" "$name"
    fi
  done
  [ "$found" -eq 1 ] || printf '  %-24s NO SKILLS %s\n' "($line)" "$root"
done < "$SOURCES_FILE"

echo
if [ "$failures" -gt 0 ]; then
  if [ "$MODE" = check ]; then
    echo "$failures problem(s). Run ./scripts/install-skills.sh to repair." >&2
  else
    echo "$failures problem(s) during install." >&2
  fi
  exit 1
fi

if [ "$MODE" = check ]; then
  echo "${#seen_from[@]} skill(s) installed and resolving"
else
  echo "${#seen_from[@]} skill(s) installed into $TARGET_DIR"
fi
if [ "$warnings" -gt 0 ]; then
  echo "$warnings listed source(s) absent — their skills are not installed"
fi
