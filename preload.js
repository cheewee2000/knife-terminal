const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('pty', {
  spawn: (id, cols, rows) => ipcRenderer.invoke('pty:spawn', { id, cols, rows }),
  write: (id, data) => ipcRenderer.send('pty:write', { id, data }),
  resize: (id, cols, rows) => ipcRenderer.send('pty:resize', { id, cols, rows }),
  kill: (id) => ipcRenderer.send('pty:kill', { id }),
  onData: (cb) => ipcRenderer.on('pty:data', (e, m) => cb(m.id, m.data)),
  onExit: (cb) => ipcRenderer.on('pty:exit', (e, m) => cb(m.id)),
});
