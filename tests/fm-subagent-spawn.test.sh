#!/usr/bin/env bash
# tests/fm-subagent-spawn.test.sh - Phase 4 sub-agent spawn primitives and meta.
#
# Covers the option-A sub-agent spawn path (design §B, captain's Call 1):
#   - fm_backend_herdr_pane_split parses the new pane_id from `pane split`
#     and fails closed on an unparseable response.
#   - fm_backend_herdr_agent_start forwards to `agent start <name> --kind <kind>
#     --pane <id>` and fails closed on a nonzero exit.
#   - fm_backend_herdr_pane_close is best-effort (never fails the caller).
#   - bin/fm-fleet-snapshot.sh surfaces parent_task and agent_status on task
#     rows (null when absent, the value when present).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-subagent-spawn)

make_herdr_fakebin_local() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb" "$dir/responses"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_HERDR_LOG:?}"
RESP="${FM_HERDR_RESPONSES:?}"
COUNT_FILE="$RESP/.count"
next=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
{
  printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
  printf '{"client":{"version":"0.8.0","protocol":16},"server":{"running":true}}\n'
  exit 0
fi
n=$next
echo "$n" > "$COUNT_FILE"
if [ -f "$RESP/$n.exit" ]; then
  exit "$(cat "$RESP/$n.exit")"
fi
[ -f "$RESP/$n.out" ] && cat "$RESP/$n.out"
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

run_backend() {  # <expr>
  PATH="$1:$PATH" FM_HERDR_LOG="$2/log" FM_HERDR_RESPONSES="$2/responses" \
    bash -c '. "$0/bin/backends/herdr.sh"; '"$3" "$ROOT"
}

# --- pane_split parses the new pane_id ----------------------------------------
test_pane_split_parses_new_pane_id() {
  local dir fb pane
  dir="$TMP_ROOT/split-ok"; fb=$(make_herdr_fakebin_local "$dir")
  printf '{"result":{"pane":{"pane_id":"p-NEW"}}}\n' > "$dir/responses/1.out"
  pane=$(run_backend "$fb" "$dir" 'fm_backend_herdr_pane_split fmses p-PARENT /wt right') \
    || fail "pane_split should succeed on a valid response"
  [ "$pane" = "p-NEW" ] || fail "pane_split returned '$pane', expected p-NEW"
  assert_contains "$(cat "$dir/log")" $'\x1f''pane'$'\x1f''split'$'\x1f''--pane'$'\x1f''p-PARENT'$'\x1f''--direction'$'\x1f''right'$'\x1f''--no-focus' \
    "pane_split did not invoke herdr pane split with --no-focus"
  pass "fm_backend_herdr_pane_split parses the new pane_id and passes --no-focus"
}

test_pane_split_fails_closed_on_unparseable_response() {
  local dir fb pane rc
  dir="$TMP_ROOT/split-bad"; fb=$(make_herdr_fakebin_local "$dir")
  printf 'not json at all\n' > "$dir/responses/1.out"
  pane=$(run_backend "$fb" "$dir" 'fm_backend_herdr_pane_split fmses p-PARENT /wt right' 2>/dev/null) ; rc=$?
  [ "$rc" -ne 0 ] || fail "pane_split should fail closed on an unparseable response"
  [ -z "$pane" ] || fail "pane_split should print nothing on failure, got '$pane'"
  pass "fm_backend_herdr_pane_split fails closed on an unparseable response"
}

# --- agent_start forwards name/kind/pane and fails closed --------------------
test_agent_start_forwards_name_kind_pane() {
  local dir fb rc
  dir="$TMP_ROOT/start-ok"; fb=$(make_herdr_fakebin_local "$dir")
  : > "$dir/responses/1.out"
  run_backend "$fb" "$dir" 'fm_backend_herdr_agent_start fmses fm-sub1 pi p-NEW' >/dev/null 2>&1 || rc=$?
  [ "${rc:-0}" -eq 0 ] || fail "agent_start should succeed on a zero-exit response"
  assert_contains "$(cat "$dir/log")" $'\x1f''agent'$'\x1f''start'$'\x1f''fm-sub1'$'\x1f''--kind'$'\x1f''pi'$'\x1f''--pane'$'\x1f''p-NEW' \
    "agent_start did not invoke herdr agent start with name/kind/pane"
  pass "fm_backend_herdr_agent_start forwards name/kind/pane to herdr"
}

test_agent_start_fails_closed_on_nonzero_exit() {
  local dir fb rc
  dir="$TMP_ROOT/start-bad"; fb=$(make_herdr_fakebin_local "$dir")
  printf '1' > "$dir/responses/1.exit"
  run_backend "$fb" "$dir" 'fm_backend_herdr_agent_start fmses fm-sub1 pi p-NEW' >/dev/null 2>&1 || rc=$?
  [ "${rc:-0}" -ne 0 ] || fail "agent_start should fail closed when herdr exits nonzero"
  pass "fm_backend_herdr_agent_start fails closed on a nonzero herdr exit"
}

# --- pane_close is best-effort -----------------------------------------------
test_pane_close_is_best_effort() {
  local dir fb rc
  dir="$TMP_ROOT/close"; fb=$(make_herdr_fakebin_local "$dir")
  printf '1' > "$dir/responses/1.exit"
  run_backend "$fb" "$dir" 'fm_backend_herdr_pane_close fmses p-NEW' >/dev/null 2>&1 || rc=$?
  [ "${rc:-0}" -eq 0 ] || fail "pane_close should be best-effort (never fail the caller), got rc=${rc:-0}"
  assert_contains "$(cat "$dir/log")" $'\x1f''pane'$'\x1f''close'$'\x1f''p-NEW' \
    "pane_close did not invoke herdr pane close with the pane id"
  pass "fm_backend_herdr_pane_close is best-effort and forwards the pane id"
}

# --- snapshot surfaces parent_task and agent_status --------------------------
test_snapshot_surfaces_parent_task_and_agent_status() {
  local home state snap
  home="$TMP_ROOT/snap-home"; state="$home/state"; mkdir -p "$state/data" "$state" "$home/data" "$home/projects" "$home/config"
  # A regular task: no parent_task, agent_status resolves from current_state.
  fm_write_meta "$state/regular.meta" \
    "window=fmses:fm-regular" "worktree=$home/projects/regular-wt" \
    "project=firstmate" "harness=claude" "kind=ship" "mode=no-mistakes"
  printf 'working: doing thing\n' > "$state/regular.status"
  # A sub-agent task: carries parent_task.
  fm_write_meta "$state/sub1.meta" \
    "window=fmses:fm-sub1" "worktree=$home/projects/sub1-wt" \
    "project=firstmate" "harness=pi" "kind=ship" "mode=no-mistakes" \
    "parent_task=regular" "parent_pane=p-PARENT"
  printf 'working: sub work\n' > "$state/sub1.status"
  snap=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-snapshot.sh" --json 2>/dev/null) \
    || fail "snapshot failed for the parent_task fixture"
  regular_parent=$(printf '%s' "$snap" | jq -r '.tasks[] | select(.id=="regular") | .parent_task')
  [ "$regular_parent" = "null" ] || fail "regular task parent_task should be null, got '$regular_parent'"
  sub_parent=$(printf '%s' "$snap" | jq -r '.tasks[] | select(.id=="sub1") | .parent_task')
  [ "$sub_parent" = "regular" ] || fail "sub-agent parent_task should be 'regular', got '$sub_parent'"
  sub_status=$(printf '%s' "$snap" | jq -r '.tasks[] | select(.id=="sub1") | .agent_status')
  [ -n "$sub_status" ] && [ "$sub_status" != "null" ] || fail "sub-agent agent_status should be non-null, got '$sub_status'"
  pass "snapshot surfaces parent_task and agent_status on task rows"
}

test_pane_split_parses_new_pane_id
test_pane_split_fails_closed_on_unparseable_response
test_agent_start_forwards_name_kind_pane
test_agent_start_fails_closed_on_nonzero_exit
test_pane_close_is_best_effort
test_snapshot_surfaces_parent_task_and_agent_status

echo "all fm-subagent-spawn tests passed"
