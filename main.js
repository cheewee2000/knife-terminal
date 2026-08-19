const { app, BrowserWindow, ipcMain } = require('electron');
const path = require('path');
const os = require('os');
const pty = require('node-pty');

const ptys = new Map();
let win;

function createWindow() {
  win = new BrowserWindow({
    width: 1000,
    height: 650,
    titleBarStyle: 'hiddenInset',
    trafficLightPosition: { x: 14, y: 13 },
    backgroundColor: '#ffffff',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });
  win.loadFile('index.html');
  win.on('closed', () => { win = null; });
}

ipcMain.handle('pty:spawn', (event, { id, cols, rows }) => {
  const shell = os.userInfo().shell || process.env.SHELL || '/bin/zsh';
  const p = pty.spawn(shell, ['-l'], {
    name: 'xterm-256color',
    cols, rows,
    cwd: os.homedir(),
    env: process.env,
  });
  ptys.set(id, p);
  p.onData(data => { if (win) win.webContents.send('pty:data', { id, data }); });
  p.onExit(() => { ptys.delete(id); if (win) win.webContents.send('pty:exit', { id }); });
  return true;
});

ipcMain.on('pty:write', (e, { id, data }) => ptys.get(id)?.write(data));
ipcMain.on('pty:resize', (e, { id, cols, rows }) => { try { ptys.get(id)?.resize(cols, rows); } catch {} });
ipcMain.on('pty:kill', (e, { id }) => { ptys.get(id)?.kill(); ptys.delete(id); });

app.whenReady().then(createWindow);
app.on('window-all-closed', () => { for (const p of ptys.values()) p.kill(); app.quit(); });
