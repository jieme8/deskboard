/* PULSE agent runtime — local demo engine: tasks, plans, tools, approval, streaming. */
(function () {
  'use strict';

  const META = window.PULSE_STATES;
  const ORDER = window.PULSE_STATE_ORDER;
  const E = window.PulseEngine;
  const $ = s => document.querySelector(s);

  const trace = $('#trace');
  const stateGrid = $('#stateGrid');
  const eventLog = $('#eventLog');
  const taskInput = $('#taskInput');
  const sendBtn = $('#sendBtn');
  const pauseBtn = $('#pauseBtn');
  const cancelBtn = $('#cancelBtn');
  const autoApproveEl = $('#autoApprove');
  const labStateZh = $('#labStateZh');
  const labStateEn = $('#labStateEn');
  const labStateDot = $('#labStateDot');
  const labStateTime = $('#labStateTime');
  const consoleState = $('#consoleState');
  const consoleStateEm = consoleState.querySelector('em');
  const consoleRate = $('#consoleRate');
  const orbWrap = $('#orbWrap');
  const orbLine1 = $('#orbLine1');
  const orbLine2 = $('#orbLine2');
  const healthChip = $('#healthChip');
  const healthChipText = healthChip.querySelector('span');
  const healthTextEl = $('#healthText');
  const healthMini = $('#healthMini');
  const fpsEl = $('#fps');
  const particleCountEl = $('#particleCount');
  const outDensityEl = $('#outDensity');
  const toastEl = $('#toast');
  const deckLab = $('#lab');
  const consolePanel = $('#console');
  const restoreBtn = $('#restore');
  const quickBar = $('#quick');
  const cpuEl = $('#cpu'), tempEl = $('#temp'), diskEl = $('#disk'), batteryEl = $('#battery');
  const outputs = { cpu: $('#outCpu'), temp: $('#outTemp'), disk: $('#outDisk'), battery: $('#outBattery') };

  const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
  const fmtNum = v => Number.isInteger(v) ? String(v) : String(Math.round(v * 1e6) / 1e6);
  const short = (s, n = 42) => s && s.length > n ? s.slice(0, n - 1) + '…' : (s || '');

  const CMD = {
    new: { key: 'new', glyph: '新', label: '新任务' },
    demo: { key: 'demo', glyph: '演', label: '运行完整回合' },
    sleep: { key: 'sleep', glyph: '眠', label: '休眠' },
    mute: { key: 'mute', glyph: '静', label: '静音粒子' },
    pause: { key: 'pause', glyph: '停', label: '暂停任务' },
    cancel: { key: 'cancel', glyph: '断', label: '中断任务' },
    log: { key: 'log', glyph: '志', label: '查看事件日志' },
    allow: { key: 'allow', glyph: '允', label: '允许操作' },
    deny: { key: 'deny', glyph: '拒', label: '拒绝操作' },
    details: { key: 'details', glyph: '详', label: '查看详情' },
    retry: { key: 'retry', glyph: '试', label: '重试任务' },
    dismiss: { key: 'dismiss', glyph: '忽', label: '忽略错误' },
    resume: { key: 'resume', glyph: '续', label: '继续任务' },
    wake: { key: 'wake', glyph: '唤', label: '唤醒 PULSE' },
    settings: { key: 'settings', glyph: '设', label: '设置' }
  };

  let currentState = 'IDLE';
  let stateSince = performance.now();
  let stateJustChanged = true;
  let currentTask = '';
  let currentSub = '给 PULSE 一个任务';
  let planStepCount = 0;
  let activeToolName = '';
  let activeToolStart = 0;
  let activeTools = [];
  let run = null;
  let runEpoch = 0;
  let busy = false;
  let autoApprove = false;
  let lastTaskText = '';
  let lastAnswer = '';
  let flakyFailPending = false;
  let manualPausedPrev = 'IDLE';
  let tokenRate = 0;
  let healthLevel = 0;
  let healthText = '环境正常';
  let lastHealthLevel = 0;
  let sleepTimer = 0;
  let muted = false;
  let mutedToastAt = 0;

  const CancelError = class extends Error {};

  function el(tag, cls, text) {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text !== undefined && text !== null) n.textContent = text;
    return n;
  }

  function toast(msg) {
    toastEl.textContent = msg;
    toastEl.classList.add('show');
    clearTimeout(toast._t);
    toast._t = setTimeout(() => toastEl.classList.remove('show'), 1800);
  }

  function logEvent(kind, detail = '') {
    const row = el('div', 'ev');
    const t = new Date();
    const stamp = [t.getHours(), t.getMinutes(), t.getSeconds()].map(v => String(v).padStart(2, '0')).join(':');
    row.appendChild(el('span', 't', stamp));
    const b = el('b', '', kind);
    row.appendChild(b);
    if (detail) row.appendChild(document.createTextNode(' ' + short(detail, 40)));
    eventLog.appendChild(row);
    while (eventLog.children.length > 7) eventLog.removeChild(eventLog.firstElementChild);
  }

  function addEntry(node) {
    trace.appendChild(node);
    while (trace.children.length > 80) trace.removeChild(trace.firstElementChild);
    trace.scrollTop = trace.scrollHeight;
  }

  function divider(text) {
    const d = el('div', 'divider entry', text);
    addEntry(d);
    return d;
  }

  function notice(text) {
    const d = el('div', 'notice-line entry', text);
    addEntry(d);
    return d;
  }

  function userLine(text) {
    const row = el('div', 'you-line entry');
    row.appendChild(el('span', 'tag', 'YOU'));
    row.appendChild(el('span', 'txt', text));
    addEntry(row);
  }

  function agentLine(text) {
    const row = el('div', 'agent-line entry');
    row.appendChild(el('span', 'tag', 'PULSE'));
    row.appendChild(el('span', 'txt', text));
    addEntry(row);
    return row;
  }

  function thinkingLine(text) {
    const row = el('div', 'thinking-line entry');
    row.appendChild(el('span', 'dots', ''));
    const dots = row.querySelector('.dots');
    dots.appendChild(el('i')); dots.appendChild(el('i')); dots.appendChild(el('i'));
    row.appendChild(el('span', '', text));
    addEntry(row);
    return row;
  }

  function setState(name, opts = {}) {
    if (!META[name]) return;
    const changed = name !== currentState;
    if (opts.task !== undefined) currentTask = opts.task;
    if (changed || opts.force) {
      stateSince = performance.now();
      stateJustChanged = true;
      currentSub = opts.sub !== undefined ? opts.sub : defaultSub(name);
    } else if (opts.sub !== undefined) {
      currentSub = opts.sub;
    }
    currentState = name;
    const meta = META[name];
    document.documentElement.style.setProperty('--state', meta.color);
    if (changed || opts.force) {
      E.setState(name);
      E.setCommands(commandsFor(name));
      planStepCount = 0;
      activeToolName = '';
      tokenRate = 0;
    } else {
      E.setCommands(commandsFor(name));
    }
    labStateZh.textContent = meta.zh;
    labStateEn.textContent = meta.en;
    labStateDot.style.background = meta.color;
    labStateDot.style.boxShadow = `0 0 13px ${meta.color}`;
    consoleStateEm.textContent = meta.zh;
    pauseBtn.textContent = name === 'PAUSED' ? '继续' : '暂停';
    cancelBtn.disabled = !(run || ['THINKING', 'PLANNING', 'RETRIEVING', 'TOOL_CALL', 'WAITING', 'OUTPUT', 'DELEGATING', 'PAUSED', 'ERROR'].includes(name));
    orbWrap.classList.toggle('live', !['IDLE', 'SLEEPING'].includes(name));
    if (changed || opts.force) {
      for (const b of stateGrid.children) b.classList.toggle('active', b.dataset.state === name);
    }
    if (name === 'IDLE') scheduleSleep(); else clearSleep();
    updateLabels(true);
  }

  function defaultSub(name) {
    switch (name) {
      case 'IDLE': return '给 PULSE 一个任务';
      case 'LISTENING': return '在听你的任务…';
      case 'THINKING': return '正在推理下一步';
      case 'PLANNING': return '正在拆解任务';
      case 'RETRIEVING': return '正在检索本地知识库';
      case 'TOOL_CALL': return '正在调用工具';
      case 'WAITING': return '需要你的确认';
      case 'OUTPUT': return '正在把答案写到控制台';
      case 'DONE': return '本回合结束';
      case 'ERROR': return '工具调用失败';
      case 'PAUSED': return '任务已暂停';
      case 'DELEGATING': return '子智能体并行工作';
      case 'SLEEPING': return '等待唤醒';
      case 'INTERRUPTED': return '任务已中断';
      default: return '';
    }
  }

  function commandsFor(name) {
    switch (name) {
      case 'WAITING': return [CMD.allow, CMD.deny, CMD.details, CMD.pause];
      case 'ERROR': return [CMD.retry, CMD.details, CMD.dismiss, CMD.sleep];
      case 'PAUSED': return [CMD.resume, CMD.cancel, CMD.log, CMD.sleep];
      case 'SLEEPING': return [CMD.wake, CMD.new, CMD.settings, CMD.mute];
      case 'IDLE':
      case 'LISTENING':
      case 'DONE':
      case 'INTERRUPTED':
        return [CMD.new, CMD.demo, CMD.sleep, CMD.mute];
      default:
        return [CMD.pause, CMD.cancel, CMD.log, CMD.mute];
    }
  }

  function updateLabels(force) {
    const elapsed = (performance.now() - stateSince) / 1000;
    let line1 = META[currentState].zh;
    let rate = '—';
    switch (currentState) {
      case 'THINKING': line1 = `思考中 · ${elapsed.toFixed(1)}s`; rate = `${elapsed.toFixed(1)}s`; break;
      case 'PLANNING': line1 = `规划中 · ${planStepCount || 0} 步`; rate = `${elapsed.toFixed(1)}s`; break;
      case 'RETRIEVING': line1 = `检索中 · ${elapsed.toFixed(1)}s`; rate = `${elapsed.toFixed(1)}s`; break;
      case 'TOOL_CALL': line1 = `工具调用 · ${activeToolName || '工具'} · ${elapsed.toFixed(1)}s`; rate = `${elapsed.toFixed(1)}s`; break;
      case 'WAITING': line1 = `等待确认 · ${elapsed.toFixed(1)}s`; rate = `${elapsed.toFixed(1)}s`; break;
      case 'OUTPUT': const rateText = tokenRate > 0 ? `${tokenRate} tok/s` : "流式"; line1 = `输出中 · ${rateText}`; rate = rateText; break;
      case 'DONE': line1 = `完成 · ${elapsed.toFixed(1)}s`; rate = `${elapsed.toFixed(1)}s`; break;
      case 'ERROR': line1 = '出错 · 可重试'; rate = 'ERROR'; break;
      case 'PAUSED': line1 = '已暂停'; rate = 'PAUSED'; break;
      case 'DELEGATING': line1 = `委派 · 2 子任务 · ${elapsed.toFixed(1)}s`; rate = `${elapsed.toFixed(1)}s`; break;
      case 'LISTENING': line1 = '聆听中'; rate = '—'; break;
      case 'SLEEPING': line1 = '休眠'; rate = '—'; break;
      case 'INTERRUPTED': line1 = '已中断'; rate = '—'; break;
      default: line1 = '待机'; rate = '—';
    }
    if (force || orbLine1.textContent !== line1) orbLine1.textContent = line1;
    const sub = currentSub || defaultSub(currentState);
    if (force || orbLine2.textContent !== sub) orbLine2.textContent = sub;
    if (force || consoleRate.textContent !== rate) consoleRate.textContent = rate;
    labStateTime.textContent = currentState === 'IDLE' || currentState === 'SLEEPING' ? '—' : elapsed.toFixed(1) + 's';
    for (let i = 0; i < activeTools.length; i++) activeTools[i].tick(elapsed);
  }

  function lastErrorText() {
    return lastErrorMessage || '工具失败';
  }

  /* ---------- environment / health ---------- */
  function syncRange(input) {
    const pct = (input.value - input.min) / (input.max - input.min) * 100;
    input.style.setProperty('--fill', pct.toFixed(1) + '%');
    const out = outputs[input.id];
    if (out) out.textContent = input.value + (input.id === 'temp' ? '°' : '%');
  }

  function envValues() {
    return {
      cpu: +cpuEl.value, temp: +tempEl.value,
      disk: +diskEl.value, battery: +batteryEl.value
    };
  }

  function computeHealth() {
    const { temp, disk, battery } = envValues();
    const tl = temp < 70 ? 0 : temp <= 85 ? 1 : 2;
    const dl = disk < 80 ? 0 : disk <= 90 ? 1 : 2;
    const bl = battery > 20 ? 0 : battery >= 10 ? 1 : 2;
    const level = Math.max(tl, dl, bl);
    let text = '环境正常';
    if (battery < 10) text = `电池过低 ${battery}%`;
    else if (disk > 90) text = `磁盘将满 ${disk}%`;
    else if (temp > 85) text = `温度过高 ${Math.round(temp)}°C`;
    else if (temp > 70) text = `温度偏高 ${Math.round(temp)}°C`;
    else if (disk > 80) text = `磁盘偏高 ${disk}%`;
    else if (battery < 20) text = `电池偏低 ${battery}%`;
    return { level, text };
  }

  function refreshHealth(log) {
    const h = computeHealth();
    healthLevel = h.level;
    healthText = h.text;
    const key = ['cyan', 'amber', 'red'][h.level];
    const hex = { cyan: '#70D8FF', amber: '#FFC46B', red: '#FF6B6B' }[key];
    document.documentElement.style.setProperty('--health', hex);
    const shortText = h.level === 0 ? '正常' : h.text.replace(/\s\d+.*$/, '');
    healthChipText.textContent = h.level === 0 ? '环境正常' : h.text;
    healthChip.classList.toggle('crit', h.level === 2);
    healthMini.textContent = h.level === 0 ? '正常' : shortText;
    healthTextEl.textContent = h.text;
    E.setHealth(h.level, h.text);
    if (log && h.level !== lastHealthLevel) {
      logEvent('health', h.text);
      lastHealthLevel = h.level;
    }
  }

  /* ---------- math ---------- */
  function normalizeMath(s) {
    return s
      .replace(/[×✕]/g, '*').replace(/÷/g, '/').replace(/[−–—]/g, '-')
      .replace(/乘以|乘/g, '*').replace(/除以/g, '/').replace(/加上|加/g, '+').replace(/减去|减/g, '-')
      .replace(/[０-９]/g, ch => String.fromCharCode(ch.charCodeAt(0) - 0xFEE0));
  }

  function tokenizeMath(s) {
    const out = [];
    let i = 0;
    while (i < s.length) {
      const c = s[i];
      if (/\s/.test(c)) { i++; continue; }
      if (/[0-9.]/.test(c)) {
        let j = i;
        while (j < s.length && /[0-9.]/.test(s[j])) j++;
        const raw = s.slice(i, j);
        if ((raw.match(/\./g) || []).length > 1) throw new Error('数字格式错误');
        const num = Number(raw);
        if (!isFinite(num)) throw new Error('数字无效');
        out.push({ t: 'num', v: num });
        i = j;
        continue;
      }
      if ('+-*/%^()'.includes(c)) { out.push({ t: c }); i++; continue; }
      throw new Error('含不支持的字符');
    }
    return out;
  }

  function evalExpression(str) {
    const tokens = tokenizeMath(normalizeMath(str));
    let pos = 0;
    const peek = () => tokens[pos] ? tokens[pos].t : '';
    function expr() {
      let v = term();
      while (peek() === '+' || peek() === '-') {
        const op = tokens[pos++].t;
        const r = term();
        v = op === '+' ? v + r : v - r;
      }
      return v;
    }
    function term() {
      let v = factor();
      while (peek() === '*' || peek() === '/' || peek() === '%') {
        const op = tokens[pos++].t;
        const r = factor();
        if ((op === '/' || op === '%') && r === 0) throw new Error('不能除以 0');
        v = op === '*' ? v * r : op === '/' ? v / r : v % r;
      }
      return v;
    }
    function factor() {
      if (peek() === '+') { pos++; return factor(); }
      if (peek() === '-') { pos++; return -factor(); }
      return power();
    }
    function power() {
      const v = primary();
      if (peek() === '^') { pos++; return Math.pow(v, factor()); }
      return v;
    }
    function primary() {
      const t = tokens[pos++];
      if (!t) throw new Error('表达式不完整');
      if (t.t === 'num') return t.v;
      if (t.t === '(') {
        const v = expr();
        if (!tokens[pos] || tokens[pos].t !== ')') throw new Error('括号不匹配');
        pos++;
        return v;
      }
      throw new Error('表达式无效');
    }
    const v = expr();
    if (pos < tokens.length) throw new Error('表达式有多余内容');
    return v;
  }

  function extractMath(text) {
    const normalized = normalizeMath(text);
    const candidates = normalized.match(/[0-9()+\-*/%^.\s]{3,}/g) || [];
    for (const raw of candidates) {
      const s = raw.trim();
      if (!/\d/.test(s) || !/[+\-*/%^]/.test(s)) continue;
      try {
        const v = evalExpression(s);
        if (isFinite(v)) return { expr: s.replace(/\s+/g, ' '), value: v };
      } catch (_) { /* try next fragment */ }
    }
    return null;
  }

  /* ---------- notes ---------- */
  const NOTES_KEY = 'pulse.notes.v2';
  let memoryNotes = [];
  function readNotes() {
    try {
      const raw = localStorage.getItem(NOTES_KEY);
      if (raw) {
        const arr = JSON.parse(raw);
        if (Array.isArray(arr)) return arr;
      }
    } catch (_) {}
    return memoryNotes;
  }
  function writeNote(text) {
    const notes = readNotes().slice(-49);
    notes.push({ text, at: new Date().toISOString() });
    memoryNotes = notes;
    try { localStorage.setItem(NOTES_KEY, JSON.stringify(notes)); } catch (_) {}
    return notes.length;
  }

  /* ---------- knowledge base ---------- */
  const KB = [
    {
      keys: ['pulse', '粒子', '智能体', 'agent', '3d'],
      title: 'PULSE 3D Agent',
      text: 'PULSE 是一颗 3D 粒子智能体：用形态表示待机、思考、规划、检索、工具调用、等待确认、输出、完成、出错、暂停、委派和休眠。'
    },
    {
      keys: ['状态', 'thinking', '工具', '审批', 'state'],
      title: 'Agent 状态机',
      text: '一轮任务会经过 思考 → 规划 → 检索/工具 → 等待确认 → 输出 → 完成；出错时可重试，任何阶段都能暂停或中断。'
    },
    {
      keys: ['3d', '投影', '透视', '粒子', '景深'],
      title: '3D 粒子渲染',
      text: 'PULSE 不依赖 Three.js：自己算 3D 旋转、透视投影和景深，再用预渲染光斑叠加，鼠标移动会带动摄像机视差。'
    },
    {
      keys: ['工具', '计算器', '笔记', '知识库', 'clock', '计算'],
      title: '本地工具',
      text: '演示里有真实本地工具：表达式计算、时间、系统状态、笔记读写、知识库检索；写入笔记需要你批准。'
    },
    {
      keys: ['deskboard', '桌面', '挂件'],
      title: 'DeskBoard',
      text: 'DeskBoard 是一个纯 Objective-C 的 macOS 桌面挂件集合，PULSE 是其中第五块、也是一块会执行任务的粒子智能体。'
    }
  ];

  function searchKB(query) {
    const q = String(query || '').toLowerCase();
    const scored = KB.map(doc => {
      let score = 0;
      for (const k of doc.keys) if (q.includes(k)) score += 2;
      for (const ch of q) if (doc.text.includes(ch)) score += .05;
      return { doc, score };
    }).sort((a, b) => b.score - a.score);
    if (!scored[0] || scored[0].score < .5) return { text: '知识库里没有直接命中。我只在本地演示库里检索，不联网。' };
    const top = scored.slice(0, 2).filter(x => x.score > .5);
    return { text: top.map(x => `${x.doc.title}：${x.doc.text}`).join('\n') };
  }

  /* ---------- plan parsing ---------- */
  function extractNoteText(text) {
    let s = text;
    const colon = s.search(/[：:]/);
    if (colon >= 0) s = s.slice(colon + 1);
    s = s.replace(/^(请|帮我|给我|麻烦)?\s*(记(一)?条?笔记|记住|写个?笔记|写入笔记)[:：,，\s]*/i, '');
    return s.trim();
  }

  function extractQuery(text) {
    let s = text
      .replace(/^(请|帮我|给我|麻烦)?\s*/i, '')
      .replace(/^(查一下|查查|搜索一下|搜索|检索|查|什么是|是什么|介绍一下|介绍|告诉我|了解一下)/, '')
      .replace(/[？?。.!！\s]+$/g, '')
      .trim();
    return s || text;
  }

  function demoPlan() {
    return {
      kind: 'demo',
      title: '完整 Agent 回合演示',
      steps: [
        { tool: 'search', label: '检索知识库', detail: 'PULSE 3D Agent', args: { query: 'PULSE 3D Agent 状态机' } },
        { tool: 'system', label: '读取系统状态', detail: 'CPU / 温度 / 磁盘 / 电池', args: {} },
        {
          tool: 'notes_write', label: '写入本地笔记', detail: 'PULSE 演示记录',
          requiresApproval: true, approvalText: '允许我把这次演示结果写入本地笔记吗？',
          args: { text: 'PULSE 3D 演示：Agent 状态机与工具调用已跑通' }
        }
      ]
    };
  }

  function failPlan() {
    return {
      kind: 'fail',
      title: '工具失败与重试演示',
      steps: [
        { tool: 'flaky', label: '访问远程接口', detail: 'https://example.invalid/agent', failOnce: true, args: {} }
      ]
    };
  }

  function delegatePlan() {
    return {
      kind: 'delegate',
      title: '委派 2 个子智能体',
      steps: [
        {
          tool: 'parallel', label: '并行子智能体', detail: '检索 + 系统检查',
          substeps: [
            { tool: 'search', label: '子智能体 A · 检索', detail: 'PULSE 3D', args: { query: 'PULSE 3D 粒子' } },
            { tool: 'system', label: '子智能体 B · 系统', detail: 'CPU / 温度', args: {} }
          ]
        }
      ]
    };
  }

  function buildPlan(raw) {
    const text = raw.trim();
    if (!text) return null;
    if (/委派|子智能体|并行/.test(text) && !/失败/.test(text)) return delegatePlan();
    if (/失败|出错|error/i.test(text)) return failPlan();
    if (/演示|巡演|完整回合|跑一遍|demo/i.test(text)) return demoPlan();

    const steps = [];
    const math = extractMath(text);
    const wantsNote = /记(?:一)?(?:条)?笔记|记住|写.*笔记|notes?/i.test(text);
    const wantsRead = /看.*笔记|读.*笔记|我的笔记|笔记.*(呢|吧)/.test(text);
    const wantsSystem = /系统|状态|温度|磁盘|电池|cpu|负载|health/i.test(text);
    const wantsClock = /几点|时间|日期|今天|now/i.test(text);
    const wantsSearch = /查|搜索|检索|什么是|是什么|介绍|知识|kb/i.test(text);

    if (wantsSearch && !wantsNote && !wantsRead && !wantsSystem && !wantsClock && !math) {
      steps.push({ tool: 'search', label: '检索知识库', detail: extractQuery(text), args: { query: extractQuery(text) } });
    }
    if (math) steps.push({ tool: 'calc', label: '计算表达式', detail: math.expr, args: { expr: math.expr } });
    if (wantsClock) steps.push({ tool: 'clock', label: '查询当前时间', detail: '本地时钟', args: {} });
    if (wantsSystem) steps.push({ tool: 'system', label: '读取系统状态', detail: '环境面板', args: {} });
    if (wantsRead) steps.push({ tool: 'notes_read', label: '读取本地笔记', detail: '最近 3 条', args: {} });
    if (wantsNote && !wantsRead) {
      let noteText = extractNoteText(text);
      if (math && !/[：:]/.test(text)) noteText = '计算结果：$result';
      else if (!noteText || /^(笔记|一下|一条)$/.test(noteText)) noteText = math ? '计算结果：$result' : text;
      const noteDetail = noteText === '计算结果：$result' ? '计算结果（上一步）' : noteText;
      steps.push({
        tool: 'notes_write', label: '写入本地笔记', detail: noteDetail,
        requiresApproval: true, approvalText: '允许我把这条内容写入本地笔记吗？',
        args: { text: noteText }
      });
    }
    if (!steps.length) {
      steps.push({ tool: 'think', label: '整理回答', detail: short(text, 22), args: { query: text } });
    }
    return { kind: 'task', title: short(text, 38), steps };
  }

  /* ---------- tools ---------- */
  const TOOLS = {
    calc: {
      name: 'calculator', glyph: '∑',
      run(args) {
        const value = evalExpression(args.expr);
        return { text: `${args.expr} = ${fmtNum(value)}`, value };
      }
    },
    clock: {
      name: 'clock.now', glyph: '◷',
      run() {
        const d = new Date();
        const text = d.toLocaleString('zh-CN', { hour12: false, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit' });
        return { text: `现在是 ${text}` };
      }
    },
    system: {
      name: 'system.status', glyph: '▤',
      run() {
        const v = envValues();
        const h = computeHealth();
        return { text: `CPU ${v.cpu}%，温度 ${Math.round(v.temp)}°C，磁盘已用 ${v.disk}%，电池 ${v.battery}%；${h.text}。` };
      }
    },
    search: {
      name: 'kb.search', glyph: '⌕',
      run(args) {
        const r = searchKB(args.query);
        return { text: r.text };
      }
    },
    notes_write: {
      name: 'notes.write', glyph: '✎',
      run(args) {
        const text = String(args.text || '').trim();
        if (!text) throw new Error('笔记内容为空');
        const n = writeNote(text);
        return { text: `已写入本地笔记（共 ${n} 条）：${short(text, 80)}` };
      }
    },
    notes_read: {
      name: 'notes.read', glyph: '▤',
      run() {
        const notes = readNotes();
        if (!notes.length) return { text: '本地还没有笔记。你可以说「记一条笔记：…」。' };
        const last = notes.slice(-3).reverse();
        return { text: '最近笔记：\n' + last.map((n, i) => `${i + 1}. ${short(n.text, 90)}`).join('\n') };
      }
    },
    flaky: {
      name: 'http.fetch', glyph: '⇅',
      run() { return { text: '远程接口返回 200 OK（重试成功）' }; }
    },
    think: {
      name: 'reason.local', glyph: '思',
      run() {
        return {
          text: '我是 PULSE，一个跑在浏览器里的本地演示智能体。我能真实执行：表达式计算、当前时间、系统状态、知识库检索、笔记读写（写入需要你批准），还能演示思考、规划、工具调用、等待确认、流式输出、暂停、中断、重试和委派。'
        };
      }
    }
  };

  function toolStepState(step) {
    if (step.tool === 'search' || step.tool === 'notes_read') return 'RETRIEVING';
    return 'TOOL_CALL';
  }

  function stepArgsText(step) {
    if (!step.args) return '';
    if (step.args.expr) return step.args.expr;
    if (step.args.query) return step.args.query;
    if (step.args.text) return short(step.args.text, 100);
    return '';
  }

  /* ---------- trace cards ---------- */
  function createPlanCard(plan) {
    const card = el('div', 'plan entry');
    const head = el('div', 'plan-head');
    head.appendChild(el('span', '', 'PLAN'));
    head.appendChild(el('b', '', short(plan.title, 32)));
    card.appendChild(head);
    const stepEls = [];
    plan.steps.forEach((step, i) => {
      const row = el('div', 'step');
      const bullet = el('span', 'bullet', '');
      row.appendChild(bullet);
      row.appendChild(el('span', '', `${i + 1}. ${step.label}`));
      row.appendChild(el('span', 'detail', step.detail || ''));
      card.appendChild(row);
      stepEls.push(row);
    });
    addEntry(card);
    planStepCount = plan.steps.length;
    return {
      el: card,
      steps: stepEls,
      active(i) {
        stepEls.forEach((r, j) => {
          r.classList.toggle('active', j === i);
          if (j < i && !r.classList.contains('fail')) r.classList.remove('active');
        });
        planStepCount = plan.steps.length;
      },
      done(i, detail) {
        const r = stepEls[i];
        if (!r) return;
        r.classList.remove('active');
        r.classList.add('done');
        r.querySelector('.bullet').textContent = '✓';
        if (detail) r.querySelector('.detail').textContent = detail;
      },
      fail(i) {
        const r = stepEls[i];
        if (!r) return;
        r.classList.remove('active');
        r.classList.add('fail');
        r.querySelector('.bullet').textContent = '!';
      }
    };
  }

  function createToolCard(step, tool, duration) {
    const card = el('div', 'tool-card entry');
    const head = el('div', 'tool-head');
    head.appendChild(el('span', 'tool-icon', tool.glyph));
    head.appendChild(el('span', 'tool-name', tool.name));
    const status = el('span', 'tool-status', '运行中');
    head.appendChild(status);
    card.appendChild(head);
    const args = stepArgsText(step);
    if (args) card.appendChild(el('div', 'tool-args', args));
    const result = el('div', 'tool-result', '');
    result.style.display = 'none';
    card.appendChild(result);
    const progress = el('div', 'tool-progress');
    const bar = el('i');
    progress.appendChild(bar);
    card.appendChild(progress);
    addEntry(card);

    const started = performance.now();
    let finished = false;
    const obj = {
      el: card,
      setStatus(text) { status.textContent = text; },
      tick() {
        if (finished) return;
        const e = (performance.now() - started) / 1000;
        status.textContent = `运行中 · ${e.toFixed(1)}s`;
        bar.style.width = Math.min(92, (e * 1000 / duration) * 100).toFixed(1) + '%';
      },
      finish(ok, text, durationMs) {
        finished = true;
        card.classList.add(ok ? 'ok' : 'fail');
        status.textContent = ok ? `成功 · ${((performance.now() - started) / 1000).toFixed(1)}s` : '失败';
        bar.style.width = ok ? '100%' : '100%';
        bar.style.background = ok ? 'var(--green)' : 'var(--red)';
        if (text) {
          result.style.display = 'block';
          result.textContent = text;
        }
        const idx = activeTools.indexOf(obj);
        if (idx >= 0) activeTools.splice(idx, 1);
      }
    };
    activeTools.push(obj);
    return obj;
  }

  function createApprovalCard(step, onDecision) {
    const card = el('div', 'approval entry');
    const title = el('div', 'title', '需要你的确认');
    card.appendChild(title);
    const desc = el('div', 'desc', step.approvalText || '允许执行这一步吗？');
    card.appendChild(desc);
    if (step.args && step.args.text) {
      desc.appendChild(document.createElement('br'));
      const q = el('span', '', '「' + short(step.args.text, 120) + '」');
      q.style.color = 'rgba(255,232,179,.92)';
      desc.appendChild(q);
    }
    const btns = el('div', 'btns');
    const allow = el('button', '', '允许');
    const deny = el('button', 'deny', '拒绝');
    btns.appendChild(allow); btns.appendChild(deny);
    card.appendChild(btns);
    addEntry(card);
    const mark = decision => {
      allow.disabled = true; deny.disabled = true;
      const decisionEl = el('div', 'notice-line', decision);
      decisionEl.style.marginTop = '6px';
      card.appendChild(decisionEl);
      trace.scrollTop = trace.scrollHeight;
    };
    allow.addEventListener('click', () => onDecision(true, mark));
    deny.addEventListener('click', () => onDecision(false, mark));
    return { el: card, mark };
  }

  function createErrorCard(message, onRetry) {
    const card = el('div', 'error-card entry');
    card.appendChild(el('div', 'title', '工具调用失败'));
    card.appendChild(el('div', 'desc', message));
    const btn = el('button', '', '重试这次任务');
    btn.addEventListener('click', onRetry);
    card.appendChild(btn);
    addEntry(card);
    return card;
  }

  function createAnswer() {
    const a = el('div', 'answer entry');
    const text = document.createTextNode('');
    const cursor = el('span', 'cursor');
    a.appendChild(text);
    a.appendChild(cursor);
    addEntry(a);
    return { el: a, text, cursor };
  }

  function doneLine(text) {
    const d = el('div', 'done-line entry');
    d.appendChild(el('i', '', '✓'));
    d.appendChild(el('span', '', text));
    addEntry(d);
    return d;
  }

  /* ---------- approvals ---------- */
  let lastErrorMessage = '';

  async function requestApproval(step, myRun) {
    return new Promise(resolve => {
      const card = createApprovalCard(step, (v, mark) => {
        if (!resolveApprovalInternal(v)) mark('已失效');
      });
      myRun.approvalCard = card;
      myRun.approvalResolve = v => resolve(v);
      logEvent('permission.requested', step.label);
      if (autoApproveEl.checked) {
        myRun.approvalTimer = setTimeout(() => {
          if (myRun.approvalResolve) resolveApprovalInternal(true);
        }, 1400);
      }
    });
  }

  function resolveApprovalInternal(value) {
    if (!run || !run.approvalResolve) return false;
    const fn = run.approvalResolve;
    const myRun = run;
    run.approvalResolve = null;
    if (myRun.approvalTimer) { clearTimeout(myRun.approvalTimer); myRun.approvalTimer = 0; }
    if (myRun.paused) resumeRun();
    if (myRun.approvalCard) myRun.approvalCard.mark(value ? '你已允许' : '你已拒绝');
    fn(!!value);
    logEvent(value ? 'approval.allowed' : 'approval.denied');
    return true;
  }

  /* ---------- pause / cancel / retry ---------- */
  function pauseRun() {
    if (!run || run.paused) return;
    run.paused = true;
    run.pausedState = currentState;
    setState('PAUSED', { sub: '任务已暂停 · ' + short(currentTask || '', 22) });
    logEvent('paused');
  }

  function resumeRun() {
    if (!run || !run.paused) return;
    run.paused = false;
    setState(run.pausedState || 'THINKING', { sub: currentSub });
    logEvent('resumed');
  }

  function togglePause() {
    if (run) {
      if (run.paused) resumeRun(); else pauseRun();
      return;
    }
    if (currentState === 'PAUSED') {
      setState(manualPausedPrev || 'IDLE');
      logEvent('resumed', 'manual');
      return;
    }
    if (['IDLE', 'SLEEPING', 'LISTENING', 'DONE', 'INTERRUPTED'].includes(currentState)) {
      toast('当前没有运行中的任务');
      return;
    }
    manualPausedPrev = currentState;
    setState('PAUSED', { sub: '已暂停 · 手动状态' });
    logEvent('paused', 'manual');
  }

  function cancelRun() {
    if (run) {
      const myRun = run;
      myRun.cancelled = true;
      if (myRun.approvalResolve) {
        try { myRun.approvalResolve(false); } catch (_) {}
        myRun.approvalResolve = null;
      }
      if (myRun.approvalTimer) clearTimeout(myRun.approvalTimer);
      runEpoch++;
      run = null;
      busy = false;
      sendBtn.disabled = false;
      activeTools = [];
      tokenRate = 0;
      setState('INTERRUPTED', { force: true, sub: '任务已中断' });
      appendNotice('任务已中断，粒子回到核心。');
      logEvent('interrupted');
      setTimeout(() => { if (currentState === 'INTERRUPTED') setState('IDLE'); }, 900);
      return;
    }
    if (['PAUSED', 'THINKING', 'PLANNING', 'RETRIEVING', 'TOOL_CALL', 'WAITING', 'OUTPUT', 'DELEGATING', 'ERROR'].includes(currentState)) {
      if (currentState === 'PAUSED') { setState(manualPausedPrev || 'IDLE'); return; }
      setState('INTERRUPTED', { force: true, sub: '已中断' });
      appendNotice('已中断。');
      logEvent('interrupted', 'manual');
      setTimeout(() => { if (currentState === 'INTERRUPTED') setState('IDLE'); }, 900);
    }
  }

  function retryLast() {
    if (busy) { toast('当前任务还在运行'); return; }
    if (!lastTaskText) { toast('没有可重试的任务'); return; }
    flakyFailPending = false;
    divider('RETRY / 重试');
    runAgentTask(lastTaskText, { retry: true });
  }

  /* ---------- event commands ---------- */
  function handleCommand(key) {
    switch (key) {
      case 'new': wakeInput(); break;
      case 'demo': if (busy) toast('当前任务还在运行'); else runAgentTask('运行完整回合演示'); break;
      case 'sleep': goSleep(); break;
      case 'mute': toggleMute(); break;
      case 'pause': case 'resume': togglePause(); break;
      case 'cancel': cancelRun(); break;
      case 'log': toast('事件日志在左侧 STATE LAB'); break;
      case 'allow': if (!resolveApprovalInternal(true)) toast('当前没有待批准的请求'); break;
      case 'deny': if (!resolveApprovalInternal(false)) toast('当前没有待批准的请求'); break;
      case 'retry': retryLast(); break;
      case 'dismiss': if (!run) { setState('IDLE', { sub: '给 PULSE 一个任务' }); } break;
      case 'details': toast(currentSub || '—'); break;
      case 'wake': wakeInput(); break;
      case 'settings': toast('设置（演示占位）'); break;
    }
  }

  function toggleMute() {
    muted = !muted;
    E.setMuted(muted);
    toast(muted ? '粒子已静音（8fps）' : '粒子已恢复');
    const now = performance.now();
    if (now - mutedToastAt > 500) mutedToastAt = now;
    logEvent(muted ? 'muted' : 'unmuted');
  }

  function goSleep() {
    if (run) { toast('任务运行中，先中断或暂停'); return; }
    clearSleep();
    setState('SLEEPING', { sub: '等待唤醒' });
    logEvent('sleep');
  }

  function wakeInput() {
    clearSleep();
    if (currentState === 'SLEEPING') {
      setState('LISTENING', { sub: '在听你的任务…' });
      logEvent('wake');
    } else if (!run && ['IDLE', 'DONE', 'ERROR', 'INTERRUPTED'].includes(currentState)) {
      setState('LISTENING', { sub: '在听你的任务…' });
    }
    taskInput.focus();
    setTimeout(() => { if (!run && currentState === 'LISTENING') taskInput.focus(); }, 50);
  }

  function scheduleSleep() {
    clearSleep();
    if (run) return;
    sleepTimer = setTimeout(() => {
      if (!run && currentState === 'IDLE') {
        setState('SLEEPING', { sub: '等待唤醒' });
        logEvent('sleep', 'idle timeout');
      }
    }, 45000);
  }

  function clearSleep() {
    if (sleepTimer) { clearTimeout(sleepTimer); sleepTimer = 0; }
  }

  /* ---------- manual state lab ---------- */
  function manualState(name) {
    if (!META[name]) return;
    if (run) {
      run.cancelled = true;
      if (run.approvalResolve) { try { run.approvalResolve(false); } catch (_) {} run.approvalResolve = null; }
      if (run.approvalTimer) clearTimeout(run.approvalTimer);
      runEpoch++;
      run = null;
      busy = false;
      sendBtn.disabled = false;
      activeTools = [];
    }
    clearSleep();
    manualPausedPrev = name === 'PAUSED' ? currentState : manualPausedPrev;
    setState(name, { force: true, sub: manualSub(name), task: '手动状态演示' });
    divider(`MANUAL / ${META[name].zh}`);
    notice(manualNote(name));
    manualSample(name);
    logEvent('manual.state', META[name].en);
    if (name === 'INTERRUPTED') {
      setTimeout(() => { if (currentState === 'INTERRUPTED') setState('IDLE'); }, 800);
    }
  }

  function manualSub(name) {
    return {
      IDLE: '给 PULSE 一个任务',
      LISTENING: '手动演示 · 环面朝向输入',
      THINKING: '手动演示 · 漩涡向内收束',
      PLANNING: '手动演示 · 三层规划环',
      RETRIEVING: '手动演示 · 波纹向外搜索',
      TOOL_CALL: '手动演示 · 双环工具姿态',
      WAITING: '手动演示 · 琥珀锁环等待批准',
      OUTPUT: '手动演示 · 粒子流射向控制台',
      DONE: '手动演示 · 绿色收束',
      ERROR: '手动演示 · 红色散射',
      PAUSED: '手动演示 · 冻结核',
      DELEGATING: '手动演示 · 主核 + 2 卫星',
      SLEEPING: '手动演示 · 低功耗休眠',
      INTERRUPTED: '手动演示 · 坍塌回核'
    }[name] || defaultSub(name);
  }

  function manualNote(name) {
    const map = {
      IDLE: '三层 3D 环慢转，核心呼吸，等待任务。',
      LISTENING: '环面向输入方向倾斜，并伸出短触须。',
      THINKING: '粒子沿锥形漩涡向内收束，核脉冲加快。',
      PLANNING: '三层半径不同的规划环，按层旋转。',
      RETRIEVING: '球形壳层脉动，外部扫描环向外扩散。',
      TOOL_CALL: '两个互相垂直的环构成工具/陀螺仪姿态。',
      WAITING: '所有运动降到 15%，琥珀色环锁定，等待你的批准。',
      OUTPUT: '环打开 90° 缺口，粒子流朝右侧控制台喷射。',
      DONE: '粒子收成整齐的环，绿色冲击波扫过。',
      ERROR: '粒子先向内爆缩，再散射成红色松散云。',
      PAUSED: '粒子冻结在当前位置，只保留极慢漂移。',
      DELEGATING: '主核分裂出两个卫星，细束连接，完成后合并。',
      SLEEPING: '只保留 34 颗粒子、8fps、低亮度。',
      INTERRUPTED: '粒子向核心坍塌，0.8s 后回到待机。'
    };
    return map[name] || '';
  }

  function manualSample(name) {
    if (name === 'PLANNING') {
      createPlanCard({
        title: '示例规划',
        steps: [
          { label: '理解任务', detail: '解析输入' },
          { label: '调用工具', detail: '计算 / 检索' },
          { label: '组织答案', detail: '流式输出' }
        ]
      });
    } else if (name === 'TOOL_CALL') {
      const step = { tool: 'calc', label: '计算表达式', detail: '128 × 64', args: { expr: '128*64' } };
      const card = createToolCard(step, TOOLS.calc, 800);
      setTimeout(() => card.finish(true, '128*64 = 8192'), 350);
    } else if (name === 'WAITING') {
      const card = createApprovalCard({
        approvalText: '允许我把「PULSE 手动状态演示」写入本地笔记吗？',
        args: { text: 'PULSE 手动状态演示' }
      }, (v, mark) => {
        mark(v ? '你已允许（演示不会真正写入）' : '你已拒绝');
        if (currentState === 'WAITING') setState('IDLE');
      });
      if (autoApproveEl.checked) setTimeout(() => { card.mark('自动批准（演示）'); if (currentState === 'WAITING') setState('IDLE'); }, 1400);
    } else if (name === 'OUTPUT') {
      const a = el('div', 'answer entry');
      a.textContent = '这是手动输出状态：粒子流正朝右侧控制台喷射。真实回合里，这段文字会按 token 节奏逐字出现，核也会同步脉冲。';
      addEntry(a);
    } else if (name === 'ERROR') {
      createErrorCard('演示错误：远程接口不可达。真实回合里，重试会重新执行失败的工具。', () => {
        if (currentState === 'ERROR') setState('IDLE');
      });
    } else if (name === 'DONE') {
      doneLine('示例回合完成 · 2.3s');
    } else if (name === 'DELEGATING') {
      notice('子智能体 A：检索 PULSE 3D；子智能体 B：读取系统状态。两个卫星会在返回后合并。');
    } else if (name === 'RETRIEVING') {
      const step = { tool: 'search', label: '检索知识库', detail: 'PULSE 3D Agent', args: { query: 'PULSE' } };
      const card = createToolCard(step, TOOLS.search, 900);
      setTimeout(() => card.finish(true, '命中：PULSE 3D Agent / Agent 状态机'), 350);
    }
  }

  /* ---------- waiting helpers ---------- */
  function wait(ms, myRun) {
    return new Promise(resolve => {
      let last = performance.now();
      let elapsed = 0;
      function tick(now) {
        if (!myRun || myRun.cancelled || myRun.epoch !== runEpoch) return resolve();
        const dt = Math.min(now - last, 100);
        last = now;
        if (!myRun.paused) elapsed += dt;
        if (elapsed >= ms) return resolve();
        requestAnimationFrame(tick);
      }
      requestAnimationFrame(tick);
    });
  }

  function ensure(myRun) {
    if (!myRun || myRun.cancelled || myRun.epoch !== runEpoch) throw new CancelError('cancelled');
  }

  /* ---------- run loop ---------- */
  async function runAgentTask(raw, opts = {}) {
    const text = String(raw || '').trim();
    if (!text) { toast('先给 PULSE 一个任务'); return; }
    if (busy) { toast('当前任务还在运行，先中断或等待完成'); return; }
    if (currentState === 'SLEEPING') { setState('IDLE'); }
    closeInputFocus();
    clearSleep();
    E.setRing(false);
    const myEpoch = ++runEpoch;
    const myRun = {
      epoch: myEpoch, cancelled: false, paused: false, pausedState: null,
      approvalResolve: null, approvalCard: null, approvalTimer: 0
    };
    run = myRun;
    busy = true;
    sendBtn.disabled = true;
    currentTask = text;
    lastTaskText = text;
    lastErrorMessage = '';
    flakyFailPending = /失败|出错|error/i.test(text) && !opts.retry;
    tokenRate = 0;
    activeTools = [];
    taskInput.value = '';
    taskInput.blur();
    divider('NEW TASK / 新任务');
    userLine(text);
    let thinking = null;
    try {
      thinking = thinkingLine('正在理解任务…');
      setState('THINKING', { sub: short(text, 42) });
      logEvent('task.started', short(text, 30));
      await wait(650, myRun);
      ensure(myRun);
      thinking.remove();

      const plan = buildPlan(text) || { kind: 'task', title: short(text, 38), steps: [{ tool: 'think', label: '整理回答', detail: '', args: {} }] };
      setState('PLANNING', { sub: short(plan.title, 42) });
      const planCard = createPlanCard(plan);
      logEvent('plan.ready', `${plan.steps.length} 步`);
      await wait(700, myRun);
      ensure(myRun);

      const ctx = { lastValue: null, results: [], denied: false };
      for (let i = 0; i < plan.steps.length; i++) {
        ensure(myRun);
        planCard.active(i);
        const step = plan.steps[i];
        try {
          if (step.tool === 'parallel') {
            await runParallelStep(step, planCard, i, ctx, myRun);
          } else {
            await runToolStep(step, planCard, i, ctx, myRun);
          }
        } catch (e) {
          planCard.fail(i);
          throw e;
        }
      }
      ensure(myRun);

      const answer = composeAnswer(plan, ctx, text);
      lastAnswer = answer;
      setState('OUTPUT', { sub: short(text, 42) });
      logEvent('output.start', 'stream');
      const out = createAnswer();
      await streamText(out, answer, myRun);
      ensure(myRun);

      setState('DONE', { sub: '本回合结束' });
      doneLine(`回合完成 · ${plan.steps.length} 步`);
      logEvent('turn.done');
      busy = false;
      sendBtn.disabled = false;
      run = null;
      activeTools = [];
      tokenRate = 0;
      scheduleSleep();
      setTimeout(() => { if (currentState === 'DONE') setState('IDLE'); }, 1600);
    } catch (e) {
      if (thinking) thinking.remove();
      if (!myRun || myRun.epoch !== runEpoch) return;
      busy = false;
      sendBtn.disabled = false;
      run = null;
      activeTools = [];
      tokenRate = 0;
      if (e instanceof CancelError) {
        setState('INTERRUPTED', { force: true, sub: '任务已中断' });
        appendNotice('任务已中断，粒子回到核心。');
        logEvent('interrupted');
        setTimeout(() => { if (currentState === 'INTERRUPTED') setState('IDLE'); }, 900);
        return;
      }
      lastErrorMessage = e && e.message ? e.message : '工具调用失败';
      setState('ERROR', { force: true, sub: short(lastErrorMessage, 42) });
      createErrorCard(lastErrorMessage, retryLast);
      logEvent('tool.fail', lastErrorMessage);
    }
  }

  async function runToolStep(step, planCard, index, ctx, myRun) {
    const tool = TOOLS[step.tool];
    if (!tool) throw new Error('未知工具：' + step.tool);
    activeToolName = tool.name;
    activeToolStart = performance.now();
    let stateName = toolStepState(step);
    if (step.tool === 'notes_write' && step.requiresApproval) stateName = 'WAITING';
    setState(stateName, { sub: `${step.label} · ${step.detail || ''}`.trim() });
    const resolvedArgs = resolveStepArgs(step, ctx);
    const displayStep = Object.assign({}, step, { args: resolvedArgs });
    const card = createToolCard(displayStep, tool, 900);
    logEvent('tool.start', tool.name);

    if (step.requiresApproval) {
      card.setStatus('等待批准');
      const allowed = await requestApproval(displayStep, myRun);
      ensure(myRun);
      if (!allowed) {
        card.finish(true, '未执行：用户拒绝');
        planCard.done(index, '已拒绝');
        ctx.denied = true;
        ctx.results.push({ text: '（写入笔记的请求被拒绝，本地数据没有改动。）' });
        setState('THINKING', { sub: '用户拒绝了写入，继续整理回答' });
        await wait(350, myRun);
        ensure(myRun);
        return;
      }
      setState('TOOL_CALL', { sub: `${step.label} · 已批准` });
      card.setStatus('运行中');
    }

    await wait(step.tool === 'search' ? 1000 : 780, myRun);
    ensure(myRun);

    if (step.failOnce && flakyFailPending) {
      flakyFailPending = false;
      lastErrorMessage = '连接超时：演示用远程接口不可达';
      card.finish(false, lastErrorMessage);
      throw new Error(lastErrorMessage);
    }

    try {
      const out = tool.run(resolvedArgs);
      card.finish(true, out.text);
      ctx.results.push(out);
      if (out.value !== undefined) ctx.lastValue = out.value;
      planCard.done(index, short(step.detail || step.label, 20));
      logEvent('tool.ok', tool.name);
    } catch (e) {
      lastErrorMessage = e.message || '工具调用失败';
      card.finish(false, lastErrorMessage);
      logEvent('tool.fail', lastErrorMessage);
      throw e;
    }

    setState('THINKING', { sub: '工具返回，继续推理' });
    await wait(380, myRun);
    ensure(myRun);
  }

  async function runParallelStep(step, planCard, index, ctx, myRun) {
    setState('DELEGATING', { sub: '2 个子智能体并行工作' });
    logEvent('subagent.start', '2');
    const subs = step.substeps || [];
    const cards = subs.map(s => {
      const tool = TOOLS[s.tool];
      return { s, tool, card: createToolCard(s, tool, 900) };
    });
    await Promise.all(subs.map((s, i) => wait(700 + i * 260, myRun)));
    ensure(myRun);
    const outputs = [];
    for (const item of cards) {
      try {
        const out = item.tool.run(item.s.args || {});
        item.card.finish(true, out.text);
        outputs.push(out);
        ctx.results.push(out);
        logEvent('subagent.done', item.s.label);
      } catch (e) {
        item.card.finish(false, e.message);
        throw e;
      }
    }
    planCard.done(index, '2 个子智能体返回');
    setState('THINKING', { sub: '子智能体返回，合并结果' });
    await wait(380, myRun);
    ensure(myRun);
    return outputs;
  }

  function resolveStepArgs(step, ctx) {
    const args = Object.assign({}, step.args || {});
    for (const k of Object.keys(args)) {
      if (typeof args[k] === 'string') {
        args[k] = args[k].replace(/\$result/g, ctx.lastValue !== null ? fmtNum(ctx.lastValue) : '（暂无计算结果）');
      }
    }
    return args;
  }

  async function streamText(out, text, myRun) {
    const chars = Array.from(text);
    let i = 0;
    let windowStart = performance.now();
    let windowChars = 0;
    tokenRate = 0;
    try {
      while (i < chars.length) {
        ensure(myRun);
        out.text.appendData(chars[i++]);
        windowChars++;
        if (i % 3 === 0) E.outputTick();
        if (performance.now() - windowStart > 450) {
          tokenRate = Math.round(windowChars * 1000 / (performance.now() - windowStart));
          windowStart = performance.now();
          windowChars = 0;
        }
        trace.scrollTop = trace.scrollHeight;
        await wait(16, myRun);
      }
    } finally {
      out.cursor.remove();
      tokenRate = 0;
    }
  }

  function composeAnswer(plan, ctx, raw) {
    if (plan.kind === 'demo') {
      return '演示回合完成：我先在本地知识库检索了 PULSE，再读取了系统状态，随后请求你批准写入一条演示笔记。\n\n思考 → 检索 → 工具 → 审批 → 输出，这条 Agent 链路现在都跑在真实的本地工具上。';
    }
    if (plan.kind === 'delegate') {
      const parts = ctx.results.map(r => r.text);
      return '两个子智能体都返回了：\n\n' + parts.join('\n') + '\n\n委派完成，主核已经合并结果。';
    }
    if (plan.kind === 'fail') {
      if (ctx.results.length) return '重试成功：远程接口这次返回了 200 OK。失败 → 重试 → 成功这条链路已经验证。';
      return '远程接口这次没有返回结果（演示用失败）。你可以点重试，第二次会成功。';
    }
    const parts = ctx.results.map(r => r.text).filter(Boolean);
    if (!parts.length) {
      return '我理解你的任务是「' + short(raw, 60) + '」。这个本地演示引擎目前能真实执行：表达式计算、当前时间、系统状态、知识库检索、笔记读写（写入需批准），以及完整 Agent 回合演示。';
    }
    let answer = parts.join('\n\n');
    if (ctx.denied) answer += '\n\n（写入笔记被拒绝，所以本地数据没有改动。）';
    return answer;
  }

  /* ---------- boot UI ---------- */
  function buildStateGrid() {
    ORDER.forEach(name => {
      const meta = META[name];
      const b = el('button', 'state-btn');
      b.dataset.state = name;
      b.style.setProperty('--sc', meta.color);
      b.title = meta.en;
      b.appendChild(el('i'));
      b.appendChild(el('span', 'n', meta.zh));
      b.appendChild(el('span', 'e', meta.en.split(' ')[0]));
      b.addEventListener('click', () => manualState(name));
      stateGrid.appendChild(b);
    });
  }

  function buildQuick() {
    const chips = [
      ['算 128×64', '算 128×64'],
      ['记一条笔记', '记一条笔记：PULSE 的 3D 粒子演示'],
      ['系统状态', '看一下系统状态'],
      ['查一下 PULSE', '查一下 PULSE 是什么'],
      ['完整回合', '运行完整回合演示'],
      ['失败演示', '演示工具失败'],
      ['委派演示', '委派两个子智能体检查']
    ];
    chips.forEach(([label, task]) => {
      const b = el('button', '', label);
      b.addEventListener('click', () => {
        if (busy) { toast('当前任务还在运行'); return; }
        runAgentTask(task);
      });
      quickBar.appendChild(b);
    });
  }

  function welcome() {
    divider('PULSE / 3D AGENT');
    agentLine('我是 PULSE。给我一个任务：我会思考、规划、调用本地工具、在需要时请求确认，再把答案流式写到这里。');
    notice('本地演示引擎 · 无网络 · 计算 / 时间 / 笔记 / 系统状态 / 知识库都是真实本地动作；写入笔记会请求批准。');
    const flow = el('div', 'flow entry');
    ['思考', '规划', '检索', '工具', '审批', '输出'].forEach((label, i) => {
      if (i) flow.appendChild(el('span', 'arrow', '→'));
      flow.appendChild(el('span', 'node', label));
    });
    addEntry(flow);
    const starter = el('div', 'starter entry');
    const st = el('div', 'starter-title');
    st.appendChild(el('span', '', 'LOCAL TOOLS / 真实本地工具'));
    st.appendChild(el('b', '', '写入需批准'));
    starter.appendChild(st);
    const grid = el('div', 'tool-grid');
    [
      ['∑', '计算器', '安全解析表达式，不 eval'],
      ['⌕', '知识库', '本地 PULSE / 状态机资料'],
      ['✎', '笔记', 'localStorage 读写'],
      ['▤', '系统', '读环境面板的实时值']
    ].forEach(([glyph, name, desc]) => {
      const tile = el('div', 'tool-tile');
      const k = el('div', 'k');
      k.appendChild(el('i', '', glyph));
      k.appendChild(el('span', '', name));
      tile.appendChild(k);
      tile.appendChild(el('div', 'd', desc));
      grid.appendChild(tile);
    });
    starter.appendChild(grid);
    addEntry(starter);
  }

  function appendNotice(text) {
    notice(text);
  }

  function closeInputFocus() {
    if (document.activeElement === taskInput) taskInput.blur();
  }

  function bindEnvironment() {
    [cpuEl, tempEl, diskEl, batteryEl].forEach(input => {
      syncRange(input);
      input.addEventListener('input', () => {
        syncRange(input);
        refreshHealth(true);
      });
    });
    $('#density').addEventListener('change', e => {
      E.setDensity(e.target.value);
      toast('粒子密度：' + ({ low: '低', mid: '中', high: '高' }[e.target.value] || e.target.value));
    });
    refreshHealth(false);
    lastHealthLevel = healthLevel;
  }

  function bindPanels() {
    const hide = () => document.body.classList.add('hide-panels');
    const show = () => document.body.classList.remove('hide-panels');
    $('#btnHide').addEventListener('click', hide);
    restoreBtn.addEventListener('click', show);
    document.addEventListener('keydown', e => {
      if (e.target === taskInput) return;
      if (e.key === 'h' || e.key === 'H') {
        if (document.body.classList.contains('hide-panels')) show(); else hide();
      }
      if (e.key === 'Escape') E.setRing(false);
    });
  }

  function bindConsole() {
    $('#composer').addEventListener('submit', e => {
      e.preventDefault();
      const text = taskInput.value.trim();
      if (!text) { toast('先给 PULSE 一个任务'); taskInput.focus(); return; }
      runAgentTask(text);
    });
    taskInput.addEventListener('focus', () => {
      clearSleep();
      if (!run && (currentState === 'SLEEPING' || currentState === 'IDLE')) {
        setState('LISTENING', { sub: '在听你的任务…' });
      }
    });
    taskInput.addEventListener('blur', () => {
      setTimeout(() => {
        if (document.activeElement !== taskInput && currentState === 'LISTENING' && !run) {
          setState('IDLE', { sub: '给 PULSE 一个任务' });
        }
      }, 160);
    });
    pauseBtn.addEventListener('click', togglePause);
    cancelBtn.addEventListener('click', cancelRun);
    autoApproveEl.addEventListener('change', () => { autoApprove = autoApproveEl.checked; });
  }

  function boot() {
    buildStateGrid();
    buildQuick();
    welcome();
    E.init({
      onCommand: handleCommand,
      onCount: n => { particleCountEl.textContent = n + ' 粒子'; outDensityEl.textContent = n; },
      onFps: n => { fpsEl.textContent = n + ' FPS'; }
    });
    logEvent('boot', '3D engine ready');
    logEvent('tools', '5 local tools');
    bindEnvironment();
    bindConsole();
    bindPanels();
    setState('IDLE', { force: true, sub: '给 PULSE 一个任务' });
    setInterval(updateLabels, 250);

    document.addEventListener('pointerdown', () => {
      if (currentState === 'SLEEPING') clearSleep();
      else if (currentState === 'IDLE') scheduleSleep();
    }, true);
    document.addEventListener('keydown', () => {
      if (currentState === 'SLEEPING') return;
      if (currentState === 'IDLE') scheduleSleep();
    });

    window.__pulse = {
      engine: E,
      get state() { return currentState; },
      get busy() { return busy; },
      get lastAnswer() { return lastAnswer; },
      get health() { return { level: healthLevel, text: healthText }; },
      run: runAgentTask,
      manual: manualState,
      pause: togglePause,
      cancel: cancelRun,
      approve: v => resolveApprovalInternal(!!v),
      retry: retryLast,
      get trace() { return trace.innerText; }
    };

    const q = new URLSearchParams(location.search);
    if (q.get('panel') === '0') document.body.classList.add('hide-panels');
    if (q.get('state')) {
      const raw = q.get('state').toUpperCase();
      const name = ORDER.find(n => n === raw || n.replace('_', '').toLowerCase() === raw.replace('_', '').toLowerCase());
      if (name) setTimeout(() => manualState(name), 500);
    }
    if (q.get('task')) setTimeout(() => runAgentTask(q.get('task')), 700);
    if (q.get('demo') === '1') setTimeout(() => runAgentTask('运行完整回合演示'), 700);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
