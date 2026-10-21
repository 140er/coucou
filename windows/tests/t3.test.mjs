// T3 Code events (src/island/t3.ts) and the project card (src/views/integrations.ts).

import { beforeEach, mock, test } from "node:test";
import assert from "node:assert/strict";
import { calls, emit } from "./tauri.mjs";
import { installFakeDom } from "./fakedom.mjs";
import { DEFAULT_SETTINGS, State } from "../src/core/state.ts";
import { Sound } from "../src/core/sound.ts";
import { hasSessionTicker } from "../src/views/views.ts";
import { idleStatus, renderIntegrationCard } from "../src/views/integrations.ts";
import { applyT3Update, decideT3, noteT3Decision, registerT3, T3_ID } from "../src/island/t3.ts";
import { registerPhoneLink } from "../src/island/phone-link.ts";
import { setLanguage } from "../src/i18n/i18n.ts";

installFakeDom();

let asked;
let played;
const island = {
  alert: (view) => asked.push(`alert:${view}`),
  setView: (view) => asked.push(`setView:${view}`),
  reveal: () => asked.push("reveal"),
  dropPin: () => asked.push("dropPin"),
};

registerT3(island);

function update(over = {}) {
  return {
    connected: true,
    error: null,
    baseUrl: "http://t3code-home:3773",
    projects: [{
      id: "p1",
      title: "Coucou",
      threads: [{
        id: "t1",
        title: "Fix the build",
        status: "running",
        url: "http://t3code-home:3773/env/t1",
      }],
    }],
    pill: { state: "working", label: "Coucou · Fix the build" },
    alerts: [],
    approval: null,
    ...over,
  };
}

beforeEach(() => {
  setLanguage("en");
  mock.timers.reset();
  mock.timers.enable({ apis: ["setTimeout"] });
  asked = [];
  played = [];
  calls.length = 0;
  State.settings = { ...DEFAULT_SETTINGS, mainPill: T3_ID, activeIntegrations: [] };
  State.tasks = [];
  State.focusId = null;
  State.mode = "hidden";
  State.view = "overview";
  State.paused = false;
  State.isPinned = false;
  State.pendingApproval = null;
  State.focusBeforeApproval = null;
  State.integrations = {};
  State.loadIntegrationTasks();
  Sound.play = (name) => played.push(name);
});

test("a live project replaces the idle card and keeps the list, not the ticker", () => {
  const task = State.tasks.find((item) => item.id === T3_ID);
  applyT3Update(island, update());
  task.state = "working";
  assert.equal(hasSessionTicker(task), false);
  const card = renderIntegrationCard(task, { openSettings() {}, detailOpen: false, openDetail() {}, closeDetail() {} });
  assert.ok(card.textContent.includes("Coucou"));
  assert.ok(card.textContent.includes("Fix the build"));
  assert.ok(card.textContent.includes("running"));
  assert.ok(!card.textContent.includes("<"));
  const row = card.querySelector(".int-row.first");
  assert.ok(row);
  row.fire("click");
  assert.deepEqual(calls[calls.length - 1], ["open_url", { url: "http://t3code-home:3773/env/t1" }]);
});

test("a thread title is text, even when it looks like markup", () => {
  applyT3Update(island, update({
    projects: [{
      id: "p1",
      title: "<b>Coucou</b>",
      threads: [{ id: "t1", title: "<img src=x>", status: "done", url: "http://t3code-home:3773/env/t1" }],
    }],
  }));
  const task = State.tasks.find((item) => item.id === T3_ID);
  const card = renderIntegrationCard(task, { openSettings() {}, detailOpen: false, openDetail() {}, closeDetail() {} });
  assert.ok(card.textContent.includes("<img src=x>"));
  assert.ok(card.textContent.includes("Done"));
});

test("an approval opens the card once, and a click tells T3 rather than the hook", () => {
  applyT3Update(island, update({
    pill: { state: "approval", label: "Coucou · Fix the build" },
    alerts: [{ kind: "approval", label: "Coucou · Fix the build" }],
    approval: { requestId: "req-1", threadId: "t1", summary: "Run tests", detail: "npm test" },
  }));
  assert.deepEqual(asked, ["alert:approval"]);
  assert.equal(State.pendingApproval.requestId, "req-1");
  assert.equal(State.pendingApproval.command, "npm test");
  assert.deepEqual(played, ["approval"]);
  const task = State.tasks.find((item) => item.id === T3_ID);
  assert.equal(task.state, "approval");

  applyT3Update(island, update({
    pill: { state: "approval", label: "Coucou · Fix the build" },
    approval: { requestId: "req-1", threadId: "t1", summary: "Run tests", detail: "npm test" },
  }));
  assert.deepEqual(asked, ["alert:approval"]);

  assert.equal(decideT3("allow"), true);
  assert.deepEqual(calls[calls.length - 1], ["t3_decide", { threadId: "t1", requestId: "req-1", decision: "accept" }]);
  // The island closes the card after the click. The same request must not reopen it.
  State.endApproval();
  applyT3Update(island, update({
    pill: { state: "working", label: "Coucou · Fix the build" },
    approval: { requestId: "req-1", threadId: "t1", summary: "Run tests", detail: "npm test" },
  }));
  assert.equal(State.pendingApproval, null);
  assert.deepEqual(asked, ["alert:approval"]);
});

test("a phone's answer is remembered, so the card does not come back", () => {
  registerPhoneLink(island);
  applyT3Update(island, update({
    pill: { state: "approval", label: "Coucou · Fix the build" },
    alerts: [{ kind: "approval", label: "Coucou · Fix the build" }],
    approval: { requestId: "req-9", threadId: "t1", summary: "Run tests", detail: "npm test" },
  }));
  emit("phone-link-decided", "req-9");
  assert.equal(State.pendingApproval, null);
  asked = [];
  applyT3Update(island, update({
    pill: { state: "approval", label: "Coucou · Fix the build" },
    approval: { requestId: "req-9", threadId: "t1", summary: "Run tests", detail: "npm test" },
  }));
  assert.deepEqual(asked, []);
  assert.equal(State.pendingApproval, null);
});

test("a finished turn holds, then returns to idle, and the first error does not use the hook pipe", () => {
  applyT3Update(island, update());
  applyT3Update(island, update({
    pill: { state: "idle", label: "Coucou · Fix the build" },
    projects: [{
      id: "p1",
      title: "Coucou",
      threads: [{ id: "t1", title: "Fix the build", status: "done", url: "http://t3code-home:3773/env/t1" }],
    }],
    alerts: [{ kind: "finished", label: "Coucou · Fix the build" }],
  }));
  const task = State.tasks.find((item) => item.id === T3_ID);
  assert.equal(task.state, "finished");
  assert.deepEqual(played, ["finish"]);
  assert.ok(asked.includes("reveal"));
  mock.timers.tick(5200);
  assert.equal(task.state, "idle");
});

test("the idle line says whether the server answered", () => {
  State.integrations[T3_ID] = { data: { connected: true }, error: null, loaded: true, configured: true };
  assert.equal(idleStatus(T3_ID, State.integrations[T3_ID], "").label, "Connected");
  State.integrations[T3_ID] = { data: {}, error: "Not connected", loaded: false, configured: false };
  assert.equal(idleStatus(T3_ID, State.integrations[T3_ID], "").label, "Not connected");
});

test("noteT3Decision alone does not invent a command", () => {
  noteT3Decision("nope");
  assert.equal(decideT3("deny"), false);
  assert.equal(calls.length, 0);
});
