import { getColor } from './hooks/supervision_tree/styles';

const THEME = 'matrix';

const CELL_PX = 16;
const RAIN_TICK_MS = 50;
const FADE_ALPHA = 0.1;
const MAX_START_DELAY_ROWS = 40;
const GLYPHS = 'ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜﾝ0123456789';

const DECODE_TICK_MS = 40;
const DECODE_MAX_STEPS = 36;
const DECODE_TARGETS =
  'h1, h2, h3, h4, th, label, .sidebar-label, .menu-title, .tracking-label';
const DECODE_SKIP = 'select, textarea, script, style';
const SCRAMBLE = '!<>-_\\/[]{}=+*^?#$%&01';

/** @param {string} chars */
const pick = (chars) => chars[Math.floor(Math.random() * chars.length)];

const newDrop = () => ({
  row: -Math.floor(Math.random() * MAX_START_DELAY_ROWS),
  every: 1 + Math.floor(Math.random() * 3),
  glyph: '',
});

/** @param {CanvasRenderingContext2D} ctx */
function createRain(ctx) {
  const { canvas } = ctx;
  /** @type {ReturnType<typeof newDrop>[]} */
  let drops = [];
  let colors = { trail: '', head: '', fade: '' };
  let tick = 0;
  /** @type {ReturnType<typeof setInterval> | undefined} */
  let timer;

  const resize = () => {
    const ratio = window.devicePixelRatio || 1;
    canvas.width = canvas.clientWidth * ratio;
    canvas.height = canvas.clientHeight * ratio;
    ctx.scale(ratio, ratio);
    ctx.font = `${CELL_PX}px monospace`;
    ctx.textBaseline = 'top';

    const cs = getComputedStyle(canvas);
    colors = {
      trail: getColor(cs, '--color-primary'),
      head: getColor(cs, '--color-accent'),
      fade: getColor(cs, '--color-base-200'),
    };
    drops = Array.from(
      { length: Math.ceil(canvas.clientWidth / CELL_PX) },
      newDrop
    );
  };

  const draw = () => {
    tick++;
    ctx.globalAlpha = FADE_ALPHA;
    ctx.fillStyle = colors.fade;
    ctx.fillRect(0, 0, canvas.clientWidth, canvas.clientHeight);
    ctx.globalAlpha = 1;

    drops.forEach((drop, column) => {
      if (tick % drop.every !== 0) return;

      const x = column * CELL_PX;
      ctx.fillStyle = colors.fade;
      ctx.fillRect(x, drop.row * CELL_PX, CELL_PX, CELL_PX);
      ctx.fillStyle = colors.trail;
      ctx.fillText(drop.glyph, x, drop.row * CELL_PX);

      drop.row++;
      drop.glyph = pick(GLYPHS);
      ctx.fillStyle = colors.head;
      ctx.fillText(drop.glyph, x, drop.row * CELL_PX);

      if (drop.row * CELL_PX > canvas.clientHeight) {
        Object.assign(drop, newDrop());
      }
    });
  };

  window.addEventListener('resize', () => {
    if (timer) resize();
  });

  return {
    start() {
      if (timer) return;
      resize();
      timer = setInterval(draw, RAIN_TICK_MS);
    },
    stop() {
      clearInterval(timer);
      timer = undefined;
    },
  };
}

/** @type {Map<Text, {target: string, shown: string, step: number, lockAt: number[]}>} */
const decoding = new Map();
/** @type {ReturnType<typeof setInterval> | undefined} */
let decodeTimer;

function stepDecode() {
  for (const [node, state] of decoding) {
    const restoredByPatch = node.nodeValue === state.target;
    const changedElsewhere = node.nodeValue !== state.shown && !restoredByPatch;
    if (!node.isConnected || changedElsewhere) {
      decoding.delete(node);
      continue;
    }

    state.step++;
    state.shown = Array.from(state.target, (char, i) =>
      state.step >= state.lockAt[i] || !char.trim() ? char : pick(SCRAMBLE)
    ).join('');
    node.nodeValue = state.shown;
    if (state.shown === state.target) decoding.delete(node);
  }

  if (decoding.size === 0) {
    clearInterval(decodeTimer);
    decodeTimer = undefined;
  }
}

/** @param {Element} root */
function decode(root) {
  const scopes = root.closest(DECODE_TARGETS)
    ? [root]
    : root.querySelectorAll(DECODE_TARGETS);

  for (const scope of scopes) {
    const walker = document.createTreeWalker(scope, NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const target = node.nodeValue ?? '';
      if (
        !(node instanceof Text) ||
        decoding.has(node) ||
        !target.trim() ||
        node.parentElement?.closest(DECODE_SKIP)
      ) {
        continue;
      }

      const steps = Math.min(12 + target.length, DECODE_MAX_STEPS);
      decoding.set(node, {
        target,
        shown: target,
        step: 0,
        lockAt: Array.from(
          target,
          (_, i) =>
            3 + steps * ((0.6 * i) / target.length + 0.4 * Math.random())
        ),
      });
    }
  }

  if (!decodeTimer && decoding.size > 0) {
    decodeTimer = setInterval(stepDecode, DECODE_TICK_MS);
  }
}

export function initMatrix() {
  const canvas = document.getElementById('matrix-rain');
  const ctx = canvas instanceof HTMLCanvasElement && canvas.getContext('2d');
  if (!ctx) return;

  const rain = createRain(ctx);
  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  const added = new MutationObserver((mutations) => {
    for (const { addedNodes } of mutations) {
      for (const node of addedNodes) {
        if (node instanceof Element) decode(node);
      }
    }
  });
  let active = false;

  const sync = () => {
    const wanted =
      document.documentElement.dataset.theme === THEME &&
      !reducedMotion.matches;
    if (wanted === active) return;
    active = wanted;

    if (active) {
      rain.start();
      added.observe(document.body, { childList: true, subtree: true });
      decode(document.body);
    } else {
      rain.stop();
      added.disconnect();
    }
  };

  new MutationObserver(sync).observe(document.documentElement, {
    attributes: true,
    attributeFilter: ['data-theme'],
  });
  reducedMotion.addEventListener('change', sync);
  sync();
}
