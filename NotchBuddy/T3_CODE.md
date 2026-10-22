# T3 Code on macOS

The `agent_t3` source ports the Windows/Linux implementation from
`windows/src-tauri/src/t3.rs`. Settings use the same `t3-url`, `t3-token`,
`t3-cf-client-id` and `t3-cf-client-secret` keys, all stored in the existing
`fr.louisraille.NotchBuddy` Keychain service. No server or credential is compiled
into the app. The existing hook sources keep their Unix-socket transport.

The source exchanges a bearer session for a WebSocket ticket using
`POST /api/auth/websocket-ticket`, then connects to
`/ws?orchestrationProtocol=2&wsTicket=…`. Without a token it supports local
servers that do not require authentication. It uses Effect JSON RPC framing,
chunk acknowledgements, heartbeats, `orchestration.subscribeShell` and
approval-only `orchestration.subscribeThread` streams. Both Cloudflare Access
fields are optional and sent together. HTTP redirects are refused; errors never
include URLs, tickets, headers or server response bodies.

Shell snapshots/events decide status and pending requests. Project metadata
refreshes preserve threads. Archived/deleted threads disappear. The projection
fills approval prompts; it cannot resolve an approval. Allow/Deny use
`orchestration.dispatchCommand` with `runtime-request.respond` and
`accept`/`decline`. Requests stay visible until the shell resolves them, and
buttons disable while a response is pending. A local hook approval can take
precedence; T3 requests remain waiting and are presented when the card is free.
Questions and authentication refresh requests open in T3 Code, matching the
Windows/Linux source. Questions are labelled **Answer in T3 Code**. Approvals,
questions, errors and completed turns use existing sounds and pill states.
Connection failures clear stale requests and retry with a 1–30 second backoff.
Disabling the pill or pausing integrations cancels the connection.

## Build and run on a Mac

Use macOS 15 or later and a full Xcode installation supporting Swift 6 (the
repository's XcodeGen spec declares Xcode 27). Run from the repository root:

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

The product is `Coucou.app`; its bundle ID is `fr.louisraille.NotchBuddy`.
Xcode resolves the existing FluidAudio package during the native build. Debug
is unsigned and omits the optional iPhone link. No paid team or provisioning
profile is needed for this local build. macOS may ask for Keychain access;
unsigned rebuilds can also require granting app permissions again. For everyday
use, select your own development team and signing identity in Xcode. The
repository's DebugCloud/Release configurations use the maintainer's team and
CloudKit entitlements; use your own matching provisioning profiles if choosing
those configurations. T3 itself does not need CloudKit or phone-link signing.

1. Connect the Mac to the server's Tailscale network if using a tailnet address.
2. Open **Settings → Agents → T3 Code**, enter the server URL and optional
   session token in the secure field, then **Save and reconnect**. Never place
   the token in a URL or shell command. If needed, enter both Cloudflare fields.
3. In **Settings → Active pills**, select T3 Code as the main workspace or
   enable it as an additional pill (remove another if the four-pill limit is
   reached). Open the notch and select T3 Code.
4. Confirm projects and active threads appear with live status. Start/finish a
   turn and confirm the status, finish animation and sound change.
5. Trigger an approval: confirm the existing approval card shows the project
   and prompt, Allow/Deny respond in T3, and a decision made in T3 clears the
   card. With a hook approval pending too, confirm both sources can be answered
   without one source's decision being sent to the other.
6. Trigger a user-input request: confirm **Answer in T3 Code** opens its thread.
   Archive/delete a thread and confirm it disappears. Briefly stop/restart the
   server to verify reconnect; disable/re-enable the pill and test forgetting
   credentials. Existing Claude Code/Cursor/Codex hooks should still work.

## Verification performed on Linux

- Swift 6.0.3: `swift test --package-path NotchBuddy`: 8 tests passed. Covers
  status precedence, non-blocking questions, legacy event rejection, snapshots,
  metadata refreshes, removal/archive events, prompt enrichment, sorting,
  alert transitions/reconnect deduplication, safe URLs and RPC command shapes.
- Existing `scripts/test-approval-queue.sh`, `scripts/test-ask-question.sh`, and
  `scripts/test-pill-colors.sh`: passed.
- Swift parser checks passed for the changed native views/source. The connection
  source also passed a strict Swift 6 concurrency type-check against temporary
  UI stubs using FoundationNetworking. This does not type-check SwiftUI/AppKit.
- Native Xcode builds, Keychain behavior, SwiftUI layout, macOS WebSocket
  transport and a live authenticated T3 session could not be verified on Linux.
  The manual Mac checks above remain required. The Mac build workflow includes
  the protocol tests and accepts PRs against the integration base branch.
