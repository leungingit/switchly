export type ApiVersion = 1 | 2;
export type LocalizedText = Readonly<Record<string, string>>;
export type PluginSettingValue = boolean | number | string;
export type JSONPrimitive = boolean | number | string | null;
export type JSONValue =
  | JSONPrimitive
  | readonly JSONValue[]
  | { readonly [key: string]: JSONValue };

export interface PluginSettingOption {
  readonly value: string;
  readonly title: LocalizedText;
}

export interface PluginToggleSetting {
  readonly key: string;
  readonly title: LocalizedText;
  readonly type?: "toggle";
  readonly default: boolean;
  readonly effect?: string;
}

export interface PluginSelectSetting {
  readonly key: string;
  readonly title: LocalizedText;
  readonly type: "select";
  readonly default: string;
  readonly options: readonly PluginSettingOption[];
  readonly effect?: string;
}

export interface PluginNumberSetting {
  readonly key: string;
  readonly title: LocalizedText;
  readonly type: "number";
  readonly default: number;
  readonly min?: number;
  readonly max?: number;
  readonly step?: number;
  readonly effect?: string;
}

export type PluginSetting =
  | PluginToggleSetting
  | PluginSelectSetting
  | PluginNumberSetting;

export type AppleScriptPermission = `appleScript:${string}`;
export type PluginPermission =
  | "media.nowPlaying"
  | "media.control"
  | "media.library"
  | "weather.current"
  | "window.focus"
  | "activity.read"
  | "activity.snapshots"
  | "window.capture"
  | "fs.read"
  | AppleScriptPermission;

/** 插件声明可装载的表面；缺省时仅 Dock 预览。 */
export type PluginSurface = "dockPreview" | "panel";

export interface PluginFSRoot {
  readonly id: string;
  readonly path: string;
  readonly summary: LocalizedText;
}

export interface PluginManifest {
  readonly renderScope?: "app" | "window" | null;
  readonly id: string;
  readonly name: LocalizedText;
  readonly version: string;
  readonly apiVersion: ApiVersion;
  readonly summary?: LocalizedText;
  readonly matches: readonly string[];
  readonly permissions: readonly PluginPermission[];
  readonly entry: string;
  readonly refreshInterval?: number | null;
  readonly settings?: readonly PluginSetting[] | null;
  readonly fsRoots?: readonly PluginFSRoot[] | null;
  readonly defaultEnabled?: boolean | null;
  readonly surfaces?: readonly PluginSurface[];
}

export interface NowPlaying {
  readonly playing: boolean;
  readonly title: string;
  readonly artist: string;
  readonly album: string;
  readonly position: number;
  readonly duration: number;
  readonly progress: number;
  readonly liked: boolean;
  readonly canLike: boolean;
}

export interface PickedTrack {
  readonly persistentID: string;
  readonly title: string;
  readonly artist: string;
  readonly bpm: number;
  readonly matchedGenre: boolean;
}

export interface PluginMusicLibrary {
  pickRandom(keywords?: readonly string[]): Promise<PickedTrack | null>;
  play(persistentID: string): Promise<void>;
  pause(): Promise<void>;
}

export interface PluginMedia {
  readonly nowPlaying?: () => Promise<NowPlaying | null>;
  readonly togglePlayPause?: () => Promise<void>;
  readonly next?: () => Promise<void>;
  readonly previous?: () => Promise<void>;
  readonly setLiked?: (liked: boolean) => Promise<void>;
  readonly library?: PluginMusicLibrary;
}

export type WeatherCondition =
  | "clear"
  | "cloudy"
  | "rain"
  | "snow"
  | "fog"
  | "storm";

export interface WeatherSnapshot {
  readonly condition: WeatherCondition | string;
  readonly temperature: number;
  readonly wind: number;
  readonly source: "online";
}

export interface PluginWeather {
  /**
   * 同步读取宿主已有快照。
   * 未授权 weather.current、在线天气关闭、未配置、失败或过期时返回 null。
   */
  current(): WeatherSnapshot | null;
}

export interface PluginStorage {
  /** 不存在时 resolve 为 null。 */
  get(key: string): Promise<JSONValue | null>;
  /** key 上限 256 字节；JSON 值上限 64 KiB。 */
  set(key: string, value: JSONValue): Promise<void>;
  remove(key: string): Promise<void>;
  clear(): Promise<void>;
}

export interface PluginFSEntry {
  readonly name: string;
  readonly isDir: boolean;
  readonly size: number;
  /** Unix 秒。 */
  readonly mtime: number;
}

export interface PluginFSScanEntry {
  readonly path: string;
  readonly size: number;
  /** Unix 秒。 */
  readonly mtime: number;
}

export interface PluginFSScanOptions {
  readonly depth?: number;
  readonly suffix?: string;
  readonly modifiedWithin?: number;
}

export interface PluginFSReadOptions {
  readonly maxBytes?: number;
}

export interface PluginFS {
  list(root: string, path?: string): Promise<readonly PluginFSEntry[]>;
  stat(root: string, path?: string): Promise<PluginFSEntry>;
  readText(
    root: string,
    path?: string,
    options?: PluginFSReadOptions,
  ): Promise<string>;
  scan(
    root: string,
    path?: string,
    options?: PluginFSScanOptions,
  ): Promise<readonly PluginFSScanEntry[]>;
  isLocked(root: string, path?: string): Promise<boolean>;
}

export interface PluginAppSnapshot {
  readonly bundleID: string;
  readonly pid: number;
  readonly name: string;
  /** Unix 秒；宿主尚未观察到激活时为 null。 */
  readonly lastActiveAt: number | null;
}

export interface PluginWindowSnapshot {
  readonly windowID: number;
  /** 已截断的标题摘要，完整标题不会传给插件。 */
  readonly title: string;
}

export type ActivityGroupBy = "app" | "hour" | "day" | "month";

/** 所有时间值均为 Unix epoch 秒。 */
export interface ActivitySummaryOptions {
  readonly from: number;
  readonly to: number;
  readonly groupBy?: ActivityGroupBy;
  readonly timeZone?: string;
}

export interface ActivitySummaryItem {
  readonly bundleID: string;
  /** 应用名；对应当前会话的 appName。 */
  readonly name: string;
  readonly seconds: number;
  readonly sessions: number;
  /** 非 app 分组时存在。 */
  readonly bucketStart?: number;
  readonly bucketEnd?: number;
}

export interface ActivitySummary {
  readonly items: readonly ActivitySummaryItem[];
  readonly availableFrom: number | null;
  readonly revision: number;
  readonly recording: boolean;
  readonly screenshotsEnabled: boolean;
}

export interface ActivitySessionsOptions {
  readonly from: number;
  readonly to: number;
  readonly limit?: number;
  readonly cursor?: string | null;
  readonly bundleID?: string;
}

export type ActivityEndReason =
  | "checkpoint"
  | "switched"
  | "disabled"
  | "idle"
  | "blocked"
  | "terminated"
  | "clockChanged";

export interface ActivitySessionItem {
  readonly id: string;
  readonly bundleID: string;
  readonly appName: string;
  readonly start: number;
  readonly end: number;
  readonly seconds: number;
  readonly endReason: ActivityEndReason;
}

export interface ActivitySessions {
  readonly items: readonly ActivitySessionItem[];
  readonly nextCursor: string | null;
  readonly revision: number;
}

export interface ActivitySnapshotsOptions {
  readonly from: number;
  readonly to: number;
  readonly limit?: number;
  readonly cursor?: string | null;
  readonly bundleID?: string;
}

export interface ActivitySnapshotItem {
  /** 宿主签发的不透明引用，可直接用于 image.activitySnapshot。 */
  readonly ref: string;
  readonly capturedAt: number;
  readonly bundleID: string;
  /** 关联已有 ActivitySessionItem.id 的不透明 UUID；不是路径，旧宿主可能缺省。 */
  readonly sessionID?: string;
}

export interface ActivitySnapshots {
  readonly items: readonly ActivitySnapshotItem[];
  readonly nextCursor: string | null;
  readonly revision: number;
}

/** 仅当 activity.read 获准且宿主活动服务可用时注入。 */
export interface PluginActivity {
  summary(options: ActivitySummaryOptions): Promise<ActivitySummary>;
  sessions(options: ActivitySessionsOptions): Promise<ActivitySessions>;
  /** 仅同时获准 activity.read 与 activity.snapshots 时存在。 */
  readonly snapshots?: (
    options: ActivitySnapshotsOptions,
  ) => Promise<ActivitySnapshots>;
}

export interface PluginCapabilityState {
  readonly supported: boolean;
  readonly granted: boolean;
  readonly available: boolean;
}

/** 宿主 UI 特性协商快照，不是用户权限表。 */
export interface PluginUIFeatures {
  /** 仅当 apiVersion 为 2 且宿主可渲染 scene3d 时为 true。 */
  readonly scene3d: boolean;
  /** 宿主是否支持 panel surface 与 panel 槽位。 */
  readonly panel?: boolean;
  /** 宿主是否支持 activity 节点与 ctx.activity 查询。 */
  readonly activity?: boolean;
  /** 宿主是否支持解码 lineChart；缺失或 false 时插件应使用原有 2D 节点。 */
  readonly lineChart?: boolean;
  /** lineChart 是否接受按应用对齐的附加序列。 */
  readonly lineChartSeries?: boolean;
  /** 宿主是否支持解码 timeline；缺失或 false 时插件应回退到同顺序纵向内容列表。 */
  readonly timeline?: boolean;
}

export interface PluginContext {
  /** 每次叠层展示的宿主标识，可用于清理上次展开状态。 */
  readonly presentationID?: string;
  /** 获准后提供；仅用户 onAction 有效调用期间可提交一次，目标由宿主卡片绑定。 */
  readonly capture?: {
    window(options: { readonly mode: "full" | "region" }): Promise<
      { readonly status: "accepted" } |
      { readonly status: "failed"; readonly reason: "permissionDenied" | "noScreenPermission" | "noUserAction" | "invalidRequest" | "windowGone" | "windowUnavailable" | "busy" | "captureFailed" | "timeout" | "tooLarge" }
    >;
  };
  readonly capabilities: Readonly<Record<string, PluginCapabilityState | undefined>>;
  /** v2 能力协商快照；缺失或具体字段为 false 时按对应节点回退。 */
  readonly uiFeatures?: PluginUIFeatures;
  /** Dock 预览为 "dockPreview"；旧宿主可能缺省。panel 使用专用上下文类型。 */
  readonly surface?: "dockPreview";
  readonly app: PluginAppSnapshot;
  readonly window: PluginWindowSnapshot;
  readonly locale: string;
  readonly settings: Readonly<Record<string, PluginSettingValue>>;
  readonly reduceMotion: boolean;
  t(key: string): string;
  invalidate(): void;
  /** 始终存在；没有 weather.current 授权或快照不可用时 current() 返回 null。 */
  readonly weather: PluginWeather;
  /** 插件私有的 Promise JSON 键值存储。 */
  readonly storage: PluginStorage;
  /** 仅当至少一个 media 权限被授权时存在。 */
  readonly media?: PluginMedia;
  /** 仅当 fs.read 被授权时存在。 */
  readonly fs?: PluginFS;
  /** 仅当 activity.read 被授权且活动服务可用时存在。 */
  readonly activity?: PluginActivity;
}

/** panel 实例没有前台应用或窗口，但保留其他 PluginContext 能力。 */
export interface PluginPanelContext
  extends Omit<PluginContext, "app" | "window" | "surface"> {
  readonly surface: "panel";
  readonly app: null;
  readonly window: null;
}

export type PluginSlot =
  | "panel"
  | "bottomBar"
  | "center"
  | "topTrailing"
  | "titleAccessory";
export type PluginSpacing = "xs" | "s" | "m";
export type PluginAlignment = "leading" | "center" | "trailing";
export type PluginMaterial = "glass" | "plain";
export type PluginControlSize = "s" | "m" | "l";
export type PluginButtonVariant = "plain" | "prominent" | "labeled";
export type PluginTextStyle = "title" | "body" | "caption";
export type PluginProgressStyle = "linear" | "circular";
export type PluginCorner = "s" | "m";
export type PluginBadgeTone = "neutral" | "accent" | "warning";

export interface PluginStackOptions {
  readonly spacing?: PluginSpacing;
  readonly align?: PluginAlignment;
}

export interface PluginSurfaceOptions {
  readonly material?: PluginMaterial;
}

export interface PluginButtonOptions {
  readonly id: string;
  readonly symbol: string;
  readonly label: string;
  readonly size?: PluginControlSize;
  readonly variant?: PluginButtonVariant;
  readonly enabled?: boolean;
  readonly selected?: boolean;
}

export interface PluginToggleOptions {
  readonly id: string;
  readonly symbolOn: string;
  readonly symbolOff: string;
  readonly isOn?: boolean;
  readonly label: string;
}

export interface PluginSliderOptions {
  readonly id: string;
  readonly value: number;
  readonly label: string;
  readonly step?: number;
}

export interface PluginTextOptions {
  readonly value: string;
  readonly style?: PluginTextStyle;
  readonly lines?: number;
}

export interface PluginProgressOptions {
  readonly value: number;
  readonly style?: PluginProgressStyle;
  readonly rate?: number;
}

export type PluginImageSource =
  | { readonly symbol: string }
  | { readonly pluginAsset: string }
  | { readonly artwork: true }
  | { readonly activitySnapshot: string };

export interface PluginImageOptions {
  readonly source: PluginImageSource;
  readonly size?: PluginControlSize;
  readonly corner?: PluginCorner;
}

export interface PluginBadgeOptions {
  readonly value: string;
  readonly tone?: PluginBadgeTone;
}

export interface PluginHStackNode {
  readonly type: "hstack";
  readonly children: readonly PluginNode[];
  readonly spacing?: PluginSpacing;
  readonly align?: PluginAlignment;
}

export interface PluginVStackNode {
  readonly type: "vstack";
  readonly children: readonly PluginNode[];
  readonly spacing?: PluginSpacing;
  readonly align?: PluginAlignment;
}

export interface PluginZStackNode {
  readonly type: "zstack";
  readonly children: readonly PluginNode[];
}

export interface PluginSpacerNode {
  readonly type: "spacer";
}

export interface PluginSurfaceNode {
  readonly type: "surface";
  readonly children: readonly PluginNode[];
  readonly material?: PluginMaterial;
}

export interface PluginScreenNode {
  readonly type: "screen";
  readonly children: readonly PluginNode[];
}

export interface PluginWheelNode {
  /** 必须恰好 5 项：上、左、右、下、中；空位用 spacer。 */
  readonly type: "wheel";
  readonly children: readonly PluginNode[];
}

export interface PluginButtonNode extends PluginButtonOptions {
  readonly type: "button";
}

export interface PluginToggleNode extends PluginToggleOptions {
  readonly type: "toggle";
}

export interface PluginSliderNode extends PluginSliderOptions {
  readonly type: "slider";
}

export interface PluginTextNode extends PluginTextOptions {
  readonly type: "text";
}

export interface PluginProgressNode extends PluginProgressOptions {
  readonly type: "progress";
}

export interface PluginImageNode extends PluginImageOptions {
  readonly type: "image";
}

export interface PluginBadgeNode extends PluginBadgeOptions {
  readonly type: "badge";
}

export interface PluginMarqueeNode {
  readonly type: "marquee";
  readonly value: string;
}

export interface PluginSegmentedOptions {
  readonly id: string;
  /** 最多 6 项。 */
  readonly options: readonly string[];
  readonly selected: number;
}

export interface PluginSegmentedNode extends PluginSegmentedOptions {
  readonly type: "segmented";
}

export interface PluginDateRangeOptions {
  readonly id: string;
  /** Unix epoch 秒，满足 from < to 且跨度不超过 400 天。 */
  readonly from: number;
  readonly to: number;
  readonly label: string;
}

export interface PluginDateRangeNode extends PluginDateRangeOptions {
  readonly type: "dateRange";
}

export interface PluginBarItem {
  readonly label: string;
  /** 秒；宿主按本地化时长绘制坐标和提示。 */
  readonly value: number;
}

export interface PluginBarChartNode {
  readonly type: "barChart";
  /** 最多 12 项；label 与 value 须满足宿主节点约束。 */
  readonly items: readonly PluginBarItem[];
}

export interface PluginLineChartNode {
  readonly type: "lineChart";
  /** 仅 panel，最多 64 点；复用 PluginBarItem 的 label/value 约束。 */
  readonly items: readonly PluginBarItem[];
  /** 汇总图例，UTF-8 1…200 字节；附加序列存在时必填。 */
  readonly label?: string;
  /** 需 lineChartSeries 协商；最多 6 列，与 items 时间标签逐项一致。 */
  readonly series?: readonly PluginLineSeries[];
}

export interface PluginLineSeries {
  readonly label: string;
  readonly items: readonly PluginBarItem[];
}

export interface PluginTimelineItem {
  /** 非负有限 epoch 秒。 */
  readonly timestamp: number;
  /** 与 timeline 节点共同计入整树 64 节点、深度 8 预算。 */
  readonly content: PluginNode;
}

export interface PluginTimelineNode {
  readonly type: "timeline";
  /** 仅 panel，最多 12 项；content 沿用整树 64 节点、深度 8 预算。 */
  readonly items: readonly PluginTimelineItem[];
}

export interface PluginGridNode {
  readonly type: "grid";
  /** 最多 6 项。 */
  readonly children: readonly PluginNode[];
}

export type SceneVec = readonly [number, number];
export type SceneColor =
  | `#${string}`
  | "$label"
  | "$secondaryLabel";

export interface SceneLinearFill {
  readonly colors: readonly SceneColor[];
  readonly from?: SceneVec;
  readonly to?: SceneVec;
}

export interface SceneAngularFill {
  readonly colors: readonly SceneColor[];
  readonly center?: SceneVec;
}

export type SceneFill =
  | SceneColor
  | { readonly linear: SceneLinearFill }
  | { readonly angular: SceneAngularFill };

export interface SceneStroke {
  readonly color: SceneFill;
  readonly width?: number;
}

export type SceneProp =
  | "x"
  | "y"
  | "w"
  | "h"
  | "rotation"
  | "scale"
  | "scaleX"
  | "scaleY"
  | "opacity"
  | "blur"
  | "angle";

export type SceneEase = "linear" | "in" | "out" | "inOut" | "hold";

export interface SceneKey {
  readonly t: number;
  readonly v: number;
  readonly e?: SceneEase;
}

export interface SceneTrack {
  readonly prop: SceneProp;
  readonly keys: readonly SceneKey[];
  readonly loop?: number;
}

export type SceneWaveShape = "sin" | "pulse" | "abs";

export interface SceneOsc {
  readonly prop: SceneProp;
  readonly amp: number;
  readonly freq: number;
  readonly phase?: number;
  readonly start?: number;
  readonly end?: number;
  readonly decay?: number;
  readonly wave?: SceneWaveShape;
  readonly power?: number;
}

export interface SceneEmitter {
  readonly seed?: number;
  readonly count: number;
  readonly t0: number;
  readonly t1?: number;
  readonly life: number;
  readonly region?: readonly [number, number, number, number];
  readonly follow?: string;
  readonly vx?: SceneVec;
  readonly vy?: SceneVec;
  readonly ax?: number;
  readonly ay?: number;
  readonly size?: SceneVec;
  readonly color: SceneColor;
  readonly glow?: number;
  readonly twinkle?: number;
  readonly drift?: number;
  readonly topFirst?: number;
}

export interface ScenePluck {
  readonly t: number;
  readonly x: number;
  readonly amp: number;
}

export interface SceneWave {
  readonly length: number;
  readonly plucks?: readonly ScenePluck[];
  readonly breathe?: number;
  readonly step?: number;
  readonly decayT?: number;
  readonly decayX?: number;
  readonly speed?: number;
  readonly wavelength?: number;
}

export interface SceneShatter {
  readonly at: number;
  readonly cols?: number;
  readonly rows?: number;
  readonly duration?: number;
}

export interface SceneHit {
  readonly id: string;
  readonly label: string;
  readonly hoverScale?: number;
}

export interface SceneSprite {
  readonly asset: string;
  readonly cols: number;
  readonly rows: number;
  readonly fps?: number;
  readonly t0: number;
}

export type SceneKind =
  | "group"
  | "rect"
  | "ellipse"
  | "text"
  | "symbol"
  | "wave"
  | "emitter"
  | "sprite"
  | "image";
export type SceneDesign = "default" | "serif" | "rounded" | "mono";
export type SceneWeight = "regular" | "medium" | "semibold" | "bold" | "heavy";

export interface SceneLayer {
  readonly id?: string;
  readonly kind: SceneKind;
  readonly x?: number;
  readonly y?: number;
  readonly w?: number;
  readonly h?: number;
  readonly anchor?: SceneVec;
  readonly rotation?: number;
  readonly scale?: number;
  readonly scaleX?: number;
  readonly scaleY?: number;
  readonly opacity?: number;
  readonly blur?: number;
  readonly angle?: number;
  readonly radius?: number;
  readonly fill?: SceneFill;
  readonly stroke?: SceneStroke | readonly SceneStroke[];
  readonly strokes?: readonly SceneStroke[];
  readonly add?: boolean;
  readonly text?: string;
  readonly symbol?: string;
  readonly size?: number;
  readonly weight?: SceneWeight;
  readonly design?: SceneDesign;
  readonly italic?: boolean;
  readonly clip?: boolean;
  readonly from?: number;
  readonly until?: number;
  readonly showOnHover?: string;
  readonly tracks?: readonly SceneTrack[];
  readonly osc?: readonly SceneOsc[];
  /** 只有 group 可以嵌套 children。 */
  readonly children?: readonly SceneLayer[];
  readonly shatter?: SceneShatter;
  readonly hit?: SceneHit;
  readonly emitter?: SceneEmitter;
  readonly wave?: SceneWave;
  readonly sprite?: SceneSprite;
  /** 插件目录内的相对图片路径。 */
  readonly image?: string;
}

export type SceneFit = "width" | "cover";

export interface PluginScene {
  /** 相同 key 的重新渲染不会重启动画。 */
  readonly key: string;
  /** 场景时间 0 对应的 Unix 秒。 */
  readonly epoch: number;
  readonly width: number;
  readonly height: number;
  readonly fps?: number;
  readonly fit?: SceneFit;
  readonly restAt?: number;
  readonly layers: readonly SceneLayer[];
}

export interface PluginSceneNode extends PluginScene {
  readonly type: "scene";
}

/** scene3d 首期只支持等比完整放入槽位。 */
export type Scene3DFit = "contain";

export interface PluginScene3DCamera {
  /** 角度制，[-180, 180]，默认 0。 */
  readonly yaw?: number;
  /** 角度制，[-89, 89]，默认 0。 */
  readonly pitch?: number;
}

export interface PluginScene3DRotate {
  readonly horizontal?: boolean;
  readonly vertical?: boolean;
  readonly pitchMin?: number;
  readonly pitchMax?: number;
}

/** 表面只能使用无交互的受限 2D 节点。 */
export type PluginScene3DSurfaceContentNode =
  | PluginHStackNode
  | PluginVStackNode
  | PluginZStackNode
  | PluginSpacerNode
  | PluginTextNode
  | PluginProgressNode
  | PluginImageNode
  | PluginBadgeNode
  | PluginMarqueeNode;

export interface PluginScene3DSurface {
  /** glTF node.name；须唯一、单一可见网格且 UV 完整。 */
  readonly node: string;
  /** [width, height]，输出纹理像素，每边 1...1024。 */
  readonly size: readonly [number, number];
  readonly content: PluginScene3DSurfaceContentNode;
}

export interface PluginScene3DHit {
  /** glTF node.name；可同时作为 surface 目标（贴图后的按钮）。 */
  readonly node: string;
  /** scene3d 内唯一；可与其自身 fallback 子树复用。 */
  readonly id: string;
  readonly label: string;
  readonly value?: number | null;
  readonly enabled?: boolean;
  /** 节点局部 X/Y 平面上以包围盒中心划分的象限（按对角线分割）；同一节点承载多个命中时必填且不可重复。 */
  readonly sector?: "top" | "right" | "bottom" | "left";
}

export interface PluginScene3DOptions {
  /** 同一插件实例内复用场景的稳定 key，1...64 字符。 */
  readonly key: string;
  /** 插件包内相对单一 .glb 路径，≤ 8 MiB。 */
  readonly asset: string;
  readonly fit?: Scene3DFit;
  readonly camera?: PluginScene3DCamera;
  readonly rotate?: PluginScene3DRotate;
  /** 最多 5 项。 */
  readonly surfaces?: readonly PluginScene3DSurface[];
  /** 最多 12 项。 */
  readonly hits?: readonly PluginScene3DHit[];
  /** 窄槽或运行期失败时的 2D 后备，不得包含 scene3d。 */
  readonly fallback: PluginNode;
}

export interface PluginScene3DNode extends PluginScene3DOptions {
  readonly type: "scene3d";
}

export type PluginNode =
  | PluginHStackNode
  | PluginVStackNode
  | PluginZStackNode
  | PluginSpacerNode
  | PluginSurfaceNode
  | PluginScreenNode
  | PluginWheelNode
  | PluginButtonNode
  | PluginToggleNode
  | PluginSliderNode
  | PluginTextNode
  | PluginProgressNode
  | PluginImageNode
  | PluginBadgeNode
  | PluginMarqueeNode
  | PluginSegmentedNode
  | PluginDateRangeNode
  | PluginBarChartNode
  | PluginLineChartNode
  | PluginTimelineNode
  | PluginGridNode
  | PluginSceneNode
  | PluginScene3DNode;

export interface PluginSlotContent {
  readonly slot: PluginSlot;
  readonly node: PluginNode;
}

export type PluginRenderOutput =
  | readonly PluginSlotContent[]
  | null
  | undefined;

export interface PluginDefinition<C = PluginContext> {
  /** 与媒体读取并行的初始界面；没有媒体、文件、存储或动作能力。旧宿主忽略此方法。 */
  prepare?(ctx: Pick<PluginContext, "app" | "window" | "locale" | "settings" | "reduceMotion" | "uiFeatures" | "t">): PluginRenderOutput | Promise<PluginRenderOutput>;
  render(ctx: C): PluginRenderOutput | Promise<PluginRenderOutput>;
  onAction?(
    ctx: C,
    id: string,
    value: number | null,
  ): void | Promise<void>;
}

export interface PluginUI {
  hstack(
    children: readonly PluginNode[],
    options?: PluginStackOptions,
  ): PluginHStackNode;
  vstack(
    children: readonly PluginNode[],
    options?: PluginStackOptions,
  ): PluginVStackNode;
  zstack(children: readonly PluginNode[]): PluginZStackNode;
  spacer(): PluginSpacerNode;
  surface(
    children: readonly PluginNode[],
    options?: PluginSurfaceOptions,
  ): PluginSurfaceNode;
  screen(children: readonly PluginNode[]): PluginScreenNode;
  wheel(children: readonly PluginNode[]): PluginWheelNode;
  button(options: PluginButtonOptions): PluginButtonNode;
  toggle(options: PluginToggleOptions): PluginToggleNode;
  slider(options: PluginSliderOptions): PluginSliderNode;
  text(options: PluginTextOptions): PluginTextNode;
  progress(options: PluginProgressOptions): PluginProgressNode;
  image(options: PluginImageOptions): PluginImageNode;
  badge(options: PluginBadgeOptions): PluginBadgeNode;
  marquee(value: string): PluginMarqueeNode;
  segmented(options: PluginSegmentedOptions): PluginSegmentedNode;
  dateRange(options: PluginDateRangeOptions): PluginDateRangeNode;
  barChart(items: readonly PluginBarItem[]): PluginBarChartNode;
  lineChart(items: readonly PluginBarItem[], options?: { label?: string; series?: readonly PluginLineSeries[] }): PluginLineChartNode;
  timeline(items: readonly PluginTimelineItem[]): PluginTimelineNode;
  grid(children: readonly PluginNode[]): PluginGridNode;
  scene(scene: PluginScene): PluginSceneNode;
  scene3d(options: PluginScene3DOptions): PluginScene3DNode;
}

export declare const ui: Readonly<PluginUI>;

export declare function definePlugin<T extends PluginDefinition>(plugin: T): T;
export declare function definePanelPlugin<
  T extends PluginDefinition<PluginPanelContext>,
>(plugin: T): T;

declare global {
  var __switchlyPlugin: PluginDefinition | undefined;
}
