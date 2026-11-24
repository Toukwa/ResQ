// Background: a grid of small square dots. Every 1.5-3 s a wave starts at a random spot and
// spreads outward as a ring of orange squares, brightest at the front and fading toward the inside.
//
// For smooth motion the grey dots are drawn once into an off-screen layer (redrawn only on resize
// or theme change); each frame copies that layer and only paints the squares near each wave.
(() => {
  const canvas = document.getElementById('bg');
  if (!canvas) return;
  const ctx = canvas.getContext('2d');
  const layer = document.createElement('canvas');
  const lctx = layer.getContext('2d');
  const GAP = 14, SIZE = 3, BAND = 70, EDGE = 8, SPEED = 140, MAX_R = 560, GROW = 90;
  const still = window.matchMedia('(prefers-reduced-motion: reduce)');
  const dark = window.matchMedia('(prefers-color-scheme: dark)');
  let w = 0, h = 0, dpr = 1, ox = 0, oy = 0, brand = '#ff6b00';
  let waves = [], last = 0, nextWave = 0, raf = 0;

  const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  const smooth = (x) => x * x * (3 - 2 * x);               // smoothstep 0..1

  function paintDots() {
    const dot = css('--dot');
    brand = css('--brand') || brand;
    lctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    lctx.clearRect(0, 0, w, h);
    lctx.fillStyle = dot;
    for (let y = oy; y < h; y += GAP) {
      // dots (not waves): full in the lower half, fading out to nothing at about 25% from the top
      lctx.globalAlpha = smooth(Math.max(0, Math.min(1, (y / h - 0.25) / 0.3)));
      if (lctx.globalAlpha === 0) continue;
      for (let x = ox; x < w; x += GAP) lctx.fillRect(x - SIZE / 2, y - SIZE / 2, SIZE, SIZE);
    }
    lctx.globalAlpha = 1;
  }

  function resize() {
    dpr = Math.min(window.devicePixelRatio || 1, 2);
    w = window.innerWidth; h = window.innerHeight;
    canvas.width = layer.width = Math.round(w * dpr);
    canvas.height = layer.height = Math.round(h * dpr);
    ox = (w % GAP) / 2; oy = (h % GAP) / 2;
    paintDots();
    draw();
  }

  // Strength of a wave at distance `dist` from its centre: soft leading edge, long fade inward.
  function strength(wv, dist) {
    const d = wv.r - dist;
    let k;
    if (d >= 0 && d < BAND) k = smooth(1 - d / BAND);
    else if (d < 0 && d > -EDGE) k = smooth(1 + d / EDGE);
    else return 0;
    const life = wv.r / MAX_R;
    return k * smooth(Math.min(1, wv.r / GROW)) * (1 - smooth(life));   // ease in, ease out
  }

  function draw() {
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    ctx.drawImage(layer, 0, 0);
    if (!waves.length) return;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.fillStyle = brand;
    // only the squares inside the area the waves cover
    let x0 = w, y0 = h, x1 = 0, y1 = 0;
    for (const wv of waves) {
      const r = wv.r + EDGE;
      x0 = Math.min(x0, wv.x - r); y0 = Math.min(y0, wv.y - r);
      x1 = Math.max(x1, wv.x + r); y1 = Math.max(y1, wv.y + r);
    }
    const sx = ox + Math.max(0, Math.ceil((x0 - ox) / GAP)) * GAP;
    const sy = oy + Math.max(0, Math.ceil((y0 - oy) / GAP)) * GAP;
    for (let y = sy; y <= Math.min(y1, h); y += GAP) {
      for (let x = sx; x <= Math.min(x1, w); x += GAP) {
        let a = 0;
        for (const wv of waves) {
          const s = strength(wv, Math.hypot(x - wv.x, y - wv.y));
          if (s > a) a = s;
        }
        if (a < 0.02) continue;
        ctx.globalAlpha = a * 0.9;
        const g = SIZE + a;                     // squares swell slightly as the wave passes
        ctx.fillRect(x - g / 2, y - g / 2, g, g);
      }
    }
    ctx.globalAlpha = 1;
  }

  function tick(t) {
    const dt = last ? Math.min((t - last) / 1000, 1 / 20) : 0;
    last = t;
    if (t > nextWave) {
      waves.push({ x: Math.random() * w, y: Math.random() * h, r: 0 });
      nextWave = t + 1500 + Math.random() * 1500;
    }
    for (const wv of waves) wv.r += SPEED * dt;
    waves = waves.filter((wv) => wv.r < MAX_R);
    draw();
    raf = requestAnimationFrame(tick);
  }

  function start() {
    cancelAnimationFrame(raf);
    last = 0; nextWave = performance.now() + 800;
    if (!still.matches && !document.hidden) raf = requestAnimationFrame(tick);
    else { waves = []; draw(); }
  }

  let resizeTimer = 0;
  window.addEventListener('resize', () => { clearTimeout(resizeTimer); resizeTimer = setTimeout(resize, 100); });
  document.addEventListener('visibilitychange', start);
  still.addEventListener?.('change', start);
  dark.addEventListener?.('change', () => { paintDots(); draw(); });
  resize();
  start();
})();
