const { app, BrowserWindow, ipcMain, nativeTheme, Menu, dialog, screen } = require('electron');
const { execFile, execFileSync, spawn: spawnProc } = require('child_process');
const net = require('net');
const path = require('path');
const os = require('os');
const fs = require('fs');
const pty = require('node-pty');

const ptys = new Map(); // id -> { p, wc }  (wc = webContents of the window that owns the tab)
const wins = new Set();
let nextTabId = 1;
let pendingOpens = []; // open-file / open-url requests that arrived before any renderer was ready
let pendingRestore = []; // per-window tab lists waiting for a renderer to come up
// The window to talk to: focused, else most recently created
function win() { const f = BrowserWindow.getFocusedWindow(); if (f && wins.has(f)) return f; return [...wins].pop() || null; }
function send(w, ch, m) { if (w && !w.isDestroyed()) w.webContents.send(ch, m); }
function wcById(id) { return [...wins].find(w => w.webContents.id === id)?.webContents || null; }

function shq(p) { return /^[A-Za-z0-9_\/.\-]+$/.test(p) ? p : "'" + p.replace(/'/g, "'\\''") + "'"; }

// Turn a file path or URL into a tab request { cwd, cmd, title }
function openRequest(target) {
  if (/^(ssh|telnet):\/\//.test(target)) {
    const u = new URL(target);
    const user = u.username ? u.username + '@' : '';
    const port = u.port ? (u.protocol === 'ssh:' ? ' -p ' + u.port : ' ' + u.port) : '';
    return { cmd: `${u.protocol.slice(0, -1)} ${user}${u.hostname}${port}`, title: u.hostname };
  }
  if (/^x-man-page:\/\//.test(target)) { const page = target.replace(/^x-man-page:\/\//, ''); return { cmd: 'man ' + page, title: 'man ' + page }; }
  try {
    const st = fs.statSync(target);
    if (st.isDirectory()) return { cwd: target, title: path.basename(target) };
    return { cwd: path.dirname(target), cmd: shq(target), title: path.basename(target) };
  } catch { return null; }
}
function dispatchOpen(target, cmd) {
  const req = openRequest(target);
  if (!req) return;
  if (cmd) req.cmd = cmd;
  const w = win();
  if (w && w.webContents.__ready) send(w, 'open:request', req);
  else pendingOpens.push(req);
}
app.on('open-file', (e, p) => { e.preventDefault(); dispatchOpen(p); });
app.on('open-url', (e, u) => { e.preventDefault(); dispatchOpen(u); });
ipcMain.on('renderer:ready', (e) => {
  e.sender.__ready = true;
  e.sender.send('session:restore', { tabs: pendingRestore.shift() || [] });
  for (const r of pendingOpens) e.sender.send('open:request', r); pendingOpens = [];
});
ipcMain.on('tab:next-id', (e) => { e.returnValue = nextTabId++; });
ipcMain.on('wc:id', (e) => { e.returnValue = e.sender.id; });

// ─── Session persistence: tabs + their cwd, restored on next launch ───
const SESSION_FILE = path.join(app.getPath('userData'), 'session.json');
const tabMeta = new Map(); // webContents.id -> [{id, title, restoreCmd, active}] from that window's renderer, in display order
function loadSession() { try { return JSON.parse(fs.readFileSync(SESSION_FILE, 'utf8')); } catch { return null; } }
function cwdOf(pid) {
  try { const out = execFileSync('/usr/sbin/lsof', ['-a', '-p', String(pid), '-d', 'cwd', '-Fn'], { encoding: 'utf8', timeout: 1500 }); const m = out.match(/^n(.+)$/m); return m ? m[1] : null; } catch { return null; }
}
let lastSaved = null;
function saveSession() {
  try {
    const windows = [...wins].map(w => {
      const b = w.getBounds();
      const tabs = (tabMeta.get(w.webContents.id) || []).map(t => { const e = ptys.get(t.id); return { title: t.title, cwd: e ? cwdOf(e.p.pid) : null, cmd: t.restoreCmd || null, active: !!t.active }; });
      return { bounds: b, tabs };
    }).filter(w => w.tabs.length);
    if (windows.length) lastSaved = { windows };
    if (!lastSaved) return;
    fs.mkdirSync(path.dirname(SESSION_FILE), { recursive: true });
    fs.writeFileSync(SESSION_FILE, JSON.stringify(lastSaved, null, 2));
  } catch {}
}
ipcMain.on('session:tabs', (e, meta) => { tabMeta.set(e.sender.id, meta); saveSession(); });
setInterval(saveSession, 15000);
app.on('before-quit', saveSession);

// Register Knife as default handler for shell scripts + ssh/telnet URLs
ipcMain.handle('default:set', () => new Promise(resolve => {
  const helper = path.join(__dirname, 'bin', 'set-default');
  execFile(helper, [app.isPackaged ? 'com.cwandt.knifeterminal' : 'com.github.Electron'], (err, out, errOut) => {
    const ok = !err;
    dialog.showMessageBox(win(), { type: ok ? 'info' : 'warning', message: ok ? 'Knife Terminal is now the default terminal.' : 'Some handlers could not be set.',
      detail: (out || '') + (errOut || '') + '\n\nKnife now opens .command/.sh/.tool files, unix executables, and ssh:// / telnet:// links. Folders: right-click → Open With → Knife Terminal.' });
    resolve(ok);
  });
}));

// ─── Attention: Claude Code hooks ping this socket with the tab id ───
const SOCK = path.join(os.homedir(), '.knife-terminal.sock');
const CHIME = '/System/Library/Sounds/Glass.aiff';
function chime() { try { spawnProc('afplay', [CHIME], { stdio: 'ignore', detached: true }).unref(); } catch {} }
// Working = Claude (or one of its sub-agents) is mid-turn: animate, don't chime.
// PreToolUse fires for sub-agent tool calls too (they inherit KNIFE_TAB), so parallel agents keep it alive.
const WORKING_ON = new Set(['UserPromptSubmit', 'PreToolUse', 'SubagentStop']);
function attention(id, type) {
  const e = ptys.get(Number(id));
  if (WORKING_ON.has(type)) { if (e) e.wc.send('working', { id: Number(id), on: true }); return; }
  if (e) e.wc.send('working', { id: Number(id), on: false });
  if (type === 'SessionEnd') return;
  if (e) e.wc.send('attention', { id: Number(id), type });
  chime();
}
ipcMain.on('chime', chime);
function startSocket() {
  try { fs.unlinkSync(SOCK); } catch {}
  const srv = net.createServer(c => {
    let buf = '';
    c.on('data', d => { buf += d; });
    c.on('end', () => {
      const msg = buf.trim();
      // "open <dir>" → new tab in <dir> running claude (used by the Finder "Open with Claude" quick action)
      const o = msg.match(/^open\s+(.+)$/s);
      if (o) { const dir = o[1].trim(); try { if (fs.statSync(dir).isDirectory()) { dispatchOpen(dir, 'claude'); const w = win(); if (w) { w.show(); app.focus({ steal: true }); } } } catch {} return; }
      const m = msg.match(/^(\d+)\s*(.*)$/s);
      if (!m) return;
      let type = 'stop';
      try { const j = JSON.parse(m[2] || '{}'); type = j.notification_type || j.hook_event_name || type; } catch {}
      attention(m[1], type);
    });
    c.on('error', () => {});
  });
  srv.on('error', () => {});
  srv.listen(SOCK);
  app.on('will-quit', () => { try { srv.close(); fs.unlinkSync(SOCK); } catch {} });
}

// Claude Code hooks (Stop + Notification) that ping the socket. Installed only when the user asks.
const HOOK_CMD = '[ -n "$KNIFE_TAB" ] && { printf \'%s \' "$KNIFE_TAB"; cat; } | nc -U -w 1 "$HOME/.knife-terminal.sock" >/dev/null 2>&1; exit 0';
const SETTINGS = path.join(os.homedir(), '.claude', 'settings.json');
const HOOK_EVENTS = ['Stop', 'Notification', 'UserPromptSubmit', 'PreToolUse', 'SubagentStop', 'SessionEnd'];
function hooksInstalled() {
  try { const cfg = JSON.parse(fs.readFileSync(SETTINGS, 'utf8')); return HOOK_EVENTS.every(ev => JSON.stringify(cfg.hooks?.[ev] || []).includes('knife-terminal.sock')); } catch { return false; }
}
ipcMain.handle('hooks:status', () => hooksInstalled());
ipcMain.handle('hooks:install', async () => {
  if (hooksInstalled()) return true;
  const { response } = await dialog.showMessageBox(win(), { type: 'question', buttons: ['Install', 'Cancel'], defaultId: 0, cancelId: 1,
    message: 'Add Claude Code hooks for attention alerts?',
    detail: `Adds hooks (${HOOK_EVENTS.join(', ')}) to ${SETTINGS}. Each hook pings Knife (via ~/.knife-terminal.sock) so the tab shows a thinking animation while Claude Code works and glows with a chime when it's waiting for you. Nothing else in the file is changed.` });
  if (response !== 0) return false;
  let cfg = {};
  try { cfg = JSON.parse(fs.readFileSync(SETTINGS, 'utf8')); } catch {}
  cfg.hooks = cfg.hooks || {};
  for (const ev of HOOK_EVENTS) {
    const arr = cfg.hooks[ev] = cfg.hooks[ev] || [];
    if (!JSON.stringify(arr).includes('knife-terminal.sock')) arr.push({ matcher: '', hooks: [{ type: 'command', command: HOOK_CMD }] });
  }
  try { fs.mkdirSync(path.dirname(SETTINGS), { recursive: true }); fs.writeFileSync(SETTINGS, JSON.stringify(cfg, null, 2) + '\n'); return true; }
  catch (e) { dialog.showErrorBox('Could not write settings', String(e)); return false; }
});

function buildMenu() {
  const tpl = [
    { label: app.name, submenu: [
      { role: 'about' }, { type: 'separator' },
      { label: 'Make Default Terminal…', click: () => send(win(), 'menu:set-default') },
      { label: 'Install Claude Code Alert Hooks…', click: () => send(win(), 'menu:install-hooks') },
      { type: 'separator' }, { role: 'hide' }, { role: 'hideOthers' }, { role: 'unhide' }, { type: 'separator' }, { role: 'quit' } ] },
    { label: 'Shell', submenu: [
      { label: 'New Tab', accelerator: 'Cmd+T', click: () => send(win(), 'menu:new-tab') },
      { label: 'New Window', accelerator: 'Cmd+N', click: () => createWindow() },
      { label: 'Close Tab', accelerator: 'Cmd+W', click: () => send(win(), 'menu:close-tab') },
      { type: 'separator' },
      { label: 'Move Tab to New Window', accelerator: 'Cmd+Shift+N', click: () => send(win(), 'menu:tab-to-new-window') },
      { label: 'Merge All Windows', accelerator: 'Cmd+Shift+M', click: () => mergeAll() } ] },
    { role: 'editMenu' },
    { label: 'View', submenu: [
      { label: 'Toggle Sidebar', accelerator: 'Cmd+B', click: () => send(win(), 'menu:toggle-sidebar') },
      { type: 'separator' }, { role: 'reload' }, { role: 'toggleDevTools' }, { type: 'separator' }, { role: 'togglefullscreen' } ] },
    { role: 'windowMenu' },
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(tpl));
}

// Use saved bounds only if a meaningful part of the window would land on a connected display
function onScreen(b) {
  if (!b || !(b.width > 0 && b.height > 0)) return false;
  return screen.getAllDisplays().some(d => {
    const a = d.workArea;
    const ix = Math.min(b.x + b.width, a.x + a.width) - Math.max(b.x, a.x);
    const iy = Math.min(b.y + b.height, a.y + a.height) - Math.max(b.y, a.y);
    return ix >= 120 && iy >= 80;
  });
}
let saveTimer = null;
const saveSoon = () => { clearTimeout(saveTimer); saveTimer = setTimeout(saveSession, 800); };
function createWindow(bounds) {
  const w = new BrowserWindow({
    width: 1100, height: 700, ...(onScreen(bounds) ? bounds : {}),
    titleBarStyle: 'hiddenInset',
    trafficLightPosition: { x: 14, y: 13 },
    backgroundColor: nativeTheme.shouldUseDarkColors ? '#111111' : '#ffffff',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });
  wins.add(w);
  w.on('move', saveSoon); w.on('resize', saveSoon);
  w.loadFile('index.html');
  const wcId = w.webContents.id;
  w.on('closed', () => { wins.delete(w); tabMeta.delete(wcId); for (const [id, e] of ptys) if (e.wc.isDestroyed()) { e.p.kill(); ptys.delete(id); } });
  return w;
}

// ─── Moving tabs between windows ───
// A tab is a pty (lives here) + an xterm (lives in a renderer). To move it, the source renderer serializes its
// screen, sends it with the tab's metadata, and the target renderer recreates the xterm and adopts the pty.
ipcMain.on('tab:move', (e, { id, targetWc, title, opts, buffer }) => {
  const entry = ptys.get(id); const wc = targetWc ? wcById(targetWc) : null;
  if (!entry || !wc) return;
  entry.wc = wc;
  wc.send('tab:adopt', { id, title, opts, buffer });
});
ipcMain.on('tab:pull', (e, { id, srcWc }) => { const wc = wcById(srcWc); if (wc) wc.send('tab:send', { id, targetWc: e.sender.id }); }); // drop target asks source to hand it over
ipcMain.on('tab:to-new-window', (e, { id }) => { const w = createWindow(); w.webContents.once('did-finish-load', () => e.sender.send('tab:send', { id, targetWc: w.webContents.id })); });
function mergeAll() {
  const target = win(); if (!target) return;
  for (const w of wins) if (w !== target) send(w, 'tabs:send-all', { targetWc: target.webContents.id });
}
ipcMain.on('window:close', (e) => { const w = BrowserWindow.fromWebContents(e.sender); if (w && wins.size > 1) w.close(); });

ipcMain.handle('pty:spawn', (event, { id, cols, rows, cwd, cmd }) => {
  const shell = os.userInfo().shell || process.env.SHELL || '/bin/zsh';
  const p = pty.spawn(shell, ['-l'], {
    name: 'xterm-256color',
    cols, rows,
    cwd: cwd && fs.existsSync(cwd) ? cwd : os.homedir(),
    env: { ...Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith('CLAUDE_CODE_'))), KNIFE_TAB: String(id) },
  });
  if (cmd) setTimeout(() => p.write(cmd + '\r'), 400);
  const entry = { p, wc: event.sender };
  ptys.set(id, entry);
  p.onData(data => { if (!entry.wc.isDestroyed()) entry.wc.send('pty:data', { id, data }); });
  p.onExit(() => { ptys.delete(id); if (!entry.wc.isDestroyed()) entry.wc.send('pty:exit', { id }); });
  return true;
});

ipcMain.on('pty:write', (e, { id, data }) => ptys.get(id)?.p.write(data));
ipcMain.on('pty:resize', (e, { id, cols, rows }) => { try { ptys.get(id)?.p.resize(cols, rows); } catch {} });
ipcMain.on('pty:kill', (e, { id }) => { ptys.get(id)?.p.kill(); ptys.delete(id); });

// Previously opened Claude Code projects, most recent first
ipcMain.handle('projects:list', () => {
  try {
    const cfg = JSON.parse(fs.readFileSync(path.join(os.homedir(), '.claude.json'), 'utf8'));
    const projDir = path.join(os.homedir(), '.claude', 'projects');
    const enc = p => p.replace(/[^A-Za-z0-9]/g, '-');
    return Object.keys(cfg.projects || {})
      .filter(p => !p.includes('/.claude-worktrees/') && fs.existsSync(p))
      .map(p => { let t = 0; try { t = fs.statSync(path.join(projDir, enc(p))).mtimeMs; } catch {} return { path: p, name: path.basename(p), t }; })
      .filter(p => p.t > 0)
      .sort((a, b) => b.t - a.t)
      .slice(0, 30);
  } catch { return []; }
});

app.whenReady().then(() => {
  buildMenu(); startSocket();
  const s = loadSession();
  const windows = s?.windows?.length ? s.windows : [{ tabs: s?.tabs || [] }];
  for (const w of windows) { pendingRestore.push(w.tabs || []); createWindow(w.bounds); }
});
app.on('window-all-closed', () => { saveSession(); for (const e of ptys.values()) e.p.kill(); app.quit(); });
