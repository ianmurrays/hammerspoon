    const searchBox = document.getElementById('search-box');
    const status = document.getElementById('status');
    const results = document.getElementById('results');
    const COLS = 3;
    let selectedIndex = -1;
    let currentTab = 'search';
    let favoritesSet = new Set();

    function getItems() {
      return results.querySelectorAll('.gif-item');
    }

    function updateSelection() {
      getItems().forEach((el, i) => {
        el.classList.toggle('selected', i === selectedIndex);
      });
      const items = getItems();
      if (selectedIndex >= 0 && items[selectedIndex]) {
        items[selectedIndex].scrollIntoView({ block: 'nearest' });
      }
    }

    function clearGrid() {
      while (results.firstChild) results.removeChild(results.firstChild);
      selectedIndex = -1;
    }

    function clearSelection() {
      selectedIndex = -1;
      updateSelection();
    }

    function selectGif(url, thumb) {
      window.webkit.messageHandlers.gifFinder.postMessage({
        action: 'select',
        url: url,
        thumb: thumb
      });
    }

    function renderGrid(gifs) {
      clearGrid();

      if (gifs.length === 0) {
        status.className = '';
        if (currentTab === 'search') {
          status.textContent = 'No results found';
        } else if (currentTab === 'favorites') {
          status.textContent = 'No favorites yet \u2014 star GIFs from search results';
        } else {
          status.textContent = 'No recent GIFs';
        }
        return;
      }

      status.textContent = '';

      gifs.forEach((gif) => {
        const item = document.createElement('div');
        item.className = 'gif-item';
        item.dataset.url = gif.url;
        item.dataset.thumb = gif.thumb;

        const star = document.createElement('button');
        const isFav = favoritesSet.has(gif.url);
        star.className = 'star-btn' + (isFav ? ' favorited' : '');
        star.textContent = isFav ? '\u2605' : '\u2606';
        star.addEventListener('click', (e) => {
          e.stopPropagation();
          window.webkit.messageHandlers.gifFinder.postMessage({
            action: 'toggleFavorite',
            thumb: gif.thumb,
            url: gif.url
          });
        });
        item.appendChild(star);

        const htmlBtn = document.createElement('button');
        htmlBtn.className = 'copy-html-btn';
        htmlBtn.textContent = '<>';
        htmlBtn.addEventListener('click', (e) => {
          e.stopPropagation();
          window.webkit.messageHandlers.gifFinder.postMessage({
            action: 'selectHtml',
            thumb: gif.thumb,
            url: gif.url
          });
        });
        item.appendChild(htmlBtn);

        const img = document.createElement('img');
        img.src = gif.thumb;
        img.loading = 'lazy';
        item.appendChild(img);
        item.addEventListener('click', () => selectGif(gif.url, gif.thumb));
        results.appendChild(item);
      });
    }

    function switchTab(tabName) {
      currentTab = tabName;
      document.querySelectorAll('#tabs button').forEach(b => {
        b.classList.toggle('active', b.dataset.tab === tabName);
      });

      clearGrid();

      if (tabName === 'search') {
        searchBox.style.display = '';
        status.className = '';
        status.textContent = 'Type a search term and press Enter';
        searchBox.focus();
      } else {
        searchBox.style.display = 'none';
        status.className = '';
        status.textContent = '';
      }

      window.webkit.messageHandlers.gifFinder.postMessage({
        action: 'switchTab',
        tab: tabName
      });
    }

    document.querySelectorAll('#tabs button').forEach(btn => {
      btn.addEventListener('click', () => switchTab(btn.dataset.tab));
    });

    document.addEventListener('keydown', (e) => {
      const items = getItems();
      const inGrid = selectedIndex >= 0;

      if (inGrid) {
        if (e.key === 'ArrowDown') {
          e.preventDefault();
          const next = selectedIndex + COLS;
          if (next < items.length) selectedIndex = next;
          updateSelection();
        } else if (e.key === 'ArrowUp') {
          e.preventDefault();
          const next = selectedIndex - COLS;
          if (next < 0) {
            clearSelection();
            if (currentTab === 'search') {
              searchBox.focus();
            }
          } else {
            selectedIndex = next;
            updateSelection();
          }
        } else if (e.key === 'ArrowLeft') {
          e.preventDefault();
          if (selectedIndex > 0) {
            selectedIndex--;
            updateSelection();
          }
        } else if (e.key === 'ArrowRight') {
          e.preventDefault();
          if (selectedIndex < items.length - 1) {
            selectedIndex++;
            updateSelection();
          }
        } else if (e.key === 'Enter') {
          e.preventDefault();
          const item = items[selectedIndex];
          const url = item?.dataset.url;
          const thumb = item?.dataset.thumb;
          if (url) selectGif(url, thumb);
        } else if (e.key === 'Escape') {
          e.preventDefault();
          clearSelection();
          if (currentTab === 'search') {
            searchBox.focus();
          }
        } else if (e.key.length === 1 && currentTab === 'search') {
          clearSelection();
          searchBox.focus();
        }
        return;
      }

      // Search box mode
      if (document.activeElement === searchBox) {
        if (e.key === 'Enter') {
          e.preventDefault();
          const query = searchBox.value.trim();
          if (query) {
            status.className = '';
            status.textContent = 'Searching...';
            clearGrid();
            window.webkit.messageHandlers.gifFinder.postMessage({
              action: 'search',
              query: query
            });
          }
        } else if (e.key === 'Escape') {
          e.preventDefault();
          window.webkit.messageHandlers.gifFinder.postMessage({ action: 'close' });
        } else if ((e.key === 'ArrowDown' || e.key === 'Tab') && items.length > 0) {
          e.preventDefault();
          selectedIndex = 0;
          updateSelection();
          searchBox.blur();
        }
      }

      // Non-search tab, not in grid
      if (currentTab !== 'search' && !inGrid) {
        if ((e.key === 'ArrowDown' || e.key === 'Tab') && items.length > 0) {
          e.preventDefault();
          selectedIndex = 0;
          updateSelection();
        } else if (e.key === 'Escape') {
          e.preventDefault();
          window.webkit.messageHandlers.gifFinder.postMessage({ action: 'close' });
        }
      }
    });

    window.showResults = function(jsonStr) {
      const gifs = JSON.parse(jsonStr);
      renderGrid(gifs);
    };

    window.showError = function(message) {
      status.className = 'error';
      status.textContent = message;
      clearGrid();
    };

    window.setFavorites = function(jsonStr) {
      const urls = JSON.parse(jsonStr);
      favoritesSet = new Set(urls);
      document.querySelectorAll('.gif-item').forEach(item => {
        const star = item.querySelector('.star-btn');
        if (star) {
          const isFav = favoritesSet.has(item.dataset.url);
          star.className = 'star-btn' + (isFav ? ' favorited' : '');
          star.textContent = isFav ? '\u2605' : '\u2606';
        }
      });
    };

    window.resetUI = function() {
      searchBox.value = '';
      searchBox.style.display = '';
      clearGrid();
      currentTab = 'search';
      document.querySelectorAll('#tabs button').forEach(b => {
        b.classList.toggle('active', b.dataset.tab === 'search');
      });
      status.className = '';
      status.textContent = 'Type a search term and press Enter';
      searchBox.focus();
    };