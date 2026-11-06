// T15 原生输入回归夹具：启用/禁用按钮、开关；动作后显示 last:<id>。无任何系统能力。
var last = "none";
globalThis.__switchlyPlugin = {
  render: function (ctx) {
    return [{ slot: "center", node: { type: "vstack", spacing: "s", children: [
      { type: "text", value: "last:" + last },
      { type: "button", id: "go", symbol: "play.fill", label: "Go", size: "m", variant: "plain", enabled: true, selected: false },
      { type: "button", id: "stop", symbol: "stop.fill", label: "Stop", size: "m", variant: "plain", enabled: false, selected: false },
      { type: "toggle", id: "mute", symbolOn: "speaker.slash.fill", symbolOff: "speaker.fill", isOn: last === "mute", label: "Mute" }
    ] } }];
  },
  onAction: function (ctx, id, value) { last = id; }
};
