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
# Both modes also follow every relative link inside each skill the way an agent
# reads it, through the installed path. A link that climbs to the directory
# holding the skills directory (ack-dev's ../../references) is served by linking
# that directory beside DIR, so a skill whose links climb is installed whole.
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
    -h|--help) sed -n '2,31p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ ! -f "$SOURCES_FILE" ]; then
  echo "error: no source list at $SOURCES_FILE" >&2
  exit 1
fi

failures=0
warnings=0
dead=0
declare -A seen_from=()

# Skills that installed (or checked) cleanly, in parallel arrays, for the link
# pass that runs once every skill is in place.
declare -a ok_names=() ok_srcs=() ok_roots=()

# Directories beside the skills directory that some skill's links climb to:
# name -> the directory it must link to, and the skill that first needed it.
declare -A shared_want=() shared_for=()

# lexical_path collapses . and .. in an absolute path without consulting the
# filesystem. That is how an agent resolves a relative link — and the opposite
# of what the kernel does when it walks through a symlinked directory.
lexical_path() {
  local IFS=/ part
  local -a parts out=()
  read -ra parts <<< "$1"
  for part in "${parts[@]}"; do
    case "$part" in
      ''|.) ;;
      ..) if [ ${#out[@]} -gt 0 ]; then unset "out[$(( ${#out[@]} - 1 ))]"; fi ;;
      *) out+=("$part") ;;
    esac
  done
  if [ ${#out[@]} -eq 0 ]; then printf '/'; else printf '/%s' "${out[@]}"; fi
}

# physical_path prints where an existing path really lands, every symlink followed.
physical_path() {
  if [ -d "$1" ]; then
    (cd "$1" && pwd -P)
  else
    printf '%s/%s' "$(cd "$(dirname "$1")" && pwd -P)" "$(basename "$1")"
  fi
}

case "$TARGET_DIR" in /*) ;; *) TARGET_DIR="$PWD/$TARGET_DIR" ;; esac
TARGET_DIR=$(lexical_path "$TARGET_DIR")
SHARED_DIR=$(dirname "$TARGET_DIR")

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

# --- Links inside a skill -----------------------------------------------------
#
# A harness reads an installed skill through its link and resolves `..`
# lexically from there. Kiro reports the skill directory as
# ~/.kiro/skills/<name>, and its read_file collapses ../ without following the
# link first, so ack-dev's ../../references/x.md resolves to
# ~/.kiro/references/x.md, not to the repository the link was written in. The
# kernel would follow the link and find the file; the agent never gets that far,
# and a dead link raises no error any more than a dead skill does.
#
# So a link may stay inside its skill, point at a sibling skill (resolved through
# that skill's own link), or climb to the directory that holds the skills
# directory. The last kind is served by linking that top-level directory beside
# the skills directory — ~/.kiro/references for ack-dev — which cannot be done
# where the harness owns the name: ~/.kiro/agents is Kiro's own. Skills in this
# repository therefore keep every link inside the skill.

# skill_links prints "<file>\t<target>" for every relative markdown link in a
# skill, fragment removed. Fenced code blocks are skipped: a link there is an
# example of output, not a link.
skill_links() {
  local file
  while IFS= read -r -d '' file; do
    awk -v f="$file" '
      /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
      fence { next }
      {
        line = $0
        while (match(line, /\]\([^)[:space:]]+\)/)) {
          t = substr(line, RSTART + 2, RLENGTH - 3)
          line = substr(line, RSTART + RLENGTH)
          sub(/#.*/, "", t)
          if (t == "" || t ~ /^[A-Za-z][A-Za-z0-9+.-]*:/ || t ~ /^\//) continue
          print f "\t" t
        }
      }' "$file"
  done < <(find "$1" -name '*.md' -print0)
}

# check_links verifies every link in one installed skill resolves the way an
# agent reads it, and records the shared directories its links climb to.
check_links() {
  local src="$1" name="$2" root="$3" above file target rel intended seen top
  above=$(dirname "$root")
  while IFS=$'\t' read -r file target; do
    rel=${file#"$src"/}
    intended=$(lexical_path "$src/$(dirname "$rel")/$target")
    seen=$(lexical_path "$TARGET_DIR/$name/$(dirname "$rel")/$target")

    if [ ! -e "$intended" ]; then
      printf '  %-24s DEAD    %s: %s is broken in the source too\n' "$name" "$rel" "$target"
      dead=$((dead + 1))
      continue
    fi

    case "$intended" in
      "$root"/*) ;;
      "$above"/*)
        top=${intended#"$above"/}
        top=${top%%/*}
        if [ -n "${shared_want[$top]:-}" ] && [ "${shared_want[$top]}" != "$above/$top" ]; then
          printf '  %-24s CONFLICT ../%s is also wanted by %s, from %s\n' \
            "$name" "$top" "${shared_for[$top]}" "${shared_want[$top]}"
          failures=$((failures + 1))
        else
          shared_want[$top]="$above/$top"
          case ", ${shared_for[$top]:-}, " in
            *", $name, "*) ;;
            *) shared_for[$top]="${shared_for[$top]:+${shared_for[$top]}, }$name" ;;
          esac
        fi
        continue
        ;;
    esac

    if [ -e "$seen" ] && [ "$(physical_path "$seen")" = "$(physical_path "$intended")" ]; then
      continue
    fi
    case "$intended" in
      "$root"/*)
        top=${intended#"$root"/}
        printf '  %-24s LINK    %s: %s needs skill %s installed beside it\n' \
          "$name" "$rel" "$target" "${top%%/*}" ;;
      *)
        printf '  %-24s LINK    %s: %s climbs above %s; no install can reach it\n' \
          "$name" "$rel" "$target" "$above" ;;
    esac
    failures=$((failures + 1))
  done < <(skill_links "$src")
}

# shared_one installs or checks one directory that skills' links climb to.
shared_one() {
  local top="$1" want="${shared_want[$1]}" link="$SHARED_DIR/$1" label="../$1"

  # A real directory here belongs to someone else — ~/.kiro/agents is Kiro's own
  # agent configuration — so not even --force replaces it. The skill has to stop
  # climbing instead.
  if [ -e "$link" ] && [ ! -L "$link" ]; then
    printf '  %-24s BLOCKED %s is a real path; links from %s into it cannot resolve\n' \
      "$label" "$link" "${shared_for[$top]}"
    failures=$((failures + 1))
  elif [ "$MODE" != check ]; then
    ln -sfn "$want" "$link"
    printf '  %-24s linked  -> %s\n' "$label" "$want"
  elif [ -L "$link" ] && [ -e "$link" ] && [ "$(physical_path "$link")" = "$(physical_path "$want")" ]; then
    printf '  %-24s ok\n' "$label"
  elif [ -L "$link" ]; then
    printf '  %-24s STALE   -> %s (wanted by %s)\n' "$label" "$(readlink "$link")" "${shared_for[$top]}"
    failures=$((failures + 1))
  else
    printf '  %-24s MISSING wanted by %s\n' "$label" "${shared_for[$top]}"
    failures=$((failures + 1))
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

    before=$failures
    if [ "$MODE" = check ]; then
      check_one "$src" "$name"
    else
      install_one "$src" "$name"
    fi
    if [ "$failures" -eq "$before" ]; then
      ok_names+=("$name"); ok_srcs+=("$src"); ok_roots+=("$root")
    fi
  done
  [ "$found" -eq 1 ] || printf '  %-24s NO SKILLS %s\n' "($line)" "$root"
done < "$SOURCES_FILE"

# Links are checked only once every skill is in place, because a link may point
# at a sibling skill installed later in the loop. A skill that is itself missing
# or broken was already reported; its links would only repeat that.
for i in ${ok_names[@]+"${!ok_names[@]}"}; do
  check_links "${ok_srcs[$i]}" "${ok_names[$i]}" "${ok_roots[$i]}"
done
for top in ${shared_want[@]+"${!shared_want[@]}"}; do
  shared_one "$top"
done

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
# Not a failure: no installation can repair a link that is dead in its own
# repository, and a sibling fork would keep this red until upstream fixes it.
if [ "$dead" -gt 0 ]; then
  echo "$dead link(s) broken in their source repository — fix them there"
fi
