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
