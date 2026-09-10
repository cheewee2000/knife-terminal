# Sidebar: sections, starring, drag-and-drop + tab coding status (2026-08-26)

Plan: /Users/eddie/.claude/plans/silly-petting-puppy.md

- [x] Part A: tab status word — TabStatus enum on TabModel, set in AppModel/WindowController, label in TabRow
- [x] B1: Support.swift — ProjectSection, ProjectMeta, SidebarMeta, loadMeta/saveMeta
- [x] B2: Support.swift — autoSection + sectioned pure functions
- [x] B3: ContentView.swift — ProjectRow extraction (star button + context menu), sectioned idle rendering, LazyVStack, search-mode flat list, onSubmit fix
- [x] B4: ContentView.swift — ProjectRowDrop / ProjectSectionDrop, liveMove/commitDrop, TabReorderDrop hardening, container onDrop clears both drags
- [x] Build + diff review — full diff verified against plan (Fable); unsigned `xcodebuild` BUILD SUCCEEDED
- [x] Fix local signing: Debug uses macOS/KnifeMacDev.entitlements (no iCloud/push) + Zelig team 5VY7X6W92A; Release keeps CW&T entitlements (now per-config CODE_SIGN_ENTITLEMENTS in project.yml — the xcodegen `entitlements:` block forced one file on all configs). `make mac` + `make install-mac` work again.
- [ ] Manual QA per plan checklist — app installed to /Applications, relaunch to test. Note: locally built Debug apps have CloudKit disabled (runtime guard), so no iOS sync from dev builds.

## Review

- Full diff across the 5 files reviewed against the approved plan — matches (Part A status word; Part B sections/star/drag-drop, order-array + override semantics as designed).
- `xcodebuild … CODE_SIGNING_ALLOWED=NO build` → BUILD SUCCEEDED.
- The CloudKit-entitlement guard in AppModel.swift init is Eddie's pre-existing uncommitted change (verified via relay transcript: seen in a read, not authored) — untouched.
- **Blocker for QA/install**: `make mac` (signed) fails at provisioning before compiling — "No Accounts" + no profile for `com.cwandt.knifeterminal` for CLI xcodebuild. Pre-existing environment state (possibly since the hardened-runtime change, 47ed32b), not caused by these edits. Build from Xcode.app or add the account for CLI builds, then run the QA checklist in the plan.

## Fix round 2 — sidebar project drag felt broken in use (2026-08-27)

Manual QA finally happened (Eddie: "moving projects around in sidebar is not working well").
Five defects found in `apple/macOS/ContentView.swift`, all fixed:

- [x] **Drag start cancelled/glitched.** `.onDrag` wrote `@State` synchronously, re-rendering the
      row while AppKit was opening the drag session. Now deferred via `DispatchQueue.main.async`
      (both project rows and tab rows).
- [x] **List reflowed the instant you picked a row up.** Empty section headers were revealed by
      `|| draggingProject != nil`, pushing every row down mid-drag so the row under the cursor was
      no longer the one grabbed. Headers now always render — layout is fixed while dragging.
- [x] **Drops that snapped back.** The container-level `.onDrop` discarded the live order with a
      bare `rebuild()`, and a project released over the tab list hit `TabReorderDrop`, which
      committed nothing. All four drop targets now funnel through one `endDrag()` that persists
      whatever order is on screen, so releasing anywhere in the sidebar sticks.
- [x] **Section-header drops landed by recency, not where dropped.** Header hover now live-moves
      the row to the top of that section (`liveMove(_:into:)`) and the drop snapshots that order.
- [x] **Two parallel drag optionals** (`draggingTabId` / `draggingProject`) with identical
      `public.plain-text` payloads → replaced by one `SidebarDrag` enum, so a tab dragged over a
      project row (or the reverse) can't be misread as a drag of the target's own kind.
- [x] `commitDrop` takes the path explicitly instead of writing `@State` and reading it back in
      the same call (context-menu "move to …" relied on that round-trip).

Verified: `xcodebuild … CODE_SIGNING_ALLOWED=NO` and `make mac` (signed) both BUILD SUCCEEDED.
The provisioning blocker noted in the previous round is gone — signed CLI builds work again.
Still needs a hands-on pass in the running app: `make install-mac`, relaunch, drag within a
section, across sections, onto a header, onto a collapsed header, and onto blank space.

# Restore every working Claude tab on relaunch (2026-09-09)

Problem: session.json only carries `cmd` for tabs opened from the sidebar (`claude -c`), so
tabs where `claude` was started by hand come back as bare shells, and `-c` resumes "most
recent in cwd" — two tabs in the same project both resume the same conversation.

- [ ] TabModel: `claudeSessionId` (from hook payloads) + `claudeRunning` (pgrep under the tab's shell)
- [ ] AppModel.handleSocketMessage: record `session_id` per tab; clear on SessionEnd
- [ ] saveSession: cmd = `claude --resume <id>` if known, else `claude -c` if claude is live, else restoreCmd
- [ ] SavedTab.fixed: keep the project name pinned only for sidebar-opened tabs (legacy files keep old rule)
- [ ] Build + install

# iOS mirror without CW&T (2026-09-09)

Zelig (5VY7X6W92A) is a paid team, so both apps run under Zelig ids and Zelig's own container:
- [x] CloudSync.containerID reads KnifeCloudContainer (Info.plist ← KNIFE_CLOUD_CONTAINER build setting), CW&T default
- [x] Makefile: XCODEBUILD_FLAGS_IOS + `make install-ios` (devicectl) — committed, pushed to the PR branch
- [x] local.mk (gitignored): com.zelig.knifeterminal / .ios, iCloud.com.zelig.knifeterminal, *.zelig.entitlements (git-excluded), IOS_DEVICE = EC PRO
- [x] Mac: built, installed to /Applications with Zelig container + push entitlements (Xcode auto-provisioning created the App ID + container)
- [x] iOS: built, installed on EC PRO via devicectl
- [ ] Eddie: relaunch Knife on the Mac, open Knife on the phone (same Apple ID as the Mac, eddiemc27@mac.com), confirm tabs appear
- [x] iOS restyle to match the Mac: KnifeStyle.swift (ui()/mono(), TermTheme.current(scheme), RGB→Color), Helvetica Now bundled locally (apple/Fonts/HelveticaNow*, git-excluded), theme backgrounds/accent/attention throughout; built + installed on EC PRO

# Session board (2026-09-09)

One screen with every live agent session as a card: status, the last exchange from its
transcript, and a reply box that types straight into that tab. ⌘⇧B / footer "board" toggles it
in place of the terminal pane; click a card header to jump into the tab.

- [ ] TabModel.runningAgent ("claude" | "codex" | nil) via the existing pgrep; claudeRunning = runningAgent == "claude"
- [ ] TranscriptReader.messages(forCwd:sessionId:) — exact ~/.claude/projects/<slug>/<session>.jsonl when the tab's session id is known, else the newest-in-cwd fallback; chatData(forCwd:sessionId:) wraps it; SyncPublisher passes tab.claudeSessionId
- [ ] KnifeWindowController.showBoard (@Published); AppDelegate View ▸ "Session Board" ⌘⇧B; FooterBar "board" button
- [ ] ContentView: board replaces TerminalPane when showBoard
- [ ] BoardView.swift: adaptive grid of SessionCard (needs-input first), 2 s transcript refresh off the main thread, reply field (text, then CR 0.25 s later, like the phone), header tap → activate tab + close board
- [x] Build + install (signed Debug, BUILD SUCCEEDED) — hands-on check pending Eddie's relaunch

# iOS: readability, status grouping, alerts off (2026-09-10)

- [x] No more one-line truncation: session + project titles wrap to two lines; the nav bar
      shows the full title (middle-truncated) with the project folder beneath it; tool lines
      in the chat expand on tap
- [x] Sessions grouped: needs input / working / idle, counts in the headers, attention color
      on the first — same order as the Mac sidebar and board
- [x] Each row carries the last exchange (Claude's newest reply, or the tool it's running),
      decoded once per sync into a snippet map rather than per row on scroll
- [x] Mirror readability: prose wraps on words, box drawing still on characters; text-size
      menu (small/medium/large) plus "fit Mac width", which solves for the size that makes
      the Mac's own column count fit — landscape then shows the desktop layout unwrapped
- [x] Cleanups: "projects" header is a header again (the sentence moved to a footer), the
      internal device label is gone from the footer
- [x] Notifications: visible pushes are opt-in behind a switch, default off — the alert
      subscription is deleted server-side and the badge cleared when off. Silent sync pushes
      are untouched, so the mirror stays as fresh as before.
