# Knife Terminal

`CWT_STE3XM1_2607` · accent `#B1A57E` · v0.9.6

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
- **Claude Code alerts**: "Install Claude Code Alert Hooks…" (or `alerts` in the footer) adds hooks to `~/.claude/settings.json` that ping `~/.knife-terminal.sock`; the tab pulses while Claude works and glows with a chime when it's waiting for you. Any terminal bell in a background tab does the same. Same socket protocol as the Electron app — already-installed hooks keep working.
- **Session restore**: tabs (and their working directories) are saved and reopened on next launch; project tabs relaunch `claude -c`. Reads the old Electron session file on first run.
- Drag files/folders onto the terminal to paste their shell-quoted paths.

## iOS mirror
- One sign-in = your Apple ID. The Mac publishes every tab (title, status, rendered text tail) and its recent-projects list to your private CloudKit database; the phone shows tabs in a native text view — wraps to the screen, native selection/copy, no side-scrolling.
- Fully interactive: quick keys (esc/tab/^C/arrows/⏎/y⏎) and a real multiline compose bar create `Input` records the Mac applies to the real PTY. Round trip is a few seconds — made for "yes, continue", not vim.
- Push notification when Claude Code is waiting for you in any tab; app badge counts waiting tabs.
- Closed projects are listed below live sessions — tap one and the Mac opens it in a new tab (running `claude`), which mirrors back to the phone within seconds.
- Latency: silent CloudKit pushes when available, 10 s polling as fallback.

## Shortcuts
- ⌘T new tab · ⌘W close tab · ⌘1–9 jump to tab · ⌘⇧[ / ⌘⇧] prev/next tab · ⌘B hide/show sidebar · ⌘N new window · ⌘⇧N move tab to new window · ⌘⇧M merge all windows

## Layout
- `apple/project.yml` — XcodeGen spec (the `.xcodeproj` is generated, not committed)
- `apple/macOS/` — the Mac app · `apple/iOS/` — the iPhone app
- `apple/KnifeKit/` — shared package: CloudKit sync, emoji picker, CW&T terminal palettes
- `legacy/electron/` — the previous Electron + xterm.js + node-pty app

Styled with the CW&T design system (Space Mono, ink on paper, hairline rules).
