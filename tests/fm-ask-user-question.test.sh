#!/usr/bin/env bash
# Focused source-binding, delivery, and Pi modal checks for ask-user-question.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-ask-user-question)
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}

make_adapter_fixture() {
  local fixture=$1
  mkdir -p "$fixture/root/bin" "$fixture/home/state"
  cp "$ROOT/bin/fm-ask-user-question.sh" "$fixture/root/bin/fm-ask-user-question.sh"
  cp "$ROOT/bin/fm-classify-lib.sh" "$fixture/root/bin/fm-classify-lib.sh"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$fixture/root/bin/fm-timeout-lib.sh"
  cat > "$fixture/root/bin/fm-session-lock-lib.sh" <<'SH'
fm_session_lock_owned_by_self() {
  if [ -n "${FM_LOCK_CHECK_LOG:-}" ]; then
    printf '%s\n' "$1" >> "$FM_LOCK_CHECK_LOG"
  fi
  [ "$(cat "$1/.lock" 2>/dev/null)" = owned ]
}
SH
  cat > "$fixture/root/bin/fm-send.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\0' "$@" >> "$FM_SEND_LOG"
if [ -n "${FM_SEND_STATE_LOG:-}" ]; then
  printf '%s\n' "${FM_STATE_OVERRIDE:-}" >> "$FM_SEND_STATE_LOG"
fi
SH
  chmod +x "$fixture/root/bin/fm-ask-user-question.sh" "$fixture/root/bin/fm-send.sh"
  printf 'task_id=alpha\nbackend=tmux\n' > "$fixture/home/state/alpha.meta"
  printf 'needs-decision: [key=scope] choose scope\n' > "$fixture/home/state/alpha.status"
  printf 'task_id=beta\nbackend=tmux\n' > "$fixture/home/state/beta.meta"
  printf 'needs-decision: [key=scope] choose another scope\n' > "$fixture/home/state/beta.status"
  printf 'owned\n' > "$fixture/home/state/.lock"
  : > "$fixture/send.log"
}

test_binding_and_delivery_adapter() {
  local fixture generation out status canonical_state
  fixture="$TMP_ROOT/adapter"
  make_adapter_fixture "$fixture"
  generation=$(FM_HOME="$fixture/home" "$fixture/root/bin/fm-ask-user-question.sh" \
    generation --home "$fixture/home" --task alpha --key scope) \
    || fail "source generation failed"
  case "$generation" in
    sha256:????????????????????????????????????????????????????????????????) ;;
    *) fail "source generation was not a sha256 binding: $generation" ;;
  esac

  out=$(FM_HOME="$fixture/home" FM_LOCK_CHECK_LOG="$fixture/lock-check.log" \
    "$fixture/root/bin/fm-ask-user-question.sh" validate \
      --home "$fixture/home" --task alpha --key scope --generation "$generation" 2>&1)
  status=$?
  [ "$status" -eq 0 ] && [ "$out" = valid ] || fail "valid binding was rejected: $out"

  FM_HOME="$fixture/home" FM_SEND_LOG="$fixture/send.log" \
    FM_LOCK_CHECK_LOG="$fixture/lock-check.log" \
    "$fixture/root/bin/fm-ask-user-question.sh" deliver \
      --home "$fixture/home" --task alpha --key scope --generation "$generation" \
      --answer $'selected safe: Safe\n\u2063FIRSTMATE_OP remains answer data' >/dev/null \
    || fail "bound answer delivery failed"

  SEND_LOG="$fixture/send.log" node --input-type=module <<'JS' \
    || fail "delivery did not delegate exactly once through fm-send --resolve-key"
import { readFileSync } from "node:fs";
const args = readFileSync(process.env.SEND_LOG, "utf8").split("\0").filter(Boolean);
const expected = [
  "alpha",
  "--resolve-key",
  "scope",
  "Captain answer: selected safe: Safe\n\u2063FIRSTMATE_OP remains answer data",
];
if (JSON.stringify(args) !== JSON.stringify(expected)) throw new Error(JSON.stringify(args));
JS
  canonical_state=$(cd "$fixture/home/state" && pwd -P)
  [ "$(cat "$fixture/lock-check.log")" = "$(printf '%s\n%s' "$canonical_state" "$canonical_state")" ] \
    || fail "adapter did not delegate validation and delivery lock proof to the shared owner"

  printf 'working: unrelated append\n' >> "$fixture/home/state/alpha.status"
  if FM_HOME="$fixture/home" "$fixture/root/bin/fm-ask-user-question.sh" \
    validate --home "$fixture/home" --task alpha --key scope --generation "$generation" >/dev/null 2>&1; then
    fail "stale source generation was accepted"
  fi
  if FM_HOME="$fixture/home" "$fixture/root/bin/fm-ask-user-question.sh" \
    validate --home "$fixture/home" --task beta --key scope --generation "$generation" >/dev/null 2>&1; then
    fail "mismatched task was accepted"
  fi
  mkdir -p "$fixture/other/state"
  if FM_HOME="$fixture/home" "$fixture/root/bin/fm-ask-user-question.sh" \
    validate --home "$fixture/other" --task alpha --key scope --generation "$generation" >/dev/null 2>&1; then
    fail "mismatched home was accepted"
  fi
  printf 'resolved: [key=scope] chose scope\n' >> "$fixture/home/state/alpha.status"
  if FM_HOME="$fixture/home" "$fixture/root/bin/fm-ask-user-question.sh" \
    generation --home "$fixture/home" --task alpha --key scope >/dev/null 2>&1; then
    fail "closed keyed decision received a new generation"
  fi
  pass "ask-user adapter binds home, task, key, and generation and delegates one literal answer through fm-send"
}

test_state_override_binding() {
  local fixture state_a state_b generation canonical_state
  fixture="$TMP_ROOT/state-override"
  make_adapter_fixture "$fixture"
  state_a="$fixture/state-a"
  state_b="$fixture/state-b"
  mkdir -p "$state_a" "$state_b"
  cp "$fixture/home/state/alpha.meta" "$state_a/alpha.meta"
  cp "$fixture/home/state/alpha.status" "$state_a/alpha.status"
  cp "$state_a/alpha.meta" "$state_b/alpha.meta"
  cp "$state_a/alpha.status" "$state_b/alpha.status"
  printf 'owned\n' > "$state_a/.lock"
  printf 'owned\n' > "$state_b/.lock"
  printf 'resolved: [key=scope] default tree is closed\n' > "$fixture/home/state/alpha.status"

  generation=$(FM_HOME="$fixture/home" FM_STATE_OVERRIDE="$state_a" \
    "$fixture/root/bin/fm-ask-user-question.sh" generation \
      --home "$fixture/home" --task alpha --key scope) \
    || fail "source generation ignored the active state override"

  FM_HOME="$fixture/home" FM_STATE_OVERRIDE="$state_a" \
    FM_SEND_LOG="$fixture/send.log" FM_SEND_STATE_LOG="$fixture/send-state.log" \
    "$fixture/root/bin/fm-ask-user-question.sh" deliver \
      --home "$fixture/home" --task alpha --key scope --generation "$generation" \
      --answer Safe >/dev/null \
    || fail "delivery did not use the active state override"
  canonical_state=$(cd "$state_a" && pwd -P)
  [ "$(cat "$fixture/send-state.log")" = "$canonical_state" ] \
    || fail "fm-send did not inherit the canonical active state path"

  if FM_HOME="$fixture/home" FM_STATE_OVERRIDE="$state_b" \
    "$fixture/root/bin/fm-ask-user-question.sh" validate \
      --home "$fixture/home" --task alpha --key scope --generation "$generation" >/dev/null 2>&1; then
    fail "generation from a different canonical state tree was accepted"
  fi
  pass "ask-user adapter binds generation, validation, and delivery to one canonical state override"
}

test_pi_state_override_integration() {
  local fixture generation out status canonical_state
  if ! command -v node >/dev/null 2>&1 || [ ! -f "$PI_PACKAGE_DIR/package.json" ]; then
    echo "skip: installed Pi package not found for ask-user-question state override integration test"
    return 0
  fi
  fixture="$TMP_ROOT/pi-state-override"
  make_adapter_fixture "$fixture"
  mkdir -p "$fixture/root/.pi/extensions" "$fixture/root/node_modules/@earendil-works" \
    "$fixture/active-state"
  cp "$ROOT/.pi/extensions/fm-ask-user-question.ts" "$fixture/root/.pi/extensions/fm-ask-user-question.ts"
  ln -s "$PI_PACKAGE_DIR" "$fixture/root/node_modules/@earendil-works/pi-coding-agent"
  ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-ai" "$fixture/root/node_modules/@earendil-works/pi-ai"
  ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$fixture/root/node_modules/@earendil-works/pi-tui"
  ln -s "$PI_PACKAGE_DIR/node_modules/typebox" "$fixture/root/node_modules/typebox"
  printf '%s\n' '{"type":"module"}' > "$fixture/root/package.json"
  cp "$fixture/home/state/alpha.meta" "$fixture/active-state/alpha.meta"
  cp "$fixture/home/state/alpha.status" "$fixture/active-state/alpha.status"
  printf 'resolved: [key=scope] default tree is closed\n' > "$fixture/home/state/alpha.status"
  printf '%s\n' 1 > "$fixture/home/state/.lock"
  printf 'owned\n' > "$fixture/active-state/.lock"
  canonical_state=$(cd "$fixture/active-state" && pwd -P)
  generation=$(FM_HOME="$fixture/home" FM_STATE_OVERRIDE="$fixture/active-state" \
    "$fixture/root/bin/fm-ask-user-question.sh" generation \
      --home "$fixture/home" --task alpha --key scope) \
    || fail "state override integration generation failed"

  out=$(cd "$fixture/root" && \
    FM_HOME="$fixture/home" \
    FM_STATE_OVERRIDE="$fixture/active-state" \
    FM_ASK_USER_QUESTION_FIXTURE=1 \
    FM_SEND_LOG="$fixture/send.log" \
    FM_SEND_STATE_LOG="$fixture/send-state.log" \
    FM_LOCK_CHECK_LOG="$fixture/lock-check.log" \
    GENERATION="$generation" \
    EXPECTED_STATE="$canonical_state" \
    EXT="$fixture/root/.pi/extensions/fm-ask-user-question.ts" \
    node --input-type=module 2>&1 <<'JS'
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const extension = await import(`${pathToFileURL(process.env.EXT).href}?fixture=${Date.now()}`);
delete process.env.FM_STATE_OVERRIDE;
let tool;
extension.default({
  registerTool(candidate) {
    if (candidate.name === "fm_ask_user_question") tool = candidate;
  },
});
if (!tool) throw new Error("fixture flag did not register the tool");

const theme = {
  fg(_color, text) { return text; },
  bg(_color, text) { return text; },
  bold(text) { return text; },
};
const ui = {
  custom(factory) {
    return new Promise((resolve, reject) => {
      try {
        const tui = { requestRender() {}, terminal: { rows: 40, columns: 80 } };
        const component = factory(tui, theme, {}, resolve);
        component.handleInput("\r");
      } catch (error) {
        reject(error);
      }
    });
  },
};
const result = await tool.execute("call", {
  home: process.env.FM_HOME,
  taskId: "alpha",
  decisionKey: "scope",
  sourceGeneration: process.env.GENERATION,
  mode: "single",
  question: "Choose",
  options: [{ id: "safe", label: "Safe" }],
}, new AbortController().signal, undefined, { mode: "tui", ui });
if (result.details.status !== "answered" || result.details.answers[0]?.id !== "safe") {
  throw new Error(`override-backed question was not answered: ${JSON.stringify(result.details)}`);
}
const args = readFileSync(process.env.FM_SEND_LOG, "utf8").split("\0").filter(Boolean);
const expectedArgs = [
  "alpha",
  "--resolve-key",
  "scope",
  "Captain answer: selected safe",
];
if (JSON.stringify(args) !== JSON.stringify(expectedArgs)) {
  throw new Error(`fm-send received wrong calls: ${JSON.stringify(args)}`);
}
const states = readFileSync(process.env.FM_SEND_STATE_LOG, "utf8").trim().split("\n");
if (states.length !== 1 || states[0] !== process.env.EXPECTED_STATE) {
  throw new Error(`fm-send inherited wrong state: ${JSON.stringify(states)}`);
}
const lockChecks = readFileSync(process.env.FM_LOCK_CHECK_LOG, "utf8").trim().split("\n");
if (lockChecks.length !== 2 || lockChecks.some((state) => state !== process.env.EXPECTED_STATE)) {
  throw new Error(`shared lock owner received wrong state: ${JSON.stringify(lockChecks)}`);
}
JS
  )
  status=$?
  [ "$status" -eq 0 ] || fail "Pi state override integration failed: $out"
  [ -z "$out" ] || fail "Pi state override integration printed output: $out"
  pass "Pi ask-user tool keeps one canonical override through modal delivery"
}

test_pi_modal_contract() {
  local fixture out status
  if ! command -v node >/dev/null 2>&1 || [ ! -f "$PI_PACKAGE_DIR/package.json" ]; then
    echo "skip: installed Pi package not found for ask-user-question modal test"
    return 0
  fi
  fixture="$TMP_ROOT/pi"
  mkdir -p "$fixture/project/.pi/extensions" "$fixture/project/node_modules/@earendil-works" \
    "$fixture/home/state" "$fixture/active-state"
  cp "$ROOT/.pi/extensions/fm-ask-user-question.ts" "$fixture/project/.pi/extensions/fm-ask-user-question.ts"
  ln -s "$PI_PACKAGE_DIR" "$fixture/project/node_modules/@earendil-works/pi-coding-agent"
  ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-ai" "$fixture/project/node_modules/@earendil-works/pi-ai"
  ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$fixture/project/node_modules/@earendil-works/pi-tui"
  ln -s "$PI_PACKAGE_DIR/node_modules/typebox" "$fixture/project/node_modules/typebox"
  printf '%s\n' '{"type":"module"}' > "$fixture/project/package.json"
  printf '%s\n' 1 > "$fixture/home/state/.lock"
  printf 'owned\n' > "$fixture/active-state/.lock"
  cat > "$fixture/adapter.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\0' "$@" >> "$FM_ASK_LOG"
command=$1
shift
task=
key=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --task) task=$2; shift 2 ;;
    --key) key=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ "$(cat "$FM_STATE_OVERRIDE/.lock" 2>/dev/null)" = owned ] || exit 2
[ "$task" != wrong-task ] || exit 2
[ "$key" != wrong-generation ] || exit 2
if [ "$command" = deliver ] && [ "$key" = stale-before-delivery ]; then
  {
    printf 'fm-send: answer queued\001 but decision close failed '
    i=0
    while [ "$i" -lt 600 ]; do printf x; i=$((i + 1)); done
    printf '\n'
  } >&2
  exit 2
fi
exit 0
SH
  chmod +x "$fixture/adapter.sh"
  : > "$fixture/adapter.log"

  out=$(cd "$fixture/project" && \
    FM_HOME="$fixture/home" \
    FM_STATE_OVERRIDE="$fixture/active-state" \
    FM_ASK_USER_QUESTION_FIXTURE=1 \
    FM_ASK_USER_QUESTION_ADAPTER="$fixture/adapter.sh" \
    FM_ASK_LOG="$fixture/adapter.log" \
    EXT="$fixture/project/.pi/extensions/fm-ask-user-question.ts" \
    node --input-type=module 2>&1 <<'JS'
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { visibleWidth } from "@earendil-works/pi-tui";

const extension = await import(`${pathToFileURL(process.env.EXT).href}?fixture=${Date.now()}`);
let tool;
const pi = {
  registerTool(candidate) {
    if (candidate.name === "fm_ask_user_question") tool = candidate;
  },
};
extension.default(pi);
if (!tool) throw new Error("fixture flag did not register the tool");

const theme = {
  fg(_color, text) { return text; },
  bg(_color, text) { return text; },
  bold(text) { return text; },
};
const generation = `sha256:${"0".repeat(64)}`;
const ENTER = "\r";
const DOWN = "\x1b[B";
const ESCAPE = "\x1b";
const base = {
  home: process.env.FM_HOME,
  taskId: "alpha",
  decisionKey: "scope",
  sourceGeneration: generation,
  mode: "single",
  question: "Choose",
  options: [{ id: "safe", label: "Safe" }],
};
const adapterLog = () => readFileSync(process.env.FM_ASK_LOG, "utf8").split("\0").filter(Boolean);
const deliveryCount = () => adapterLog().filter((value) => value === "deliver").length;
let customCalls = 0;
let activeModals = 0;
let maxActiveModals = 0;
let behavior = "single";
let resizeEvidence = false;

const ui = {
  custom(factory) {
    customCalls += 1;
    activeModals += 1;
    maxActiveModals = Math.max(maxActiveModals, activeModals);
    return new Promise((resolve, reject) => {
      const tui = { requestRender() {}, terminal: { rows: 40, columns: 80 } };
      const done = (result) => {
        activeModals -= 1;
        resolve(result);
      };
      let component;
      try {
        component = factory(tui, theme, {}, done);
        component.focused = true;
        const wide = component.render(72);
        const narrow = component.render(17);
        if (wide === narrow || narrow.some((line) => visibleWidth(line) > 17)) {
          throw new Error("resize cache did not honor the new width");
        }
        resizeEvidence = true;
        if (behavior === "throw") throw new Error("synthetic UI failure");
        if (behavior === "cancel") component.handleInput(ESCAPE);
        else if (behavior === "single") {
          component.handleInput(ENTER);
          component.handleInput(ENTER);
        } else if (behavior === "text") {
          for (const char of "free answer") component.handleInput(char);
          component.handleInput(ENTER);
        } else if (behavior === "multi") {
          component.handleInput(ENTER);
          component.handleInput(DOWN);
          component.handleInput(DOWN);
          component.handleInput(ENTER);
          for (const char of "custom") component.handleInput(char);
          component.handleInput(ENTER);
          component.handleInput(DOWN);
          component.handleInput(ENTER);
        } else if (behavior === "delayed") {
          setTimeout(() => component.handleInput(ENTER), 25);
        }
      } catch (error) {
        activeModals -= 1;
        reject(error);
      }
    });
  },
};
const tuiContext = { mode: "tui", ui };
const execute = (params, context = tuiContext) => tool.execute("call", params, new AbortController().signal, undefined, context);

let before = deliveryCount();
let result = await execute(base);
if (result.details.status !== "answered" || result.details.answers[0].id !== "safe" || deliveryCount() !== before + 1) {
  throw new Error("single-select did not deliver exactly one structured answer");
}

behavior = "text";
result = await execute({ ...base, decisionKey: "text", mode: "text", options: undefined, question: "Free text" });
if (result.details.answers[0]?.type !== "text" || result.details.answers[0]?.text !== "free answer") {
  throw new Error(`free text answer was not structured: ${JSON.stringify(result.details)}`);
}

behavior = "multi";
result = await execute({
  ...base,
  decisionKey: "multi",
  mode: "multi",
  allowOther: true,
  options: [{ id: "one", label: "One" }, { id: "two", label: "Two" }],
});
if (result.details.answers.length !== 2 || result.details.answers[0].id !== "one" || result.details.answers[1].text !== "custom") {
  throw new Error(`multi-select/Other result was wrong: ${JSON.stringify(result.details)}`);
}

behavior = "cancel";
before = deliveryCount();
result = await execute({ ...base, decisionKey: "cancel" });
if (result.details.status !== "cancelled" || result.details.reason !== "user" || deliveryCount() !== before) {
  throw new Error("cancellation delivered or lost structured cancellation");
}

before = customCalls;
result = await execute({ ...base, decisionKey: "no-ui" }, { mode: "print", ui });
if (result.details.reason !== "ui-unavailable" || customCalls !== before) {
  throw new Error("no-UI mode attempted to open a modal");
}

before = customCalls;
result = await execute({ ...base, taskId: "wrong-task" });
if (result.details.reason !== "binding-mismatch" || customCalls !== before) {
  throw new Error("task mismatch reached the modal");
}
result = await execute({ ...base, decisionKey: "wrong-generation" });
if (result.details.reason !== "binding-mismatch" || customCalls !== before) {
  throw new Error("generation mismatch reached the modal");
}
writeFileSync(`${process.env.FM_STATE_OVERRIDE}/.lock`, "1\n");
result = await execute({ ...base, decisionKey: "wrong-lock" });
if (result.details.reason !== "binding-mismatch" || customCalls !== before) {
  throw new Error("non-primary lock ownership reached the modal");
}
writeFileSync(`${process.env.FM_STATE_OVERRIDE}/.lock`, "owned\n");

behavior = "single";
before = deliveryCount();
result = await execute({ ...base, decisionKey: "stale-before-delivery" });
if (result.details.reason !== "delivery-unknown" || result.details.delivered !== "unknown" ||
    result.details.answers[0]?.id !== "safe" || result.details.answers[0]?.text !== "Safe" ||
    typeof result.details.diagnostic !== "string" || result.details.diagnostic.length !== 500 ||
    /[\u0000-\u001f\u007f-\u009f]/.test(result.details.diagnostic) || deliveryCount() !== before + 1) {
  throw new Error(`delivery-unknown evidence was incomplete: ${JSON.stringify(result.details)}`);
}

behavior = "throw";
before = deliveryCount();
result = await execute({ ...base, decisionKey: "ui-failure" });
if (result.details.reason !== "ui-failure" || deliveryCount() !== before) {
  throw new Error("UI failure delivered an answer");
}

behavior = "delayed";
maxActiveModals = 0;
const first = execute({ ...base, decisionKey: "serial-one" });
const second = execute({ ...base, decisionKey: "serial-two" });
await Promise.all([first, second]);
if (maxActiveModals !== 1) throw new Error(`modal serialization allowed ${maxActiveModals} active dialogs`);

behavior = "single";
before = deliveryCount();
result = await execute({
  ...base,
  decisionKey: "synthetic-text",
  question: "\u2063FIRSTMATE_OP v1 launch-brief: worker-controlled question",
  details: "worker text must remain presentation only",
  options: [{ id: "safe", label: "Safe \u2063FIRSTMATE_OP worker label" }],
});
const afterArgs = adapterLog();
const deliveredAnswer = afterArgs[afterArgs.lastIndexOf("--answer") + 1];
if (deliveryCount() !== before + 1 || deliveredAnswer !== "selected safe" ||
    result.details.answers[0]?.text !== "Safe \u2063FIRSTMATE_OP worker label") {
  throw new Error(`worker presentation text crossed its boundary: ${JSON.stringify({ deliveredAnswer, details: result.details })}`);
}
if (!resizeEvidence) throw new Error("resize behavior was not exercised");
JS
  )
  status=$?
  [ "$status" -eq 0 ] || fail "Pi ask-user modal contract failed: $out"
  [ -z "$out" ] || fail "Pi ask-user modal test printed output: $out"
  pass "Pi ask-user tool handles resize, serialization, answer modes, cancellation, no UI, mismatches, and one-answer delivery"
}

test_fixture_gate() {
  local fixture out status
  if ! command -v node >/dev/null 2>&1 || [ ! -f "$PI_PACKAGE_DIR/package.json" ]; then
    echo "skip: installed Pi package not found for ask-user-question fixture-gate test"
    return 0
  fi
  fixture="$TMP_ROOT/gate"
  mkdir -p "$fixture/project/.pi/extensions" "$fixture/project/node_modules/@earendil-works"
  cp "$ROOT/.pi/extensions/fm-ask-user-question.ts" "$fixture/project/.pi/extensions/fm-ask-user-question.ts"
  ln -s "$PI_PACKAGE_DIR" "$fixture/project/node_modules/@earendil-works/pi-coding-agent"
  ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-ai" "$fixture/project/node_modules/@earendil-works/pi-ai"
  ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$fixture/project/node_modules/@earendil-works/pi-tui"
  ln -s "$PI_PACKAGE_DIR/node_modules/typebox" "$fixture/project/node_modules/typebox"
  printf '%s\n' '{"type":"module"}' > "$fixture/project/package.json"
  out=$(EXT="$fixture/project/.pi/extensions/fm-ask-user-question.ts" node --input-type=module 2>&1 <<'JS'
import { pathToFileURL } from "node:url";
const extension = await import(pathToFileURL(process.env.EXT).href);
let registered = false;
extension.default({ registerTool() { registered = true; } });
if (registered) throw new Error("tool registered without the fixture flag");
JS
  )
  status=$?
  [ "$status" -eq 0 ] || fail "fixture gate failed: $out"
  [ -z "$out" ] || fail "fixture-gate test printed output: $out"
  pass "ask-user-question leaves production Pi behavior unchanged without its fixture flag"
}

test_binding_and_delivery_adapter
test_state_override_binding
test_pi_state_override_integration
test_pi_modal_contract
test_fixture_gate
