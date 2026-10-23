// Disposable fixture process; no user documents are opened or saved.
#import <AppKit/AppKit.h>
#import <unistd.h>
@interface Fixture : NSObject <NSApplicationDelegate>
@property NSMutableArray *windows;
@end
@implementation Fixture
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    (void)note; self.windows=[NSMutableArray array];
    for(int i=0;i<2;i++){NSWindow *w=[[NSWindow alloc] initWithContentRect:NSMakeRect(150+i*40,150+i*40,400,150) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];w.title=[NSString stringWithFormat:@"Foreign Fixture %d",i+1];w.releasedWhenClosed=NO;[w.contentView addSubview:[NSTextField labelWithString:@"Disposable test fixture. No user content."]];[w makeKeyAndOrderFront:nil];[self.windows addObject:w];}
    NSMenu *menu=[NSMenu new];NSMenuItem *item=[NSMenuItem new];[menu addItem:item];NSMenu *sub=[NSMenu new];[sub addItemWithTitle:@"Quit Foreign Fixture" action:@selector(terminate:) keyEquivalent:@"q"];item.submenu=sub;NSApp.mainMenu=menu;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{NSMutableArray *ids=[NSMutableArray array];for(NSWindow *w in self.windows)[ids addObject:@(w.windowNumber)];NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"pid":@(getpid()),@"windowIDs":ids,@"bundle":NSBundle.mainBundle.bundleIdentifier} options:0 error:NULL];NSString *path=[NSProcessInfo.processInfo.environment[@"GRID_PROBE_OUTPUT"] stringByAppendingPathComponent:@"foreign-window.json"];if(path)[data writeToFile:path atomically:YES];});
}
@end
int main(void){@autoreleasepool{NSApplication *app=NSApplication.sharedApplication;[app setActivationPolicy:NSApplicationActivationPolicyRegular];Fixture *delegate=[Fixture new];app.delegate=delegate;[app run];}return 0;}
