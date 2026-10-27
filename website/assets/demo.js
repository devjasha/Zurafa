// The homepage's simulated Zurafa window: a tiny shell whose commands each show one feature.
(() => {
  const $ = id => document.getElementById(id);
  const term = $('demo-term');
  if (!term) return;
  const out = $('demo-out'), input = $('demo-input'), promptEl = $('demo-prompt'), tabs = $('demo-tabs');
  const body = term.closest('.demo-body'), demo = term.closest('.demo'), preview = $('demo-preview');

  const LOCAL = { workspace: 'Local', host: 'this Mac', tab: 'fish', title: '~' };
  const KALI = { workspace: 'Hacking', host: '192.168.64.2', tab: 'yareliu@kali-linux-vm-1', title: 'yareliu@kali-linux-vm-1: ~', kali: true };
  const THEMES = {
    zurafa: ['#17132e', '#e4def9', '#8a82b3', '#c3a1ff', '#7fd6a0', '#ffc46b'],
    dracula: ['#282a36', '#f8f8f2', '#6272a4', '#ff79c6', '#50fa7b', '#f1fa8c'],
    'catppuccin-mocha': ['#1e1e2e', '#cdd6f4', '#7f849c', '#cba6f7', '#a6e3a1', '#f9e2af'],
    'catppuccin-latte': ['#eff1f5', '#4c4f69', '#8c8fa1', '#8839ef', '#40a02b', '#df8e1d'],
    'gruvbox-dark': ['#282828', '#ebdbb2', '#928374', '#fabd2f', '#b8bb26', '#fe8019'],
  };
  const FILES = ['README.md', 'euler.html', 'kali-vm.png'];
  let where = LOCAL, status = null, busy = false;
  const history = []; let back = 0;

  const el = (tag, cls, text) => {
    const node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text != null) node.textContent = text;
    return node;
  };
  const scroll = () => { term.scrollTop = term.scrollHeight; };
  // print('plain', ['t-dim', 'styled'], ...) appends one line; text is never parsed as HTML.
  const print = (...parts) => {
    const row = el('div', 't-line');
    for (const part of parts) row.append(typeof part === 'string' ? part : el('span', part[0], part[1]));
    out.append(row); scroll();
  };
  const note = text => print(['t-dim', '# ' + text]);
  const wait = ms => new Promise(resolve => setTimeout(resolve, ms));

  const promptParts = () => where.kali
    ? [el('span', 'p-top'), el('span', 'k-g', '└─'), el('span', 'k-b', '$ ')].map((node, i) => {
        if (i === 0) node.append(el('span', 'k-g', '┌──('), el('span', 'k-b', 'yareliu㉿kali-linux-vm-1'), el('span', 'k-g', ')-['), '~', el('span', 'k-g', ']'));
        return node;
      })
    : [el('span', 't-acc', '~ '), el('span', 't-ok', '❯ ')];

  const render = () => {
    const ws = el('span', 'demo-ws', where.workspace);
    ws.append(el('small', null, where.host));
    const tab = el('span', 'demo-tab');
    if (status) tab.append(el('span', 'dot ' + status));
    tab.append(where.tab);
    tabs.replaceChildren(ws, tab);
    $('demo-title').textContent = where.title;
    promptEl.replaceChildren(...promptParts());
  };

  const openPreview = (name, node) => {
    $('preview-title').textContent = name;
    $('preview-body').replaceChildren(node);
    preview.hidden = false; body.classList.add('split');
  };
  const closePreview = () => { preview.hidden = true; body.classList.remove('split'); };
  const image = (src, alt) => {
    const link = Object.assign(el('a'), { href: src, target: '_blank', rel: 'noopener', title: 'Open full size' });
    link.append(Object.assign(el('img'), { src, alt, width: 2000, height: 1230 }));
    return link;
  };

  const previews = {
    'README.md': () => {
      const doc = el('div');
      const h = el('h4', null, 'Zurafa');
      h.append(el('span', 'git-badge', 'M'));
      doc.append(h, el('p', null, 'Rendered Markdown, syntax-highlighted code, images, Org files, and LaTeX math open beside your panes.'),
        el('p', null, '⌘-click any path in terminal output, even a bare README.md, to get here. The badge shows the file\'s git status.'),
        el('code', null, 'zurafa preview <file>'));
      return doc;
    },
    'euler.html': () => image('/assets/zurafa-interactive-preview.png', 'A coding agent explaining Neural ODEs beside an interactive Euler-step explorer in the Zurafa preview.'),
    'kali-vm.png': () => image('/assets/zurafa-local-vm.png', 'A Zurafa tab connected to a Kali Linux VM running in UTM, showing nc help output.'),
  };

  const commands = {
    help() {
      print('Commands in this demo:');
      for (const [name, text] of [
        ['ssh kali', 'connect to a local Kali VM'], ['zurafa preview <file>', 'open README.md, euler.html or kali-vm.png beside the pane'],
        ['claude', 'run a coding agent and watch the tab status'], ['theme [name]', 'switch to another Ghostty theme'],
        ['cat ~/.config/config.zurafa', 'the whole config, in one plain file'], ['zurafa ls', 'drive Zurafa from scripts'],
        ['ls', 'list files'], ['clear', 'clear the screen'], ['exit', 'leave a remote session'],
      ]) print('  ', ['t-cmd', name.padEnd(30)], ['t-dim', text]);
    },
    async ssh([target = '']) {
      if (where.kali) return print('Already on kali-linux-vm-1. Type ', ['t-cmd', 'exit'], ' to go back.');
      if (!/^(yareliu@)?kali(-linux-vm-1)?$/.test(target)) {
        print(`ssh: Could not resolve hostname ${target || '(none)'}`);
        return note('try: ssh kali');
      }
      note('⌘K → Add Remote Host lists VMs on this Mac\'s shared network (UTM, Tart, Apple Virtualization)');
      print('  ', ['t-acc', '▣ kali-linux-vm-1'], '   192.168.64.2   ', ['t-dim', 'UTM']);
      await wait(500);
      print(['t-dim', 'Connecting with your system SSH client and keys…']);
      await wait(600);
      print(['t-dim', 'Starting the Zurafa daemon in ~/.zurafa/ '], ['t-ok', 'done']);
      note('the shell lives on the VM, so it survives dropped connections and a sleeping Mac');
      where = KALI; render();
      openPreview('kali-vm.png', previews['kali-vm.png']());
    },
    exit() {
      if (!where.kali) return note('this is the last tab, so the demo keeps it open');
      print('Connection to kali-linux-vm-1 closed.');
      where = LOCAL; render(); closePreview();
    },
    async claude() {
      status = 'amber'; render();
      print(['t-acc', '✻ Claude Code'], ['t-dim', '  (any agent works: Codex, Pi, …)']);
      for (const step of ['Reading src/parser.rs', 'Running cargo test', 'Fixing 2 failing tests']) {
        await wait(650);
        print(['t-warn', '● '], step);
      }
      await wait(600);
      status = 'green'; render();
      print(['t-ok', '✓ '], 'All tests pass.');
      note('the tab shows the agent\'s icon and status: amber while working, green when done, pink when blocked');
      note('paste a screenshot and Zurafa hands the agent its file path');
    },
    theme([name]) {
      if (!name || !THEMES[name]) {
        print('Themes: ', ...Object.keys(THEMES).flatMap(t => [['t-cmd', t], '  ']));
        return note('Zurafa uses any Ghostty theme, or imports your Ghostty colors and fonts');
      }
      ['--t-bg', '--t-fg', '--t-dim', '--t-acc', '--t-ok', '--t-warn'].forEach((v, i) => demo.style.setProperty(v, THEMES[name][i]));
      print('theme = ', ['t-acc', name]);
      note('the whole app follows the theme, down to the command palette');
    },
    cat([file]) {
      if (file === '~/.config/config.zurafa') {
        for (const line of ['theme = light:Catppuccin Latte,dark:Catppuccin Mocha', 'accent-color = #3a69cc', 'window-opacity = 0.9', 'pane-gap = 8', 'pane-corner-radius = 14', 'sidebar-width = 194']) {
          const [key, value] = line.split(' = ');
          print(['t-acc', key], ' = ', value);
        }
        return note('press ⌘, to edit it; changes apply when you save');
      }
      if (file === 'README.md') return print('# Zurafa\nA calm macOS terminal workspace.');
      print(`cat: ${file || ''}: No such file or directory`);
    },
    async zurafa([sub, file]) {
      if (sub === 'ls') {
        print(['t-dim', 'SESSION   TABS  HOST']);
        print('default   3     local');
        print('Hacking   1     yareliu@192.168.64.2');
        return note('every session, tab, and pane can be listed and controlled from scripts; add --json for machines');
      }
      if (sub === 'preview') {
        if (!previews[file]) return print(`zurafa: no such file: ${file || '(none)'}`, ['t-dim', `  (try ${FILES.join(', ')})`]);
        openPreview(file, previews[file]());
        return note(file === 'euler.html'
          ? 'agents open live pages here; click a button and its question lands in the prompt, ready to send'
          : '⌘-click a path in terminal output does the same');
      }
      print('usage: zurafa ls | zurafa preview <file>');
    },
    ls() { print(where.kali ? 'Desktop  Documents  Downloads  tools' : FILES.join('  ')); },
    clear() { out.replaceChildren(); },
  };
  commands.open = ([file]) => commands.zurafa(['preview', file]);

  const run = async line => {
    const cmd = line.trim();
    input.value = '';
    const echo = el('div', 't-line');
    echo.append(...promptParts(), cmd);
    out.append(echo);
    if (cmd) { history.push(cmd); back = history.length; }
    const [name, ...args] = cmd.split(/\s+/);
    busy = true; input.readOnly = true;
    try {
      if (!cmd) { /* blank line, like a real shell */ }
      else if (commands[name]) await commands[name](args);
      else print(where.kali ? `zsh: command not found: ${name}` : `fish: Unknown command: ${name}`);
    } finally {
      busy = false; input.readOnly = false; scroll();
    }
  };

  input.addEventListener('keydown', event => {
    if (busy) return;
    if (event.key === 'Enter') run(input.value);
    else if (event.key === 'ArrowUp' || event.key === 'ArrowDown') {
      event.preventDefault();
      back = Math.max(0, Math.min(history.length, back + (event.key === 'ArrowUp' ? -1 : 1)));
      input.value = history[back] ?? '';
    } else if (event.key === 'Tab' && input.value) {
      const match = Object.keys(commands).find(name => name.startsWith(input.value));
      if (match) { event.preventDefault(); input.value = match + ' '; }
    } else if (event.key === 'l' && event.ctrlKey) { event.preventDefault(); commands.clear(); }
  });
  term.addEventListener('click', () => { if (!getSelection().toString()) input.focus({ preventScroll: true }); });
  $('preview-close').addEventListener('click', closePreview);

  document.querySelectorAll('.demo-suggest button').forEach(button => button.addEventListener('click', async () => {
    if (busy) return;
    busy = true;
    input.value = '';
    for (const char of button.dataset.cmd) { input.value += char; await wait(28); }
    busy = false;
    input.focus({ preventScroll: true });
    await run(input.value);
  }));

  render();
  print(['t-acc', 'Welcome to Zurafa.'], ' This window is a simulation; the screenshots are the real app.');
  print('Type ', ['t-cmd', 'help'], ' or pick a command below.');
})();
