const filterBox = document.getElementById('filter-box');
const countEl = document.getElementById('count');
const entriesEl = document.getElementById('entries');
const MAX_ROWS = 300; // ponytail: render cap, virtualize if history grows past what this shows
let allEntries = [];
let filtered = [];
let selected = 0;

function post(msg) { window.webkit.messageHandlers.sttHistory.postMessage(msg); }

// history.txt stores UTC without a zone suffix
function parseTs(ts) { return new Date(ts + 'Z'); }

function dayLabel(d) {
  const today = new Date(); today.setHours(0, 0, 0, 0);
  const day = new Date(d); day.setHours(0, 0, 0, 0);
  const diff = Math.round((today - day) / 86400000);
  if (diff === 0) return 'Today';
  if (diff === 1) return 'Yesterday';
  return d.toLocaleDateString(undefined, { weekday: 'short', month: 'short', day: 'numeric' });
}

// Append text to el, wrapping case-insensitive matches of needle in <mark>
function appendHighlighted(el, text, needle) {
  if (!needle) { el.appendChild(document.createTextNode(text)); return; }
  const lower = text.toLowerCase();
  let pos = 0;
  for (let i = lower.indexOf(needle); i !== -1; i = lower.indexOf(needle, pos)) {
    el.appendChild(document.createTextNode(text.slice(pos, i)));
    const m = document.createElement('mark');
    m.textContent = text.slice(i, i + needle.length);
    el.appendChild(m);
    pos = i + needle.length;
  }
  el.appendChild(document.createTextNode(text.slice(pos)));
}

// Word-level LCS between raw and polished. Words compare without case and punctuation;
// a matching pair shows the polished spelling.
function wordDiff(raw, llm) {
  const a = raw.split(/\s+/).filter(Boolean);
  const b = llm.split(/\s+/).filter(Boolean);
  const norm = w => w.toLowerCase().replace(/[^\p{L}\p{N}]/gu, '');
  const n = a.length, m = b.length;
  const dp = Array.from({ length: n + 1 }, () => new Array(m + 1).fill(0));
  for (let i = n - 1; i >= 0; i--)
    for (let j = m - 1; j >= 0; j--)
      dp[i][j] = norm(a[i]) === norm(b[j]) ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
  const out = [];
  let i = 0, j = 0;
  while (i < n && j < m) {
    if (norm(a[i]) === norm(b[j])) { out.push({ w: b[j], t: 'same' }); i++; j++; }
    else if (dp[i + 1][j] >= dp[i][j + 1]) out.push({ w: a[i++], t: 'del' });
    else out.push({ w: b[j++], t: 'ins' });
  }
  while (i < n) out.push({ w: a[i++], t: 'del' });
  while (j < m) out.push({ w: b[j++], t: 'ins' });
  return out;
}

const polished = e => e.llm || e.raw || '';

function render() {
  entriesEl.replaceChildren();
  const needle = filterBox.value.trim().toLowerCase();
  filtered = needle
    ? allEntries.filter(e => (e.raw || '').toLowerCase().includes(needle) || (e.llm || '').toLowerCase().includes(needle))
    : allEntries;
  countEl.textContent = `${filtered.length} of ${allEntries.length}`;
  if (selected >= filtered.length) selected = Math.max(0, filtered.length - 1);

  if (filtered.length === 0) {
    const empty = document.createElement('div');
    empty.className = 'panel-empty';
    empty.textContent = needle ? 'No matching transcriptions' : 'No transcriptions yet';
    entriesEl.appendChild(empty);
    return;
  }

  let lastDay = null;
  filtered.slice(0, MAX_ROWS).forEach((entry, idx) => {
    const d = parseTs(entry.timestamp);
    const day = dayLabel(d);
    if (day !== lastDay) {
      const h = document.createElement('div');
      h.className = 'panel-section';
      h.textContent = day;
      entriesEl.appendChild(h);
      lastDay = day;
    }

    const row = document.createElement('div');
    row.className = 'row' + (idx === selected ? ' selected' : '');
    const main = document.createElement('div');
    main.className = 'row-main';
    const text = document.createElement('span');
    text.className = 'row-text';
    appendHighlighted(text, polished(entry), needle);
    main.appendChild(text);
    if (entry.llm && idx !== selected) {
      const dot = document.createElement('span');
      dot.className = 'row-dot';
      dot.textContent = '●';
      main.appendChild(dot);
    }
    const time = document.createElement('span');
    time.className = 'row-time';
    time.textContent = isNaN(d) ? '' : d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false });
    main.appendChild(time);
    row.appendChild(main);

    if (idx === selected && entry.llm && entry.raw) {
      const diff = document.createElement('div');
      diff.className = 'row-diff';
      const label = document.createElement('span');
      label.className = 'row-diff-label';
      label.textContent = 'Original';
      const words = document.createElement('div');
      words.className = 'row-diff-words';
      wordDiff(entry.raw, entry.llm).forEach(t => {
        const s = document.createElement('span');
        if (t.t !== 'same') s.className = t.t;
        s.textContent = t.w;
        words.appendChild(s);
      });
      diff.append(label, words);
      row.appendChild(diff);
    }

    row.addEventListener('click', () => { selected = idx; render(); });
    row.addEventListener('dblclick', () => copy(false));
    entriesEl.appendChild(row);
  });
  const sel = entriesEl.querySelector('.row.selected');
  if (sel) sel.scrollIntoView({ block: 'nearest' });
}

function copy(original) {
  const e = filtered[selected];
  if (!e) return;
  post({ action: 'copy', text: original ? (e.raw || '') : polished(e) });
}

filterBox.addEventListener('input', () => { selected = 0; render(); });

document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') {
    e.preventDefault();
    post({ action: 'close' });
  } else if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
    e.preventDefault();
    const last = Math.min(filtered.length, MAX_ROWS) - 1;
    selected = Math.max(0, Math.min(last, selected + (e.key === 'ArrowDown' ? 1 : -1)));
    render();
  } else if (e.key === 'Enter') {
    e.preventDefault();
    copy(e.altKey);
  }
});

window.loadEntries = function(jsonStr) {
  allEntries = JSON.parse(jsonStr);
  render();
};

window.resetUI = function() {
  filterBox.value = '';
  selected = 0;
  render();
  filterBox.focus();
};

post({ action: 'ready' });
