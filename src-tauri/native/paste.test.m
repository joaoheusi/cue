#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>

// Run the real adapter against a controlled accessibility server. No UI events
// leave this process, and these tests require no Accessibility permission.
static AXUIElementRef testApplication, testWindow, testField;
static AXUIElementRef focusedWindow, focusedField;
static BOOL testTrusted = YES, testPosting = YES, testSecure = NO;
static BOOL testWindowExists = YES, testFieldExists = YES;
static CGEventFlags testModifiers = 0;
static NSUInteger postedEvents = 0;

@interface TestPasteboard : NSObject
@property(nonatomic) NSInteger changeCount;
+ (instancetype)generalPasteboard;
- (void)clearContents;
- (BOOL)setString:(NSString *)value forType:(NSPasteboardType)type;
@end
@implementation TestPasteboard
+ (instancetype)generalPasteboard {
    static TestPasteboard *board;
    if (!board) { board = [TestPasteboard new]; board.changeCount = 42; }
    return board;
}
- (void)clearContents { self.changeCount++; }
- (BOOL)setString:(NSString *)value forType:(NSPasteboardType)type { (void)value; (void)type; return YES; }
@end

@interface TestApplication : NSObject
@property(nonatomic) pid_t processIdentifier;
@property(nonatomic, getter=isTerminated) BOOL terminated;
@property(nonatomic, copy) NSString *bundleIdentifier;
@end
@interface TestWorkspace : NSObject
@property(nonatomic, strong) NSRunningApplication *frontmostApplication;
@property(nonatomic, readonly) NSNotificationCenter *notificationCenter;
+ (instancetype)sharedWorkspace;
- (BOOL)openURL:(NSURL *)url;
@end
@implementation TestWorkspace
+ (instancetype)sharedWorkspace {
    static TestWorkspace *workspace;
    if (!workspace) workspace = [TestWorkspace new];
    return workspace;
}
- (NSNotificationCenter *)notificationCenter { return NSNotificationCenter.defaultCenter; }
- (BOOL)openURL:(NSURL *)url { (void)url; return NO; }
@end
@implementation TestApplication
- (BOOL)activateWithOptions:(NSApplicationActivationOptions)options {
    (void)options;
    TestWorkspace.sharedWorkspace.frontmostApplication = (NSRunningApplication *)self;
    focusedWindow = testWindow;
    focusedField = testField;
    return YES;
}
@end

static AXError testCopyAttribute(AXUIElementRef element, CFStringRef name, CFTypeRef *value) {
    CFTypeRef result = NULL;
    if (CFEqual(element, testApplication)) {
        if (CFEqual(name, kAXFocusedWindowAttribute)) result = focusedWindow;
        if (CFEqual(name, kAXFocusedUIElementAttribute)) result = focusedField;
        if (CFEqual(name, kAXWindowsAttribute)) {
            *value = CFArrayCreate(NULL, (const void **)&testWindow, testWindowExists ? 1 : 0, &kCFTypeArrayCallBacks);
            return kAXErrorSuccess;
        }
    } else {
        if (CFEqual(name, kAXSubroleAttribute) && testSecure) result = kAXSecureTextFieldSubrole;
        if (CFEqual(name, kAXRoleAttribute) && testFieldExists) result = CFEqual(element, testWindow) ? kAXWindowRole : kAXTextAreaRole;
        if (CFEqual(name, kAXWindowAttribute)) result = testWindow;
    }
    *value = result ? CFRetain(result) : NULL;
    return result ? kAXErrorSuccess : kAXErrorNoValue;
}
static Boolean testAXTrusted(void) { return testTrusted; }
static bool testPostAccess(void) { return testPosting; }
static Boolean testSecureInput(void) { return false; }
static CGEventFlags testFlags(CGEventSourceStateID state) { (void)state; return testModifiers; }
static void testPost(pid_t pid, CGEventRef event) { (void)pid; (void)event; postedEvents++; }
static AXError testRaise(AXUIElementRef element, CFStringRef action) { (void)element; (void)action; return kAXErrorSuccess; }

#define NSWorkspace TestWorkspace
#define NSPasteboard TestPasteboard
#define AXUIElementCopyAttributeValue testCopyAttribute
#define AXIsProcessTrusted testAXTrusted
#define CGPreflightPostEventAccess testPostAccess
#define IsSecureEventInputEnabled testSecureInput
#define CGEventSourceFlagsState testFlags
#define CGEventPostToPid testPost
#define AXUIElementPerformAction testRaise
#include "paste.m"

static void expectStatus(NSString *label, int actual, int expected) {
    if (actual != expected) {
        fprintf(stderr, "%s: expected %d, got %d\n", label.UTF8String, expected, actual);
        exit(1);
    }
    printf("PASS %s\n", label.UTF8String);
}
int main(void) {
    @autoreleasepool {
        TestApplication *external = [TestApplication new];
        external.processIdentifier = NSProcessInfo.processInfo.processIdentifier + 1;
        external.bundleIdentifier = @"app.cue.test-editor";
        TestApplication *cue = [TestApplication new];
        cue.processIdentifier = NSProcessInfo.processInfo.processIdentifier;
        TestWorkspace.sharedWorkspace.frontmostApplication = (NSRunningApplication *)external;
        testApplication = AXUIElementCreateApplication(external.processIdentifier);
        testWindow = AXUIElementCreateApplication(external.processIdentifier + 1);
        testField = AXUIElementCreateApplication(external.processIdentifier + 2);
        focusedWindow = testWindow;
        focusedField = testField;
        int status = 0;
        uintptr_t target = cue_capture_target(&status);
        expectStatus(@"capture focused editor", status, 0);
        if (!target) return 1;
        expectStatus(@"unchanged focused target", cue_check_target(target), 0);
        testTrusted = NO;
        expectStatus(@"permission revoked", cue_check_target(target), 1);
        testTrusted = YES;
        testPosting = NO;
        expectStatus(@"event permission revoked", cue_check_target(target), 11);
        testPosting = YES;
        testSecure = YES;
        expectStatus(@"protected field", cue_check_target(target), 4);
        testSecure = NO;
        focusedField = testWindow;
        expectStatus(@"different focused field", cue_check_target(target), 3);
        focusedField = testField;
        TestWorkspace.sharedWorkspace.frontmostApplication = (NSRunningApplication *)cue;
        focusedField = NULL;
        expectStatus(@"palette owns focus; editor has no focused field", cue_check_target(target), 0);
        focusedWindow = NULL;
        expectStatus(@"inactive app reports no focused window or field", cue_check_target(target), 0);
        focusedWindow = testField;
        focusedField = testWindow;
        expectStatus(@"inactive app reports temporary focus", cue_check_target(target), 0);
        testWindowExists = NO;
        expectStatus(@"captured window closed while palette is open", cue_check_target(target), 3);
        testWindowExists = YES;
        testFieldExists = NO;
        expectStatus(@"captured field removed while palette is open", cue_check_target(target), 3);
        testFieldExists = YES;
        testSecure = YES;
        expectStatus(@"retained field became protected", cue_check_target(target), 4);
        testSecure = NO;
        expectStatus(@"no paste before activation", cue_send_paste(target, 42), 9);
        expectStatus(@"activate retained target despite inactive focus", cue_activate_target(target), 0);
        expectStatus(@"focused target after activation", cue_check_target(target), 0);
        focusedField = NULL;
        expectStatus(@"wait for accessibility focus after activation", cue_send_paste(target, 42), 9);
        expectStatus(@"activation tolerates focus pending after Cue hides", cue_activate_target(target), 0);
        focusedWindow = testField;
        focusedField = NULL;
        expectStatus(@"changed window blocks even with missing field", cue_send_paste(target, 42), 3);
        focusedWindow = testWindow;
        focusedField = testWindow;
        expectStatus(@"different field after activation blocks paste", cue_send_paste(target, 42), 3);
        focusedField = testField;
        expectStatus(@"clipboard changed", cue_send_paste(target, 41), 6);
        testModifiers = kCGEventFlagMaskCommand;
        expectStatus(@"wait for released modifiers", cue_send_paste(target, 42), 7);
        testModifiers = 0;
        expectStatus(@"no events posted during failed checks", (int)postedEvents, 0);
        expectStatus(@"paste into exact restored target", cue_send_paste(target, 42), 0);
        expectStatus(@"one paste chord posted", (int)postedEvents, 2);
        TestApplication *other = [TestApplication new];
        other.processIdentifier = external.processIdentifier + 10;
        TestWorkspace.sharedWorkspace.frontmostApplication = (NSRunningApplication *)other;
        expectStatus(@"another app took focus", cue_send_paste(target, 42), 3);
        TestWorkspace.sharedWorkspace.frontmostApplication = (NSRunningApplication *)external;
        external.terminated = YES;
        expectStatus(@"target process exited", cue_check_target(target), 3);
        external.terminated = NO;
        session++;
        expectStatus(@"session changed", cue_check_target(target), 3);
        expectStatus(@"failed checks never posted another chord", (int)postedEvents, 2);
        cue_release_target(target);
        CFRelease(testApplication);
        CFRelease(testWindow);
        CFRelease(testField);
    }
    return 0;
}
