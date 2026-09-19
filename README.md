# Knife Terminal

`CWT_STE3XM1_2607` · accent `#B1A57E` · v0.9.21

CW&T's own terminal. Native Swift — SwiftUI + [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) on macOS, with an iOS companion app that mirrors the Mac's live sessions over CloudKit. (The original Electron app lives in `legacy/electron/`.)

## Build & install

    make install-mac      # build the macOS app and copy to /Applications
    make ios              # build the iOS app (install to your iPhone from Xcode)
    make gen              # regenerate apple/KnifeTerminal.xcodeproj from apple/project.yml

Needs Xcode signed into the CW&T Studio developer account (team `L6DVQR8JB9`) — signing is automatic.

## macOS features
- Left sidebar: tabs, then recent Claude Code projects (from `~/.claude.json`) — click one to open a tab in that folder running `claude`.
- ⌘K searches projects; Enter opens the first match. Theme toggle (auto/light/dark) in the footer.
- **Default terminal**: Knife Terminal menu → "Make Default Terminal…" (or `set default` in the footer) registers Knife for `.command`/`.sh`/`.tool`/unix executables and `ssh://`, `telnet://`, `x-man-page://` links. Folders: Finder → Open With → Knife Terminal, or `open -a "Knife Terminal" <dir>`. To open a folder with `claude` running: `printf "open %s" "$dir" | nc -U ~/.knife-terminal.sock` (the Finder "Open with Claude" quick action does this).
- **Claude Code alerts**: "Install Claude Code Alert Hooks…" (or `alerts` in the footer) adds hooks to `~/.claude/settings.json` that ping `~/.knife-terminal.sock`; the tab pulses while Claude works and glows with a chime when it's waiting for you. The phone push says why: the permission or question text, or the last paragraph of Claude's reply. A turn that ends on a usage limit (the `StopFailure` hook, added to existing installs on launch) reads `limit` to the job runner, which pauses the job instead of resuming its overseer. Any terminal bell in a background tab does the same. Same socket protocol as the Electron app — already-installed hooks keep working.
- **Session restore**: tabs (and their working directories) are saved and reopened on next launch; project tabs relaunch `claude --resume <the tab's session id>` (from its hooks), so two tabs in one project each get their own conversation back; `claude -c` only when no hook has reported one. Reads the old Electron session file on first run.
- Drag files/folders onto the terminal to paste their shell-quoted paths. URLs and file paths on screen are underlined in the accent color and open on a plain click — URLs in the browser, folders in Finder, files revealed in Finder (⌘-click works anywhere, incl. the input row). Paths resolve absolute, `~`, and relative-to-the-shell's-cwd forms, and a `file.swift:12` reference opens VS Code at that line.

## iOS mirror
- One sign-in = your Apple ID. The Mac publishes every tab (title, status, rendered text tail) and its recent-projects list to your private CloudKit database; the phone shows tabs in a native text view — wraps to the screen, native selection/copy, no side-scrolling, tappable links.
- Fully interactive (composer and overseer text is typed in 256-character chunks, not pasted — Claude Code tags a paste as possibly not the user's words): quick keys (esc/tab/^C/arrows/⏎/y⏎) and a real multiline compose bar create `Input` records the Mac applies to the real PTY. Round trip is a few seconds — made for "yes, continue", not vim.
- Push notification when Claude Code is waiting for you in any tab; app badge counts waiting tabs.
- Closed projects are listed below live sessions — tap one and the Mac opens it in a new tab (running `claude`), which mirrors back to the phone within seconds.
- Latency: silent CloudKit pushes when available, 10 s polling as fallback.

## Jobs: dictate a request, one Mac runs it
- **One Mac runs everything**: the Mac running Knife publishes its tabs, answers the phone, and runs every job. The phone posts requests (the "ask" box at the top of the list — dictate with the keyboard mic); the Mac's sidebar has the same box. If the Mac is asleep or closed, jobs wait until it's back.
- **Manifest**: the Mac publishes its recent projects with the **git remote** (the project's identity across machines), a one-line **description** (README first paragraph, else `claude -p --model haiku` writes one, cached in `~/.knife/descriptions.json`) and **last touched** time. The merged view lands in `~/.knife/manifest.json`. Projects without a remote can't be routed to.
- **Routing** runs on the executor (`knife-job.sh`, bundled): the request + manifest go to haiku, which picks a remote with a confidence and three candidates. ≥ 0.75 dispatches; below that the job tab lists the candidates, pings the phone ("which project? 1 … 2 … 3 …") and one tap on 1/2/3 in the tab picks.
- **Execution — the overseer**: after routing, the job tab starts an overseer (`claude -p --model sonnet`) whose only tool is `knife-tab`, a thin client for the app's `tab …` socket commands: `open <dir>` (new tab running `claude`, returns the id), `shell <dir>`, `type <id> <text>`, `key <id> enter|esc|ctrl-c|…`, `read <id>` (the rendered screen), `status <id>` (working / attention / idle / gone) and `wait <id>`. It opens the project's checkout (cloning into `~/.knife/projects/` if absent) in a real tab, types the request the way you would, answers claude's questions from what it reads on screen, and asks claude to commit and push when done. Every action is echoed in the job tab, and the project tab is an ordinary session — watch it on the Mac or the phone, take over by typing, and it stays open afterwards. The job tab is a chat with the overseer: anything typed into it (Mac or phone) becomes its next turn, before or after it reports DONE, so you can redirect it or ask for more. The overseer's report is saved to `~/.knife/jobs/<job>.out` and rides in the push notification.
- **New project from a folder**: Knife Terminal menu → "New Project from Folder…" (or `printf "adopt %s" "$dir" | nc -U ~/.knife-terminal.sock` from a Finder quick action): `git init`, private GitHub repo via `gh repo create`, then `claude`. The next manifest publish carries it to the executor, which clones it on the first job.
- No CloudKit schema change: a request is an `Open` record with a `job:` prefix, the manifest is one `Projects` record per machine (`projects-<host>`), jobs are ordinary `Tab` records. There is one executor, so there is no job claiming; if a second Mac ever runs jobs, iCloud is the wrong coordination layer (eventually consistent) — claiming needs an atomic write, e.g. a small HTTP endpoint on the executor.

## Shortcuts
- ⌘T new tab · ⌘W close tab (or mini) · ⌘1–9 jump to tab · ⌘⇧[ / ⌘⇧] prev/next tab · ⌘B hide/show sidebar · ⌘N mini popout terminal (plain shell, no tabs/projects)

## Layout
- `apple/project.yml` — XcodeGen spec (the `.xcodeproj` is generated, not committed)
- `apple/macOS/` — the Mac app · `apple/iOS/` — the iPhone app
- `apple/KnifeKit/` — shared package: CloudKit sync, emoji picker, CW&T terminal palettes
- `legacy/electron/` — the previous Electron + xterm.js + node-pty app

Styled with the CW&T design system (Space Mono, ink on paper, hairline rules).
