const THEMES = {
  light: {
    background: '#ffffff', foreground: '#111111', cursor: '#111111', cursorAccent: '#ffffff',
    selectionBackground: 'rgba(17,17,17,0.15)',
    black: '#111111', red: '#d11d1d', green: '#2e7d4f', yellow: '#e35a1e',
    blue: '#3a3a38', magenta: '#b08a4d', cyan: '#8c8c87', white: '#b9b8b3',
    brightBlack: '#8a8a8a', brightRed: '#d11d1d', brightGreen: '#2e7d4f', brightYellow: '#e35a1e',
    brightBlue: '#4a4a4a', brightMagenta: '#b08a4d', brightCyan: '#8c8c87', brightWhite: '#ececea',
  },
  dark: {
    background: '#111111', foreground: '#ececea', cursor: '#ececea', cursorAccent: '#111111',
    selectionBackground: 'rgba(236,236,234,0.18)',
    black: '#1a1a18', red: '#e04a4a', green: '#4caf7a', yellow: '#f07a45',
    blue: '#b9b8b3', magenta: '#c9a567', cyan: '#9c9c97', white: '#b9b8b3',
    brightBlack: '#6a6a66', brightRed: '#e04a4a', brightGreen: '#4caf7a', brightYellow: '#f07a45',
    brightBlue: '#d6d6d2', brightMagenta: '#c9a567', brightCyan: '#9c9c97', brightWhite: '#ffffff',
  },
};
const mql = window.matchMedia('(prefers-color-scheme: dark)');
let themeMode = localStorage.getItem('theme') || 'auto'; // auto | light | dark
function resolvedTheme() { return themeMode === 'auto' ? (mql.matches ? 'dark' : 'light') : themeMode; }
function termTheme() { return THEMES[resolvedTheme()]; }
function applyTheme() {
  document.documentElement.dataset.theme = resolvedTheme();
  document.getElementById('theme').textContent = themeMode;
  for (const t of tabs.values()) t.term.options.theme = termTheme();
}
mql.addEventListener('change', applyTheme);
document.getElementById('theme').onclick = () => {
  themeMode = { auto: 'light', light: 'dark', dark: 'auto' }[themeMode];
  localStorage.setItem('theme', themeMode); applyTheme();
};

// Emoji picker: keyword match on the folder name (quick, no network), hash fallback.
const EMOJI_KEYS = [
  ['knife|blade|cut|slice','🔪'], ['terminal|shell|cli|console','⌨️'], ['clock|time|watch|timer|hour|minute','⏱️'],
  ['earth|globe|planet|world|geo|map','🌍'], ['sea|ocean|wave|tide|level|marine','🌊'], ['sun|solar|light|lamp','☀️'],
  ['moon|lunar|night|dark','🌙'], ['star|space|astro|orbit|satellite','🛰️'], ['rocket|launch','🚀'],
  ['email|mail|inbox|newsletter','✉️'], ['invoice|bill|receipt|payment|pay|money|cash|price','🧾'],
  ['todo|task|list|checklist|reminder','☑️'], ['calendar|schedule|date|event|fork','📅'], ['news|press|paper|journal|blog','📰'],
  ['cms|content|site|web|www|html|page','🗂️'], ['engrav|laser|etch','🔆'], ['camera|photo|wink|lens|image|pic','📷'],
  ['video|film|movie|clip','🎬'], ['music|song|audio|sound|wav|mp3|spotify|spoon','🎵'], ['speaker|radio|pager|ring|bell|alert','🔔'],
  ['game|play|arcade|puzzle|squirrel','🎮'], ['bot|robot|agent|ai|gpt|llm|claude','🤖'], ['arb|arbitrage|trade|trading|stock|crypto|market','📈'],
  ['bunny|rabbit','🐰'], ['flamingo','🦩'], ['crow|bird|flight|wing|feather','🐦‍⬛'], ['mosquito|bug|insect|fly|pest','🦟'], ['pebble|stone|rock|haptic','🪨'],
  ['incense|smoke|scent|candle','🕯️'], ['glasses|eyewear|spec|vision|eye','👓'], ['titanium|metal|steel|alu|brass|machin|cnc|mill|lathe','⚙️'],
  ['pcb|schematic|circuit|electronic|board|kicad|easyeda','🔌'], ['mcp|server|api|proxy|socket|daemon','🔧'], ['design|figma|ui|ux|system|style|theme|font|type','🎨'],
  ['art|artwork|archive|gallery|museum|paint|draw|sketch','🖼️'], ['cad|fusion|3d|model|mesh|print|stl|cadgang','📐'], ['parts|fast|mcmaster|hardware|tool|supply|stock','🔩'],
  ['standard|industry|spec|norm','📏'], ['meditat|zen|calm|breath|mind','🧘'], ['box|crate|package|case|enclosure','📦'], ['noodle|ramen|food|eat|kitchen|cook|recipe','🍜'],
  ['polar|pair|bear|ice|snow|cold|arctic','🐻‍❄️'], ['academy|school|class|course|learn|teach|study|edu','🎓'], ['pendant|necklace|jewel|ring|remix','📿'],
  ['pager|beeper|message|chat|sms|text','📟'], ['human|person|people|body|health|fit','🧍'], ['straw|drink|cup|coffee|tea|bar','🥤'],
  ['proof|life|heart|pulse|alive|check','💓'], ['moire|pattern|texture|grid|wave','🌀'], ['tempra|temp|heat|thermo|weather|climate','🌡️'],
  ['constructor|build|sim|simulation|physics|engine','🏗️'], ['infinite|loop|forever|endless','♾️'], ['random|dice|together|chance|shuffle','🎲'],
  ['dropbox|sync|cloud|backup|drive','☁️'], ['download|dl|fetch|import','⬇️'], ['advisor|advice|consult|coach|mentor','🧭'], ['crouton|bread|toast|bake','🍞'],
  ['jesus|church|holy|faith|pray','✝️'], ['tag|barcode|label|qr|scan|sticker','🏷️'], ['darkball|ball|sphere|orb','⚫'], ['ios|iphone|mobile|app|swift|xcode','📱'],
  ['mac|macos|desktop|electron','🖥️'], ['git|github|repo|code|dev|src','💻'], ['test|spec|lab|experiment|research','🧪'], ['doc|docs|note|wiki|readme|write|book','📓'],
  ['home|house|room|furniture','🏠'], ['car|auto|vehicle|drive|bike|bicycle','🚲'], ['plant|garden|tree|leaf|flower|seed','🌱'], ['dog|puppy|cat|kitten|pet','🐾'],
  ['fish|shark|whale|squid|octopus','🐙'], ['fire|flame|burn|hot','🔥'], ['water|rain|drop|liquid|fluid','💧'], ['wind|air|fan|breeze','🌬️'],
  ['key|lock|auth|login|password|secure|vault','🔑'], ['search|find|query|index','🔍'], ['data|db|database|sql|table|sheet|csv','🗄️'], ['chart|graph|plot|dash|analytics|stat','📊'],
  ['shop|store|cart|commerce|shopify|order|sell','🛒'], ['ship|deliver|post|parcel|tracking','📬'], ['phone|call|voice|dial','📞'], ['printer|print|ink|paper','🖨️'],
  ['battery|power|charge|volt|energy','🔋'], ['magnet|mag','🧲'], ['wire|cable|usb|plug','🔌'], ['watch|wrist|final','⌚'], ['pen|pencil|write|draft','✏️'],
  ['trophy|win|award|best','🏆'], ['flag|country|nation','🚩'], ['egg|chick|hatch|gochi|tamagotchi','🥚'], ['wang|levy|cw|cwandt|cwt','🔪']
];
const EMOJI = ['🪚','🔧','🔩','⚙️','🧲','🧪','🔬','🔭','📐','📏','✏️','📎','🧷','🧵','🪵','🪨','🧱','🔦','🕯️','💡','🔋','📡','🛠️','⚗️','🧭','⏱️','⌛','🪙','🎛️','🎚️','📻','🔑','🪛','🧰','📦','📁','📓','🌲','🌵','🍄','🪴','🌊','🔥','❄️','⚡','🌑','🌕','🐙','🦀','🐢','🦉','🐋','🦊','🐻','🐚','🪶','🍋','🍎','🫐','🧊','🏔️','⛺','🛶','⛵','🚲','🎲','♟️','🎯','🎹','🥁','🎸'];
const EMOJI_RX = EMOJI_KEYS.map(([k, e]) => [new RegExp('^(' + k + ')', 'i'), new RegExp('(' + k + ')', 'i'), e]);
const emojiOverrides = JSON.parse(localStorage.getItem('emoji') || '{}');
function emojiFor(path) {
  if (!path) return '🔪';
  if (emojiOverrides[path]) return emojiOverrides[path];
  const name = path.split('/').pop();
  const tokens = name.replace(/([a-z])([A-Z])/g, '$1 $2').split(/[^A-Za-z0-9]+/).filter(Boolean);
  let best = null, bestLen = 0; // longest keyword match wins; prefix match on any token, substring only for longer tokens
  tokens.forEach((t, i) => { for (const [rx, sub, e] of EMOJI_RX) {
    const m = rx.exec(t) || (t.length >= 6 && sub.exec(t));
    const len = m ? m[1].length + (i === 0 ? 3 : 0) : 0; // first word gets a bonus
    if (len > bestLen) { best = e; bestLen = len; }
  } });
  if (best) return best;
  let h = 0; for (const c of path) h = (h * 31 + c.charCodeAt(0)) >>> 0; return EMOJI[h % EMOJI.length];
}
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
    theme: termTheme(),
  });
  const fit = new FitAddon.FitAddon();
  term.loadAddon(fit);
  term.open(termEl);

  const tabEl = document.createElement('div');
  tabEl.className = 'tab';
  tabEl.innerHTML = `<span class="dot"></span><span class="emoji">${opts.cwd ? emojiFor(opts.cwd) : "🔪"}</span><span class="title">shell ${id}</span><span class="close">×</span>`;
  tabEl.onclick = (e) => { if (e.target.classList.contains('close')) closeTab(id); else activate(id); };
  tabsEl.appendChild(tabEl);

  tabs.set(id, { term, fit, tabEl, termEl, opts });
  activate(id);
  fit.fit();
  syncSession();
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

  term.onData(data => { window.pty.write(id, data); tabEl.classList.remove('attn'); });
  term.onBell(() => markAttention(id, true));
  term.onResize(({ cols, rows }) => window.pty.resize(id, cols, rows));
  term.onTitleChange(title => { if (!opts.title) tabEl.querySelector('.title').textContent = title || `shell ${id}`; });
}

function activate(id) {
  active = id;
  if (document.hasFocus()) tabs.get(id)?.tabEl.classList.remove('attn');
  syncSession();
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
  syncSession();
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
    el.className = 'proj'; el.innerHTML = `<span class="emoji">${emojiFor(p.path)}</span><span class="name"></span>`; el.querySelector('.name').textContent = p.name; el.title = p.path;
    el.onclick = () => createTab({ cwd: p.path, cmd: 'claude', restoreCmd: 'claude -c', title: p.name });
    projectsEl.appendChild(el);
  }
  filterProjects();
}
loadProjects();
window.addEventListener('focus', loadProjects);

const searchEl = document.getElementById('search');
function filterProjects() {
  const q = searchEl.value.trim().toLowerCase();
  for (const el of projectsEl.children) el.classList.toggle('hidden', q && !el.textContent.toLowerCase().includes(q) && !el.title.toLowerCase().includes(q));
}
searchEl.addEventListener('input', filterProjects);
searchEl.addEventListener('keydown', e => {
  if (e.key === 'Enter') { const first = [...projectsEl.children].find(el => !el.classList.contains('hidden')); if (first) { first.click(); searchEl.value = ''; filterProjects(); } }
  else if (e.key === 'Escape') { searchEl.value = ''; filterProjects(); active && tabs.get(active)?.term.focus(); }
});
window.addEventListener('resize', () => active && tabs.get(active)?.fit.fit());
window.addEventListener('keydown', (e) => {
  if (!e.metaKey) return;
  if (e.key === 'k') { e.preventDefault(); searchEl.focus(); searchEl.select(); }
  else if (e.key === 'b') { e.preventDefault(); toggleSidebar(); }
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

// Green tab (glowing emoji when collapsed) + chime when a Claude Code session (or any bell) wants attention
function markAttention(id, fromBell) {
  const t = tabs.get(id); if (!t) return;
  if (fromBell && id === active && document.hasFocus()) return; // a bell in the tab you're looking at is just a bell
  t.tabEl.classList.add('attn');
  if (fromBell) window.pty.chime();
}
window.pty.onAttention((id) => markAttention(id, false));
window.addEventListener('focus', () => { if (active) tabs.get(active)?.tabEl.classList.remove('attn'); });

const hooksEl = document.getElementById('hooks');
async function refreshHooks() { hooksEl.textContent = (await window.pty.hooksStatus()) ? 'alerts on' : 'alerts off'; }
hooksEl.onclick = async () => { await window.pty.installHooks(); refreshHooks(); };
refreshHooks();

window.pty.onOpen(req => createTab(req));
window.pty.onMenu(what => {
  if (what === 'new-tab') createTab();
  else if (what === 'close-tab') { if (document.activeElement === searchEl) return; active && closeTab(active); }
  else if (what === 'set-default') window.pty.setDefault();
  else if (what === 'toggle-sidebar') toggleSidebar();
  else if (what === 'install-hooks') { window.pty.installHooks().then(refreshHooks); }
});
document.getElementById('setdefault').onclick = () => window.pty.setDefault();
function toggleSidebar() {
  const on = document.body.classList.toggle('collapsed');
  localStorage.setItem('sidebar', on ? 'collapsed' : 'open');
  document.getElementById('collapse').textContent = on ? '›' : '‹';
  requestAnimationFrame(() => active && tabs.get(active)?.fit.fit());
}
if (localStorage.getItem('sidebar') === 'collapsed') { document.body.classList.add('collapsed'); document.getElementById('collapse').textContent = '›'; }
document.getElementById('collapse').onclick = toggleSidebar;

function syncSession() {
  window.pty.saveTabs([...tabs].map(([id, t]) => ({ id, title: t.tabEl.querySelector('.title').textContent, restoreCmd: t.opts.restoreCmd || null, active: id === active })));
}

applyTheme();
window.pty.onRestore(s => {
  const saved = (s?.tabs || []).filter(t => t.cwd);
  if (!saved.length) { createTab(); return; }
  let act = null;
  for (const t of saved) { createTab({ cwd: t.cwd, cmd: t.cmd, restoreCmd: t.cmd, title: t.cmd ? t.title : undefined }); if (t.active) act = active; }
  if (act) activate(act);
});
window.pty.ready();
