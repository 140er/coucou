# T3-only Coucou for macOS

Coucou connects to one T3 server and displays its projects as live pills.
The old service integrations and agent settings/pill toggles are removed from
navigation. Their implementation files remain, but their pollers/hook listener
are not started, saved selections are migrated away, and the task collection
rejects non-T3 pills. A single T3 connection card is shown until projects load.

## Live orchestrator status

Home shows the project's orchestrator as the main activity card, with app-owned
child threads and provider-native subagents beneath it. It uses existing T3
protocol v2 data; no server changes are required.

The card derives action verbs/targets from turn items, displays shell run timing
and provider-scoped model names, and keeps a rolling log of at most five actions.
Plans from `todo_list` / `plan.updated` provide the actual step count and segmented
bar; without a plan both are hidden. File-change paths and ready checkpoint files
are deduplicated within the run. Completion freezes the timer and fills the bar.
Approval actions use the same request IDs and `runtime-request.respond` path as
the existing popup. Questions continue to open the answer popup.

Child relationships use lineage, launch ownership and app-owned subagent items'
`childThreadId`. Finished children with `lastHandoff` remain visible until settled;
old handoffs do not carry into a new run. Native subagents stay separate from the
chat picker and do not duplicate app-owned shell rows.

At most eight bounded thread-detail streams are open: root, visible popup and
selected chat first, then active children and queued request details. Child streams
are dropped on completion/settlement or when switching projects. Cached activity
for visible terminal rows is retained separately from message/prompt caches.
The reducer retains at most 128 compact action items, eight plans and four runs'
file sets per cached thread, without tool outputs or diffs. Existing shell status,
project pills, per-thread chat and request popups continue to own their behavior.

The orchestrator Stop button sends `thread.stop`; child runs use `run.interrupt`
with the child run ID, and provider-native rows use `subagent.stop` with the parent
thread/run and subagent node IDs. Stale child run IDs are rejected locally. There
is no Pause action because T3 has no run pause.

### Mac preview and validation

Open `Sources/App/T3LiveStatusView.swift` in Xcode with the **NotchBuddy / Debug**
scheme and enable the Preview Canvas. `T3LiveStatusPreviews` includes:

- Running: current action, elapsed timer, step 4/6, rolling log and active children.
- Approval: blue accent, `npm test` prompt and Approve/Deny controls.
- Done: 13 seconds, six changed files, completed segments and retained handoff row.

These deterministic wire-shaped fixtures run through the same reducer as live
data. Preview callbacks are inert: they do not contact or stop any live agent.
Linux cannot render SwiftUI, so no native screenshots are supplied. Chief still
needs the Xcode build and visual inspection at the real notch size. Use the build
command below, then verify a live root and child update, handoff then settlement,
a late approval with the stream cap reached, each kind of Stop, and project/chat
switching. No build or installation on Jeffrey's Mac was performed by the agent.

## Projects and requests

Each project has a stable pill ID and displays running, needs answer, approval,
done, error or idle. Status aggregates all active threads, including subagents.
The thread opened by a pill prefers an active parent of subagents (the
orchestrator), otherwise the most urgent/recent thread. Clicking a project pill switches the bot inside Coucou and restores its selected
thread. The project card and chat picker list top-level threads/orchestrators;
subagents stay hidden from chat targets. Only the explicit arrow opens T3 in a
browser. Projects have distinct colors persisted by project ID. Chat also has a
project switcher. All project pills are scrollable, without the old
four-pill limit. Empty projects appear idle and can be opened in T3 to create a
thread. Project/thread removal updates the pills immediately.

Approvals and questions from any thread, including subagents, open a native
popup labelled with their project and thread. Questions support choices,
multiple selections and custom text; answers use question IDs and option values
in `runtime-request.respond`. Authentication requests offer an explicit T3 link.
The popup stays pending until the shell resolves the request. **Later** dismisses
it without answering; the project's request indicator reopens it. A request never
switches chat to a subagent. Projection updates enrich question/approval details.
Reconnect uses a 1–30 second backoff and clears stale live state.

Home and chat share their rendered geometry with the native window's mouse hit
region. Only the active view is mounted. Home has scrollable project/thread
lists; chat uses the full width with a visible composer and no decorative bot
column. Command-Return sends to the selected thread. The plus icon is an action,
so it does not appear as a second selected chat tab.

## Chat and attachments

The chat button opens the selected project's thread. Coucou streams the latest
100 user/assistant messages through `orchestration.subscribeThread` and upserts
`message.updated` events, including streaming text and attachment names. Drafts
and attachment state are separate for each thread.

Send uses the web composer's `message.dispatch` command. With
`serverResolvedCommandContext`, the server resolves `deliveryIntent` (`steer`
for an active turn, `auto` otherwise). Older servers receive `steer_active`
with the shell's active run ID, or `start_immediately` for an idle thread.
Messages retain command/message IDs for a retry of an unchanged draft. On a
lost acknowledgement, inspect the thread before retrying; the draft is kept.
New threads are created in T3 rather than with an invented launch API.

The plus button opens a multi-file chooser. Files can also be dropped onto the
notch/chat; PNG/JPEG image data and dragged plain text/code are accepted in the
chat drop area. Text becomes a `.txt` attachment. The existing T3 upload flow is:

1. Read `server.getConfig` upload capabilities.
2. Call `attachments.createUploadUrl` with name, type, MIME type and byte count.
3. POST raw bytes to its signed, same-origin `/api/attachments/upload/…` URL.
4. Include the returned persisted attachment ID and metadata in `message.dispatch`.

There is no custom upload API and no base64 payload in a message. The client
checks 100 attachments/message, 10 MiB/image, 80 MiB total images, and the lesser
of the server's advertised file limit and 50 MiB/file. Uploads are limited to
three concurrently. Empty files/folders, unsupported server capabilities,
expired/rejected uploads and failed sends produce visible errors. Failed files
must be removed and attached again; sending is disabled while an upload is
pending/failed. Removing an unsent upload uses `attachments.delete`; removed,
failed or disconnected transfers are cancelled/cleaned up. Ready unsent uploads
remain in the thread draft across automatic reconnects; expired references may
need attaching again. Drafts are in memory and are not retained on app restart.

## Settings and credentials

Open **Settings → Agents → T3 Code**. For Jeffrey's server enter
`https://t3.hoerekind.nl` and the T3 session token in the secure field; leave both
Cloudflare Access fields empty. Projects appear automatically after saving.
No URL or credential is compiled into the app. Settings retain the reference
implementation's `t3-url`, `t3-token`, `t3-cf-client-id`, `t3-cf-client-secret`
keys, stored in `fr.louisraille.NotchBuddy` Keychain service.

A session token is exchanged at `POST /api/auth/websocket-ticket`; the socket
uses `/ws?orchestrationProtocol=2&wsTicket=…`. Bearer tokens are not put in
socket URLs. Redirects are refused, signed upload URLs must remain on the
configured origin, and errors never include credentials or response bodies.

## Mac build and smoke test

New T3 code uses macOS 14-compatible APIs; the existing native project's default
deployment baseline remains macOS 15. Use full Xcode with Swift 6 (the repository
spec declares Xcode 27) and run from the repository root:

```sh
brew install xcodegen
(cd NotchBuddy && xcodegen)
swift test --package-path NotchBuddy
xcodebuild -project NotchBuddy/NotchBuddy.xcodeproj \
  -scheme NotchBuddy -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath NotchBuddy/build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
open NotchBuddy/build/Build/Products/Debug/Coucou.app
```

The app bundle is `fr.louisraille.NotchBuddy`. Debug is unsigned, omits the
optional phone link, and needs no provisioning profile. Xcode resolves the
existing FluidAudio dependency. Unsigned rebuilds may need macOS permissions or
Keychain access granting again. For signed daily builds select your own team;
DebugCloud/Release use the maintainer's signing/CloudKit setup and need matching
provisioning if used. T3 itself needs neither CloudKit nor phone-link signing.
Chief performs the native build; Linux cannot validate AppKit/SwiftUI or Keychain.

Manual checks on the Mac:

1. Save the HTTPS server and token. Confirm only T3 project pills appear, with
   no old service/agent toggles or integrations sections. Relaunch with old
   non-T3 selections saved to verify migration.
2. Start/finish a run, trigger a question/approval (including a subagent), and
   check the project status, sound, approval prompt and Allow/Deny ownership.
   Click a different project and verify Coucou switches locally without opening
   a browser. Use the explicit arrow to open T3. Confirm different projects have
   different colors after relaunch. Verify subagent requests open a popup and
   do not add subagents to the chat picker. Answer choices/custom text, dismiss
   with Later, reopen with the request indicator, and resolve a request in T3.
3. Select another thread in chat. Send to an idle thread, then send while it is
   running and confirm steering. Watch the latest assistant text stream. Change
   project and verify draft and attachment state do not cross threads.
4. Use plus and drag/drop to attach an image, PDF, code file and text. Confirm
   the same files appear in T3 and the agent can use them. Remove an unsent file,
   try an oversized/empty file, and interrupt an upload to check error recovery.
5. Restart the server and verify reconnect, project removal/archival and live
   replies; change the configured server and confirm old drafts are cleared.

## Linux verification

Swift 6.0.3: `swift test --package-path NotchBuddy --jobs 2` passes 32 tests,
covering protocol parsing/state precedence, project/orchestrator mapping,
metadata refresh/removal, approval prompts/alert deduplication, safe URLs,
start/steer dispatch shapes, upload metadata/POST/reference shapes, attachment
limits, streamed reply replacement, subagent filtering, stable distinct colors,
popup answer command building, activity reduction/timing, run isolation, tree and
handoff lifecycle, bounded subscription/cache behavior, model names, stop command
shapes and the three preview fixtures. Changed native sources pass Swift syntax
checks. The connection source also passes strict Swift 6 concurrency type-checks
with temporary Linux UI/resource stubs; this does not verify native frameworks.

Native `xcodegen`/`xcodebuild`, live authenticated sends/uploads, Keychain and
visual layout require Chief's Mac build and the smoke checks above.
