// T3 Code → island. The server pushes a picture of its projects (src-tauri/src/t3.rs);
// this applies it the way a hook event would, without going through the hook pipe.
// Allow / Deny is a click, and it is sent only to T3.

import { Bridge, onEvent } from "../core/bridge";
import { Sound } from "../core/sound";
import type { BotStateName } from "../core/layout";
import { State, type AgentTask } from "../core/state";
import { dropPendingCard } from "./hooks";
import type { Island } from "./island";

export const T3_ID = "agent_t3";

/** How long a finished turn stays on Mochi, same as a hook's Stop. */
const FINISH_MS = 5200;

export interface T3Thread {
  id: string;
  title: string;
  status: string;
  url: string;
}

export interface T3Project {
  id: string;
  title: string;
  threads: T3Thread[];
}

export interface T3Approval {
  requestId: string;
  threadId: string;
  summary: string;
  detail: string;
}

export interface T3Alert {
  kind: "approval" | "question" | "error" | "finished";
  label: string;
}

/** What Rust emits on the `t3` event. */
export interface T3Update {
  connected: boolean;
  error: string | null;
  baseUrl: string;
  projects: T3Project[];
  pill: { state: string; label: string };
  alerts: T3Alert[];
  approval: T3Approval | null;
}

/** Requests the user already answered, until the server drops them. */
const decided = new Set<string>();
let finishTimer: number | null = null;

/** Remember a click so the same request does not open the card again. */
export function noteT3Decision(requestId: string): void {
  if (requestId) decided.add(requestId);
}

export function registerT3(island: Island): void {
  void onEvent<T3Update>("t3", (update) => applyT3Update(island, update));
}

/** Allow / Deny for the card that is up, when it belongs to T3. */
export function decideT3(decision: "allow" | "deny"): boolean {
  const req = State.pendingApproval;
  if (!req || req.pillId !== T3_ID) return false;
  noteT3Decision(req.requestId);
  void Bridge.t3Decide(req.sessionId, req.requestId, decision === "allow" ? "accept" : "decline");
  return true;
}

export function applyT3Update(island: Island, update: T3Update): void {
  if (State.paused) return;

  if (!update.approval) decided.clear();
  else {
    for (const id of decided) {
      if (id !== update.approval.requestId) decided.delete(id);
    }
  }

  const previous = State.integrations[T3_ID];
  State.integrations[T3_ID] = {
    data: {
      projects: update.projects,
      connected: update.connected,
      baseUrl: update.baseUrl,
    },
    error: update.error,
    loaded: update.connected,
    configured: previous?.configured ?? update.baseUrl.length > 0,
  };

  const pending = State.pendingApproval;
  if (pending?.pillId === T3_ID && (!update.approval || pending.requestId !== update.approval.requestId)) {
    dropPendingCard(island);
  }
  const approval = update.approval;
  if (approval && !decided.has(approval.requestId) && !State.pendingApproval) {
    State.beginApproval({
      requestId: approval.requestId,
      sessionId: approval.threadId,
      pillId: T3_ID,
      tool: approval.summary || "T3 Code",
      command: approval.detail || approval.summary,
    });
    island.alert("approval");
  }

  const task = State.tasks.find((item) => item.id === T3_ID);
  if (task) applyPill(task, update);

  let reveal = false;
  for (const alert of update.alerts) {
    if (alert.kind === "approval") Sound.play("approval");
    else if (alert.kind === "question") Sound.play("question");
    else if (alert.kind === "error") Sound.play("error");
    else if (alert.kind === "finished") Sound.play("finish");
    if (alert.kind !== "approval") reveal = true;
    if (task && State.focusId !== T3_ID && (alert.kind === "approval" || alert.kind === "error" || alert.kind === "finished")) {
      task.pillBadge = alert.kind === "approval" ? "approval" : alert.kind === "error" ? "error" : "finished";
    }
  }
  // A permission card is already the alert. Anything else just shows the island.
  if (reveal && State.pendingApproval?.pillId !== T3_ID) island.reveal();
  State.notify();
}

function applyPill(task: AgentTask, update: T3Update): void {
  const next = update.pill.state;
  const finished = update.alerts.find((alert) => alert.kind === "finished");
  const urgent = next === "approval" || next === "question" || next === "error" || next === "working";
  if (urgent || finished) {
    if (finishTimer != null) {
      window.clearTimeout(finishTimer);
      finishTimer = null;
    }
  }
  if (finished && !urgent) {
    task.state = "finished";
    task.steps = [finished.label];
    task.stepIndex = 0;
    finishTimer = window.setTimeout(() => {
      finishTimer = null;
      const current = State.tasks.find((item) => item.id === T3_ID);
      if (!current || current.state !== "finished") return;
      current.state = "idle";
      current.steps = [];
      current.stepIndex = 0;
      State.notify();
    }, FINISH_MS);
    return;
  }
  if (task.state === "finished" && finishTimer != null && next === "idle") return;
  task.state = pillState(next);
  task.steps = update.pill.label ? [update.pill.label] : [];
  task.stepIndex = 0;
}

function pillState(next: string): BotStateName {
  if (next === "approval" || next === "question" || next === "error" || next === "working" || next === "idle") {
    return next;
  }
  return "idle";
}
