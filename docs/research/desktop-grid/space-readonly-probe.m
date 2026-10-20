// Read-only feasibility probe. No event posting, permission requests or window operations.
#import <Foundation/Foundation.h>
#import <ApplicationServices/ApplicationServices.h>
#import <dlfcn.h>
#import <time.h>
static double now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1000.0 + t.tv_nsec / 1e6; }
int main(void) { @autoreleasepool {
    void *handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL);
    if (!handle) { fprintf(stderr,"SkyLight unavailable\n"); return 2; }
    int (*connection)(void) = dlsym(handle,"SLSMainConnectionID");
    CFArrayRef (*copySpaces)(int) = dlsym(handle,"SLSCopyManagedDisplaySpaces");
    uint64_t (*currentSpace)(int, CFStringRef) = dlsym(handle,"SLSManagedDisplayGetCurrentSpace");
    CFArrayRef (*windowSpaces)(int,int,CFArrayRef) = dlsym(handle,"SLSCopySpacesForWindows");
    if (!connection || !copySpaces || !currentSpace || !windowSpaces) { fprintf(stderr,"Required read symbol unavailable\n"); return 3; }
    int cid = connection();
    NSArray *snapshot = CFBridgingRelease(copySpaces(cid));
    if (![snapshot isKindOfClass:NSArray.class] || snapshot.count == 0) { fprintf(stderr,"No display snapshot\n"); return 4; }
    NSMutableArray *displays = [NSMutableArray array];
    NSMutableSet *knownIDs = [NSMutableSet set];
    for (NSDictionary *display in snapshot) {
        if (![display isKindOfClass:NSDictionary.class]) continue;
        NSString *displayID = display[@"Display Identifier"];
        uint64_t current = [displayID isKindOfClass:NSString.class] ? currentSpace(cid,(__bridge CFStringRef)displayID) : 0;
        NSMutableArray *spaces = [NSMutableArray array];
        BOOL foundCurrent = NO;
        for (NSDictionary *space in display[@"Spaces"]) {
            NSNumber *sid = space[@"id64"];
            if (sid) [knownIDs addObject:sid];
            foundCurrent |= sid.unsignedLongLongValue == current;
            [spaces addObject:@{@"id":sid ?: @0,@"type":space[@"type"] ?: @(-1),@"uuidPresent":@([space[@"uuid"] isKindOfClass:NSString.class])}];
        }
        [displays addObject:@{@"spaces":spaces,@"currentID":@(current),@"currentInList":@(foundCurrent)}];
    }
    NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll | kCGWindowListExcludeDesktopElements,kCGNullWindowID));
    NSUInteger queried=0, mapped=0, multi=0, outsideAllDisplaysCurrentSpaces=0, unknown=0, nullResults=0;
    NSMutableSet *activeIDs = [NSMutableSet set];
    for (NSDictionary *d in displays) [activeIDs addObject:d[@"currentID"]];
    double queryStart = now_ms();
    for (NSDictionary *w in windows) {
        if ([w[(__bridge NSString *)kCGWindowLayer] intValue] != 0) continue;
        NSNumber *wid = w[(__bridge NSString *)kCGWindowNumber];
        if (!wid) continue;
        queried++;
        NSArray *membership = CFBridgingRelease(windowSpaces(cid,7,(__bridge CFArrayRef)@[wid]));
        if (!membership) { nullResults++; continue; }
        if (membership.count) mapped++;
        if (membership.count > 1) multi++;
        BOOL hasCurrent=NO;
        for (NSNumber *sid in membership) { if (![knownIDs containsObject:sid]) unknown++; if ([activeIDs containsObject:sid]) hasCurrent=YES; }
        if (membership.count && !hasCurrent) outsideAllDisplaysCurrentSpaces++;
    }
    double queryMS = now_ms() - queryStart;
    NSMutableArray *times = [NSMutableArray array];
    NSUInteger consistent=0, valid=0;
    for (int i=0;i<100;i++) { double start=now_ms(); NSArray *s=CFBridgingRelease(copySpaces(cid)); [times addObject:@(now_ms()-start)]; if (s) valid++; if ([s isEqual:snapshot]) consistent++; }
    [times sortUsingSelector:@selector(compare:)];
    NSMutableDictionary *symbols=[NSMutableDictionary dictionary];
    for (NSString *name in @[@"SLSMoveWindowsToManagedSpace"]) symbols[name]=@(dlsym(handle,name.UTF8String)!=NULL);
    symbols[@"bridgedMoveClassPresent"] = @(NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation") != Nil);
    NSDictionary *report=@{@"os":NSProcessInfo.processInfo.operatingSystemVersionString,@"axTrusted":@(AXIsProcessTrusted()),@"screenCapturePreflight":@(CGPreflightScreenCaptureAccess()),@"displays":displays,@"windowQuery":@{@"queriedLayerZero":@(queried),@"nonemptyMembership":@(mapped),@"multiSpace":@(multi),@"noMembershipInAnyDisplaysCurrentSpace":@(outsideAllDisplaysCurrentSpaces),@"unknownMembershipIDs":@(unknown),@"nullResults":@(nullResults),@"totalMS":@(queryMS)},@"enumeration":@{@"samples":@100,@"valid":@(valid),@"equalToInitial":@(consistent),@"p50MS":times[49],@"p95MS":times[94],@"maxMS":times[99]},@"writeSymbolsExistOnlyNotInvoked":symbols};
    NSData *data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:NULL];
    fwrite(data.bytes,1,data.length,stdout); putchar('\n');
    return 0;
} }
