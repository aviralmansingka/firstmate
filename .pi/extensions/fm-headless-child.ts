// Firstmate headless reasoning child: appends one JSON line per run to
// state/<parent>.children.jsonl so the fleet snapshot exposes the parent's
// headless children as tasks[].children[] (design §C.2, Phase 5).
//
// A headless child is context-protecting fan-out: no pane, no steering channel,
// seconds-lived, parent-attributed. The last assistant message IS the answer.
// This extension is inert unless FM_TASK_ID and FM_PARENT_TASK are both set: a
// pane-visible crewmate or the primary firstmate has no parent sidecar to
// write. On session_start it appends `{agent, task_excerpt, state}` to the
// PARENT's children.jsonl (latest-wins on read); on agent_settled it updates
// the trailing line's state. The sidecar is read-only to the fleet snapshot.
import { appendFileSync, readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const stateDir = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const taskId = process.env.FM_TASK_ID || "";
const parentTask = process.env.FM_PARENT_TASK || "";

function sidecarPath(): string {
  return `${stateDir}/${parentTask}.children.jsonl`;
}

function appendChild(state: string): void {
  if (!taskId || !parentTask) return;
  try {
    mkdirSync(stateDir, { recursive: true });
    const line = JSON.stringify({
      agent: `fm-${taskId}`,
      task_excerpt: "",
      state,
      at: new Date().toISOString(),
    });
    appendFileSync(sidecarPath(), `${line}\n`);
  } catch {
    // best-effort; a missing sidecar just means the snapshot shows no children
  }
}

export default function (pi: ExtensionAPI) {
  if (!taskId || !parentTask) return;
  pi.on("session_start", () => appendChild("running"));
  pi.on("agent_settled", () => appendChild("settled"));
}
