import { itemsFromDocument, pickLatestItem, formatBytes } from './appcast.js';

document.documentElement.classList.add('js');

// The download button ships with a working href in the HTML. This only ever
// upgrades it to the newest release; a failure leaves the fallback in place.
async function hydrateDownload() {
  // Task 3 put a download button in BOTH the nav and the hero, so every
  // match must be upgraded — hydrating only the first would leave the
  // hero's primary CTA pinned to the hardcoded fallback.
  const links = [...document.querySelectorAll('[data-download-link]')];
  const badge = document.querySelector('[data-version-badge]');
  if (!links.length) return;
  try {
    const res = await fetch('/appcast.xml', { cache: 'no-cache' });
    if (!res.ok) return;
    const doc = new DOMParser().parseFromString(await res.text(), 'application/xml');
    if (doc.getElementsByTagName('parsererror').length) return;
    const latest = pickLatestItem(itemsFromDocument(doc));
    if (!latest) return;
    links.forEach((link) => { link.href = latest.url; });
    if (badge) {
      const size = formatBytes(latest.length);
      badge.textContent = ['Free download', latest.version && `v${latest.version}`, size]
        .filter(Boolean)
        .join(' · ');
    }
  } catch {
    /* keep the hardcoded fallback */
  }
}

hydrateDownload();

const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)');

// Beat switching: the root band covers only the middle 10% of the viewport, so
// a full-screenful beat never crosses the 0.5 or 1 thresholds -- in practice
// the last beat whose edge entered that band wins, which stays monotonic with
// scroll direction.
function mountTheater() {
  const theater = document.querySelector('[data-theater]');
  if (!theater) return;
  const beats = [...theater.querySelectorAll('[data-beat]')];
  const imgs = [...theater.querySelectorAll('[data-beat-img]')];
  if (!beats.length || !imgs.length) return;

  let active = -1;
  const setActive = (n) => {
    if (n === active) return;
    active = n;
    imgs.forEach((img) => img.classList.toggle('is-active', +img.dataset.beatImg === n));
    beats.forEach((b) => b.classList.toggle('is-active', +b.dataset.beat === n));
  };

  const io = new IntersectionObserver(
    (entries) => {
      const visible = entries.filter((e) => e.isIntersecting);
      if (!visible.length) return;
      const best = visible.reduce((a, b) => (b.intersectionRatio > a.intersectionRatio ? b : a));
      setActive(+best.target.dataset.beat);
    },
    { rootMargin: '-45% 0px -45% 0px', threshold: [0, 0.5, 1] },
  );
  beats.forEach((b) => io.observe(b));
  setActive(0);
}

// Reveal-on-scroll. Elements are visible by default in CSS; the `.js` class on
// <html> is what arms the hidden state, so a JS failure never hides content.
function mountReveals() {
  const items = [...document.querySelectorAll('.reveal')];
  if (!items.length) return;
  if (reduceMotion.matches) {
    items.forEach((el) => el.classList.add('is-revealed'));
    return;
  }
  const io = new IntersectionObserver(
    (entries) => {
      entries.forEach((e) => {
        if (e.isIntersecting) {
          e.target.classList.add('is-revealed');
          io.unobserve(e.target);
        }
      });
    },
    { rootMargin: '0px 0px -10% 0px', threshold: 0.15 },
  );
  items.forEach((el) => io.observe(el));
}

// Slipreel's signature smoothed cursor, performed on the visitor.
function mountCursorTrail() {
  const stage = document.querySelector('[data-cursor-stage]');
  if (!stage || reduceMotion.matches) return;
  if (!window.matchMedia('(pointer: fine)').matches) return;

  const canvas = document.createElement('canvas');
  canvas.className = 'cursor-trail';
  canvas.setAttribute('aria-hidden', 'true');
  stage.appendChild(canvas);
  const ctx = canvas.getContext('2d');

  let dpr = 1, w = 0, h = 0;
  const resize = () => {
    dpr = Math.min(window.devicePixelRatio || 1, 2);
    const r = stage.getBoundingClientRect();
    w = r.width; h = r.height;
    canvas.width = w * dpr; canvas.height = h * dpr;
    canvas.style.width = `${w}px`; canvas.style.height = `${h}px`;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  };
  resize();
  window.addEventListener('resize', resize, { passive: true });

  const trail = [];
  let target = null;
  // Critically damped follow, matching the app's spring feel.
  let px = 0, py = 0, has = false;

  // Read --accent once at mount rather than hardcoding its RGB triplet a
  // third time (the stylesheet already carries two, both noted as such).
  const accentRGB = (() => {
    const probe = document.createElement('div');
    probe.style.cssText = 'position:absolute;visibility:hidden;';
    probe.style.color = getComputedStyle(document.documentElement).getPropertyValue('--accent');
    document.body.appendChild(probe);
    const match = getComputedStyle(probe).color.match(/\d+/g);
    probe.remove();
    return match ? match.slice(0, 3).join(', ') : '108, 92, 231';
  })();

  // The loop only ever runs while there's something to draw and the stage is
  // actually on screen; it is started on demand (pointermove, or the stage
  // scrolling into view) and cancelled the moment neither holds, rather than
  // running for the whole page lifetime.
  let rafId = null;
  let visible = false;

  const startLoop = () => {
    if (rafId !== null) return;
    rafId = requestAnimationFrame(tick);
  };
  const stopLoop = () => {
    if (rafId === null) return;
    cancelAnimationFrame(rafId);
    rafId = null;
  };

  stage.addEventListener('pointermove', (e) => {
    const r = stage.getBoundingClientRect();
    target = { x: e.clientX - r.left, y: e.clientY - r.top };
    if (!has) { px = target.x; py = target.y; has = true; }
    startLoop();
  }, { passive: true });
  stage.addEventListener('pointerleave', () => { target = null; has = false; trail.length = 0; }, { passive: true });

  const io = new IntersectionObserver((entries) => {
    visible = entries[entries.length - 1].isIntersecting;
    if (visible) startLoop(); else stopLoop();
  });
  io.observe(stage);

  function tick() {
    ctx.clearRect(0, 0, w, h);
    if (target && has) {
      px += (target.x - px) * 0.18;
      py += (target.y - py) * 0.18;
      trail.push({ x: px, y: py });
      if (trail.length > 22) trail.shift();
    } else if (trail.length) {
      trail.shift();
    }
    for (let i = 0; i < trail.length; i++) {
      const p = trail[i];
      const t = i / trail.length;
      ctx.beginPath();
      ctx.arc(p.x, p.y, 3 + t * 7, 0, Math.PI * 2);
      ctx.fillStyle = `rgba(${accentRGB}, ${t * t * 0.32})`;
      ctx.fill();
    }
    if (!visible || (!target && !trail.length)) {
      rafId = null;
      return;
    }
    rafId = requestAnimationFrame(tick);
  }
}

mountTheater();
mountReveals();
mountCursorTrail();
