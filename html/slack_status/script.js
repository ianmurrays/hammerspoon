const PRESETS = {{PRESETS}};
const DURATIONS = [
  { value: '30', label: '30 min' },
  { value: '60', label: '1 hour' },
  { value: '120', label: '2 hours' },
  { value: '240', label: '4 hours' },
  { value: 'eod', label: 'End of day' },
  { value: '0', label: "Don't clear" },
];

const panelEl = document.getElementById('panel');
const input = document.getElementById('statusText');
const rowsEl = document.getElementById('rows');
const grid = document.getElementById('emojiGrid');
const emojiPick = document.getElementById('emojiPick');
const durationEl = document.getElementById('duration');
const emojiBtns = Array.from(grid.querySelectorAll('.emoji-btn'));

let durationIdx = 1;
let emojiIdx = 0;       // selected emoji
let gridCursor = 0;     // keyboard cursor while the grid is active
let gridActive = false;
let rows = [];
let selected = 0;

function post(msg) { window.webkit.messageHandlers.customStatus.postMessage(msg); }

// A leading Slack shortcode (":custom_emoji: text") overrides the picked emoji
function parseInput() {
  const raw = input.value.trim();
  const m = raw.match(/^(:[a-z0-9_+\-']+:)\s*(.*)$/i);
  return m ? { code: m[1], text: m[2] } : { code: null, text: raw };
}

function renderEmoji() {
  const { code } = parseInput();
  emojiBtns.forEach((b, i) => {
    b.classList.toggle('selected', i === emojiIdx && !code);
    b.classList.toggle('cursor', i === gridCursor);
  });
  grid.classList.toggle('active', gridActive);
  emojiPick.classList.toggle('code', !!code);
  emojiPick.textContent = code || emojiBtns[emojiIdx].textContent;
}

function renderRows() {
  const { text } = parseInput();
  const needle = text.toLowerCase();
  rows = PRESETS.filter(p => !needle || p.text.toLowerCase().includes(needle)).map(p => ({ preset: p }));
  if (text) rows.push({ free: text });
  selected = Math.min(selected, Math.max(rows.length - 1, 0));

  while (rowsEl.firstChild) rowsEl.removeChild(rowsEl.firstChild);
  if (PRESETS.length && !needle) {
    const h = document.createElement('div');
    h.className = 'panel-section';
    h.textContent = 'Presets';
    rowsEl.appendChild(h);
  }
  rows.forEach((r, i) => {
    const row = document.createElement('div');
    row.className = 'row' + (i === selected ? ' selected' : '');
    const e = document.createElement('span');
    e.className = 'e';
    const t = document.createElement('span');
    t.className = 't';
    const x = document.createElement('span');
    x.className = 'x';
    if (r.preset) {
      e.textContent = r.preset.emoji;
      t.textContent = r.preset.text;
      x.textContent = r.preset.expiry;
    } else {
      e.textContent = parseInput().code ? '✏️' : emojiBtns[emojiIdx].textContent;
      t.textContent = 'Set “' + r.free + '”';
      x.textContent = DURATIONS[durationIdx].label;
    }
    row.append(e, t, x);
    row.addEventListener('mousemove', () => { if (selected !== i) { selected = i; renderRows(); } });
    row.addEventListener('click', () => { selected = i; submit(); });
    rowsEl.appendChild(row);
  });
  resize();
}

function resize() { post({ action: 'resize', height: panelEl.offsetHeight }); }

function submit() {
  const r = rows[selected];
  if (!r) return;
  if (r.preset) {
    post({ action: 'preset', index: r.preset.index });
    return;
  }
  const { code, text } = parseInput();
  post({
    action: 'submit',
    emoji: code || emojiBtns[emojiIdx].getAttribute('data-code'),
    text: text,
    expiration: DURATIONS[durationIdx].value,
  });
}

function cycleDuration(step) {
  durationIdx = (durationIdx + step + DURATIONS.length) % DURATIONS.length;
  durationEl.textContent = DURATIONS[durationIdx].label;
  renderRows();
}

function pickEmoji(i) {
  emojiIdx = i;
  gridCursor = i;
  // A picked emoji replaces a typed shortcode
  const { code, text } = parseInput();
  if (code) input.value = text;
  setGridActive(false);
  renderRows();
}

function setGridActive(on) {
  gridActive = on;
  if (on) gridCursor = emojiIdx;
  renderEmoji();
  input.focus();
}

// Columns in the grid's first row, for up/down movement
function gridCols() {
  const top = emojiBtns[0].offsetTop;
  return emojiBtns.filter(b => b.offsetTop === top).length;
}

emojiBtns.forEach((b, i) => b.addEventListener('click', () => pickEmoji(i)));
emojiPick.addEventListener('click', () => setGridActive(!gridActive));
durationEl.addEventListener('click', () => cycleDuration(1));
input.addEventListener('input', () => { selected = 0; renderEmoji(); renderRows(); });

// Focus stays in the input; the grid is driven by a keyboard cursor while active
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') {
    e.preventDefault();
    if (gridActive) setGridActive(false); else post({ action: 'cancel' });
    return;
  }
  if (e.key === 'Tab') {
    e.preventDefault();
    setGridActive(!gridActive);
    return;
  }
  if (e.metaKey && e.key === 'Backspace') {
    e.preventDefault();
    post({ action: 'clear' });
    return;
  }
  if (e.altKey && (e.key === 'ArrowLeft' || e.key === 'ArrowRight')) {
    e.preventDefault();
    cycleDuration(e.key === 'ArrowLeft' ? -1 : 1);
    return;
  }
  if (gridActive) {
    const n = emojiBtns.length;
    const moves = { ArrowLeft: -1, ArrowRight: 1, ArrowUp: -gridCols(), ArrowDown: gridCols() };
    if (e.key in moves) {
      e.preventDefault();
      gridCursor = Math.min(n - 1, Math.max(0, gridCursor + moves[e.key]));
      renderEmoji();
    } else if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      pickEmoji(gridCursor);
    }
    return;
  }
  if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
    e.preventDefault();
    if (!rows.length) return;
    selected = (selected + (e.key === 'ArrowDown' ? 1 : -1) + rows.length) % rows.length;
    renderRows();
  } else if (e.key === 'Enter') {
    e.preventDefault();
    submit();
  }
});

renderEmoji();
renderRows();
input.focus();
