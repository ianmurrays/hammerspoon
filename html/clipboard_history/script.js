    const filterBox = document.getElementById('filter-box');
    const countEl = document.getElementById('count');
    const listEl = document.getElementById('list');
    const detailEl = document.getElementById('detail');
    const previewEl = document.getElementById('preview');
    const metaSource = document.getElementById('meta-source');
    const metaCopied = document.getElementById('meta-copied');
    const metaContent = document.getElementById('meta-content');
    const post = (msg) => window.webkit.messageHandlers.clipboardHistory.postMessage(msg);

    let allEntries = [];
    let filtered = [];
    let selected = 0;

    const TILE_COLORS = {
      Slack: '#611f69', Safari: '#1E6FD9', Ghostty: '#3A3A3C', Notes: '#B8860B',
      Code: '#0F6CBD', 'Visual Studio Code': '#0F6CBD', Mail: '#1E88E5',
    };
    const FALLBACK_COLORS = ['#3E4A5C', '#5B4A3A', '#3D5247', '#5A3E4B', '#4A4458', '#585037', '#3B4F57', '#53433F'];
    const MONO_APPS = /^(Ghostty|Terminal|iTerm2?|Code|Visual Studio Code|Cursor|Xcode|Zed|Nova|Sublime Text|Warp|Alacritty|kitty|WezTerm|Neovide|BBEdit)$/i;

    function tileColor(app) {
      if (TILE_COLORS[app]) return TILE_COLORS[app];
      let h = 0;
      for (const ch of app) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
      return FALLBACK_COLORS[h % FALLBACK_COLORS.length];
    }
    function initials(app) {
      if (!app) return '?';
      if (app === 'Code' || app === 'Visual Studio Code') return 'VS';
      return app[0].toUpperCase();
    }
    const isMono = (app) => MONO_APPS.test(app || '');

    function sameDay(a, b) {
      return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
    }
    function hhmm(d) {
      return d.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit', hour12: false });
    }
    function relativeTime(iso) {
      const d = new Date(iso);
      if (isNaN(d)) return '';
      const secs = (Date.now() - d) / 1000;
      if (secs < 60) return 'now';
      if (secs < 3600) return Math.floor(secs / 60) + 'm';
      const now = new Date();
      if (sameDay(d, now)) return Math.floor(secs / 3600) + 'h';
      const y = new Date(now); y.setDate(now.getDate() - 1);
      if (sameDay(d, y)) return 'Yesterday';
      if (secs < 7 * 86400) return d.toLocaleDateString(undefined, { weekday: 'short' });
      return d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
    }
    function copiedLabel(iso) {
      const d = new Date(iso);
      if (isNaN(d)) return iso || '';
      const now = new Date();
      const y = new Date(now); y.setDate(now.getDate() - 1);
      if (sameDay(d, now)) return 'Today, ' + hhmm(d);
      if (sameDay(d, y)) return 'Yesterday, ' + hhmm(d);
      return d.toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' }) + ', ' + hhmm(d);
    }
    function firstLine(text) {
      const t = text.replace(/^\s+/, '');
      const nl = t.indexOf('\n');
      return nl === -1 ? t : t.slice(0, nl) + '…';
    }

    function renderList() {
      const needle = filterBox.value.toLowerCase();
      filtered = needle
        ? allEntries.filter(e => e.text.toLowerCase().includes(needle) || (e.app && e.app.toLowerCase().includes(needle)))
        : allEntries;
      if (selected >= filtered.length) selected = Math.max(0, filtered.length - 1);

      countEl.textContent = needle
        ? `${filtered.length} ${filtered.length === 1 ? 'match' : 'matches'}`
        : `${allEntries.length} ${allEntries.length === 1 ? 'item' : 'items'}`;

      listEl.replaceChildren();
      if (filtered.length === 0) {
        const empty = document.createElement('div');
        empty.className = 'panel-empty';
        empty.textContent = needle ? 'No matching entries' : 'No entries yet';
        listEl.appendChild(empty);
      }
      filtered.forEach((entry, i) => {
        const row = document.createElement('div');
        row.className = 'clip-row' + (i === selected ? ' selected' : '');

        const tile = document.createElement('div');
        tile.className = 'clip-tile';
        tile.style.background = tileColor(entry.app || '');
        tile.textContent = initials(entry.app);
        row.appendChild(tile);

        const text = document.createElement('div');
        text.className = 'clip-text';
        const line = document.createElement('span');
        line.className = 'clip-line' + (isMono(entry.app) ? ' mono' : '');
        line.textContent = firstLine(entry.text);
        const sub = document.createElement('span');
        sub.className = 'clip-sub';
        sub.textContent = [entry.app, relativeTime(entry.timestamp)].filter(Boolean).join(' · ');
        text.append(line, sub);
        row.appendChild(text);

        row.addEventListener('click', () => select(i));
        row.addEventListener('dblclick', () => { select(i); paste(); });
        listEl.appendChild(row);
      });
      renderDetail();
    }

    function renderDetail() {
      const entry = filtered[selected];
      detailEl.classList.toggle('empty', !entry);
      if (!entry) return;
      previewEl.className = 'clip-preview' + (isMono(entry.app) ? ' mono' : '');
      previewEl.textContent = entry.text;
      previewEl.scrollTop = 0;
      metaSource.textContent = entry.app || 'Unknown';
      metaCopied.textContent = copiedLabel(entry.timestamp);
      const lines = entry.text.split('\n').length;
      const chars = [...entry.text].length;
      metaContent.textContent = `${lines} ${lines === 1 ? 'line' : 'lines'} · ${chars} ${chars === 1 ? 'character' : 'characters'}`;
    }

    function select(i) {
      if (i < 0 || i >= filtered.length) return;
      const rows = listEl.querySelectorAll('.clip-row');
      if (rows[selected]) rows[selected].classList.remove('selected');
      selected = i;
      rows[i].classList.add('selected');
      rows[i].scrollIntoView({ block: 'nearest' });
      renderDetail();
    }

    function paste() {
      const entry = filtered[selected];
      if (entry) post({ action: 'paste', text: entry.text });
    }

    filterBox.addEventListener('input', () => { selected = 0; renderList(); });

    document.addEventListener('keydown', (e) => {
      const entry = filtered[selected];
      if (e.key === 'Escape') {
        e.preventDefault();
        post({ action: 'close' });
      } else if (e.key === 'ArrowDown') {
        e.preventDefault();
        select(Math.min(selected + 1, filtered.length - 1));
      } else if (e.key === 'ArrowUp') {
        e.preventDefault();
        select(Math.max(selected - 1, 0));
      } else if (e.key === 'Enter') {
        e.preventDefault();
        paste();
      } else if (e.metaKey && e.key.toLowerCase() === 'c' && entry) {
        // Keep the native copy when the user has text selected in the preview
        if (String(window.getSelection())) return;
        e.preventDefault();
        post({ action: 'copy', text: entry.text });
      } else if (e.metaKey && e.key === 'Backspace' && entry) {
        e.preventDefault();
        post({ action: 'delete', id: entry.id });
      }
    });

    window.loadEntries = function(jsonStr) {
      try {
        allEntries = JSON.parse(jsonStr);
      } catch (e) {
        console.error('clipboard_history: failed to parse entries:', e);
        allEntries = [];
      }
      renderList();
    };

    window.resetUI = function() {
      filterBox.value = '';
      selected = 0;
      renderList();
      filterBox.focus();
    };

    // Signal Lua that JS is ready to receive data
    post({ action: 'ready' });
