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
// fm_complete is the scout self-termination tool (Phase 3). It enforces a
// store-first gate: it refuses unless the task's status file tail already
// carries a terminal verb (done: or failed:), so the durable record lands before
// the process ever exits - the same discipline as branch outcomes. When the gate
// holds, it schedules the process exit for the agent_settled boundary (the
// "will not run again" moment, NOT turn_end, because auto-retries and queued
// follow-ups keep a run un-settled past individual turn boundaries). If the
// agent is already idle when fm_complete is called, the exit is immediate.
// Ships (v1 needs a landed-precondition before exit) and secondmates (never
// self-terminate) do not call fm_complete; their briefs never mention it.
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

// The most recent terminal verb in the status file tail, or empty when none.
// The store-first gate refuses fm_complete unless this is done or failed.
function terminalVerbOf(statusPath: string): string {
  let text: string;
  try {
    text = readFileSync(statusPath, "utf8");
  } catch {
    return "";
  }
  const lines = text.split("\n");
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i].trim();
    if (!line) continue;
    const m = line.match(/^(done|failed):/);
    if (m) return m[1];
    // The first non-empty trailing line is the status tail; if it is not a
    // terminal verb, nothing later in the file is either.
    return "";
  }
  return "";
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

  // Phase 3: scout self-termination with a store-first gate. The tool refuses
  // unless the task's status file tail already carries done: or failed: (the
  // durable record lands before the process ever exits). When the gate holds,
  // the exit is scheduled for agent_settled - the "will not run again"
  // boundary, not turn_end - so auto-retries and queued follow-ups complete
  // first. If the agent is already idle, the exit is immediate. Ships and
  // secondmates never call this (no brief mentions it); the fm-spawn meta
  // self_terminate=expected is what tells the branch observer this exit is a
  // clean self-termination (🏁), not a wedge (🛑).
  let settleExitArmed = false;
  const statusPath = `${stateDir}/${taskId}.status`;
  function armExit(): void {
    if (settleExitArmed) return;
    settleExitArmed = true;
    pi.on("agent_settled", () => process.exit(0));
  }
  pi.registerTool?.({
    name: "fm_complete",
    label: "Complete and exit",
    description:
      "Mark this scout task complete and exit cleanly. STORE-FIRST GATE: append `done: <one-line summary>` (or `failed: <reason>`) to your status file FIRST, then call this tool. It refuses unless the status file tail already carries done: or failed:. On success the process exits at the agent_settled boundary (after any auto-retries or queued follow-ups finish). Only scouts call this; ships and secondmates never do.",
    promptSnippet:
      "Append done: or failed: to the status file, then call fm_complete to exit cleanly. Refuses without a terminal status line.",
    promptGuidelines: [
      "Append `done: <summary>` or `failed: <reason>` to the status file BEFORE calling fm_complete; it refuses without a terminal status line.",
      "Call fm_complete exactly once at the very end of the task; it exits the process at agent_settled.",
      "Only scouts call fm_complete; ships and secondmates never do.",
    ],
    parameters: Type.Object({}),
    async execute() {
      const verb = terminalVerbOf(statusPath);
      if (verb !== "done" && verb !== "failed") {
        return {
          content: [
            {
              type: "text",
              text: "fm_complete refused: no terminal status line found. Append `done: <one-line summary>` or `failed: <reason>` to your status file FIRST, then call fm_complete again. The durable record must land before the process exits.",
            },
          ],
          details: undefined,
          isError: true,
        };
      }
      armExit();
      return {
        content: [
          {
            type: "text",
            text: `Terminal status \`${verb}:\` confirmed. The process will exit at the agent_settled boundary (after any auto-retries or queued follow-ups finish). Do not call any more tools.",
          },
        ],
        details: undefined,
      };
    },
  });
}
