    const filterBox = document.getElementById('filter-box');
    const statusEl = document.getElementById('status');
    const entriesEl = document.getElementById('entries');
    let allEntries = [];

    function renderEntries(filter) {
      while (entriesEl.firstChild) entriesEl.removeChild(entriesEl.firstChild);

      const needle = (filter || '').toLowerCase();
      const filtered = needle
        ? allEntries.filter(e =>
            (e.raw && e.raw.toLowerCase().includes(needle)) ||
            (e.llm && e.llm.toLowerCase().includes(needle)))
        : allEntries;

      if (filtered.length === 0) {
        statusEl.textContent = needle ? 'No matching entries' : 'No entries yet';
        return;
      }
      statusEl.textContent = '';

      filtered.forEach(entry => {
        const card = document.createElement('div');
        card.className = 'entry-card';

        const ts = document.createElement('div');
        ts.className = 'timestamp';
        ts.textContent = entry.timestamp;
        card.appendChild(ts);

        // RAW text block
        const rawBlock = document.createElement('div');
        rawBlock.className = 'text-block';

        const rawLabel = document.createElement('div');
        rawLabel.className = 'label raw';
        rawLabel.textContent = 'RAW';
        rawBlock.appendChild(rawLabel);

        const rawText = document.createElement('div');
        rawText.className = 'text';
        rawText.textContent = entry.raw;
        rawBlock.appendChild(rawText);

        const rawCopy = document.createElement('button');
        rawCopy.className = 'copy-btn';
        rawCopy.textContent = 'Copy';
        rawCopy.addEventListener('click', () => copyText(rawCopy, entry.raw));
        rawBlock.appendChild(rawCopy);

        card.appendChild(rawBlock);

        // LLM text block (only if different from raw)
        if (entry.llm && entry.llm !== entry.raw) {
          const llmBlock = document.createElement('div');
          llmBlock.className = 'text-block';

          const llmLabel = document.createElement('div');
          llmLabel.className = 'label llm';
          llmLabel.textContent = 'LLM';
          llmBlock.appendChild(llmLabel);

          const llmText = document.createElement('div');
          llmText.className = 'text llm';
          llmText.textContent = entry.llm;
          llmBlock.appendChild(llmText);

          const llmCopy = document.createElement('button');
          llmCopy.className = 'copy-btn';
          llmCopy.textContent = 'Copy';
          llmCopy.addEventListener('click', () => copyText(llmCopy, entry.llm));
          llmBlock.appendChild(llmCopy);

          card.appendChild(llmBlock);
        }

        entriesEl.appendChild(card);
      });
    }

    function copyText(btn, text) {
      window.webkit.messageHandlers.sttHistory.postMessage({
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
        window.webkit.messageHandlers.sttHistory.postMessage({ action: 'close' });
      }
    });

    window.loadEntries = function(jsonStr) {
      allEntries = JSON.parse(jsonStr);
      renderEntries(filterBox.value);
    };

    window.resetUI = function() {
      filterBox.value = '';
      renderEntries('');
      filterBox.focus();
    };