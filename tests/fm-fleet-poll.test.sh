#!/usr/bin/env bash
# Behavior tests for fm-fleet-poll.sh, the read-only precedence-ranked fleet poll.
# Covers the five-tier precedence ladder, oldest-first tie-break, JSON and human
# output modes, read-only proof (no state-file mtime change), --snapshot stdin
# passthrough, and the Phase-1 absence of --peek.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

POLL="$ROOT/bin/fm-fleet-poll.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-poll)
FM_ROOT_OVERRIDE="$TMP_ROOT/fixture-root"
mkdir -p "$FM_ROOT_OVERRIDE"
export FM_ROOT_OVERRIDE

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_fakebin() {
  local fb
  fb=$(fm_fakebin "$TMP_ROOT")
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'all quiet\n> \n' ;;
  list-windows) printf '' ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

make_home() {
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

write_fixture() {  # <home>
  local home=$1
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] working-task - Active work (repo: firstmate) (kind: ship) (since 2026-07-11)

## Queued
- [ ] held-task - A captain-held task (repo: firstmate) (kind: ship) (hold: captain choice pending) (hold-kind: captain) (since 2026-07-11)
- [ ] queued-gate - Queued work blocked-by: working-task (repo: firstmate) (kind: ship)

## Done
- [x] done-task - Landed thing https://github.com/kunchenguid/firstmate/pull/7 (repo: firstmate) (kind: ship) (merged 2026-07-10)
EOF

  # Tier 1: captain-held backlog item. A queued + hold-kind=captain row with a
  # hold reason and no blockers is captain_actionable=true (the snapshot's
  # "captain must act now" signal), so it lands tier 1.
  fm_write_meta "$home/state/held-task.meta" \
    "window=firstmate:fm-held-task" \
    "worktree=$home/projects/held-wt" \
    "project=firstmate" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes"
  printf 'working: building\n' > "$home/state/held-task.status"

  # Tier 2: open needs-decision key
  fm_write_meta "$home/state/decision-task.meta" \
    "window=firstmate:fm-decision-task" \
    "worktree=$home/projects/decision-wt" \
    "project=firstmate" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes"
  printf 'needs-decision [key=api-choice]: pick REST or GraphQL\n' > "$home/state/decision-task.status"

  # Tier 3: blocked with enumerated options
  fm_write_meta "$home/state/blocked-opts.meta" \
    "window=firstmate:fm-blocked-opts" \
    "worktree=$home/projects/blocked-opts-wt" \
    "project=firstmate" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes"
  printf 'blocked [key=db-pick]: option A - use postgres; option B - use mysql\n' > "$home/state/blocked-opts.status"

  # Tier 4: blocked without options
  fm_write_meta "$home/state/blocked-bare.meta" \
    "window=firstmate:fm-blocked-bare" \
    "worktree=$home/projects/blocked-bare-wt" \
    "project=firstmate" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes"
  printf 'blocked [key=missing-dep]: dependency X not found\n' > "$home/state/blocked-bare.status"

  # Tier 5: failed state
  fm_write_meta "$home/state/failed-task.meta" \
    "window=firstmate:fm-failed-task" \
    "worktree=$home/projects/failed-wt" \
    "project=firstmate" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes"
  printf 'failed: build broke\n' > "$home/state/failed-task.status"

  # Working task (not in any tier)
  fm_write_meta "$home/state/working-task.meta" \
    "window=firstmate:fm-working-task" \
    "worktree=$home/projects/working-wt" \
    "project=firstmate" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes"
  printf 'working: making progress\n' > "$home/state/working-task.status"
}

run_poll() {  # <home> <args...>
  local home=$1; shift
  PATH="$(make_fakebin):$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$FM_ROOT_OVERRIDE" "$POLL" "$@"
}

# --- Test 1: JSON output has correct schema and ranking ----------------------
home=$(make_home primary)
write_fixture "$home"
out=$(run_poll "$home" --json) || fail "poll --json failed"
schema=$(printf '%s' "$out" | jq -r '.schema')
[ "$schema" = "fm-fleet-poll.v1" ] || fail "schema is $schema, expected fm-fleet-poll.v1"

# Verify tier ordering: 1 < 2 < 3 < 4 < 5
tiers=$(printf '%s' "$out" | jq -r '[.ranked[].tier] | join(",")')
expected="1,2,3,4,5"
[ "$tiers" = "$expected" ] || fail "tier order is $tiers, expected $expected"
pass "JSON output has correct schema and tier ordering (1-5)"

# --- Test 2: tier-1 is captain-held from backlog -----------------------------
t1_kind=$(printf '%s' "$out" | jq -r '.ranked[] | select(.tier == 1) | .kind')
t1_source=$(printf '%s' "$out" | jq -r '.ranked[] | select(.tier == 1) | .source')
[ "$t1_kind" = "captain-held" ] || fail "tier-1 kind is $t1_kind"
[ "$t1_source" = "backlog" ] || fail "tier-1 source is $t1_source"
pass "tier-1 is captain-held from backlog"

# --- Test 3: tier-2 is needs-decision from status ----------------------------
t2_kind=$(printf '%s' "$out" | jq -r '.ranked[] | select(.tier == 2) | .kind')
t2_key=$(printf '%s' "$out" | jq -r '.ranked[] | select(.tier == 2) | .key')
t2_source=$(printf '%s' "$out" | jq -r '.ranked[] | select(.tier == 2) | .source')
[ "$t2_kind" = "needs-decision" ] || fail "tier-2 kind is $t2_kind"
[ "$t2_key" = "api-choice" ] || fail "tier-2 key is $t2_key"
[ "$t2_source" = "status" ] || fail "tier-2 source is $t2_source"
pass "tier-2 is needs-decision from status"

# --- Test 4: tier-3 is blocked-with-options ----------------------------------
t3_kind=$(printf '%s' "$out" | jq -r '.ranked[] | select(.tier == 3) | .kind')
[ "$t3_kind" = "blocked-with-options" ] || fail "tier-3 kind is $t3_kind"
pass "tier-3 is blocked-with-options"

# --- Test 5: tier-4 is blocked without options -------------------------------
t4_kind=$(printf '%s' "$out" | jq -r '.ranked[] | select(.tier == 4) | .kind')
[ "$t4_kind" = "blocked" ] || fail "tier-4 kind is $t4_kind"
pass "tier-4 is blocked without options"

# --- Test 6: tier-5 is failed state ------------------------------------------
t5_kind=$(printf '%s' "$out" | jq -r '.ranked[] | select(.tier == 5) | .kind')
[ "$t5_kind" = "failed" ] || fail "tier-5 kind is $t5_kind"
pass "tier-5 is failed state"

# --- Test 7: digest is present and non-empty ---------------------------------
digest=$(printf '%s' "$out" | jq -r '.digest')
[ -n "$digest" ] || fail "digest is empty"
case "$digest" in
  *captain-held*needs-decision*) : ;;
  *) fail "digest does not contain expected kinds: $digest" ;;
esac
pass "digest is present and contains tier summaries"

# --- Test 8: read-only proof - no state file mtime change --------------------
# Portable mtime fingerprint: GNU stat -c or BSD stat -f, hashed with shasum.
status_mtime_fp() {
  find "$1" -name '*.status' -exec sh -c '
    for f; do stat -c "%Y %n" "$f" 2>/dev/null || stat -f "%m %N" "$f" 2>/dev/null; done
  ' _ {} + 2>/dev/null | LC_ALL=C sort | shasum -a 256 | awk '{print $1}'
}
before=$(status_mtime_fp "$home/state")
run_poll "$home" --json >/dev/null 2>&1
after=$(status_mtime_fp "$home/state")
[ "$before" = "$after" ] || fail "state file mtimes changed (not read-only)"
pass "read-only: state file mtimes unchanged after poll"

# --- Test 9: --snapshot - reads from stdin -----------------------------------
snap=$(PATH="$(make_fakebin):$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$FM_ROOT_OVERRIDE" \
  "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "snapshot failed"
stdin_out=$(printf '%s' "$snap" | run_poll "$home" --json --snapshot -) || fail "poll --snapshot - failed"
stdin_schema=$(printf '%s' "$stdin_out" | jq -r '.schema')
[ "$stdin_schema" = "fm-fleet-poll.v1" ] || fail "stdin schema is $stdin_schema"
stdin_tiers=$(printf '%s' "$stdin_out" | jq -r '[.ranked[].tier] | join(",")')
[ "$stdin_tiers" = "$expected" ] || fail "stdin tier order is $stdin_tiers, expected $expected"
pass "--snapshot - reads from stdin and produces same ranking"

# --- Test 10: --peek is not a recognized flag in Phase 1 ---------------------
# Behavioral proof (not a source grep): --peek must be rejected as unknown in
# Phase 1, so an armed musing read cannot happen by accident.
peek_rc=0
run_poll "$home" --peek --json >/tmp/fm-poll-peek.out 2>/tmp/fm-poll-peek.err || peek_rc=$?
[ "$peek_rc" -ne 0 ] || fail "--peek was accepted in Phase 1 (rc=$peek_rc)"
# A rejected unknown flag prints usage to stderr and exits 2.
[ "$peek_rc" -eq 2 ] || fail "--peek exit code is $peek_rc, expected 2 (usage)"
grep -qi 'usage' /tmp/fm-poll-peek.err || fail "--peek did not print usage to stderr"
rm -f /tmp/fm-poll-peek.out /tmp/fm-poll-peek.err
pass "--peek rejected as unknown flag in Phase 1"

# --- Test 11: human mode prints digest and rows ------------------------------
human_out=$(run_poll "$home") || fail "poll (human mode) failed"
case "$human_out" in
  *Fleet\ Pulse*) : ;;
  *) fail "human output missing 'Fleet Pulse' header" ;;
esac
case "$human_out" in
  *captain-held*) : ;;
  *) fail "human output missing tier-1 row" ;;
esac
pass "human mode prints digest and ranked rows"

# --- Test 12: empty fleet produces valid empty output ------------------------
empty_home=$(make_home empty)
empty_out=$(run_poll "$empty_home" --json) || fail "poll on empty fleet failed"
empty_count=$(printf '%s' "$empty_out" | jq '.ranked | length')
[ "$empty_count" = "0" ] || fail "empty fleet has $empty_count ranked items, expected 0"
empty_digest=$(printf '%s' "$empty_out" | jq -r '.digest')
[ "$empty_digest" = "0 items" ] || fail "empty digest is '$empty_digest', expected '0 items'"
pass "empty fleet produces valid empty output"

# --- Test 13: ranked items carry required fields -----------------------------
fields=$(printf '%s' "$out" | jq -r '.ranked[0] | keys | join(",")')
for required in tier id kind key summary age_s source; do
  case ",$fields," in
    *",$required,"*) : ;;
    *) fail "ranked item missing field: $required (has: $fields)" ;;
  esac
done
pass "ranked items carry all required fields"

echo "all tests passed"
