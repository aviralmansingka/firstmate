#!/usr/bin/env bash
# fm-ask-user-question.sh - fixture-stage source binding and delivery adapter
# for the primary Pi ask-user-question prototype.
#
# Commands:
#   fm-ask-user-question.sh generation --home <home> --task <id> --key <key>
#   fm-ask-user-question.sh validate --home <home> --task <id> --key <key> --generation <sha256:...>
#   fm-ask-user-question.sh deliver --home <home> --task <id> --key <key> --generation <sha256:...> --answer <text>
#
# This adapter owns no decision state.
# It binds a presentation to the exact task metadata and status bytes, verifies
# that the keyed decision is still open through fm-classify-lib.sh, and delegates
# successful delivery to fm-send.sh --resolve-key.
set -euo pipefail

PREFLIGHT_FAILURE=3
DELIVERY_UNKNOWN=4
failure_status=2

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$ROOT/bin/fm-session-lock-lib.sh"

die() {
  printf 'fm-ask-user-question: %s\n' "$*" >&2
  exit "$failure_status"
}

hash_stream() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    die 'shasum or sha256sum is required'
  fi
}

canonical_dir() {
  [ -d "$1" ] || return 1
  (cd -- "$1" 2>/dev/null && pwd -P)
}

parse_binding() {
  home=
  task=
  key=
  generation=
  answer=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --home) [ "$#" -ge 2 ] || die '--home requires a value'; home=$2; shift 2 ;;
      --task) [ "$#" -ge 2 ] || die '--task requires a value'; task=$2; shift 2 ;;
      --key) [ "$#" -ge 2 ] || die '--key requires a value'; key=$2; shift 2 ;;
      --generation) [ "$#" -ge 2 ] || die '--generation requires a value'; generation=$2; shift 2 ;;
      --answer) [ "$#" -ge 2 ] || die '--answer requires a value'; answer=$2; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
}

validate_identity() {
  local active_home active_state canonical_home canonical_active canonical_state
  [ -n "$home" ] || die '--home is required'
  [ -n "$task" ] || die '--task is required'
  [ -n "$key" ] || die '--key is required'
  case "$task" in
    *[!A-Za-z0-9._-]*|'') die 'invalid task id' ;;
  esac
  case "$key" in
    *[!A-Za-z0-9._-]*|'') die 'invalid decision key' ;;
  esac
  active_home=${FM_HOME:-${FM_ROOT_OVERRIDE:-$ROOT}}
  canonical_home=$(canonical_dir "$home") || die 'home does not exist'
  canonical_active=$(canonical_dir "$active_home") || die 'active FM_HOME does not exist'
  [ "$canonical_home" = "$canonical_active" ] || die 'supplied home is not the active FM_HOME'
  [ ! -e "$canonical_home/.fm-secondmate-home" ] && [ ! -L "$canonical_home/.fm-secondmate-home" ] \
    || die 'captain dialog is primary-only'
  home=$canonical_home
  active_state=${FM_STATE_OVERRIDE:-$home/state}
  canonical_state=$(canonical_dir "$active_state") || die 'active state dir does not exist'
  state=$canonical_state
  meta="$state/$task.meta"
  status="$state/$task.status"
  [ -f "$meta" ] && [ -r "$meta" ] && [ ! -L "$meta" ] || die 'task metadata is missing or unsafe'
  [ -f "$status" ] && [ -r "$status" ] && [ ! -L "$status" ] || die 'task status is missing or unsafe'
}

require_open_key() {
  local open line found=0
  open=$(status_open_decisions "$status")
  while IFS= read -r line; do
    case "$line" in
      "$key"$'\t'*) found=1; break ;;
    esac
  done <<EOF
$open
EOF
  [ "$found" -eq 1 ] || die 'keyed decision is no longer open for this task'
}

current_generation() {
  local digest
  digest=$({
    printf 'home\0%s\0state\0%s\0task\0%s\0key\0%s\0meta\0' "$home" "$state" "$task" "$key"
    cat "$meta"
    printf '\0status\0'
    cat "$status"
  } | hash_stream)
  printf 'sha256:%s\n' "$digest"
}

validate_generation() {
  local current
  [[ "$generation" =~ ^sha256:[0-9a-f]{64}$ ]] || die 'invalid source generation'
  current=$(current_generation)
  [ "$generation" = "$current" ] || die 'source generation no longer matches the task'
}

require_primary_lock() {
  fm_session_lock_owned_by_self "$state" || die 'active session does not own the primary lock'
}

command=${1:-}
[ -n "$command" ] || die 'a command is required'
case "$command" in
  generation|validate) ;;
  deliver)
    failure_status=$PREFLIGHT_FAILURE
    set -E
    trap 'exit "$PREFLIGHT_FAILURE"' ERR
    ;;
  *) die "unknown command: $command" ;;
esac
shift
parse_binding "$@"
validate_identity
require_open_key

case "$command" in
  generation)
    [ -z "$generation" ] || die 'generation does not accept --generation'
    [ -z "$answer" ] || die 'generation does not accept --answer'
    current_generation
    ;;
  validate)
    [ -n "$generation" ] || die '--generation is required'
    [ -z "$answer" ] || die 'validate does not accept --answer'
    require_primary_lock
    validate_generation
    printf 'valid\n'
    ;;
  deliver)
    [ -n "$generation" ] || die '--generation is required'
    [ -n "$answer" ] || die '--answer is required'
    require_primary_lock
    validate_generation
    [ -x "$ROOT/bin/fm-send.sh" ] || die 'delivery owner is missing or not executable'
    trap - ERR
    if [ -n "${FM_ASK_USER_QUESTION_OWNER_ENTRY_MARKER:-}" ]; then
      [ "${FM_ASK_USER_QUESTION_OWNER_ENTRY_FD:-}" = 3 ] || exit "$PREFLIGHT_FAILURE"
    fi
    if FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
      "$ROOT/bin/fm-send.sh" "$task" --resolve-key "$key" "Captain answer: $answer"; then
      :
    else
      exit "$DELIVERY_UNKNOWN"
    fi
    ;;
  *) die "unknown command: $command" ;;
esac
