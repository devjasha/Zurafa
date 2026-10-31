(() => {
  const toggle = document.querySelector('.nav-toggle');
  if (toggle) {
    const wrap = toggle.closest('.nav-wrap');
    const setOpen = open => { wrap.classList.toggle('open', open); toggle.setAttribute('aria-expanded', open); };
    toggle.addEventListener('click', () => setOpen(!wrap.classList.contains('open')));
    wrap.querySelector('nav').addEventListener('click', event => { if (event.target.closest('a')) setOpen(false); });
    document.addEventListener('click', event => { if (!wrap.contains(event.target)) setOpen(false); });
    document.addEventListener('keydown', event => { if (event.key === 'Escape' && wrap.classList.contains('open')) { setOpen(false); toggle.focus(); } });
  }

  const current = document.body.dataset.page;
  if (current) {
    document.querySelectorAll('.nav-group a[data-page]').forEach(link => {
      if (link.dataset.page === current) link.setAttribute('aria-current', 'page');
    });
  }

  const search = document.getElementById('docs-search');
  const results = document.getElementById('search-results');
  if (!search || !results) return;

  let pages;
  const load = async () => {
    if (pages) return pages;
    const response = await fetch('/assets/search.json');
    if (!response.ok) throw new Error('Search index unavailable');
    pages = await response.json();
    return pages;
  };
  const clear = () => { results.replaceChildren(); results.hidden = true; };
  const render = async () => {
    const query = search.value.trim().toLocaleLowerCase();
    if (!query) { clear(); return; }
    try {
      const documents = await load();
      const matches = documents.filter(page =>
        `${page.title} ${page.group} ${page.text}`.toLocaleLowerCase().includes(query)
      ).slice(0, 8);
      results.replaceChildren();
      if (!matches.length) {
        const empty = document.createElement('div');
        empty.className = 'search-empty';
        empty.textContent = 'No matching guides';
        results.append(empty);
      }
      for (const page of matches) {
        const link = document.createElement('a');
        link.href = page.url;
        const title = document.createElement('span');
        title.textContent = page.title;
        const group = document.createElement('small');
        group.textContent = page.group;
        link.append(title, group);
        results.append(link);
      }
      results.hidden = false;
    } catch {
      results.replaceChildren();
      const error = document.createElement('div');
      error.className = 'search-empty';
      error.textContent = 'Search is temporarily unavailable';
      results.append(error);
      results.hidden = false;
    }
  };
  search.addEventListener('input', render);
  search.addEventListener('keydown', event => {
    if (event.key === 'Escape') { search.value = ''; clear(); search.blur(); }
    if (event.key === 'Enter') results.querySelector('a')?.click();
  });
  document.addEventListener('keydown', event => {
    if (event.key === '/' && !['INPUT', 'TEXTAREA'].includes(document.activeElement?.tagName)) {
      event.preventDefault(); search.focus();
    }
  });
  document.addEventListener('click', event => {
    if (!search.contains(event.target) && !results.contains(event.target)) clear();
  });
})();
