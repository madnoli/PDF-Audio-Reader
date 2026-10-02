'use strict';

pdfjsLib.GlobalWorkerOptions.workerSrc =
  'https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.worker.min.js';

const $ = (id) => document.getElementById(id);
const els = {
  fileInput: $('file-input'),
  title: $('book-title'),
  toc: $('toc'),
  tocToggle: $('toc-toggle'),
  reader: $('reader'),
  play: $('play'),
  prev: $('prev'),
  next: $('next'),
  rate: $('rate'),
  rateValue: $('rate-value'),
  voice: $('voice'),
  indianOnly: $('indian-only'),
  status: $('status'),
};

const MAX_CHUNK = 240; // long sentences are split so the speech engine never stalls

const state = {
  sentences: [],   // { text, el, section }
  tocLinks: [],    // one <a> per section
  index: 0,
  playing: false,
  gen: 0,          // bumps on every restart so stale utterance callbacks are ignored
  utterance: null, // kept referenced so Chrome doesn't garbage-collect it mid-speech
  bookKey: null,
  currentSection: -1,
};

// localStorage can be unavailable (private mode, blocked storage) — never let that break the app.
const store = {
  get(key, fallback) {
    try {
      const v = localStorage.getItem(key);
      return v == null ? fallback : JSON.parse(v);
    } catch { return fallback; }
  },
  set(key, value) {
    try { localStorage.setItem(key, JSON.stringify(value)); } catch { /* ignore */ }
  },
};

const setStatus = (msg) => { els.status.textContent = msg; };

/* ---------------------------------------------------------------- Loading */

async function openFile(file) {
  pause();
  const ext = file.name.split('.').pop().toLowerCase();
  setStatus(`Loading ${file.name}…`);
  try {
    const buf = await file.arrayBuffer();
    let book;
    if (ext === 'pdf') book = await loadPdf(buf);
    else if (ext === 'epub') book = await loadEpub(buf);
    else throw new Error('please choose a .pdf or .epub file.');

    book.title = book.title || file.name.replace(/\.[^.]+$/, '');
    state.bookKey = `progress:${file.name}:${file.size}`;
    render(book);

    const saved = store.get(state.bookKey, 0);
    const start = Math.min(saved, state.sentences.length - 1);
    goTo(start, { scroll: true });
    setStatus(start > 0
      ? `Resuming where you left off. Press ▶ to listen.`
      : `${state.sentences.length.toLocaleString()} sentences ready. Press ▶ to listen.`);
  } catch (err) {
    console.error(err);
    setStatus(`Could not open ${file.name}: ${err.message}`);
  }
}

async function loadPdf(buf) {
  const pdf = await pdfjsLib.getDocument({ data: buf }).promise;
  let title = '';
  try { title = (await pdf.getMetadata()).info?.Title?.trim() || ''; } catch { /* no metadata */ }

  const sections = [];
  for (let p = 1; p <= pdf.numPages; p++) {
    setStatus(`Reading page ${p} of ${pdf.numPages}…`);
    const page = await pdf.getPage(p);
    const content = await page.getTextContent();
    sections.push({ title: `Page ${p}`, paragraphs: pdfParagraphs(content.items) });
    page.cleanup();
  }
  if (sections.every((s) => s.paragraphs.length === 0)) {
    throw new Error('no text found. This PDF looks like scanned images, which need OCR first.');
  }
  return { title, sections };
}

// Rebuilds lines and paragraphs from pdf.js text fragments using their positions.
function pdfParagraphs(items) {
  const lines = [];
  let cur = null;
  for (const it of items) {
    if (typeof it.str !== 'string') continue;
    const x = it.transform[4];
    const y = it.transform[5];
    const h = Math.abs(it.transform[3]) || it.height || 10;
    if (!cur || Math.abs(y - cur.y) > h * 0.5) {
      cur = { y, text: '', endX: null };
      lines.push(cur);
    }
    // Some PDFs omit space characters; infer them from the horizontal gap.
    if (cur.text && cur.endX != null && x - cur.endX > h * 0.15 &&
        !/\s$/.test(cur.text) && !/^\s/.test(it.str)) {
      cur.text += ' ';
    }
    cur.text += it.str;
    cur.endX = x + (it.width || 0);
    if (it.hasEOL) cur = null;
  }

  const gaps = [];
  for (let i = 1; i < lines.length; i++) {
    const g = lines[i - 1].y - lines[i].y;
    if (g > 0) gaps.push(g);
  }
  gaps.sort((a, b) => a - b);
  const typicalGap = gaps.length ? gaps[gaps.length >> 1] : 0;

  const paragraphs = [];
  let buf = '';
  const flush = () => { if (buf.trim()) paragraphs.push(buf.trim()); buf = ''; };

  lines.forEach((line, i) => {
    const t = line.text.replace(/\s+/g, ' ').trim();
    if (i > 0) {
      const g = lines[i - 1].y - line.y;
      // Blank line, a jump upwards (new column), or a large vertical gap starts a new paragraph.
      if (!t || g <= 0 || (typicalGap && g > typicalGap * 1.6)) flush();
    }
    if (!t) return;
    if (/[a-z]-$/.test(buf) && /^[a-z]/.test(t)) buf = buf.slice(0, -1) + t; // re-join hyphenated words
    else buf = buf ? `${buf} ${t}` : t;
  });
  flush();
  return paragraphs;
}

async function loadEpub(buf) {
  const zip = await JSZip.loadAsync(buf);
  const read = async (path) => {
    const f = zip.file(path);
    if (!f) throw new Error(`the EPUB is missing ${path}.`);
    return f.async('string');
  };
  const parseXml = (s) => new DOMParser().parseFromString(s, 'application/xml');
  const parseHtml = (s) => {
    const doc = new DOMParser().parseFromString(s, 'application/xhtml+xml');
    return doc.getElementsByTagName('parsererror').length
      ? new DOMParser().parseFromString(s, 'text/html')
      : doc;
  };
  const dirOf = (p) => p.slice(0, p.lastIndexOf('/') + 1);
  const resolve = (base, href) =>
    decodeURIComponent(new URL(href, `http://epub/${base}`).pathname.slice(1));
  const byTag = (node, tag) => Array.from(node.getElementsByTagNameNS('*', tag));

  const container = parseXml(await read('META-INF/container.xml'));
  const opfPath = byTag(container, 'rootfile')[0]?.getAttribute('full-path');
  if (!opfPath) throw new Error('this EPUB has no package file.');
  const opfDir = dirOf(opfPath);
  const opf = parseXml(await read(opfPath));

  const title = byTag(opf, 'title')[0]?.textContent.trim() || '';
  const manifest = new Map();
  for (const item of byTag(opf, 'item')) manifest.set(item.getAttribute('id'), item);
  const spine = byTag(opf, 'spine')[0];

  // Chapter names from the table of contents (EPUB 3 nav, or EPUB 2 NCX).
  const tocTitles = new Map();
  const addTitle = (path, label) => {
    const key = path.split('#')[0];
    if (label && !tocTitles.has(key)) tocTitles.set(key, label.replace(/\s+/g, ' ').trim());
  };
  try {
    const items = Array.from(manifest.values());
    const nav = items.find((i) => (i.getAttribute('properties') || '').split(/\s+/).includes('nav'));
    const ncx = manifest.get(spine?.getAttribute('toc')) ||
      items.find((i) => i.getAttribute('media-type') === 'application/x-dtbncx+xml');
    if (nav) {
      const navPath = resolve(opfDir, nav.getAttribute('href'));
      const doc = parseHtml(await read(navPath));
      for (const a of byTag(doc, 'a')) {
        if (a.getAttribute('href')) addTitle(resolve(dirOf(navPath), a.getAttribute('href')), a.textContent);
      }
    } else if (ncx) {
      const ncxPath = resolve(opfDir, ncx.getAttribute('href'));
      const doc = parseXml(await read(ncxPath));
      for (const point of byTag(doc, 'navPoint')) {
        const src = byTag(point, 'content')[0]?.getAttribute('src');
        const label = byTag(point, 'text')[0]?.textContent;
        if (src) addTitle(resolve(dirOf(ncxPath), src), label);
      }
    }
  } catch (err) {
    console.warn('Could not read EPUB table of contents', err);
  }

  const sections = [];
  const refs = spine ? byTag(spine, 'itemref') : [];
  for (let i = 0; i < refs.length; i++) {
    setStatus(`Reading chapter ${i + 1} of ${refs.length}…`);
    const item = manifest.get(refs[i].getAttribute('idref'));
    if (!item || !/html|xml/.test(item.getAttribute('media-type') || '')) continue;
    const path = resolve(opfDir, item.getAttribute('href'));
    let doc;
    try { doc = parseHtml(await read(path)); } catch { continue; }
    const body = doc.body || byTag(doc, 'body')[0];
    if (!body) continue;
    const paragraphs = htmlParagraphs(body);
    if (!paragraphs.length) continue;
    const heading = byTag(body, 'h1')[0] || byTag(body, 'h2')[0];
    sections.push({
      title: tocTitles.get(path) || heading?.textContent.trim() || `Section ${sections.length + 1}`,
      paragraphs,
    });
  }
  if (!sections.length) throw new Error('no readable text found in this EPUB.');
  return { title, sections };
}

const BLOCK_TAGS = new Set([
  'address', 'article', 'aside', 'blockquote', 'br', 'dd', 'div', 'dl', 'dt', 'figcaption',
  'figure', 'footer', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'header', 'hr', 'li', 'ol', 'p',
  'pre', 'section', 'table', 'td', 'th', 'tr', 'ul',
]);
const SKIP_TAGS = new Set(['script', 'style', 'head', 'title', 'rt', 'rp', 'svg', 'math']);

function htmlParagraphs(root) {
  const out = [];
  let buf = '';
  const flush = () => {
    const t = buf.replace(/\s+/g, ' ').trim();
    if (t) out.push(t);
    buf = '';
  };
  (function walk(node) {
    for (const child of node.childNodes) {
      if (child.nodeType === Node.TEXT_NODE) {
        buf += child.nodeValue;
      } else if (child.nodeType === Node.ELEMENT_NODE) {
        const tag = child.localName.toLowerCase();
        if (SKIP_TAGS.has(tag)) continue;
        // Footnote reference markers like ¹ or [3] just interrupt the reading.
        if (tag === 'sup' && child.querySelector('a')) continue;
        const block = BLOCK_TAGS.has(tag);
        if (block) flush();
        walk(child);
        if (block) flush();
      }
    }
  })(root);
  flush();
  return out;
}

/* -------------------------------------------------------------- Rendering */

const segmenter = 'Segmenter' in Intl ? new Intl.Segmenter('en', { granularity: 'sentence' }) : null;

function splitSentences(text) {
  const parts = segmenter
    ? Array.from(segmenter.segment(text), (s) => s.segment)
    : text.match(/[^.!?।]+[.!?।]+["'”’)\]]*\s*|[^.!?।]+$/g) || [text];
  const out = [];
  for (let rest of parts) {
    while (rest.length > MAX_CHUNK) {
      let cut = rest.lastIndexOf(', ', MAX_CHUNK);
      if (cut < MAX_CHUNK / 2) cut = rest.lastIndexOf(' ', MAX_CHUNK);
      if (cut <= 0) cut = MAX_CHUNK;
      out.push(rest.slice(0, cut + 1));
      rest = rest.slice(cut + 1);
    }
    if (rest) out.push(rest);
  }
  return out;
}

function render(book) {
  els.title.textContent = book.title;
  document.title = `${book.title} · Audio Book Reader`;
  state.sentences = [];
  state.tocLinks = [];
  state.currentSection = -1;

  const container = document.createElement('article');
  container.className = 'book';
  const toc = document.createDocumentFragment();

  book.sections.forEach((section, si) => {
    const sec = document.createElement('section');
    sec.id = `sec-${si}`;
    const label = document.createElement('div');
    label.className = 'section-label';
    label.textContent = section.title;
    sec.append(label);

    const firstSentence = state.sentences.length;
    for (const para of section.paragraphs) {
      const p = document.createElement('p');
      for (const part of splitSentences(para)) {
        const text = part.trim();
        if (!text) { p.append(part); continue; }
        const span = document.createElement('span');
        span.className = 's';
        span.dataset.i = state.sentences.length;
        span.textContent = part;
        p.append(span);
        state.sentences.push({ text, el: span, section: si });
      }
      sec.append(p);
    }
    container.append(sec);

    const a = document.createElement('a');
    a.href = `#sec-${si}`;
    a.textContent = section.title;
    a.title = section.title;
    a.addEventListener('click', (e) => {
      e.preventDefault();
      document.body.classList.remove('toc-open');
      if (state.sentences.length > firstSentence) goTo(firstSentence, { scroll: true });
    });
    toc.append(a);
    state.tocLinks.push(a);
  });

  els.reader.replaceChildren(container);
  els.toc.replaceChildren(toc);
  els.reader.scrollTop = 0;
  updateButtons();
}

function highlight(i) {
  document.querySelector('.s.current')?.classList.remove('current');
  const s = state.sentences[i];
  if (!s) return;
  s.el.classList.add('current');

  if (s.section !== state.currentSection) {
    state.tocLinks[state.currentSection]?.classList.remove('active');
    state.tocLinks[s.section]?.classList.add('active');
    state.tocLinks[s.section]?.scrollIntoView({ block: 'nearest' });
    state.currentSection = s.section;
  }
}

function scrollToSentence(i, force) {
  const el = state.sentences[i]?.el;
  if (!el) return;
  const r = el.getBoundingClientRect();
  const v = els.reader.getBoundingClientRect();
  if (force || r.top < v.top + 40 || r.bottom > v.bottom - 40) {
    el.scrollIntoView({ block: 'center', behavior: force ? 'auto' : 'smooth' });
  }
}

/* ---------------------------------------------------------------- Speech */

let voices = [];

const isIndian = (v) => /-IN$/i.test(v.lang.replace('_', '-')) || /india/i.test(v.name);
const voiceRank = (v) =>
  (/natural|online|neural/i.test(v.name) ? 0 : 2) + (/^en/i.test(v.lang) ? 0 : 1);

function loadVoices() {
  voices = speechSynthesis.getVoices();
  if (!voices.length) return;

  const indian = voices.filter(isIndian).sort((a, b) => voiceRank(a) - voiceRank(b));
  const others = voices.filter((v) => !isIndian(v));
  const showOthers = !els.indianOnly.checked || indian.length === 0;
  const saved = store.get('voice', null);
  const previous = els.voice.value || saved;

  els.voice.replaceChildren();
  const addGroup = (label, list) => {
    if (!list.length) return;
    const group = document.createElement('optgroup');
    group.label = label;
    for (const v of list) {
      const opt = document.createElement('option');
      opt.value = v.name;
      opt.textContent = `${v.name.replace(/^Microsoft /, '')} (${v.lang})`;
      group.append(opt);
    }
    els.voice.append(group);
  };
  addGroup('Indian voices', indian);
  if (showOthers) addGroup('Other voices', others);

  const options = Array.from(els.voice.options).map((o) => o.value);
  els.voice.value = options.includes(previous) ? previous : options[0] || '';

  if (!indian.length) {
    setStatus('No Indian voice found on this device. Open this app in Microsoft Edge, ' +
      'or add "English (India)" in Windows Settings › Time & language › Speech.');
  }
}

const currentVoice = () => voices.find((v) => v.name === els.voice.value) || null;

function speakCurrent() {
  const gen = ++state.gen;
  const s = state.sentences[state.index];
  if (!s) {
    pause();
    setStatus('Finished reading.');
    return;
  }
  highlight(state.index);
  scrollToSentence(state.index, false);

  const u = new SpeechSynthesisUtterance(s.text);
  const voice = currentVoice();
  if (voice) { u.voice = voice; u.lang = voice.lang; }
  u.rate = Number(els.rate.value);
  u.onend = () => {
    if (gen !== state.gen || !state.playing) return;
    state.index++;
    saveProgress();
    speakCurrent();
  };
  u.onerror = (e) => {
    if (gen !== state.gen || e.error === 'interrupted' || e.error === 'canceled') return;
    console.error('Speech error', e.error);
    pause();
    setStatus(`Speech stopped: ${e.error}. Try another voice.`);
  };
  state.utterance = u;
  speechSynthesis.speak(u);
}

// Cancel whatever is speaking and start the current sentence again (used for play, seek, speed/voice change).
function restart() {
  state.gen++;
  speechSynthesis.cancel();
  // Chrome sometimes drops a speak() issued in the same tick as cancel().
  setTimeout(() => { if (state.playing) speakCurrent(); }, 60);
}

function play() {
  if (!state.sentences.length) return;
  if (!('speechSynthesis' in window)) {
    setStatus('This browser does not support text-to-speech.');
    return;
  }
  state.playing = true;
  setStatus('');
  updateButtons();
  restart();
}

function pause() {
  state.playing = false;
  state.gen++;
  if ('speechSynthesis' in window) speechSynthesis.cancel();
  updateButtons();
}

function goTo(i, { scroll = false } = {}) {
  if (!state.sentences.length) return;
  state.index = Math.max(0, Math.min(i, state.sentences.length - 1));
  highlight(state.index);
  if (scroll) scrollToSentence(state.index, true);
  saveProgress();
  if (state.playing) restart();
}

function saveProgress() {
  if (state.bookKey) store.set(state.bookKey, state.index);
}

function updateButtons() {
  const has = state.sentences.length > 0;
  els.play.disabled = els.prev.disabled = els.next.disabled = !has;
  els.play.textContent = state.playing ? '⏸' : '▶';
  els.play.setAttribute('aria-label', state.playing ? 'Pause' : 'Play');
}

function showRate() {
  els.rateValue.textContent = `${Number(els.rate.value).toFixed(1)}×`;
}

/* ---------------------------------------------------------------- Wiring */

els.fileInput.addEventListener('change', () => {
  const file = els.fileInput.files[0];
  if (file) openFile(file);
  els.fileInput.value = '';
});

els.play.addEventListener('click', () => (state.playing ? pause() : play()));
els.prev.addEventListener('click', () => goTo(state.index - 1, { scroll: true }));
els.next.addEventListener('click', () => goTo(state.index + 1, { scroll: true }));

els.reader.addEventListener('click', (e) => {
  const span = e.target.closest('.s');
  if (!span || window.getSelection().toString()) return;
  goTo(Number(span.dataset.i));
  if (!state.playing) play();
});

els.rate.addEventListener('input', showRate);
els.rate.addEventListener('change', () => {
  store.set('rate', Number(els.rate.value));
  if (state.playing) restart();
});

els.voice.addEventListener('change', () => {
  store.set('voice', els.voice.value);
  if (state.playing) restart();
});

els.indianOnly.addEventListener('change', () => {
  store.set('indianOnly', els.indianOnly.checked);
  loadVoices();
  if (state.playing) restart();
});

els.tocToggle.addEventListener('click', () => document.body.classList.toggle('toc-open'));

document.addEventListener('keydown', (e) => {
  if (e.target.closest('input, select, textarea, button') || e.ctrlKey || e.metaKey || e.altKey) return;
  if (e.code === 'Space') { e.preventDefault(); state.playing ? pause() : play(); }
  else if (e.key === 'ArrowRight') { e.preventDefault(); goTo(state.index + 1, { scroll: true }); }
  else if (e.key === 'ArrowLeft') { e.preventDefault(); goTo(state.index - 1, { scroll: true }); }
});

['dragenter', 'dragover'].forEach((type) => document.addEventListener(type, (e) => {
  e.preventDefault();
  document.body.classList.add('drag');
}));
['dragleave', 'drop'].forEach((type) => document.addEventListener(type, (e) => {
  e.preventDefault();
  if (type === 'dragleave' && e.relatedTarget) return;
  document.body.classList.remove('drag');
}));
document.addEventListener('drop', (e) => {
  const file = e.dataTransfer?.files?.[0];
  if (file) openFile(file);
});

// Stop speaking when the tab is closed; the engine otherwise keeps talking in some browsers.
window.addEventListener('beforeunload', () => { if ('speechSynthesis' in window) speechSynthesis.cancel(); });

/* ------------------------------------------------------------------ Init */

els.rate.value = store.get('rate', 1);
els.indianOnly.checked = store.get('indianOnly', true);
showRate();
updateButtons();

if ('speechSynthesis' in window) {
  loadVoices();
  speechSynthesis.addEventListener('voiceschanged', loadVoices);
} else {
  setStatus('This browser does not support text-to-speech. Please use Microsoft Edge or Chrome.');
}
