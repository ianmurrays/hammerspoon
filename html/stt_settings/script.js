const nav = document.getElementById('nav');
const text = document.getElementById('text');
const hint = document.getElementById('hint');
const removeBtn = document.getElementById('remove');
let settings = { vocabulary: [], style: '', apps: [] };
let front = null;     // {app, name} the panel was opened over
let selected = 'vocabulary';   // 'vocabulary' | 'style' | a bundle ID
let saveTimer = null;

function post(msg) { window.webkit.messageHandlers.sttSettings.postMessage(msg); }

function save() {
  clearTimeout(saveTimer);
  saveTimer = null;
  post({ action: 'save', settings });
}

function appOf(id) { return settings.apps.find(a => a.app === id); }

function navItem(label, sub, id) {
  const el = document.createElement('div');
  el.className = 'settings-item' + (id === selected ? ' selected' : '');
  el.innerHTML = '<div></div><div class="settings-item-sub"></div>';
  el.firstChild.textContent = label;
  el.lastChild.textContent = sub;
  el.addEventListener('click', () => select(id));
  nav.appendChild(el);
}

function render() {
  nav.innerHTML = '';
  navItem('Vocabulary', 'Terms to spell right', 'vocabulary');
  navItem('Default style', 'Apps without their own', 'style');
  settings.apps.forEach(a => navItem(a.name, a.app, a.app));
  if (front && !appOf(front.app)) {
    const add = document.createElement('div');
    add.className = 'settings-item settings-add';
    add.textContent = '+ Add ' + front.name;
    add.addEventListener('click', () => {
      settings.apps.push({ app: front.app, name: front.name, style: settings.style });
      save();
      select(front.app);
    });
    nav.appendChild(add);
  }
  const app = appOf(selected);
  removeBtn.style.display = app ? '' : 'none';
  if (selected === 'vocabulary') {
    hint.textContent = 'One term per line. The LLM writes words that sound like a term with this spelling.';
    text.value = settings.vocabulary.join('\n');
  } else if (selected === 'style') {
    hint.textContent = 'How to clean up dictation in apps without their own style.';
    text.value = settings.style;
  } else {
    hint.textContent = 'Replaces the default style when dictating into ' + app.name + '.';
    text.value = app.style;
  }
}

function select(id) {
  if (saveTimer) save();
  selected = id;
  render();
  text.focus();
}

window.setSettings = function (data) {
  settings = data.settings;
  // Lua encodes an empty table as {} or [], so normalize the lists
  if (!Array.isArray(settings.vocabulary)) settings.vocabulary = [];
  if (!Array.isArray(settings.apps)) settings.apps = [];
  front = data.front || null;
  if (selected !== 'vocabulary' && selected !== 'style' && !appOf(selected)) selected = 'vocabulary';
  // Open on the current app's style when it has one
  if (front && appOf(front.app)) selected = front.app;
  render();
  text.focus();
};

text.addEventListener('input', () => {
  if (selected === 'vocabulary') {
    settings.vocabulary = text.value.split('\n').map(t => t.trim()).filter(Boolean);
  } else if (selected === 'style') {
    settings.style = text.value;
  } else {
    appOf(selected).style = text.value;
  }
  clearTimeout(saveTimer);
  saveTimer = setTimeout(save, 400);
});

removeBtn.addEventListener('click', () => {
  settings.apps = settings.apps.filter(a => a.app !== selected);
  save();
  select('vocabulary');
});

// The panel hides on blur too, so flush a pending save
window.addEventListener('blur', () => { if (saveTimer) save(); });

document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') {
    e.preventDefault();
    if (saveTimer) save();
    post({ action: 'close' });
  }
});

post({ action: 'ready' });
