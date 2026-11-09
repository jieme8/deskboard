/* PULSE 3D particle engine — zero dependency, manual perspective projection on 2D canvas. */
(function () {
  'use strict';

  const W = 420, H = 420, CX = 210, CY = 195;
  const FOCAL = 300, CAM = 320;
  const HEALTH_R = 158, RING_R = 136, CORE_HIT = 92;
  const DENSITY = { low: 260, mid: 420, high: 560 };
  const RING_DEFS = [
    { r: 52, rx: .55, ry: .10, speed: .34, thick: 3.0 },
    { r: 70, rx: 1.05, ry: .72, speed: -.24, thick: 3.6 },
    { r: 88, rx: 1.52, ry: .18, speed: .16, thick: 4.0 }
  ];
  const RGB = {
    cyan: [112, 216, 255], ice: [178, 238, 255], white: [226, 246, 255],
    amber: [255, 196, 107], red: [255, 107, 107], green: [120, 226, 172],
    muted: [126, 176, 206], dim: [94, 126, 146]
  };
  const COLOR_KEY = {
    '#70D8FF': 'cyan', '#B2EEFF': 'ice', '#E2F6FF': 'white',
    '#FFC46B': 'amber', '#FF6B6B': 'red', '#78E2AC': 'green',
    '#7EB0CE': 'muted', '#5E7E92': 'dim'
  };
  const HEALTH_KEY = ['cyan', 'amber', 'red'];
  const META = window.PULSE_STATES;

  const canvas = document.getElementById('orb');
  const ctx = canvas.getContext('2d');
  const wrap = document.getElementById('orbWrap');
  const tip = document.getElementById('stationTip');
  const docEl = document.documentElement;

  const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
  const frac = v => v - Math.floor(v);
  const rgba = (key, a) => { const c = RGB[key]; return `rgba(${c[0]},${c[1]},${c[2]},${a})`; };
  const easeOut = t => 1 - Math.pow(1 - t, 3);

  function mulberry32(a) {
    return function () {
      a |= 0; a = a + 0x6D2B79F5 | 0;
      let t = Math.imul(a ^ a >>> 15, 1 | a);
      t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t;
      return ((t ^ t >>> 14) >>> 0) / 4294967296;
    };
  }

  let dpr = 1;
  let particles = [];
  let density = 'mid';
  let state = 'IDLE';
  let stateT = 0;
  let simT = 0;
  let health = { level: 0, text: '环境正常' };
  let muted = false;
  let ringOpen = false;
  let ringProgress = 0;
  let commands = [];
  let hoverStation = -1;
  let shake = 0;
  let tokenPulse = 0;
  let sparks = [];
  let shocks = [];
  let pointer = { x: CX, y: CY, nx: 0, ny: 0, inside: false };
  let camYaw = .28, camPitch = .18;
  let camYawTarget = .28, camPitchTarget = .18;
  let lastFrame = 0, lastFpsAt = 0, frameCount = 0, fps = 30;
  let opts = {};
  let sprites = {}, coreSprites = {};
  let PX = 0, PY = 0, PS = 1, PZ = 0;

  /* ---------- sprites ---------- */
  function buildSprites() {
    for (const key of Object.keys(RGB)) {
      const c = document.createElement('canvas');
      c.width = c.height = 64;
      const g = c.getContext('2d');
      const grad = g.createRadialGradient(32, 32, 0, 32, 32, 32);
      grad.addColorStop(0, rgba(key, 1));
      grad.addColorStop(.12, rgba(key, .95));
      grad.addColorStop(.38, rgba(key, .32));
      grad.addColorStop(1, rgba(key, 0));
      g.fillStyle = grad;
      g.fillRect(0, 0, 64, 64);
      sprites[key] = c;

      const cc = document.createElement('canvas');
      cc.width = cc.height = 192;
      const cg = cc.getContext('2d');
      const cgrad = cg.createRadialGradient(96, 96, 0, 96, 96, 96);
      cgrad.addColorStop(0, 'rgba(252,254,255,1)');
      cgrad.addColorStop(.08, 'rgba(244,252,255,.96)');
      cgrad.addColorStop(.19, rgba(key, .48));
      cgrad.addColorStop(.44, rgba(key, .13));
      cgrad.addColorStop(1, rgba(key, 0));
      cg.fillStyle = cgrad;
      cg.fillRect(0, 0, 192, 192);
      coreSprites[key] = cc;
    }
  }

  function resize() {
    dpr = Math.min(window.devicePixelRatio || 1, 2.5);
    canvas.width = Math.round(W * dpr);
    canvas.height = Math.round(H * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  }

  /* ---------- particle pool ---------- */
  function buildParticles() {
    const n = DENSITY[density] || DENSITY.mid;
    const rng = mulberry32(0x51ED270B);
    particles = [];
    for (let i = 0; i < n; i++) {
      const p = {
        a: rng() * Math.PI * 2,
        u: rng(), v: rng(), w: rng(),
        phase: rng() * Math.PI * 2,
        kind: i % 4,
        size: .70 + rng() * 1.15,
        alphaBase: .40 + rng() * .55,
        white: rng() < .07,
        x: 0, y: 0, z: 0, tx: 0, ty: 0, tz: 0
      };
      targetIdle(p, 0);
      p.x = p.tx; p.y = p.ty; p.z = p.tz;
      particles.push(p);
    }
    if (opts.onCount) opts.onCount(n);
  }

  /* ---------- state shapes: each writes p.tx / p.ty / p.tz ---------- */
  function targetIdle(p, t) {
    if (p.kind < 3) {
      const d = RING_DEFS[p.kind];
      const a = p.a + t * d.speed;
      const rr = d.r + (p.v - .5) * 3.2 + Math.sin(t * .7 + p.phase) * 1.2;
      const x = Math.cos(a) * rr;
      const z = Math.sin(a) * rr;
      const y = (p.w - .5) * d.thick;
      const y1 = y * d.cx - z * d.sx;
      const z1 = y * d.sx + z * d.cx;
      p.tx = x * d.cy - z1 * d.sy;
      p.ty = y1;
      p.tz = x * d.sy + z1 * d.cy;
    } else {
      const theta = p.a + t * .045;
      const phi = Math.acos(2 * p.v - 1);
      const r = 92 + p.w * 16 + Math.sin(t * .5 + p.phase) * 1.8;
      p.tx = Math.sin(phi) * Math.cos(theta) * r;
      p.ty = Math.cos(phi) * r;
      p.tz = Math.sin(phi) * Math.sin(theta) * r;
    }
  }

  function targetListening(p, t) {
    targetIdle(p, t);
    const lean = 7;
    p.tx = p.tx * 1.05 + pointer.nx * lean;
    p.ty = p.ty * 1.05 - pointer.ny * lean;
    p.tz = p.tz * 1.05;
  }

  function targetThinking(p, t) {
    const u = frac(p.u + t * .18 + p.v * .035);
    const r = 8 + 95 * (1 - u) * (.86 + .14 * Math.sin(p.phase + t * .8));
    const a = p.a + t * 1.5 + u * 6.2;
    p.tx = Math.cos(a) * r;
    p.ty = (u - .5) * 112 + Math.sin(t * 1.2 + p.phase) * 3;
    p.tz = Math.sin(a) * r;
  }

  function targetPlanning(p, t) {
    const layer = Math.floor(p.u * 3);
    const R = 46 + layer * 16;
    const a = p.a + t * (.42 - layer * .12);
    p.tx = Math.cos(a) * R;
    p.ty = (layer - 1) * 34 + Math.sin(t * 1.1 + p.phase) * .8;
    p.tz = Math.sin(a) * R;
  }

  function targetRetrieving(p, t) {
    const theta = p.a + t * .15;
    const phi = Math.acos(2 * p.v - 1);
    const r = 74 + p.w * 14 + Math.sin(t * 2.4 - p.phase) * 6;
    p.tx = Math.sin(phi) * Math.cos(theta) * r;
    p.ty = Math.cos(phi) * r * .9;
    p.tz = Math.sin(phi) * Math.sin(theta) * r;
  }

  function targetTool(p, t) {
    if (p.kind % 2 === 0) {
      const a = p.a + t * 1.5;
      const R = 80 + p.w * 4;
      p.tx = Math.cos(a) * R;
      p.ty = (p.v - .5) * 2 + Math.sin(t * 2 + p.phase) * .6;
      p.tz = Math.sin(a) * R;
    } else {
      const a = p.a - t * 1.1;
      const R = 80 + p.w * 4;
      p.tx = Math.cos(a) * R;
      p.ty = Math.sin(a) * R;
      p.tz = (p.v - .5) * 2;
    }
  }

  function targetWaiting(p, t) {
    const outer = p.u < .78;
    const R = (outer ? 78 : 46) * (1 + .02 * Math.sin(t * 2.2));
    const a = p.a + t * (outer ? .06 : -.09);
    p.tx = Math.cos(a) * R;
    p.ty = (p.v - .5) * 2.2 + Math.sin(t * 1.2 + p.phase) * .7;
    p.tz = Math.sin(a) * R;
  }

  function targetOutput(p, t) {
    if (p.u < .78) {
      const u = frac(p.v + t * .55 + p.w * .12);
      const a = p.a + t * 2.4;
      const r = (1 - u) * 30 * (.4 + p.w);
      p.tx = 8 + u * 184;
      p.ty = Math.cos(a) * r;
      p.tz = Math.sin(a) * r;
    } else {
      const a = -Math.PI + .5 + frac(p.a / (Math.PI * 2)) * (Math.PI * 2 - 1) - t * .2;
      const R = 52 + p.v * 10;
      p.tx = Math.cos(a) * R;
      p.ty = Math.sin(a) * R * .7;
      p.tz = Math.sin(a) * R;
    }
  }

  function targetDone(p, t) {
    const a = p.a + t * .5;
    const R = 80 + (p.v - .5) * 3;
    p.tx = Math.cos(a) * R;
    p.ty = (p.w - .5) * 2.5;
    p.tz = Math.sin(a) * R;
  }

  function targetError(p, t) {
    const theta = p.a * 1.7 + p.phase;
    const phi = Math.acos(2 * p.v - 1);
    const r = 96 + p.w * 56 + Math.sin(t * 9 + p.phase) * 4;
    p.tx = Math.sin(phi) * Math.cos(theta) * r;
    p.ty = Math.cos(phi) * r;
    p.tz = Math.sin(phi) * Math.sin(theta) * r;
  }

  function targetDelegating(p, t) {
    const g = Math.floor(p.u * 10);
    if (g < 6) {
      const theta = p.a + t * .8;
      const phi = Math.acos(2 * p.v - 1);
      const r = 30 + p.w * 10;
      p.tx = Math.sin(phi) * Math.cos(theta) * r;
      p.ty = Math.cos(phi) * r;
      p.tz = Math.sin(phi) * Math.sin(theta) * r;
    } else {
      const sat = g < 8 ? 0 : 1;
      const phase = t * .75 + (sat ? Math.PI : 0);
      const cx = Math.cos(phase) * (sat ? 132 : 118);
      const cz = Math.sin(phase) * (sat ? 132 : 118);
      const cy = sat ? -18 : 18;
      const a = p.a + t * 1.6;
      const R = 16 + p.w * 6;
      p.tx = cx + Math.cos(a) * R;
      p.ty = cy + Math.sin(a) * R * .72;
      p.tz = cz + Math.sin(a) * R;
    }
  }

  function targetSleeping(p, t) {
    const theta = p.a + t * .12;
    const phi = Math.acos(2 * p.v - 1);
    const r = 30 + p.w * 8 + Math.sin(t * .6 + p.phase) * .8;
    p.tx = Math.sin(phi) * Math.cos(theta) * r;
    p.ty = Math.cos(phi) * r;
    p.tz = Math.sin(phi) * Math.sin(theta) * r;
  }

  function targetInterrupted(p) {
    const r = 2 + p.w * 3;
    p.tx = Math.cos(p.a) * r;
    p.ty = (p.v - .5) * 4;
    p.tz = Math.sin(p.a) * r;
  }

  function computeTarget(p, t) {
    switch (state) {
      case 'LISTENING': targetListening(p, t); break;
      case 'THINKING': targetThinking(p, t); break;
      case 'PLANNING': targetPlanning(p, t); break;
      case 'RETRIEVING': targetRetrieving(p, t); break;
      case 'TOOL_CALL': targetTool(p, t); break;
      case 'WAITING': targetWaiting(p, t); break;
      case 'OUTPUT': targetOutput(p, t); break;
      case 'DONE': targetDone(p, t); break;
      case 'ERROR': targetError(p, t); break;
      case 'DELEGATING': targetDelegating(p, t); break;
      case 'SLEEPING': targetSleeping(p, t); break;
      case 'INTERRUPTED': targetInterrupted(p); break;
      default: targetIdle(p, t); break;
    }
  }

  /* ---------- projection ---------- */
  function project(x, y, z) {
    const cy = Math.cos(camYaw), sy = Math.sin(camYaw);
    const x1 = x * cy - z * sy;
    const z1 = x * sy + z * cy;
    const cp = Math.cos(camPitch), sp = Math.sin(camPitch);
    const y1 = y * cp - z1 * sp;
    const z2 = y * sp + z1 * cp;
    const zc = z2 + CAM;
    PS = FOCAL / Math.max(90, zc);
    PX = CX + x1 * PS;
    PY = CY - y1 * PS;
    PZ = z2;
  }

  function dot(x, y, size, key, alpha) {
    if (alpha <= .004) return;
    const s = Math.max(2.5, size * 7.0);
    ctx.globalAlpha = clamp(alpha, 0, 1);
    ctx.drawImage(sprites[key], x - s / 2, y - s / 2, s, s);
  }

  /* ---------- camera ---------- */
  function cameraBase() {
    switch (state) {
      case 'THINKING': return simT * .25;
      case 'RETRIEVING': return simT * .18;
      case 'TOOL_CALL': return simT * .32;
      case 'PLANNING': return simT * .10;
      case 'DELEGATING': return simT * .12;
      case 'LISTENING': return simT * .10;
      case 'WAITING': return Math.sin(simT * .2) * .12;
      case 'OUTPUT': return 0;
      case 'DONE': return .15;
      case 'ERROR': return Math.sin(simT * 15) * .02;
      case 'SLEEPING': return .1;
      case 'PAUSED': return camYaw;
      case 'INTERRUPTED': return simT * .4;
      default: return simT * .12 + .18;
    }
  }

  function updateCamera(dt) {
    const parallax = state === 'OUTPUT' ? .10 : (state === 'PAUSED' ? 0 : .28);
    camYawTarget = cameraBase() + pointer.nx * parallax;
    camPitchTarget = (state === 'OUTPUT' ? .12 : .18) + pointer.ny * parallax * .6;
    if (state === 'ERROR') {
      camYawTarget += Math.sin(simT * 40) * .055 * shake;
      camPitchTarget += Math.cos(simT * 37) * .04 * shake;
    }
    if (state !== 'PAUSED') {
      camYaw += (camYawTarget - camYaw) * Math.min(1, dt * 4.5);
      camPitch += (camPitchTarget - camPitch) * Math.min(1, dt * 4.5);
      shake *= Math.exp(-dt * 3.4);
    }
  }

  /* ---------- state ---------- */
  function setState(name, force) {
    if (!META[name]) return;
    if (name === state && !force) return;
    state = name;
    stateT = 0;
    camYawTarget = cameraBase();
    if (name === 'OUTPUT') { camYaw = 0; camYawTarget = 0; camPitch = .12; camPitchTarget = .12; }
    docEl.style.setProperty('--state', META[name].color);
    setRing(false);
    if (!META[name].transient && opts.onState) opts.onState(name);
    if (name === 'TOOL_CALL') spawnSparks(16, 'white', 46);
    if (name === 'DELEGATING') spawnSparks(14, 'cyan', 54);
    if (name === 'DONE') { spawnSparks(44, 'green', 72); addShock('green', 1); }
    if (name === 'ERROR') { spawnSparks(58, 'red', 90); addShock('red', 1.2); shake = 1; }
    if (name === 'WAITING') addShock('amber', .8);
  }

  function setHealth(level, text) {
    health.level = clamp(level, 0, 2);
    health.text = text || '环境正常';
    docEl.style.setProperty('--health', META.IDLE.color && HEALTH_KEY[health.level] ? `#${RGB[HEALTH_KEY[health.level]].map(v => v.toString(16).padStart(2, '0')).join('')}` : '#70D8FF');
  }

  function setCommands(list) {
    commands = Array.isArray(list) ? list.slice(0, 4) : [];
    if (ringOpen) hideTip();
  }

  function setDensity(d) {
    if (!DENSITY[d] || d === density) return;
    density = d;
    buildParticles();
  }

  function setMuted(v) { muted = !!v; }

  /* ---------- transients ---------- */
  function spawnSparks(n, key, speed) {
    for (let i = 0; i < n; i++) {
      const theta = Math.random() * Math.PI * 2;
      const phi = Math.acos(2 * Math.random() - 1);
      const sp = speed * (.35 + Math.random() * .9);
      sparks.push({
        x: 0, y: 0, z: 0,
        vx: Math.sin(phi) * Math.cos(theta) * sp,
        vy: Math.cos(phi) * sp,
        vz: Math.sin(phi) * Math.sin(theta) * sp,
        age: 0, life: .45 + Math.random() * .55,
        size: .5 + Math.random() * 1.1,
        key: key || 'white'
      });
    }
    if (sparks.length > 180) sparks.splice(0, sparks.length - 180);
  }

  function addShock(key, strength) {
    shocks.push({ age: 0, life: 1.2, key, strength: strength || 1 });
  }

  function outputTick() {
    tokenPulse = Math.min(1.6, tokenPulse + .55);
    const key = COLOR_KEY[META[state].color] || 'cyan';
    sparks.push({
      x: 8, y: (Math.random() - .5) * 10, z: (Math.random() - .5) * 10,
      vx: 130 + Math.random() * 80,
      vy: (Math.random() - .5) * 26,
      vz: (Math.random() - .5) * 26,
      age: 0, life: .35 + Math.random() * .25,
      size: .4 + Math.random() * .8, key
    });
  }

  function notify(kind) {
    const key = kind === 'error' ? 'red' : kind === 'info' ? 'amber' : 'green';
    spawnSparks(kind === 'error' ? 34 : 26, key, 58);
    addShock(key, .8);
  }

  /* ---------- command ring ---------- */
  function stationPos(i) {
    if (i < 0 || i >= commands.length) return { x: CX, y: CY };
    const a = -Math.PI / 2 + i * Math.PI / 2;
    return { x: CX + Math.cos(a) * RING_R, y: CY + Math.sin(a) * RING_R };
  }

  function stationAt(mx, my) {
    if (!ringOpen || ringProgress < .55) return -1;
    let best = -1, bd = 26;
    for (let i = 0; i < commands.length; i++) {
      const p = stationPos(i);
      const d = Math.hypot(mx - p.x, my - p.y);
      if (d < bd) { best = i; bd = d; }
    }
    return best;
  }

  function setRing(open) {
    ringOpen = open;
    wrap.classList.toggle('ring-open', open);
    if (!open) hideTip();
    updateCursor();
  }

  function hideTip() {
    hoverStation = -1;
    tip.classList.remove('show');
  }

  function showTip(i) {
    if (i < 0 || !commands[i]) { hideTip(); return; }
    const p = stationPos(i);
    const scale = canvas.getBoundingClientRect().width / W || 1;
    tip.textContent = commands[i].label || commands[i].key;
    tip.style.left = (p.x * scale) + 'px';
    if (p.y * scale < 50) {
      tip.style.top = ((p.y + 20) * scale) + 'px';
      tip.classList.add('below');
    } else {
      tip.style.top = ((p.y - 20) * scale) + 'px';
      tip.classList.remove('below');
    }
    tip.classList.add('show');
  }

  function updateCursor() {
    if (ringOpen && hoverStation >= 0) canvas.style.cursor = 'pointer';
    else if (ringOpen) canvas.style.cursor = 'default';
    else if (pointer.inside && Math.hypot(pointer.x - CX, pointer.y - CY) < CORE_HIT + 20) canvas.style.cursor = 'pointer';
    else canvas.style.cursor = 'default';
  }

  function canvasPoint(e) {
    const rect = canvas.getBoundingClientRect();
    return {
      x: (e.clientX - rect.left) * (W / Math.max(1, rect.width)),
      y: (e.clientY - rect.top) * (H / Math.max(1, rect.height))
    };
  }

  function onPointerMove(e) {
    const rect = canvas.getBoundingClientRect();
    const p = canvasPoint(e);
    pointer.x = p.x; pointer.y = p.y;
    pointer.inside = e.clientX >= rect.left && e.clientX <= rect.right && e.clientY >= rect.top && e.clientY <= rect.bottom;
    pointer.nx = clamp((e.clientX - (rect.left + rect.width / 2)) / (rect.width / 2 || 1), -1, 1);
    pointer.ny = clamp((e.clientY - (rect.top + rect.height / 2)) / (rect.height / 2 || 1), -1, 1);
    if (ringOpen) {
      const hit = stationAt(p.x, p.y);
      if (hit !== hoverStation) {
        hoverStation = hit;
        if (hit >= 0) showTip(hit); else hideTip();
      }
    }
    updateCursor();
  }

  function onPointerDown(e) {
    if (e.button !== 0) return;
    e.preventDefault();
    const p = canvasPoint(e);
    if (ringOpen) {
      const hit = stationAt(p.x, p.y);
      if (hit >= 0 && commands[hit] && opts.onCommand) opts.onCommand(commands[hit].key);
      setRing(false);
      return;
    }
    if (Math.hypot(p.x - CX, p.y - CY) < CORE_HIT) setRing(true);
  }

  /* ---------- draw helpers ---------- */
  function drawOrbit(radius, plane, centerY, color, alpha) {
    ctx.strokeStyle = rgba(color, alpha);
    ctx.lineWidth = .8;
    ctx.beginPath();
    for (let i = 0; i <= 56; i++) {
      const a = i / 56 * Math.PI * 2;
      let x, y, z;
      if (plane === 'xy') { x = Math.cos(a) * radius; y = Math.sin(a) * radius; z = 0; y += centerY || 0; }
      else if (plane === 'yz') { x = 0; y = Math.cos(a) * radius; z = Math.sin(a) * radius; y += centerY || 0; }
      else { x = Math.cos(a) * radius; y = 0; z = Math.sin(a) * radius; y += centerY || 0; }
      project(x, y, z);
      if (i === 0) ctx.moveTo(PX, PY); else ctx.lineTo(PX, PY);
    }
    ctx.stroke();
  }

  function drawSphereCage(color) {
    drawOrbit(100, 'xz', 0, color, .045);
    drawOrbit(100, 'xy', 0, color, .034);
    drawOrbit(100, 'yz', 0, color, .034);
  }

  function drawIdleRails(color, alpha) {
    ctx.lineWidth = .7;
    for (let k = 0; k < RING_DEFS.length; k++) {
      const d = RING_DEFS[k];
      ctx.strokeStyle = rgba(color, alpha);
      ctx.beginPath();
      for (let i = 0; i <= 56; i++) {
        const a = i / 56 * Math.PI * 2;
        const x = Math.cos(a) * d.r;
        const z = Math.sin(a) * d.r;
        const y = 0;
        const y1 = y * d.cx - z * d.sx;
        const z1 = y * d.sx + z * d.cx;
        const x2 = x * d.cy - z1 * d.sy;
        const z2 = x * d.sy + z1 * d.cy;
        project(x2, y1, z2);
        if (i === 0) ctx.moveTo(PX, PY); else ctx.lineTo(PX, PY);
      }
      ctx.stroke();
    }
  }

  function drawHealth() {
    const key = HEALTH_KEY[health.level] || 'cyan';
    const pulse = health.level === 2 ? .55 + .35 * Math.sin(simT * 4) : .42;
    ctx.strokeStyle = rgba(key, .065);
    ctx.lineWidth = .8;
    ctx.beginPath();
    ctx.arc(CX, CY, HEALTH_R, 0, Math.PI * 2);
    ctx.stroke();
    for (let i = 0; i < 12; i++) {
      const a = -Math.PI / 2 + i * Math.PI / 6;
      const long = i % 3 === 0;
      const r0 = HEALTH_R - (long ? 5 : 2.5);
      const r1 = HEALTH_R + (long ? 4 : 2);
      ctx.strokeStyle = rgba(key, pulse * (long ? 1 : .58));
      ctx.lineWidth = long ? 1 : .7;
      ctx.beginPath();
      ctx.moveTo(CX + Math.cos(a) * r0, CY + Math.sin(a) * r0);
      ctx.lineTo(CX + Math.cos(a) * r1, CY + Math.sin(a) * r1);
      ctx.stroke();
    }
    if (health.level > 0) {
      ctx.fillStyle = rgba(key, .9);
      ctx.beginPath();
      ctx.arc(CX + Math.cos(-Math.PI / 2) * HEALTH_R, CY + Math.sin(-Math.PI / 2) * HEALTH_R, 1.8, 0, Math.PI * 2);
      ctx.fill();
    }
  }

  function drawShocks() {
    for (let i = 0; i < shocks.length; i++) {
      const s = shocks[i];
      const k = clamp(s.age / s.life, 0, 1);
      const r = 28 + easeOut(k) * 118;
      ctx.strokeStyle = rgba(s.key, (1 - k) * .32 * s.strength);
      ctx.lineWidth = 1.1;
      ctx.beginPath();
      ctx.arc(CX, CY, r, 0, Math.PI * 2);
      ctx.stroke();
    }
  }

  function drawScanRings() {
    for (let i = 0; i < 3; i++) {
      const k = ((simT * .55 + i / 3) % 1);
      const r = 20 + k * 96;
      ctx.strokeStyle = rgba('cyan', (1 - k) * .18);
      ctx.lineWidth = .8;
      ctx.beginPath();
      for (let j = 0; j <= 48; j++) {
        const a = j / 48 * Math.PI * 2;
        project(Math.cos(a) * r, 0, Math.sin(a) * r);
        if (j === 0) ctx.moveTo(PX, PY); else ctx.lineTo(PX, PY);
      }
      ctx.stroke();
    }
  }

  function satelliteCenters(t) {
    const sats = [];
    for (let s = 0; s < 2; s++) {
      const phase = t * .75 + (s ? Math.PI : 0);
      sats.push({
        x: Math.cos(phase) * (s ? 112 : 98),
        y: s ? -16 : 16,
        z: Math.sin(phase) * (s ? 112 : 98)
      });
    }
    return sats;
  }

  function drawBeams() {
    const sats = satelliteCenters(simT);
    ctx.strokeStyle = rgba(state === 'DELEGATING' ? 'cyan' : 'cyan', .18);
    ctx.lineWidth = .9;
    for (let i = 0; i < sats.length; i++) {
      const s = sats[i];
      project(s.x, s.y, s.z);
      const sx = PX, sy = PY;
      project(0, 0, 0);
      ctx.beginPath();
      ctx.moveTo(PX, PY);
      ctx.lineTo(sx, sy);
      ctx.stroke();
      ctx.fillStyle = rgba('cyan', .5);
      ctx.beginPath();
      ctx.arc(sx, sy, 1.6, 0, Math.PI * 2);
      ctx.fill();
    }
  }

  function drawWhiskers() {
    if (state !== 'LISTENING' || !pointer.inside) return;
    const dx = pointer.x - CX, dy = pointer.y - CY;
    if (Math.hypot(dx, dy) < 40) return;
    const base = Math.atan2(dy, dx);
    ctx.strokeStyle = rgba('ice', .24);
    ctx.lineWidth = .8;
    for (let i = 0; i < 7; i++) {
      const a = base + (i - 3) * .085;
      for (let k = 0; k < 3; k++) {
        const r = 88 + k * 9;
        const x = CX + Math.cos(a) * r;
        const y = CY + Math.sin(a) * r;
        ctx.fillStyle = rgba('ice', (0.22 - k * .05));
        ctx.beginPath();
        ctx.arc(x, y, 1.1 - k * .2, 0, Math.PI * 2);
        ctx.fill();
      }
    }
  }

  function drawOutputBeam() {
    if (state !== 'OUTPUT') return;
    const grad = ctx.createLinearGradient(CX + 26, 0, W + 30, 0);
    grad.addColorStop(0, rgba('cyan', .18));
    grad.addColorStop(.55, rgba('cyan', .06));
    grad.addColorStop(1, rgba('cyan', 0));
    ctx.strokeStyle = grad;
    ctx.lineWidth = 2.2;
    ctx.beginPath();
    ctx.moveTo(CX + 26, CY);
    ctx.lineTo(W + 32, CY);
    ctx.stroke();
  }

  function drawRing() {
    if (ringProgress < .005) return;
    const p = easeOut(ringProgress);
    const R = RING_R * p;
    const key = COLOR_KEY[META[state].color] || 'cyan';
    ctx.strokeStyle = rgba(key, .22 * p);
    ctx.lineWidth = 1;
    for (let i = 0; i < commands.length; i++) {
      const a = -Math.PI / 2 + i * Math.PI / 2;
      ctx.beginPath();
      ctx.arc(CX, CY, R, a - .5, a + .5);
      ctx.stroke();
    }
    for (let i = 0; i < commands.length; i++) {
      const pos = stationPos(i);
      const hover = hoverStation === i;
      const rad = (15 + (hover ? 2 : 0)) * (.6 + .4 * p);
      ctx.globalAlpha = p;
      ctx.beginPath();
      ctx.arc(pos.x, pos.y, rad, 0, Math.PI * 2);
      ctx.fillStyle = hover ? rgba(key, .18) : 'rgba(4,11,20,.86)';
      ctx.fill();
      ctx.strokeStyle = rgba(key, hover ? .95 : .52);
      ctx.lineWidth = 1;
      ctx.stroke();
      ctx.fillStyle = hover ? '#F4FCFF' : 'rgba(226,246,255,.86)';
      ctx.font = '600 10px "PingFang SC", "SF Pro Text", sans-serif';
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.fillText(commands[i].glyph || '·', pos.x, pos.y + .5);
    }
    ctx.globalAlpha = 1;
  }

  /* ---------- main draw ---------- */
  function draw() {
    ctx.clearRect(0, 0, W, H);
    const accent = COLOR_KEY[META[state].color] || 'cyan';
    const dim = 1 - ringProgress * .48;
    const particleDim = muted ? .42 : 1;

    ctx.globalCompositeOperation = 'source-over';
    drawHealth();
    const railAlpha = state === 'IDLE' || state === 'LISTENING' ? .14 : .07;
    if (state === 'IDLE' || state === 'LISTENING') { drawSphereCage(accent); drawIdleRails(accent, railAlpha); }
    else if (state === 'PLANNING') {
      for (let l = 0; l < 3; l++) drawOrbit(46 + l * 16, 'xz', (l - 1) * 34, accent, .095);
    } else if (state === 'TOOL_CALL') {
      drawOrbit(64, 'xz', 0, accent, .095);
      drawOrbit(80, 'xy', 0, accent, .08);
    } else if (state === 'WAITING') {
      drawOrbit(78, 'xz', 0, 'amber', .09);
    } else if (state === 'DONE') {
      drawOrbit(80, 'xz', 0, 'green', .10);
    } else if (state === 'RETRIEVING') {
      drawOrbit(88, 'xz', 0, accent, .05);
    }

    ctx.globalCompositeOperation = 'lighter';
    if (state === 'RETRIEVING') drawScanRings();
    if (state === 'DELEGATING') drawBeams();

    const k = 1 - Math.exp(-(state === 'INTERRUPTED' ? 16 : state === 'ERROR' ? 10 : state === 'OUTPUT' ? 9 : 7));
    for (let i = 0; i < particles.length; i++) {
      const p = particles[i];
      if (state !== 'PAUSED') {
        computeTarget(p, simT);
        p.x += (p.tx - p.x) * k;
        p.y += (p.ty - p.y) * k;
        p.z += (p.tz - p.z) * k;
      }
      project(p.x, p.y, p.z);
      p.pz = PZ;
      const depth = clamp(1 - (PZ + 140) / 420, .28, 1);
      let alpha = p.alphaBase * depth * dim * particleDim;
      if (state === 'SLEEPING' && i > 34) alpha = 0;
      if (state === 'PAUSED') alpha *= .8;
      let key = p.white ? 'white' : accent;
      if (state === 'DONE' && p.kind === 1) key = 'green';
      if (state === 'ERROR' && p.kind === 0) key = 'white';
      dot(PX, PY, p.size * PS, key, alpha);
    }

    drawCore(accent, dim, particleDim);

    for (let i = 0; i < particles.length; i++) {
      const p = particles[i];
      if (p.pz === undefined || p.pz > -24 || state === 'SLEEPING') continue;
      project(p.x, p.y, p.z);
      const depth = clamp(1 - (PZ + 140) / 420, .28, 1);
      let key = p.white ? 'white' : accent;
      if (state === 'DONE' && p.kind === 1) key = 'green';
      if (state === 'ERROR' && p.kind === 0) key = 'white';
      dot(PX, PY, p.size * PS * .82, key, p.alphaBase * depth * dim * particleDim * .5);
    }

    ctx.globalCompositeOperation = 'lighter';
    for (let i = 0; i < sparks.length; i++) {
      const s = sparks[i];
      project(s.x, s.y, s.z);
      const depth = clamp(1 - (PZ + 140) / 420, .25, 1);
      dot(PX, PY, s.size * PS, s.key, (1 - s.age / s.life) * .8 * depth);
    }
    drawShocks();

    ctx.globalCompositeOperation = 'source-over';
    drawOutputBeam();
    drawWhiskers();
    drawRing();
    ctx.globalAlpha = 1;
  }

  function drawCore(accent, dim, particleDim) {
    project(0, 0, 0);
    const base = state === 'OUTPUT' ? .85 + tokenPulse * .25 : .9;
    const pulseRate = state === 'THINKING' ? 1.1 : state === 'TOOL_CALL' ? .65 : state === 'ERROR' ? .35 : state === 'SLEEPING' ? 5 : 3.2;
    const pulse = 1 + Math.sin(simT * Math.PI * 2 / pulseRate) * (state === 'TOOL_CALL' ? .06 : .035);
    const scale = state === 'SLEEPING' ? .6 : state === 'ERROR' ? .9 : 1;
    const size = 122 * pulse * scale * (1 + tokenPulse * .12);
    const key = accent === 'ice' ? 'ice' : accent;
    ctx.globalAlpha = .9 * dim * (muted ? .6 : 1);
    ctx.drawImage(coreSprites[key], PX - size / 2, PY - size / 2, size, size);
    ctx.globalAlpha = .07 * dim;
    ctx.drawImage(sprites[key], PX - 74, PY - 74, 148, 148);
    ctx.globalAlpha = .95;
    ctx.fillStyle = 'rgba(250,253,255,.96)';
    ctx.beginPath();
    ctx.arc(PX, PY, titleCoreSize(), 0, Math.PI * 2);
    ctx.fill();
    ctx.globalAlpha = 1;
  }

  function titleCoreSize() {
    if (state === 'SLEEPING') return 1.1;
    if (state === 'ERROR') return 1.8;
    if (state === 'TOOL_CALL') return 2.8;
    return 2.4;
  }

  /* ---------- loop ---------- */
  function frame(now) {
    requestAnimationFrame(frame);
    const targetFps = muted ? 8 : (META[state] ? META[state].fps : 30);
    const interval = 1000 / targetFps;
    if (!lastFrame) lastFrame = now;
    if (now - lastFrame < interval - 1) return;
    const dt = Math.min((now - lastFrame) / 1000, .1);
    lastFrame = now;

    const advancing = state !== 'PAUSED';
    if (advancing) {
      simT += dt;
      stateT += dt;
    }
    shake *= Math.exp(-dt * 2.8);
    tokenPulse *= Math.exp(-dt * 8);
    updateCamera(advancing ? dt : 0);
    ringProgress += ((ringOpen ? 1 : 0) - ringProgress) * Math.min(1, dt * 15);
    if (Math.abs(ringProgress - (ringOpen ? 1 : 0)) < .002) ringProgress = ringOpen ? 1 : 0;

    for (let i = 0; i < sparks.length; i++) {
      const s = sparks[i];
      if (!advancing) break;
      s.age += dt;
      s.x += s.vx * dt;
      s.y += s.vy * dt;
      s.z += s.vz * dt;
      s.vx *= .97; s.vy *= .97; s.vz *= .97;
    }
    sparks = sparks.filter(s => s.age < s.life);
    shocks.forEach(s => { s.age += dt; });
    shocks = shocks.filter(s => s.age < s.life);

    draw();

    frameCount++;
    if (now - lastFpsAt > 600) {
      fps = Math.round(frameCount * 1000 / (now - lastFpsAt));
      frameCount = 0;
      lastFpsAt = now;
      if (opts.onFps) opts.onFps(Math.max(1, fps));
    }
  }

  /* ---------- lifecycle ---------- */
  function init(options) {
    opts = options || {};
    for (const d of RING_DEFS) {
      d.cx = Math.cos(d.rx); d.sx = Math.sin(d.rx);
      d.cy = Math.cos(d.ry); d.sy = Math.sin(d.ry);
    }
    buildSprites();
    resize();
    buildParticles();
    setCommands([
      { key: 'new', glyph: '新', label: '新任务' },
      { key: 'demo', glyph: '演', label: '运行演示' },
      { key: 'sleep', glyph: '眠', label: '休眠' },
      { key: 'mute', glyph: '静', label: '静音粒子' }
    ]);
    docEl.style.setProperty('--state', META.IDLE.color);
    document.addEventListener('pointermove', onPointerMove);
    canvas.addEventListener('pointerdown', onPointerDown);
    document.addEventListener('pointerdown', e => {
      if (!wrap.contains(e.target)) setRing(false);
    }, true);
    document.addEventListener('keydown', e => {
      if (e.key === 'Escape') setRing(false);
    });
    window.addEventListener('resize', resize);
    window.addEventListener('blur', () => { pointer.nx = 0; pointer.ny = 0; });
    requestAnimationFrame(frame);
  }

  window.PulseEngine = {
    init, setState, setHealth, setCommands, setDensity, setMuted,
    notify, outputTick, setRing,
    getState: () => state,
    getFPS: () => fps,
    getCount: () => particles.length,
    isRingOpen: () => ringOpen,
    getRingProgress: () => ringProgress,
    getCommands: () => commands.slice(),
    getStationScreenPos: i => {
      const r = canvas.getBoundingClientRect();
      const scale = r.width / W;
      const p = stationPos(i);
      return { x: r.left + p.x * scale, y: r.top + p.y * scale, w: r.width, h: r.height };
    },
    getCamera: () => ({ yaw: camYaw, pitch: camPitch, targetYaw: camYawTarget, nx: pointer.nx, ny: pointer.ny })
  };
})();
