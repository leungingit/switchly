// Weather gacha for the Music Dock preview. Draws three cards from the weather,
// reveals a song from the Music library and plays it. All motion is declared as
// `scene` nodes (layers + keyframes + oscillators + emitters) that the host
// plays locally; this script only runs on state changes, never per frame.
(function () {
  "use strict";

  // ---- small helpers ---------------------------------------------------------
  const clamp01 = function (v) { return Math.min(1, Math.max(0, v)); };
  const smooth = function (v) { const u = clamp01(v); return u * u * (3 - 2 * u); };
  const now = function () { return Date.now() / 1000; };
  const hex = function (r, g, b, a) {
    return "#" + [r, g, b, a === undefined ? 1 : a].map(function (v) {
      const n = Math.round(clamp01(v) * 255).toString(16);
      return n.length < 2 ? "0" + n : n;
    }).join("");
  };
  const GOLD = hex(1.0, 0.82, 0.35);
  const WHITE = "#FFFFFFFF";
  const delay = function (ms) { return new Promise(function (res) { setTimeout(res, ms); }); };

  // ---- cards and engine (port of GachaCardPool / GachaEngine) ----------------
  // kinds: mood / genre / scene; rarity 0 common, 1 rare, 2 epic.
  const POOL = (function () {
    function t(id, kind, rarity, keywords, o) {
      o = o || {};
      return { card: { id: id, kind: kind, rarity: rarity, keywords: keywords },
        conditions: o.conditions, seasons: o.seasons, temperature: o.temperature, wind: o.wind };
    }
    return [
      t("mood.calm", "mood", 0, ["ambient", "new age", "classical", "acoustic"], { conditions: ["cloudy", "fog"] }),
      t("mood.cozy", "mood", 0, ["folk", "singer", "jazz"], { temperature: [-30, 12] }),
      t("mood.bright", "mood", 0, ["pop", "dance"], { conditions: ["clear"], temperature: [18, 50] }),
      t("mood.melancholy", "mood", 1, ["indie", "alternative", "blues"], { conditions: ["rain", "fog"] }),
      t("mood.euphoric", "mood", 2, ["electronic", "house", "dance"], { conditions: ["clear"], seasons: ["summer"] }),
      t("mood.dramatic", "mood", 2, ["soundtrack", "classical", "rock"], { conditions: ["storm"] }),
      t("genre.lofi", "genre", 0, ["lo-fi", "chill", "hip-hop", "r&b"], { conditions: ["rain", "cloudy"] }),
      t("genre.jazz", "genre", 0, ["jazz", "blues"], { seasons: ["autumn", "winter"] }),
      t("genre.pop", "genre", 0, ["pop"], { seasons: ["spring", "summer"] }),
      t("genre.rock", "genre", 1, ["rock", "metal"], { wind: [30, 200] }),
      t("genre.classical", "genre", 1, ["classical", "piano"], { conditions: ["snow", "fog"] }),
      t("genre.electronic", "genre", 2, ["electronic", "techno", "house"], { temperature: [24, 50] }),
      t("scene.rainyWindow", "scene", 0, ["jazz", "lo-fi", "acoustic", "singer"], { conditions: ["rain"] }),
      t("scene.morningWalk", "scene", 0, ["pop", "folk", "indie"], { conditions: ["clear"], seasons: ["spring", "autumn"] }),
      t("scene.beachDrive", "scene", 1, ["pop", "reggae", "dance", "rock"], { seasons: ["summer"], temperature: [25, 50] }),
      t("scene.fireside", "scene", 1, ["folk", "country", "acoustic"], { seasons: ["winter"], temperature: [-30, 8] }),
      t("scene.snowfall", "scene", 2, ["classical", "soundtrack", "new age", "piano"], { conditions: ["snow"] }),
      t("scene.windRider", "scene", 2, ["rock", "electronic", "soundtrack"], { wind: [40, 200] }),
    ];
  })();
  const KINDS = ["mood", "genre", "scene"];
  const ENGINE = { epic: 5, rare: 25, pityThreshold: 9, offWeather: 0.15 };

  function fits(tpl, w) {
    const inRange = function (r, v) { return !r || (v >= r[0] && v <= r[1]); };
    return (!tpl.conditions || tpl.conditions.indexOf(w.condition) >= 0)
      && (!tpl.seasons || tpl.seasons.indexOf(w.season) >= 0)
      && inRange(tpl.temperature, w.temperature) && inRange(tpl.wind, w.wind);
  }

  function rollRarity(rng) {
    const roll = Math.floor(rng() * 100);
    if (roll < ENGINE.epic) return 2;
    if (roll < ENGINE.epic + ENGINE.rare) return 1;
    return 0;
  }

  // Weighted pick among the kind's templates of `rarity`, falling back to lower tiers.
  function pick(kind, rarity, w, rng) {
    const ofKind = POOL.filter(function (p) { return p.card.kind === kind; });
    let tier = rarity;
    let pool = ofKind.filter(function (p) { return p.card.rarity === tier; });
    while (pool.length === 0 && tier > 0) {
      tier -= 1;
      pool = ofKind.filter(function (p) { return p.card.rarity === tier; });
    }
    if (pool.length === 0) pool = ofKind;
    if (pool.length === 0) return null;
    const weights = pool.map(function (p) { return fits(p, w) ? 1 : ENGINE.offWeather; });
    let target = rng() * weights.reduce(function (a, b) { return a + b; }, 0);
    for (let i = 0; i < pool.length; i++) {
      if (target < weights[i]) return pool[i].card;
      target -= weights[i];
    }
    return pool[pool.length - 1].card;
  }

  // One card per kind. `pity` counts draws without a rare-or-better card.
  function draw(w, pity, rng) {
    const cards = KINDS.map(function (k) { return pick(k, rollRarity(rng), w, rng); }).filter(Boolean);
    if (cards.some(function (c) { return c.rarity >= 1; })) return { cards: cards, pity: 0 };
    if (pity >= ENGINE.pityThreshold && cards.length > 0) {
      const index = Math.floor(rng() * cards.length);
      const upgraded = pick(cards[index].kind, 1, w, rng);
      if (upgraded && upgraded.rarity >= 1) {
        cards[index] = upgraded;
        return { cards: cards, pity: 0 };
      }
    }
    return { cards: cards, pity: pity + 1 };
  }

  function seasonOf(date, southern) {
    const m = date.getMonth() + 1;
    const north = m >= 3 && m <= 5 ? "spring" : m >= 6 && m <= 8 ? "summer" : m >= 9 && m <= 11 ? "autumn" : "winter";
    if (!southern) return north;
    return { spring: "autumn", summer: "winter", autumn: "spring", winter: "summer" }[north];
  }

  function weatherOf(settings, date) {
    return { condition: settings.condition || "clear", temperature: Number(settings.temperature === undefined ? 20 : settings.temperature),
      wind: Number(settings.windSpeed === undefined ? 10 : settings.windSpeed),
      season: seasonOf(date || new Date(), settings.southernHemisphere === true) };
  }

  // ---- looks -----------------------------------------------------------------
  const RARITY_COLORS = [
    [[0.43, 0.66, 1.0], [0.25, 0.33, 0.62]],
    [[0.31, 0.82, 0.77], [0.55, 0.48, 1.0]],
    [[1.0, 0.70, 0.28], [1.0, 0.36, 0.60], [0.62, 0.35, 1.0]],
  ];
  // Per-card colours and symbol; rarity only drives the effects on top.
  const THEMES = {
    "mood.calm": [[[0.45, 0.75, 0.85], [0.30, 0.45, 0.75]], "moon.stars"],
    "mood.cozy": [[[0.95, 0.62, 0.38], [0.70, 0.35, 0.30]], "cup.and.saucer"],
    "mood.bright": [[[1.0, 0.85, 0.30], [1.0, 0.55, 0.25]], "sun.max"],
    "mood.melancholy": [[[0.55, 0.60, 0.80], [0.30, 0.30, 0.55]], "cloud.rain"],
    "mood.euphoric": [[[1.0, 0.45, 0.75], [0.65, 0.40, 1.0], [0.30, 0.80, 1.0]], "sparkles"],
    "mood.dramatic": [[[0.95, 0.30, 0.35], [0.60, 0.30, 0.85], [0.20, 0.15, 0.40]], "bolt.fill"],
    "genre.lofi": [[[0.80, 0.60, 0.85], [0.40, 0.40, 0.70]], "headphones"],
    "genre.jazz": [[[0.85, 0.60, 0.30], [0.30, 0.20, 0.40]], "music.mic"],
    "genre.pop": [[[1.0, 0.55, 0.70], [1.0, 0.75, 0.40]], "heart.fill"],
    "genre.rock": [[[0.85, 0.25, 0.30], [0.20, 0.20, 0.28]], "speaker.wave.3.fill"],
    "genre.classical": [[[0.92, 0.84, 0.66], [0.55, 0.45, 0.38]], "music.quarternote.3"],
    "genre.electronic": [[[0.20, 0.90, 0.95], [0.60, 0.30, 1.0], [1.0, 0.30, 0.80]], "waveform"],
    "scene.rainyWindow": [[[0.45, 0.65, 0.80], [0.25, 0.35, 0.50]], "cloud.drizzle"],
    "scene.morningWalk": [[[1.0, 0.78, 0.50], [0.55, 0.80, 0.65]], "sunrise"],
    "scene.beachDrive": [[[0.30, 0.80, 0.85], [1.0, 0.70, 0.40]], "car"],
    "scene.fireside": [[[1.0, 0.60, 0.25], [0.55, 0.20, 0.20]], "flame"],
    "scene.snowfall": [[[0.80, 0.92, 1.0], [0.50, 0.65, 0.90], [0.75, 0.70, 1.0]], "snowflake"],
    "scene.windRider": [[[0.40, 0.85, 0.70], [0.25, 0.45, 0.85], [0.70, 0.55, 1.0]], "wind"],
  };
  const KIND_SYMBOL = { mood: "face.smiling", genre: "music.note", scene: "photo" };
  const toHex = function (c, a) { return hex(c[0], c[1], c[2], a); };
  function paletteOf(card) {
    const theme = THEMES[card.id];
    return (theme ? theme[0] : RARITY_COLORS[card.rarity]).map(function (c) { return toHex(c); });
  }
  function symbolOf(card) { const theme = THEMES[card.id]; return theme ? theme[1] : KIND_SYMBOL[card.kind]; }
  const EPIC = RARITY_COLORS[2].map(function (c) { return toHex(c); });

  // ---- layout and timing -----------------------------------------------------
  const W = 288, H = 276, MID_X = 144, CARD_Y = 100;
  const CARD_W = Math.min((W - 36) / 3, 92), CARD_H = CARD_W / 0.72;
  const slotX = function (i) { return MID_X + (i - 1) * (CARD_W + 10); };
  const STEP = 0.9, BOW = 0.6, SHATTER = 0.9;
  const COUNT_END = 3 * STEP, DEAL = COUNT_END + BOW, DUST = 0.9;
  const SIT = 0.58, INTRO = 0.15, CROUCH = 0.12, HOP = STEP * (1 - SIT);
  const SPACING = 9, LINE_LEFT = 18, LINE_LEN = 252, MID_Y = CARD_Y + 6;
  const STATIONS = [{ x: 0.10, line: 4 }, { x: 0.25, line: 1 }, { x: 0.40, line: 3 }];
  const FINISH = { x: 0.5, line: 2 };
  const LANDINGS = [[INTRO, STATIONS[0]], [STEP, STATIONS[1]], [2 * STEP, STATIONS[2]], [COUNT_END, FINISH]];
  const absX = function (f) { return LINE_LEFT + f * LINE_LEN; };

  // Staff geometry: lines close in, outer ones lagging a little.
  function lineQ(i, t) { return smooth(t / COUNT_END * 1.1 - 0.05 * Math.abs(i - 2)); }
  function lineY(i, t) { return MID_Y + (i - 2) * SPACING * (1 - lineQ(i, t)); }
  function yOnStaff(line, t) {
    const lo = Math.floor(line), hi = Math.min(4, lo + 1), f = line - lo;
    return lineY(lo, t) * (1 - f) + lineY(hi, t) * f;
  }

  // The note's pose: hop arcs, crouch before launch, damped squash after landing.
  function pose(t) {
    let sx = 1, sy = 1;
    for (let i = LANDINGS.length - 1; i >= 0; i--) {
      if (LANDINGS[i][0] <= t) {
        const age = t - LANDINGS[i][0];
        if (age < 0.4) { const d = Math.exp(-age * 9) * Math.cos(age * 24); sy -= 0.2 * d; sx += 0.1 * d; }
        break;
      }
    }
    if (t >= COUNT_END) return { x: FINISH.x, line: FINISH.line, lift: 0, lean: 0, sx: sx, sy: sy };
    if (t < INTRO) {
      const u = t / INTRO;
      return { x: STATIONS[0].x, line: STATIONS[0].line, lift: 26 * (1 - u * u), lean: 0, sx: 1, sy: 1 + 0.08 * u };
    }
    const k = Math.min(2, Math.floor(t / STEP));
    const from = STATIONS[k], to = k < 2 ? STATIONS[k + 1] : FINISH;
    const local = t - k * STEP, hopStart = STEP * SIT;
    const u = clamp01((local - hopStart) / HOP);
    if (local < hopStart && local > hopStart - CROUCH) {
      const c = smooth((local - (hopStart - CROUCH)) / CROUCH);
      sy -= 0.16 * c; sx += 0.08 * c;
    }
    const e = smooth(u), air = Math.sin(Math.PI * u);
    if (u > 0 && u < 1) { sy += 0.12 * air; sx -= 0.06 * air; }
    const sway = u === 0 ? 2.5 * Math.sin(t * 3.4) : 0;
    return { x: from.x + (to.x - from.x) * e, line: from.line + (to.line - from.line) * e,
      lift: 26 * 4 * u * (1 - u), lean: 16 * air + sway, sx: sx, sy: sy };
  }

  // ---- scene building blocks -------------------------------------------------
  const track = function (prop, keys, loop) { const o = { prop: prop, keys: keys.map(function (k) { return { t: k[0], v: k[1], e: k[2] }; }) }; if (loop) o.loop = loop; return o; };
  const lin = function (colors, from, to) { return { linear: { colors: colors, from: from, to: to } }; };
  const sampled = function (t0, t1, dt, fn) {
    const out = [];
    for (let t = t0; t < t1; t += dt) out.push(fn(t));
    out.push(fn(t1));
    return out;
  };

  // Staff, note, numbers, trail and final dust of the countdown. Absolute scene time.
  function countdownLayers() {
    const layers = [];
    const fadeStart = DEAL, fadeEnd = DEAL + DUST;
    for (let i = 0; i < 5; i++) {
      const t0 = 0.05 * Math.abs(i - 2) * COUNT_END / 1.1, t1 = (1 + 0.05 * Math.abs(i - 2)) * COUNT_END / 1.1;
      const plucks = LANDINGS.map(function (l) {
        const weight = Math.abs(i - l[1].line) < 0.5 ? 1 : 0.22;
        return { t: l[0], x: absX(l[1].x) - LINE_LEFT, amp: 2.6 * weight };
      });
      layers.push({ kind: "wave", id: "staff" + i, x: LINE_LEFT, y: MID_Y + (i - 2) * SPACING, anchor: [0, 0.5], until: fadeEnd,
        wave: { length: LINE_LEN, plucks: plucks, breathe: 0.5 },
        strokes: [{ color: hex(1, 1, 1, 0.22), width: 3 }, { color: hex(0, 0, 0, 0.85), width: 1.2 }],
        tracks: [track("y", [[t0, MID_Y + (i - 2) * SPACING, "linear"], [t1, MID_Y, "inOut"]]),
          track("opacity", [[fadeStart, 1], [fadeEnd, 0, "inOut"]])] });
    }
    // Numbers stand on their line while the note is there and drift off at the hop.
    for (let k = 0; k < 3; k++) {
      const st = STATIONS[k];
      const keys = sampled(k * STEP, (k + 1) * STEP, 0.03, function (t) {
        const sat = t - k * STEP;
        const appear = smooth((sat - (k === 0 ? INTRO : 0)) / (STEP * 0.2));
        const hop = smooth((sat - STEP * SIT) / (HOP * 0.7));
        return { t: t, y: yOnStaff(st.line, t) - 12 - 5 * (1 - appear) - 8 * hop, o: appear * (1 - hop), s: 0.8 + 0.2 * appear };
      });
      layers.push({ kind: "text", id: "n" + (3 - k), text: String(3 - k), x: absX(st.x) + 16, y: 0, size: 24, weight: "bold",
        design: "serif", italic: true, fill: GOLD, from: k * STEP, until: (k + 1) * STEP,
        tracks: [track("y", keys.map(function (s) { return [s.t, s.y]; })), track("opacity", keys.map(function (s) { return [s.t, s.o]; })),
          track("scale", keys.map(function (s) { return [s.t, s.s]; }))] });
    }
    // The note: white head and stem; position, lean and squash sampled from pose().
    const end = DEAL + 0.45;
    const poses = sampled(0, end, 0.03, function (t) {
      const p = pose(t);
      const tb = clamp01((t - COUNT_END) / BOW);
      const bowAngle = t >= COUNT_END ? 34 * Math.sin(Math.PI * Math.pow(tb, 0.75)) : 0;
      const bowDip = t >= COUNT_END ? 3 * Math.sin(Math.PI * tb) : 0;
      const dissolve = smooth((t - DEAL) / 0.45);
      const intro = t < INTRO ? clamp01(t / INTRO) : 1;
      return { t: t, x: absX(p.x), y: yOnStaff(p.line, t) - p.lift + bowDip - 10 * dissolve, r: p.lean + bowAngle,
        sx: p.sx * (1 + 0.08 * dissolve), sy: p.sy, o: intro * (1 - dissolve) };
    });
    const part = function (prop, key) { return track(prop, poses.map(function (s) { return [s.t, s[key]]; })); };
    layers.push({ kind: "group", id: "note", until: end, tracks: [part("x", "x"), part("y", "y"), part("rotation", "r"),
      part("scaleX", "sx"), part("scaleY", "sy"), part("opacity", "o")],
      children: [
        { kind: "rect", x: 5, y: -14, w: 1.6, h: 26, fill: WHITE, strokes: [{ color: hex(0, 0, 0, 0.45), width: 0.6 }] },
        { kind: "ellipse", w: 11, h: 8, rotation: -20, fill: WHITE, strokes: [{ color: hex(0, 0, 0, 0.45), width: 0.6 }] },
      ] });
    // Gold dust shed during each hop, then the burst when the note dissolves.
    for (let k = 0; k < 3; k++) {
      layers.push({ kind: "emitter", emitter: { seed: 10 * (k + 1), count: 24, t0: k * STEP + STEP * SIT, t1: (k + 1) * STEP, life: 0.55,
        region: [0, 2, 8, 0], follow: "note", vx: [0, 0], vy: [10, 32], ay: 36, size: [0.8, 2.4], color: GOLD, glow: 0.18, twinkle: 1, drift: 3 } });
    }
    layers.push({ kind: "emitter", emitter: { seed: 77, count: 48, t0: DEAL, t1: DEAL, life: 0.55, region: [MID_X - 6, MID_Y - 27, 12, 29],
      vx: [-23, 23], vy: [-44, -10], ay: 180, size: [0.9, 2.6], color: GOLD, glow: 0.16, twinkle: 1, topFirst: 0.3 } });
    return layers;
  }

  // One card; `dealAt` is when it flies in, `mode` is deal | chosen | other | still.
  function cardLayer(card, i, mode, dealAt) {
    const pal = paletteOf(card), glow = pal[0], r = card.rarity;
    const epic = r === 2;
    const glowOpacity = 0.25 + 0.18 * r + 0.2 * 0.5;
    const children = [
      { kind: "rect", w: CARD_W, h: CARD_H, radius: 16, fill: glow, blur: 10 + r * 4 + 2, opacity: glowOpacity,
        osc: epic ? [{ prop: "opacity", amp: 0.1, freq: 3 / (2 * Math.PI) }, { prop: "blur", amp: 2, freq: 3 / (2 * Math.PI) }] : [] },
      { kind: "rect", w: CARD_W, h: CARD_H, radius: 16, fill: lin(pal, [0, 0], [1, 1]) },
      { kind: "rect", w: CARD_W, h: CARD_H, radius: 16, fill: lin([hex(1, 1, 1, 0.28), hex(1, 1, 1, 0), hex(0, 0, 0, 0.22)], [0.5, 0], [0.5, 1]) },
    ];
    if (r > 0) {
      const period = epic ? 1 / 0.45 : 1 / 0.3;
      children.push({ kind: "group", w: CARD_W, h: CARD_H, radius: 16, clip: true, children: [
        { kind: "rect", w: CARD_W * 0.5, h: CARD_H * 1.8, rotation: 20, add: true,
          fill: lin([hex(1, 1, 1, 0), hex(1, 1, 1, epic ? 0.55 : 0.35), hex(1, 1, 1, 0)], [0, 0.5], [1, 0.5]),
          tracks: [track("x", [[0, -CARD_W * 0.8], [period, CARD_W * 0.8]], period)] }] });
    }
    const edge = [hex(1, 1, 1, 0.9), toHex(RARITY_COLORS[r][0], 0.2), hex(1, 1, 1, 0.7), toHex(RARITY_COLORS[r][0], 0.3), hex(1, 1, 1, 0.9)];
    children.push({ kind: "rect", w: CARD_W, h: CARD_H, radius: 16, strokes: [{ color: { angular: { colors: edge, center: [0.5, 0.5] } }, width: r === 0 ? 1 : 1.5 }] });
    children.push({ kind: "text", text: card.tag, y: -CARD_H / 2 + 14, size: 9, weight: "bold", fill: hex(1, 1, 1, 0.8) });
    children.push({ kind: "symbol", symbol: symbolOf(card), y: -6, size: 26, weight: "semibold", fill: WHITE });
    children.push({ kind: "text", text: card.name, y: 24, w: CARD_W - 16, size: 11, weight: "semibold", fill: WHITE });
    for (let s = 0; s <= r; s++) {
      children.push({ kind: "symbol", symbol: "star.fill", x: (s - r / 2) * 10, y: CARD_H / 2 - 14, size: 8, fill: WHITE });
    }

    const layer = { kind: "group", id: "card" + i, w: CARD_W, h: CARD_H, x: slotX(i), y: CARD_Y, children: children };
    if (mode === "deal") {
      const d = dealAt + i * 0.12;
      layer.from = d;
      layer.hit = { id: "pick:" + card.id, label: card.tag + ": " + card.name + ", " + card.rarityName, hoverScale: 1.06 };
      layer.tracks = [
        track("x", [[d, MID_X], [d + 0.45, slotX(i), "out"]]),
        track("scale", [[d, 0.2], [d + 0.3, 1.08, "out"], [d + 0.5, 1, "inOut"]]),
        track("rotation", [[d, (i - 1) * 28], [d + 0.4, 0, "out"]]),
        track("opacity", [[d, 0], [d + 0.15, 1]]),
      ];
    } else if (mode === "chosen") {
      layer.tracks = [track("x", [[0, slotX(i)], [1, MID_X, "inOut"]]), track("scale", [[0, 1], [1, 1.1, "inOut"]])];
    } else if (mode === "other") {
      layer.shatter = { at: 0, cols: 4, rows: 6, duration: SHATTER };
    }
    return layer;
  }

  // ---- header: weather glyphs and the compact Again button -------------------
  const SEASON_SYMBOL = { spring: "leaf", summer: "flame", autumn: "leaf.fill", winter: "snowflake" };
  const SEASON_TINT = { spring: [0.20, 0.78, 0.35], summer: [1.0, 0.62, 0.04], autumn: [0.64, 0.52, 0.37], winter: [0.39, 0.82, 1.0] };
  const COND_SYMBOL = { clear: "sun.max", cloudy: "cloud", rain: "cloud.rain", snow: "snow", fog: "cloud.fog", storm: "cloud.bolt" };
  const COND_TINT = { clear: [1.0, 0.84, 0.04], cloudy: [0.56, 0.56, 0.58], rain: [0.04, 0.52, 1.0], snow: [0.39, 0.82, 1.0], fog: [0.6, 0.6, 0.62], storm: [0.37, 0.36, 0.9] };
  const TAU = 2 * Math.PI;
  const hz = function (radPerSec) { return radPerSec / TAU; };
  const osc = function (prop, amp, rad, o) { return Object.assign({ prop: prop, amp: amp, freq: hz(rad) }, o || {}); };

  function glyphMotion(name, w) {
    const wind = Math.min(w.wind, 80);
    if (name === "condition") {
      switch (w.condition) {
        case "clear": return { tracks: [track("rotation", [[0, 0], [9, 360]], 9)], osc: [osc("scale", 0.08, 2)] };
        case "cloudy": return { osc: [osc("x", 2.5, 1.1)] };
        case "rain": return { osc: [osc("y", 1.6, 5)] };
        case "snow": return { osc: [osc("x", 1.5, 1.4), osc("y", 1.5, 2.2), osc("rotation", 14, 1.4)] };
        case "fog": return { opacity: 0.55, osc: [osc("opacity", 0.45, 1.3)] };
        default: return { opacity: 0.45, osc: [{ prop: "opacity", amp: 0.55, freq: 4.5 / Math.PI, wave: "pulse", power: 8 }] };
      }
    }
    if (name === "temperature") return { osc: [osc("scale", 0.08, 2 + Math.max(w.temperature, 0) / 15)] };
    if (name === "wind") { const pace = 1.5 + wind / 12; return { osc: [osc("x", 1.5 + wind / 30, pace), osc("rotation", 4, pace)] }; }
    return { osc: [osc("x", 1.5, 1.6), osc("y", 1.2, 3.2), osc("rotation", 16, 1.6)] };
  }

  function headerLayers(ctx, w) {
    const t = ctx.t;
    const temp = w.temperature;
    const items = [
      { name: "condition", symbol: COND_SYMBOL[w.condition], tint: COND_TINT[w.condition], value: t("gacha.weather." + w.condition) },
      { name: "temperature", symbol: temp <= 5 ? "thermometer.snowflake" : temp <= 24 ? "thermometer" : "thermometer.sun",
        tint: temp <= 5 ? [0.39, 0.82, 1.0] : temp <= 24 ? [0.20, 0.78, 0.35] : temp <= 32 ? [1.0, 0.62, 0.04] : [1.0, 0.27, 0.23],
        value: Math.round(temp) + " °C" },
      { name: "wind", symbol: "wind", tint: [0.19, 0.69, 0.78], value: Math.round(w.wind) + " km/h" },
      { name: "season", symbol: SEASON_SYMBOL[w.season], tint: SEASON_TINT[w.season], value: t("gacha.season." + w.season) },
    ];
    const glyphs = [], labels = [];
    items.forEach(function (it, i) {
      const x = 22 + i * 26, y = 14, motion = glyphMotion(it.name, w), id = "info:" + it.name;
      glyphs.push({ kind: "group", x: x, y: y, w: 22, h: 22, hit: { id: id, label: it.value, hoverScale: 1.12 }, children: [
        { kind: "symbol", symbol: it.symbol, size: 13, weight: "semibold", fill: toHex(it.tint),
          opacity: motion.opacity === undefined ? 1 : motion.opacity, tracks: motion.tracks || [], osc: motion.osc || [] },
      ] });
      // The value shows in a pill under its glyph, clear of the neighbouring glyphs.
      const width = 16 + it.value.length * 6.2;
      labels.push({ kind: "group", x: Math.max(x, width / 2 + 6), y: y + 24, w: width, h: 20, showOnHover: id, children: [
        { kind: "rect", w: width, h: 20, radius: 10, fill: toHex(it.tint, 0.3) },
        { kind: "text", text: it.value, size: 11, weight: "medium", fill: "$label" },
      ] });
    });
    return { glyphs: glyphs, labels: labels };
  }

  // Glowing capsule with a travelling sheen.
  function againButton(label, id, x, y, wd, ht, size) {
    return { kind: "group", id: id, x: x, y: y, w: wd, h: ht, hit: { id: "again", label: label, hoverScale: 1.06 }, children: [
      { kind: "rect", w: wd, h: ht, radius: ht / 2, fill: EPIC[0], blur: 6, opacity: 0.55 },
      { kind: "rect", w: wd, h: ht, radius: ht / 2, fill: lin(EPIC, [0, 0.5], [1, 0.5]) },
      { kind: "group", w: wd, h: ht, radius: ht / 2, clip: true, children: [
        { kind: "rect", w: wd * 0.35, h: ht * 2, rotation: 20, add: true,
          fill: lin([hex(1, 1, 1, 0), hex(1, 1, 1, 0.55), hex(1, 1, 1, 0)], [0, 0.5], [1, 0.5]),
          tracks: [track("x", [[0, -wd * 0.6], [2.4, wd * 0.6]], 2.4)] }] },
      { kind: "rect", w: wd, h: ht, radius: ht / 2, strokes: [{ color: hex(1, 1, 1, 0.45), width: 1 }] },
      { kind: "symbol", symbol: "arrow.counterclockwise", x: -wd * 0.3, size: size, weight: "bold", fill: WHITE },
      { kind: "text", text: label, x: wd * 0.1, size: size, weight: "bold", fill: WHITE },
    ] };
  }

  // The glowing round Play button; dancing notes replace the icon while playing.
  function playButton(label, accent, playing, audible, beat, at) {
    const pulse = playing && audible
      ? { osc: [{ prop: "scale", amp: 0.25, freq: beat, wave: "pulse", power: 3 }], scale: 1.15 }
      : { osc: [osc("scale", 0.125, 2.5)], scale: 1.275 };
    const children = [
      { kind: "ellipse", w: 44, h: 44, fill: accent, blur: 10, opacity: 0.55, scale: pulse.scale, osc: pulse.osc },
      { kind: "ellipse", w: 44, h: 44, strokes: [{ color: { angular: { colors: [WHITE, accent, hex(1, 1, 1, 0.2), accent, WHITE], center: [0.5, 0.5] } }, width: 2 }],
        tracks: [track("angle", [[0, 0], [4, 360]], 4)] },
      { kind: "ellipse", w: 38, h: 38, fill: lin([accent, accent.slice(0, 7) + "8C"], [0.5, 0], [0.5, 1]) },
    ];
    if (!playing) {
      children.push({ kind: "symbol", symbol: "play.fill", x: 1, size: 18, weight: "bold", fill: WHITE });
    } else {
      [[0, 7, 17, -7], [0.5, 9, 14, 8]].forEach(function (n) {
        const phase = n[0], hop = n[1], size = n[2], dx = n[3];
        const move = audible
          ? { osc: [{ prop: "y", amp: -hop, freq: beat, phase: phase, wave: "pulse", power: 0.8 },
            { prop: "scaleY", amp: -0.18, freq: beat, phase: phase + 0.5, wave: "pulse", power: 12 },
            { prop: "rotation", amp: 10, freq: beat / 2, phase: phase / 2 }] } : { osc: [] };
        children.push({ kind: "group", x: dx, y: 4, w: size, h: size,
          osc: move.osc, children: [
            { kind: "symbol", symbol: "music.note", size: size, weight: "bold", fill: accent, blur: 3, opacity: 0.9 },
            { kind: "symbol", symbol: "music.note", size: size, weight: "bold", fill: WHITE }] });
      });
    }
    return { kind: "group", id: "play", x: MID_X, y: 248, w: 44, h: 44, from: at, children: children,
      hit: playing ? undefined : { id: "play", label: label, hoverScale: 1.06 },
      tracks: [track("scale", [[at, 0.3], [at + 0.25, 1.1, "out"], [at + 0.45, 1, "inOut"]]), track("opacity", [[at, 0], [at + 0.15, 1]])] };
  }

  // ---- backdrop: drifting colour blobs and beat ripples (covers the card) ----
  function backdropScene(colors, beating, bpm, epoch, key) {
    const beat = (bpm > 0 ? bpm : 100) / 60;
    const layers = [];
    for (let i = 0; i < 3; i++) {
      const w = 0.35 + 0.12 * i, ph = i * 2.1;
      layers.push({ kind: "ellipse", w: W * 0.7, h: W * 0.7, fill: colors[i % colors.length], blur: 34, opacity: 0.2, x: W * 0.5, y: H * 0.5,
        osc: [{ prop: "x", amp: W * 0.32, freq: hz(w), phase: ph / TAU + 0.25 }, { prop: "y", amp: H * 0.3, freq: hz(w * 1.3), phase: ph * 1.3 / TAU }]
          .concat(beating ? [{ prop: "opacity", amp: 0.1, freq: beat, wave: "pulse", power: 3 }] : [{ prop: "opacity", amp: 0, freq: 1 }]) });
    }
    const period = 1 / (beat * 0.5);
    for (let i = 0; i < 3; i++) {
      const p0 = i / 3, cut = period * (1 - p0);
      const peak = beating ? 0.22 : 0.1;
      layers.push({ kind: "ellipse", x: W / 2, y: H * 0.45, w: W, h: W, strokes: [{ color: colors[i % colors.length], width: 1.5 }],
        tracks: [track("scale", [[0, 0.3 + 0.9 * p0], [cut, 1.2], [cut + 0.001, 0.3], [period, 0.3 + 0.9 * p0]], period),
          track("opacity", [[0, (1 - p0) * peak], [cut, 0], [cut + 0.001, peak], [period, (1 - p0) * peak]], period)] });
    }
    return { type: "scene", key: key, epoch: epoch, width: W, height: H, fit: "cover", fps: 30, layers: layers };
  }

  // ---- state machine ----------------------------------------------------------
  const state = { phase: "idle", round: 0, pity: 0, cards: [], chosen: null, track: null, audible: false,
    epoch: 0, roundEpoch: 0, revealedAt: 0, failure: null, timers: [], cache: null };

  function later(ctx, seconds, fn) {
    state.timers.push(setTimeout(fn, seconds * 1000));
  }
  function cancelTimers() { state.timers.forEach(clearTimeout); state.timers = []; }
  function failureOf(err) {
    const s = String(err);
    if (s.indexOf("notAuthorized") >= 0) return "auth";
    if (s.indexOf("notRunning") >= 0) return "notRunning";
    return "failed";
  }
  const reduced = function (ctx) { return ctx.reduceMotion === true; };

  function startRound(ctx) {
    const interrupting = state.chosen !== null && state.track !== null;
    cancelTimers();
    if (interrupting && ctx.media && ctx.media.library) ctx.media.library.pause().catch(function () {});
    const result = draw(weatherOf(ctx.settings || {}), state.pity, Math.random);
    state.cards = result.cards; state.pity = result.pity;
    state.chosen = null; state.track = null; state.audible = false; state.failure = null;
    state.round += 1;
    state.epoch = state.roundEpoch = now();
    const round = state.round;
    const wait = reduced(ctx) ? 0 : DEAL;
    state.phase = wait > 0 ? "countdown" : "choosing";
    if (wait > 0) {
      later(ctx, wait, function () { if (state.round === round && state.phase === "countdown") { state.phase = "choosing"; ctx.invalidate(); } });
    }
    ctx.invalidate();
  }

  function choose(ctx, cardID) {
    if (state.phase !== "choosing") return;
    const card = state.cards.filter(function (c) { return c.id === cardID; })[0];
    if (!card) return;
    state.chosen = card.id; state.phase = "picking"; state.epoch = now(); state.track = null;
    const round = state.round;
    const picked = ctx.media.library.pickRandom(card.keywords).then(function (v) { return { v: v }; }, function (e) { return { e: e }; });
    Promise.all([picked, delay(reduced(ctx) ? 0 : SHATTER * 1000)]).then(function (res) {
      if (state.round !== round || state.phase !== "picking") return;
      const out = res[0];
      if (out.e !== undefined) { state.failure = failureOf(out.e); state.phase = "failed"; }
      else if (!out.v) { state.failure = "empty"; state.phase = "failed"; }
      else { state.track = out.v; state.phase = "revealed"; state.revealedAt = now() - state.epoch; }
      ctx.invalidate();
    });
    ctx.invalidate();
  }

  function play(ctx) {
    if (state.phase !== "revealed" || !state.track) return;
    const round = state.round, track = state.track;
    ctx.media.library.play(track.persistentID).then(function () {
      if (state.round !== round) return;
      state.phase = "playing"; state.audible = true;
      ctx.invalidate();
      monitor(ctx, round, track, 0);
    }, function (e) {
      if (state.round !== round) return;
      state.failure = failureOf(e); state.phase = "failed"; ctx.invalidate();
    });
  }

  // Ends the round when the song finishes: Music would roll on to the next
  // library track by itself, so the end is caught just before it.
  function monitor(ctx, round, track, polls) {
    later(ctx, 0.5, function () {
      if (state.round !== round || state.phase !== "playing") return;
      ctx.media.nowPlaying().then(function (np) {
        if (state.round !== round || state.phase !== "playing") return;
        const finish = function () { state.audible = false; state.phase = "finished"; ctx.invalidate(); };
        if (np) {
          const same = np.title === track.title && np.artist === track.artist;
          const nearEnd = np.duration > 0 && np.duration - np.position < 1;
          if (!same || nearEnd) {
            (np.playing ? ctx.media.library.pause().catch(function () {}) : Promise.resolve()).then(finish);
            return;
          }
          if (state.audible !== np.playing) { state.audible = np.playing; ctx.invalidate(); }
        } else if (polls + 1 > 4) { finish(); return; }
        monitor(ctx, round, track, polls + 1);
      }, function () { monitor(ctx, round, track, polls + 1); });
    });
  }

  // ---- render ------------------------------------------------------------------
  // Online weather (opt-in, fetched by the host) wins over the manual settings.
  function currentWeather(ctx) {
    const settings = ctx.settings || {};
    const online = ctx.weather ? ctx.weather.current() : null;
    if (online && online.condition) {
      return { condition: online.condition, temperature: Number(online.temperature),
        wind: Number(online.wind), season: seasonOf(new Date(), settings.southernHemisphere === true) };
    }
    return weatherOf(settings);
  }

  function view(ctx) {
    const t = ctx.t, w = currentWeather(ctx);
    const cards = state.cards.map(function (c) {
      return Object.assign({}, c, { tag: t("gacha.kind." + c.kind), name: t("gacha.card." + c.id), rarityName: t("gacha.rarity." + c.rarity) });
    });
    const phase = state.phase, still = reduced(ctx);
    const chosen = cards.filter(function (c) { return c.id === state.chosen; })[0];
    const best = cards.reduce(function (m, c) { return Math.max(m, c.rarity); }, 0);
    const accent = chosen ? paletteOf(chosen)[0] : EPIC[0];
    const bpm = state.track ? state.track.bpm : 0;
    const beating = phase === "playing" && state.audible;
    const burst = function (rarity, at) {
      return { kind: "sprite", x: MID_X, y: CARD_Y, w: 220, h: 220, sprite: { asset: "assets/burst_" + ["common", "rare", "epic"][rarity] + ".png", cols: 6, rows: 4, fps: 24, t0: at } };
    };
    const header = headerLayers(ctx, w);
    let layers = header.glyphs.slice(), key, epoch, fps = 30, restAt;

    if (phase === "countdown" || phase === "choosing") {
      const deal = still ? 0 : DEAL;
      epoch = state.roundEpoch; key = "r" + state.round + "a"; restAt = deal + 1.2;
      fps = phase === "countdown" ? 60 : 30;
      if (!still) layers = layers.concat(countdownLayers());
      layers.push(burst(best, deal));
      cards.forEach(function (c, i) { layers.push(cardLayer(c, i, "deal", deal)); });
      layers.push({ kind: "text", text: t("Pick one card to reveal your song."), x: MID_X, y: 196, size: 11, fill: "$secondaryLabel", from: deal + 0.8 });
    } else if (phase === "idle") {
      return null;
    } else {
      epoch = state.epoch; key = "r" + state.round + "b"; restAt = 2.2;
      cards.forEach(function (c, i) { layers.push(cardLayer(c, i, c.id === state.chosen ? "chosen" : "other", 0)); });
      if (phase === "revealed" || phase === "playing" || phase === "finished") {
        const at = state.revealedAt;
        if (chosen) layers.push(burst(chosen.rarity, at));
        const song = state.track || { title: "", artist: "" };
        const pop = [track("scale", [[at, 0.7], [at + 0.3, 1, "out"]]), track("opacity", [[at, 0], [at + 0.2, 1]])];
        layers.push({ kind: "group", x: MID_X, y: 196, from: at, tracks: pop, children: [
          { kind: "text", text: song.title, y: -8, w: W - 32, size: 14, weight: "semibold", fill: "$label" },
          { kind: "text", text: song.artist, y: 9, w: W - 32, size: 11, fill: "$secondaryLabel" }] });
        if (phase !== "finished") layers.push(playButton(t("Play"), accent, phase === "playing", state.audible, (bpm > 0 ? bpm : 100) / 60, at));
        else layers.push(againButton(t("Again"), "againMain", MID_X, 248, 112, 34, 14));
        if (phase === "playing") layers.push(againButton(t("Again"), "againTop", W - 50, 14, 76, 22, 11));
      } else if (phase === "failed") {
        const msg = { empty: "Your Music library has no songs.", auth: "Allow Switchly to control Music, then draw again.",
          notRunning: "Open Music first, then draw again.", failed: "Couldn't play a song." }[state.failure || "failed"];
        layers.push({ kind: "text", text: t(msg), x: MID_X, y: 196, w: W - 32, size: 11, fill: "$secondaryLabel" });
        layers.push(againButton(t("Again"), "againMain", MID_X, 248, 112, 34, 14));
      }
    }
    layers = layers.concat(header.labels); // hover pills stay above the cards
    const scene = { type: "scene", key: key, epoch: epoch, width: W, height: H, fps: fps, fit: "width", restAt: restAt, layers: layers };
    const colors = chosen ? paletteOf(chosen) : (cards.length ? paletteOf(cards.reduce(function (m, c) { return c.rarity > m.rarity ? c : m; }, cards[0])) : EPIC);
    const back = backdropScene(colors, beating, bpm, state.roundEpoch, "bd" + state.round + (beating ? "b" : "i") + (state.chosen || ""));
    return { type: "zstack", children: [back, scene] };
  }

  globalThis.__switchlyPlugin = {
    async render(ctx) {
      if (state.phase === "idle") startRound(ctx);
      const node = view(ctx);
      return node ? [{ slot: "center", node: { type: "surface", material: "glass", children: [node] } }] : [];
    },

    async onAction(ctx, id) {
      if (id === "again") startRound(ctx);
      else if (id === "play") play(ctx);
      else if (id.indexOf("pick:") === 0) choose(ctx, id.slice(5));
    },

    // Exposed for the unit tests.
    __test: { draw: draw, weatherOf: weatherOf, pose: pose, POOL: POOL, THEMES: THEMES },
  };
})();
