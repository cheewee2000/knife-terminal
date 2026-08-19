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
  ready: () => ipcRenderer.send('renderer:ready'),
  onRestore: (cb) => ipcRenderer.once('session:restore', (e, s) => cb(s)),
  saveTabs: (meta) => ipcRenderer.send('session:tabs', meta),
  onOpen: (cb) => ipcRenderer.on('open:request', (e, req) => cb(req)),
  onMenu: (cb) => { for (const k of ['new-tab', 'close-tab', 'set-default', 'install-hooks']) ipcRenderer.on('menu:' + k, () => cb(k)); },
  setDefault: () => ipcRenderer.invoke('default:set'),
  hooksStatus: () => ipcRenderer.invoke('hooks:status'),
  installHooks: () => ipcRenderer.invoke('hooks:install'),
  onAttention: (cb) => ipcRenderer.on('attention', (e, m) => cb(m.id, m.type)),
  chime: () => ipcRenderer.send('chime'),
});
