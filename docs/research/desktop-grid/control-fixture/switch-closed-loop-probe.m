// Research only: R2 closed-loop Space switch probe. Not part of Switchly.
// One binary, two roles. Controller (default) launches two fixture children (--fixture NAME x,y,w,h) from the same
// executable, puts one on the original Space and one on a neighbouring Space (bridged move), then tries each switch
// path and records five independent signals. A switch counts only if signals 1-3 hold (and 4 when it applies).
// Only owned fixture windows are touched; no user preference, hotkey or Dock setting is written; no screenshots are taken.
// Gesture/bridge technique follows yabai dd845723416f5fe92af49fad5ebab00369e07edd (MIT, see yabai-MIT.txt).
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <dlfcn.h>
#import <signal.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <time.h>
#import <unistd.h>
#import <mach-o/dyld.h>
#import <mach-o/nlist.h>
#define string_equals(a,b) (strcmp((a),(b))==0)
#include "yabai-macho-dlsym.h"

@interface NSObject (R2BridgeInit)
- (id)initWithWindows:(NSArray *)windows spaceID:(uint64_t)sid;
- (id)initWithDisplayIdentifier:(NSString *)display spaceID:(uint64_t)sid;
@end

static double kTotalBudgetSeconds = 150.0;         // hard cap for the whole controller run (R2_BUDGET overrides)
static const double kAttemptTimeoutSeconds = 3.5;  // per attempt, must stay <= 4 s
static int kMaxAttempts = 3;                       // per path and scenario (R2_MAX_ATTEMPTS overrides)

static double millis(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec*1000.0+t.tv_nsec/1e6; }
static double round1(double v) { return round(v*10.0)/10.0; }
static BOOL gAbort = NO;
static void pumpOnce(void) { if(![NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.004]]) usleep(4000); }
static void pump(double seconds) { double end=millis()+seconds*1000; while(millis()<end&&!gAbort) pumpOnce(); }

// ---------------------------------------------------------------- fixture child role
@interface FixtureApp : NSObject <NSApplicationDelegate>
@property NSWindow *window; @property NSString *name; @property NSRect frame;
@property NSWindow *freshWindow; @property NSInteger keys, f19; @property int lastKey; @property NSMutableArray *spaceTimes;
@end
@implementation FixtureApp
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    (void)note; self.spaceTimes=[NSMutableArray array];
    if(![self.name isEqual:@"arrival"]) { // the "arrival" fixture has no window until asked: a fresh window of a windowless app lands on the REAL active Space
    self.window=[[NSWindow alloc] initWithContentRect:self.frame styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    self.window.releasedWhenClosed=NO; self.window.title=[NSString stringWithFormat:@"R2 Fixture %@",self.name];
    NSTextField *field=[[NSTextField alloc] initWithFrame:NSMakeRect(20,60,self.frame.size.width-40,24)]; field.stringValue=@"";
    NSTextField *label=[NSTextField labelWithString:@"Disposable R2 fixture. No user content."]; label.frame=NSMakeRect(20,20,self.frame.size.width-40,24);
    [self.window.contentView addSubview:field]; [self.window.contentView addSubview:label];
    [self.window makeKeyAndOrderFront:nil]; [self.window makeFirstResponder:field]; [NSApp activateIgnoringOtherApps:YES]; }
    __weak FixtureApp *weak=self;
    [NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:NSWorkspaceActiveSpaceDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n){ (void)n; [weak.spaceTimes addObject:@(round1(millis()))]; }];
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *e){ weak.keys++; weak.lastKey=e.keyCode; if(e.keyCode==80) weak.f19++; return e; }];
    NSFileHandle.fileHandleWithStandardInput.readabilityHandler=^(NSFileHandle *h){
        NSData *d=h.availableData;
        if(!d.length){ h.readabilityHandler=nil; dispatch_async(dispatch_get_main_queue(),^{ [NSApp terminate:nil]; }); return; }
        NSString *text=[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        for(NSString *line in [text componentsSeparatedByString:@"\n"]) {
            if([line hasPrefix:@"info "]) { int seq=[[line substringFromIndex:5] intValue]; dispatch_async(dispatch_get_main_queue(),^{ [weak reply:seq]; }); }
            else if([line hasPrefix:@"fresh "]) { int seq=[[line substringFromIndex:6] intValue]; dispatch_async(dispatch_get_main_queue(),^{ [weak fresh:seq]; }); }
            else if([line hasPrefix:@"closefresh "]) { int seq=[[line substringFromIndex:11] intValue]; dispatch_async(dispatch_get_main_queue(),^{ [weak closeFresh:seq]; }); }
            else if([line isEqual:@"quit"]) dispatch_async(dispatch_get_main_queue(),^{ [NSApp terminate:nil]; });
        }
    };
}
// A window created without activating the app lands on the REAL active Space; used as arrival evidence for empty target Spaces.
- (void)fresh:(int)seq {
    if(!self.freshWindow) { self.freshWindow=[[NSWindow alloc] initWithContentRect:NSMakeRect(self.frame.origin.x+30,self.frame.origin.y+200,220,60) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO]; self.freshWindow.releasedWhenClosed=NO; self.freshWindow.title=@"R2 Fresh"; }
    [self.freshWindow orderFront:nil];
    [self emit:@{@"seq":@(seq),@"freshWindowNumber":@(self.freshWindow.windowNumber),@"isOnActiveSpace":@(self.freshWindow.isOnActiveSpace)}];
}
- (void)closeFresh:(int)seq { [self.freshWindow close]; self.freshWindow=nil; [self emit:@{@"seq":@(seq),@"closed":@YES}]; }
- (void)emit:(NSDictionary *)info { NSData *json=[NSJSONSerialization dataWithJSONObject:info options:0 error:NULL]; fwrite(json.bytes,1,json.length,stdout); fputc('\n',stdout); fflush(stdout); }
- (void)reply:(int)seq {
    NSDictionary *info=@{@"seq":@(seq),@"name":self.name,@"pid":@(getpid()),@"windowNumber":@(self.window.windowNumber),
        @"isOnActiveSpace":@(self.window.isOnActiveSpace),@"occlusionVisible":@((self.window.occlusionState&NSWindowOcclusionStateVisible)!=0),
        @"isKeyWindow":@(self.window.isKeyWindow),@"appIsActive":@(NSApp.isActive),@"keyDownTotal":@(self.keys),@"f19Count":@(self.f19),
        @"lastKeyCode":@(self.lastKey),@"spaceNotificationMS":self.spaceTimes,@"nowMS":@(round1(millis()))};
    [self emit:info];
}
@end
static int runFixture(NSString *name,NSString *frameText) {
    @autoreleasepool {
        NSArray *p=[frameText componentsSeparatedByString:@","];
        NSApplication *app=NSApplication.sharedApplication; [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        FixtureApp *delegate=[FixtureApp new]; delegate.name=name;
        delegate.frame=p.count==4 ? NSMakeRect([p[0] doubleValue],[p[1] doubleValue],[p[2] doubleValue],[p[3] doubleValue]) : NSMakeRect(200,200,420,120);
        app.delegate=delegate; [app run];
    }
    return 0;
}

// ---------------------------------------------------------------- private symbols
static int cid;
static CFArrayRef (*copySpaces)(int);
static uint64_t (*currentSpace)(int,CFStringRef);
static CFArrayRef (*windowSpaces)(int,int,CFArrayRef);
static int64_t (*bridgePerform)(void *);
static CFUUIDRef (*displayUUID)(CGDirectDisplayID);
static NSMutableArray *gKeepOperations; // operations run asynchronously; keep them alive for the process lifetime
// R2b: bridged SetCurrentSpace was removed on purpose (it leaves ghost Spaces); only window placement uses the bridge.
static BOOL bridgedMoveWindows(NSArray *windows,uint64_t sid) {
    Class cls=NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation"); if(!cls||!bridgePerform) return NO;
    id op=[[cls alloc] initWithWindows:windows spaceID:sid]; if(!op) return NO;
    [gKeepOperations addObject:op]; bridgePerform((__bridge void *)op); return YES;
}
static NSArray *spaceSnapshot(void) { return CFBridgingRelease(copySpaces(cid)) ?: @[]; }
static NSArray *membersOf(NSNumber *wid) { return CFBridgingRelease(windowSpaces(cid,7,(__bridge CFArrayRef)@[wid])) ?: @[]; }
static NSArray *structure(void) {
    NSMutableArray *r=[NSMutableArray array];
    for(NSDictionary *d in spaceSnapshot()) {
        NSMutableArray *s=[NSMutableArray array];
        for(NSDictionary *v in d[@"Spaces"]) [s addObject:@{@"id":v[@"id64"] ?: @0,@"type":v[@"type"] ?: @(-1)}];
        [r addObject:@{@"spaces":s,@"current":@(currentSpace(cid,(__bridge CFStringRef)d[@"Display Identifier"]))}];
    }
    return r;
}
static NSSet *onScreenIDs(void) {
    NSArray *cg=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly,kCGNullWindowID)); NSMutableSet *ids=[NSMutableSet set];
    for(NSDictionary *w in cg) [ids addObject:w[(__bridge NSString *)kCGWindowNumber]];
    return ids;
}

// Read-only census: normal-layer windows (alpha>0, >50 pt) grouped by the Space they belong to, excluding this process and its fixtures
// (excludePIDs). Window titles are never read, so no screen-recording permission is involved. A Space with count 0 counts as empty.
static NSDictionary *census(NSArray *excludePIDs) {
    NSArray *cg=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID)); NSMutableDictionary *counts=[NSMutableDictionary dictionary];
    for(NSDictionary *w in cg) {
        if([w[(__bridge NSString *)kCGWindowLayer] intValue]!=0||[w[(__bridge NSString *)kCGWindowAlpha] doubleValue]<=0) continue;
        if([excludePIDs containsObject:w[(__bridge NSString *)kCGWindowOwnerPID]]||[w[(__bridge NSString *)kCGWindowOwnerPID] intValue]==getpid()) continue;
        NSDictionary *b=w[(__bridge NSString *)kCGWindowBounds]; if([b[@"Width"] doubleValue]<=50||[b[@"Height"] doubleValue]<=50) continue;
        for(NSNumber *sid in membersOf(w[(__bridge NSString *)kCGWindowNumber])) counts[sid.stringValue]=@([counts[sid.stringValue] integerValue]+1);
    }
    return counts;
}
// ---------------------------------------------------------------- fixture handle (controller side)
@interface Fx : NSObject
@property NSString *name; @property NSTask *task; @property NSPipe *inPipe, *outPipe; @property NSMutableData *buf; @property NSMutableDictionary *replies; @property int seq;
@property pid_t pid;
- (BOOL)launchWithFrame:(NSRect)frame;
- (NSDictionary *)info;
- (NSDictionary *)command:(NSString *)verb;
- (NSRunningApplication *)app;
- (void)stop;
@end
@implementation Fx
- (BOOL)launchWithFrame:(NSRect)f {
    self.buf=[NSMutableData data]; self.replies=[NSMutableDictionary dictionary]; self.inPipe=[NSPipe pipe]; self.outPipe=[NSPipe pipe];
    self.task=[NSTask new]; self.task.executableURL=[NSURL fileURLWithPath:NSBundle.mainBundle.executablePath];
    self.task.arguments=@[@"--fixture",self.name,[NSString stringWithFormat:@"%g,%g,%g,%g",f.origin.x,f.origin.y,f.size.width,f.size.height]];
    self.task.standardInput=self.inPipe; self.task.standardOutput=self.outPipe; self.task.standardError=NSFileHandle.fileHandleWithNullDevice;
    __weak Fx *weak=self;
    self.outPipe.fileHandleForReading.readabilityHandler=^(NSFileHandle *h){
        NSData *d=h.availableData; if(!d.length){ h.readabilityHandler=nil; return; }
        Fx *me=weak; if(!me) return;
        @synchronized(me) {
            [me.buf appendData:d]; NSData *nl=[NSData dataWithBytes:"\n" length:1]; NSRange r;
            while((r=[me.buf rangeOfData:nl options:0 range:NSMakeRange(0,me.buf.length)]).location!=NSNotFound) {
                NSData *line=[me.buf subdataWithRange:NSMakeRange(0,r.location)]; [me.buf replaceBytesInRange:NSMakeRange(0,r.location+1) withBytes:NULL length:0];
                NSDictionary *obj=[NSJSONSerialization JSONObjectWithData:line options:0 error:NULL];
                if([obj isKindOfClass:NSDictionary.class]&&obj[@"seq"]) me.replies[obj[@"seq"]]=obj;
            }
        }
    };
    NSError *err=nil; if(![self.task launchAndReturnError:&err]) return NO; self.pid=self.task.processIdentifier; return YES;
}
- (NSDictionary *)info { return [self command:@"info"]; }
- (NSDictionary *)command:(NSString *)verb {
    int s=++self.seq; NSError *err=nil; NSData *cmd=[[NSString stringWithFormat:@"%@ %d\n",verb,s] dataUsingEncoding:NSUTF8StringEncoding];
    if(![self.inPipe.fileHandleForWriting writeData:cmd error:&err]) return nil;
    double end=millis()+800;
    while(millis()<end&&!gAbort) { @synchronized(self) { NSDictionary *d=self.replies[@(s)]; if(d){ [self.replies removeObjectForKey:@(s)]; return d; } } pumpOnce(); }
    return nil;
}
- (NSRunningApplication *)app { return [NSRunningApplication runningApplicationWithProcessIdentifier:self.pid]; }
- (void)stop {
    if(!self.task) return;
    if(self.task.isRunning) { kill(self.pid,SIGTERM); double end=millis()+600; while(self.task.isRunning&&millis()<end) usleep(20000); if(self.task.isRunning) kill(self.pid,SIGKILL); }
    self.outPipe.fileHandleForReading.readabilityHandler=nil;
}
@end

// ---------------------------------------------------------------- controller state
static NSString *gDisplay; static uint64_t gOrig, gTarget; static NSUInteger gDirection; // 1 = target is right of original, 0 = left
static Fx *gO, *gT, *gW; static BOOL gFreshValidated; static NSInteger gNotifCount; static double gStartMS; static CGPoint gPointer; static CGPoint gCenter;
static NSNumber *gOWin, *gTWin;
static BOOL gAdjacent=YES; static BOOL gFatal; static BOOL gStatusOnly; static BOOL gPreflightOnly; static NSString *gFatalReason; static NSRunningApplication *gPreviousApp;

// "Ghost" = the target fixture reports isOnActiveSpace=NO yet CGWindowList still lists it on screen (left by earlier bridged
// current-Space operations). R2b never tolerates it: a ghost baseline is a hard stop, nothing is repaired.
static uint64_t gStartCurrent; static NSUInteger gDesktopOffset; static BOOL gGhostSeen, gTargetEmpty, gHotkeysEnabled; static NSUInteger gOrigDesktop, gTargetDesktop;
static BOOL baselineHolds(NSDictionary *oi,NSDictionary *ti,NSSet *onScreen) {
    if(!(oi&&ti&&currentSpace(cid,(__bridge CFStringRef)gDisplay)==gOrig&&[oi[@"isOnActiveSpace"] boolValue]&&[onScreen containsObject:oi[@"windowNumber"]])) return NO;
    if(gTargetEmpty) return [ti[@"isOnActiveSpace"] boolValue]&&[onScreen containsObject:ti[@"windowNumber"]];   // witness T parked on the origin Space
    if([ti[@"isOnActiveSpace"] boolValue]) return NO;
    if([onScreen containsObject:ti[@"windowNumber"]]) { gGhostSeen=YES; return NO; }
    return YES;
}
static BOOL currentBaseline(void) { return baselineHolds([gO info],[gT info],onScreenIDs()); }
static void postKey(CGKeyCode key,CGEventFlags flags,CGEventTapLocation tap);
static NSArray *chosenOrder(void) { for(NSDictionary *d in structure()) { (void)d; } NSMutableArray *r=[NSMutableArray array]; for(NSDictionary *d in spaceSnapshot()) if([d[@"Display Identifier"] isEqual:gDisplay]) for(NSDictionary *v in d[@"Spaces"]) [r addObject:v[@"id64"]]; return r; }
// Returns restore info; ok=NO means the original scene could not be reproduced. Restore uses only B1 (activate the origin fixture)
// and, when this run enabled them, the system Control+N hotkeys. It never calls the bridged setter.
static NSDictionary *ensureBaseline(void) {
    double start=millis(); NSString *method=@"alreadyBaseline";
    if(!currentBaseline()) {
        method=@"activateOriginFixture"; [gO.app activateWithOptions:NSApplicationActivateAllWindows|NSApplicationActivateIgnoringOtherApps];
        double aend=millis()+2500; while(millis()<aend&&!gAbort&&!currentBaseline()) pump(0.08);
        if(!currentBaseline()&&!gAbort&&gHotkeysEnabled&&gOrigDesktop>=1&&gOrigDesktop<=9) {
            static const CGKeyCode digit[10]={0,18,19,20,21,23,22,26,28,25};
            method=[method stringByAppendingString:@"+systemHotkeyControlN"]; CGWarpMouseCursorPosition(gCenter); usleep(100000); postKey(digit[gOrigDesktop],kCGEventFlagMaskControl,kCGHIDEventTap);
            double end=millis()+2500; while(millis()<end&&!gAbort&&!currentBaseline()) pump(0.08);
        }
    }
    BOOL ok=currentBaseline();
    if(ok&&gO.app) [gO.app activateWithOptions:NSApplicationActivateIgnoringOtherApps];
    return @{@"ok":@(ok),@"method":method,@"ms":@(round1(millis()-start)),@"ghostSeen":@(gGhostSeen)};
}

// ---------------------------------------------------------------- one attempt
typedef BOOL (^Action)(NSMutableDictionary *notes);
static NSDictionary *fixtureState(NSDictionary *i) { return i ? @{@"isOnActiveSpace":i[@"isOnActiveSpace"],@"occlusionVisible":i[@"occlusionVisible"],@"isKeyWindow":i[@"isKeyWindow"],@"appIsActive":i[@"appIsActive"]} : @{}; }
static BOOL fixtureOffScreen(NSDictionary *i) { return i&&![i[@"isOnActiveSpace"] boolValue]&&![i[@"occlusionVisible"] boolValue]; }
static BOOL fixtureOnScreen(NSDictionary *i) { return i&&[i[@"isOnActiveSpace"] boolValue]&&[i[@"occlusionVisible"] boolValue]; }
// Signal 2 / 3 for the current scenario. Non-empty target: target arrived and origin left. Empty target: origin and witness left (arrival is proven separately).
static BOOL signal2(NSDictionary *oi,NSDictionary *ti) { return gTargetEmpty ? (fixtureOffScreen(oi)&&fixtureOffScreen(ti)) : (fixtureOnScreen(ti)&&fixtureOffScreen(oi)); }
static BOOL signal3(NSSet *on) { return gTargetEmpty ? (![on containsObject:gOWin]&&![on containsObject:gTWin]) : (![on containsObject:gOWin]&&[on containsObject:gTWin]); }
static NSDictionary *runAttempt(Action action) {
    if(gFatal) return @{@"verdict":@"skipped",@"reason":[NSString stringWithFormat:@"fatal: %@",gFatalReason]};
    if(gAbort||millis()-gStartMS>kTotalBudgetSeconds*1000) return @{@"verdict":@"skipped",@"reason":@"total time budget or abort"};
    NSDictionary *pre=ensureBaseline();
    if(![pre[@"ok"] boolValue]) { gFatal=YES; gFatalReason=@"baseline could not be established"; return @{@"verdict":@"inconclusive",@"reason":@"baseline could not be established",@"baselineRestore":pre}; }
    NSMutableDictionary *notes=[NSMutableDictionary dictionary]; NSInteger notif0=gNotifCount; NSArray *orderBefore=chosenOrder();
    NSDictionary *o0=[gO info],*t0=[gT info]; NSInteger oNotif0=[o0[@"spaceNotificationMS"] count],tNotif0=[t0[@"spaceNotificationMS"] count];
    double start=millis();
    if(!action(notes)) return @{@"verdict":@"inconclusive",@"reason":notes[@"blocked"] ?: @"action not performed",@"notes":notes,@"baselineRestore":pre};
    double f1=-1,f2=-1,f3=-1,f5=-1,lastQuery=0; BOOL s2=NO,s3=NO,s5=NO; NSDictionary *oi=nil,*ti=nil; NSSet *on=nil; BOOL all=NO;
    while(millis()-start<kAttemptTimeoutSeconds*1000&&!gAbort) {
        double t=millis()-start;
        if(f1<0&&gNotifCount>notif0) f1=t;
        on=onScreenIDs(); s3=signal3(on);
        s5=currentSpace(cid,(__bridge CFStringRef)gDisplay)==gTarget; if(s5&&f5<0) f5=t; if(s3&&f3<0) f3=t;
        if(millis()-lastQuery>=90) { lastQuery=millis(); oi=[gO info]; ti=[gT info]; s2=signal2(oi,ti); if(s2&&f2<0) f2=millis()-start; }
        all=s2&&s3; if(all) break;
        pumpOnce();
    }
    if(all) { pump(0.3); oi=[gO info]; ti=[gT info]; on=onScreenIDs(); s2=signal2(oi,ti); s3=signal3(on); }   // stability recheck
    else { oi=[gO info]; ti=[gT info]; on=onScreenIDs(); }
    double arrivalMS=millis()-start; NSArray *orderAtArrival=chosenOrder();
    NSDictionary *oN=[gO info],*tN=[gT info]; NSMutableArray *fixtureTimes=[NSMutableArray array];
    for(NSArray *d in @[@[oN,@(oNotif0)],@[tN,@(tNotif0)]]) { NSArray *all2=[d[0] objectForKey:@"spaceNotificationMS"]; NSUInteger from=MIN((NSUInteger)[d[1] integerValue],all2.count); [fixtureTimes addObjectsFromArray:[all2 subarrayWithRange:NSMakeRange(from,all2.count-from)]]; }
    double fixtureFirst=-1; for(NSNumber *x in fixtureTimes) if(fixtureFirst<0||x.doubleValue<fixtureFirst) fixtureFirst=x.doubleValue;
    BOOL controllerGot=gNotifCount>notif0; BOOL s1=controllerGot||fixtureTimes.count>0; if(!controllerGot&&fixtureFirst>=0) f1=fixtureFirst-start;
    // Arrival evidence: a window created by the windowless "arrival" fixture lands on the REAL active Space. It is validated on non-empty targets
    // (where T proves arrival) and then used as the arrival proof for empty targets. It is informational only for non-empty targets.
    NSMutableDictionary *arrival=[NSMutableDictionary dictionaryWithDictionary:@{@"applicable":@(gTargetEmpty)}]; BOOL arrivalOK=YES;
    if(s1&&s2&&s3&&gW) { NSDictionary *fr=[gW command:@"fresh"]; NSNumber *fw=fr[@"freshWindowNumber"]; NSArray *mem=@[];
        double end=millis()+1200; while(fw&&millis()<end&&!gAbort) { mem=membersOf(fw); if(mem.count) break; pump(0.05); }
        BOOL onTarget=[mem isEqual:@[@(gTarget)]]; arrival[@"freshWindowMembers"]=mem; arrival[@"onTargetSpace"]=@(onTarget); arrival[@"methodValidatedBefore"]=@(gFreshValidated);
        if(!gTargetEmpty&&onTarget) gFreshValidated=YES;
        if(gTargetEmpty) { arrivalOK=onTarget; arrival[@"pass"]=@(onTarget); }
        [gW command:@"closefresh"]; }
    else if(gTargetEmpty) { arrivalOK=NO; arrival[@"pass"]=@NO; arrival[@"reason"]=@"switch signals 1-3 did not hold, arrival not probed"; }
    // Signal 4: harmless F19 key (code 80) to whatever is frontmost, only if that is one of our fixtures.
    NSMutableDictionary *s4=[NSMutableDictionary dictionaryWithDictionary:@{@"applicable":@NO}];
    pid_t front=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier; NSString *frontAtArrival=front==gO.pid?@"origin":front==gT.pid?@"target":@"other"; double fs=millis();
    while(front!=gO.pid&&front!=gT.pid&&millis()-fs<1500&&!gAbort) { pump(0.05); front=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier; }
    NSString *frontLabel=front==gO.pid?@"origin":front==gT.pid?@"target":@"other";
    s4[@"frontmost"]=frontLabel; s4[@"frontmostAtArrival"]=frontAtArrival; s4[@"frontmostSettleMS"]=@(round1(millis()-fs));
    if(!CGPreflightPostEventAccess()) s4[@"reason"]=@"post-event access missing";
    else if([frontLabel isEqual:@"other"]) s4[@"reason"]=@"frontmost app is not a fixture; nothing posted (never type into user apps)";
    else {
        NSDictionary *a=[gO info],*b=[gT info]; CGEventSourceRef src=CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
        CGEventRef d=CGEventCreateKeyboardEvent(src,80,true),u=CGEventCreateKeyboardEvent(src,80,false); CGEventPost(kCGHIDEventTap,d); usleep(20000); CGEventPost(kCGHIDEventTap,u);
        CFRelease(d); CFRelease(u); if(src) CFRelease(src); pump(0.4);
        NSDictionary *a2=[gO info],*b2=[gT info]; NSInteger od=[a2[@"f19Count"] integerValue]-[a[@"f19Count"] integerValue],td=[b2[@"f19Count"] integerValue]-[b[@"f19Count"] integerValue];
        s4[@"originReceived"]=@(od); s4[@"targetReceived"]=@(td);
        if(gTargetEmpty) s4[@"reason"]=@"empty target Space: no target fixture window exists there, so receipt is recorded as information only (never part of the verdict)";
        else { s4[@"applicable"]=@YES; s4[@"pass"]=@(td>=1&&od==0); }
    }
    NSDictionary *oF=[gO info],*tF=[gT info];
    NSDictionary *signals=@{
        @"1_workspaceNotification":@{@"pass":@(s1),@"controllerReceived":@(controllerGot),@"count":@(gNotifCount-notif0),@"source":controllerGot?@"controller process":(s1?@"fixture process(es) only":@"none"),@"firstMS":f1>=0?@(round1(f1)):[NSNull null],
            @"fixtureNotificationCounts":@{@"origin":@([oF[@"spaceNotificationMS"] count]-oNotif0),@"target":@([tF[@"spaceNotificationMS"] count]-tNotif0)}},
        @"2_fixtureSelfReport":@{@"pass":@(s2),@"firstMS":f2>=0?@(round1(f2)):[NSNull null],@"origin":fixtureState(oi),@"target":fixtureState(ti)},
        @"3_cgOnScreenList":@{@"pass":@(s3),@"firstMS":f3>=0?@(round1(f3)):[NSNull null],@"originOnScreen":@([on containsObject:gOWin]),@"targetOrWitnessOnScreen":@([on containsObject:gTWin])},
        @"3b_arrivalFreshWindow":arrival,
        @"4_inputRouting":s4,
        @"5_skyLightGetterAuxiliary":@{@"matchedTarget":@(s5),@"firstMS":f5>=0?@(round1(f5)):[NSNull null],@"finalCurrent":@(currentSpace(cid,(__bridge CFStringRef)gDisplay)),@"countsAsSuccess":@NO}};
    BOOL inputOK=![s4[@"applicable"] boolValue]||[s4[@"pass"] boolValue];
    NSString *verdict=(s1&&s2&&s3&&inputOK&&arrivalOK)?@"pass":@"fail";
    if(gTargetEmpty&&s1&&s2&&s3&&!arrivalOK&&!gFreshValidated) verdict=@"inconclusive";   // departure proven, arrival method never validated
    NSDictionary *restore=ensureBaseline();
    NSMutableDictionary *r=[NSMutableDictionary dictionaryWithDictionary:@{@"verdict":verdict,@"arrivalOrFailureMS":@(round1(arrivalMS)),@"elapsedMS":@(round1(millis()-start)),@"signals":signals,@"notes":notes,@"restore":restore,
        @"spaceOrderBefore":orderBefore,@"spaceOrderAtArrival":orderAtArrival,@"spaceOrderAfterRestore":chosenOrder(),@"inputEvidence":@([s4[@"applicable"] boolValue])}];
    if(![restore[@"ok"] boolValue]) { gFatal=YES; gFatalReason=@"restore after attempt failed"; }
    return r;
}

static NSDictionary *runPath(NSString *name,NSString *desc,Action action) {
    NSString *only=NSProcessInfo.processInfo.environment[@"R2_PATHS"]; // optional comma-separated path-name prefixes
    if(only.length) { BOOL hit=NO; NSString *base=[name componentsSeparatedByString:@"/"].lastObject; for(NSString *prefix in [only componentsSeparatedByString:@","]) if([base hasPrefix:prefix]) hit=YES;
        if(!hit) return @{@"path":name,@"verdict":@"not-tested",@"reason":@"excluded by R2_PATHS filter",@"attempts":@[]}; }
    NSMutableArray *attempts=[NSMutableArray array]; int pass=0,fail=0,other=0;
    for(int i=0;i<kMaxAttempts;i++) {
        NSMutableDictionary *a=[NSMutableDictionary dictionaryWithDictionary:runAttempt(action)]; a[@"attempt"]=@(i+1); [attempts addObject:a];
        NSString *v=a[@"verdict"]; if([v isEqual:@"pass"]) pass++; else if([v isEqual:@"fail"]) fail++; else other++;
        if(other) break; // blocked/inconclusive preconditions are deterministic; do not repeat
    }
    NSString *verdict=other?@"inconclusive":(pass==(int)attempts.count?@"pass":(pass==0?@"fail":@"inconclusive"));
    fprintf(stderr,"path %s: %s (pass=%d fail=%d other=%d)\n",name.UTF8String,verdict.UTF8String,pass,fail,other);
    return @{@"path":name,@"description":desc,@"verdict":verdict,@"passCount":@(pass),@"failCount":@(fail),@"otherCount":@(other),@"attempts":attempts};
}

// ---------------------------------------------------------------- actions
static void postKey(CGKeyCode key,CGEventFlags flags,CGEventTapLocation tap) {
    CGEventSourceRef src=CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    CGEventRef d=CGEventCreateKeyboardEvent(src,key,true),u=CGEventCreateKeyboardEvent(src,key,false); CGEventSetFlags(d,flags); CGEventSetFlags(u,flags);
    CGEventPost(tap,d); usleep(30000); CGEventPost(tap,u); CFRelease(d); CFRelease(u); if(src) CFRelease(src);
}
static BOOL axRaiseTarget(NSMutableDictionary *notes) {
    if(!AXIsProcessTrusted()) { notes[@"axBlocked"]=@"AXIsProcessTrusted=false"; return NO; }
    AXUIElementRef app=AXUIElementCreateApplication(gT.pid); CFArrayRef windows=NULL;
    notes[@"axSetFrontmost"]=@(AXUIElementSetAttributeValue(app,kAXFrontmostAttribute,kCFBooleanTrue));
    AXError e=AXUIElementCopyAttributeValue(app,kAXWindowsAttribute,(CFTypeRef *)&windows); notes[@"axCopyWindows"]=@(e); notes[@"axWindowCount"]=@(windows?CFArrayGetCount(windows):0);
    for(CFIndex i=0;windows&&i<CFArrayGetCount(windows);i++) { AXUIElementRef w=(AXUIElementRef)CFArrayGetValueAtIndex(windows,i);
        notes[@"axRaise"]=@(AXUIElementPerformAction(w,kAXRaiseAction)); notes[@"axSetMain"]=@(AXUIElementSetAttributeValue(w,kAXMainAttribute,kCFBooleanTrue)); notes[@"axSetFocused"]=@(AXUIElementSetAttributeValue(w,kAXFocusedAttribute,kCFBooleanTrue)); }
    if(windows) CFRelease(windows); CFRelease(app); return YES;
}
static id hotkey(NSDictionary *all,int code) {
    NSDictionary *e=all[[NSString stringWithFormat:@"%d",code]]; if(![e isKindOfClass:NSDictionary.class]) return @{@"state":@"unspecified"};
    return @{@"state":[e[@"enabled"] boolValue]?@"enabled":@"disabled",@"parameters":e[@"value"][@"parameters"] ?: [NSNull null]};
}
static NSString *shell(NSString *path,NSArray *args) {
    NSTask *t=[NSTask new]; t.executableURL=[NSURL fileURLWithPath:path]; t.arguments=args; NSPipe *p=[NSPipe pipe]; t.standardOutput=p; t.standardError=p;
    if(![t launchAndReturnError:NULL]) return @""; NSData *d=[p.fileHandleForReading readDataToEndOfFile]; [t waitUntilExit];
    return [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSArray *sortedStructure(NSArray *st) { // same Spaces and current per display, order of Spaces ignored (macOS may rearrange Spaces by recent use)
    NSMutableArray *r=[NSMutableArray array];
    for(NSDictionary *d in st) { NSArray *ids=[[d[@"spaces"] valueForKey:@"id"] sortedArrayUsingSelector:@selector(compare:)]; [r addObject:@{@"ids":ids,@"current":d[@"current"]}]; }
    return r;
}
static void cleanupAndExit(NSString *outPath,NSMutableDictionary *result,NSArray *initialStructure) {
    NSDictionary *finalRestore=@{@"ok":@NO,@"method":@"fixturesMissing"};
    if(gO&&gT) { // return to the Space that was current when the run began: move the origin fixture there and activate it (B1), never the bridged setter
        double t0=millis(); NSString *m=@"alreadyAtStart";
        if(currentSpace(cid,(__bridge CFStringRef)gDisplay)!=gStartCurrent) { m=@"activateOriginFixture";
            if(gOrig!=gStartCurrent&&gOWin) { bridgedMoveWindows(@[gOWin],gStartCurrent); double e=millis()+3000; while(millis()<e&&![membersOf(gOWin) isEqual:@[@(gStartCurrent)]]) usleep(100000); m=@"moveOriginFixtureThenActivate"; }
            [gO.app activateWithOptions:NSApplicationActivateAllWindows|NSApplicationActivateIgnoringOtherApps]; double e=millis()+4000; while(millis()<e&&currentSpace(cid,(__bridge CFStringRef)gDisplay)!=gStartCurrent) usleep(100000); }
        finalRestore=@{@"ok":@(currentSpace(cid,(__bridge CFStringRef)gDisplay)==gStartCurrent),@"method":m,@"startCurrent":@(gStartCurrent),@"ms":@(round1(millis()-t0))}; }
    CGWarpMouseCursorPosition(gPointer);
    [gO stop]; [gT stop]; [gW stop];
    pump(0.5); if(gPreviousApp) [gPreviousApp activateWithOptions:NSApplicationActivateIgnoringOtherApps]; pump(0.3);
    NSArray *finalStructure=structure();
    result[@"finalRestoreCheck"]=@{@"baselineRestore":finalRestore,@"structureAtStart":initialStructure,@"structureAtEnd":finalStructure,
        @"spaceCountIdsAndCurrentUnchanged":@([initialStructure isEqual:finalStructure]),@"spaceIdsAndCurrentUnchangedIgnoringOrder":@([sortedStructure(initialStructure) isEqual:sortedStructure(finalStructure)]),@"fixtureProcessesTerminated":@(!gO.task.isRunning&&!gT.task.isRunning)};
    result[@"totalRuntimeSeconds"]=@(round1((millis()-gStartMS)/1000.0));
    NSData *json=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:NULL];
    [json writeToFile:outPath atomically:YES]; fprintf(stderr,"wrote %s\n",outPath.UTF8String);
}
static void killFixturesAtExit(void) { if(gO.task.isRunning) kill(gO.pid,SIGKILL); if(gT.task.isRunning) kill(gT.pid,SIGKILL); if(gW.task.isRunning) kill(gW.pid,SIGKILL); }

// ---------------------------------------------------------------- R2b scenarios
static NSArray *displaySpaces(void) { for(NSDictionary *d in spaceSnapshot()) if([d[@"Display Identifier"] isEqual:gDisplay]) return d[@"Spaces"]; return @[]; }
// Recompute direction, adjacency and 1-based Desktop numbers (display-local) from the CURRENT order, which macOS may rearrange by recent use.
static void computeGeometry(void) {
    NSArray *sp=displaySpaces(); NSUInteger oi=NSNotFound,ti=NSNotFound;
    for(NSUInteger i=0;i<sp.count;i++) { uint64_t v=[sp[i][@"id64"] unsignedLongLongValue]; if(v==gOrig) oi=i; if(v==gTarget) ti=i; }
    NSUInteger offset=0; if(![NSProcessInfo.processInfo.environment[@"R2_DESKTOP_NUMBERING"] isEqual:@"local"]) for(NSDictionary *d in spaceSnapshot()) { if([d[@"Display Identifier"] isEqual:gDisplay]) break; offset+=[d[@"Spaces"] count]; }   // global numbering by default
    gDesktopOffset=offset; gOrigDesktop=oi==NSNotFound?0:oi+1+offset; gTargetDesktop=ti==NSNotFound?0:ti+1+offset;
    gDirection=ti>oi; gAdjacent=(oi!=NSNotFound&&ti!=NSNotFound&&(ti==oi+1||oi==ti+1));
}
static BOOL placeWitness(uint64_t space) {
    if(![membersOf(gTWin) isEqual:@[@(space)]]) { bridgedMoveWindows(@[gTWin],space);
        double end=millis()+4000; while(millis()<end&&!gAbort&&![membersOf(gTWin) isEqual:@[@(space)]]) pump(0.1); }
    pump(0.5); double end=millis()+4000; while(millis()<end&&!gAbort&&!currentBaseline()) pump(0.1);
    return [membersOf(gTWin) isEqual:@[@(space)]]&&currentBaseline();
}
static void runScenario(NSMutableArray *paths,NSDictionary *hk,NSString *label,uint64_t target,BOOL empty,NSArray *which) {
    NSString *only=NSProcessInfo.processInfo.environment[@"R2_SCENARIOS"];
    if(only.length) { BOOL hit=NO; for(NSString *prefix in [only componentsSeparatedByString:@","]) if([label hasPrefix:prefix]) hit=YES; if(!hit) return; }
    if(gFatal||gAbort||!target) return;
    gTarget=target; gTargetEmpty=empty; computeGeometry();
    if(!placeWitness(empty?gOrig:target)) { [paths addObject:@{@"path":label,@"verdict":@"inconclusive",@"reason":@"witness fixture could not be placed or baseline not established",@"targetSpace":@(target),@"attempts":@[]}]; gFatal=YES; gFatalReason=@"scenario baseline failed"; return; }
    NSString *tag=[NSString stringWithFormat:@"%@(target=%llu,desktop=%lu,adjacent=%d,empty=%d)",label,target,(unsigned long)gTargetDesktop,gAdjacent,empty];
    CGEventFlags arrowFlags=kCGEventFlagMaskControl|kCGEventFlagMaskSecondaryFn|kCGEventFlagMaskNumericPad; CGKeyCode arrow=gDirection?124:123;
    if([which containsObject:@"A"]) for(NSNumber *tapNumber in @[@(kCGHIDEventTap),@(kCGSessionEventTap)]) {
        CGEventTapLocation tap=(CGEventTapLocation)tapNumber.intValue; NSString *tapName=tap==kCGHIDEventTap?@"HID":@"Session";
        NSString *name=[NSString stringWithFormat:@"%@/A_syntheticControlArrow_%@",label,tapName];
        if(!gAdjacent) { [paths addObject:@{@"path":name,@"verdict":@"not-tested",@"reason":@"target Space is not adjacent to the original (an arrow key moves one Space)",@"scenario":tag,@"attempts":@[]}]; continue; }
        [paths addObject:runPath(name,[NSString stringWithFormat:@"%@ CGEvent %@ arrow (keycode %d) with Control|SecondaryFn|NumericPad flags via %@ tap. %@",tag,gDirection?@"Right":@"Left",arrow,tapName,empty?@"Empty target Space.":@"Target Space holds the witness fixture."],
            ^BOOL(NSMutableDictionary *n){ CGWarpMouseCursorPosition(gCenter); usleep(100000); postKey(arrow,arrowFlags,tap); n[@"flags"]=@((uint64_t)arrowFlags); return YES; })];
        CGWarpMouseCursorPosition(gPointer);
    }
    if([which containsObject:@"B1"]) [paths addObject:runPath([label stringByAppendingString:@"/B1_activateTargetApp_NSRunningApplication"],[tag stringByAppendingString:@" NSRunningApplication activate of the target fixture."],
        ^BOOL(NSMutableDictionary *n){ n[@"activateReturned"]=@([gT.app activateWithOptions:NSApplicationActivateAllWindows|NSApplicationActivateIgnoringOtherApps]); return YES; })];
    if([which containsObject:@"B2"]) [paths addObject:runPath([label stringByAppendingString:@"/B2_activateTargetApp_AXRaise"],[tag stringByAppendingString:@" AXUIElement frontmost + AXRaise + AXMain + AXFocused on the target fixture."],
        ^BOOL(NSMutableDictionary *n){ if(!axRaiseTarget(n)){ n[@"blocked"]=@"Accessibility not trusted for this process"; return NO; } return YES; })];
    if([which containsObject:@"D"]) { // the Desktop number is recomputed at press time: an earlier activation may already have reordered the Spaces (MRU)
        NSString *name=[label stringByAppendingString:@"/D_systemSwitchToDesktopN"];
        [paths addObject:runPath(name,[NSString stringWithFormat:@"%@ 'Switch to Desktop N' hotkey (N from the current order, global numbering across displays unless R2_DESKTOP_NUMBERING=local) replayed via HID tap with the configured key and modifiers.",tag],
            ^BOOL(NSMutableDictionary *n){ computeGeometry();
                NSDictionary *e=gTargetDesktop>=1&&gTargetDesktop<=9?hk[[NSString stringWithFormat:@"%lu",(unsigned long)(117+gTargetDesktop)]]:nil;
                if(![e isKindOfClass:NSDictionary.class]||![e[@"enabled"] boolValue]) { n[@"blocked"]=@"Switch-to-Desktop hotkey for this desktop number is not enabled"; return NO; }
                NSArray *params=e[@"value"][@"parameters"]; CGKeyCode code=(CGKeyCode)[params[1] intValue]; CGEventFlags fl=(CGEventFlags)[params[2] unsignedLongLongValue];
                CGWarpMouseCursorPosition(gCenter); usleep(100000); postKey(code,fl,kCGHIDEventTap);
                n[@"keyCode"]=@(code); n[@"flags"]=@((uint64_t)fl); n[@"desktopNumber"]=@(gTargetDesktop); n[@"desktopNumberingOffset"]=@(gDesktopOffset); n[@"spaceOrderAtPress"]=chosenOrder(); return YES; })];
        CGWarpMouseCursorPosition(gPointer);
    }
}

static int runController(NSString *outPath) {
    { NSDictionary *e=NSProcessInfo.processInfo.environment; if(e[@"R2_BUDGET"]) kTotalBudgetSeconds=[e[@"R2_BUDGET"] doubleValue]; if(e[@"R2_MAX_ATTEMPTS"]) kMaxAttempts=[e[@"R2_MAX_ATTEMPTS"] intValue]; gHotkeysEnabled=[e[@"R2_HOTKEYS_ENABLED"] isEqual:@"1"]; }
    NSMutableDictionary *result=[NSMutableDictionary dictionary]; gStartMS=millis(); gKeepOperations=[NSMutableArray array]; signal(SIGPIPE,SIG_IGN); atexit(killFixturesAtExit);
    NSApplication *app=NSApplication.sharedApplication; [app setActivationPolicy:NSApplicationActivationPolicyAccessory]; [app finishLaunching];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{ // hard watchdog: abort flag first, then forced exit
        usleep((useconds_t)(kTotalBudgetSeconds*1e6)); gAbort=YES; usleep(15*1000000); killFixturesAtExit(); _exit(4); });
    for(NSNumber *sig in @[@(SIGINT),@(SIGTERM)]) { signal(sig.intValue,SIG_IGN); dispatch_source_t s=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,sig.intValue,0,dispatch_get_main_queue()); dispatch_source_set_event_handler(s,^{ gAbort=YES; }); dispatch_resume(s); }
    void *h=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_LAZY|RTLD_LOCAL);
    int(*connection)(void)=dlsym(h,"SLSMainConnectionID"); copySpaces=dlsym(h,"SLSCopyManagedDisplaySpaces"); currentSpace=dlsym(h,"SLSManagedDisplayGetCurrentSpace"); windowSpaces=dlsym(h,"SLSCopySpacesForWindows");
    displayUUID=dlsym(h,"CGDisplayCreateUUIDFromDisplayID");
    bridgePerform=macho_find_symbol("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight","__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation");
    NSMutableDictionary *env=[NSMutableDictionary dictionary]; result[@"environment"]=env;
    struct utsname uts; uname(&uts); char build[64]={0}; size_t len=sizeof(build); sysctlbyname("kern.osversion",build,&len,NULL,0);
    NSDictionary *hk=CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("AppleSymbolicHotKeys"),CFSTR("com.apple.symbolichotkeys")));
    NSMutableDictionary *keys=[NSMutableDictionary dictionary]; for(int c=79;c<=82;c++) keys[[NSString stringWithFormat:@"%d",c]]=hotkey(hk,c); for(int c=118;c<=126;c++) keys[[NSString stringWithFormat:@"%d",c]]=hotkey(hk,c);
    id swoosh=CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("workspaces-auto-swoosh"),CFSTR("com.apple.dock"))); id spans=CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("spans-displays"),CFSTR("com.apple.spaces")));
    [env addEntriesFromDictionary:@{@"os":NSProcessInfo.processInfo.operatingSystemVersionString,@"build":@(build),@"arch":@(uts.machine),
        @"sip":shell(@"/usr/bin/csrutil",@[@"status"]),@"axTrusted":@(AXIsProcessTrusted()),@"postEventPreflight":@(CGPreflightPostEventAccess()),@"listenEventPreflight":@(CGPreflightListenEventAccess()),
        @"screenCapturePreflight":@(CGPreflightScreenCaptureAccess()),@"screenshotsTaken":@NO,
        @"symbolicHotkeys":keys,@"dockWorkspacesAutoSwoosh":swoosh ?: @"unset (system default applies)",@"spacesSpansDisplays":spans ?: @"unset (system default applies)",
        @"privateSymbols":@{@"SLSCopyManagedDisplaySpaces":@(copySpaces!=NULL),@"SLSManagedDisplayGetCurrentSpace":@(currentSpace!=NULL),@"SLSCopySpacesForWindows":@(windowSpaces!=NULL),@"bridgePerform":@(bridgePerform!=NULL),
            @"SetCurrentSpaceOperationClass":@(NSClassFromString(@"SLSBridgedManagedDisplaySetCurrentSpaceOperation")!=nil),@"MoveWindowsOperationClass":@(NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation")!=nil)}}];
    result[@"schemaVersion"]=@1; result[@"date"]=@"2026-10-21";
    result[@"verdictRules"]=@{
        @"attemptPass":@"Signals 1 (workspace notification), 2 (fixture self-report: target isOnActiveSpace and occlusionVisible YES, origin NO for both), 3 (CG on-screen list: origin gone, target present) must all hold at the same time after a 300 ms stability recheck; signal 4 (F19 routed to the target fixture only) must pass whenever it is applicable. A fixture-posted F19 is skipped when the frontmost app is not a fixture, and then inputEvidence=false.",
        @"signal5":@"SLSManagedDisplayGetCurrentSpace is auxiliary only and never counts toward success.",
        @"attemptInconclusive":@"The action could not be performed (permission/precondition missing) or the baseline could not be established.",
        @"pathVerdict":@"pass = every executed attempt passed; fail = no attempt passed and none was inconclusive; inconclusive = mixed results, blocked precondition or skipped; not-tested = path not applicable (e.g. hotkey disabled).",
        @"overallVerdict":@"pass = at least one path pass; fail = every tested path failed; inconclusive otherwise.",
        @"timing":@{@"attemptTimeoutSeconds":@(kAttemptTimeoutSeconds),@"maxAttempts":@(kMaxAttempts),@"totalBudgetSeconds":@(kTotalBudgetSeconds)}};
    if(!connection||!copySpaces||!currentSpace||!windowSpaces||!displayUUID) { result[@"overallVerdict"]=@"inconclusive"; result[@"reason"]=@"SkyLight symbols missing"; [[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:NULL] writeToFile:outPath atomically:YES]; return 2; }
    cid=connection();
    if(gPreflightOnly) { // read-only: permission preflights (never the request APIs) and the Space structure; no fixtures, no events
        NSData *j=[NSJSONSerialization dataWithJSONObject:@{@"AXIsProcessTrusted":@(AXIsProcessTrusted()),@"CGPreflightPostEventAccess":@(CGPreflightPostEventAccess()),
            @"CGPreflightListenEventAccess":@(CGPreflightListenEventAccess()),@"CGPreflightScreenCaptureAccess":@(CGPreflightScreenCaptureAccess()),@"structure":structure(),
            @"displays":[spaceSnapshot() valueForKey:@"Display Identifier"],@"windowCensusBySpace":census(@[]),@"mruSpaces":CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("mru-spaces"),CFSTR("com.apple.dock"))) ?: @"unset (system default: automatic rearrange)"} options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:NULL];
        printf("%s\n",(const char *)[[[NSString alloc] initWithData:j encoding:NSUTF8StringEncoding] UTF8String]); return 0; }
    NSArray *initial=structure(); result[@"structureAtStart"]=initial; gPreviousApp=NSWorkspace.sharedWorkspace.frontmostApplication;
    CGEventRef pe=CGEventCreate(NULL); gPointer=CGEventGetLocation(pe); CFRelease(pe);
    [NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:NSWorkspaceActiveSpaceDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n){ (void)n; gNotifCount++; }];
    // Choose the display with the most Spaces, a normal current Space and a normal neighbour (right preferred).
    NSDictionary *chosen=nil; for(NSDictionary *d in spaceSnapshot()) if([d[@"Spaces"] count]>[chosen[@"Spaces"] count]) chosen=d;
    { NSString *di=NSProcessInfo.processInfo.environment[@"R2_DISPLAY_INDEX"]; NSArray *snap=spaceSnapshot(); if(di.length&&(NSUInteger)di.integerValue<snap.count) chosen=snap[di.integerValue]; }   // optional: pick a display by enumeration index
    gDisplay=chosen[@"Display Identifier"]; gOrig=currentSpace(cid,(__bridge CFStringRef)gDisplay); gStartCurrent=gOrig; NSArray *spaces=chosen[@"Spaces"]; NSUInteger idx=NSNotFound;
    for(NSUInteger i=0;i<spaces.count;i++) if([spaces[i][@"id64"] unsignedLongLongValue]==gOrig) idx=i;
    gTarget=0; if(idx!=NSNotFound&&[spaces[idx][@"type"] intValue]==0) {
        if(idx+1<spaces.count&&[spaces[idx+1][@"type"] intValue]==0){ gTarget=[spaces[idx+1][@"id64"] unsignedLongLongValue]; gDirection=1; }
        else if(idx>0&&[spaces[idx-1][@"type"] intValue]==0){ gTarget=[spaces[idx-1][@"id64"] unsignedLongLongValue]; gDirection=0; } }
    NSString *override=NSProcessInfo.processInfo.environment[@"R2_TARGET_SPACE_ID"]; // optional: pick another normal Space (A is then skipped unless adjacent)
    if(override&&gTarget) for(NSUInteger i=0;i<spaces.count;i++) if([spaces[i][@"id64"] unsignedLongLongValue]==(uint64_t)override.longLongValue&&i!=idx&&[spaces[i][@"type"] intValue]==0) { gTarget=(uint64_t)override.longLongValue; gDirection=i>idx; gAdjacent=(i==idx+1||i+1==idx); }
    result[@"setup"]=@{@"originalSpace":@(gOrig),@"targetSpace":@(gTarget),@"targetIsRightNeighbour":@(gDirection==1),@"targetIsAdjacent":@(gAdjacent),@"originalIndex":idx==NSNotFound?@-1:@(idx),@"displaySpaceCount":@(spaces.count)};
    NSMutableArray *paths=[NSMutableArray array]; result[@"paths"]=paths;
    if(!gTarget) { result[@"overallVerdict"]=@"inconclusive"; result[@"reason"]=@"no normal neighbour Space next to a normal current Space"; [[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:NULL] writeToFile:outPath atomically:YES]; return 2; }
    NSScreen *screen=NSScreen.mainScreen;
    for(NSScreen *s in NSScreen.screens) { CFUUIDRef u=displayUUID([s.deviceDescription[@"NSScreenNumber"] unsignedIntValue]); NSString *v=u?CFBridgingRelease(CFUUIDCreateString(NULL,u)):nil; if(u) CFRelease(u); if([v isEqual:gDisplay]) screen=s; }
    CGRect bounds=CGDisplayBounds([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue]); gCenter=CGPointMake(CGRectGetMidX(bounds),CGRectGetMidY(bounds));
    NSRect vf=screen.visibleFrame;
    if(gStatusOnly) { // read-only diagnostic: a fresh window lands on the REAL active Space, so its membership shows where the scene is
        gO=[Fx new]; gO.name=@"origin"; BOOL ok=[gO launchWithFrame:NSMakeRect(NSMinX(vf)+80,NSMinY(vf)+120,300,110)]; pump(1.2); NSDictionary *i=ok?[gO info]:nil;
        { NSData *j=[NSJSONSerialization dataWithJSONObject:structure() options:0 error:NULL]; printf("structure=%s\n",(const char *)[[[NSString alloc] initWithData:j encoding:NSUTF8StringEncoding] UTF8String]); }
        printf("getterCurrent=%llu freshWindowMembers=%s isOnActiveSpace=%s\n",gOrig,i?[[membersOf(i[@"windowNumber"]) description] UTF8String]:"n/a",i?([i[@"isOnActiveSpace"] boolValue]?"YES":"NO"):"n/a");
        [gO stop]; return 0; }
    // Setup: witness fixture T first, origin fixture O last so the origin app ends up frontmost. T is placed per scenario.
    gT=[Fx new]; gT.name=@"target"; gO=[Fx new]; gO.name=@"origin"; gW=[Fx new]; gW.name=@"arrival"; [gW launchWithFrame:NSMakeRect(0,0,10,10)];
    BOOL launched=[gT launchWithFrame:NSMakeRect(NSMinX(vf)+420,NSMinY(vf)+120,360,110)]; pump(0.8); launched=launched&&[gO launchWithFrame:NSMakeRect(NSMinX(vf)+80,NSMinY(vf)+120,300,110)];
    NSDictionary *oi=nil,*ti=nil; double end=millis()+6000; while(launched&&millis()<end&&!gAbort){ oi=[gO info]; ti=[gT info]; if(oi&&ti&&membersOf(oi[@"windowNumber"]).count&&membersOf(ti[@"windowNumber"]).count) break; pump(0.2); }
    gOWin=oi[@"windowNumber"]; gTWin=ti[@"windowNumber"]; pump(0.5); if(![gW info]) { result[@"setupWarning"]=@"arrival fixture did not answer"; }
    { NSString *fs=NSProcessInfo.processInfo.environment[@"R2_FINAL_SPACE"]; if(fs.length) gStartCurrent=(uint64_t)fs.longLongValue; }   // recovery mode: end on this Space instead of the start Space
    NSDictionary *cen=census(@[@(gO.pid),@(gT.pid)]);
    result[@"setup"]=@{@"originalSpace":@(gOrig),@"firstTargetSpace":@(gTarget),@"fixturesLaunched":@(launched),@"spaceOrderAtStart":chosenOrder(),@"windowCensusBySpaceExcludingFixtures":cen,
        @"censusNote":@"normal-layer windows with alpha>0 and size>50pt, grouped by Space membership; titles are not read. Count 0 = empty desktop candidate."};
    if(!launched||!gOWin||!gTWin) { result[@"overallVerdict"]=@"inconclusive"; result[@"reason"]=@"fixture launch failed"; cleanupAndExit(outPath,result,initial); return 2; }
    NSString *ro=NSProcessInfo.processInfo.environment[@"R2_ORIGIN_SPACE"];   // optional: first reach another origin (B1 with the origin fixture), e.g. an end Space so a non-adjacent target exists
    if(ro.length&&(uint64_t)ro.longLongValue!=gOrig&&[[displaySpaces() valueForKey:@"id64"] containsObject:@(ro.longLongValue)]) {
        uint64_t dest=(uint64_t)ro.longLongValue; bridgedMoveWindows(@[gOWin],dest); double e2=millis()+3000; while(millis()<e2&&!gAbort&&![membersOf(gOWin) isEqual:@[@(dest)]]) pump(0.1);
        [gO.app activateWithOptions:NSApplicationActivateAllWindows|NSApplicationActivateIgnoringOtherApps]; e2=millis()+3500; while(millis()<e2&&!gAbort&&currentSpace(cid,(__bridge CFStringRef)gDisplay)!=dest) pump(0.1);
        BOOL moved=currentSpace(cid,(__bridge CFStringRef)gDisplay)==dest; result[@"originRepositioning"]=@{@"from":@(gOrig),@"to":@(dest),@"ok":@(moved)};
        if(moved) gOrig=dest; else { gFatal=YES; gFatalReason=@"origin repositioning failed"; } pump(0.5);
    }
    NSArray *spaceIDs=[displaySpaces() valueForKey:@"id64"]; NSMutableArray *others=[NSMutableArray array];
    for(NSDictionary *sp in displaySpaces()) if([sp[@"type"] intValue]==0&&[sp[@"id64"] unsignedLongLongValue]!=gOrig) [others addObject:sp[@"id64"]];
    (void)spaceIDs;
    // Pick targets from the current order: nearest/second-nearest normal Space on the origin's right then left; empty = census count 0.
    NSUInteger oidx=[[displaySpaces() valueForKey:@"id64"] indexOfObject:@(gOrig)]; uint64_t adj=0,far=0,emptyAdj=0,emptyFar=0;
    for(NSNumber *sid in others) { NSUInteger idx=[[displaySpaces() valueForKey:@"id64"] indexOfObject:sid]; BOOL isAdj=(idx==oidx+1||idx+1==oidx); BOOL isEmpty=[cen[sid.stringValue] integerValue]==0;
        if(isAdj){ if(!adj) adj=sid.unsignedLongLongValue; if(isEmpty&&!emptyAdj) emptyAdj=sid.unsignedLongLongValue; } else { if(!far) far=sid.unsignedLongLongValue; if(isEmpty&&!emptyFar) emptyFar=sid.unsignedLongLongValue; } }
    result[@"scenarioTargets"]=@{@"adjacentNonEmptyByWitness":@(adj),@"farNonEmptyByWitness":@(far),@"adjacentEmpty":emptyAdj?@(emptyAdj):@"none available",@"farEmpty":emptyFar?@(emptyFar):@"none available"};
    CGPoint here=gPointer; (void)here;
    // Adjacent first, non-adjacent last, to disturb the Space order as little as possible.
    runScenario(paths,hk,@"S1_adjacentWithWindow",adj,NO,@[@"B1",@"A",@"B2",@"D"]);
    runScenario(paths,hk,@"S2_adjacentEmpty",emptyAdj,YES,@[@"A",@"D"]);
    runScenario(paths,hk,@"S3_nonAdjacentWithWindow",far,NO,@[@"B1",@"B2",@"D"]);
    runScenario(paths,hk,@"S4_nonAdjacentEmpty",emptyFar,YES,@[@"D"]);
    if(!emptyAdj&&!emptyFar) result[@"emptyDesktopNote"]=@"No empty desktop exists on the chosen display (census count 0); empty-target paths were not tested.";

    int passPaths=0,failPaths=0,tested=0; for(NSDictionary *p in paths) { NSString *v=p[@"verdict"]; if([v isEqual:@"not-tested"]) continue; tested++; if([v isEqual:@"pass"]) passPaths++; else if([v isEqual:@"fail"]) failPaths++; }
    result[@"overallVerdict"]=passPaths>0?@"pass":(tested>0&&failPaths==tested?@"fail":@"inconclusive");
    result[@"aborted"]=@(gAbort); result[@"fatal"]=gFatal?gFatalReason:[NSNull null];
    cleanupAndExit(outPath,result,initial);
    return 0;
}

int main(int argc,char **argv) {
    @autoreleasepool {
        if(argc>=2&&strcmp(argv[1],"--status")==0) gStatusOnly=YES;
        if(argc>=2&&strcmp(argv[1],"--preflight")==0) gPreflightOnly=YES;
        if(argc>=4&&strcmp(argv[1],"--fixture")==0) return runFixture(@(argv[2]),@(argv[3]));
        NSString *out=argc>=3&&strcmp(argv[1],"--out")==0 ? @(argv[2]) : [NSProcessInfo.processInfo.environment[@"GRID_PROBE_OUTPUT"] ?: NSTemporaryDirectory() stringByAppendingPathComponent:@"r2-switch-observations.json"];
        return runController(out);
    }
}
