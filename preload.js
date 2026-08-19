const { contextBridge, ipcRenderer, webUtils } = require('electron');

contextBridge.exposeInMainWorld('pty', {
  spawn: (id, cols, rows, cwd, cmd) => ipcRenderer.invoke('pty:spawn', { id, cols, rows, cwd, cmd }),
  pathFor: (file) => webUtils.getPathForFile(file),
  projects: () => ipcRenderer.invoke('projects:list'),
  write: (id, data) => ipcRenderer.send('pty:write', { id, data }),
  resize: (id, cols, rows) => ipcRenderer.send('pty:resize', { id, cols, rows }),
  kill: (id) => ipcRenderer.send('pty:kill', { id }),
  onData: (cb) => ipcRenderer.on('pty:data', (e, m) => cb(m.id, m.data)),
  onExit: (cb) => ipcRenderer.on('pty:exit', (e, m) => cb(m.id)),
});
