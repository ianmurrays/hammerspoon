    const initialContent = `{{CONTENT}}`;
    const editor = CodeMirror.fromTextArea(document.getElementById('content'), {
      mode: 'markdown',
      theme: 'material-darker',
      lineWrapping: true,
      autofocus: true,
      lineNumbers: false,
      viewportMargin: Infinity
    });
    editor.setValue(initialContent);

    // Expose getValue for Lua callbacks
    window.getEditorValue = () => editor.getValue();

    function save(andClose) {
      window.webkit.messageHandlers.scratchpad.postMessage({
        action: andClose ? 'save_and_close' : 'save',
        content: editor.getValue()
      });
    }

    // Save on blur
    editor.on('blur', () => save(false));

    // Escape to save and close, Cmd+S to save
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