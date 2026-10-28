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

  const stars = document.getElementById('star-count');
  if (stars) {
    fetch('https://api.github.com/repos/devjasha/Zurafa')
      .then(response => response.ok ? response.json() : Promise.reject())
      .then(repo => { if (Number.isFinite(repo.stargazers_count)) stars.textContent = repo.stargazers_count.toLocaleString('en-US'); })
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
