// Homepage motion and the live GitHub star count.
(() => {
  const reveals = document.querySelectorAll('.reveal');
  const seen = new IntersectionObserver(entries => {
    for (const entry of entries) if (entry.isIntersecting) { entry.target.classList.add('in'); seen.unobserve(entry.target); }
  }, { rootMargin: '0px 0px -10% 0px' });
  reveals.forEach(node => seen.observe(node));

  // Tagline: wrap each word, then light them in reading order as the block crosses a line 60% down the viewport.
  const tagline = document.getElementById('tagline');
  if (tagline) {
    for (const text of [...tagline.childNodes].filter(node => node.nodeType === Node.TEXT_NODE)) {
      const words = document.createDocumentFragment();
      text.textContent.split(/(\s+)/).forEach(part => {
        if (!part.trim()) { words.append(part); return; }
        const word = document.createElement('span');
        word.className = 'word';
        word.textContent = part;
        words.append(word);
      });
      text.replaceWith(words);
    }
    const words = [...tagline.querySelectorAll('.word')];
    let queued = false;
    const update = () => {
      queued = false;
      const box = tagline.getBoundingClientRect();
      const progress = Math.min(1, Math.max(0, (innerHeight * 0.6 - box.top) / box.height));
      const lit = Math.round(progress * words.length);
      words.forEach((word, i) => word.classList.toggle('lit', i < lit));
    };
    addEventListener('scroll', () => { if (!queued) { queued = true; requestAnimationFrame(update); } }, { passive: true });
    update();
  }

  // Hero painting tilts toward the pointer.
  const visual = document.querySelector('.hero-visual');
  if (visual && matchMedia('(pointer: fine) and (prefers-reduced-motion: no-preference)').matches) {
    visual.addEventListener('pointermove', event => {
      const box = visual.getBoundingClientRect();
      visual.style.setProperty('--ry', `${((event.clientX - box.left) / box.width - 0.5) * 4}deg`);
      visual.style.setProperty('--rx', `${((event.clientY - box.top) / box.height - 0.5) * -4}deg`);
    });
    visual.addEventListener('pointerleave', () => { visual.style.removeProperty('--rx'); visual.style.removeProperty('--ry'); });
  }

  // After a download starts, show what to do next instead of leaving the visitor on the same page.
  const next = document.getElementById('next-steps');
  if (next) {
    const close = () => { next.classList.remove('in'); setTimeout(() => { next.hidden = true; }, 500); };
    document.querySelectorAll('a[download]').forEach(link => link.addEventListener('click', () => {
      next.hidden = false;
      requestAnimationFrame(() => requestAnimationFrame(() => next.classList.add('in')));
    }));
    next.querySelector('.next-close').addEventListener('click', close);
    addEventListener('keydown', event => { if (event.key === 'Escape' && !next.hidden) close(); });
  }

  const stars = document.getElementById('star-count');
  if (stars) {
    fetch('https://api.github.com/repos/devjasha/Zurafa')
      .then(response => response.ok ? response.json() : Promise.reject())
      .then(repo => { if (Number.isFinite(repo.stargazers_count)) stars.textContent = `${repo.stargazers_count.toLocaleString('en-US')} ${repo.stargazers_count === 1 ? 'star' : 'stars'}`; })
      .catch(() => {}); // Keep "Star on GitHub" when the API is rate limited or offline.
  }
})();

// Product window: replay a short scripted session while it is on screen.
(() => {
  const mock = document.getElementById('mock');
  if (!mock) return;
  const agent = mock.querySelector('[data-agent]'), tests = mock.querySelector('[data-tests]');
  const timer = mock.querySelector('[data-timer]');
  const tabs = [...mock.querySelectorAll('.mock-tab s')];
  const counts = () => {
    for (const state of ['blocked', 'working', 'done']) {
      mock.querySelector(`[data-count=${state}]`).textContent = tabs.filter(s => s.dataset.state === state).length;
    }
    mock.querySelector('.needs').classList.toggle('on', agent.dataset.state === 'blocked');
  };
  const at = (selector, attr, apply) => mock.querySelectorAll(selector).forEach(node => apply(node, Number(node.getAttribute(attr))));
  const final = () => {
    at('[data-at]', 'data-at', node => node.classList.add('on'));
    at('[data-done-at]', 'data-done-at', node => node.classList.add('done'));
    at('[data-hide-at]', 'data-hide-at', node => node.classList.add('off'));
    agent.dataset.state = 'blocked'; tests.dataset.state = 'done'; mock.classList.add('go'); counts();
  };
  if (matchMedia('(prefers-reduced-motion: reduce)').matches) { final(); return; }

  let pending = [];
  const later = (ms, fn) => pending.push(setTimeout(fn, ms));
  const stop = () => { pending.forEach(clearTimeout); pending = []; };
  const play = () => {
    stop();
    mock.querySelectorAll('.on, .done, .off').forEach(node => node.classList.remove('on', 'done', 'off'));
    mock.classList.remove('go');
    agent.dataset.state = 'working'; tests.dataset.state = 'working'; counts();
    requestAnimationFrame(() => requestAnimationFrame(() => mock.classList.add('go')));
    at('[data-at]', 'data-at', (node, ms) => later(ms, () => node.classList.add('on')));
    at('[data-done-at]', 'data-done-at', (node, ms) => later(ms, () => node.classList.add('done')));
    at('[data-hide-at]', 'data-hide-at', (node, ms) => later(ms, () => node.classList.add('off')));
    for (let s = 0; s * 1000 < 5200; s++) later(s * 1000, () => { timer.textContent = `${s}s`; });
    later(4700, () => { tests.dataset.state = 'done'; counts(); });
    later(5200, () => { agent.dataset.state = 'blocked'; counts(); });
    later(10000, play);
  };
  new IntersectionObserver(([entry]) => entry.isIntersecting ? play() : stop(), { threshold: 0.3 }).observe(mock);
})();

// How it works: each step sets the agents' states and reveals what happened so far.
(() => {
  const flow = document.querySelector('[data-flow]');
  if (!flow) return;
  const win = flow.querySelector('.flow-window');
  const buttons = [...flow.querySelectorAll('[data-step]')].filter(b => b !== win);
  const states = [
    { lead: 'working' },
    { lead: 'working', build: 'working', tests: 'working' },
    { lead: 'working', build: 'working', tests: 'blocked' },
    { lead: 'done', build: 'done', tests: 'done' }
  ];
  const show = step => {
    win.dataset.step = step;
    buttons.forEach((b, i) => b.setAttribute('aria-pressed', String(i === step)));
    flow.querySelectorAll('[data-agent]').forEach(node => {
      node.dataset.state = states[step][node.dataset.agent] || '';
      if (node.tagName === 'EM') node.textContent = node.dataset.state.replace(/^./, c => c.toUpperCase());
    });
    const team = [states[step].build, states[step].tests];
    win.querySelector('[data-done]').textContent = `${team.filter(s => s === 'done').length}/2 done`;
    flow.querySelectorAll('[data-from], [data-until]').forEach(node => {
      const visible = step >= Number(node.dataset.from || 0) && step < Number(node.dataset.until || Infinity);
      const appearing = visible && node.classList.contains('off');
      node.classList.toggle('off', !visible);
      if (appearing) { node.classList.add('enter'); requestAnimationFrame(() => requestAnimationFrame(() => node.classList.remove('enter'))); }
    });
    for (const state of ['blocked', 'working', 'done']) {
      win.querySelector(`[data-count=${state}]`).textContent = Object.values(states[step]).filter(s => s === state).length;
    }
  };
  buttons.forEach((b, i) => b.addEventListener('click', () => show(i)));
  show(0);
})();
