(() => {
  const root = document.getElementById("piano");
  if (!root) return;

  const colors = ["--cyan", "--green", "--orange", "--pink", "--purple", "--yellow"];
  const blackAfter = [0, 1, 3, 4, 5];
  const whiteSteps = [0, 2, 4, 5, 7, 9, 11];
  const whites = 15;
  const base = 48;
  const keyMap = "awsedftgyhujk";

  const keys = document.createElement("div");
  keys.className = "keys";
  root.appendChild(keys);

  const byNote = new Map();
  let ctx;
  let hue = 0;

  for (let i = 0; i < whites; i++) {
    const note = base + Math.floor(i / 7) * 12 + whiteSteps[i % 7];
    add("w", note);
    if (i < whites - 1 && blackAfter.includes(i % 7)) {
      const el = add("b", note + 1);
      el.style.left = `${((i + 1) / whites) * 100 - 100 / whites * 0.3}%`;
      el.style.width = `${(100 / whites) * 0.6}%`;
    }
  }

  function add(kind, note) {
    const el = document.createElement("div");
    el.className = kind;
    el.dataset.note = note;
    keys.appendChild(el);
    byNote.set(note, el);
    return el;
  }

  function play(note) {
    ctx ??= new AudioContext();
    const t = ctx.currentTime;
    const freq = 440 * 2 ** ((note - 69) / 12);
    const out = ctx.createGain();
    out.gain.setValueAtTime(0, t);
    out.gain.linearRampToValueAtTime(0.18, t + 0.008);
    out.gain.exponentialRampToValueAtTime(0.001, t + 1.6);
    const tone = ctx.createBiquadFilter();
    tone.type = "lowpass";
    tone.frequency.setValueAtTime(3200, t);
    tone.frequency.exponentialRampToValueAtTime(700, t + 1.2);
    tone.connect(out).connect(ctx.destination);
    for (const [type, mul, gain] of [["triangle", 1, 1], ["sine", 2, 0.35]]) {
      const osc = ctx.createOscillator();
      const g = ctx.createGain();
      osc.type = type;
      osc.frequency.value = freq * mul;
      g.gain.value = gain;
      osc.connect(g).connect(tone);
      osc.start(t);
      osc.stop(t + 1.7);
    }
  }

  function light(el) {
    el.style.setProperty("--k", `var(${colors[hue++ % colors.length]})`);
    el.classList.add("on");
  }

  function down(el) {
    if (!el || el.classList.contains("on")) return;
    light(el);
    play(Number(el.dataset.note));
  }

  if (!matchMedia("(prefers-reduced-motion: reduce)").matches) {
    [57, 60, 64, 67, 71].forEach((note, i) => {
      const el = byNote.get(note);
      setTimeout(() => light(el), 500 + i * 140);
      setTimeout(() => up(el), 2200 + i * 80);
    });
  }

  function up(el) {
    el?.classList.remove("on");
  }

  keys.addEventListener("pointerdown", (e) => {
    keys.releasePointerCapture?.(e.pointerId);
    down(e.target.closest(".w, .b"));
  });
  keys.addEventListener("pointerover", (e) => {
    if (e.buttons) down(e.target.closest(".w, .b"));
  });
  keys.addEventListener("pointerout", (e) => up(e.target.closest(".w, .b")));
  window.addEventListener("pointerup", () => keys.querySelectorAll(".on").forEach(up));

  window.addEventListener("keydown", (e) => {
    if (e.repeat || e.metaKey || e.ctrlKey || e.altKey) return;
    const i = keyMap.indexOf(e.key.toLowerCase());
    if (i >= 0) down(byNote.get(base + 12 + i));
  });
  window.addEventListener("keyup", (e) => {
    const i = keyMap.indexOf(e.key.toLowerCase());
    if (i >= 0) up(byNote.get(base + 12 + i));
  });
})();
