    const filterBox = document.getElementById('filter-box');
    const statusEl = document.getElementById('status');
    const entriesEl = document.getElementById('entries');
    let allEntries = [];

    function formatTimestamp(isoStr) {
      const d = new Date(isoStr);
      return d.toLocaleString(undefined, {
        month: 'short', day: 'numeric',
        hour: '2-digit', minute: '2-digit'
      });
    }

    function renderEntries(filter) {
      while (entriesEl.firstChild) entriesEl.removeChild(entriesEl.firstChild);

      const needle = (filter || '').toLowerCase();
      const filtered = needle
        ? allEntries.filter(e =>
            e.text.toLowerCase().includes(needle) ||
            (e.app && e.app.toLowerCase().includes(needle)))
        : allEntries;

      if (filtered.length === 0) {
        statusEl.textContent = needle ? 'No matching entries' : 'No entries yet';
        return;
      }
      statusEl.textContent = '';

      filtered.forEach(entry => {
        const card = document.createElement('div');
        card.className = 'entry-card';

        // Header: timestamp + app name
        const header = document.createElement('div');
        header.className = 'entry-header';

        const ts = document.createElement('span');
        ts.className = 'timestamp';
        ts.textContent = formatTimestamp(entry.timestamp);
        header.appendChild(ts);

        if (entry.app) {
          const appEl = document.createElement('span');
          appEl.className = 'app-name';
          appEl.textContent = entry.app;
          header.appendChild(appEl);
        }

        card.appendChild(header);

        // Body: text + actions
        const body = document.createElement('div');
        body.className = 'entry-body';

        const textEl = document.createElement('div');
        textEl.className = 'text';
        textEl.textContent = entry.text;
        body.appendChild(textEl);

        const actions = document.createElement('div');
        actions.className = 'entry-actions';

        const copyBtn = document.createElement('button');
        copyBtn.className = 'copy-btn';
        copyBtn.textContent = 'Copy';
        copyBtn.addEventListener('click', (e) => {
          e.stopPropagation();
          copyText(copyBtn, entry.text);
        });
        actions.appendChild(copyBtn);

        const deleteBtn = document.createElement('button');
        deleteBtn.className = 'delete-btn';
        deleteBtn.textContent = '\u00d7';
        deleteBtn.title = 'Delete';
        deleteBtn.addEventListener('click', (e) => {
          e.stopPropagation();
          window.webkit.messageHandlers.clipboardHistory.postMessage({
            action: 'delete',
            id: entry.id
          });
        });
        actions.appendChild(deleteBtn);

        body.appendChild(actions);
        card.appendChild(body);

        // Click card to copy
        card.addEventListener('click', () => copyText(copyBtn, entry.text));

        entriesEl.appendChild(card);
      });
    }

    function copyText(btn, text) {
      window.webkit.messageHandlers.clipboardHistory.postMessage({
        action: 'copy',
        text: text
      });
      btn.textContent = 'Copied!';
      btn.classList.add('copied');
      setTimeout(() => {
        btn.textContent = 'Copy';
        btn.classList.remove('copied');
      }, 1500);
    }

    filterBox.addEventListener('input', () => {
      renderEntries(filterBox.value);
    });

    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') {
        e.preventDefault();
        window.webkit.messageHandlers.clipboardHistory.postMessage({ action: 'close' });
      }
    });

    window.loadEntries = function(jsonStr) {
      try {
        allEntries = JSON.parse(jsonStr);
      } catch (e) {
        console.error('clipboard_history: failed to parse entries:', e);
        allEntries = [];
      }
      renderEntries(filterBox.value);
    };

    window.resetUI = function() {
      filterBox.value = '';
      renderEntries('');
      filterBox.focus();
    };

    // Signal Lua that JS is ready to receive data
    window.webkit.messageHandlers.clipboardHistory.postMessage({ action: 'ready' });
