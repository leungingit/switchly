// Research only: getterMatched does not mean a visually verified Space switch.
// Historical raw logs used the misleading name confirmed; see evaluation report.
// Standalone research fixture; never linked into Switchly. Window mutations target owned fixtures only; switching changes the current session.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <dlfcn.h>
#import <time.h>
#import <mach-o/dyld.h>
#import <mach-o/nlist.h>
#define string_equals(a,b) (strcmp((a),(b))==0)
#include "yabai-macho-dlsym.h"
@interface NSObject (GridBridgeInit)
- (id)initWithWindows:(NSArray *)windows spaceID:(uint64_t)sid;
- (id)initWithDisplayIdentifier:(NSString *)display spaceID:(uint64_t)sid;
@end
// Gesture field technique follows yabai dd845723416f5fe92af49fad5ebab00369e07edd.
// Copyright (c) 2019 Åsmund Vikane. MIT license, full notice in yabai-MIT.txt.
static int cid;
static CFArrayRef (*copySpaces)(int);
static uint64_t (*currentSpace)(int,CFStringRef);
static CFArrayRef (*windowSpaces)(int,int,CFArrayRef);
static void (*legacyMove)(int,CFArrayRef,uint64_t);
static int64_t (*bridgePerform)(void *);
static BOOL useBridge=NO;
static void moveWindows(int connection,CFArrayRef windows,uint64_t sid){
    if(useBridge){if(!bridgePerform)return;Class cls=NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation");id operation=[[cls alloc] initWithWindows:(__bridge NSArray *)windows spaceID:sid];if(operation)bridgePerform((__bridge void *)operation);}
    else if(legacyMove)legacyMove(connection,windows,sid);
}
static bool (*isAnimating)(int,CFStringRef);
static CFUUIDRef (*displayUUID)(CGDirectDisplayID);
static double millis(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec*1000.0+t.tv_nsec/1e6; }
static NSArray *snapshot(void) { return CFBridgingRelease(copySpaces(cid)) ?: @[]; }
static NSArray *members(NSWindow *w) { return CFBridgingRelease(windowSpaces(cid,7,(__bridge CFArrayRef)@[@(w.windowNumber)])) ?: @[]; }
static void later(double seconds,dispatch_block_t block) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(seconds*NSEC_PER_SEC)),dispatch_get_main_queue(),block); }
@interface Probe : NSObject <NSApplicationDelegate>
@property NSWindow *panel;
@property NSMutableArray<NSWindow *> *fixtures;
@property NSTextField *status;
@property NSMutableArray<NSButton *> *buttons;
@property NSArray *initial;
@property NSString *display;
@property NSArray<NSNumber *> *targets;
@property uint64_t original;
@property CGPoint pointer;
@property CGPoint center;
@property NSRunningApplication *previousApp;
@property BOOL busy;
@property BOOL bridgedSwitch;
@end
@implementation Probe
- (void)log:(NSString *)event data:(NSDictionary *)data {
    NSMutableDictionary *entry=[data mutableCopy]; entry[@"event"]=event; entry[@"monotonicMS"]=@(millis());
    NSData *json=[NSJSONSerialization dataWithJSONObject:entry options:NSJSONWritingSortedKeys error:NULL];
    NSString *path=[NSProcessInfo.processInfo.environment[@"GRID_PROBE_OUTPUT"] stringByAppendingPathComponent:@"control.jsonl"];
    if (!path) return;
    NSFileHandle *f=[NSFileHandle fileHandleForWritingAtPath:path];
    if (!f) { [NSFileManager.defaultManager createFileAtPath:path contents:nil attributes:@{NSFilePosixPermissions:@0600}]; f=[NSFileHandle fileHandleForWritingAtPath:path]; }
    [f seekToEndOfFile]; [f writeData:json]; [f writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]]; [f closeFile];
    NSLog(@"%@ %@",event,[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]);
}
- (void)setBusyState:(BOOL)busy message:(NSString *)message { self.busy=busy; self.status.stringValue=message; for(NSButton *b in self.buttons) b.enabled=!busy; }
- (NSArray *)structure {
    NSMutableArray *r=[NSMutableArray array];
    for(NSDictionary *d in snapshot()) { NSMutableArray *s=[NSMutableArray array]; for(NSDictionary *v in d[@"Spaces"]) [s addObject:@{@"id":v[@"id64"] ?: @0,@"type":v[@"type"] ?: @(-1),@"uuid":v[@"uuid"] ?: @""}]; [r addObject:@{@"spaces":s,@"current":@(currentSpace(cid,(__bridge CFStringRef)d[@"Display Identifier"]))}]; } return r;
}
- (NSArray *)fixtureVisibility {
    NSArray *cg=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID));NSMutableArray *r=[NSMutableArray array];
    for(NSWindow *window in self.fixtures){BOOL onscreen=NO;for(NSDictionary *w in cg)if([w[(__bridge NSString *)kCGWindowNumber] integerValue]==window.windowNumber)onscreen=[w[(__bridge NSString *)kCGWindowIsOnscreen] boolValue];[r addObject:@{@"id":@(window.windowNumber),@"onScreen":@(onscreen),@"occlusionVisible":@((window.occlusionState&NSWindowOcclusionStateVisible)!=0),@"members":members(window)}];}return r;
}
- (void)inspect:(id)sender {
    (void)sender; [self.fixtures[0] orderFrontRegardless]; [self.panel orderFrontRegardless]; NSMutableArray *windows=[NSMutableArray array];
    for(NSWindow *w in self.fixtures) [windows addObject:@{@"id":@(w.windowNumber),@"members":members(w),@"minimized":@(w.miniaturized),@"fullScreen":@((w.styleMask & NSWindowStyleMaskFullScreen)!=0)}];
    [self log:@"inspect" data:@{@"structure":[self structure],@"ownedWindows":windows,@"visibility":[self fixtureVisibility]}]; self.status.stringValue=@"Snapshot written (owned windows only).";
}
- (NSWindow *)makeFixture:(NSUInteger)index screen:(NSScreen *)screen {
    NSRect f=screen.visibleFrame; NSWindow *w=[[NSWindow alloc] initWithContentRect:NSMakeRect(NSMinX(f)+80+index*35,NSMinY(f)+100+index*35,420,180) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    w.releasedWhenClosed=NO; w.title=[NSString stringWithFormat:@"Grid Probe Fixture %lu",(unsigned long)index+1]; w.collectionBehavior=NSWindowCollectionBehaviorFullScreenPrimary;
    NSTextField *text=[NSTextField labelWithString:@"Temporary owned test window. No user content."]; text.frame=NSMakeRect(20,70,380,40); [w.contentView addSubview:text]; [w orderFront:nil]; return w;
}
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    (void)note; void *h=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_LAZY|RTLD_LOCAL);
    int(*connection)(void)=dlsym(h,"SLSMainConnectionID"); copySpaces=dlsym(h,"SLSCopyManagedDisplaySpaces"); currentSpace=dlsym(h,"SLSManagedDisplayGetCurrentSpace"); windowSpaces=dlsym(h,"SLSCopySpacesForWindows"); legacyMove=dlsym(h,"SLSMoveWindowsToManagedSpace"); bridgePerform=macho_find_symbol("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight","__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation"); isAnimating=dlsym(h,"SLSManagedDisplayIsAnimating"); displayUUID=dlsym(h,"CGDisplayCreateUUIDFromDisplayID");
    if(!connection||!copySpaces||!currentSpace||!windowSpaces||!displayUUID) { [NSApp terminate:nil]; return; } cid=connection();
    self.previousApp=NSWorkspace.sharedWorkspace.frontmostApplication; self.initial=snapshot(); self.fixtures=[NSMutableArray array]; self.buttons=[NSMutableArray array];
    CGEventRef e=CGEventCreate(NULL); self.pointer=CGEventGetLocation(e); CFRelease(e);
    NSDictionary *chosen=nil; for(NSDictionary *d in self.initial) if([d[@"Spaces"] count]>[chosen[@"Spaces"] count]) chosen=d;
    self.display=chosen[@"Display Identifier"]; self.original=currentSpace(cid,(__bridge CFStringRef)self.display);
    NSMutableArray *ids=[NSMutableArray array]; for(NSDictionary *s in chosen[@"Spaces"]) if([s[@"type"] intValue]==0) [ids addObject:s[@"id64"]]; self.targets=ids;
    NSScreen *targetScreen=NSScreen.mainScreen;
    for(NSScreen *screen in NSScreen.screens) { CFUUIDRef uuid=displayUUID([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue]); NSString *value=uuid ? CFBridgingRelease(CFUUIDCreateString(NULL,uuid)) : nil; if(uuid) CFRelease(uuid); if([value isEqual:self.display]) targetScreen=screen; }
    CGRect bounds=CGDisplayBounds([targetScreen.deviceDescription[@"NSScreenNumber"] unsignedIntValue]); self.center=CGPointMake(CGRectGetMidX(bounds),CGRectGetMidY(bounds));
    for(NSUInteger i=0;i<2;i++) [self.fixtures addObject:[self makeFixture:i screen:targetScreen]];
    NSRect f=targetScreen.visibleFrame; self.panel=[[NSWindow alloc] initWithContentRect:NSMakeRect(NSMinX(f)+600,NSMinY(f)+150,520,800) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO]; self.panel.releasedWhenClosed=NO; self.panel.title=@"Grid Probe Controller"; self.panel.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorFullScreenAuxiliary|NSWindowCollectionBehaviorStationary;
    NSArray *titles=@[@"Inspect owned windows",@"Test minimize and restore",@"Test legacy move and restore",@"Test one gesture round trip",@"Test bridged space round trip",@"Hold last Space (bridged)",@"Restore original Space (bridged)",@"Test owned fullscreen lifecycle",@"Test cross-process legacy move",@"Test cross-process bridged move",@"Test configured system shortcut",@"Restore pointer and quit"];
    NSArray *selectors=@[NSStringFromSelector(@selector(inspect:)),NSStringFromSelector(@selector(minimize:)),NSStringFromSelector(@selector(move:)),NSStringFromSelector(@selector(gestureRoundTrip:)),NSStringFromSelector(@selector(bridgeRoundTrip:)),NSStringFromSelector(@selector(hold:)),NSStringFromSelector(@selector(restore:)),NSStringFromSelector(@selector(fullscreen:)),NSStringFromSelector(@selector(foreignLegacy:)),NSStringFromSelector(@selector(foreignBridge:)),NSStringFromSelector(@selector(systemShortcut:)),NSStringFromSelector(@selector(quit:))];
    for(NSUInteger i=0;i<titles.count;i++){ NSButton *b=[NSButton buttonWithTitle:titles[i] target:self action:NSSelectorFromString(selectors[i])]; b.frame=NSMakeRect(20,730-i*44,480,34); [self.panel.contentView addSubview:b]; [self.buttons addObject:b]; }
    self.status=[NSTextField wrappingLabelWithString:@"Ready. Test windows only. No permissions requested."]; self.status.frame=NSMakeRect(20,15,480,55); [self.panel.contentView addSubview:self.status];
    [self.panel makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
    [self log:@"startup" data:@{@"os":NSProcessInfo.processInfo.operatingSystemVersionString,@"axTrusted":@(AXIsProcessTrusted()),@"postEventPreflight":@(CGPreflightPostEventAccess()),@"screenPreflight":@(CGPreflightScreenCaptureAccess()),@"structure":[self structure],@"targetOriginal":@(self.original),@"targetSpaceCount":@(self.targets.count)}]; [self inspect:nil];
}
- (void)minimize:(id)sender { (void)sender; if(self.busy)return; [self setBusyState:YES message:@"Testing minimize..."]; NSWindow *w=self.fixtures[0]; NSArray *before=members(w); [w miniaturize:nil]; later(0.5,^{ [self log:@"minimized" data:@{@"before":before,@"after":members(w),@"flag":@(w.miniaturized)}]; [w deminiaturize:nil]; later(0.5,^{ [self log:@"deminimized" data:@{@"members":members(w),@"flag":@(w.miniaturized)}]; [self setBusyState:NO message:@"Minimize lifecycle recorded."]; }); }); }
- (void)move:(id)sender { (void)sender; if(self.busy||!legacyMove)return; useBridge=NO; NSWindow *w=self.fixtures[0]; NSArray *before=members(w); NSNumber *origin=before.firstObject; NSNumber *target=nil; for(NSNumber *n in self.targets) if(![before containsObject:n]) {target=n;break;}
    if(!origin||!target)return; [self setBusyState:YES message:@"Moving owned window with legacy API..."]; CFArrayRef list=(__bridge CFArrayRef)@[@(w.windowNumber)]; moveWindows(cid,list,target.unsignedLongLongValue);
    later(0.8,^{ NSArray *after=members(w); BOOL reached=[after containsObject:target]; [self log:@"legacyMove" data:@{@"origin":origin,@"target":target,@"before":before,@"after":after,@"reached":@(reached)}];
        if(![after isEqual:before]) moveWindows(cid,(__bridge CFArrayRef)@[@(w.windowNumber)],origin.unsignedLongLongValue);
        later(0.8,^{ [self log:@"legacyMoveRestore" data:@{@"after":members(w),@"matchesBefore":@([members(w) isEqual:before])}]; [self setBusyState:NO message:reached ? @"Legacy move reached target; restore recorded." : @"Legacy move did not reach target. No success inferred."]; }); });
}
- (void)switchTo:(uint64_t)target completion:(void(^)(BOOL,double))completion {
    NSArray *fresh=snapshot(); NSArray *ids=nil;
    for(NSDictionary *d in fresh) if([d[@"Display Identifier"] isEqual:self.display]) {NSMutableArray *a=[NSMutableArray array];for(NSDictionary *s in d[@"Spaces"]) [a addObject:s[@"id64"]]; ids=a;}
    uint64_t before=currentSpace(cid,(__bridge CFStringRef)self.display); NSUInteger a=[ids indexOfObject:@(before)], b=[ids indexOfObject:@(target)];
    if(a==NSNotFound||b==NSNotFound||(!self.bridgedSwitch&&!CGPreflightPostEventAccess())){completion(NO,0);return;} if(a==b){completion(YES,0);return;}
    if(isAnimating&&isAnimating(cid,(__bridge CFStringRef)self.display)){completion(NO,0);return;}
    if(self.bridgedSwitch){if(!bridgePerform){completion(NO,0);return;}Class cls=NSClassFromString(@"SLSBridgedManagedDisplaySetCurrentSpaceOperation");if(!cls){completion(NO,0);return;}id operation=[[cls alloc] initWithDisplayIdentifier:self.display spaceID:target];double start=millis();bridgePerform((__bridge void *)operation);[self confirm:target start:start attempt:0 stable:0 completion:completion];return;}
    CGWarpMouseCursorPosition(self.center); CGEventRef event=CGEventCreate(NULL); if(!event){completion(NO,0);return;}
    double sign=b>a ? 1.0 : -1.0; CGEventSetIntegerValueField(event,55,30); CGEventSetIntegerValueField(event,110,23); CGEventSetIntegerValueField(event,123,1); CGEventSetDoubleValueField(event,124,sign); CGEventSetDoubleValueField(event,129,sign*9999.0);
    double start=millis(); for(NSUInteger i=0;i<(a>b?a-b:b-a);i++){CGEventSetIntegerValueField(event,132,1);CGEventPost(kCGSessionEventTap,event);CGEventSetIntegerValueField(event,132,4);CGEventPost(kCGSessionEventTap,event);}CFRelease(event);
    [self confirm:target start:start attempt:0 stable:0 completion:completion];
}
- (void)confirm:(uint64_t)target start:(double)start attempt:(NSUInteger)attempt stable:(NSUInteger)stable completion:(void(^)(BOOL,double))completion {
    later(0.05,^{ BOOL matches=currentSpace(cid,(__bridge CFStringRef)self.display)==target; BOOL settled=!isAnimating||!isAnimating(cid,(__bridge CFStringRef)self.display); NSUInteger next=matches&&settled ? stable+1:0;
        if(next>=3){completion(YES,millis()-start);return;} if(attempt>=59){completion(NO,millis()-start);return;}
        [self confirm:target start:start attempt:attempt+1 stable:next completion:completion]; });
}
- (void)gestureRoundTrip:(id)sender {self.bridgedSwitch=NO;[self roundTrip:sender];}
- (void)bridgeRoundTrip:(id)sender {self.bridgedSwitch=YES;[self roundTrip:sender];}
- (void)roundTrip:(id)sender { (void)sender; if(self.busy)return; NSNumber *target=nil; for(NSNumber *n in self.targets) if(n.unsignedLongLongValue!=self.original){target=n;break;} if(!target)return;
    [self setBusyState:YES message:@"Testing one gesture round trip..."]; [self switchTo:target.unsignedLongLongValue completion:^(BOOL ok,double ms){ [self log:@"gestureOutbound" data:@{@"visibility":[self fixtureVisibility],@"backend":self.bridgedSwitch?@"bridged":@"gesture",@"target":target,@"actual":@(currentSpace(cid,(__bridge CFStringRef)self.display)),@"getterMatched":@(ok),@"observedMS":@(ms)}];
        later(0.3,^{[self switchTo:self.original completion:^(BOOL restored,double returnMS){BOOL getterRoundTrip=ok&&restored; [self log:@"gestureReturn" data:@{@"visibility":[self fixtureVisibility],@"backend":self.bridgedSwitch?@"bridged":@"gesture",@"target":@(self.original),@"getterMatched":@(restored),@"observedMS":@(returnMS)}]; CGWarpMouseCursorPosition(self.pointer); [self setBusyState:NO message:getterRoundTrip ? @"Getter round trip observed. Visual result NOT verified." : @"Getter round trip failed."]; }];}); }];
}
- (void)hold:(id)sender {(void)sender;if(self.busy)return;self.bridgedSwitch=YES;[self setBusyState:YES message:@"Holding last target Space..."];uint64_t target=self.targets.lastObject.unsignedLongLongValue;[self switchTo:target completion:^(BOOL ok,double ms){[self log:@"holdSpace" data:@{@"target":@(target),@"getterMatched":@(ok),@"observedMS":@(ms),@"visibility":[self fixtureVisibility],@"structure":[self structure]}];[self setBusyState:NO message:ok?@"Getter matches target; visual result NOT verified. Restore before quit.":@"Hold failed. Check original Space."]; }];}
- (void)restore:(id)sender {(void)sender;if(self.busy)return;self.bridgedSwitch=YES;[self setBusyState:YES message:@"Restoring original Space..."];[self switchTo:self.original completion:^(BOOL ok,double ms){[self log:@"restoreSpace" data:@{@"target":@(self.original),@"getterMatched":@(ok),@"observedMS":@(ms),@"visibility":[self fixtureVisibility]}];CGWarpMouseCursorPosition(self.pointer);[self setBusyState:NO message:ok?@"Original Space getter restored; inspect actual scene.":@"Restore failed; use system navigation."]; }];}
- (void)fullscreen:(id)sender { (void)sender; if(self.busy)return; [self setBusyState:YES message:@"Testing owned fullscreen lifecycle..."]; NSWindow *w=self.fixtures[0]; NSArray *before=[self structure]; [w makeKeyAndOrderFront:nil]; [w toggleFullScreen:nil]; later(2,^{ [self log:@"fullscreenEntered" data:@{@"before":before,@"after":[self structure],@"members":members(w),@"fullScreen":@((w.styleMask&NSWindowStyleMaskFullScreen)!=0)}];if(w.styleMask&NSWindowStyleMaskFullScreen)[w toggleFullScreen:nil];later(2,^{[self log:@"fullscreenExited" data:@{@"structure":[self structure],@"members":members(w),@"fullScreen":@((w.styleMask&NSWindowStyleMaskFullScreen)!=0)}];[self.panel makeKeyAndOrderFront:nil];[self setBusyState:NO message:@"Fullscreen lifecycle recorded."];}); }); }

- (void)foreignLegacy:(id)sender {useBridge=NO;[self foreignMove:sender];}
- (void)foreignBridge:(id)sender {if(!bridgePerform){self.status.stringValue=@"Bridged operation unavailable.";return;}useBridge=YES;[self foreignMove:sender];}
- (void)foreignMove:(id)sender {
    (void)sender; if(self.busy||(!useBridge&&!legacyMove)||(useBridge&&!bridgePerform))return;
    NSString *fixturePath=[NSProcessInfo.processInfo.environment[@"GRID_PROBE_OUTPUT"] stringByAppendingPathComponent:@"foreign-window.json"];
    NSData *data=fixturePath ? [NSData dataWithContentsOfFile:fixturePath] : nil;
    NSDictionary *fixture=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]:nil;
    pid_t pid=[fixture[@"pid"] intValue]; NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    if(![app.bundleIdentifier isEqual:@"com.switchly.research.ForeignFixture"]||[fixture[@"windowIDs"] count]!=2){self.status.stringValue=@"Foreign fixture identity check failed.";return;}
    NSArray *ids=fixture[@"windowIDs"]; NSMutableArray *before=[NSMutableArray array];
    NSArray *cg=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID));
    for(NSNumber *wid in ids){BOOL owns=NO;for(NSDictionary *w in cg)if([w[(__bridge NSString *)kCGWindowNumber] isEqual:wid]&&[w[(__bridge NSString *)kCGWindowOwnerPID] intValue]==pid)owns=YES;
        NSArray *m=CFBridgingRelease(windowSpaces(cid,7,(__bridge CFArrayRef)@[wid]));if(!owns||m.count!=1){self.status.stringValue=@"Foreign window ownership/membership unknown. Aborted.";return;}[before addObject:m];}
    NSNumber *target=nil;for(NSDictionary *d in snapshot()){BOOL source=NO;for(NSDictionary *v in d[@"Spaces"])if([before[0] containsObject:v[@"id64"]])source=YES;if(source)for(NSDictionary *v in d[@"Spaces"])if([v[@"type"] intValue]==0&&![before[0] containsObject:v[@"id64"]]){target=v[@"id64"];break;}}if(!target)return;
    [self setBusyState:YES message:@"Testing cross-process owned-fixture move..."];moveWindows(cid,(__bridge CFArrayRef)@[ids[0]],target.unsignedLongLongValue);
    later(0.8,^{NSArray *a=CFBridgingRelease(windowSpaces(cid,7,(__bridge CFArrayRef)@[ids[0]]));NSArray *other=CFBridgingRelease(windowSpaces(cid,7,(__bridge CFArrayRef)@[ids[1]]));
        [self log:@"foreignSingleMove" data:@{@"backend":useBridge?@"bridged":@"legacy",@"before":before,@"target":target,@"firstAfter":a?:@[],@"secondAfter":other?:@[],@"firstReached":@([a containsObject:target]),@"otherUnchanged":@([other isEqual:before[1]])}];
        for(NSUInteger i=0;i<ids.count;i++)moveWindows(cid,(__bridge CFArrayRef)@[ids[i]],[before[i][0] unsignedLongLongValue]);
        later(0.8,^{[self log:@"foreignSingleRestore" data:@{@"backend":useBridge?@"bridged":@"legacy",@"first":CFBridgingRelease(windowSpaces(cid,7,(__bridge CFArrayRef)@[ids[0]]))?:@[],@"second":CFBridgingRelease(windowSpaces(cid,7,(__bridge CFArrayRef)@[ids[1]]))?:@[]}];
            moveWindows(cid,(__bridge CFArrayRef)ids,target.unsignedLongLongValue);
            later(0.8,^{[self log:@"foreignBatchMove" data:@{@"backend":useBridge?@"bridged":@"legacy",@"target":target,@"first":CFBridgingRelease(windowSpaces(cid,7,(__bridge CFArrayRef)@[ids[0]]))?:@[],@"second":CFBridgingRelease(windowSpaces(cid,7,(__bridge CFArrayRef)@[ids[1]]))?:@[]}];
                for(NSUInteger i=0;i<ids.count;i++)moveWindows(cid,(__bridge CFArrayRef)@[ids[i]],[before[i][0] unsignedLongLongValue]);
                later(0.8,^{[self log:@"foreignBatchRestore" data:@{@"backend":useBridge?@"bridged":@"legacy",@"first":CFBridgingRelease(windowSpaces(cid,7,(__bridge CFArrayRef)@[ids[0]]))?:@[],@"second":CFBridgingRelease(windowSpaces(cid,7,(__bridge CFArrayRef)@[ids[1]]))?:@[]}];[self setBusyState:NO message:@"Cross-process single/batch movement recorded."];});
            });
        });
    });
}
- (void)systemShortcut:(id)sender {
    (void)sender;if(self.busy)return;[self setBusyState:YES message:@"Testing existing Control-Right shortcut (no settings changes)..."];CGWarpMouseCursorPosition(self.center);
    uint64_t before=currentSpace(cid,(__bridge CFStringRef)self.display);
    CGEventRef down=CGEventCreateKeyboardEvent(NULL,124,true),up=CGEventCreateKeyboardEvent(NULL,124,false);CGEventSetFlags(down,kCGEventFlagMaskControl);CGEventSetFlags(up,kCGEventFlagMaskControl);CGEventPost(kCGHIDEventTap,down);CGEventPost(kCGHIDEventTap,up);CFRelease(down);CFRelease(up);
    later(1.2,^{uint64_t after=currentSpace(cid,(__bridge CFStringRef)self.display);[self log:@"publicShortcut" data:@{@"before":@(before),@"after":@(after),@"changed":@(before!=after)}];
        if(after!=before){CGEventRef d=CGEventCreateKeyboardEvent(NULL,123,true),u=CGEventCreateKeyboardEvent(NULL,123,false);CGEventSetFlags(d,kCGEventFlagMaskControl);CGEventSetFlags(u,kCGEventFlagMaskControl);CGEventPost(kCGHIDEventTap,d);CGEventPost(kCGHIDEventTap,u);CFRelease(d);CFRelease(u);}
        later(1.2,^{[self log:@"publicShortcutRestore" data:@{@"expected":@(before),@"actual":@(currentSpace(cid,(__bridge CFStringRef)self.display))}];CGWarpMouseCursorPosition(self.pointer);[self setBusyState:NO message:@"System shortcut result recorded."];});
    });
}

- (void)quit:(id)sender { (void)sender; if(self.busy)return;if(currentSpace(cid,(__bridge CFStringRef)self.display)!=self.original){self.status.stringValue=@"Restore original Space before quitting.";return;}[self log:@"exit" data:@{@"structure":[self structure]}]; for(NSWindow *w in self.fixtures)[w close];CGWarpMouseCursorPosition(self.pointer);[self.previousApp activateWithOptions:NSApplicationActivateIgnoringOtherApps];[NSApp terminate:nil]; }
@end
int main(void) { @autoreleasepool { NSApplication *app=NSApplication.sharedApplication;[app setActivationPolicy:NSApplicationActivationPolicyRegular];Probe *delegate=[Probe new];app.delegate=delegate;[app run]; } return 0; }
