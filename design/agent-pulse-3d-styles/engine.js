/* PULSE 3D style lab — WebGL points + crisp 2D reticle UI. Zero dependencies. */
(function () {
  'use strict';

  const TAU = Math.PI * 2;
  const W = 520, H = 520, CX = 260, CY = 248;
  const FOCAL = 520, CAM = 640;
  const HEALTH_R = 208, CMD_R = 176, ARENA_R = 238, CORE_HIT = 118;
  const DENSITY = { low: .70, mid: 1, high: 1.35 };
  const STYLES = {
    crystal: { key: 'crystal', count: 1600, stars: 170, size: 2.9, soft: .08, rail: .17, trail: 0, white: .08, core: 150, cam: .95, boost: 1.35 },
    nova:    { key: 'nova',    count: 4200, stars: 300, size: 3.5, soft: .40, rail: .035, trail: 0, white: .11, core: 196, cam: .55, boost: 1.05 },
    flux:    { key: 'flux',    count: 1800, stars: 210, size: 1.55, soft: .10, rail: .00, trail: 1, white: .06, core: 148, cam: 1.4, boost: 1.15 }
  };
  const CRYSTAL_RINGS = [
    { R: 105, rx: .35, ry: .10, speed: .26,  thick: 2.4 },
    { R: 150, rx: 1.15, ry: .55, speed: -.18, thick: 3.0 },
    { R: 195, rx: 1.55, ry: .12, speed: .10,  thick: 3.4 }
  ];
  const NOVA_RINGS = [
    { R: 130, rx: .45, ry: .10, speed: .18 },
    { R: 175, rx: 1.10, ry: .65, speed: -.12 },
    { R: 205, rx: 1.50, ry: .20, speed: .08 }
  ];
  const CRYSTAL_THINK = [
    { R: 108, tx: .55, tz: .30, speed: .34 },
    { R: 138, tx: 1.12, tz: -.48, speed: -.26 },
    { R: 166, tx: .22, tz: .95, speed: .18 }
  ];
  CRYSTAL_THINK.forEach(d => {
    d.cx = Math.cos(d.tx); d.sx = Math.sin(d.tx);
    d.cz = Math.cos(d.tz); d.sz = Math.sin(d.tz);
  });
  const NOVA_TILT = {
    cx: Math.cos(1.05), sx: Math.sin(1.05),
    cz: Math.cos(.35), sz: Math.sin(.35)
  };
  const RGB = {
    cyan: [112, 216, 255], ice: [178, 238, 255], white: [226, 246, 255],
    amber: [255, 196, 107], red: [255, 107, 107], green: [120, 226, 172],
    teal: [77, 232, 204], violet: [160, 124, 255], magenta: [255, 107, 214],
    blue: [77, 155, 255],
    muted: [126, 176, 206], dim: [94, 126, 146]
  };
  const WHITE = [.88, .96, 1];
  const STYLE_SHOCK = { crystal: 'ice', nova: 'teal', flux: 'green' };
  const COLOR_KEY = {
    '#70D8FF': 'cyan', '#B2EEFF': 'ice', '#E2F6FF': 'white',
    '#FFC46B': 'amber', '#FF6B6B': 'red', '#78E2AC': 'green',
    '#7EB0CE': 'muted', '#5E7E92': 'dim'
  };
  const HEALTH_KEY = ['cyan', 'amber', 'red'];
  const STYLE_ACCENT_HEX = {
    crystal: ['#C9F4FF', '#4D9BFF', '#9B6BFF'],
    nova: ['#4DE8CC', '#A07CFF', '#FF6BD6', '#70D8FF'],
    flux: ['#6BF0C0', '#70D8FF', '#FF6BD6']
  };
  const STYLE_ACCENT_RGB = {};
  for (const k of Object.keys(STYLE_ACCENT_HEX)) STYLE_ACCENT_RGB[k] = STYLE_ACCENT_HEX[k].map(hexRGB);
  const SEMANTIC_STATES = new Set(['WAITING', 'ERROR', 'DONE', 'PAUSED', 'INTERRUPTED', 'SLEEPING']);
  const META = window.PULSE_STATES;

  const glCanvas = document.getElementById('gl');
  const uiCanvas = document.getElementById('orb');
  const gl = glCanvas.getContext('webgl', { alpha: true, antialias: true, premultipliedAlpha: false, powerPreference: 'low-power' });
  const ui = uiCanvas.getContext('2d');
  const wrap = document.getElementById('orbWrap');
  const tip = document.getElementById('stationTip');
  const docEl = document.documentElement;

  const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
  const frac = v => v - Math.floor(v);
  function hexRGB(hex) {
    const n = parseInt(hex.slice(1), 16);
    return [(n >> 16 & 255) / 255, (n >> 8 & 255) / 255, (n & 255) / 255];
  }
  const rgba = (key, a) => { const c = RGB[key]; return `rgba(${c[0]},${c[1]},${c[2]},${a})`; };
  const easeOut = t => 1 - Math.pow(1 - t, 3);
  const lighten = (c, a) => [c[0] + (1 - c[0]) * a, c[1] + (1 - c[1]) * a, c[2] + (1 - c[2]) * a];
  function currentPalette() {
    if (paletteCache) return paletteCache;
    const sc = hexRGB(META[state].color);
    paletteCache = SEMANTIC_STATES.has(state) ? [sc, lighten(sc, .55), [.9, .97, 1]] : [sc, ...STYLE_ACCENT_RGB[style]];
    return paletteCache;
  }
  function refreshPalette() {
    paletteCache = null;
    stateColor = hexRGB(META[state].color);
    currentPalette();
  }

  function mulberry32(a) {
    return function () {
      a |= 0; a = a + 0x6D2B79F5 | 0;
      let t = Math.imul(a ^ a >>> 15, 1 | a);
      t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t;
      return ((t ^ t >>> 14) >>> 0) / 4294967296;
    };
  }

  let style = (() => {
    const q = new URLSearchParams(location.search).get('style');
    if (STYLES[q]) return q;
    return STYLES[document.body.dataset.style] ? document.body.dataset.style : 'nova';
  })();
  let cfg = STYLES[style];
  let density = 'mid';
  let state = 'IDLE';
  let stateT = 0, simT = 0;
  let health = { level: 0, text: '环境正常' };
  let muted = false;
  let ringOpen = false, ringProgress = 0;
  let commands = [];
  let hoverStation = -1;
  let tokenPulse = 0;
  let stateColor = hexRGB(META.IDLE.color);
  let paletteCache = null;
  let particles = [];
  let stars = [];
  let shocks = [];
  let pointer = { x: CX, y: CY, nx: 0, ny: 0, inside: false };
  let camYaw = .2, camPitch = .18, camYawTarget = .2, camPitchTarget = .18;
  let camCY = Math.cos(.2), camSY = Math.sin(.2), camCP = Math.cos(.18), camSP = Math.sin(.18);
  let userYaw = 0, userPitch = 0, yawVel = 0, pitchVel = 0;
  let zoom = 1, zoomTarget = 1, focal = FOCAL;
  let hoverCore = 0, hoverCoreTarget = 0;
  let pressActive = false, dragging = false, dragDist = 0, downOnCore = false;
  let downAt = 0, lastMoveX = 0, lastMoveY = 0;
  let shake = 0;
  let PX = 0, PY = 0, PS = 1, PZ = 0;
  let lastFrame = 0, lastFpsAt = 0, frames = 0, fps = 60;
  let frameCap = 60, effectiveCap = 60, focused = true, blurAt = 0;
  let frameCost = 1.5;
  let lastShockAt = -9;
  let coreX = CX, coreY = CY;
  let reticleCanvas = null, reticleKey = '';
  let useGL = !!gl;
  let opts = {};
  let dpr = 1;

  /* ---------- shader / buffers ---------- */
  let pointProgram, lineProgram, coreProgram;
  let pointLoc, lineLoc, coreLoc;
  const MAX_POINTS = 8000, MAX_LINE_VERTS = 40000;
  const pointData = new Float32Array(MAX_POINTS * 7);
  const lineData = new Float32Array(MAX_LINE_VERTS * 6);
  let pointBuffer, lineBuffer, coreBuffer;
  let pointCount = 0, lineVertCount = 0;
  const quad = new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]);

  function compileShader(type, source) {
    const sh = gl.createShader(type);
    gl.shaderSource(sh, source);
    gl.compileShader(sh);
    if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) {
      console.error('PULSE shader:', gl.getShaderInfoLog(sh));
      return null;
    }
    return sh;
  }

  function makeProgram(vsSource, fsSource) {
    const vs = compileShader(gl.VERTEX_SHADER, vsSource);
    const fs = compileShader(gl.FRAGMENT_SHADER, fsSource);
    if (!vs || !fs) return null;
    const p = gl.createProgram();
    gl.attachShader(p, vs); gl.attachShader(p, fs); gl.linkProgram(p);
    if (!gl.getProgramParameter(p, gl.LINK_STATUS)) {
      console.error('PULSE link:', gl.getProgramInfoLog(p));
      return null;
    }
    return p;
  }

  function initWebGL() {
    if (!gl) return;
    pointProgram = makeProgram(`
      attribute vec2 a_pos; attribute float a_size; attribute float a_alpha; attribute vec3 a_color;
      varying vec3 v_color; varying float v_alpha;
      void main(){ gl_Position=vec4(a_pos,0.0,1.0); gl_PointSize=a_size; v_alpha=a_alpha; v_color=a_color; }
    `, `
      precision mediump float;
      varying vec3 v_color; varying float v_alpha; uniform float u_soft;
      void main(){
        vec2 p = gl_PointCoord * 2.0 - 1.0;
        float d = length(p);
        if (d > 1.0) discard;
        float core = smoothstep(1.0, 0.58 - u_soft * 0.18, d);
        float halo = (1.0 - smoothstep(0.0, 1.0, d)) * u_soft;
        float a = (core + halo) * v_alpha;
        if (a < 0.006) discard;
        gl_FragColor = vec4(v_color * (0.78 + core * 0.48), a);
      }
    `);
    lineProgram = makeProgram(`
      attribute vec2 a_pos; attribute float a_alpha; attribute vec3 a_color;
      varying vec3 v_color; varying float v_alpha;
      void main(){ gl_Position=vec4(a_pos,0.0,1.0); v_alpha=a_alpha; v_color=a_color; }
    `, `
      precision mediump float;
      varying vec3 v_color; varying float v_alpha; uniform float u_mul;
      void main(){ if(v_alpha<0.004) discard; gl_FragColor=vec4(v_color,v_alpha*u_mul); }
    `);
    coreProgram = makeProgram(`
      attribute vec2 a_pos;
      void main(){ gl_Position=vec4(a_pos,0.0,1.0); }
    `, `
      precision mediump float;
      uniform vec2 u_res; uniform vec2 u_center; uniform float u_radius; uniform vec3 u_color; uniform float u_alpha;
      void main(){
        vec2 p = (gl_FragCoord.xy - u_center) / u_radius;
        float d = length(p);
        if (d > 1.0) discard;
        float core = exp(-d * d * 22.0);
        float halo = pow(max(0.0, 1.0 - d), 3.0);
        float a = (core + halo * 0.36) * u_alpha;
        gl_FragColor = vec4(u_color, a);
      }
    `);
    if (!pointProgram || !lineProgram || !coreProgram) { useGL = false; return; }
    pointLoc = {
      pos: gl.getAttribLocation(pointProgram, 'a_pos'),
      size: gl.getAttribLocation(pointProgram, 'a_size'),
      alpha: gl.getAttribLocation(pointProgram, 'a_alpha'),
      color: gl.getAttribLocation(pointProgram, 'a_color'),
      soft: gl.getUniformLocation(pointProgram, 'u_soft')
    };
    lineLoc = {
      pos: gl.getAttribLocation(lineProgram, 'a_pos'),
      alpha: gl.getAttribLocation(lineProgram, 'a_alpha'),
      color: gl.getAttribLocation(lineProgram, 'a_color'),
      mul: gl.getUniformLocation(lineProgram, 'u_mul')
    };
    coreLoc = {
      pos: gl.getAttribLocation(coreProgram, 'a_pos'),
      res: gl.getUniformLocation(coreProgram, 'u_res'),
      center: gl.getUniformLocation(coreProgram, 'u_center'),
      radius: gl.getUniformLocation(coreProgram, 'u_radius'),
      color: gl.getUniformLocation(coreProgram, 'u_color'),
      alpha: gl.getUniformLocation(coreProgram, 'u_alpha')
    };
    pointBuffer = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, pointBuffer);
    gl.bufferData(gl.ARRAY_BUFFER, pointData, gl.DYNAMIC_DRAW);
    gl.enableVertexAttribArray(pointLoc.pos);
    gl.vertexAttribPointer(pointLoc.pos, 2, gl.FLOAT, false, 28, 0);
    gl.enableVertexAttribArray(pointLoc.size);
    gl.vertexAttribPointer(pointLoc.size, 1, gl.FLOAT, false, 28, 8);
    gl.enableVertexAttribArray(pointLoc.alpha);
    gl.vertexAttribPointer(pointLoc.alpha, 1, gl.FLOAT, false, 28, 12);
    gl.enableVertexAttribArray(pointLoc.color);
    gl.vertexAttribPointer(pointLoc.color, 3, gl.FLOAT, false, 28, 16);

    lineBuffer = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, lineBuffer);
    gl.bufferData(gl.ARRAY_BUFFER, lineData, gl.DYNAMIC_DRAW);
    gl.enableVertexAttribArray(lineLoc.pos);
    gl.vertexAttribPointer(lineLoc.pos, 2, gl.FLOAT, false, 24, 0);
    gl.enableVertexAttribArray(lineLoc.alpha);
    gl.vertexAttribPointer(lineLoc.alpha, 1, gl.FLOAT, false, 24, 8);
    gl.enableVertexAttribArray(lineLoc.color);
    gl.vertexAttribPointer(lineLoc.color, 3, gl.FLOAT, false, 24, 12);

    coreBuffer = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, coreBuffer);
    gl.bufferData(gl.ARRAY_BUFFER, quad, gl.STATIC_DRAW);

    gl.disable(gl.DEPTH_TEST);
    gl.enable(gl.BLEND);
    gl.blendFunc(gl.SRC_ALPHA, gl.ONE);
  }

  function resize() {
    dpr = Math.min(window.devicePixelRatio || 1, 2);
    for (const c of [glCanvas, uiCanvas]) {
      c.width = Math.round(W * dpr);
      c.height = Math.round(H * dpr);
    }
    ui.setTransform(dpr, 0, 0, dpr, 0, 0);
    if (gl) gl.viewport(0, 0, glCanvas.width, glCanvas.height);
  }

  /* ---------- particles ---------- */
  function buildParticles() {
    cfg = STYLES[style] || STYLES.crystal;
    const n = Math.round(cfg.count * (DENSITY[density] || 1));
    const rng = mulberry32(0xA53C9E1 + (style === 'nova' ? 7 : style === 'flux' ? 13 : 3));
    particles = [];
    for (let i = 0; i < n; i++) {
      const p = {
        a: rng() * TAU, u: rng(), v: rng(), w: rng(), phase: rng() * TAU,
        kind: i % (style === 'nova' ? 5 : 3),
        size: .62 + rng() * 1.05,
        alpha: .48 + rng() * .52,
        white: rng() < cfg.white,
        beacon: style === 'crystal' && i % 29 === 0,
        colorIndex: 0, fade: 1, phi: 0, sp: 0, cp: 0,
        x: 0, y: 0, z: 0, tx: 0, ty: 0, tz: 0,
        h0x: 0, h0y: 0, h0z: 0, h1x: 0, h1y: 0, h1z: 0, h2x: 0, h2y: 0, h2z: 0
      };
      p.colorIndex = i % 6 === 0 ? 0 : 1 + (p.kind % (style === 'nova' ? 4 : 3));
      p.phi = Math.acos(2 * p.v - 1);
      p.sp = Math.sin(p.phi);
      p.cp = Math.cos(p.phi);
      target(p, simT);
      p.x = p.tx; p.y = p.ty; p.z = p.tz;
      p.h0x = p.h1x = p.h2x = p.x; p.h0y = p.h1y = p.h2y = p.y; p.h0z = p.h1z = p.h2z = p.z;
      particles.push(p);
    }
    buildStars();
    if (opts.onCount) opts.onCount(n);
  }

  function buildStars() {
    const n = cfg.stars || 180;
    const rng = mulberry32(0x51A7);
    stars = [];
    for (let i = 0; i < n; i++) {
      const theta = rng() * TAU;
      const phi = Math.acos(2 * rng() - 1);
      const r = 290 + rng() * 190;
      stars.push({
        x: Math.sin(phi) * Math.cos(theta) * r,
        y: Math.cos(phi) * r,
        z: Math.sin(phi) * Math.sin(theta) * r,
        size: .6 + rng() * 1.5,
        alpha: .10 + rng() * .36,
        phase: rng() * TAU
      });
    }
  }

  /* ---------- 3D shapes ---------- */
  function ringPos(p, t, R, rx, ry, thick, speed) {
    const a = p.a + t * speed;
    const rr = R + (p.v - .5) * 2.8;
    const x = Math.cos(a) * rr;
    const z = Math.sin(a) * rr;
    const y = (p.w - .5) * thick;
    const cx = Math.cos(rx), sx = Math.sin(rx), cy = Math.cos(ry), sy = Math.sin(ry);
    const y1 = y * cx - z * sx;
    const z1 = y * sx + z * cx;
    p.tx = x * cy - z1 * sy;
    p.ty = y1;
    p.tz = x * sy + z1 * cy;
  }

  function orbitPos(p, t, d, thick) {
    const a = p.a + t * d.speed;
    const rr = d.R + (p.v - .5) * (thick || 3);
    const x = Math.cos(a) * rr;
    const z = Math.sin(a) * rr;
    const y = (p.w - .5) * 2;
    const y1 = y * d.cx - z * d.sx;
    const z1 = y * d.sx + z * d.cx;
    p.tx = x * d.cz - y1 * d.sz;
    p.ty = x * d.sz + y1 * d.cz;
    p.tz = z1;
  }

  function spherePos(p, R, scaleY, theta) {
    const r = R + (p.w - .5) * 16;
    p.tx = p.sp * Math.cos(theta) * r;
    p.ty = p.cp * r * (scaleY || 1);
    p.tz = p.sp * Math.sin(theta) * r;
  }

  function target(p, t) {
    if (style === 'nova') return targetNova(p, t);
    if (style === 'flux') return targetFlux(p, t);
    return targetCrystal(p, t);
  }

  function targetCrystal(p, t) {
    switch (state) {
      case 'IDLE': {
        const d = CRYSTAL_RINGS[p.kind % 3];
        ringPos(p, t, d.R, d.rx, d.ry, d.thick, d.speed);
        break;
      }
      case 'LISTENING': {
        const d = CRYSTAL_RINGS[p.kind % 3];
        ringPos(p, t, d.R, d.rx, d.ry, d.thick, d.speed);
        p.tx = p.tx * 1.04 + pointer.nx * 12;
        p.ty = p.ty * 1.04 - pointer.ny * 12;
        p.tz *= 1.04;
        break;
      }
      case 'THINKING': {
        if (p.u < .18) {
          const a = p.a + t * (1.0 + p.v * .55);
          const r = 30 + p.w * 26 + Math.sin(t * 1.6 + p.phase) * 4;
          p.tx = Math.cos(a) * r;
          p.ty = Math.sin(a * 1.7 + p.phase) * r * .55;
          p.tz = Math.sin(a) * r;
          p.colorIndex = 1;
        } else {
          const ring = p.kind % 3;
          const d = CRYSTAL_THINK[ring];
          orbitPos(p, t, d, 3.4);
          p.colorIndex = 1 + ring;
        }
        break;
      }
      case 'PLANNING': {
        const layer = p.kind % 3;
        const R = 72 + layer * 38;
        const a = p.a + t * (.30 - layer * .06);
        p.tx = Math.cos(a) * R;
        p.ty = (layer - 1) * 52 + Math.sin(t + p.phase) * 1.5;
        p.tz = Math.sin(a) * R;
        break;
      }
      case 'RETRIEVING': {
        const layer = p.kind % 4;
        const R = (74 + layer * 32) * (1 + .025 * Math.sin(t * 2.2 + p.phase));
        const a = p.a + t * (.20 - layer * .03);
        p.tx = Math.cos(a) * R;
        p.ty = (p.v - .5) * 8;
        p.tz = Math.sin(a) * R;
        break;
      }
      case 'TOOL_CALL': {
        const plane = p.kind % 3;
        const R = [92, 124, 154][plane];
        const a = p.a + t * (1.2 - plane * .22);
        if (plane === 0) { p.tx = Math.cos(a) * R; p.ty = Math.sin(a) * R; p.tz = (p.v - .5) * 3; }
        else if (plane === 1) { p.tx = Math.cos(a) * R; p.ty = (p.v - .5) * 3; p.tz = Math.sin(a) * R; }
        else { p.tx = (p.v - .5) * 3; p.ty = Math.cos(a) * R; p.tz = Math.sin(a) * R; }
        break;
      }
      case 'WAITING': {
        const outer = p.u < .8;
        const R = outer ? 150 : 82;
        const a = p.a + t * (outer ? .06 : -.10);
        p.tx = Math.cos(a) * R;
        p.ty = Math.sin(a) * R * .78;
        p.tz = (p.v - .5) * 2.5 + Math.sin(t * 1.2 + p.phase) * .7;
        break;
      }
      case 'OUTPUT': {
        const shell = p.kind % 3;
        const R = [84, 132, 178][shell] + Math.sin(t * 1.5 + shell * 1.3) * 5;
        const th = p.a + t * (.12 + shell * .03);
        p.tx = p.sp * Math.cos(th) * R;
        p.ty = p.cp * R * .92;
        p.tz = p.sp * Math.sin(th) * R;
        p.fade = .5 + .5 * (.5 + .5 * Math.sin(t * 1.6 - shell * 1.4));
        p.colorIndex = 1 + shell;
        break;
      }
      case 'DONE': {
        const a = p.a + t * .5;
        const R = 150 + (p.v - .5) * 3;
        p.tx = Math.cos(a) * R;
        p.ty = (p.w - .5) * 2.2;
        p.tz = Math.sin(a) * R;
        break;
      }
      case 'ERROR': {
        const theta = p.a * 1.7 + p.phase;
        const r = 130 + p.w * 110 + Math.sin(t * 9 + p.phase) * 5;
        p.tx = p.sp * Math.cos(theta) * r;
        p.ty = p.cp * r;
        p.tz = p.sp * Math.sin(theta) * r;
        break;
      }
      case 'DELEGATING': {
        const g = Math.floor(p.u * 10);
        if (g < 6) {
          const theta = p.a + t * .8;
          const r = 55 + p.w * 20;
          p.tx = p.sp * Math.cos(theta) * r;
          p.ty = p.cp * r;
          p.tz = p.sp * Math.sin(theta) * r;
        } else {
          const sat = g < 8 ? 0 : 1;
          const phase = t * .7 + (sat ? Math.PI : 0);
          const cx = Math.cos(phase) * 160;
          const cz = Math.sin(phase) * 160;
          const cy = sat ? -30 : 30;
          const a = p.a + t * 1.6;
          const R = 28 + p.w * 10;
          p.tx = cx + Math.cos(a) * R;
          p.ty = cy + Math.sin(a) * R * .7;
          p.tz = cz + Math.sin(a) * R;
        }
        break;
      }
      case 'SLEEPING': {
        const a = p.a + t * .1;
        const R = p.kind < 2 ? 55 : 85;
        p.tx = Math.cos(a) * R;
        p.ty = (p.v - .5) * 40;
        p.tz = Math.sin(a) * R;
        break;
      }
      case 'INTERRUPTED': {
        const r = 3 + p.w * 4;
        p.tx = Math.cos(p.a) * r;
        p.ty = (p.v - .5) * 6;
        p.tz = Math.sin(p.a) * r;
        break;
      }
      default: {
        const d = CRYSTAL_RINGS[p.kind % 3];
        ringPos(p, t, d.R, d.rx, d.ry, d.thick, d.speed);
      }
    }
  }

  function targetNova(p, t) {
    switch (state) {
      case 'IDLE': {
        if (p.kind < 3) {
          const d = NOVA_RINGS[p.kind];
          ringPos(p, t, d.R, d.rx, d.ry, 3.4, d.speed);
        } else {
          spherePos(p, 145 + p.w * 55, 1, p.a + t * .06);
        }
        break;
      }
      case 'LISTENING': {
        if (p.kind < 3) {
          const d = NOVA_RINGS[p.kind];
          ringPos(p, t, d.R, d.rx, d.ry, 3.4, d.speed);
        } else {
          spherePos(p, 150 + p.w * 55, 1, p.a + t * .06);
        }
        p.tx = p.tx * 1.03 + pointer.nx * 14;
        p.ty = p.ty * 1.03 - pointer.ny * 14;
        p.tz *= 1.03;
        break;
      }
      case 'THINKING': {
        if (p.kind === 4) {
          spherePos(p, 36 + p.w * 20, .9, p.a + t * .8);
          p.colorIndex = 1;
        } else {
          const lane = p.kind % 3;
          const a = p.a + t * (.30 + lane * .04);
          const b = p.phase + t * (.85 + lane * .16) + lane * TAU / 3;
          const R = 128 + 4 * Math.sin(t * .8 + lane);
          const r = 25 + 7 * Math.sin(t * 1.1 + p.phase) + (p.w - .5) * 6;
          const x = (R + r * Math.cos(b)) * Math.cos(a);
          const z = (R + r * Math.cos(b)) * Math.sin(a);
          const y = r * Math.sin(b);
          const cx = NOVA_TILT.cx, sx = NOVA_TILT.sx;
          const y1 = y * cx - z * sx;
          const z1 = y * sx + z * cx;
          const cz = NOVA_TILT.cz, sz = NOVA_TILT.sz;
          p.tx = x * cz - y1 * sz;
          p.ty = x * sz + y1 * cz;
          p.tz = z1;
          p.colorIndex = 1 + lane;
        }
        break;
      }
      case 'PLANNING': {
        if (p.kind === 4) {
          spherePos(p, 155 + p.w * 35, 1, p.a + t * .08);
        } else {
          const layer = p.kind % 3;
          const R = 90 + layer * 40;
          const a = p.a + t * (.22 - layer * .03);
          p.tx = Math.cos(a) * R;
          p.ty = (layer - 1) * 75 + Math.sin(t + p.phase) * 2;
          p.tz = Math.sin(a) * R;
        }
        break;
      }
      case 'RETRIEVING': {
        spherePos(p, 150 + p.w * 50 + Math.sin(t * 2.2 - p.phase) * 8, 1, p.a + t * .1);
        break;
      }
      case 'TOOL_CALL': {
        if (p.kind < 2) {
          const plane = p.kind;
          const R = plane ? 130 : 165;
          const a = p.a + t * (plane ? -1.1 : 1.3);
          if (plane) { p.tx = Math.cos(a) * R; p.ty = Math.sin(a) * R; p.tz = (p.v - .5) * 4; }
          else { p.tx = Math.cos(a) * R; p.ty = (p.v - .5) * 4; p.tz = Math.sin(a) * R; }
        } else {
          spherePos(p, 100 + p.w * 34, 1, p.a + t * .3);
        }
        break;
      }
      case 'WAITING': {
        if (p.kind >= 3) {
          spherePos(p, 130 + p.w * 40, 1, p.a + t * .03);
        } else {
          const a = p.a + t * .06;
          const R = 165;
          p.tx = Math.cos(a) * R;
          p.ty = (p.v - .5) * 3 + Math.sin(t + p.phase) * 1;
          p.tz = Math.sin(a) * R;
        }
        break;
      }
      case 'OUTPUT': {
        if (p.kind === 0 || p.kind === 1) {
          const a = p.a + t * .16;
          ringPos(p, t, 130, .45, .10, 2.2, .16);
          p.fade = .78 + .22 * Math.sin(a - t * .8);
          p.colorIndex = 1;
        } else if (p.kind === 2) {
          const a = p.a + t * -.10;
          ringPos(p, t, 176, 1.12, .62, 2.0, -.10);
          p.fade = .72 + .24 * Math.sin(a + t * .55);
          p.colorIndex = 2;
        } else if (p.kind === 3) {
          const th = p.a + t * .05;
          const R = 190 + (p.w - .5) * 6;
          p.tx = p.sp * Math.cos(th) * R;
          p.ty = p.cp * R * .9;
          p.tz = p.sp * Math.sin(th) * R;
          p.fade = .36;
          p.colorIndex = 0;
        } else {
          const group = Math.floor(p.u * 3);
          const ph = frac(simT * .16 + group / 3);
          const R = 54 + ph * 168 + (p.w - .5) * 3;
          const a = p.a + t * .04;
          const x = Math.cos(a) * R;
          const z = Math.sin(a) * R;
          const y = (p.w - .5) * 2;
          const cx = Math.cos(.55), sx = Math.sin(.55);
          p.tx = x;
          p.ty = y * cx - z * sx;
          p.tz = y * sx + z * cx;
          p.fade = Math.max(.02, Math.sin(ph * Math.PI)) * .78;
          p.colorIndex = 0;
        }
        break;
      }
      case 'DONE': {
        if (p.kind === 4) {
          spherePos(p, 140 + p.w * 30, 1, p.a + t * .15);
        } else {
          const a = p.a + t * .4;
          const R = 170 + (p.v - .5) * 4;
          p.tx = Math.cos(a) * R;
          p.ty = (p.w - .5) * 2.5;
          p.tz = Math.sin(a) * R;
        }
        break;
      }
      case 'ERROR': {
        const theta = p.a * 1.7 + p.phase;
        const r = 140 + p.w * 120 + Math.sin(t * 9 + p.phase) * 6;
        p.tx = p.sp * Math.cos(theta) * r;
        p.ty = p.cp * r;
        p.tz = p.sp * Math.sin(theta) * r;
        break;
      }
      case 'DELEGATING': {
        const g = Math.floor(p.u * 10);
        if (g < 6) {
          spherePos(p, 64 + p.w * 24, 1, p.a + t * .5);
        } else {
          const sat = g < 8 ? 0 : 1;
          const phase = t * .7 + (sat ? Math.PI : 0);
          const cx = Math.cos(phase) * 175;
          const cz = Math.sin(phase) * 175;
          const cy = sat ? -32 : 32;
          const theta = p.a + t * 1.4;
          const rr = 34 + p.w * 12;
          p.tx = cx + p.sp * Math.cos(theta) * rr;
          p.ty = cy + p.cp * rr;
          p.tz = cz + p.sp * Math.sin(theta) * rr;
        }
        break;
      }
      case 'SLEEPING': {
        spherePos(p, 62 + p.w * 20, 1, p.a + t * .05);
        break;
      }
      case 'INTERRUPTED': {
        const r = 3 + p.w * 5;
        p.tx = Math.cos(p.a) * r;
        p.ty = (p.v - .5) * 7;
        p.tz = Math.sin(p.a) * r;
        break;
      }
      default: {
        if (p.kind < 3) {
          const d = NOVA_RINGS[p.kind];
          ringPos(p, t, d.R, d.rx, d.ry, 3.4, d.speed);
        } else spherePos(p, 145 + p.w * 55, 1, p.a + t * .06);
      }
    }
  }

  function targetFlux(p, t) {
    switch (state) {
      case 'IDLE':
      case 'LISTENING': {
        const strand = p.kind % 3;
        const u = frac(p.u + t * .05);
        const a = strand * TAU / 3 + u * TAU * 1.7 + t * .8 + (p.a - Math.PI) * .075;
        const R = 126 + 20 * Math.sin(u * TAU * 1.7 + p.phase);
        p.tx = Math.cos(a) * R;
        p.ty = (u - .5) * 280;
        p.tz = Math.sin(a) * R;
        if (state === 'LISTENING') {
          p.tx = p.tx * 1.03 + pointer.nx * 14;
          p.ty = p.ty * 1.03 - pointer.ny * 14;
          p.tz *= 1.03;
        }
        break;
      }
      case 'THINKING': {
        const ph = (p.u + t * .055) * TAU;
        if (p.u > .9) {
          const a = p.a + t * .35;
          const R = 172 + (p.v - .5) * 4;
          p.tx = Math.cos(a) * R;
          p.ty = (p.w - .5) * 2;
          p.tz = Math.sin(a) * R;
        } else {
          const strand = p.kind % 3;
          const rad = 96 + 16 * Math.sin(ph * 2 + p.phase) + (p.w - .5) * 10;
          const a = ph * 1.35 + strand * TAU / 3 + (p.v - .5) * .5;
          p.tx = Math.cos(a) * rad;
          p.ty = Math.sin(ph) * 112;
          p.tz = Math.sin(a) * rad;
          p.colorIndex = 1 + strand;
        }
        break;
      }
      case 'PLANNING': {
        const layer = p.kind % 3;
        const a = p.a + t * .35;
        const R = 150;
        p.tx = Math.cos(a) * R;
        p.ty = (layer - 1) * 70 + Math.sin(a * 2 + t) * 18;
        p.tz = Math.sin(a) * R;
        break;
      }
      case 'RETRIEVING': {
        const u = frac(p.v + t * .35);
        const R = 20 + u * 220;
        const a = p.a + (p.kind % 3) * TAU / 3;
        p.tx = Math.cos(a) * R;
        p.ty = Math.sin(u * TAU + p.phase) * 50;
        p.tz = Math.sin(a) * R;
        break;
      }
      case 'TOOL_CALL': {
        const R = 140;
        const a = p.a + t * 1.3;
        p.tx = Math.cos(a) * R;
        p.ty = Math.sin(a * 2 + p.phase) * 80;
        p.tz = Math.sin(a) * R;
        break;
      }
      case 'WAITING': {
        const a = p.a + t * .12;
        const R = 155;
        p.tx = Math.cos(a) * R;
        p.ty = Math.sin(a * 3 + t) * 30;
        p.tz = Math.sin(a) * R;
        break;
      }
      case 'OUTPUT': {
        if (p.u > .94) {
          const a = p.a + t * 1.2;
          p.tx = Math.cos(a) * 22;
          p.ty = (p.w - .5) * 2;
          p.tz = Math.sin(a) * 22;
        } else {
          const arm = p.kind % 3;
          const u = frac(p.v + t * .30);
          p.fade = Math.max(.02, Math.sin(u * Math.PI));
          const r = 24 + u * 212;
          const a = arm * TAU / 3 + u * 2.8 + t * .12 + (p.a - Math.PI) * .04;
          p.tx = Math.cos(a) * r;
          p.ty = Math.sin(u * TAU * .5 + p.phase) * 18 * (1 - u) + (p.w - .5) * 8;
          p.tz = Math.sin(a) * r;
          p.colorIndex = 1 + arm;
        }
        break;
      }
      case 'DONE': {
        const a = p.a + t * .45;
        const R = 160;
        p.tx = Math.cos(a) * R;
        p.ty = Math.sin(a * 2 + p.phase) * 25;
        p.tz = Math.sin(a) * R;
        break;
      }
      case 'ERROR': {
        const theta = p.a * 1.7 + p.phase;
        const r = 130 + p.w * 120 + Math.sin(t * 8 + p.phase) * 6;
        p.tx = p.sp * Math.cos(theta) * r;
        p.ty = p.cp * r;
        p.tz = p.sp * Math.sin(theta) * r;
        break;
      }
      case 'DELEGATING': {
        const g = p.kind % 3;
        const phase = t * .7 + g * TAU / 3;
        const cx = Math.cos(phase) * 145;
        const cz = Math.sin(phase) * 145;
        const a = p.a + t * 1.6;
        const R = 42;
        p.tx = cx + Math.cos(a) * R;
        p.ty = Math.sin(a) * R * .8;
        p.tz = cz + Math.sin(a) * R;
        break;
      }
      case 'SLEEPING': {
        const u = frac(p.u + t * .02);
        const a = p.a + t * .15;
        const R = 80;
        p.tx = Math.cos(a) * R;
        p.ty = (u - .5) * 110;
        p.tz = Math.sin(a) * R;
        break;
      }
      case 'INTERRUPTED': {
        const r = 3 + p.w * 4;
        p.tx = Math.cos(p.a) * r;
        p.ty = (p.v - .5) * 6;
        p.tz = Math.sin(p.a) * r;
        break;
      }
      default: {
        const strand = p.kind % 3;
        const u = frac(p.u + t * .05);
        const a = strand * TAU / 3 + u * TAU * 1.7 + t * .8 + (p.a - Math.PI) * .075;
        const R = 126 + 20 * Math.sin(u * TAU * 1.7 + p.phase);
        p.tx = Math.cos(a) * R;
        p.ty = (u - .5) * 280;
        p.tz = Math.sin(a) * R;
      }
    }
  }

  /* ---------- camera / projection ---------- */
  function baseYaw() {
    switch (state) {
      case 'OUTPUT': return .38 + Math.sin(simT * .12) * .10;
      case 'THINKING': return simT * (style === 'flux' ? .28 : .22) + .2;
      case 'TOOL_CALL': return simT * (style === 'flux' ? .3 : .24) + .1;
      case 'PLANNING': return simT * .14 + .2;
      case 'DELEGATING': return simT * .12 + .2;
      case 'WAITING': return Math.sin(simT * .2) * .12;
      case 'ERROR': return Math.sin(simT * 16) * .02;
      case 'PAUSED': return camYaw;
      default: return simT * (style === 'flux' ? .18 : style === 'nova' ? .05 : .1) + .2;
    }
  }

  function updateCamera(dt) {
    const parallax = state === 'OUTPUT' ? .10 : (style === 'flux' ? .4 : .3);
    if (!dragging && (Math.abs(yawVel) > .002 || Math.abs(pitchVel) > .002)) {
      userYaw += yawVel * dt;
      userPitch = clamp(userPitch + pitchVel * dt, -.55, .55);
      const damp = Math.exp(-dt * 4.5);
      yawVel *= damp; pitchVel *= damp;
    }
    camYawTarget = baseYaw() + userYaw + pointer.nx * parallax * (dragging ? .2 : 1);
    const basePitch = state === 'OUTPUT' ? .33 : .18;
    camPitchTarget = clamp(basePitch + userPitch + pointer.ny * parallax * .55, -.48, .72);
    if (state === 'ERROR') {
      camYawTarget += Math.sin(simT * 40) * .05 * shake;
      camPitchTarget += Math.cos(simT * 37) * .04 * shake;
    }
    if (state !== 'PAUSED') {
      camYaw += (camYawTarget - camYaw) * Math.min(1, dt * 4.2);
      camPitch += (camPitchTarget - camPitch) * Math.min(1, dt * 4.2);
      shake *= Math.exp(-dt * 3.2);
    }
  }

  function project(x, y, z) {
    const x1 = x * camCY - z * camSY;
    const z1 = x * camSY + z * camCY;
    const y1 = y * camCP - z1 * camSP;
    const z2 = y * camSP + z1 * camCP;
    const zc = z2 + CAM;
    PS = focal / Math.max(150, zc);
    PX = CX + x1 * PS;
    PY = CY - y1 * PS;
    PZ = z2;
  }

  /* ---------- point / line buffers ---------- */
  function pushPoint(x, y, size, alpha, r, g, b) {
    if (pointCount >= MAX_POINTS || alpha <= .008 || size <= .1) return;
    const x1 = (x / W) * 2 - 1;
    const y1 = 1 - (y / H) * 2;
    const i = pointCount * 7;
    pointData[i] = x1; pointData[i + 1] = y1;
    pointData[i + 2] = size * dpr;
    pointData[i + 3] = alpha;
    pointData[i + 4] = r; pointData[i + 5] = g; pointData[i + 6] = b;
    pointCount++;
  }

  function pushLine(x1, y1, z1, x2, y2, z2, a1, a2, r, g, b) {
    if (lineVertCount + 2 > MAX_LINE_VERTS) return;
    project(x1, y1, z1);
    if (!isFinite(PX) || !isFinite(PY)) return;
    let i = lineVertCount * 6;
    lineData[i] = (PX / W) * 2 - 1;
    lineData[i + 1] = 1 - (PY / H) * 2;
    lineData[i + 2] = a1;
    lineData[i + 3] = r; lineData[i + 4] = g; lineData[i + 5] = b;
    project(x2, y2, z2);
    if (!isFinite(PX) || !isFinite(PY)) return;
    i += 6;
    lineData[i] = (PX / W) * 2 - 1;
    lineData[i + 1] = 1 - (PY / H) * 2;
    lineData[i + 2] = a2;
    lineData[i + 3] = r; lineData[i + 4] = g; lineData[i + 5] = b;
    lineVertCount += 2;
  }

  function addCircle(R, rx, ry, alpha, color) {
    const c = color || stateColor;
    const steps = 64;
    const cx = Math.cos(rx), sx = Math.sin(rx), cy = Math.cos(ry), sy = Math.sin(ry);
    let px = 0, py = 0, pz = 0;
    for (let i = 0; i <= steps; i++) {
      const a = i / steps * TAU;
      const x = Math.cos(a) * R;
      const z = Math.sin(a) * R;
      const y1 = -z * sx;
      const z1 = z * cx;
      const qx = x * cy - z1 * sy;
      const qy = y1;
      const qz = x * sy + z1 * cy;
      if (i > 0) pushLine(px, py, pz, qx, qy, qz, alpha, alpha, c[0], c[1], c[2]);
      px = qx; py = qy; pz = qz;
    }
  }

  function addOrbitCircle(R, tiltX, tiltZ, alpha, color) {
    const c = color || stateColor;
    const steps = 64;
    const cx = Math.cos(tiltX), sx = Math.sin(tiltX);
    const cz = Math.cos(tiltZ), sz = Math.sin(tiltZ);
    let px = 0, py = 0, pz = 0;
    for (let i = 0; i <= steps; i++) {
      const a = i / steps * TAU;
      const x = Math.cos(a) * R;
      const z = Math.sin(a) * R;
      const y1 = -z * sx;
      const z1 = z * cx;
      const qx = x * cz - y1 * sz;
      const qy = x * sz + y1 * cz;
      if (i > 0) pushLine(px, py, pz, qx, qy, z1, alpha, alpha, c[0], c[1], c[2]);
      px = qx; py = qy; pz = z1;
    }
  }

  function addCircleAt(cx0, cy0, cz0, R, plane, alpha, color) {
    const c = color || stateColor;
    const steps = 40;
    for (let i = 0; i < steps; i++) {
      const a0 = i / steps * TAU, a1 = (i + 1) / steps * TAU;
      let x0, y0, z0, x1, y1, z1;
      if (plane === 'xy') { x0 = Math.cos(a0) * R; y0 = Math.sin(a0) * R; z0 = 0; x1 = Math.cos(a1) * R; y1 = Math.sin(a1) * R; z1 = 0; }
      else if (plane === 'yz') { x0 = 0; y0 = Math.cos(a0) * R; z0 = Math.sin(a0) * R; x1 = 0; y1 = Math.cos(a1) * R; z1 = Math.sin(a1) * R; }
      else { x0 = Math.cos(a0) * R; y0 = 0; z0 = Math.sin(a0) * R; x1 = Math.cos(a1) * R; y1 = 0; z1 = Math.sin(a1) * R; }
      pushLine(cx0 + x0, cy0 + y0, cz0 + z0, cx0 + x1, cy0 + y1, cz0 + z1, alpha, alpha, c[0], c[1], c[2]);
    }
  }

  function buildRails() {
    const a = cfg.rail;
    if (!a || style === 'flux') return;
    const palette = currentPalette();
    const semantic = SEMANTIC_STATES.has(state);
    const railColor = idx => semantic ? palette[1] : palette[1 + (idx % (palette.length - 1))];
    if (style === 'crystal') {
      if (state === 'IDLE' || state === 'LISTENING') {
        CRYSTAL_RINGS.forEach((d, k) => addCircle(d.R, d.rx, d.ry, .17, railColor(k)));
      } else if (state === 'THINKING') {
        CRYSTAL_THINK.forEach((d, k) => addOrbitCircle(d.R, d.tx, d.tz, .10, railColor(k)));
        addCircleAt(0, 0, 0, 52, 'xy', .05, railColor(0));
      } else if (state === 'OUTPUT') {
        addCircleAt(0, 0, 0, 178, 'xy', .045, railColor(0));
        addCircleAt(0, 0, 0, 178, 'xz', .04, railColor(1));
        addOrbitCircle(132, .9, .2, .03, railColor(2));
        for (let k = 0; k < 3; k++) {
          const ph = frac(simT * .18 + k / 3);
          addCircleAt(0, 0, 0, 50 + ph * 150, 'xz', .13 * (1 - ph), railColor(k));
        }
      } else if (state === 'PLANNING') {
        for (let l = 0; l < 3; l++) addCircleAt(0, (l - 1) * 52, 0, 72 + l * 38, 'xz', .10, railColor(l));
      } else if (state === 'TOOL_CALL') {
        addCircleAt(0, 0, 0, 92, 'xy', .09, railColor(0));
        addCircleAt(0, 0, 0, 124, 'xz', .09, railColor(1));
        addCircleAt(0, 0, 0, 154, 'yz', .09, railColor(2));
      } else if (state === 'WAITING') {
        addCircleAt(0, 0, 0, 150, 'xy', .10, palette[0]);
        addCircleAt(0, 0, 0, 82, 'xy', .07, palette[1]);
      } else if (state === 'DONE') {
        addCircle(150, 0, 0, .12, palette[0]);
      } else if (state === 'RETRIEVING') {
        for (let l = 0; l < 4; l++) addCircleAt(0, 0, 0, 74 + l * 32, 'xz', .07, railColor(l));
      } else if (state === 'DELEGATING') {
        addCircleAt(0, 0, 0, 55, 'xz', .08, palette[0]);
        for (let s = 0; s < 2; s++) {
          const phase = simT * .7 + (s ? Math.PI : 0);
          addCircleAt(Math.cos(phase) * 160, s ? -30 : 30, Math.sin(phase) * 160, 28, 'xz', .08, railColor(s + 1));
        }
      }
    } else if (style === 'nova') {
      if (state === 'IDLE' || state === 'LISTENING') {
        addCircle(205, 0, 0, .05, railColor(0));
        addCircle(225, 1.0, .4, .035, railColor(1));
      } else if (state === 'THINKING') {
        addOrbitCircle(128, 1.05, .35, .05, railColor(0));
        addCircleAt(0, 0, 0, 42, 'xy', .035, railColor(1));
      } else if (state === 'OUTPUT') {
        addCircle(130, .45, .10, .06, railColor(0));
        addCircle(176, 1.12, .62, .045, railColor(1));
      } else if (state === 'PLANNING') {
        for (let l = 0; l < 3; l++) addCircleAt(0, (l - 1) * 75, 0, 90 + l * 40, 'xz', .05, railColor(l));
      } else if (state === 'TOOL_CALL') {
        addCircleAt(0, 0, 0, 165, 'xz', .045, railColor(0));
        addCircleAt(0, 0, 0, 130, 'xy', .045, railColor(1));
      } else if (state === 'WAITING') {
        addCircle(165, 0, 0, .06, palette[0]);
      } else if (state === 'DONE') {
        addCircle(170, 0, 0, .08, palette[0]);
      } else if (state === 'DELEGATING') {
        for (let s = 0; s < 2; s++) {
          const phase = simT * .7 + (s ? Math.PI : 0);
          addCircleAt(Math.cos(phase) * 175, s ? -32 : 32, Math.sin(phase) * 175, 34, 'xz', .055, railColor(s + 1));
        }
      }
    }
  }

  /* ---------- update / draw ---------- */
  function buildFrame(dt) {
    pointCount = 0;
    lineVertCount = 0;
    camCY = Math.cos(camYaw); camSY = Math.sin(camYaw);
    camCP = Math.cos(camPitch); camSP = Math.sin(camPitch);
    const dimRing = 1 - ringProgress * .52;
    const dimMute = muted ? .45 : 1;
    const dimPause = state === 'PAUSED' ? .82 : 1;
    const dim = dimRing * dimMute * dimPause;
    const palette = currentPalette();

    // stars first (additive, no depth sorting)
    for (const s of stars) {
      project(s.x, s.y, s.z);
      if (PX < -30 || PX > W + 30 || PY < -30 || PY > H + 30) continue;
      const depth = clamp(1 - (PZ + 200) / 640, .15, 1);
      const tw = .75 + .25 * Math.sin(simT * 1.4 + s.phase);
      pushPoint(PX, PY, s.size * (.7 + PS * .3), s.alpha * depth * tw * dimMute, .72, .9, 1);
    }

    const k = 1 - Math.exp(-(state === 'INTERRUPTED' ? 16 : state === 'ERROR' ? 10 : state === 'OUTPUT' ? 9 : 7) * dt);
    const visible = state === 'SLEEPING' ? Math.min(60, particles.length) : particles.length;
    for (let i = 0; i < particles.length; i++) {
      const p = particles[i];
      if (state !== 'PAUSED') {
        const px = p.tx, py = p.ty, pz = p.tz;
        p.fade = 1;
        target(p, simT);
        if (hoverCore > .01) {
          const r2 = p.tx * p.tx + p.ty * p.ty + p.tz * p.tz;
          if (r2 < 22500) {
            const w = hoverCore * (1 - r2 / 22500) * 8;
            p.tx += pointer.nx * w;
            p.ty -= pointer.ny * w;
          }
        }
        const jx = p.tx - px, jy = p.ty - py, jz = p.tz - pz;
        // flux 的 u 参数回绕会让目标点瞬移；此时直接落位并清空轨迹，避免拉出穿过核心的长线
        if (style === 'flux' && stateT > .45 && jx * jx + jy * jy + jz * jz > 12100) {
          p.x = p.tx; p.y = p.ty; p.z = p.tz;
          p.h0x = p.h1x = p.h2x = p.x;
          p.h0y = p.h1y = p.h2y = p.y;
          p.h0z = p.h1z = p.h2z = p.z;
        } else {
          p.x += (p.tx - p.x) * k;
          p.y += (p.ty - p.y) * k;
          p.z += (p.tz - p.z) * k;
        }
        if (style === 'flux') {
          p.h2x = p.h1x; p.h2y = p.h1y; p.h2z = p.h1z;
          p.h1x = p.h0x; p.h1y = p.h0y; p.h1z = p.h0z;
          p.h0x = p.x; p.h0y = p.y; p.h0z = p.z;
        }
      }
      if (i >= visible) continue;
      project(p.x, p.y, p.z);
      const depth = clamp(1 - (PZ + 210) / 620, .15, 1);
      let alpha = p.alpha * depth * dim * (cfg.boost || 1) * p.fade;
      if (state === 'WAITING') alpha *= .85;
      if (state === 'SLEEPING') alpha *= .55;
      let size = p.size * cfg.size * (.72 + PS * .42);
      if (p.beacon) size *= 1.55;
      const c = p.white || p.beacon ? WHITE : palette[p.colorIndex % palette.length];
      pushPoint(PX, PY, size, alpha, c[0], c[1], c[2]);
    }

    // flux trails
    if (style === 'flux' && state !== 'PAUSED') {
      const ta = (state === 'THINKING' ? .65 : .78) * dim;
      const tail = state === 'OUTPUT' ? 18 : state === 'ERROR' ? 7 : state === 'THINKING' ? 11 : 14;
      for (let i = 0; i < visible; i++) {
        const p = particles[i];
        if (p.fade < .05) continue;
        const c = p.white ? WHITE : palette[p.colorIndex % palette.length];
        let dx = p.x - p.h1x, dy = p.y - p.h1y, dz = p.z - p.h1z;
        const d2 = dx * dx + dy * dy + dz * dz;
        if (d2 < .0025) continue;
        if (d2 > 1600) {
          const s = 40 / Math.sqrt(d2);
          dx *= s; dy *= s; dz *= s;
        }
        project(p.x, p.y, p.z);
        const ad = clamp(1 - (PZ + 210) / 620, .15, 1) * p.fade;
        pushLine(p.x, p.y, p.z, p.x - dx * tail, p.y - dy * tail, p.z - dz * tail,
          ta * ad, ta * ad * .015, c[0], c[1], c[2]);
      }
    }

    buildRails();

    // core
    const pulseRate = state === 'THINKING' ? 1.1 : state === 'TOOL_CALL' ? .65 : state === 'WAITING' ? 2.8 : state === 'ERROR' ? .35 : state === 'SLEEPING' ? 5 : 3.2;
    const pulse = 1 + Math.sin(simT * TAU / pulseRate) * .035;
    coreX = CX + pointer.nx * hoverCore * 8;
    coreY = CY + pointer.ny * hoverCore * 8;
    const coreRadius = cfg.core * (.86 + .14 * pulse) * (1 + tokenPulse * .14) * (state === 'SLEEPING' ? .6 : 1) * (state === 'OUTPUT' && style === 'nova' ? .84 : 1) * (1 + hoverCore * .10) * zoom;
    coreUniform = {
      center: [coreX * dpr, (H - coreY) * dpr],
      radius: coreRadius * dpr,
      color: stateColor,
      alpha: (.95 * dim) * (muted ? .6 : 1) * (1 + hoverCore * .22) + tokenPulse * .05
    };
    if (state === 'OUTPUT' && simT - lastShockAt > 1.15) {
      lastShockAt = simT;
      addShock(STYLE_SHOCK[style], style === 'nova' ? .18 : .26);
    }
  }

  let coreUniform = null;

  function drawGL() {
    if (!useGL) return;
    gl.clearColor(0, 0, 0, 0);
    gl.clear(gl.COLOR_BUFFER_BIT);
    gl.enable(gl.BLEND);
    gl.blendFunc(gl.SRC_ALPHA, gl.ONE);

    if (pointCount > 0) {
      gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
      gl.useProgram(pointProgram);
      gl.uniform1f(pointLoc.soft, cfg.soft);
      gl.bindBuffer(gl.ARRAY_BUFFER, pointBuffer);
      gl.bufferSubData(gl.ARRAY_BUFFER, 0, pointData.subarray(0, pointCount * 7));
      gl.enableVertexAttribArray(pointLoc.pos);
      gl.vertexAttribPointer(pointLoc.pos, 2, gl.FLOAT, false, 28, 0);
      gl.enableVertexAttribArray(pointLoc.size);
      gl.vertexAttribPointer(pointLoc.size, 1, gl.FLOAT, false, 28, 8);
      gl.enableVertexAttribArray(pointLoc.alpha);
      gl.vertexAttribPointer(pointLoc.alpha, 1, gl.FLOAT, false, 28, 12);
      gl.enableVertexAttribArray(pointLoc.color);
      gl.vertexAttribPointer(pointLoc.color, 3, gl.FLOAT, false, 28, 16);
      gl.drawArrays(gl.POINTS, 0, pointCount);
    }

    if (lineVertCount > 0) {
      gl.useProgram(lineProgram);
      gl.bindBuffer(gl.ARRAY_BUFFER, lineBuffer);
      gl.bufferSubData(gl.ARRAY_BUFFER, 0, lineData.subarray(0, lineVertCount * 6));
      gl.enableVertexAttribArray(lineLoc.pos);
      gl.vertexAttribPointer(lineLoc.pos, 2, gl.FLOAT, false, 24, 0);
      gl.enableVertexAttribArray(lineLoc.alpha);
      gl.vertexAttribPointer(lineLoc.alpha, 1, gl.FLOAT, false, 24, 8);
      gl.enableVertexAttribArray(lineLoc.color);
      gl.vertexAttribPointer(lineLoc.color, 3, gl.FLOAT, false, 24, 12);
      if (style === 'flux') {
        // flux trails: opaque base keeps hue, low additive pass restores glow
        gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
        gl.uniform1f(lineLoc.mul, 1);
        gl.drawArrays(gl.LINES, 0, lineVertCount);
        gl.blendFunc(gl.SRC_ALPHA, gl.ONE);
        gl.uniform1f(lineLoc.mul, .34);
        gl.drawArrays(gl.LINES, 0, lineVertCount);
      } else {
        gl.blendFunc(gl.SRC_ALPHA, gl.ONE);
        gl.uniform1f(lineLoc.mul, 1);
        gl.drawArrays(gl.LINES, 0, lineVertCount);
      }
    }

    if (coreUniform) {
      gl.useProgram(coreProgram);
      gl.bindBuffer(gl.ARRAY_BUFFER, coreBuffer);
      gl.enableVertexAttribArray(coreLoc.pos);
      gl.vertexAttribPointer(coreLoc.pos, 2, gl.FLOAT, false, 0, 0);
      gl.uniform2f(coreLoc.res, glCanvas.width, glCanvas.height);
      gl.uniform2f(coreLoc.center, coreUniform.center[0], coreUniform.center[1]);
      gl.uniform1f(coreLoc.radius, coreUniform.radius);
      gl.uniform3f(coreLoc.color, coreUniform.color[0], coreUniform.color[1], coreUniform.color[2]);
      gl.uniform1f(coreLoc.alpha, coreUniform.alpha);
      gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
    }
  }

  function buildReticle() {
    const key = META[state].color + '|' + dpr;
    if (reticleKey === key && reticleCanvas) return;
    if (!reticleCanvas) reticleCanvas = document.createElement('canvas');
    reticleCanvas.width = Math.round(W * dpr);
    reticleCanvas.height = Math.round(H * dpr);
    const rc = reticleCanvas.getContext('2d');
    rc.setTransform(dpr, 0, 0, dpr, 0, 0);
    rc.clearRect(0, 0, W, H);
    const stateKey = COLOR_KEY[META[state].color] || 'cyan';
    rc.strokeStyle = rgba(stateKey, .045);
    rc.lineWidth = .8;
    rc.beginPath(); rc.arc(CX, CY, ARENA_R, 0, TAU); rc.stroke();
    rc.strokeStyle = rgba(stateKey, .09);
    rc.beginPath();
    for (let i = 0; i < 72; i += 6) {
      const a = i / 72 * TAU;
      rc.moveTo(CX + Math.cos(a) * (ARENA_R - 4), CY + Math.sin(a) * (ARENA_R - 4));
      rc.lineTo(CX + Math.cos(a) * (ARENA_R + 1), CY + Math.sin(a) * (ARENA_R + 1));
    }
    rc.stroke();
    rc.strokeStyle = rgba(stateKey, .04);
    rc.beginPath();
    for (let i = 0; i < 72; i++) {
      if (i % 6 === 0) continue;
      const a = i / 72 * TAU;
      rc.moveTo(CX + Math.cos(a) * (ARENA_R - 1.5), CY + Math.sin(a) * (ARENA_R - 1.5));
      rc.lineTo(CX + Math.cos(a) * (ARENA_R + 1), CY + Math.sin(a) * (ARENA_R + 1));
    }
    rc.stroke();
    reticleKey = key;
  }

  function drawUI() {
    ui.setTransform(dpr, 0, 0, dpr, 0, 0);
    ui.clearRect(0, 0, W, H);
    if (!useGL) drawFallback();
    ui.setTransform(1, 0, 0, 1, 0, 0);
    buildReticle();
    ui.drawImage(reticleCanvas, 0, 0);
    ui.setTransform(dpr, 0, 0, dpr, 0, 0);
    const stateKey = COLOR_KEY[META[state].color] || 'cyan';
    const hkey = HEALTH_KEY[health.level] || 'cyan';
    // health
    const hp = health.level === 2 ? .55 + .35 * Math.sin(simT * 4) : .48;
    ui.strokeStyle = rgba(hkey, .07);
    ui.beginPath(); ui.arc(CX, CY, HEALTH_R, 0, TAU); ui.stroke();
    for (let i = 0; i < 12; i++) {
      const a = -Math.PI / 2 + i * Math.PI / 6;
      const long = i % 3 === 0;
      const r0 = HEALTH_R - (long ? 6 : 3);
      const r1 = HEALTH_R + (long ? 4 : 2);
      ui.strokeStyle = rgba(hkey, hp * (long ? 1 : .55));
      ui.lineWidth = long ? 1.1 : .7;
      ui.beginPath();
      ui.moveTo(CX + Math.cos(a) * r0, CY + Math.sin(a) * r0);
      ui.lineTo(CX + Math.cos(a) * r1, CY + Math.sin(a) * r1);
      ui.stroke();
    }
    if (health.level > 0) {
      ui.fillStyle = rgba(hkey, .9);
      ui.beginPath(); ui.arc(CX, CY - HEALTH_R, 2, 0, TAU); ui.fill();
    }
    // hover halo
    if (hoverCore > .02 && ringProgress < .05) {
      const hp2 = hoverCore;
      ui.strokeStyle = rgba(stateKey, .15 * hp2);
      ui.lineWidth = 1;
      ui.beginPath(); ui.arc(coreX, coreY, CORE_HIT + 16 + (1 - hp2) * 10, 0, TAU); ui.stroke();
      ui.strokeStyle = rgba(stateKey, .28 * hp2);
      ui.beginPath();
      for (let i = 0; i < 4; i++) {
        const a = -Math.PI / 2 + i * Math.PI / 2;
        const r0 = CORE_HIT + 10, r1 = CORE_HIT + 22;
        ui.moveTo(coreX + Math.cos(a) * r0, coreY + Math.sin(a) * r0);
        ui.lineTo(coreX + Math.cos(a) * r1, coreY + Math.sin(a) * r1);
      }
      ui.stroke();
      ui.fillStyle = rgba(stateKey, .48 * hp2);
      ui.font = '8.5px "SF Mono", "PingFang SC", monospace';
      ui.textAlign = 'center'; ui.textBaseline = 'middle';
      ui.fillText('拖动旋转 · 滚轮缩放 · 点击命令', CX, CY - ARENA_R + 24);
    }
    // shocks
    for (const s of shocks) {
      const p = easeOut(clamp(s.age / s.life, 0, 1));
      ui.strokeStyle = rgba(s.key, (1 - p) * .35 * s.strength);
      ui.lineWidth = 1.2;
      ui.beginPath(); ui.arc(coreX, coreY, 40 + p * 190, 0, TAU); ui.stroke();
    }
    // command ring
    if (ringProgress > .005) {
      const p = easeOut(ringProgress);
      const R = CMD_R * p;
      const key = stateKey;
      ui.strokeStyle = rgba(key, .22 * p);
      ui.lineWidth = 1;
      for (let i = 0; i < commands.length; i++) {
        const a = -Math.PI / 2 + i * Math.PI / 2;
        ui.beginPath(); ui.arc(CX, CY, R, a - .5, a + .5); ui.stroke();
      }
      for (let i = 0; i < commands.length; i++) {
        const pos = stationScreen(i);
        const hover = hoverStation === i;
        const rad = (17 + (hover ? 2 : 0)) * (.6 + .4 * p);
        ui.globalAlpha = p;
        ui.beginPath(); ui.arc(pos.x, pos.y, rad, 0, TAU);
        ui.fillStyle = hover ? rgba(key, .18) : 'rgba(4,11,20,.86)'; ui.fill();
        ui.strokeStyle = rgba(key, hover ? .95 : .52); ui.lineWidth = 1; ui.stroke();
        ui.fillStyle = hover ? '#F4FCFF' : 'rgba(226,246,255,.86)';
        ui.font = '600 11px "PingFang SC", "SF Pro Text", sans-serif';
        ui.textAlign = 'center'; ui.textBaseline = 'middle';
        ui.fillText(commands[i].glyph || '·', pos.x, pos.y + .5);
      }
      ui.globalAlpha = 1;
    }
  }

  function drawFallback() {
    // 2D fallback: soft-free small dots, still state-morphing.
    ui.globalCompositeOperation = 'lighter';
    for (let i = 0; i < pointCount; i++) {
      const dx = pointData[i * 7] * W / 2 + W / 2;
      const dy = (1 - pointData[i * 7 + 1]) * H / 2;
      const size = Math.max(1, pointData[i * 7 + 2] / dpr * .8);
      ui.fillStyle = `rgba(${Math.round(pointData[i * 7 + 4] * 255)},${Math.round(pointData[i * 7 + 5] * 255)},${Math.round(pointData[i * 7 + 6] * 255)},${pointData[i * 7 + 3]})`;
      ui.fillRect(dx - size / 2, dy - size / 2, size, size);
    }
    ui.globalCompositeOperation = 'source-over';
  }

  function addShock(key, strength) {
    shocks.push({ age: 0, life: 1.2, key, strength: strength || 1 });
    if (shocks.length > 8) shocks.shift();
  }

  /* ---------- state / API ---------- */
  function setState(name, force) {
    if (!META[name]) return;
    if (name === state && !force) return;
    state = name;
    stateT = 0;
    refreshPalette();
    docEl.style.setProperty('--state', META[name].color);
    setRing(false);
    if (name === 'OUTPUT') {
      camPitchTarget = .33;
    }
    if (name === 'DONE') addShock('green', .8);
    if (name === 'ERROR') { addShock('red', 1.1); shake = 1; }
    if (name === 'WAITING') addShock('amber', .6);
    if (opts.onState) opts.onState(name);
  }

  function setHealth(level, text) {
    health.level = clamp(level, 0, 2);
    health.text = text || '环境正常';
    const hex = { cyan: '#70D8FF', amber: '#FFC46B', red: '#FF6B6B' }[HEALTH_KEY[health.level]];
    docEl.style.setProperty('--health', hex);
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

  function setStyle(key) {
    if (!STYLES[key] || key === style) return;
    style = key;
    cfg = STYLES[key];
    document.body.dataset.style = key;
    refreshPalette();
    buildParticles();
    addShock(key === 'flux' ? 'amber' : key === 'nova' ? 'cyan' : 'ice', .5);
  }

  function setFrameCap(v) {
    frameCap = clamp(Number(v) || 60, 20, 60);
    lastFrame = 0; lastFpsAt = 0; frames = 0;
  }

  function notify(kind) {
    addShock(kind === 'error' ? 'red' : kind === 'info' ? 'amber' : 'green', .8);
  }

  function outputTick() {
    tokenPulse = Math.min(1.6, tokenPulse + .55);
    if (simT - lastShockAt > .22) {
      lastShockAt = simT;
      addShock(STYLE_SHOCK[style], style === 'nova' ? .16 : .3);
    }
  }

  /* ---------- command ring ---------- */
  function stationPos(i) {
    if (i < 0 || i >= commands.length) return { x: CX, y: CY };
    const a = -Math.PI / 2 + i * Math.PI / 2;
    return { x: CX + Math.cos(a) * CMD_R, y: CY + Math.sin(a) * CMD_R };
  }

  function stationScreen(i) {
    const p = stationPos(i);
    const r = uiCanvas.getBoundingClientRect();
    const s = r.width / W;
    return { x: p.x * s, y: p.y * s };
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

  function hideTip() { hoverStation = -1; tip.classList.remove('show'); }
  function showTip(i) {
    if (i < 0 || !commands[i]) { hideTip(); return; }
    const p = stationPos(i);
    const r = uiCanvas.getBoundingClientRect();
    const s = r.width / W;
    tip.textContent = commands[i].label || commands[i].key;
    tip.style.left = (p.x * s) + 'px';
    if (p.y * s < 50) { tip.style.top = ((p.y + 22) * s) + 'px'; tip.classList.add('below'); }
    else { tip.style.top = ((p.y - 22) * s) + 'px'; tip.classList.remove('below'); }
    tip.classList.add('show');
  }

  function canvasPoint(e) {
    const r = uiCanvas.getBoundingClientRect();
    return { x: (e.clientX - r.left) * (W / Math.max(1, r.width)), y: (e.clientY - r.top) * (H / Math.max(1, r.height)) };
  }

  function onPointerMove(e) {
    const r = uiCanvas.getBoundingClientRect();
    const p = canvasPoint(e);
    pointer.x = p.x; pointer.y = p.y;
    pointer.inside = e.clientX >= r.left && e.clientX <= r.right && e.clientY >= r.top && e.clientY <= r.bottom;
    pointer.nx = clamp((e.clientX - (r.left + r.width / 2)) / (r.width / 2 || 1), -1, 1);
    pointer.ny = clamp((e.clientY - (r.top + r.height / 2)) / (r.height / 2 || 1), -1, 1);
    const nearCore = Math.hypot(p.x - CX, p.y - CY) < CORE_HIT + 26;
    hoverCoreTarget = (!ringOpen && pointer.inside && nearCore) ? 1 : 0;
    if (pressActive && !ringOpen) {
      const dx = e.clientX - lastMoveX, dy = e.clientY - lastMoveY;
      dragDist += Math.abs(dx) + Math.abs(dy);
      if (dragDist > 6) dragging = true;
      if (dragging) {
        const dYaw = dx * .0042, dPitch = dy * .0032;
        userYaw += dYaw;
        userPitch = clamp(userPitch + dPitch, -.55, .55);
        yawVel = dYaw * 42;
        pitchVel = dPitch * 42;
      }
      lastMoveX = e.clientX; lastMoveY = e.clientY;
    }
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
    pressActive = true;
    dragging = false;
    dragDist = 0;
    downOnCore = Math.hypot(p.x - CX, p.y - CY) < CORE_HIT;
    downAt = performance.now();
    lastMoveX = e.clientX; lastMoveY = e.clientY;
    yawVel = pitchVel = 0;
    try { uiCanvas.setPointerCapture(e.pointerId); } catch (_) {}
    updateCursor();
  }

  function onPointerUp(e) {
    if (e.button !== 0 || !pressActive) return;
    pressActive = false;
    if (!ringOpen && downOnCore && dragDist < 7 && performance.now() - downAt < 650) {
      setRing(true);
      addShock(STYLE_SHOCK[style], .7);
      shake = Math.max(shake, .55);
    }
    dragging = false;
    updateCursor();
  }

  function onWheel(e) {
    if (!pointer.inside) return;
    e.preventDefault();
    zoomTarget = clamp(zoomTarget - e.deltaY * .0009, .84, 1.18);
  }

  function updateCursor() {
    if (dragging) uiCanvas.style.cursor = 'grabbing';
    else if (ringOpen && hoverStation >= 0) uiCanvas.style.cursor = 'pointer';
    else if (ringOpen) uiCanvas.style.cursor = 'default';
    else if (hoverCoreTarget) uiCanvas.style.cursor = 'grab';
    else uiCanvas.style.cursor = 'default';
  }
  /* ---------- loop ---------- */
  function frame(now) {
    requestAnimationFrame(frame);
    if (!lastFrame) { lastFrame = now; lastFpsAt = now; }
    let cap = frameCap;
    if (muted) cap = Math.min(cap, 20);
    if (state === 'SLEEPING') cap = Math.min(cap, 20);
    if (state === 'PAUSED') cap = Math.min(cap, 30);
    if (!focused && now - blurAt > 4000) {
      const idle = state === 'IDLE' || state === 'SLEEPING' || state === 'PAUSED';
      cap = Math.min(cap, pointer.inside ? 45 : idle ? 24 : 30);
    }
    effectiveCap = cap;
    if (document.hidden) { lastFrame = now; return; }
    const interval = 1000 / cap;
    if (now - lastFrame < interval - 1) return;
    const dt = Math.min((now - lastFrame) / 1000, .1);
    lastFrame = now;

    if (state !== 'PAUSED') { simT += dt; stateT += dt; }
    tokenPulse *= Math.exp(-dt * 8);
    shake *= Math.exp(-dt * 3);
    hoverCore += (hoverCoreTarget - hoverCore) * Math.min(1, dt * 10);
    zoom += (zoomTarget - zoom) * Math.min(1, dt * 8);
    focal = FOCAL * zoom;
    updateCamera(state === 'PAUSED' ? 0 : dt);
    ringProgress += ((ringOpen ? 1 : 0) - ringProgress) * Math.min(1, dt * 15);
    if (Math.abs(ringProgress - (ringOpen ? 1 : 0)) < .002) ringProgress = ringOpen ? 1 : 0;

    let w = 0;
    for (let i = 0; i < shocks.length; i++) {
      const s = shocks[i];
      s.age += dt;
      if (s.age < s.life) shocks[w++] = s;
    }
    shocks.length = w;

    const t0 = performance.now();
    buildFrame(dt);
    if (useGL) drawGL();
    drawUI();
    frameCost += (performance.now() - t0 - frameCost) * .08;

    frames++;
    if (now - lastFpsAt > 600) {
      const span = now - lastFpsAt;
      if (frames > 2 && span < 1600) {
        fps = Math.round(frames * 1000 / span);
        if (opts.onFps) opts.onFps(Math.max(1, fps));
      }
      frames = 0; lastFpsAt = now;
    }
  }

  function initCtx() {
    resize();
    initWebGL();
    document.addEventListener('pointermove', onPointerMove);
    document.addEventListener('pointerup', onPointerUp);
    uiCanvas.addEventListener('pointerdown', onPointerDown);
    uiCanvas.addEventListener('wheel', onWheel, { passive: false });
    document.addEventListener('pointerdown', e => { if (!wrap.contains(e.target)) setRing(false); }, true);
    document.addEventListener('keydown', e => { if (e.key === 'Escape') setRing(false); });
    window.addEventListener('resize', resize);
    window.addEventListener('focus', () => { focused = true; });
    window.addEventListener('blur', () => { focused = false; blurAt = performance.now(); });
    document.addEventListener('visibilitychange', () => { if (!document.hidden) lastFrame = 0; });
    window.addEventListener('blur', () => { pointer.nx = 0; pointer.ny = 0; pointer.inside = false; hoverCoreTarget = 0; });
  }

  /* ---------- init ---------- */
  function init(options) {
    opts = options || {};
    document.body.dataset.style = style;
    initCtx();
    refreshPalette();
    buildParticles();
    if (opts.frameCap) setFrameCap(opts.frameCap);
    setCommands([
      { key: 'new', glyph: '新', label: '新任务' },
      { key: 'demo', glyph: '演', label: '运行演示' },
      { key: 'sleep', glyph: '眠', label: '休眠' },
      { key: 'mute', glyph: '静', label: '静音粒子' }
    ]);
    docEl.style.setProperty('--state', META.IDLE.color);
    requestAnimationFrame(frame);
  }

  window.PulseEngine = {
    init, setState, setHealth, setCommands, setDensity, setMuted,
    setStyle, notify, outputTick, setRing, setFrameCap,
    getState: () => state,
    getStyle: () => style,
    getFPS: () => fps,
    getCount: () => particles.length,
    isRingOpen: () => ringOpen,
    getRingProgress: () => ringProgress,
    getCommands: () => commands.slice(),
    getStationScreenPos: i => {
      const r = uiCanvas.getBoundingClientRect();
      const s = r.width / W;
      const p = stationPos(i);
      return { x: r.left + p.x * s, y: r.top + p.y * s, w: r.width, h: r.height };
    },
    getCamera: () => ({ yaw: camYaw, pitch: camPitch, targetYaw: camYawTarget, nx: pointer.nx, ny: pointer.ny, userYaw, userPitch }),
    getHover: () => hoverCore,
    getZoom: () => zoom,
    getPerf: () => ({
      fps, ms: +frameCost.toFixed(2), dpr: +dpr.toFixed(2), count: particles.length,
      target: frameCap, effective: effectiveCap, focused, gl: useGL, state, style
    }),
    isWebGL: () => useGL
  };
})();
