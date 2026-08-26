import { spawn, spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { realpathSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { StringDecoder } from "node:string_decoder";
import { fileURLToPath } from "node:url";
import { StringEnum } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import {
  Editor,
  type EditorTheme,
  Key,
  matchesKey,
  Text,
  truncateToWidth,
  visibleWidth,
  wrapTextWithAnsi,
} from "@earendil-works/pi-tui";
import { Type } from "typebox";

const fixtureEnabled = process.env.FM_ASK_USER_QUESTION_FIXTURE === "1";
const extensionFile = fileURLToPath(import.meta.url);
const root = resolve(dirname(extensionFile), "../..");
const activeHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const configuredState = process.env.FM_STATE_OVERRIDE || `${activeHome}/state`;
let activeState = configuredState;
try {
  activeState = realpathSync(configuredState);
} catch {
  activeState = configuredState;
}
const adapter = process.env.FM_ASK_USER_QUESTION_ADAPTER || `${root}/bin/fm-ask-user-question.sh`;

const OptionSchema = Type.Object({
  id: Type.String({ description: "Stable answer identifier" }),
  label: Type.String({ description: "Captain-facing option label" }),
  description: Type.Optional(Type.String({ description: "Short option explanation" })),
});

const ParamsSchema = Type.Object({
  home: Type.String({ description: "Explicit Firstmate home that owns the task" }),
  taskId: Type.String({ description: "Exact Firstmate task id" }),
  decisionKey: Type.String({ description: "Exact open decision key" }),
  sourceGeneration: Type.String({ description: "Generation returned by fm-ask-user-question.sh generation" }),
  mode: StringEnum(["text", "single", "multi"] as const),
  question: Type.String({ description: "Question shown to the captain" }),
  details: Type.Optional(Type.String({ description: "Optional context shown below the question" })),
  options: Type.Optional(Type.Array(OptionSchema, { description: "Options for single or multi mode" })),
  allowOther: Type.Optional(Type.Boolean({ description: "Offer a free-text Other answer" })),
});

type QuestionOption = {
  id: string;
  label: string;
  description?: string;
};

type QuestionParams = {
  home: string;
  taskId: string;
  decisionKey: string;
  sourceGeneration: string;
  mode: "text" | "single" | "multi";
  question: string;
  details?: string;
  options?: QuestionOption[];
  allowOther?: boolean;
};

type AnswerItem = {
  type: "text" | "option" | "other";
  id?: string;
  text: string;
};

type AnswerDetails = {
  schema: "fm-captain-answer.v1";
  status: "answered" | "cancelled";
  home: string;
  taskId: string;
  decisionKey: string;
  sourceGeneration: string;
  mode: QuestionParams["mode"];
  answers: AnswerItem[];
  delivered: boolean | "unknown";
  reason?: "user" | "aborted" | "ui-unavailable" | "ui-failure" | "binding-mismatch" | "delivery-unknown";
  diagnostic?: string;
};

type ModalResult = {
  cancelled: boolean;
  reason?: "user" | "aborted";
  answers: AnswerItem[];
};

let modalTail: Promise<void> = Promise.resolve();

async function withPrimaryModal<T>(show: () => Promise<T>): Promise<T> {
  const previous = modalTail.catch(() => undefined);
  let release = (): void => undefined;
  const gate = new Promise<void>((resolveGate) => {
    release = resolveGate;
  });
  modalTail = previous.then(() => gate);
  await previous;
  try {
    return await show();
  } finally {
    release();
  }
}

function cleanDisplay(value: string, limit: number): string {
  return value.replace(/[\u0000-\u001f\u007f-\u009f]/g, " ").replace(/\s+/g, " ").trim().slice(0, limit);
}

function cleanAnswer(value: string): string {
  return cleanDisplay(value, 1000);
}

function cancelled(
  params: QuestionParams,
  reason: AnswerDetails["reason"],
  text: string,
  delivered: false | "unknown" = false,
  answers: AnswerItem[] = [],
  diagnostic?: string,
) {
  const details: AnswerDetails = {
    schema: "fm-captain-answer.v1",
    status: "cancelled",
    home: params.home,
    taskId: params.taskId,
    decisionKey: params.decisionKey,
    sourceGeneration: params.sourceGeneration,
    mode: params.mode,
    answers,
    delivered,
    reason,
    ...(diagnostic ? { diagnostic } : {}),
  };
  return { content: [{ type: "text" as const, text }], details };
}

function adapterArgs(command: "validate" | "deliver", params: QuestionParams, answer?: string): string[] {
  const args = [
    command,
    "--home", params.home,
    "--task", params.taskId,
    "--key", params.decisionKey,
    "--generation", params.sourceGeneration,
  ];
  if (answer !== undefined) args.push("--answer", answer);
  return args;
}

function validateAdapter(params: QuestionParams) {
  return spawnSync(adapter, adapterArgs("validate", params), {
    encoding: "utf8",
    env: { ...process.env, FM_HOME: activeHome, FM_STATE_OVERRIDE: activeState },
    timeout: 10_000,
  });
}

type DeliveryResult = {
  status: number | null;
  signal: NodeJS.Signals | null;
  ownerEntered: boolean;
  diagnostic: string;
};

function deliverAdapter(params: QuestionParams, answer: string): Promise<DeliveryResult> {
  const marker = `fm-owner-entry-v1:${randomBytes(16).toString("hex")}`;
  const child = spawn(adapter, adapterArgs("deliver", params, answer), {
    env: {
      ...process.env,
      FM_HOME: activeHome,
      FM_STATE_OVERRIDE: activeState,
      FM_ASK_USER_QUESTION_OWNER_ENTRY_FD: "3",
      FM_ASK_USER_QUESTION_OWNER_ENTRY_MARKER: marker,
    },
    stdio: ["ignore", "pipe", "pipe", "pipe"],
  });

  return new Promise((resolveDelivery) => {
    let ownerEntered = false;
    let ownerOutput = "";
    let diagnostic = "";
    const stdoutDecoder = new StringDecoder("utf8");
    const stderrDecoder = new StringDecoder("utf8");
    const appendDiagnostic = (value: string): void => {
      const clean = value
        .replace(/[\u0000-\u001f\u007f-\u009f]/g, " ")
        .replace(/\s+/g, " ");
      diagnostic = `${diagnostic}${clean}`.replace(/\s+/g, " ").trim().slice(-500);
    };
    const ownerEntry = child.stdio[3] as NodeJS.ReadableStream | null;

    child.stdout?.on("data", (chunk: Buffer) => appendDiagnostic(stdoutDecoder.write(chunk)));
    child.stdout?.on("end", () => appendDiagnostic(stdoutDecoder.end()));
    child.stderr?.on("data", (chunk: Buffer) => appendDiagnostic(stderrDecoder.write(chunk)));
    child.stderr?.on("end", () => appendDiagnostic(stderrDecoder.end()));
    ownerEntry?.on("data", (chunk: Buffer) => {
      if (ownerEntered) return;
      ownerOutput = `${ownerOutput}${chunk.toString("utf8")}`.slice(0, marker.length + 1);
      ownerEntered = ownerOutput === `${marker}\n`;
    });
    child.once("error", (error) => appendDiagnostic(error.message));
    child.once("close", (status, signal) => {
      resolveDelivery({
        status,
        signal,
        ownerEntered,
        diagnostic: diagnostic || `Firstmate delivery owner exited with ${signal ? `signal ${signal}` : `status ${status ?? "unknown"}`}.`,
      });
    });
  });
}

function normalize(params: QuestionParams): QuestionParams | undefined {
  if (params.home.includes("\0")) return undefined;
  if (!/^[A-Za-z0-9._-]+$/.test(params.taskId) || !/^[A-Za-z0-9._-]+$/.test(params.decisionKey)) return undefined;
  if (!/^sha256:[0-9a-f]{64}$/.test(params.sourceGeneration)) return undefined;
  const question = cleanDisplay(params.question, 500);
  const details = params.details ? cleanDisplay(params.details, 1000) : undefined;
  const options = (params.options || []).slice(0, 12).map((option) => ({
    id: cleanDisplay(option.id, 80),
    label: cleanDisplay(option.label, 160),
    description: option.description ? cleanDisplay(option.description, 300) : undefined,
  }));
  if (!question) return undefined;
  if (new Set(options.map((option) => option.id)).size !== options.length) return undefined;
  if (options.some((option) => !/^[A-Za-z0-9._-]+$/.test(option.id) || !option.label)) return undefined;
  if (params.mode !== "text" && options.length === 0 && params.allowOther !== true) return undefined;
  return { ...params, question, details, options };
}

function deliveryText(answers: AnswerItem[]): string {
  return answers.map((answer) => {
    if (answer.type === "option") return `selected ${answer.id}`;
    if (answer.type === "other") return `other: ${answer.text}`;
    return answer.text;
  }).join("; ");
}

function showQuestion(params: QuestionParams, signal: AbortSignal, ctx: ExtensionContext) {
  return ctx.ui.custom<ModalResult>((tui, theme, _keybindings, done) => {
    const options = params.options || [];
    const allowOther = params.allowOther === true;
    const selected = new Set<string>();
    let optionIndex = 0;
    let editing = params.mode === "text";
    let finished = false;
    let cacheWidth = -1;
    let cachedLines: string[] | undefined;
    const editorTheme: EditorTheme = {
      borderColor: (text) => theme.fg("accent", text),
      selectList: {
        selectedPrefix: (text) => theme.fg("accent", text),
        selectedText: (text) => theme.fg("accent", text),
        description: (text) => theme.fg("muted", text),
        scrollInfo: (text) => theme.fg("dim", text),
        noMatch: (text) => theme.fg("warning", text),
      },
    };
    const editor = new Editor(tui, editorTheme);

    const refresh = (): void => {
      cachedLines = undefined;
      tui.requestRender();
    };
    const finish = (result: ModalResult): void => {
      if (finished) return;
      finished = true;
      signal.removeEventListener("abort", abort);
      done(result);
    };
    const abort = (): void => finish({ cancelled: true, reason: "aborted", answers: [] });
    signal.addEventListener("abort", abort, { once: true });
    if (signal.aborted) abort();

    const submitEditor = (value: string): void => {
      const text = cleanAnswer(value);
      if (!text) return;
      if (params.mode === "text") {
        finish({ cancelled: false, answers: [{ type: "text", text }] });
        return;
      }
      if (params.mode === "single") {
        finish({ cancelled: false, answers: [{ type: "other", text }] });
        return;
      }
      editing = false;
      editor.setText(text);
      refresh();
    };
    editor.onSubmit = submitEditor;

    const submitMulti = (): void => {
      const answers: AnswerItem[] = options
        .filter((option) => selected.has(option.id))
        .map((option) => ({ type: "option", id: option.id, text: option.label }));
      const other = cleanAnswer(editor.getText());
      if (other) answers.push({ type: "other", text: other });
      if (answers.length > 0) finish({ cancelled: false, answers });
    };

    const rowCount = (): number => options.length + (allowOther ? 1 : 0) + (params.mode === "multi" ? 1 : 0);

    const handleInput = (data: string): void => {
      if (finished) return;
      if (matchesKey(data, Key.escape)) {
        finish({ cancelled: true, reason: "user", answers: [] });
        return;
      }
      if (editing) {
        editor.handleInput(data);
        refresh();
        return;
      }
      if (matchesKey(data, Key.up)) {
        optionIndex = Math.max(0, optionIndex - 1);
        refresh();
        return;
      }
      if (matchesKey(data, Key.down)) {
        optionIndex = Math.min(Math.max(0, rowCount() - 1), optionIndex + 1);
        refresh();
        return;
      }
      if (!matchesKey(data, Key.enter)) return;
      if (optionIndex < options.length) {
        const option = options[optionIndex];
        if (params.mode === "multi") {
          if (selected.has(option.id)) selected.delete(option.id);
          else selected.add(option.id);
          refresh();
        } else {
          finish({ cancelled: false, answers: [{ type: "option", id: option.id, text: option.label }] });
        }
        return;
      }
      if (allowOther && optionIndex === options.length) {
        editing = true;
        editor.setText(params.mode === "multi" ? editor.getText() : "");
        refresh();
        return;
      }
      submitMulti();
    };

    const render = (width: number): string[] => {
      const renderWidth = Math.max(1, width);
      if (cachedLines && cacheWidth === renderWidth) return cachedLines;
      cacheWidth = renderWidth;
      const lines: string[] = [];
      const add = (text: string): void => {
        const wrapped = wrapTextWithAnsi(text, renderWidth);
        lines.push(...(wrapped.length > 0 ? wrapped : [""]));
      };
      const addRow = (prefix: string, text: string): void => {
        const prefixWidth = visibleWidth(prefix);
        if (prefixWidth >= renderWidth) {
          add(`${prefix}${text}`);
          return;
        }
        const wrapped = wrapTextWithAnsi(text, renderWidth - prefixWidth);
        wrapped.forEach((line, index) => lines.push(`${index === 0 ? prefix : " ".repeat(prefixWidth)}${line}`));
      };

      lines.push(theme.fg("accent", "─".repeat(renderWidth)));
      addRow(" ", theme.fg("accent", theme.bold(`Captain decision · ${params.taskId} · ${params.decisionKey}`)));
      addRow(" ", theme.fg("text", params.question));
      if (params.details) addRow(" ", theme.fg("muted", params.details));
      lines.push("");

      if (editing) {
        addRow(" ", theme.fg("muted", params.mode === "multi" ? "Other answer:" : "Your answer:"));
        editor.render(Math.max(1, renderWidth - 2)).forEach((line) => lines.push(truncateToWidth(` ${line}`, renderWidth)));
      } else {
        options.forEach((option, index) => {
          const cursor = index === optionIndex ? "> " : "  ";
          const mark = params.mode === "multi" ? (selected.has(option.id) ? "[x] " : "[ ] ") : "";
          addRow(cursor, theme.fg(index === optionIndex ? "accent" : "text", `${mark}${option.label}`));
          if (option.description) addRow("      ", theme.fg("muted", option.description));
        });
        if (allowOther) {
          const index = options.length;
          const other = cleanAnswer(editor.getText());
          addRow(index === optionIndex ? "> " : "  ", theme.fg(index === optionIndex ? "accent" : "text", other ? `Other: ${other}` : "Other..."));
        }
        if (params.mode === "multi") {
          const index = options.length + (allowOther ? 1 : 0);
          addRow(index === optionIndex ? "> " : "  ", theme.fg(index === optionIndex ? "accent" : "success", "Submit selected answers"));
        }
      }

      lines.push("");
      addRow(" ", theme.fg("dim", editing ? "Enter submits · Esc cancels" : "↑↓ navigate · Enter selects · Esc cancels"));
      lines.push(theme.fg("accent", "─".repeat(renderWidth)));
      cachedLines = lines.map((line) => truncateToWidth(line, renderWidth));
      return cachedLines;
    };

    return {
      render,
      invalidate: refresh,
      handleInput,
      get focused() { return editor.focused; },
      set focused(value: boolean) { editor.focused = value; },
      dispose: () => signal.removeEventListener("abort", abort),
    };
  });
}

export default function askUserQuestion(pi: ExtensionAPI): void {
  if (!fixtureEnabled) return;
  pi.registerTool({
    name: "fm_ask_user_question",
    label: "Ask Captain",
    description: "Fixture-stage primary-only dialog for one already-open keyed Firstmate decision.",
    parameters: ParamsSchema,
    executionMode: "sequential",
    async execute(_toolCallId, rawParams, signal, _onUpdate, ctx) {
      const params = normalize(rawParams as QuestionParams);
      const abortSignal = signal || new AbortController().signal;
      if (!params) return cancelled(rawParams as QuestionParams, "binding-mismatch", "Captain dialog rejected invalid input.");
      if (ctx.mode !== "tui") return cancelled(params, "ui-unavailable", "Captain dialog requires the primary Pi TUI.");

      return withPrimaryModal(async () => {
        if (abortSignal.aborted) return cancelled(params, "aborted", "Captain dialog was cancelled before display.");
        const validation = validateAdapter(params);
        if (validation.status !== 0) return cancelled(params, "binding-mismatch", "Captain dialog source binding no longer matches.");

        let modal: ModalResult | undefined;
        try {
          modal = await showQuestion(params, abortSignal, ctx);
        } catch {
          return cancelled(params, "ui-failure", "Captain dialog could not be displayed.");
        }
        if (!modal || modal.cancelled) return cancelled(params, modal?.reason || "ui-failure", "Captain left the decision open.");
        if (abortSignal.aborted) return cancelled(params, "aborted", "Captain dialog was cancelled before delivery.");

        const delivery = await deliverAdapter(params, deliveryText(modal.answers));
        if (!delivery.ownerEntered) {
          return cancelled(
            params,
            "binding-mismatch",
            "Captain dialog source binding no longer matches.",
            false,
            modal.answers,
          );
        }
        if (delivery.status !== 0) {
          return cancelled(
            params,
            "delivery-unknown",
            "Captain answer delivery could not be confirmed; the decision remains open. Do not resend automatically.",
            "unknown",
            modal.answers,
            delivery.diagnostic,
          );
        }
        const details: AnswerDetails = {
          schema: "fm-captain-answer.v1",
          status: "answered",
          home: params.home,
          taskId: params.taskId,
          decisionKey: params.decisionKey,
          sourceGeneration: params.sourceGeneration,
          mode: params.mode,
          answers: modal.answers,
          delivered: true,
        };
        return { content: [{ type: "text" as const, text: "Captain answer delivered through Firstmate's keyed decision owner." }], details };
      });
    },
    renderCall(args, theme) {
      const task = typeof args.taskId === "string" ? cleanDisplay(args.taskId, 80) : "unknown";
      const key = typeof args.decisionKey === "string" ? cleanDisplay(args.decisionKey, 80) : "unknown";
      return new Text(theme.fg("toolTitle", theme.bold(`Ask Captain · ${task} · ${key}`)), 0, 0);
    },
    renderResult(result, _options, theme) {
      const details = result.details as AnswerDetails | undefined;
      if (!details) return new Text(theme.fg("warning", "Captain dialog returned no structured result."), 0, 0);
      if (details.reason === "delivery-unknown") {
        const diagnostic = cleanDisplay(details.diagnostic || "Firstmate delivery owner returned no diagnostic.", 500);
        return new Text(
          theme.fg("warning", `Decision left open · delivery-unknown\n${diagnostic}\nDo not resend automatically.`),
          0,
          0,
        );
      }
      const text = details.status === "answered" ? "Captain answer delivered" : `Decision left open · ${details.reason || "cancelled"}`;
      return new Text(theme.fg(details.status === "answered" ? "success" : "warning", text), 0, 0);
    },
  });
}
