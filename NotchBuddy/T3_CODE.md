# T3-only Coucou for macOS

Coucou connects to one T3 server and displays its projects as live pills.
The old service integrations and agent settings/pill toggles are removed from
navigation. Their implementation files remain, but their pollers/hook listener
are not started, saved selections are migrated away, and the task collection
rejects non-T3 pills. A single T3 connection card is shown until projects load.

## Projects and requests

Each project has a stable pill ID and displays running, needs answer, approval,
done, error or idle. Status aggregates all active threads, including subagents.
The thread opened by a pill prefers an active parent of subagents (the
orchestrator), otherwise the most urgent/recent thread. Clicking a project pill
selects it and opens that thread in T3. The project card lists its other threads;
chat has a thread picker. All project pills are scrollable, without the old
four-pill limit. Empty projects appear idle and can be opened in T3 to create a
thread. Project/thread removal updates the pills immediately.

Approvals use the existing card and belong to their project pill. The shell owns
pending state; a thread projection enriches prompts. Allow/Deny dispatch
`runtime-request.respond` and remain pending until the shell resolves them.
Questions show **Needs answer** and can be answered in T3. Reconnect uses a
1–30 second backoff, clears stale live state and deduplicates approval sounds.

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
   Click a project with an active orchestrator and confirm its T3 thread opens.
3. Select another thread in chat. Send to an idle thread, then send while it is
   running and confirm steering. Watch the latest assistant text stream. Change
   project and verify draft and attachment state do not cross threads.
4. Use plus and drag/drop to attach an image, PDF, code file and text. Confirm
   the same files appear in T3 and the agent can use them. Remove an unsent file,
   try an oversized/empty file, and interrupt an upload to check error recovery.
5. Restart the server and verify reconnect, project removal/archival and live
   replies; change the configured server and confirm old drafts are cleared.

## Linux verification

Swift 6.0.3: `swift test --package-path NotchBuddy --jobs 2` passes 15 tests,
covering protocol parsing/state precedence, project/orchestrator mapping,
metadata refresh/removal, approval prompts/alert deduplication, safe URLs,
start/steer dispatch shapes, upload metadata/POST/reference shapes, attachment
limits and streamed reply replacement. Changed native sources pass Swift syntax
checks. The connection source also passes strict Swift 6 concurrency type-checks
with temporary Linux UI/resource stubs; this does not verify native frameworks.

Native `xcodegen`/`xcodebuild`, live authenticated sends/uploads, Keychain and
visual layout require Chief's Mac build and the smoke checks above.
