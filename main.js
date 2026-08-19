const { app, BrowserWindow, ipcMain, nativeTheme, Menu, dialog } = require('electron');
const { execFile, execFileSync, spawn: spawnProc } = require('child_process');
const net = require('net');
const path = require('path');
const os = require('os');
const fs = require('fs');
const pty = require('node-pty');

const ptys = new Map();
let win;
let pendingOpens = []; // open-file / open-url requests that arrived before the renderer was ready
let rendererReady = false;

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
  if (rendererReady && win) win.webContents.send('open:request', req);
  else pendingOpens.push(req);
}
app.on('open-file', (e, p) => { e.preventDefault(); dispatchOpen(p); });
app.on('open-url', (e, u) => { e.preventDefault(); dispatchOpen(u); });
ipcMain.on('renderer:ready', () => {
  rendererReady = true;
  win.webContents.send('session:restore', loadSession());
  for (const r of pendingOpens) win.webContents.send('open:request', r); pendingOpens = [];
});

// ─── Session persistence: tabs + their cwd, restored on next launch ───
const SESSION_FILE = path.join(app.getPath('userData'), 'session.json');
let tabMeta = []; // [{id, title, cmd, restoreCmd}] from renderer, in display order
function loadSession() { try { return JSON.parse(fs.readFileSync(SESSION_FILE, 'utf8')); } catch { return null; } }
function cwdOf(pid) {
  try { const out = execFileSync('/usr/sbin/lsof', ['-a', '-p', String(pid), '-d', 'cwd', '-Fn'], { encoding: 'utf8', timeout: 1500 }); const m = out.match(/^n(.+)$/m); return m ? m[1] : null; } catch { return null; }
}
function saveSession() {
  try {
    const tabs = tabMeta.map(t => { const p = ptys.get(t.id); return { title: t.title, cwd: p ? cwdOf(p.pid) : null, cmd: t.restoreCmd || null, active: !!t.active }; });
    fs.mkdirSync(path.dirname(SESSION_FILE), { recursive: true });
    fs.writeFileSync(SESSION_FILE, JSON.stringify({ tabs }, null, 2));
  } catch {}
}
ipcMain.on('session:tabs', (e, meta) => { tabMeta = meta; saveSession(); });
setInterval(saveSession, 15000);
app.on('before-quit', saveSession);

// Register Knife as default handler for shell scripts + ssh/telnet URLs
ipcMain.handle('default:set', () => new Promise(resolve => {
  const helper = path.join(__dirname, 'bin', 'set-default');
  execFile(helper, [app.isPackaged ? 'com.cwandt.knifeterminal' : 'com.github.Electron'], (err, out, errOut) => {
    const ok = !err;
    dialog.showMessageBox(win, { type: ok ? 'info' : 'warning', message: ok ? 'Knife Terminal is now the default terminal.' : 'Some handlers could not be set.',
      detail: (out || '') + (errOut || '') + '\n\nKnife now opens .command/.sh/.tool files, unix executables, and ssh:// / telnet:// links. Folders: right-click → Open With → Knife Terminal.' });
    resolve(ok);
  });
}));

// ─── Attention: Claude Code hooks ping this socket with the tab id ───
const SOCK = path.join(os.homedir(), '.knife-terminal.sock');
const CHIME = '/System/Library/Sounds/Glass.aiff';
function chime() { try { spawnProc('afplay', [CHIME], { stdio: 'ignore', detached: true }).unref(); } catch {} }
function attention(id, type) { if (win) win.webContents.send('attention', { id: Number(id), type }); chime(); }
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
      if (o) { const dir = o[1].trim(); try { if (fs.statSync(dir).isDirectory()) { dispatchOpen(dir, 'claude'); if (win) { win.show(); app.focus({ steal: true }); } } } catch {} return; }
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
function hooksInstalled() {
  try { const cfg = JSON.parse(fs.readFileSync(SETTINGS, 'utf8')); return ['Stop', 'Notification'].every(ev => JSON.stringify(cfg.hooks?.[ev] || []).includes('knife-terminal.sock')); } catch { return false; }
}
ipcMain.handle('hooks:status', () => hooksInstalled());
ipcMain.handle('hooks:install', async () => {
  if (hooksInstalled()) return true;
  const { response } = await dialog.showMessageBox(win, { type: 'question', buttons: ['Install', 'Cancel'], defaultId: 0, cancelId: 1,
    message: 'Add Claude Code hooks for attention alerts?',
    detail: `Adds a Stop and a Notification hook to ${SETTINGS}. Each hook pings Knife (via ~/.knife-terminal.sock) so the tab gets an orange dot and a chime when Claude Code is waiting for you. Nothing else in the file is changed.` });
  if (response !== 0) return false;
  let cfg = {};
  try { cfg = JSON.parse(fs.readFileSync(SETTINGS, 'utf8')); } catch {}
  cfg.hooks = cfg.hooks || {};
  for (const ev of ['Stop', 'Notification']) {
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
      { label: 'Make Default Terminal…', click: () => win && win.webContents.send('menu:set-default') },
      { label: 'Install Claude Code Alert Hooks…', click: () => win && win.webContents.send('menu:install-hooks') },
      { type: 'separator' }, { role: 'hide' }, { role: 'hideOthers' }, { role: 'unhide' }, { type: 'separator' }, { role: 'quit' } ] },
    { label: 'Shell', submenu: [
      { label: 'New Tab', accelerator: 'Cmd+T', click: () => win && win.webContents.send('menu:new-tab') },
      { label: 'Close Tab', accelerator: 'Cmd+W', click: () => win && win.webContents.send('menu:close-tab') } ] },
    { role: 'editMenu' },
    { role: 'viewMenu' },
    { role: 'windowMenu' },
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(tpl));
}

function createWindow() {
  win = new BrowserWindow({
    width: 1100, height: 700,
    titleBarStyle: 'hiddenInset',
    trafficLightPosition: { x: 14, y: 13 },
    backgroundColor: nativeTheme.shouldUseDarkColors ? '#111111' : '#ffffff',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });
  win.loadFile('index.html');
  win.on('closed', () => { win = null; });
}

ipcMain.handle('pty:spawn', (event, { id, cols, rows, cwd, cmd }) => {
  const shell = os.userInfo().shell || process.env.SHELL || '/bin/zsh';
  const p = pty.spawn(shell, ['-l'], {
    name: 'xterm-256color',
    cols, rows,
    cwd: cwd && fs.existsSync(cwd) ? cwd : os.homedir(),
    env: { ...Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith('CLAUDE_CODE_'))), KNIFE_TAB: String(id) },
  });
  if (cmd) setTimeout(() => p.write(cmd + '\r'), 400);
  ptys.set(id, p);
  p.onData(data => { if (win) win.webContents.send('pty:data', { id, data }); });
  p.onExit(() => { ptys.delete(id); if (win) win.webContents.send('pty:exit', { id }); });
  return true;
});

ipcMain.on('pty:write', (e, { id, data }) => ptys.get(id)?.write(data));
ipcMain.on('pty:resize', (e, { id, cols, rows }) => { try { ptys.get(id)?.resize(cols, rows); } catch {} });
ipcMain.on('pty:kill', (e, { id }) => { ptys.get(id)?.kill(); ptys.delete(id); });

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

app.whenReady().then(() => { buildMenu(); startSocket(); createWindow(); });
app.on('window-all-closed', () => { saveSession(); for (const p of ptys.values()) p.kill(); app.quit(); });
