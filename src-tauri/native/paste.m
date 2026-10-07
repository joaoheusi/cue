#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>

// All entry points except release run on AppKit's main thread.
@interface CuePasteTarget : NSObject
@property(nonatomic, strong) NSRunningApplication *app;
@property(nonatomic) AXUIElementRef application;
@property(nonatomic) AXUIElementRef window;
@property(nonatomic) AXUIElementRef field;
@property(nonatomic) NSUInteger session;
@end
@implementation CuePasteTarget
- (void)dealloc {
    if (_application) CFRelease(_application);
    if (_window) CFRelease(_window);
    if (_field) CFRelease(_field);
}
@end

static NSUInteger session = 0;
static void observeSession(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSNotificationCenter *center = NSWorkspace.sharedWorkspace.notificationCenter;
        for (NSString *name in @[NSWorkspaceWillSleepNotification, NSWorkspaceSessionDidResignActiveNotification]) {
            [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { (void)note; session++; }];
        }
        [NSDistributedNotificationCenter.defaultCenter addObserverForName:@"com.apple.screenIsLocked" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { (void)note; session++; }];
    });
}
static CFTypeRef attribute(AXUIElementRef element, CFStringRef name) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, name, &value) != kAXErrorSuccess) return NULL;
    return value;
}
static AXUIElementRef elementAttribute(AXUIElementRef element, CFStringRef name) {
    CFTypeRef value = attribute(element, name);
    if (value && CFGetTypeID(value) != AXUIElementGetTypeID()) { CFRelease(value); return NULL; }
    return (AXUIElementRef)value;
}
static BOOL secure(AXUIElementRef field) {
    CFTypeRef role = attribute(field, kAXSubroleAttribute);
    BOOL result = role && CFEqual(role, kAXSecureTextFieldSubrole);
    if (role) CFRelease(role);
    return result || IsSecureEventInputEnabled();
}
static BOOL terminal(NSRunningApplication *app) {
    NSString *bundle = app.bundleIdentifier.lowercaseString ?: @"";
    return [@[@"com.apple.terminal", @"com.googlecode.iterm2", @"dev.warp.warp-stable", @"com.mitchellh.ghostty", @"net.kovidgoyal.kitty", @"org.alacritty", @"org.wezfurlong.wezterm", @"co.zeit.hyper"] containsObject:bundle];
}
// Preserve both results so event-posting access cannot masquerade as an AX failure.
int cue_paste_permissions(void) {
    int permissions = AXIsProcessTrusted() ? 1 : 0;
    if (CGPreflightPostEventAccess()) permissions |= 2;
    return permissions;
}
static int permissionStatus(void) {
    int permissions = cue_paste_permissions();
    if (!(permissions & 1)) return 1;
    return (permissions & 2) ? 0 : 11;
}
void cue_request_paste_permission(void) {
    NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
}
uintptr_t cue_capture_target(int *status) {
    observeSession();
    *status = 0;
    *status = permissionStatus();
    if (*status) return 0;
    NSRunningApplication *app = NSWorkspace.sharedWorkspace.frontmostApplication;
    if (!app || app.processIdentifier == NSProcessInfo.processInfo.processIdentifier) { *status = 2; return 0; }
    if (terminal(app)) { *status = 5; return 0; }
    CuePasteTarget *target = [CuePasteTarget new];
    target.app = app;
    target.session = session;
    target.application = AXUIElementCreateApplication(app.processIdentifier);
    AXUIElementSetMessagingTimeout(target.application, 0.2);
    target.window = elementAttribute(target.application, kAXFocusedWindowAttribute);
    target.field = elementAttribute(target.application, kAXFocusedUIElementAttribute);
    if (!target.window || !target.field) { *status = 2; return 0; }
    if (secure(target.field)) { *status = 4; return 0; }
    return (uintptr_t)CFBridgingRetain(target);
}
void cue_release_target(uintptr_t handle) {
    if (handle) CFRelease((CFTypeRef)handle);
}
static int check(CuePasteTarget *target, BOOL foreground) {
    int permission = permissionStatus();
    if (permission) return permission;
    if (target.session != session || target.app.terminated) return 3;
    pid_t front = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    if (front != target.app.processIdentifier) {
        if (front != NSProcessInfo.processInfo.processIdentifier) return 3;
        if (foreground) return 9;
        // An inactive app may clear or replace its focused element when Cue
        // opens. Validate the retained target here; verify active focus only
        // after activation, immediately before sending the paste chord.
        CFTypeRef windows = attribute(target.application, kAXWindowsAttribute);
        BOOL windowExists = windows && CFGetTypeID(windows) == CFArrayGetTypeID()
            && CFArrayContainsValue(windows, CFRangeMake(0, CFArrayGetCount(windows)), target.window);
        CFTypeRef role = attribute(target.field, kAXRoleAttribute);
        BOOL fieldExists = role && CFGetTypeID(role) == CFStringGetTypeID();
        BOOL protected = secure(target.field);
        if (windows) CFRelease(windows);
        if (role) CFRelease(role);
        if (protected) return 4;
        return windowExists && fieldExists ? 0 : 3;
    }
    AXUIElementRef window = elementAttribute(target.application, kAXFocusedWindowAttribute);
    AXUIElementRef field = elementAttribute(target.application, kAXFocusedUIElementAttribute);
    BOOL same = window && field && CFEqual(window, target.window) && CFEqual(field, target.field);
    BOOL missing = !window || !field;
    BOOL changed = (window && !CFEqual(window, target.window)) || (field && !CFEqual(field, target.field));
    BOOL protected = field && secure(field);
    if (window) CFRelease(window);
    if (field) CFRelease(field);
    if (protected) return 4;
    if (same) return 0;
    // Activation can precede the app's accessibility focus update. Only an
    // absent focus is retryable; a different window or field is a hard stop.
    if (missing && !changed) return 9;
    return 3;
}
int cue_check_target(uintptr_t handle) { return check((__bridge CuePasteTarget *)(void *)handle, NO); }
int cue_activate_target(uintptr_t handle) {
    CuePasteTarget *target = (__bridge CuePasteTarget *)(void *)handle;
    int status = check(target, NO);
    // Hiding Cue may already have activated the target before AX focus updates.
    // Allow that pending transition; delivery still requires the exact field.
    if (status && status != 9) return status;
    if (![target.app activateWithOptions:0]) return 3;
    AXUIElementPerformAction(target.window, kAXRaiseAction);
    return 0;
}
long cue_clipboard_generation(void) { return NSPasteboard.generalPasteboard.changeCount; }
long cue_write_paste_text(const char *text, long expected) {
    NSPasteboard *board = NSPasteboard.generalPasteboard;
    if (expected >= 0 && board.changeCount != expected) return -2;
    NSString *value = [[NSString alloc] initWithUTF8String:text];
    if (!value) return -1;
    [board clearContents];
    if (![board setString:value forType:NSPasteboardTypeString]) return -1;
    return board.changeCount;
}
int cue_send_paste(uintptr_t handle, long generation) {
    CuePasteTarget *target = (__bridge CuePasteTarget *)(void *)handle;
    int status = check(target, YES);
    if (status) return status;
    if (NSPasteboard.generalPasteboard.changeCount != generation) return 6;
    CGEventFlags flags = CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
    if (flags & (kCGEventFlagMaskShift | kCGEventFlagMaskControl | kCGEventFlagMaskAlternate | kCGEventFlagMaskCommand)) return 7;
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStatePrivate);
    CGEventRef down = CGEventCreateKeyboardEvent(source, 9, true);
    CGEventRef up = CGEventCreateKeyboardEvent(source, 9, false);
    if (!source || !down || !up) {
        if (down) CFRelease(down);
        if (up) CFRelease(up);
        if (source) CFRelease(source);
        return 8;
    }
    CGEventSetFlags(down, kCGEventFlagMaskCommand);
    CGEventSetFlags(up, kCGEventFlagMaskCommand);
    // Route both events to the captured process. Never retry after this point.
    CGEventPostToPid(target.app.processIdentifier, down);
    CGEventPostToPid(target.app.processIdentifier, up);
    CFRelease(down);
    CFRelease(up);
    CFRelease(source);
    return 0;
}
