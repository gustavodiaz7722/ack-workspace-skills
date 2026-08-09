#!/usr/bin/env bash
#
# merge-reference-findings.sh — assemble reference-audit reports from per-resource findings.
#
# This exists so the audit orchestrator never has to read a finding document. Findings are
# long by design (quoted evidence, proposed config, caveats), and an orchestrator that reads
# 268 of them exhausts its context before it can merge anything. Every number and table this
# script emits is derived by grep/awk over the finding files on disk, so merging costs the
# orchestrator nothing but the summary it prints.
#
# It writes one report per controller plus a thin fleet index. Per-controller is the readable
# unit: a single fleet-wide document containing every finding verbatim runs to tens of
# thousands of lines and is navigable by nobody.
#
# Usage:
#   merge-reference-findings.sh [OUT_DIR]
#
# OUT_DIR defaults to /tmp/ref-audit and must be the directory `ack-workspace candidates
# --out-dir` wrote to, holding:
#   <OUT_DIR>/<alias>/<Kind>.jsonl        candidate indexes  (defines the full audit scope)
#   <OUT_DIR>/findings/<alias>/<Kind>.md  per-resource findings (what actually completed)
#   <OUT_DIR>/phase0.log                  Phase 0 stderr
#
# Outputs:
#   <OUT_DIR>/reports/<alias>.md          per-controller report
#   <OUT_DIR>/reference-audit-index.md    fleet index
#   <OUT_DIR>/.merge/                     intermediate TSVs, kept so results are inspectable
#
# A resource with an index but no finding is NOT_ASSESSED. That is not PASS, and the
# distinction is enforced here rather than left to the orchestrator's memory.

set -euo pipefail

OUT_DIR="${1:-/tmp/ref-audit}"
[ -d "$OUT_DIR" ] || { echo "merge: OUT_DIR not found: $OUT_DIR" >&2; exit 1; }

cd "$OUT_DIR"
[ -d findings ] || { echo "merge: no findings/ under $OUT_DIR — nothing to merge" >&2; exit 1; }

WORK=.merge
REPORTS=reports
rm -rf "$WORK"; mkdir -p "$WORK" "$REPORTS"

DATE=$(date -u +%F)

# ---------------------------------------------------------------------------
# Scope: every candidate index is an auditable resource; every finding is a
# completed one. all - done = NOT_ASSESSED.
# ---------------------------------------------------------------------------
find . -mindepth 2 -maxdepth 2 -name '*.jsonl' -not -path './findings/*' -not -path "./$WORK/*" \
  | sed 's|^\./||; s|\.jsonl$||' | sort > "$WORK/all.txt"
find findings -mindepth 2 -maxdepth 2 -name '*.md' \
  | sed 's|^findings/||; s|\.md$||' | sort > "$WORK/done.txt"
comm -23 "$WORK/all.txt" "$WORK/done.txt" > "$WORK/notassessed.txt"

n_all=$(wc -l < "$WORK/all.txt" | tr -d ' ')
n_done=$(wc -l < "$WORK/done.txt" | tr -d ' ')
n_na=$(wc -l < "$WORK/notassessed.txt" | tr -d ' ')

# ---------------------------------------------------------------------------
# Verdicts: alias<TAB>Kind<TAB>verdict<TAB>candidates<TAB>configured<TAB>gaps<TAB>model
# ---------------------------------------------------------------------------
: > "$WORK/verdicts.tsv"
while read -r res; do
  f="findings/$res.md"
  alias=${res%%/*}; kind=${res#*/}
  # `|| true` on every extraction: a finding that does not match is the case this loop
  # exists to classify, so a failing grep must not abort the merge under `set -e`.
  v=$( { grep -m1 '^- \*\*Verdict:\*\*'            "$f" || true; } 2>/dev/null | sed 's/.*Verdict:\*\* *//;s/ *$//')
  c=$( { grep -m1 '^- \*\*Candidates examined:\*\*' "$f" || true; } 2>/dev/null | sed 's/[^0-9]*\([0-9]*\).*/\1/')
  k=$( { grep -m1 '^- \*\*Already configured:\*\*'  "$f" || true; } 2>/dev/null | sed 's/[^0-9]*\([0-9]*\).*/\1/')
  g=$( { grep -m1 '^- \*\*Gaps found:\*\*'          "$f" || true; } 2>/dev/null | sed 's/[^0-9]*\([0-9]*\).*/\1/')
  m=$( { grep -m1 '^- \*\*Model available:\*\*'     "$f" || true; } 2>/dev/null | sed 's/.*Model available:\*\* *//;s/ *$//')
  # A finding with no parsable verdict line is malformed: treat as NOT_ASSESSED, never PASS.
  case "$v" in PASS|FAIL|NOT_ASSESSED) ;; *) v="NOT_ASSESSED" ;; esac
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$alias" "$kind" "$v" "${c:-0}" "${k:-0}" "${g:-0}" "${m:-unknown}" >> "$WORK/verdicts.tsv"
done < "$WORK/done.txt"

# ---------------------------------------------------------------------------
# Gaps: confidence<TAB>alias<TAB>Kind<TAB>path<TAB>target<TAB>signal
#
# Parses the Gaps section of each finding. Anchored on the schema's numbered
# entry form ("N. `field.path`") and its Target/Signal/Confidence bullets, so a
# finding that does not follow the schema contributes no rows and is reported as
# a parse miss rather than silently counted as clean.
# ---------------------------------------------------------------------------
GAP_AWK='
/^### Gaps/                { ingaps=1; next }
/^### Already Configured/  { flush(); ingaps=0 }
/^### Rejected/            { flush(); ingaps=0 }
/^### Discrepancies/       { flush(); ingaps=0 }
ingaps && /^[0-9]+\. *`/ {
  flush()
  line=$0; sub(/^[0-9]+\. *`/,"",line); sub(/`.*$/,"",line); path=line
  next
}
ingaps && /\*\*Target:\*\**/     && path!="" && target=="" { t=$0; sub(/.*\*\*Target:\*\* *(#)?/,"",t); gsub(/^ +| +$/,"",t); target=t; next }
ingaps && /\*\*Signal:\*\*/      && path!="" && signal=="" { t=$0; sub(/.*\*\*Signal:\*\* */,"",t);      gsub(/^ +| +$/,"",t); signal=t; next }
ingaps && /\*\*Confidence:\*\*/  && path!="" && conf==""   { t=$0; sub(/.*\*\*Confidence:\*\* */,"",t);  gsub(/^ +| +$/,"",t); conf=t;   next }
END { flush() }
function flush() {
  if (path != "") {
    if (conf == "")   conf   = "unspecified"
    if (target == "") target = "unidentified"
    if (signal == "") signal = "-"
    printf "%s\t%s\t%s\t%s\t%s\t%s\n", conf, ALIAS, KIND, path, target, signal
  }
  path=""; target=""; signal=""; conf=""
}
'
: > "$WORK/gaps.tsv"
while read -r res; do
  alias=${res%%/*}; kind=${res#*/}
  awk -v ALIAS="$alias" -v KIND="$kind" "$GAP_AWK" "findings/$res.md" >> "$WORK/gaps.tsv"
done < "$WORK/done.txt"

n_gaps_parsed=$(wc -l < "$WORK/gaps.tsv" | tr -d ' ')
n_gaps_declared=$(awk -F'\t' '{s+=$6} END{print s+0}' "$WORK/verdicts.tsv")

# Findings whose header could not be parsed. These are recorded as NOT_ASSESSED above; listing
# them separately is what stops a malformed finding from quietly reading as an unaudited resource.
awk -F'\t' '$3=="NOT_ASSESSED" {print $1"/"$2}' "$WORK/verdicts.tsv" | sort > "$WORK/na_from_finding.txt"

# ---------------------------------------------------------------------------
# Normalized target, for grouping work by the dependency it adds.
# Trims the caveat prose findings attach after an em dash or in parentheses.
# ---------------------------------------------------------------------------
awk -F'\t' '{
  t=$5
  sub(/ *\(.*/,"",t); sub(/ *—.*/,"",t); sub(/ *--.*/,"",t)
  gsub(/^ +| +$/,"",t)
  if (t=="") t="unidentified"
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", $1,$2,$3,$4,$5,$6,t
}' "$WORK/gaps.tsv" > "$WORK/gaps_norm.tsv"

# ---------------------------------------------------------------------------
# Emitters
# ---------------------------------------------------------------------------

# gap table for a confidence level, optionally scoped to one controller
emit_gap_table() {
  local conf="$1" scope="${2:-}" out="$3" showctl="$4"
  if [ -n "$scope" ]; then
    awk -F'\t' -v c="$conf" -v a="$scope" '$1==c && $2==a' "$WORK/gaps_norm.tsv" > "$WORK/.t"
  else
    awk -F'\t' -v c="$conf" '$1==c' "$WORK/gaps_norm.tsv" > "$WORK/.t"
  fi
  if [ ! -s "$WORK/.t" ]; then
    printf '_None._\n\n' >> "$out"; return
  fi
  if [ "$showctl" = yes ]; then
    printf '| Controller/Resource | Field Path | Target | Signal |\n|---|---|---|---|\n' >> "$out"
    sort -t"$(printf '\t')" -k2,2 -k3,3 "$WORK/.t" \
      | awk -F'\t' '{printf "| %s/%s | `%s` | %s | %s |\n", $2,$3,$4,$5,$6}' >> "$out"
  else
    printf '| Resource | Field Path | Target | Signal |\n|---|---|---|---|\n' >> "$out"
    sort -t"$(printf '\t')" -k3,3 "$WORK/.t" \
      | awk -F'\t' '{printf "| %s | `%s` | %s | %s |\n", $3,$4,$5,$6}' >> "$out"
  fi
  printf '\n' >> "$out"
}

# "target -> gap count, referencing controllers" table
emit_target_table() {
  local scope="${1:-}" out="$2"
  if [ -n "$scope" ]; then
    awk -F'\t' -v a="$scope" '$2==a' "$WORK/gaps_norm.tsv" > "$WORK/.t"
  else
    cat "$WORK/gaps_norm.tsv" > "$WORK/.t"
  fi
  [ -s "$WORK/.t" ] || { printf '_No gaps._\n\n' >> "$out"; return; }
  printf '| Target | Gaps | Referencing controllers |\n|---|---:|---|\n' >> "$out"
  awk -F'\t' '{
      key=$7; cnt[key]++
      if (index(seen[key], "|" $2 "|") == 0) {
        seen[key] = seen[key] "|" $2 "|"
        list[key] = list[key] (list[key]==""?"":", ") $2
      }
    }
    END { for (k in cnt) printf "%d\t%s\t%s\n", cnt[k], k, list[k] }' "$WORK/.t" \
    | sort -rn | awk -F'\t' '{printf "| %s | %d | %s |\n", $2,$1,$3}' >> "$out"
  printf '\n' >> "$out"
}

# ---------------------------------------------------------------------------
# Per-controller reports
# ---------------------------------------------------------------------------
cut -d/ -f1 "$WORK/all.txt" | sort -u > "$WORK/controllers.txt"

while read -r alias; do
  rep="$REPORTS/$alias.md"
  c_all=$(grep -c "^$alias/" "$WORK/all.txt" || true)
  c_done=$(awk -F'\t' -v a="$alias" '$1==a' "$WORK/verdicts.tsv" | wc -l | tr -d ' ')
  c_na=$(grep -c "^$alias/" "$WORK/notassessed.txt" || true)
  [ "$c_done" -eq 0 ] && continue   # nothing audited in this controller; it appears in the index only

  c_pass=$(awk -F'\t' -v a="$alias" '$1==a && $3=="PASS"' "$WORK/verdicts.tsv" | wc -l | tr -d ' ')
  c_fail=$(awk -F'\t' -v a="$alias" '$1==a && $3=="FAIL"' "$WORK/verdicts.tsv" | wc -l | tr -d ' ')
  c_nax=$(awk -F'\t' -v a="$alias" '$1==a && $3=="NOT_ASSESSED"' "$WORK/verdicts.tsv" | wc -l | tr -d ' ')
  c_gaps=$(awk -F'\t' -v a="$alias" '$2==a' "$WORK/gaps_norm.tsv" | wc -l | tr -d ' ')
  c_hi=$(awk -F'\t' -v a="$alias" '$2==a && $1=="high"'   "$WORK/gaps_norm.tsv" | wc -l | tr -d ' ')
  c_md=$(awk -F'\t' -v a="$alias" '$2==a && $1=="medium"' "$WORK/gaps_norm.tsv" | wc -l | tr -d ' ')
  c_lo=$(awk -F'\t' -v a="$alias" '$2==a && $1=="low"'    "$WORK/gaps_norm.tsv" | wc -l | tr -d ' ')
  c_gapres=$(awk -F'\t' -v a="$alias" '$2==a {print $3}' "$WORK/gaps_norm.tsv" | sort -u | wc -l | tr -d ' ')
  c_nomodel=$(awk -F'\t' -v a="$alias" '$1==a && $7!="yes"' "$WORK/verdicts.tsv" | wc -l | tr -d ' ')

  {
    printf '# Cross-Resource Reference Audit: %s\n\n' "$alias"
    printf -- '- **Controller:** `%s-controller`\n' "$alias"
    printf -- '- **Date:** %s\n' "$DATE"
    printf -- '- **Resources audited:** %s of %s\n' "$c_done" "$c_all"
    printf -- '- **Model enrichment:** %s of %s audited resources\n\n' "$((c_done - c_nomodel))" "$c_done"
    if [ "$c_na" -gt 0 ] || [ "$c_nax" -gt 0 ]; then
      printf '> **Coverage is incomplete for this controller.** %s of %s resources were not assessed. `NOT_ASSESSED` is not `PASS` — see the Not Assessed table.\n\n' \
        "$((c_na + c_nax))" "$c_all"
    fi
    printf '## Summary\n\n| Verdict | Count |\n|---|---|\n'
    printf '| PASS | %s |\n| FAIL | %s |\n| NOT_ASSESSED | %s |\n\n' "$c_pass" "$c_fail" "$((c_na + c_nax))"
    printf '**Total gaps:** %s across %s resources (high: %s, medium: %s, low: %s)\n\n' \
      "$c_gaps" "$c_gapres" "$c_hi" "$c_md" "$c_lo"
    printf '| Resource | Verdict | Candidates | Configured | Gaps |\n|---|---|---:|---:|---:|\n'
    awk -F'\t' -v a="$alias" '$1==a {printf "| %s | %s | %s | %s | %s |\n", $2,$3,$4,$5,$6}' \
      "$WORK/verdicts.tsv" | sort
    printf '\n## Gaps by Confidence\n\n### High Confidence\n\n'
  } > "$rep"
  emit_gap_table high   "$alias" "$rep" no
  printf '### Medium Confidence\n\n' >> "$rep"; emit_gap_table medium "$alias" "$rep" no
  printf '### Low Confidence\n\n'    >> "$rep"; emit_gap_table low    "$alias" "$rep" no

  {
    printf '## Not Assessed\n\n'
    if [ "$c_na" -eq 0 ] && [ "$c_nax" -eq 0 ]; then
      printf 'None — every resource in this controller was audited.\n\n'
    else
      printf 'These resources have a candidate index but no completed audit. Nothing in this report supports any claim about them.\n\n'
      printf '| Resource | Reason |\n|---|---|\n'
      grep "^$alias/" "$WORK/notassessed.txt" 2>/dev/null | sed "s|^$alias/||" \
        | awk '{printf "| %s | no auditor completed for this resource |\n", $0}' || true
      awk -F'\t' -v a="$alias" '$1==a && $3=="NOT_ASSESSED" {printf "| %s | auditor returned NOT_ASSESSED; see its finding below |\n", $2}' \
        "$WORK/verdicts.tsv"
      printf '\n'
    fi
    printf '## Recommended Sequencing\n\n'
    printf 'Gaps grouped by target. Each distinct cross-service target adds one `go.mod` dependency and one `ATTRIBUTION.md` regeneration, so one PR per target keeps dependency changes reviewable.\n\n'
  } >> "$rep"
  emit_target_table "$alias" "$rep"

  {
    printf '## Per-Resource Findings\n\n'
  } >> "$rep"
  awk -F'\t' -v a="$alias" '$1==a {print $2}' "$WORK/verdicts.tsv" | sort | while read -r kind; do
    cat "findings/$alias/$kind.md" >> "$rep"
    printf '\n---\n\n' >> "$rep"
  done

  echo "  reports/$alias.md  ($c_done/$c_all audited, $c_gaps gaps)"
done < "$WORK/controllers.txt"

# ---------------------------------------------------------------------------
# Fleet index — navigation and totals only. No findings verbatim.
# ---------------------------------------------------------------------------
IDX=reference-audit-index.md
n_pass=$(awk -F'\t' '$3=="PASS"' "$WORK/verdicts.tsv" | wc -l | tr -d ' ')
n_fail=$(awk -F'\t' '$3=="FAIL"' "$WORK/verdicts.tsv" | wc -l | tr -d ' ')
n_nax=$(awk -F'\t' '$3=="NOT_ASSESSED"' "$WORK/verdicts.tsv" | wc -l | tr -d ' ')
n_hi=$(awk -F'\t' '$1=="high"'   "$WORK/gaps_norm.tsv" | wc -l | tr -d ' ')
n_md=$(awk -F'\t' '$1=="medium"' "$WORK/gaps_norm.tsv" | wc -l | tr -d ' ')
n_lo=$(awk -F'\t' '$1=="low"'    "$WORK/gaps_norm.tsv" | wc -l | tr -d ' ')
n_gapres=$(awk -F'\t' '{print $2"/"$3}' "$WORK/gaps_norm.tsv" | sort -u | wc -l | tr -d ' ')
n_ctl_all=$(wc -l < "$WORK/controllers.txt" | tr -d ' ')
n_ctl_rep=$(find "$REPORTS" -name '*.md' | wc -l | tr -d ' ')

{
  printf '# Cross-Resource Reference Audit — Fleet Index\n\n'
  printf -- '- **Date:** %s\n' "$DATE"
  printf -- '- **Resources audited:** %s of %s across %s controllers\n' "$n_done" "$n_all" "$n_ctl_all"
  printf -- '- **Controller reports:** %s (in `reports/`)\n\n' "$n_ctl_rep"
  if [ "$n_na" -gt 0 ] || [ "$n_nax" -gt 0 ]; then
    printf '> **This run is incomplete.** %s of %s resources were not assessed. `NOT_ASSESSED` is not `PASS`: nothing here supports any claim about those resources. Candidate indexes exist for all of them, so a resumed run skips Phase 0 entirely.\n\n' \
      "$((n_na + n_nax))" "$n_all"
  fi
  printf '## Summary\n\n| Verdict | Count |\n|---|---|\n'
  printf '| PASS | %s |\n| FAIL | %s |\n| NOT_ASSESSED | %s |\n\n' "$n_pass" "$n_fail" "$((n_na + n_nax))"
  printf '**Total gaps:** %s across %s resources (high: %s, medium: %s, low: %s)\n\n' \
    "$n_gaps_parsed" "$n_gapres" "$n_hi" "$n_md" "$n_lo"
  if [ "$n_gaps_parsed" -ne "$n_gaps_declared" ]; then
    printf '> **Parse warning:** findings declare %s gaps in their headers but %s gap entries were parsed. A finding whose Gaps section does not follow the output schema contributes no rows to the tables below. Reconcile before relying on the counts.\n\n' \
      "$n_gaps_declared" "$n_gaps_parsed"
  fi
  printf '## Coverage by Controller\n\n'
  printf '| Controller | Audited | PASS | FAIL | NOT_ASSESSED | Gaps | Report |\n|---|---:|---:|---:|---:|---:|---|\n'
} > "$IDX"

while read -r alias; do
  c_all=$(grep -c "^$alias/" "$WORK/all.txt" || true)
  c_done=$(awk -F'\t' -v a="$alias" '$1==a' "$WORK/verdicts.tsv" | wc -l | tr -d ' ')
  c_pass=$(awk -F'\t' -v a="$alias" '$1==a && $3=="PASS"' "$WORK/verdicts.tsv" | wc -l | tr -d ' ')
  c_fail=$(awk -F'\t' -v a="$alias" '$1==a && $3=="FAIL"' "$WORK/verdicts.tsv" | wc -l | tr -d ' ')
  c_na=$(grep -c "^$alias/" "$WORK/notassessed.txt" || true)
  c_nax=$(awk -F'\t' -v a="$alias" '$1==a && $3=="NOT_ASSESSED"' "$WORK/verdicts.tsv" | wc -l | tr -d ' ')
  c_gaps=$(awk -F'\t' -v a="$alias" '$2==a' "$WORK/gaps_norm.tsv" | wc -l | tr -d ' ')
  if [ "$c_done" -eq 0 ]; then
    printf '| %s | 0 of %s | 0 | 0 | %s | — | _not audited_ |\n' "$alias" "$c_all" "$c_all" >> "$IDX"
  else
    printf '| %s | %s of %s | %s | %s | %s | %s | [`reports/%s.md`](reports/%s.md) |\n' \
      "$alias" "$c_done" "$c_all" "$c_pass" "$c_fail" "$((c_na + c_nax))" "$c_gaps" "$alias" "$alias" >> "$IDX"
  fi
done < "$WORK/controllers.txt"

{
  printf '\n## Fleet Gaps by Confidence\n\n### High Confidence\n\n'
} >> "$IDX"
emit_gap_table high "" "$IDX" yes
printf '### Medium Confidence\n\n' >> "$IDX"; emit_gap_table medium "" "$IDX" yes
printf '### Low Confidence\n\n'    >> "$IDX"; emit_gap_table low    "" "$IDX" yes

{
  printf '## Fleet Sequencing by Target\n\n'
  printf 'Each distinct cross-service target adds one `go.mod` dependency, so this is the natural batching for PRs. Controllers listed are the ones with gaps against that target.\n\n'
} >> "$IDX"
emit_target_table "" "$IDX"

{
  printf '## Phase 0\n\n'
  if [ -f phase0.log ]; then
    printf -- '- Candidate indexes: %s across %s controllers\n' "$n_all" "$n_ctl_all"
    printf -- '- `SKIP` (declared but no generated CRD): %s\n' "$(grep -c 'SKIP' phase0.log || true)"
    printf -- '- `model … unavailable`: %s\n' "$(grep -c 'unavailable' phase0.log || true)"
    printf -- '- Controllers with suppressed identifier-looking fields: %s\n\n' \
      "$(grep -c 'suppressed by ignore.field_paths' phase0.log || true)"
    printf 'A suppressed field cannot reach any index, and a suppression can hide a reference. Each affected resource carries its controller'"'"'s suppression note in the Discrepancies section of its finding.\n\n'
  else
    printf 'No `phase0.log` found under `%s`, so index-quality conditions could not be reported. Treat coverage claims with caution.\n\n' "$OUT_DIR"
  fi
  printf '## How to read this\n\n'
  printf 'Per-controller reports carry the full findings verbatim; this index carries none. Numbers here are derived mechanically from the finding files by `merge-reference-findings.sh`, so they cannot drift from the findings — but the judgment in a gap entry (target, confidence, caveats) belongs to the auditor that wrote it and is not re-evaluated during the merge.\n'
} >> "$IDX"

echo
echo "merge complete"
echo "  fleet index:  $OUT_DIR/$IDX"
echo "  controllers:  $n_ctl_rep report(s) in $OUT_DIR/$REPORTS/"
echo "  audited:      $n_done of $n_all   (PASS $n_pass / FAIL $n_fail / NOT_ASSESSED $((n_na + n_nax)))"
echo "  gaps:         $n_gaps_parsed parsed (high $n_hi / medium $n_md / low $n_lo)"
if [ "$n_gaps_parsed" -ne "$n_gaps_declared" ]; then
  echo "  WARNING:      findings declare $n_gaps_declared gaps but $n_gaps_parsed parsed — check schema conformance" >&2
fi
