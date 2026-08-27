// Firstmate crewmate doorbell: in-process steering delivery for pi-harness
// crewmates (ship, scout, secondmate).
//
// The durable steering inbox (bin/fm-task-inbox-lib.sh) is the delivery: a steer
// is a record under state/<task>.inbox/. The terminal only needs a short constant
// doorbell line to tell the worker to read it. On a pi crewmate this extension
// owns that doorbell in-process: it polls the inbox, and when a new unhandled
// record arrives it injects the same constant doorbell line via
// pi.sendUserMessage with the deliverAs timing the record's deliver= header
// names - "steer" lands at the next turn boundary (mid-work correction),
// "followUp" lands when the agent fully stops (today's inbox semantics). It
// touches a liveness heartbeat stamp on every poll so bin/fm-task-inbox-lib.sh's
// fm_task_inbox_ring skips the typed ring while the extension is alive; a stale
// or absent stamp falls back to the typed-ring + re-ring ladder exactly as
// before, and a non-pi harness or an extension that is not loaded gets today's
// behavior bit-for-bit (no heartbeat file is ever written there).
//
// This extension is inert unless FM_TASK_ID names this session's task: the
// primary firstmate pi session auto-discovers it too, but it has no task inbox
// of its own, so it must neither poll nor register the fm_complete tool. A
// crewmate's fm-spawn launch sets FM_TASK_ID (and the -e load path is outside
// the worktree, so pi's project-trust gate does not fire on it).
//
// fm_complete is registered here as a Phase-2 stub that refuses: Phase 3 wires
// scout self-termination and replaces this body with the store-first gate (the
// tool refuses unless the task's status file tail already carries a terminal
// verb, then exits the process). No brief tells a worker to call fm_complete
// until Phase 3, so the stub is never reached in Phase 2.
//
// The doorbell line text is the stable self-describing contract owned by
// bin/fm-task-inbox-lib.sh (fm_task_inbox_doorbell_line); this file mirrors that
// exact string so a worker whose brief predates the in-process doorbell still
// receives the complete instruction in the line itself. Change both together.
import { readdirSync, readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const stateDir = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const taskId = process.env.FM_TASK_ID || "";
const pollMs = positiveInteger("FM_CREW_DOORBELL_POLL_MS", 5000);

function positiveInteger(name: string, fallback: number): number {
  const value = Number(process.env[name]);
  if (!Number.isFinite(value) || value <= 0) return fallback;
  return Math.floor(value);
}

// The constant self-describing doorbell line for this task's inbox. Mirrors
// bin/fm-task-inbox-lib.sh fm_task_inbox_doorbell_line exactly; that lib is the
// single owner of the wording, so update both together if it ever changes.
function doorbellLine(inboxDir: string): string {
  return `Firstmate instruction waiting: list ${inboxDir}/*.msg and, in numeric order, read and act on each, then mv each handled file to ${inboxDir}/handled/.`;
}

// The deliver= header of a record, defaulting to followUp when absent (the
// byte-compatible default for records written before the field existed).
function deliverModeOf(recordPath: string): "steer" | "followUp" {
  try {
    const text = readFileSync(recordPath, "utf8");
    for (const line of text.split("\n")) {
      if (line === "--") break;
      const m = line.match(/^deliver=(steer|followUp)$/);
      if (m) return m[1] as "steer" | "followUp";
    }
  } catch {
    // unreadable or gone: treat as the safe default
  }
  return "followUp";
}

function seqOf(name: string): number | null {
  const m = name.match(/^(\d+)\.msg$/);
  if (!m) return null;
  return Number(m[1]);
}

// Unhandled records in the inbox root, ascending by sequence.
function unhandledRecords(inboxDir: string): { path: string; seq: number }[] {
  let entries: string[];
  try {
    entries = readdirSync(inboxDir);
  } catch {
    return [];
  }
  const out: { path: string; seq: number }[] = [];
  for (const name of entries) {
    const seq = seqOf(name);
    if (seq === null) continue;
    out.push({ path: resolve(inboxDir, name), seq });
  }
  out.sort((a, b) => a.seq - b.seq);
  return out;
}

function touchHeartbeat(path: string): void {
  try {
    writeFileSync(path, String(Date.now()));
  } catch {
    // best-effort; a missing heartbeat just restores the typed-ring ladder
  }
}

export default function (pi: ExtensionAPI) {
  // Inert outside a crewmate session: no task inbox, no fm_complete tool.
  if (!taskId) return;

  const inboxDir = `${stateDir}/${taskId}.inbox`;
  const heartbeat = `${inboxDir}/.doorbell-heartbeat`;
  // Highest unhandled sequence this extension has already injected a doorbell
  // for. Starts at -1 so a freshly-started session catches up on any
  // pre-existing unhandled records with one doorbell before the heartbeat goes
  // fresh (otherwise the typed ring would be skipped for records we never
  // notified about).
  let notifiedSeq = -1;
  let timer: ReturnType<typeof setInterval> | null = null;

  function poll(): void {
    const records = unhandledRecords(inboxDir);
    const maxSeq = records.length > 0 ? records[records.length - 1].seq : -1;
    if (maxSeq > notifiedSeq) {
      // Inject one doorbell covering the whole inbox; the newest record's
      // deliver= names the timing (the latest instruction's urgency).
      const deliverAs = records[records.length - 1]
        ? deliverModeOf(records[records.length - 1].path)
        : "followUp";
      try {
        void pi.sendUserMessage(doorbellLine(inboxDir), { deliverAs });
      } catch {
        // sendUserMessage throws when streaming without deliverAs; we always
        // pass it, so this is unreachable in practice. Swallow to keep polling.
      }
      notifiedSeq = maxSeq;
    }
    touchHeartbeat(heartbeat);
  }

  function start(): void {
    try {
      mkdirSync(inboxDir, { recursive: true });
    } catch {
      // inbox is created on first steer; polling still touches the heartbeat
      // best-effort so the typed-ring ladder keeps owning delivery until then
    }
    if (timer) clearInterval(timer);
    poll();
    timer = setInterval(poll, pollMs);
  }

  function stop(): void {
    if (timer) {
      clearInterval(timer);
      timer = null;
    }
  }

  pi.on("session_start", () => start());
  pi.on("session_shutdown", () => stop());

  // Phase-2 stub: Phase 3 replaces this body with the store-first gate (refuse
  // unless the task status tail carries done:/failed:, then exit the process).
  // Registered only inside a crewmate session, never in the primary firstmate.
  pi.registerTool?.({
    name: "fm_complete",
    label: "Complete task",
    description:
      "Mark this task complete and exit cleanly. Appends nothing itself; Phase 3 wires the store-first gate that requires a terminal status line first. Until then this tool is not active - append done: or failed: to your status file and exit via your normal mechanism.",
    promptSnippet:
      "Mark the task complete and exit; not active until self-termination wiring is in place.",
    promptGuidelines: [
      "fm_complete is not active until self-termination wiring lands; do not call it. Append done: or failed: to your status file and exit via your normal mechanism instead.",
    ],
    parameters: Type.Object({}),
    async execute() {
      return {
        content: [
          {
            type: "text",
            text: "fm_complete is not active yet (self-termination wiring is Phase 3). Append done: or failed: to your status file and exit via your normal mechanism.",
          },
        ],
        details: {},
      };
    },
  });
}
