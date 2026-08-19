# Knife Terminal

CW&T's own terminal. Electron + xterm.js + node-pty. Basic for now — just tabs.

## Run
    npm install
    npm start

## Features
- Left sidebar: tabs, then recent Claude Code projects (from `~/.claude.json`) — click one to open a tab in that folder running `claude`.
- ⌘K searches projects; Enter opens the first match. Theme toggle (auto/light/dark) in the sidebar footer.
- Drag files/folders onto the terminal to paste their shell-quoted paths.

## Shortcuts
- ⌘T new tab · ⌘W close tab · ⌘1–9 jump to tab · ⌘⇧[ / ⌘⇧] prev/next tab

## Build the macOS app
    npm run install-app    # packages to dist/ and copies to /Applications

Styled with the CW&T design system (`colors_and_type.css`, Space Mono).
