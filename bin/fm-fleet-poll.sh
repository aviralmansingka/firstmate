#!/usr/bin/env bash
# fm-fleet-poll.sh - read-only precedence-ranked fleet poll.
#
# Composes the existing fm-fleet-snapshot.sh output + the keyed open-decision
# fold into a precedence-ranked list, surfaced in /bearings as "Fleet Pulse".
# Read-only: no locks, no mutation, no watcher arming, no state-file writes.
#
# Output contract: `fm-fleet-poll.v1` (JSON via --json, human digest by default).
# Phase 1: tiers 1-5 only, NO --peek flag (that is Phase 5, gated by Call 2).
#
# Precedence ladder (total order, not a score):
#   1. captain-held items (backlog captain_actionable) - captain owns by definition.
#   2. open needs-decision keys - a worker asked and is waiting.
#   3. open blocked keys whose summary enumerates options - actionable immediately.
#   4. open blocked keys without options - need diagnosis before the captain can rule.
#   5. failure/attention states - failed, paused past its re-surface cadence.
#   6. undeclared musings - ONLY when --peek armed; ABSENT in Phase 1.
# Tie-break inside a tier: oldest-first (age from status file mtimes).
#
# Flags:
#   --json           emit fm-fleet-poll.v1 JSON (default is human digest)
#   --snapshot -     read snapshot JSON from stdin instead of running fm-fleet-snapshot.sh
#   --snapshot <file> read snapshot JSON from <file>
#   -h, --help       usage
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

usage() {
  cat <<'EOF'
usage: fm-fleet-poll.sh [--json] [--snapshot -|<file>]

Read-only precedence-ranked fleet poll over declared signals.
Composes fm-fleet-snapshot.sh + the keyed open-decision fold.

--json           emit fm-fleet-poll.v1 JSON (default: human digest)
--snapshot -     read snapshot JSON from stdin
--snapshot <file> read snapshot JSON from a file
EOF
}

OUTPUT=human
SNAPSHOT_SRC=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json) OUTPUT=json ;;
    --snapshot) shift; SNAPSHOT_SRC=${1:-} ;;
    --snapshot=*) SNAPSHOT_SRC=${1#--snapshot=} ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || { echo "fm-fleet-poll: jq not found" >&2; exit 1; }

# --- acquire snapshot JSON ---------------------------------------------------
if [ -n "$SNAPSHOT_SRC" ]; then
  if [ "$SNAPSHOT_SRC" = "-" ]; then
    SNAP=$(cat) || { echo "fm-fleet-poll: failed to read snapshot from stdin" >&2; exit 1; }
  else
    SNAP=$(cat "$SNAPSHOT_SRC") || { echo "fm-fleet-poll: failed to read snapshot from $SNAPSHOT_SRC" >&2; exit 1; }
  fi
else
  SNAP=$("$SCRIPT_DIR/fm-fleet-snapshot.sh" --json) || exit $?
fi

# Validate the snapshot has the expected schema.
printf '%s' "$SNAP" | jq -e '.schema == "fm-fleet-snapshot.v1"' >/dev/null 2>&1 \
  || { echo "fm-fleet-poll: invalid or missing snapshot schema" >&2; exit 1; }

# --- compute age map: task_id -> age_seconds from status file mtime ----------
STATE_DIR=$(printf '%s' "$SNAP" | jq -r '.roots.state // empty')
NOW_EPOCH=$(date +%s)
AGE_MAP='{}'
if [ -n "$STATE_DIR" ] && [ -d "$STATE_DIR" ]; then
  for f in "$STATE_DIR"/*.status; do
    [ -e "$f" ] || continue
    task=$(basename "$f"); task="${task%.status}"
    if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
      mtime=$(stat -f '%m' "$f" 2>/dev/null || echo 0)
    else
      mtime=$(stat -c '%Y' "$f" 2>/dev/null || echo 0)
    fi
    case "$mtime" in ''|*[!0-9]*) mtime=0 ;; esac
    age=$((NOW_EPOCH - mtime))
    [ "$age" -lt 0 ] && age=0
    AGE_MAP=$(printf '%s' "$AGE_MAP" | jq --arg task "$task" --argjson age "$age" \
      '. + {($task): $age}')
  done
fi

NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# --- compose the ranked list (precedence ladder) -----------------------------
RESULT=$(printf '%s' "$SNAP" | jq --argjson age_map "$AGE_MAP" --arg now "$NOW_ISO" '
  # Heuristic: does a blocked summary enumerate options?
  def has_options:
    test("(?i)\\boption\\b|alternatively|either\\b")
    or test("\\s+or\\s+")
    or test(";.*;")
    or test("[0-9]+[.)]\\s")
    or test("\\b[A-C][.)]\\s");

  # Tier 1: captain-held items from the backlog ledger.
  ([
    .backlog.records[]
    | select(.structured == true and .captain_actionable == true)
    | {
        tier: 1,
        id: .id,
        kind: "captain-held",
        key: null,
        summary: ((.title + ": " + (.hold_reason // "captain action needed"))[:140]),
        age_s: ($age_map[.id] // null),
        source: "backlog"
      }
  ])

  # Tier 2: open needs-decision keys.
  + ([
    .tasks[]
    | .id as $tid
    | .hints.open_decisions[]?
    | select(.verb == "needs-decision")
    | {
        tier: 2,
        id: $tid,
        kind: "needs-decision",
        key: .key,
        summary: (.summary[:140]),
        age_s: ($age_map[$tid] // null),
        source: "status"
      }
  ])

  # Tier 3: open blocked keys with enumerated options.
  + ([
    .tasks[]
    | .id as $tid
    | .hints.open_decisions[]?
    | select(.verb == "blocked")
    | select(.summary | has_options)
    | {
        tier: 3,
        id: $tid,
        kind: "blocked-with-options",
        key: .key,
        summary: (.summary[:140]),
        age_s: ($age_map[$tid] // null),
        source: "status"
      }
  ])

  # Tier 4: open blocked keys without options.
  + ([
    .tasks[]
    | .id as $tid
    | .hints.open_decisions[]?
    | select(.verb == "blocked")
    | select(.summary | has_options | not)
    | {
        tier: 4,
        id: $tid,
        kind: "blocked",
        key: .key,
        summary: (.summary[:140]),
        age_s: ($age_map[$tid] // null),
        source: "status"
      }
  ])

  # Tier 5: failure/attention states. The durable signal is the status log
  # last wake-event verb (failed:/paused:), which survives a gone backend where
  # current_state falls back to `unknown`. current_state is OR-ed in for the
  # rare case a live backend reports failed/paused before a status event lands.
  # Stale-wedge detection is deferred: it needs watcher-internal signals
  # (.stale-*) not exposed in the fleet snapshot, and surfacing every `unknown`
  # task would noise the poll with done-but-not-torn-down rows.
  + ([
    .tasks[]
    | .paths.status_log.last_event.state as $le
    | select(
        ($le // null) == "failed" or ($le // null) == "paused"
        or .current_state.state == "failed" or .current_state.state == "paused"
      )
    | {
        tier: 5,
        id: .id,
        kind: ($le // .current_state.state),
        key: null,
        summary: ((.paths.status_log.last_event.note // .current_state.detail // .hints.last_event_text // "attention")[:140]),
        age_s: ($age_map[.id] // null),
        source: "status"
      }
  ])

  # Sort: tier ascending, then oldest-first (age descending), nulls last.
  | sort_by(.tier, if .age_s == null then 999999999 else -(.age_s) end)

  # Build the digest string from tier groups.
  | . as $ranked
  | ($ranked | group_by(.tier)) as $groups
  | {
      schema: "fm-fleet-poll.v1",
      generated_at: $now,
      ranked: $ranked,
      digest: (
        if ($ranked | length) == 0 then "0 items"
        else
          [ $groups[] | ((. | length) | tostring) + " " + .[0].kind ]
          | join(" · ")
        end
      )
    }
') || { echo "fm-fleet-poll: ranked-list composition failed" >&2; exit 1; }

if [ "$OUTPUT" = json ]; then
  printf '%s\n' "$RESULT"
  exit 0
fi

# --- human digest ------------------------------------------------------------
printf '%s\n' "$RESULT" | jq -r '
  .digest as $d
  | "Fleet Pulse: \($d)\n"
  + ([.ranked[]? | "T\(.tier)  \(.kind[:18])  \(.id[:25])  \(.summary)"] | join("\n"))
'
