function definePlugin(plugin) {
  if (!plugin || typeof plugin !== "object" || typeof plugin.render !== "function") {
    throw new TypeError("definePlugin() 需要一个包含 render 函数的对象");
  }
  if (plugin.onAction !== undefined && typeof plugin.onAction !== "function") {
    throw new TypeError("definePlugin() 的 onAction 必须是函数");
  }
  globalThis.__switchlyPlugin = plugin;
  return plugin;
}

function withType(type, props = {}) {
  return { ...props, type };
}

function stack(type, children, options = {}) {
  const node = withType(type, { children: [...children] });
  if (options.spacing !== undefined) node.spacing = options.spacing;
  if (options.align !== undefined) node.align = options.align;
  return node;
}

const ui = Object.freeze({
  hstack(children, options) {
    return stack("hstack", children, options);
  },
  vstack(children, options) {
    return stack("vstack", children, options);
  },
  zstack(children) {
    return withType("zstack", { children: [...children] });
  },
  spacer() {
    return withType("spacer");
  },
  surface(children, options = {}) {
    const node = withType("surface", { children: [...children] });
    if (options.material !== undefined) node.material = options.material;
    return node;
  },
  screen(children) {
    return withType("screen", { children: [...children] });
  },
  wheel(children) {
    return withType("wheel", { children: [...children] });
  },
  button(options) {
    return withType("button", options);
  },
  toggle(options) {
    return withType("toggle", options);
  },
  slider(options) {
    return withType("slider", options);
  },
  text(options) {
    return withType("text", options);
  },
  progress(options) {
    return withType("progress", options);
  },
  image(options) {
    return withType("image", options);
  },
  badge(options) {
    return withType("badge", options);
  },
  marquee(value) {
    return withType("marquee", { value });
  },
  scene(scene) {
    return withType("scene", scene);
  },
  scene3d(options) {
    return withType("scene3d", options);
  },
});

export { definePlugin, ui };
