// Whale Girl: a small character in the Dock preview whose pose follows how many
// agent sessions are running / finished-but-unread. Everything is declared as
// `scene` layers (images + keyframes + oscillators) that the host plays locally;
// this script only runs when the counts change, never per frame.
//
// Modes:  idle   no running, no unread  -> dozes off, zZz
//         banner 1-2 running or unread  -> pulls up a banner: pony (running) and green flag (unread) with counts
//         busy   3+ running             -> same banner, but bobbing, sweating, papers flying
(function () {
  "use strict";

  // ---- geometry: source art is a 1280² canvas; scene units are points ---------
  const K = 180 / 950, OX = 200, OY = 160;
  const X = function (v) { return (v - OX) * K; };
  const Y = function (v) { return (v - OY) * K; };
  const W = Math.ceil(X(1090)), H = 180;
  const PART = { // bounding boxes inside the source canvas
    "back-hair": [207, 181, 1082, 984], legs: [502, 862, 755, 1106], skirt: [434, 731, 828, 939],
    body: [509, 506, 757, 899], "arm-left": [222, 547, 556, 639], "arm-right": [721, 547, 1058, 637],
    head: [481, 241, 778, 548], "eyes-open": [492, 380, 747, 475], "eyes-closed": [516, 418, 726, 448],
    "hair-front": [418, 165, 843, 618], ears: [312, 163, 975, 503],
  };
  const PIVOT = { left: [548, 586], right: [731, 586] };
  const GRIP = { left: [250, 602], right: [1030, 602] };
  const BANNER = { w: 790, h: 145 };
  const ARM_DOWN = 72; // degrees the arms hang below the pulled-up pose
  const INK = "#14306EFF";
  const FLAG = { strips: 6, stripW: 2.2, h: 9, poleH: 18, cloth: "#27B35AFF", pole: "#7A6A5CFF" };

  const track = function (prop, keys, loop) {
    const o = { prop: prop, keys: keys.map(function (k) { return { t: k[0], v: k[1], e: k[2] }; }) };
    if (loop) o.loop = loop;
    return o;
  };
  const osc = function (prop, amp, freq, extra) { return Object.assign({ prop: prop, amp: amp, freq: freq }, extra || {}); };
  const ease = function (u) { return u < 0.5 ? 2 * u * u : 1 - Math.pow(-2 * u + 2, 2) / 2; };
  const rad = function (deg) { return deg * Math.PI / 180; };

  // A part positioned by its source bbox, relative to a group whose origin is (ox, oy) in scene points.
  function part(name, ox, oy, extra) {
    const b = PART[name];
    return Object.assign({ kind: "image", image: "assets/" + name + ".png", anchor: [0, 0],
      x: X(b[0]) - ox, y: Y(b[1]) - oy, w: (b[2] - b[0]) * K, h: (b[3] - b[1]) * K }, extra || {});
  }

  // Where a hand grip ends up when the arm swings `angle` radians around its shoulder.
  function hand(side, angle) {
    const p = PIVOT[side], g = GRIP[side], dx = g[0] - p[0], dy = g[1] - p[1];
    return [p[0] + dx * Math.cos(angle) - dy * Math.sin(angle), p[1] + dx * Math.sin(angle) + dy * Math.cos(angle)];
  }

  // Keyframes for raising the arms and unrolling the banner between them. The banner
  // follows the rotated grips, so its edges stay in the hands at every frame.
  function pullTracks(delay, dur) {
    const steps = Math.max(2, Math.round(dur / 0.05));
    const out = { armL: [], armR: [], bx: [], by: [], bsx: [], bsy: [], bop: [], top: [] };
    for (let i = 0; i <= steps; i++) {
      const p = ease(i / steps), t = delay + dur * i / steps, a = rad((1 - p) * ARM_DOWN);
      const l = hand("left", -a), r = hand("right", a);
      out.armL.push([t, -(1 - p) * ARM_DOWN]); out.armR.push([t, (1 - p) * ARM_DOWN]);
      out.bx.push([t, X(l[0])]); out.by.push([t, Y(l[1])]);
      out.bsx.push([t, (r[0] - l[0]) / BANNER.w]); out.bsy.push([t, 0.2 + 0.8 * p]);
      out.bop.push([t, Math.min(1, p * 4)]); out.top.push([t, Math.max(0, Math.min(1, (p - 0.6) / 0.3))]);
    }
    const first = function (list) { return [[0, list[0][1]]].concat(list); };
    Object.keys(out).forEach(function (k) { out[k] = first(out[k]); }); // hold the start pose until `delay`
    return out;
  }

  function arms(ox, oy, mode, pull) {
    const left = PIVOT.left, right = PIVOT.right;
    const one = function (name, pivot, sign, keys) {
      const b = PART[name];
      const layer = part(name, ox, oy, { anchor: [(pivot[0] - b[0]) / (b[2] - b[0]), (pivot[1] - b[1]) / (b[3] - b[1])] });
      layer.x = X(pivot[0]) - ox; layer.y = Y(pivot[1]) - oy;
      if (keys) layer.tracks = [track("rotation", keys)]; else layer.rotation = sign * ARM_DOWN;
      return layer;
    };
    return [one("arm-left", left, -1, pull && pull.armL), one("arm-right", right, 1, pull && pull.armR)];
  }

  const shift = function (keys, by) { return keys.map(function (k) { return [k[0], k[1] - by]; }); };

  function banner(ox, oy, pull, running, unread) {
    const layers = [{ kind: "image", image: "assets/banner.png", anchor: [0, 0], x: X(GRIP.left[0]) - ox, y: Y(GRIP.left[1]) - oy,
      w: BANNER.w * K, h: BANNER.h * K, opacity: 0,
      tracks: [track("x", shift(pull.bx, ox)), track("y", shift(pull.by, oy)), track("scaleX", pull.bsx), track("scaleY", pull.bsy), track("opacity", pull.bop)] }];
    // Icons and counts are siblings (never stretched with the banner), but ride it: each follows the
    // banner's left edge, width and height at every keyframe, and only fades in once it is nearly open.
    const rideX = function (px, dx) { // px: source x of the spot at full width
      const f = (px - GRIP.left[0]) / BANNER.w;
      return track("x", pull.bx.map(function (k, i) { return [k[0], k[1] - ox + f * BANNER.w * K * pull.bsx[i][1] + (dx || 0)]; }));
    };
    const rideY = function (dy) {
      return track("y", pull.by.map(function (k, i) { return [k[0], k[1] - oy + 0.5 * BANNER.h * K * pull.bsy[i][1] + (dy || 0)]; }));
    };
    const ride = function (px, extra, dx, dy) {
      return Object.assign({ opacity: 0, tracks: [track("opacity", pull.top), rideX(px, dx), rideY(dy)] }, extra);
    };
    const count = function (n, px) {
      return ride(px, { kind: "text", text: String(n), size: 14, weight: "heavy", design: "rounded", fill: INK });
    };
    // Running: a pony at a gallop (bobbing and rocking), then its count.
    layers.push(ride(420, { kind: "text", text: "\uD83D\uDC0E", size: 16, scaleX: -1, // the emoji faces left; flip it to run right
      osc: [osc("y", 1.1, 3), osc("rotation", 7, 3, { phase: 0.25 }), osc("x", 1.2, 1.5)] }), count(running, 505));
    // Finished and unread: a green flag whose cloth ripples from the pole outwards.
    const strips = [];
    for (let i = 0; i < FLAG.strips; i++) {
      strips.push({ kind: "rect", x: 1.6 + i * FLAG.stripW, y: 1, w: FLAG.stripW + 0.3, h: FLAG.h, anchor: [0, 0], fill: FLAG.cloth,
        osc: [osc("y", 0.3 + 0.18 * i, 1.1, { phase: i * 0.11 })] });
    }
    const pole = { kind: "rect", x: 0, y: 0, w: 1.6, h: FLAG.poleH, anchor: [0, 0], fill: FLAG.pole, radius: 0.8 };
    layers.push(ride(735, { kind: "group", w: 0, h: 0, children: [pole].concat(strips) }, -6, -FLAG.poleH / 2), count(unread, 820));
    return layers;
  }

  // Blink: open eyes show, closed eyes replace them briefly. `closedSpans` are extra [from, to] stretches (dozing).
  function eyes(ox, oy, period, closedSpans) {
    const open = [[0, 1]], closed = [[0, 0]];
    const events = closedSpans.concat([[period * 0.87, period * 0.92]]).sort(function (a, b) { return a[0] - b[0]; });
    events.forEach(function (s) {
      open.push([s[0], 0, "hold"], [s[1], 1, "hold"]); closed.push([s[0], 1, "hold"], [s[1], 0, "hold"]);
    });
    open.push([period, 1]); closed.push([period, 0]);
    return [part("eyes-open", ox, oy, { tracks: [track("opacity", open, period)] }),
      part("eyes-closed", ox, oy, { opacity: 0, tracks: [track("opacity", closed, period)] })];
  }

  function head(mode, ox, oy) {
    const hx = 630, hy = 540, o = [X(hx), Y(hy)];
    const base = { kind: "group", x: o[0] - ox, y: o[1] - oy, w: 0, h: 0 };
    const kids = [part("head", o[0], o[1]), null, part("ears", o[0], o[1]), part("hair-front", o[0], o[1])];
    if (mode === "idle") {
      // Nods off, jerks awake, repeat.
      base.tracks = [track("rotation", [[0, 0], [3.5, 7, "inOut"], [4.4, 7], [4.8, -1.5, "out"], [5.4, 0, "inOut"], [8, 0]], 8)];
      kids[1] = eyes(o[0], o[1], 8, [[2.6, 4.5]]);
    } else if (mode === "busy") {
      base.osc = [osc("rotation", 3, 2.6)];
      kids[1] = eyes(o[0], o[1], 1.4, []);
    } else {
      base.osc = [osc("rotation", 1.4, 0.3)];
      kids[1] = eyes(o[0], o[1], 3.1, []);
    }
    base.children = [kids[0]].concat(kids[1], [kids[2], kids[3]]);
    return base;
  }

  function sleepyZ(ox, oy) {
    return [0, 1.6, 3.2].map(function (d, i) {
      const x0 = X(800 + i * 40) - ox, y0 = Y(330 - i * 25) - oy;
      return { kind: "text", text: "z", x: x0, y: y0, size: 9 + i * 3, weight: "bold", design: "serif", italic: true, fill: "$secondaryLabel", opacity: 0,
        tracks: [track("opacity", [[0, 0], [d, 0], [d + 0.4, 1], [d + 2, 0], [6, 0]], 6),
          track("y", [[0, y0], [d, y0], [d + 2, y0 - 14], [6, y0 - 14]], 6),
          track("x", [[0, x0], [d, x0], [d + 2, x0 + 8], [6, x0 + 8]], 6)] };
    });
  }

  function busyProps(ox, oy) {
    const out = [];
    [[-1, 0], [1, 0.6]].forEach(function (s) { // sweat drops at the temples, falling out of step
      const x0 = X(630 + s[0] * 150) - ox, y0 = Y(420) - oy, d = s[1];
      out.push({ kind: "symbol", symbol: "drop.fill", x: x0, y: y0, size: 10, fill: "#6FC3FFFF", opacity: 0,
        tracks: [track("opacity", [[0, 0], [d, 0], [d + 0.1, 1], [d + 0.5, 0], [1.2, 0]], 1.2),
          track("y", [[0, y0], [d, y0], [d + 0.5, y0 + 18], [1.2, y0 + 18]], 1.2)] });
    });
    [0, 1, 2].forEach(function (i) { // papers orbiting
      out.push({ kind: "symbol", symbol: "doc.text.fill", x: X(640) - ox, y: Y(560) - oy, size: 13, fill: "$secondaryLabel", opacity: 0.85,
        osc: [osc("x", W / 2 - 14, 0.45, { phase: i / 3 }), osc("y", 18, 0.45, { phase: i / 3 + 0.25 }), osc("rotation", 25, 0.9, { phase: i / 3 })] });
    });
    return out;
  }

  function unreadSparkle(ox, oy) {
    return { kind: "symbol", symbol: "sparkle", x: X(930) - ox, y: Y(300) - oy, size: 13, fill: "#FFC83DFF",
      osc: [osc("scale", 0.25, 0.8), osc("opacity", -0.25, 0.8)] };
  }

  // ---- scene -----------------------------------------------------------------
  let lastMode = null, epoch = 0;

  function modeOf(running, unread) { return running >= 3 ? "busy" : running > 0 || unread > 0 ? "banner" : "idle"; }

  function build(running, unread) {
    const mode = modeOf(running, unread), now = Date.now() / 1000;
    if (mode !== lastMode) { lastMode = mode; epoch = now; }
    const cx = X(640), cy = Y(1100); // feet: bobbing pivots here
    const pull = mode === "idle" ? null : mode === "busy" ? pullTracks(0.15, 0.4) : pullTracks(0.4, 0.8);
    const holdAt = mode === "idle" ? 0 : mode === "busy" ? 0.6 : 1.3;
    const inner = [part("back-hair", cx, cy), part("legs", cx, cy), part("skirt", cx, cy), part("body", cx, cy)];
    inner.push(head(mode, cx, cy));
    arms(cx, cy, mode, pull).forEach(function (a) { inner.push(a); });
    if (pull) banner(cx, cy, pull, running, unread).forEach(function (b) { inner.push(b); });
    const body = { kind: "group", x: cx, y: cy, w: 0, h: 0,
      osc: mode === "busy" ? [osc("y", 1.4, 3), osc("rotation", 1.2, 2.2)] : [osc("y", mode === "idle" ? 0.4 : 0.6, 0.4)], children: inner };
    let layers = [body];
    if (mode === "idle") layers = layers.concat(sleepyZ(0, 0));
    if (mode === "busy") layers = layers.concat(busyProps(0, 0));
    if (mode !== "idle" && unread > 0) layers.push(unreadSparkle(0, 0));
    return { type: "scene", key: mode, epoch: epoch, width: W, height: H, fps: mode === "busy" ? 30 : 24, fit: "width", restAt: holdAt, layers: layers };
  }

  const count = function (v) { return Math.max(0, Math.min(99, Math.floor(Number(v) || 0))); };

  // ---- session counts from the user's DeepSeek Harness data (read-only, via ctx.fs) ------------
  // Each session writes <workspace>/session-<id>/session.v4.jsonl.zstd while it works (every ~6 s,
  // up to a minute or two between writes during long steps) and keeps a flock on session.lock for as
  // long as Harness has it open. Harness's own "unread" lives only in its memory, so it is approximated:
  // a session is unread when it is open, has stopped writing, and finished after Harness last left the front.
  const QUIET = 60;      // seconds without a write before a session counts as finished
  const RECENT = 86400;  // sessions untouched for a day cannot matter
  const MAX_LOCK_CHECKS = 30;

  async function readCounts(ctx) {
    if (!ctx.fs) return { running: 0, unread: 0 }; // folder access not allowed: the "no sessions" animation
    try {
      const files = await ctx.fs.scan("sessions", "", { depth: 3, suffix: ".jsonl.zstd", modifiedWithin: RECENT });
      const now = Date.now() / 1000, since = ctx.app && ctx.app.lastActiveAt;
      let running = 0;
      const finished = [];
      files.forEach(function (f) {
        if (now - f.mtime <= QUIET) running++;
        else if (typeof since === "number" && f.mtime > since) finished.push(f);
      });
      let unread = 0;
      for (const f of finished.slice(0, MAX_LOCK_CHECKS)) {
        const dir = f.path.slice(0, f.path.lastIndexOf("/"));
        try { if (await ctx.fs.isLocked("sessions", dir + "/session.lock")) unread++; } catch (e) { /* closed or unreadable */ }
      }
      return { running: running, unread: unread };
    } catch (e) {
      console.warn("session scan failed: " + e);
      return { running: 0, unread: 0 };
    }
  }

  globalThis.__switchlyPlugin = {
    async render(ctx) {
      const counts = await readCounts(ctx);
      const scene = build(count(counts.running), count(counts.unread));
      return [{ slot: "center", node: { type: "surface", material: "glass", children: [scene] } }];
    },
    async onAction() {},
    // Exposed for the unit tests.
    __test: { modeOf: modeOf, hand: hand, pullTracks: pullTracks, build: build, readCounts: readCounts },
  };
})();
