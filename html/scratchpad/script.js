    const initialContent = `{{CONTENT}}`;
    const editor = CodeMirror.fromTextArea(document.getElementById('content'), {
      mode: 'markdown',
      lineWrapping: true,
      autofocus: true,
      lineNumbers: false,
      viewportMargin: Infinity,
      extraKeys: { 'Cmd-Enter': cm => toggleTask(cm.getCursor().line) }
    });
    editor.setValue(initialContent);
    editor.clearHistory();

    // Expose getValue for Lua callbacks
    window.getEditorValue = () => editor.getValue();

    const statusEl = document.getElementById('status');
    const statusText = document.getElementById('statusText');
    const wordsEl = document.getElementById('words');

    // Lua calls setStatus('saved') after the encrypted write
    window.setStatus = function(state) {
      const saved = state === 'saved';
      statusEl.classList.toggle('edited', !saved);
      statusText.textContent = saved ? 'Saved · Encrypted · iCloud' : 'Edited';
    };

    // "- [ ] task" / "* [x] task"; group 1 is the list marker, the box starts right after it
    const TASK_RE = /^(\s*[-*+]\s+)\[( |x|X)\]/;
    let taskMarks = [];

    // Task line: flip [ ] / [x]. List item: add a box after the marker. Other line: make it "- [ ] ".
    function toggleTask(line) {
      const text = editor.getLine(line);
      const m = text.match(TASK_RE);
      if (!m) {
        const list = text.match(/^(\s*[-*+]\s+)/);
        const at = list ? list[1].length : text.match(/^\s*/)[0].length;
        editor.replaceRange(list ? '[ ] ' : '- [ ] ', { line, ch: at });
        return;
      }
      const ch = m[1].length + 1;
      editor.replaceRange(m[2] === ' ' ? 'x' : ' ', { line, ch }, { line, ch: ch + 1 });
    }

    function renderTasks() {
      taskMarks.forEach(mk => mk.clear());
      taskMarks = [];
      editor.operation(() => {
        editor.eachLine(handle => {
          const line = editor.getLineNumber(handle);
          const m = handle.text.match(TASK_RE);
          editor.removeLineClass(handle, 'text', 'task-done');
          if (!m) return;
          const done = m[2] !== ' ';
          if (done) editor.addLineClass(handle, 'text', 'task-done');
          const box = document.createElement('span');
          box.className = 'task-box' + (done ? ' done' : '');
          box.textContent = done ? '✓' : '';
          box.addEventListener('mousedown', e => {
            e.preventDefault();
            toggleTask(editor.getLineNumber(handle));
          });
          const from = m[1].length;
          taskMarks.push(editor.markText({ line, ch: from }, { line, ch: from + 3 }, { replacedWith: box }));
        });
      });
    }

    function countWords() {
      const n = editor.getValue().split(/\s+/).filter(Boolean).length;
      wordsEl.textContent = n + (n === 1 ? ' word' : ' words');
    }

    renderTasks();
    countWords();
    editor.on('changes', () => {
      renderTasks();
      countWords();
      setStatus('edited');
    });

    function save(andClose) {
      window.webkit.messageHandlers.scratchpad.postMessage({
        action: andClose ? 'save_and_close' : 'save',
        content: editor.getValue()
      });
    }

    // Escape to save and close, Cmd+S to save (blur is handled by Lua, which saves and hides)
    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') {
        e.preventDefault();
        save(true);
      }
      if ((e.metaKey || e.ctrlKey) && e.key === 's') {
        e.preventDefault();
        save(false);
      }
    });
