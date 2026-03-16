  var selectedEmoji = ':speech_balloon:';

  document.getElementById('emojiGrid').addEventListener('click', function(e) {
    var btn = e.target.closest('.emoji-btn');
    if (!btn) return;
    document.querySelectorAll('.emoji-btn').forEach(function(b) { b.classList.remove('selected'); });
    btn.classList.add('selected');
    selectedEmoji = btn.getAttribute('data-code');
    document.getElementById('customCode').value = '';
  });

  document.getElementById('customCode').addEventListener('input', function() {
    if (this.value.trim()) {
      document.querySelectorAll('.emoji-btn').forEach(function(b) { b.classList.remove('selected'); });
    }
  });

  function doSubmit() {
    var custom = document.getElementById('customCode').value.trim();
    var emoji = custom || selectedEmoji;
    var text = document.getElementById('statusText').value.trim();
    var exp = document.getElementById('expiration').value;
    window.webkit.messageHandlers.customStatus.postMessage({
      action: 'submit', emoji: emoji, text: text, expiration: exp
    });
  }
  function doCancel() {
    window.webkit.messageHandlers.customStatus.postMessage({ action: 'cancel' });
  }
  document.addEventListener('keydown', function(e) {
    if (e.key === 'Escape') { doCancel(); }
    if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') { doSubmit(); }
  });