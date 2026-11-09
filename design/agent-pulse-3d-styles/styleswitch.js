/* Style lab switcher + live GPU HUD. */
(function () {
  'use strict';
  const INFO = {
    crystal: {
      name: 'CRYSTAL',
      desc: '冰蓝 / 电蓝 / 靛紫 · 1.6k 硬点阵；思考=陀螺仪认知环，输出=球形广播。'
    },
    nova: {
      name: 'NOVA',
      desc: '青 / 蓝绿 / 紫 / 品红 · 4.2k 体积星云；思考=思想环，输出=光波广播。'
    },
    flux: {
      name: 'FLUX',
      desc: '青绿 / 青 / 品红 · 1.8k 拖尾光流；思考=三股螺旋，输出=旋涡外溢。'
    }
  };
  const tabs = Array.from(document.querySelectorAll('.style-tab'));
  const descEl = document.getElementById('styleDesc');
  const fpsEl = document.getElementById('styleFps');
  const countEl = document.getElementById('styleCount');
  const hudLast = document.querySelector('.style-hud span:last-child');
  const hudDot = document.querySelector('.style-hud .gl-dot');
  let current = 'nova';
  let engine = null;
  let hudTimer = 0;

  function setActive(id) {
    tabs.forEach(t => t.classList.toggle('active', t.dataset.style === id));
    document.body.dataset.style = id;
    descEl.textContent = INFO[id].desc;
  }

  function apply(id, silent) {
    if (!INFO[id]) return;
    current = id;
    setActive(id);
    if (engine) engine.setStyle(id);
    const q = new URLSearchParams(location.search);
    q.set('style', id);
    if (!silent) { try { history.replaceState(null, '', '?' + q.toString()); } catch (_) {} }
  }

  tabs.forEach(tab => tab.addEventListener('click', () => apply(tab.dataset.style)));
  document.addEventListener('keydown', e => {
    if (e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement || e.target.isContentEditable) return;
    const map = { a: 'crystal', b: 'nova', c: 'flux' };
    const id = map[e.key.toLowerCase()];
    if (id) { e.preventDefault(); apply(id); }
  });

  const q = new URLSearchParams(location.search);
  current = INFO[q.get('style')] ? q.get('style') : 'nova';
  if (q.get('widget') === '1') document.body.classList.add('widget');
  setActive(current);

  function updateHud() {
    if (!engine) return;
    const f = engine.getFPS();
    const n = engine.getCount();
    const perf = engine.getPerf ? engine.getPerf() : null;
    fpsEl.textContent = Math.max(1, f || 60) + ' FPS' + (perf && !perf.focused ? ' · 后台' : '');
    fpsEl.title = perf ? `${perf.ms} ms/frame · 上限 ${perf.target} FPS${perf.focused ? '' : ' · 失焦自动省电'}` : '';
    countEl.textContent = (n >= 1000 ? (n / 1000).toFixed(1) + 'k' : n) + ' 粒子';
    const ok = engine.isWebGL();
    if (hudLast) hudLast.textContent = (ok ? 'WEBGL' : '2D') + (perf ? ' · ' + perf.dpr.toFixed(1) + 'x' : '');
    if (hudDot) hudDot.style.background = ok ? 'var(--green)' : 'var(--amber)';
  }

  const wait = setInterval(() => {
    if (!window.__pulse || !window.__pulse.engine) return;
    engine = window.__pulse.engine;
    clearInterval(wait);
    engine.setStyle(current);
    updateHud();
    hudTimer = setInterval(updateHud, 250);
  }, 120);
})();
