/* PULSE agent state vocabulary shared by the 3D engine and the runtime. */
window.PULSE_STATES = {
  IDLE:        { zh: '待机',   en: 'IDLE',        color: '#70D8FF', fps: 20, glyph: '○' },
  LISTENING:   { zh: '聆听',   en: 'LISTENING',   color: '#B2EEFF', fps: 30, glyph: '听' },
  THINKING:    { zh: '思考',   en: 'THINKING',    color: '#70D8FF', fps: 30, glyph: '思' },
  PLANNING:    { zh: '规划',   en: 'PLANNING',    color: '#B2EEFF', fps: 30, glyph: '规' },
  RETRIEVING:  { zh: '检索',   en: 'RETRIEVING',  color: '#70D8FF', fps: 30, glyph: '检' },
  TOOL_CALL:   { zh: '工具调用', en: 'TOOL CALL', color: '#E2F6FF', fps: 30, glyph: '具' },
  WAITING:     { zh: '等待确认', en: 'WAITING',   color: '#FFC46B', fps: 15, glyph: '候' },
  OUTPUT:      { zh: '输出',   en: 'OUTPUT',      color: '#70D8FF', fps: 30, glyph: '出' },
  DONE:        { zh: '完成',   en: 'DONE',        color: '#78E2AC', fps: 30, glyph: '✓' },
  ERROR:       { zh: '出错',   en: 'ERROR',       color: '#FF6B6B', fps: 30, glyph: '!' },
  PAUSED:      { zh: '暂停',   en: 'PAUSED',      color: '#7EB0CE', fps: 10, glyph: '∥' },
  DELEGATING:  { zh: '委派',   en: 'DELEGATING',  color: '#70D8FF', fps: 30, glyph: '委' },
  SLEEPING:    { zh: '休眠',   en: 'SLEEPING',    color: '#5E7E92', fps: 8,  glyph: '眠' },
  INTERRUPTED: { zh: '中断',   en: 'INTERRUPTED', color: '#7EB0CE', fps: 30, glyph: '断', transient: true }
};

window.PULSE_STATE_ORDER = [
  'IDLE', 'LISTENING', 'THINKING', 'PLANNING', 'RETRIEVING', 'TOOL_CALL',
  'WAITING', 'OUTPUT', 'DONE', 'ERROR', 'PAUSED', 'DELEGATING', 'SLEEPING', 'INTERRUPTED'
];
