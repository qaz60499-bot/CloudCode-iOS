// IPA Total V122: read-only access-context check for this process only.
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <errno.h>
#include <stdint.h>
#include <sys/types.h>
#include <unistd.h>

typedef int (*self_csops_fn)(pid_t, uint32_t, void *, size_t);
typedef CFTypeRef (*self_task_create_fn)(CFAllocatorRef);
typedef CFTypeRef (*self_task_copy_entitlement_fn)(CFTypeRef, CFStringRef, CFErrorRef *);

static NSDictionary *UnknownValue(NSString *status) {
    return @{@"status": status, @"value": [NSNull null]};
}

static NSDictionary *ReadOwnEntitlement(CFTypeRef task,
                                        self_task_copy_entitlement_fn copyValue,
                                        NSString *name) {
    if (task == NULL || copyValue == NULL) {
        return UnknownValue(task == NULL ? @"UNKNOWN_SELF_TASK" : @"UNKNOWN_SYMBOL_MISSING");
    }
    CFErrorRef error = NULL;
    CFTypeRef value = copyValue(task, (__bridge CFStringRef)name, &error);
    if (error != NULL) CFRelease(error);
    if (value == NULL) return UnknownValue(@"UNKNOWN_MISSING_OR_DENIED");
    if (CFGetTypeID(value) != CFBooleanGetTypeID()) {
        CFRelease(value);
        return UnknownValue(@"UNKNOWN_NON_BOOLEAN");
    }
    BOOL answer = CFBooleanGetValue((CFBooleanRef)value);
    CFRelease(value);
    return @{@"status": @"KNOWN", @"value": @(answer)};
}

static NSDictionary *CollectSelfCheck(void) {
    NSMutableDictionary *result = [@{
        @"schema": @"ios166-v122-access-selfcheck/1",
        @"scope": @"SELF_PROCESS_ONLY_NOT_OFFICIAL_CHATGPT",
        @"uid": @(getuid()),
        @"euid": @(geteuid()),
        @"gid": @(getgid()),
        @"egid": @(getegid()),
        @"pid": @(getpid()),
        @"os_version": UIDevice.currentDevice.systemVersion ?: @"UNKNOWN",
        @"bundle_id": NSBundle.mainBundle.bundleIdentifier ?: @"UNKNOWN"
    } mutableCopy];

    self_csops_fn csops = (self_csops_fn)dlsym(RTLD_DEFAULT, "csops");
    if (csops == NULL) {
        result[@"csops_available"] = @NO;
        result[@"csops_status_result"] = @"UNAVAILABLE";
        result[@"csops_errno"] = [NSNull null];
        result[@"csops_flags"] = [NSNull null];
    } else {
        uint32_t flags = 0;
        errno = 0;
        int callResult = csops(getpid(), 0, &flags, sizeof(flags));
        int callErrno = errno;
        result[@"csops_available"] = @YES;
        result[@"csops_status_result"] = @(callResult);
        result[@"csops_errno"] = @(callErrno);
        result[@"csops_flags"] = callResult == 0 ? @(flags) : [NSNull null];
    }

    self_task_create_fn createTask =
        (self_task_create_fn)dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
    self_task_copy_entitlement_fn copyEntitlement =
        (self_task_copy_entitlement_fn)dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
    CFTypeRef task = createTask != NULL ? createTask(kCFAllocatorDefault) : NULL;
    if (createTask == NULL) {
        result[@"platform_application"] = UnknownValue(@"UNKNOWN_SYMBOL_MISSING");
        result[@"no_sandbox"] = UnknownValue(@"UNKNOWN_SYMBOL_MISSING");
    } else {
        result[@"platform_application"] =
            ReadOwnEntitlement(task, copyEntitlement, @"platform-application");
        result[@"no_sandbox"] =
            ReadOwnEntitlement(task, copyEntitlement, @"com.apple.private.security.no-sandbox");
    }
    if (task != NULL) CFRelease(task);
    return result;
}

static NSString *JSONText(NSDictionary *object) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:&error];
    if (data == nil) return @"{\"status\":\"JSON_SERIALIZATION_FAILED\"}";
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
        ?: @"{\"status\":\"JSON_ENCODING_FAILED\"}";
}

@interface V122AppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@interface V122ViewController : UIViewController
@property(nonatomic, strong) UITextView *outputView;
@property(nonatomic, strong) UILabel *saveStatus;
@end

@implementation V122AppDelegate
- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)application;
    (void)launchOptions;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [V122ViewController new];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

@implementation V122ViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.055 green:0.075 blue:0.11 alpha:1.0];

    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"IPA Access 16.6";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont systemFontOfSize:27 weight:UIFontWeightBold];
    [self.view addSubview:title];

    UILabel *scope = [UILabel new];
    scope.translatesAutoresizingMaskIntoConstraints = NO;
    scope.numberOfLines = 0;
    scope.text = @"Self process only. Not official ChatGPT. Read-only identity and two named entitlement checks; no other app or entitlement data is accessed.";
    scope.textColor = [UIColor colorWithWhite:0.87 alpha:1.0];
    scope.font = [UIFont systemFontOfSize:14];
    [self.view addSubview:scope];

    self.saveStatus = [UILabel new];
    self.saveStatus.translatesAutoresizingMaskIntoConstraints = NO;
    self.saveStatus.numberOfLines = 0;
    self.saveStatus.textColor = [UIColor colorWithRed:0.63 green:0.86 blue:1.0 alpha:1.0];
    self.saveStatus.font = [UIFont systemFontOfSize:13];
    [self.view addSubview:self.saveStatus];

    self.outputView = [UITextView new];
    self.outputView.translatesAutoresizingMaskIntoConstraints = NO;
    self.outputView.editable = NO;
    self.outputView.selectable = YES;
    self.outputView.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];
    self.outputView.textColor = [UIColor colorWithWhite:0.91 alpha:1.0];
    self.outputView.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    [self.view addSubview:self.outputView];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [title.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:18],
        [title.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-18],
        [title.topAnchor constraintEqualToAnchor:safe.topAnchor constant:18],
        [scope.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [scope.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
        [scope.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:12],
        [self.saveStatus.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [self.saveStatus.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
        [self.saveStatus.topAnchor constraintEqualToAnchor:scope.bottomAnchor constant:10],
        [self.outputView.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [self.outputView.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
        [self.outputView.topAnchor constraintEqualToAnchor:self.saveStatus.bottomAnchor constant:10],
        [self.outputView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-14],
    ]];

    NSDictionary *check = CollectSelfCheck();
    NSString *json = JSONText(check);
    NSURL *caches = [[[NSFileManager defaultManager]
        URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] firstObject];
    NSURL *outputURL = [caches URLByAppendingPathComponent:@"access-selfcheck.json"
                                                isDirectory:NO];
    NSString *home = [NSHomeDirectory() stringByResolvingSymlinksInPath];
    NSString *cachePath = [caches.path stringByResolvingSymlinksInPath];
    BOOL ownContainer = [home hasPrefix:@"/private/var/mobile/Containers/Data/Application/"]
        && [cachePath hasPrefix:[home stringByAppendingString:@"/Library/Caches"]];
    NSError *error = nil;
    BOOL saved = ownContainer && [json writeToURL:outputURL atomically:YES
                         encoding:NSUTF8StringEncoding error:&error];
    self.saveStatus.text = saved
        ? @"Self-check JSON saved in this app's Caches."
        : @"Self-check collected; saving to this app's Caches failed.";
    self.outputView.text = json;
}
@end

int main(int argc, char *argv[]) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([V122AppDelegate class]));
    }
}
