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
  | "fs.read"
  | AppleScriptPermission;

export interface PluginFSRoot {
  readonly id: string;
  readonly path: string;
  readonly summary: LocalizedText;
}

export interface PluginManifest {
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

export interface PluginCapabilityState {
  readonly supported: boolean;
  readonly granted: boolean;
  readonly available: boolean;
}

/** 宿主 UI 特性协商快照，不是用户权限表。 */
export interface PluginUIFeatures {
  /** 仅当 apiVersion 为 2 且宿主可渲染 scene3d 时为 true。 */
  readonly scene3d: boolean;
}

export interface PluginContext {
  readonly capabilities: Readonly<Record<string, PluginCapabilityState | undefined>>;
  /** v2 协商增量；缺失表示无协商，插件必须返回 2D 树。 */
  readonly uiFeatures?: PluginUIFeatures;
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
}

export type PluginSlot =
  | "bottomBar"
  | "center"
  | "topTrailing"
  | "titleAccessory";
export type PluginSpacing = "xs" | "s" | "m";
export type PluginAlignment = "leading" | "center" | "trailing";
export type PluginMaterial = "glass" | "plain";
export type PluginControlSize = "s" | "m" | "l";
export type PluginButtonVariant = "plain" | "prominent";
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
  | { readonly artwork: true };

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
  /** glTF node.name；不能同时被 surface 引用。 */
  readonly node: string;
  /** scene3d 内唯一；可与其自身 fallback 子树复用。 */
  readonly id: string;
  readonly label: string;
  readonly value?: number | null;
  readonly enabled?: boolean;
}

export interface PluginScene3DOptions {
  /** 同一插件实例内复用场景的稳定 key，1...64 字符。 */
  readonly key: string;
  /** 插件包内相对单一 .glb 路径，≤ 8 MiB。 */
  readonly asset: string;
  readonly fit?: Scene3DFit;
  readonly camera?: PluginScene3DCamera;
  readonly rotate?: PluginScene3DRotate;
  /** 最多 2 项。 */
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

export interface PluginDefinition {
  render(ctx: PluginContext): PluginRenderOutput | Promise<PluginRenderOutput>;
  onAction?(
    ctx: PluginContext,
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
  scene(scene: PluginScene): PluginSceneNode;
  scene3d(options: PluginScene3DOptions): PluginScene3DNode;
}

export declare const ui: Readonly<PluginUI>;

export declare function definePlugin<T extends PluginDefinition>(plugin: T): T;

declare global {
  var __switchlyPlugin: PluginDefinition | undefined;
}
