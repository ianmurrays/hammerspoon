    const searchBox = document.getElementById('search-box');
    const status = document.getElementById('status');
    const results = document.getElementById('results');
    const COLS = 4;
    const TABS = ['search', 'favorites', 'recents'];
    let currentTab = 'search';
    let favoritesSet = new Set();
    let gifs = [];      // list from Lua for the current tab
    let shown = [];     // gifs after the local filter (favorites/recents)
    let columns = [];   // columns[c] = indices into shown, top to bottom
    let tileEls = [];   // tileEls[i] = element for shown[i]
    let selected = -1;
    let searchTimer = null;

    function post(msg) {
      window.webkit.messageHandlers.gifFinder.postMessage(msg);
    }

    function setStatus(text, isError) {
      status.className = 'panel-empty' + (isError ? ' error' : '');
      status.textContent = text;
    }

    function emptyText() {
      if (currentTab === 'search') return searchBox.value.trim() ? 'No results found' : 'Type to search Klipy';
      if (gifs.length && searchBox.value.trim()) return 'No matches';
      return currentTab === 'favorites' ? 'No favorites yet. Press ⌘D on a GIF to add it.' : 'No recent GIFs';
    }

    // Masonry: each tile goes to the currently shortest column. Columns have equal width,
    // so column height is tracked as the sum of height/width ratios.
    function render(keepSelection) {
      const prev = selected;
      results.replaceChildren();
      columns = Array.from({ length: COLS }, () => []);
      tileEls = [];
      const colRatio = new Array(COLS).fill(0);
      const colEls = columns.map(() => {
        const col = document.createElement('div');
        col.className = 'gif-col';
        return col;
      });

      if (shown.length === 0) {
        selected = -1;
        setStatus(emptyText());
        return;
      }
      setStatus('');

      shown.forEach((gif, i) => {
        const ratio = gif.width > 0 && gif.height > 0 ? gif.height / gif.width : 1;
        let c = 0;
        for (let k = 1; k < COLS; k++) if (colRatio[k] < colRatio[c]) c = k;
        colRatio[c] += ratio;
        columns[c].push(i);

        const item = document.createElement('div');
        item.className = 'gif-item';
        item.style.aspectRatio = gif.width > 0 && gif.height > 0 ? gif.width + ' / ' + gif.height : '1 / 1';
        const img = document.createElement('img');
        img.src = gif.thumb;
        img.loading = 'lazy';
        item.appendChild(img);
        if (favoritesSet.has(gif.url)) {
          const badge = document.createElement('div');
          badge.className = 'fav-badge';
          badge.textContent = '★';
          item.appendChild(badge);
        }
        const overlay = document.createElement('div');
        overlay.className = 'copy-overlay';
        const key = document.createElement('span');
        key.className = 'key';
        key.textContent = '↵';
        overlay.append(key, 'Copy URL');
        item.appendChild(overlay);
        item.addEventListener('click', (e) => {
          select(i);
          copy(e.metaKey ? 'selectHtml' : 'select');
        });
        item.addEventListener('mouseenter', () => select(i));
        colEls[c].appendChild(item);
        tileEls.push(item);
      });
      colEls.forEach(col => results.appendChild(col));
      select(keepSelection ? Math.min(Math.max(prev, 0), shown.length - 1) : 0);
    }

    function applyFilter(keepSelection) {
      const needle = searchBox.value.trim().toLowerCase();
      shown = currentTab === 'search' || !needle
        ? gifs
        : gifs.filter(g => (g.title || '').toLowerCase().includes(needle));
      render(keepSelection);
    }

    function select(i) {
      if (tileEls[selected]) tileEls[selected].classList.remove('selected');
      selected = i;
      const el = tileEls[i];
      if (el) {
        el.classList.add('selected');
        el.scrollIntoView({ block: 'nearest' });
      }
    }

    function copy(action) {
      const gif = shown[selected];
      if (gif) post({ action: action, gif: gif });
    }

    function locate(i) {
      for (let c = 0; c < COLS; c++) {
        const r = columns[c].indexOf(i);
        if (r >= 0) return { c, r };
      }
      return null;
    }

    function centreY(i) {
      const el = tileEls[i];
      return el.offsetTop + el.offsetHeight / 2;
    }

    // Up/down stay in the column; left/right jump to the tile in the next non-empty
    // column whose vertical centre is closest.
    function move(key) {
      const pos = locate(selected);
      if (!pos) return;
      const col = columns[pos.c];
      if (key === 'ArrowUp' && pos.r > 0) return select(col[pos.r - 1]);
      if (key === 'ArrowDown' && pos.r < col.length - 1) return select(col[pos.r + 1]);
      if (key !== 'ArrowLeft' && key !== 'ArrowRight') return;
      const step = key === 'ArrowLeft' ? -1 : 1;
      for (let c = pos.c + step; c >= 0 && c < COLS; c += step) {
        if (columns[c].length === 0) continue;
        const y = centreY(selected);
        let best = columns[c][0];
        for (const j of columns[c]) {
          if (Math.abs(centreY(j) - y) < Math.abs(centreY(best) - y)) best = j;
        }
        return select(best);
      }
    }

    function runSearch() {
      clearTimeout(searchTimer);
      const query = searchBox.value.trim();
      if (!query) {
        gifs = [];
        applyFilter(false);
        return;
      }
      searchTimer = setTimeout(() => {
        setStatus('Searching…');
        post({ action: 'search', query: query });
      }, 300);
    }

    function switchTab(tabName) {
      currentTab = tabName;
      document.querySelectorAll('#tabs button').forEach(b => {
        b.classList.toggle('active', b.dataset.tab === tabName);
      });
      clearTimeout(searchTimer);
      gifs = [];
      shown = [];
      results.replaceChildren();
      selected = -1;
      searchBox.placeholder = tabName === 'search' ? 'Search GIFs' : 'Filter ' + tabName;
      searchBox.focus();
      post({ action: 'switchTab', tab: tabName });
      if (tabName === 'search') runSearch();
    }

    document.querySelectorAll('#tabs button').forEach(btn => {
      btn.addEventListener('mousedown', (e) => e.preventDefault()); // keep focus in the input
      btn.addEventListener('click', () => switchTab(btn.dataset.tab));
    });

    searchBox.addEventListener('input', () => {
      if (currentTab === 'search') runSearch();
      else applyFilter(false);
    });

    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') {
        e.preventDefault();
        post({ action: 'close' });
      } else if (e.key === 'Tab') {
        e.preventDefault();
        const i = TABS.indexOf(currentTab);
        switchTab(TABS[(i + (e.shiftKey ? TABS.length - 1 : 1)) % TABS.length]);
      } else if (e.key === 'Enter') {
        e.preventDefault();
        copy(e.metaKey ? 'selectHtml' : 'select');
      } else if (e.metaKey && e.key.toLowerCase() === 'd') {
        e.preventDefault();
        const gif = shown[selected];
        if (gif) post({ action: 'toggleFavorite', gif: gif });
      } else if (e.key.startsWith('Arrow') && !e.metaKey && selected >= 0) {
        e.preventDefault();
        move(e.key);
      }
    });

    window.showResults = function(list) {
      gifs = Array.isArray(list) ? list : [];
      applyFilter(currentTab === 'favorites');
    };

    window.showError = function(message) {
      gifs = [];
      shown = [];
      results.replaceChildren();
      selected = -1;
      setStatus(message, true);
    };

    window.setFavorites = function(urls) {
      favoritesSet = new Set(urls);
      if (currentTab !== 'favorites') render(true); // favorites tab gets a fresh list from Lua
    };

    window.resetUI = function() {
      searchBox.value = '';
      switchTab('search');
    };
