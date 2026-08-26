import { cpSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";
import { resolve } from "node:path";

const evidence = process.env.EVIDENCE_DIR;
const root = process.env.WORKTREE;
const piPackage = process.env.PI_PACKAGE_DIR;
const fixture = `${evidence}/.ask-user-fixture`;
rmSync(fixture, { recursive: true, force: true });
mkdirSync(`${fixture}/project/.pi/extensions`, { recursive: true });
mkdirSync(`${fixture}/project/node_modules/@earendil-works`, { recursive: true });
mkdirSync(`${fixture}/home/state`, { recursive: true });
cpSync(`${root}/.pi/extensions/fm-ask-user-question.ts`, `${fixture}/project/.pi/extensions/fm-ask-user-question.ts`);
symlinkSync(piPackage, `${fixture}/project/node_modules/@earendil-works/pi-coding-agent`);
symlinkSync(`${piPackage}/node_modules/@earendil-works/pi-ai`, `${fixture}/project/node_modules/@earendil-works/pi-ai`);
symlinkSync(`${piPackage}/node_modules/@earendil-works/pi-tui`, `${fixture}/project/node_modules/@earendil-works/pi-tui`);
symlinkSync(`${piPackage}/node_modules/typebox`, `${fixture}/project/node_modules/typebox`);
writeFileSync(`${fixture}/project/package.json`, '{"type":"module"}\n');
writeFileSync(`${fixture}/home/state/.lock`, "owned\n");
writeFileSync(`${fixture}/adapter.log`, "");
writeFileSync(`${fixture}/owner.log`, "");
writeFileSync(`${fixture}/adapter.sh`, `#!/usr/bin/env bash
set -eu
printf '%s\\0' "$@" >> "$FM_ASK_LOG"
command=$1
shift
key=
answer=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --key) key=$2; shift 2 ;;
    --answer) answer=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ "$command" = validate ] && exit 0
[ "$FM_ASK_USER_QUESTION_OWNER_ENTRY_FD" = 3 ]
printf '%s\\n' "$FM_ASK_USER_QUESTION_OWNER_ENTRY_MARKER" >&3
printf '%s\\t%s\\n' "$key" "$answer" >> "$FM_OWNER_LOG"
`);
execFileSync("chmod", ["+x", `${fixture}/adapter.sh`]);

process.env.FM_HOME = `${fixture}/home`;
process.env.FM_STATE_OVERRIDE = `${fixture}/home/state`;
process.env.FM_ASK_USER_QUESTION_FIXTURE = "1";
process.env.FM_ASK_USER_QUESTION_ADAPTER = `${fixture}/adapter.sh`;
process.env.FM_ASK_LOG = `${fixture}/adapter.log`;
process.env.FM_OWNER_LOG = `${fixture}/owner.log`;
const extensionPath = `${fixture}/project/.pi/extensions/fm-ask-user-question.ts`;
const extension = await import(`${pathToFileURL(extensionPath).href}?evidence=${Date.now()}`);
let tool;
extension.default({ registerTool(candidate) { tool = candidate; } });
if (!tool) throw new Error("fixture tool was not registered");

const theme = { fg(_color, text) { return text; }, bg(_color, text) { return text; }, bold(text) { return text; } };
const ENTER = "\r", DOWN = "\x1b[B", ESC = "\x1b";
const frames = [];
let behavior = "multi";
const ui = {
  custom(factory) {
    return new Promise((resolveDone, reject) => {
      try {
        const tui = { requestRender() {}, terminal: { rows: 40, columns: 80 } };
        const component = factory(tui, theme, {}, resolveDone);
        component.focused = true;
        frames.push({ label: behavior === "multi" ? "Multi-select · wide terminal" : "Cancellation · decision remains open", width: 72, lines: component.render(72) });
        if (behavior === "multi") {
          frames.push({ label: "Same dialog after terminal resize", width: 30, lines: component.render(30) });
          component.handleInput(ENTER); // select first stable option
          component.handleInput(DOWN);
          component.handleInput(DOWN);
          component.handleInput(ENTER); // edit Other
          for (const char of "custom") component.handleInput(char);
          frames.push({ label: "Other free text in progress", width: 72, lines: component.render(72) });
          component.handleInput(ENTER); // keep Other and return to choices
          component.handleInput(DOWN); // Submit selected answers
          frames.push({ label: "Ready to submit selected + Other", width: 72, lines: component.render(72) });
          component.handleInput(ENTER);
        } else {
          component.handleInput(ESC);
        }
      } catch (error) { reject(error); }
    });
  },
};
const context = { mode: "tui", ui };
const generation = `sha256:${"a".repeat(64)}`;
const base = {
  home: process.env.FM_HOME,
  taskId: "alpha",
  decisionKey: "scope",
  sourceGeneration: generation,
  mode: "multi",
  question: "Which rollout should Firstmate use?",
  details: "Choose one or more safe paths. Worker text is presentation only.",
  options: [
    { id: "safe", label: "Safe rollout", description: "Stage the change behind the fixture boundary." },
    { id: "fast", label: "Fast rollout", description: "Use the smallest bounded rollout." },
  ],
  allowOther: true,
};
const answered = await tool.execute("evidence-answer", base, new AbortController().signal, undefined, context);
behavior = "cancel";
const cancelled = await tool.execute("evidence-cancel", { ...base, taskId: "beta", decisionKey: "cancel", mode: "single", allowOther: false }, new AbortController().signal, undefined, context);
const deliveries = readFileSync(`${fixture}/owner.log`, "utf8").trim().split("\n").filter(Boolean);
if (answered.details.status !== "answered" || answered.details.delivered !== true) throw new Error(JSON.stringify(answered.details));
if (cancelled.details.status !== "cancelled" || cancelled.details.reason !== "user" || cancelled.details.delivered !== false) throw new Error(JSON.stringify(cancelled.details));
if (deliveries.length !== 1 || deliveries[0] !== "scope\tselected safe; other: custom") throw new Error(JSON.stringify(deliveries));
const payload = { schema: "fm-ask-user-question-evidence.v1", commit: process.env.TARGET_COMMIT, frames, answered: answered.details, cancelled: cancelled.details, ownerDeliveries: deliveries };
writeFileSync(`${evidence}/ask-user-question-results.json`, JSON.stringify(payload, null, 2) + "\n");
const esc = (s) => String(s).replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
const frameHtml = frames.map((frame) => `<section class="frame"><div class="frame-title">${esc(frame.label)} <span>${frame.width} cols</span></div><pre style="max-width:${frame.width}ch">${esc(frame.lines.join("\n"))}</pre></section>`).join("\n");
const html = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Firstmate Ask Captain evidence</title><style>
:root{color-scheme:dark;font-family:ui-sans-serif,system-ui;background:#07111f;color:#dce8f8}body{margin:0;padding:36px;background:radial-gradient(circle at top right,#16345a,#07111f 45%)}main{max-width:1100px;margin:auto}h1{font-size:30px;margin:0 0 8px}.lede{color:#9eb2cd;margin:0 0 26px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(310px,1fr));gap:18px}.frame,.result{background:#0c192a;border:1px solid #294568;border-radius:12px;box-shadow:0 14px 35px #0008;overflow:hidden}.frame-title{padding:11px 14px;background:#11243b;color:#7fc4ff;font-weight:700}.frame-title span{float:right;color:#8098b6;font-weight:500}pre{margin:0;padding:16px;white-space:pre-wrap;color:#e9f2ff;font:14px/1.45 ui-monospace,SFMono-Regular,Consolas,monospace}.results{display:grid;grid-template-columns:repeat(auto-fit,minmax(270px,1fr));gap:18px;margin-top:18px}.result{padding:18px}.result h2{font-size:16px;margin:0 0 12px;color:#7fc4ff}.ok{color:#80e6af;font-weight:800}.cancel{color:#ffd082;font-weight:800}code{color:#dce8f8}.meta{margin-top:22px;color:#8098b6;font-size:13px}</style></head><body><main><h1>Ask Captain · executable UI evidence</h1><p class="lede">The tracked Pi extension rendered these modal states, handled resize and Other input, then returned structured results through the fixture-stage owner boundary.</p><div class="grid">${frameHtml}</div><div class="results"><section class="result"><h2>Answered result</h2><div class="ok">answered · delivered=true</div><pre>${esc(JSON.stringify(answered.details, null, 2))}</pre></section><section class="result"><h2>Cancelled result</h2><div class="cancel">cancelled · delivered=false</div><pre>${esc(JSON.stringify(cancelled.details, null, 2))}</pre></section><section class="result"><h2>Owner boundary</h2><div class="ok">Exactly one delivery</div><pre>${esc(deliveries.join("\n"))}</pre></section></div><div class="meta">Target ${esc(process.env.TARGET_COMMIT)} · executable source: .pi/extensions/fm-ask-user-question.ts</div></main></body></html>`;
writeFileSync(`${evidence}/ask-user-question-ui.html`, html);
rmSync(fixture, { recursive: true, force: true });
console.log(`answered=${answered.details.status} delivered=${answered.details.delivered}`);
console.log(`cancelled=${cancelled.details.status} reason=${cancelled.details.reason} delivered=${cancelled.details.delivered}`);
console.log(`owner_deliveries=${deliveries.length} payload=${deliveries[0]}`);
console.log(`artifact=${evidence}/ask-user-question-ui.html`);
