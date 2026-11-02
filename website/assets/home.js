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

// Cursor reactive surfaces: lean toward the pointer and move a soft light under it.
(() => {
  if (!matchMedia('(pointer: fine) and (prefers-reduced-motion: no-preference)').matches) return;
  document.querySelectorAll('[data-tilt]').forEach(node => {
    const glow = node.querySelector(':scope > .glow-follow');
    node.addEventListener('pointermove', event => {
      const box = node.getBoundingClientRect();
      const x = (event.clientX - box.left) / box.width, y = (event.clientY - box.top) / box.height;
      node.style.setProperty('--ry', `${(x - 0.5) * 6}deg`);
      node.style.setProperty('--rx', `${(y - 0.5) * -6}deg`);
      if (glow) { glow.style.setProperty('--gx', `${event.clientX - box.left}px`); glow.style.setProperty('--gy', `${event.clientY - box.top}px`); }
    });
    node.addEventListener('pointerleave', () => { node.style.removeProperty('--rx'); node.style.removeProperty('--ry'); });
  });

  // Buttons marked magnetic pull a few pixels toward a nearby pointer.
  document.querySelectorAll('.magnetic').forEach(button => {
    button.addEventListener('pointermove', event => {
      const box = button.getBoundingClientRect();
      button.style.setProperty('--bx', `${(event.clientX - box.left - box.width / 2) * 0.25}px`);
      button.style.setProperty('--by', `${(event.clientY - box.top - box.height / 2) * 0.35}px`);
    });
    button.addEventListener('pointerleave', () => { button.style.removeProperty('--bx'); button.style.removeProperty('--by'); });
  });

  // The mascot in the final call to action leans toward the pointer while it is on screen.
  const art = document.querySelector('.download-art');
  if (art) {
    let queued = false, last;
    addEventListener('pointermove', event => {
      last = event;
      if (queued) return;
      queued = true;
      requestAnimationFrame(() => {
        queued = false;
        const box = art.getBoundingClientRect();
        if (box.bottom < 0 || box.top > innerHeight) return;
        const dx = Math.max(-1, Math.min(1, (last.clientX - box.left - box.width / 2) / innerWidth * 2));
        const dy = Math.max(-1, Math.min(1, (last.clientY - box.top - box.height / 2) / innerHeight * 2));
        art.style.setProperty('--mx', `${dx * 16}px`);
        art.style.setProperty('--my', `${dy * 12}px`);
        art.style.setProperty('--mr', `${dx * 6}deg`);
      });
    }, { passive: true });
  }
})();

// Demo: the window builds itself, then plays one delegated task on a loop while it is on screen.
(() => {
  const demo = document.getElementById('demo');
  if (!demo) return;
  const chapters = [...document.querySelectorAll('.chapters li')];
  const typed = demo.querySelector('[data-type]'), prompt = typed.textContent;
  const cursor = demo.querySelector('.demo-cursor'), approve = demo.querySelector('[data-approve]');
  const panes = { build: demo.querySelector('.demo-pane.build'), tests: demo.querySelector('.demo-pane.tests') };
  const setStates = states => {
    demo.querySelectorAll('[data-agent]').forEach(s => { s.dataset.state = states[s.dataset.agent] || ''; });
    panes.tests.classList.toggle('is-blocked', states.tests === 'blocked');
    for (const state of ['blocked', 'working', 'done']) demo.querySelector(`[data-count=${state}]`).textContent = Object.values(states).filter(s => s === state).length;
  };
  const chapter = ms => chapters.forEach(li => li.classList.toggle('on', Number(li.dataset.from) <= ms));
  // Position relative to the demo box, ignoring the tilt transform on the stage around it.
  const offset = node => { let x = 0, y = 0; for (; node && node !== demo; node = node.offsetParent) { x += node.offsetLeft; y += node.offsetTop; } return [x, y]; };
  const final = () => {
    demo.querySelectorAll('[data-at]').forEach(node => node.classList.add('on'));
    demo.querySelectorAll('[data-off]').forEach(node => node.classList.add('gone'));
    setStates({ lead: 'done', build: 'done', tests: 'done' }); chapter(Infinity);
  };
  if (matchMedia('(prefers-reduced-motion: reduce)').matches) { final(); return; }

  let pending = [];
  const later = (ms, fn) => pending.push(setTimeout(fn, ms));
  const stop = () => { pending.forEach(clearTimeout); pending = []; };
  const play = () => {
    stop();
    demo.classList.remove('fade');
    demo.querySelectorAll('.on, .gone').forEach(node => node.classList.remove('on', 'gone'));
    cursor.classList.remove('on'); cursor.style.setProperty('--cx', `${demo.offsetWidth * 0.4}px`); cursor.style.setProperty('--cy', `${demo.offsetHeight * 0.45}px`);
    typed.textContent = '';
    setStates({}); chapter(0);
    demo.querySelectorAll('[data-at]').forEach(node => later(Number(node.dataset.at), () => node.classList.add('on')));
    demo.querySelectorAll('[data-off]').forEach(node => later(Number(node.dataset.off), () => node.classList.add('gone')));
    chapters.forEach(li => later(Number(li.dataset.from), () => chapter(Number(li.dataset.from))));
    const start = Number(typed.dataset.type);
    later(start, () => demo.classList.add('typing'));
    [...prompt].forEach((_, i) => later(start + i * 26, () => { typed.textContent = prompt.slice(0, i + 1); }));
    later(start + prompt.length * 26 + 300, () => demo.classList.remove('typing'));
    later(start, () => setStates({ lead: 'working' }));
    later(3900, () => setStates({ lead: 'working', build: 'working' }));
    later(4600, () => setStates({ lead: 'working', build: 'working', tests: 'working' }));
    later(6400, () => setStates({ lead: 'working', build: 'working', tests: 'blocked' }));
    later(7000, () => cursor.classList.add('on'));
    later(7100, () => {
      const [x, y] = offset(approve);
      cursor.style.setProperty('--cx', `${x + approve.offsetWidth / 2}px`);
      cursor.style.setProperty('--cy', `${y + approve.offsetHeight / 2}px`);
    });
    later(8200, () => approve.classList.add('press'));
    later(8400, () => { approve.classList.remove('press'); setStates({ lead: 'working', build: 'working', tests: 'working' }); });
    later(8800, () => cursor.classList.remove('on'));
    later(10000, () => setStates({ lead: 'working', build: 'done', tests: 'working' }));
    later(10200, () => setStates({ lead: 'working', build: 'done', tests: 'done' }));
    later(12000, () => setStates({ lead: 'done', build: 'done', tests: 'done' }));
    later(15600, () => demo.classList.add('fade'));
    later(16300, play);
  };
  new IntersectionObserver(([entry]) => entry.isIntersecting ? play() : stop(), { threshold: 0.35 }).observe(demo);
})();
