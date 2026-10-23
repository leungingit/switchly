// R3 手势捕获探针：私有 MultitouchSupport 原始触点 + 四指八方向识别。
// 研究夹具，不是 Switchly 功能：不发送任何事件、不改系统设置、不联网、不截图。
//
// 用法：
//   gesture-probe --list-only                 只列设备（不注册回调、不启动设备）
//   gesture-probe [--duration 20]             注册回调并按 JSON Lines 输出（默认 20 秒后自动退出）
//   选项：--no-frames（不输出逐帧，只输出会话/识别事件）、--min-fingers 4、
//         --threshold-mm 12（质心位移阈值）、--cooldown-ms 350、--dropout-ms 80
//
// 触点结构与回调签名来自社区对该私有框架的公开逆向（OpenMultitouchSupport，MIT；
// M5MultitouchSupport，MIT）。此处只按布局事实自行声明结构，未拷贝其源码。
// 符号全部用 dlsym 解析，缺失时输出 JSON 并以非零码退出，不会在加载时崩溃。
// 私有接口，随时可能变化；识别算法（directionForAngle / GestureRecognizer）与框架无关，可单独移植。

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <math.h>
#import <pthread.h>
#import <signal.h>
#import <stdatomic.h>

// ---------- 私有类型（布局事实，96 字节） ----------
typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint position, velocity; } MTReadout;
typedef struct {
  int32_t frame;
  double timestamp;
  int32_t pathIndex;
  int32_t state;  // 0 notTracking 1 starting 2 hovering 3 making 4 touching 5 breaking 6 lingering 7 leaving
  int32_t fingerID;
  int32_t handID;
  MTReadout normalized;  // position 为 0…1，y 向上
  float zTotal;
  int32_t pressure;
  float angle, majorAxis, minorAxis;
  MTReadout absoluteVector;
  int32_t unknown1[2];
  float zDensity;
} MTTouch;
_Static_assert(sizeof(MTTouch) == 96, "MTTouch layout drifted");

typedef void *MTDeviceRef;
typedef int (*MTContactCallback)(MTDeviceRef, MTTouch *, int, double, int);

static CFArrayRef (*pCreateList)(void);
static int (*pRegister)(MTDeviceRef, MTContactCallback);
static void (*pUnregister)(MTDeviceRef, MTContactCallback);
static int (*pStart)(MTDeviceRef, int);
static void (*pStop)(MTDeviceRef);
static int (*pGetID)(MTDeviceRef, uint64_t *);
static bool (*pIsBuiltIn)(MTDeviceRef);
static bool (*pIsRunning)(MTDeviceRef);
static int (*pGetFamily)(MTDeviceRef, int *);
static int (*pGetDims)(MTDeviceRef, int *, int *);

// ---------- 配置 ----------
typedef struct {
  int minFingers;
  double thresholdMM;
  double cooldownMS;
  double dropoutMS;
  bool frames;
} Config;
static Config gConfig = {4, 12.0, 350.0, 80.0, true};

// ---------- 工具 ----------
static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
static volatile sig_atomic_t gStop = 0;
static void onSignal(int s) { (void)s; gStop = 1; }

static double nowUptime(void) {
  static mach_timebase_info_data_t tb;
  if (tb.denom == 0) mach_timebase_info(&tb);
  return (double)mach_absolute_time() * tb.numer / tb.denom / 1e9;
}

static void emit(NSDictionary *obj) {
  NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:NSJSONWritingSortedKeys error:nil];
  fwrite(d.bytes, 1, d.length, stdout);
  fputc('\n', stdout);
  fflush(stdout);
}

static NSString *isoNow(void) {
  struct timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  struct tm tmv;
  gmtime_r(&ts.tv_sec, &tmv);
  char buf[40];
  strftime(buf, sizeof buf, "%Y-%m-%dT%H:%M:%S", &tmv);
  return [NSString stringWithFormat:@"%s.%03ldZ", buf, ts.tv_nsec / 1000000];
}

// ---------- 八方向 ----------
// 角度以毫米坐标、y 向上、右为 0°、逆时针为正。每个扇区 45°，斜向扇区以 45°、135°… 为中心，
// 因此斜向 ±22.5°，水平/垂直同样 ±22.5°。可通过 diagonalBias 让斜向变宽/变窄（探针默认 0）。
static const char *kDirections[8] = {"right", "up-right", "up", "up-left", "left", "down-left", "down", "down-right"};
static const char *directionForAngle(double deg, double diagonalBias) {
  while (deg < 0) deg += 360;
  while (deg >= 360) deg -= 360;
  // 斜向扇区半宽 22.5+bias，轴向扇区半宽 22.5-bias
  double axisHalf = 22.5 - diagonalBias;
  for (int i = 0; i < 8; i++) {
    double center = i * 45.0;
    double d = fabs(fmod(deg - center + 540.0, 360.0) - 180.0);
    double half = (i % 2 == 0) ? axisHalf : 22.5 + diagonalBias;
    if (d <= half) return kDirections[i];
  }
  return kDirections[0];
}

// ---------- 识别器 ----------
typedef struct {
  bool inSession;
  bool fired;
  double sessionStartTs;     // 设备时间戳，第一次达到 minFingers
  double startX, startY;     // 起点质心（mm），达到 minFingers 的那一帧
  double lastX, lastY;       // 最近质心（mm）
  double maxDisp;            // 会话内最大位移（mm）
  int maxFingers;
  double belowSince;         // 手指数跌破 minFingers 的设备时间戳，<0 表示未跌破
  double cooldownUntil;      // 设备时间戳
  double widthMM, heightMM;
} Recognizer;
static Recognizer gRec = {.belowSince = -1};

static void endSession(const char *reason, double ts, double hostLagMS) {
  double dx = gRec.lastX - gRec.startX, dy = gRec.lastY - gRec.startY;
  double disp = hypot(dx, dy);
  double ang = atan2(dy, dx) * 180.0 / M_PI;
  emit(@{@"event": @"session_end", @"t": isoNow(), @"deviceTs": @(ts), @"reason": @(reason),
         @"fired": @(gRec.fired), @"durationMs": @((ts - gRec.sessionStartTs) * 1000.0),
         @"finalDisplacementMM": @(disp), @"finalAngleDeg": @(ang),
         @"finalDirection": disp >= gConfig.thresholdMM ? @(directionForAngle(ang, 0)) : [NSNull null],
         @"maxDisplacementMM": @(gRec.maxDisp), @"maxFingers": @(gRec.maxFingers),
         @"hostLagMs": @(hostLagMS)});
  gRec.inSession = false;
  gRec.fired = false;
  gRec.belowSince = -1;
  gRec.maxDisp = 0;
  gRec.maxFingers = 0;
}

static void process(MTTouch *t, int n, double ts, int frame, double hostLagMS, double cbStart) {
  // 只统计 making/touching 的触点；hover/leaving 不算手指。
  int active = 0;
  double sx = 0, sy = 0;
  for (int i = 0; i < n; i++) {
    if (t[i].state == 3 || t[i].state == 4) {
      active++;
      sx += t[i].normalized.position.x;
      sy += t[i].normalized.position.y;
    }
  }
  double cx = 0, cy = 0;
  if (active > 0) {
    cx = sx / active * gRec.widthMM;
    cy = sy / active * gRec.heightMM;
  }

  if (!gRec.inSession) {
    if (active >= gConfig.minFingers && ts >= gRec.cooldownUntil) {
      gRec = (Recognizer){.inSession = true, .sessionStartTs = ts, .startX = cx, .startY = cy,
                          .lastX = cx, .lastY = cy, .maxFingers = active, .belowSince = -1,
                          .cooldownUntil = gRec.cooldownUntil, .widthMM = gRec.widthMM, .heightMM = gRec.heightMM};
      emit(@{@"event": @"session_start", @"t": isoNow(), @"deviceTs": @(ts), @"fingers": @(active),
             @"startCentroidMM": @[@(cx), @(cy)]});
    }
    return;
  }

  if (active >= gConfig.minFingers) {
    gRec.belowSince = -1;
    gRec.lastX = cx;
    gRec.lastY = cy;
    if (active > gRec.maxFingers) gRec.maxFingers = active;
    double dx = cx - gRec.startX, dy = cy - gRec.startY;
    double disp = hypot(dx, dy);
    if (disp > gRec.maxDisp) gRec.maxDisp = disp;
    if (!gRec.fired && disp >= gConfig.thresholdMM) {
      double ang = atan2(dy, dx) * 180.0 / M_PI;
      gRec.fired = true;
      double localUs = (nowUptime() - cbStart) * 1e6;
      emit(@{@"event": @"swipe", @"t": isoNow(), @"deviceTs": @(ts), @"frame": @(frame),
             @"direction": @(directionForAngle(ang, 0)), @"angleDeg": @(ang),
             @"displacementMM": @(disp), @"fingers": @(active),
             @"sinceSessionStartMs": @((ts - gRec.sessionStartTs) * 1000.0),
             @"hostLagMs": @(hostLagMS), @"callbackLocalUs": @(localUs)});
      gRec.cooldownUntil = ts + gConfig.cooldownMS / 1000.0;
    }
    return;
  }

  // 手指数跌破阈值：抖动容忍 dropoutMS，之后判定结束。active==0 视为抬起，立即结束。
  if (gRec.belowSince < 0) gRec.belowSince = ts;
  bool lifted = (active == 0);
  if (lifted || (ts - gRec.belowSince) * 1000.0 >= gConfig.dropoutMS) {
    endSession(lifted ? "lift" : "fingers-dropped", ts, hostLagMS);
  }
}

static int contactCallback(MTDeviceRef dev, MTTouch *touches, int n, double ts, int frame) {
  double cbStart = nowUptime();
  pthread_mutex_lock(&gLock);
  // 设备时间戳与主机 uptime 不同源（实测相差数万秒），不能直接相减。
  // 改为按设备跟踪 (到达时间 - 设备时间戳) 的最小值，hostLagMs = 当前值 - 最小值，
  // 只估计相对排队/调度延迟（不含触点到驱动之前的硬件延迟）。
  static MTDeviceRef seen[8];
  static double minOffset[8];
  int slot = -1;
  for (int i = 0; i < 8; i++) {
    if (seen[i] == dev) { slot = i; break; }
    if (!seen[i]) { seen[i] = dev; minOffset[i] = INFINITY; slot = i; break; }
  }
  double offset = cbStart - ts;
  if (slot >= 0 && offset < minOffset[slot]) minOffset[slot] = offset;
  double hostLagMS = slot >= 0 ? (offset - minOffset[slot]) * 1000.0 : 0;
  if (gConfig.frames && n > 0) {
    NSMutableArray *fingers = [NSMutableArray arrayWithCapacity:n];
    double sx = 0, sy = 0;
    for (int i = 0; i < n; i++) {
      [fingers addObject:@{@"id": @(touches[i].fingerID), @"state": @(touches[i].state),
                           @"x": @(touches[i].normalized.position.x), @"y": @(touches[i].normalized.position.y),
                           @"size": @(touches[i].zTotal)}];
      sx += touches[i].normalized.position.x;
      sy += touches[i].normalized.position.y;
    }
    emit(@{@"event": @"frame", @"t": isoNow(), @"deviceTs": @(ts), @"frame": @(frame),
           @"fingers": @(n), @"centroid": @[@(sx / n), @(sy / n)], @"touches": fingers,
           @"hostLagMs": @(hostLagMS)});
  }
  process(touches, n, ts, frame, hostLagMS, cbStart);
  pthread_mutex_unlock(&gLock);
  return 0;
}

// ---------- 主程序 ----------
static NSDictionary *deviceInfo(MTDeviceRef d, int idx) {
  uint64_t did = 0;
  int family = -1, w = 0, h = 0;
  if (pGetID) pGetID(d, &did);
  if (pGetFamily) pGetFamily(d, &family);
  if (pGetDims) pGetDims(d, &w, &h);
  return @{@"index": @(idx), @"deviceID": @(did), @"builtIn": @(pIsBuiltIn ? pIsBuiltIn(d) : false),
           @"familyID": @(family), @"surfaceWidthMM": @(w / 100.0), @"surfaceHeightMM": @(h / 100.0),
           @"running": @(pIsRunning ? pIsRunning(d) : false)};
}

int main(int argc, char **argv) {
  @autoreleasepool {
    double duration = 20.0;
    bool listOnly = false;
    for (int i = 1; i < argc; i++) {
      NSString *a = @(argv[i]);
      if ([a isEqualToString:@"--list-only"]) listOnly = true;
      else if ([a isEqualToString:@"--no-frames"]) gConfig.frames = false;
      else if ([a isEqualToString:@"--duration"] && i + 1 < argc) duration = atof(argv[++i]);
      else if ([a isEqualToString:@"--min-fingers"] && i + 1 < argc) gConfig.minFingers = atoi(argv[++i]);
      else if ([a isEqualToString:@"--threshold-mm"] && i + 1 < argc) gConfig.thresholdMM = atof(argv[++i]);
      else if ([a isEqualToString:@"--cooldown-ms"] && i + 1 < argc) gConfig.cooldownMS = atof(argv[++i]);
      else if ([a isEqualToString:@"--dropout-ms"] && i + 1 < argc) gConfig.dropoutMS = atof(argv[++i]);
      else { fprintf(stderr, "usage: gesture-probe [--list-only] [--duration s] [--no-frames] [--min-fingers n] [--threshold-mm mm] [--cooldown-ms ms] [--dropout-ms ms]\n"); return 2; }
    }

    const char *path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport";
    void *h = dlopen(path, RTLD_NOW);
    if (!h) { emit(@{@"event": @"error", @"stage": @"dlopen", @"message": @(dlerror())}); return 1; }
    pCreateList = dlsym(h, "MTDeviceCreateList");
    pRegister = dlsym(h, "MTRegisterContactFrameCallback");
    pUnregister = dlsym(h, "MTUnregisterContactFrameCallback");
    pStart = dlsym(h, "MTDeviceStart");
    pStop = dlsym(h, "MTDeviceStop");
    pGetID = dlsym(h, "MTDeviceGetDeviceID");
    pIsBuiltIn = dlsym(h, "MTDeviceIsBuiltIn");
    pIsRunning = dlsym(h, "MTDeviceIsRunning");
    pGetFamily = dlsym(h, "MTDeviceGetFamilyID");
    pGetDims = dlsym(h, "MTDeviceGetSensorSurfaceDimensions");
    NSDictionary *symbols = @{@"MTDeviceCreateList": @(pCreateList != NULL), @"MTRegisterContactFrameCallback": @(pRegister != NULL),
                              @"MTUnregisterContactFrameCallback": @(pUnregister != NULL), @"MTDeviceStart": @(pStart != NULL),
                              @"MTDeviceGetDeviceID": @(pGetID != NULL), @"MTDeviceIsBuiltIn": @(pIsBuiltIn != NULL),
                              @"MTDeviceIsRunning": @(pIsRunning != NULL), @"MTDeviceGetFamilyID": @(pGetFamily != NULL),
                              @"MTDeviceGetSensorSurfaceDimensions": @(pGetDims != NULL)};
    NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
    emit(@{@"event": @"symbols", @"t": isoNow(), @"os": [NSString stringWithFormat:@"%ld.%ld.%ld", (long)v.majorVersion, (long)v.minorVersion, (long)v.patchVersion],
           @"symbols": symbols});
    if (!pCreateList || !pRegister || !pStart || !pStop) { emit(@{@"event": @"error", @"stage": @"dlsym", @"message": @"required symbol missing"}); return 1; }

    CFArrayRef list = pCreateList();
    CFIndex count = list ? CFArrayGetCount(list) : 0;
    NSMutableArray *infos = [NSMutableArray array];
    for (CFIndex i = 0; i < count; i++) [infos addObject:deviceInfo((MTDeviceRef)CFArrayGetValueAtIndex(list, i), (int)i)];
    emit(@{@"event": @"devices", @"t": isoNow(), @"count": @(count), @"devices": infos});
    if (listOnly || count == 0) {
      if (count == 0) emit(@{@"event": @"warning", @"message": @"no multitouch devices enumerated"});
      if (list) CFRelease(list);
      return 0;
    }

    // 内置触控板优先作为尺寸来源；多设备时识别器只按首个设备的尺寸换算（探针限制）。
    NSDictionary *first = infos[0];
    for (NSDictionary *d in infos) if ([d[@"builtIn"] boolValue]) { first = d; break; }
    gRec.widthMM = [first[@"surfaceWidthMM"] doubleValue];
    gRec.heightMM = [first[@"surfaceHeightMM"] doubleValue];
    if (gRec.widthMM <= 0 || gRec.heightMM <= 0) { gRec.widthMM = 160; gRec.heightMM = 115; }  // 缺省近似，仅在读不到尺寸时
    emit(@{@"event": @"config", @"minFingers": @(gConfig.minFingers), @"thresholdMM": @(gConfig.thresholdMM),
           @"cooldownMs": @(gConfig.cooldownMS), @"dropoutMs": @(gConfig.dropoutMS), @"durationS": @(duration),
           @"surfaceMM": @[@(gRec.widthMM), @(gRec.heightMM)]});

    signal(SIGINT, onSignal);
    signal(SIGTERM, onSignal);

    for (CFIndex i = 0; i < count; i++) {
      MTDeviceRef d = (MTDeviceRef)CFArrayGetValueAtIndex(list, i);
      int rr = pRegister(d, contactCallback);
      int sr = pStart(d, 0);
      emit(@{@"event": @"started", @"t": isoNow(), @"deviceIndex": @(i), @"registerResult": @(rr), @"startResult": @(sr)});
    }

    double deadline = nowUptime() + duration;
    while (!gStop && nowUptime() < deadline) {
      CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
    }

    for (CFIndex i = 0; i < count; i++) {
      MTDeviceRef d = (MTDeviceRef)CFArrayGetValueAtIndex(list, i);
      pStop(d);
      if (pUnregister) pUnregister(d, contactCallback);
    }
    pthread_mutex_lock(&gLock);  // 等待在途回调结束
    pthread_mutex_unlock(&gLock);
    // 设备对象归 CreateList 返回的数组所有，释放数组即可，不单独 MTDeviceRelease（避免重复释放）。
    CFRelease(list);
    emit(@{@"event": @"stopped", @"t": isoNow(), @"interrupted": @(gStop != 0)});
  }
  return 0;
}
