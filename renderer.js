const tabs = new Map(); // id -> { term, fit, tabEl, termEl }
let active = null;
let nextId = 1;
const tabsEl = document.getElementById('tabs');
const projectsEl = document.getElementById('projects');
const newtabBtn = document.getElementById('newtab');
const termsEl = document.getElementById('terms');

function createTab(opts = {}) {
  const id = nextId++;
  const termEl = document.createElement('div');
  termEl.className = 'term';
  termsEl.appendChild(termEl);

  const term = new Terminal({
    fontFamily: "'Space Mono', 'JetBrains Mono', Menlo, 'Courier New', monospace",
    fontSize: 13,
    lineHeight: 1.2,
    cursorBlink: false,
    cursorStyle: 'block',
    theme: {
      background: '#ffffff', foreground: '#111111',
      cursor: '#111111', cursorAccent: '#ffffff',
      selectionBackground: 'rgba(17,17,17,0.15)',
      black: '#111111', red: '#d11d1d', green: '#2e7d4f', yellow: '#e35a1e',
      blue: '#3a3a38', magenta: '#b08a4d', cyan: '#8c8c87', white: '#b9b8b3',
      brightBlack: '#8a8a8a', brightRed: '#d11d1d', brightGreen: '#2e7d4f', brightYellow: '#e35a1e',
      brightBlue: '#4a4a4a', brightMagenta: '#b08a4d', brightCyan: '#8c8c87', brightWhite: '#ececea',
    },
  });
  const fit = new FitAddon.FitAddon();
  term.loadAddon(fit);
  term.open(termEl);

  const tabEl = document.createElement('div');
  tabEl.className = 'tab';
  tabEl.innerHTML = `<span class="title">shell ${id}</span><span class="close">×</span>`;
  tabEl.onclick = (e) => { if (e.target.classList.contains('close')) closeTab(id); else activate(id); };
  tabsEl.appendChild(tabEl);

  tabs.set(id, { term, fit, tabEl, termEl });
  activate(id);
  fit.fit();
  window.pty.spawn(id, term.cols, term.rows, opts.cwd, opts.cmd);
  if (opts.title) tabEl.querySelector('.title').textContent = opts.title;

  // drag & drop files/folders → paste shell-quoted path
  termEl.addEventListener('dragover', e => { e.preventDefault(); termEl.classList.add('over'); });
  termEl.addEventListener('dragleave', () => termEl.classList.remove('over'));
  termEl.addEventListener('drop', e => {
    e.preventDefault(); termEl.classList.remove('over');
    const paths = [...e.dataTransfer.files].map(f => window.pty.pathFor(f)).filter(Boolean);
    if (paths.length) { window.pty.write(id, paths.map(shellQuote).join(' ') + ' '); term.focus(); }
  });

  term.onData(data => window.pty.write(id, data));
  term.onResize(({ cols, rows }) => window.pty.resize(id, cols, rows));
  term.onTitleChange(title => { if (!opts.title) tabEl.querySelector('.title').textContent = title || `shell ${id}`; });
}

function activate(id) {
  active = id;
  for (const [tid, t] of tabs) {
    t.tabEl.classList.toggle('active', tid === id);
    t.termEl.classList.toggle('active', tid === id);
  }
  const t = tabs.get(id);
  requestAnimationFrame(() => { t.fit.fit(); t.term.focus(); });
}

function closeTab(id) {
  const t = tabs.get(id);
  if (!t) return;
  window.pty.kill(id);
  t.term.dispose();
  t.tabEl.remove();
  t.termEl.remove();
  tabs.delete(id);
  if (tabs.size === 0) { createTab(); return; }
  if (active === id) activate([...tabs.keys()].pop());
}

window.pty.onData((id, data) => tabs.get(id)?.term.write(data));
window.pty.onExit((id) => closeTab(id));

newtabBtn.onclick = () => createTab();

function shellQuote(p) { return /^[A-Za-z0-9_\/.\-]+$/.test(p) ? p : "'" + p.replace(/'/g, "'\\''") + "'"; }

async function loadProjects() {
  const list = await window.pty.projects();
  projectsEl.innerHTML = '';
  for (const p of list) {
    const el = document.createElement('div');
    el.className = 'proj'; el.textContent = p.name; el.title = p.path;
    el.onclick = () => createTab({ cwd: p.path, cmd: 'claude', title: p.name });
    projectsEl.appendChild(el);
  }
}
loadProjects();
window.addEventListener('focus', loadProjects);
window.addEventListener('resize', () => active && tabs.get(active)?.fit.fit());
window.addEventListener('keydown', (e) => {
  if (!e.metaKey) return;
  if (e.key === 't') { e.preventDefault(); createTab(); }
  else if (e.key === 'w') { e.preventDefault(); if (active) closeTab(active); }
  else if (e.key === '}' || (e.shiftKey && e.key === ']')) { e.preventDefault(); cycle(1); }
  else if (e.key === '{' || (e.shiftKey && e.key === '[')) { e.preventDefault(); cycle(-1); }
  else if (e.key >= '1' && e.key <= '9') {
    const ids = [...tabs.keys()]; const t = ids[Number(e.key) - 1];
    if (t) { e.preventDefault(); activate(t); }
  }
});
function cycle(dir) {
  const ids = [...tabs.keys()]; const i = ids.indexOf(active);
  activate(ids[(i + dir + ids.length) % ids.length]);
}

createTab();
