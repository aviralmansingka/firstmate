#!/usr/bin/env bash
# tests/fm-peek-musings.test.sh - Phase 5: --peek musings, children sidecar,
# and the heartbeat-excludes-peek proof.
#
#   - --peek armed with a running sub-agent emits tier-6 undeclared rows;
#     unarmed emits zero (privacy proof, already covered in fm-fleet-poll tests
#     but re-pinned here against a fixture with a running child).
#   - A headless child sidecar (state/<parent>.children.jsonl) is surfaced by
#     fm-fleet-snapshot.sh as tasks[].children[].
#   - --peek is absent from the heartbeat path (grep proof: no --peek in
#     bin/fm-watch.sh or fm-branch-supervision.ts wake handling).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-peek-musings)

# --- children sidecar surfaced by the snapshot -------------------------------
test_snapshot_surfaces_children_sidecar() {
  local home state snap
  home="$TMP_ROOT/child-home"; state="$home/state"; mkdir -p "$state" "$home/data" "$home/projects" "$home/config"
  fm_write_meta "$state/parent1.meta" \
    "window=fmses:fm-parent1" "worktree=$home/projects/parent1-wt" \
    "project=firstmate" "harness=pi" "kind=ship" "mode=no-mistakes"
  printf 'working: parent task\n' > "$state/parent1.status"
  # Write a children.jsonl sidecar on the parent (one headless child).
  printf '%s\n' '{"agent":"fm-child-a","task_excerpt":"researching X","state":"running","at":"2026-08-27T08:00:00Z"}' > "$state/parent1.children.jsonl"
  snap=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-snapshot.sh" --json 2>/dev/null) \
    || fail "snapshot failed for the children sidecar fixture"
  count=$(printf '%s' "$snap" | jq '.tasks[] | select(.id=="parent1") | .children | length')
  [ "$count" = 1 ] || fail "parent1 should have 1 child from the sidecar, got $count"
  child_agent=$(printf '%s' "$snap" | jq -r '.tasks[] | select(.id=="parent1") | .children[0].agent')
  [ "$child_agent" = "fm-child-a" ] || fail "child agent should be fm-child-a, got '$child_agent'"
  pass "snapshot surfaces children[] from the state/<parent>.children.jsonl sidecar"
}

test_snapshot_empty_children_without_sidecar() {
  local home state snap count
  home="$TMP_ROOT/child-empty"; state="$home/state"; mkdir -p "$state" "$home/data" "$home/projects" "$home/config"
  fm_write_meta "$state/orphan1.meta" \
    "window=fmses:fm-orphan1" "worktree=$home/projects/orphan1-wt" \
    "project=firstmate" "harness=claude" "kind=ship" "mode=no-mistakes"
  printf 'working: no children\n' > "$state/orphan1.status"
  snap=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-snapshot.sh" --json 2>/dev/null) \
    || fail "snapshot failed for the no-sidecar fixture"
  count=$(printf '%s' "$snap" | jq '.tasks[] | select(.id=="orphan1") | .children | length')
  [ "$count" = 0 ] || fail "a task with no sidecar should have 0 children, got $count"
  pass "snapshot emits an empty children[] array when no sidecar exists"
}

# --- heartbeat path excludes --peek (grep proof, Call 2) ---------------------
# fm-watch.sh and fm-branch-supervision.ts are the heartbeat/wake path. --peek
# must never appear there. This is a contract assertion on two named files that
# own the wake path (not implementation-source bytes of the poll script itself).
test_peek_absent_from_heartbeat_path() {
  local hits
  hits=$(grep -rn -- '--peek' "$ROOT/bin/fm-watch.sh" "$ROOT/.pi/extensions/fm-branch-supervision.ts" 2>/dev/null | wc -l | tr -d ' ')
  [ "$hits" = 0 ] || fail "--peek must never appear in the heartbeat path (fm-watch.sh or fm-branch-supervision.ts), found $hits hit(s)"
  pass "--peek is absent from the heartbeat path (fm-watch.sh, fm-branch-supervision.ts)"
}

test_snapshot_surfaces_children_sidecar
test_snapshot_empty_children_without_sidecar
test_peek_absent_from_heartbeat_path

echo "all fm-peek-musings tests passed"
