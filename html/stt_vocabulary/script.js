const terms = document.getElementById('terms');
let saveTimer = null;

function post(msg) { window.webkit.messageHandlers.sttVocabulary.postMessage(msg); }

function save() {
  clearTimeout(saveTimer);
  saveTimer = null;
  post({ action: 'save', text: terms.value });
}

window.setText = function (text) {
  terms.value = text;
  terms.focus();
  terms.setSelectionRange(text.length, text.length);
};

terms.addEventListener('input', () => {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(save, 400);
});

document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') {
    e.preventDefault();
    if (saveTimer) save();
    post({ action: 'close' });
  }
});
