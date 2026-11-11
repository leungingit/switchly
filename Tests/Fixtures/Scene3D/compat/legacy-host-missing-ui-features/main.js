// T00 夹具：v2 插件只在 ctx.uiFeatures.scene3d === true 时返回 3D；
// 缺失协商（旧宿主）必须返回 2D 树，绝不能用 apiVersion 2 推断 3D 可用。
globalThis.__switchlyPlugin = {
  render: function (ctx) {
    var supportsScene3D = ctx.uiFeatures && ctx.uiFeatures.scene3d === true;
    if (!supportsScene3D) {
      return [{ slot: "center", node: {
        type: "surface",
        material: "glass",
        children: [
          { type: "text", value: "2D fallback" }
        ]
      } }];
    }
    return [{ slot: "center", node: {
      type: "scene3d",
      key: "legacy-host",
      asset: "assets/ipod.glb",
      fallback: { type: "text", value: "2D fallback" }
    } }];
  }
};
