// Built-in Apple Music controls. Plain JS in the shape the SDK's
// definePlugin() emits, so it doubles as the reference plugin.
(function () {
  function btn(id, symbol, label) {
    return { type: "button", id: id, symbol: symbol, size: "l", label: label };
  }

  // iPod-style: track "screen" on top, dial below (love / previous / next /
  // play-pause around the ring).
  function wheelCard(ctx, np, st) {
    const info = { type: "vstack", spacing: "xs", align: "center", children: [
      { type: "marquee", value: np.title },
      { type: "text", value: np.artist, style: "caption" },
    ] };
    const screen = { type: "screen", children: [
      { type: "hstack", spacing: "m", align: "center", children:
        (st.showCover === false ? [] : [{ type: "image", source: { artwork: true }, size: "l", corner: "m" }]).concat([info]) },
    ] };
    const love = st.showLove === false ? { type: "spacer" }
      : { type: "toggle", id: "love", symbolOn: "heart.fill", symbolOff: "heart", isOn: !!np.liked, label: ctx.t("Love") };
    const small = function (id, symbol, label) { return { type: "button", id: id, symbol: symbol, size: "m", label: label }; };
    const dial = { type: "wheel", children: [
      love,
      small("previous", "backward.fill", ctx.t("Previous")),
      small("next", "forward.fill", ctx.t("Next")),
      small("toggle", np.playing ? "pause.fill" : "play.fill", ctx.t(np.playing ? "Pause" : "Play")),
      { type: "image", source: { symbol: "music.note" }, size: "m" },
    ] };
    return { type: "surface", material: "glass", children: [
      { type: "vstack", spacing: "m", align: "center", children: [screen, dial] },
    ] };
  }

  globalThis.__switchlyPlugin = {
    async render(ctx) {
      // Stopped / no track: keep the card so Play can start playback.
      const np = (await ctx.media.nowPlaying()) || { playing: false, title: ctx.t("Not playing"), artist: (ctx.app && ctx.app.name) || "Music" };
      const st = ctx.settings || {};
      if (st.wheelLayout === true) return [{ slot: "center", node: wheelCard(ctx, np, st) }];
      // Card below the window strip: cover left, track + transport right.
      const top = [];
      if (st.showLove !== false) {
        top.push({ type: "toggle", id: "love", symbolOn: "heart.fill", symbolOff: "heart", isOn: !!np.liked, label: ctx.t("Love") });
      }
      top.push({ type: "spacer" });
      top.push({ type: "image", source: { symbol: "music.note" }, size: "s" });
      const body = { type: "vstack", spacing: "xs", align: "center", children: [
        { type: "hstack", spacing: "xs", children: top },
        { type: "marquee", value: np.title },
        { type: "text", value: np.artist, style: "caption" },
        { type: "hstack", spacing: "m", children: [
          { type: "spacer" },
          btn("previous", "backward.fill", ctx.t("Previous")),
          btn("toggle", np.playing ? "pause.fill" : "play.fill", ctx.t(np.playing ? "Pause" : "Play")),
          btn("next", "forward.fill", ctx.t("Next")),
          { type: "spacer" },
        ] },
      ] };
      const row = st.showCover === false ? [body]
        : [{ type: "image", source: { artwork: true }, size: "l", corner: "m" }, body];
      return [{ slot: "center", node: { type: "surface", material: "glass", children: [
        { type: "hstack", spacing: "m", align: "center", children: row },
      ] } }];
    },

    async onAction(ctx, id, value) {
      if (id === "toggle") await ctx.media.togglePlayPause();
      else if (id === "next") await ctx.media.next();
      else if (id === "previous") await ctx.media.previous();
      else if (id === "love") await ctx.media.setLiked(value === 1);
    },
  };
})();
