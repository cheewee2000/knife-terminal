const { app, BrowserWindow, ipcMain, nativeTheme } = require('electron');
const path = require('path');
const os = require('os');
const fs = require('fs');
const pty = require('node-pty');

const ptys = new Map();
let win;

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
    env: Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith('CLAUDE_CODE_'))),
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

app.whenReady().then(createWindow);
app.on('window-all-closed', () => { for (const p of ptys.values()) p.kill(); app.quit(); });
