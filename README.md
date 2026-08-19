# Knife Terminal

`CWT_STE3XM1_2607` · accent `#B1A57E`

CW&T's own terminal. Electron + xterm.js + node-pty. Basic for now — just tabs.

## Run
    npm install
    npm start

## Features
- Left sidebar: tabs, then recent Claude Code projects (from `~/.claude.json`) — click one to open a tab in that folder running `claude`.
- ⌘K searches projects; Enter opens the first match. Theme toggle (auto/light/dark) in the sidebar footer.
- **Default terminal**: Knife Terminal menu → "Make Default Terminal…" (or `set default` in the footer) registers Knife for `.command`/`.sh`/`.tool`/unix executables and `ssh://`, `telnet://`, `x-man-page://` links. Folders: Finder → Open With → Knife Terminal, or `open -a "Knife Terminal" <dir>`. To open a folder with `claude` running: `printf "open %s" "$dir" | nc -U ~/.knife-terminal.sock` (the Finder "Open with Claude" quick action does this).
- **Claude Code alerts**: "Install Claude Code Alert Hooks…" (or `alerts` in the footer) adds Stop + Notification hooks to `~/.claude/settings.json` that ping `~/.knife-terminal.sock`; the tab gets an orange dot and a chime when Claude is waiting for you. Any terminal bell in a background tab does the same.
- **Session restore**: tabs (and their working directories) are saved and reopened on next launch; project tabs relaunch `claude -c`.
- Drag files/folders onto the terminal to paste their shell-quoted paths.

## Shortcuts
- ⌘T new tab · ⌘W close tab · ⌘1–9 jump to tab · ⌘⇧[ / ⌘⇧] prev/next tab

## Build the macOS app
    npm run install-app    # packages to dist/ and copies to /Applications

Styled with the CW&T design system (`colors_and_type.css`, Space Mono).
