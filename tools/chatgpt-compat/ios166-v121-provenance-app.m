// IPA Total V121 provenance UI.
// Bundle identifier: cc.guess.ipatotal.provenance.ios166.
// The image, signature material, and manifest are supplied only by the local
// package assembler. CI builds without those resources and never receives them.
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int v121_diagnostic_main(int argc, char **argv);

static const NSUInteger kWrapperPrefixSize = 16384;
static const NSUInteger kOriginalImageSize = 551440;
static const char *kExpectedImageSHA256 =
    "9c6b55caa0180276b9175cc949ec3678222f287672a1c5fff3cbc57a79d7aeb0";
static NSString * const kJournalSchema = @"ios166-v121-provenance-attempt-journal/1";

@interface V121AppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@interface V121ViewController : UIViewController
@property(nonatomic, strong) UIScrollView *scrollView;
@property(nonatomic, strong) UIStackView *stackView;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UILabel *outputLabel;
@property(nonatomic, strong) UIButton *prepareButton;
@property(nonatomic, strong) UIButton *runButton;
@property(nonatomic, strong) NSURL *sessionURL;
@property(nonatomic, strong) NSURL *unsignedImageURL;
@property(nonatomic, strong) NSURL *signedImageURL;
@property(nonatomic, copy) NSString *sessionID;
@property(nonatomic, strong) dispatch_queue_t workerQueue;
@property(nonatomic) BOOL localResourcesPresent;
@property(nonatomic) BOOL prepared;
@property(nonatomic) BOOL operationRunning;
@property(nonatomic) BOOL replayLocked;
@end

@implementation V121AppDelegate
- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)application;
    (void)launchOptions;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [V121ViewController new];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

@implementation V121ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.055 green:0.075 blue:0.11 alpha:1.0];
    self.workerQueue = dispatch_queue_create("cc.guess.ipatotal.provenance.v121", DISPATCH_QUEUE_SERIAL);
    [self buildInterface];

    self.localResourcesPresent = [self bundledResourceURLForName:@"OriginalImage"
                                                        extension:@"raw"
                                                       directory:nil] != nil
        && [self bundledResourceURLForName:@"ChatGPT"
                                  extension:@"sinf"
                                 directory:@"EmbeddedLicense"] != nil
        && [self bundledResourceURLForName:@"Manifest"
                                  extension:@"plist"
                                 directory:@"EmbeddedLicense"] != nil;
    self.replayLocked = [self journalExistsOrIsInvalid];
    [self refreshControls];

    if (!self.localResourcesPresent) {
        self.statusLabel.text = @"NO_LOCAL_PAYLOAD: local image/license/manifest resources are absent. No files were written and no diagnostic was run.";
    } else if (self.replayLocked) {
        self.statusLabel.text = @"NO_REPLAY: a prior one-page attempt is recorded. No diagnostic was replayed.";
    } else {
        self.statusLabel.text = @"Ready. Tap Prepare / Inspect to validate the local payload and create isolated cache copies.";
    }
}

- (void)buildInterface {
    self.scrollView = [UIScrollView new];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.alwaysBounceVertical = YES;
    [self.view addSubview:self.scrollView];
    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [self.scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
    ]];

    self.stackView = [UIStackView new];
    self.stackView.translatesAutoresizingMaskIntoConstraints = NO;
    self.stackView.axis = UILayoutConstraintAxisVertical;
    self.stackView.spacing = 14;
    self.stackView.layoutMargins = UIEdgeInsetsMake(22, 18, 28, 18);
    self.stackView.layoutMarginsRelativeArrangement = YES;
    [self.scrollView addSubview:self.stackView];
    [NSLayoutConstraint activateConstraints:@[
        [self.stackView.leadingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor],
        [self.stackView.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor],
        [self.stackView.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor],
        [self.stackView.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor],
        [self.stackView.widthAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.widthAnchor],
    ]];

    UILabel *title = [UILabel new];
    title.text = @"IPA Integrity 16.6";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    [self.stackView addArrangedSubview:title];

    UILabel *scope = [UILabel new];
    scope.numberOfLines = 0;
    scope.textColor = [UIColor colorWithWhite:0.88 alpha:1.0];
    scope.font = [UIFont systemFontOfSize:15];
    scope.text = @"NOT official ChatGPT. This standalone provenance helper never launches or replaces the official app. Each page mode attempts one read-only device page; partial-span behavior is unknown, and failure does not disprove full-range mapping. Results do not prove decryption or compatibility.";
    [self.stackView addArrangedSubview:scope];

    UILabel *modeNote = [UILabel new];
    modeNote.numberOfLines = 0;
    modeNote.textColor = [UIColor colorWithWhite:0.72 alpha:1.0];
    modeNote.font = [UIFont systemFontOfSize:13];
    modeNote.text = @"“Unsigned” and “signed” name the signature-registration setting for the same byte-identical image copies. The signed mode calls F_ADDFILESIGS_RETURN before its single-page attempt.";
    [self.stackView addArrangedSubview:modeNote];

    self.statusLabel = [UILabel new];
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.textColor = [UIColor colorWithRed:0.63 green:0.86 blue:1.0 alpha:1.0];
    self.statusLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightMedium];
    self.statusLabel.text = @"Idle.";
    [self.stackView addArrangedSubview:self.statusLabel];

    self.prepareButton = [self makeButtonWithTitle:@"Prepare / Inspect"
                                            action:@selector(prepareAndInspectTapped:)];
    [self.stackView addArrangedSubview:self.prepareButton];
    self.runButton = [self makeButtonWithTitle:@"Run one-page tests"
                                        action:@selector(runOnePageTestsTapped:)];
    [self.stackView addArrangedSubview:self.runButton];

    UILabel *jsonHeading = [UILabel new];
    jsonHeading.text = @"Structured diagnostic output";
    jsonHeading.textColor = UIColor.whiteColor;
    jsonHeading.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [self.stackView addArrangedSubview:jsonHeading];

    self.outputLabel = [UILabel new];
    self.outputLabel.numberOfLines = 0;
    self.outputLabel.lineBreakMode = NSLineBreakByCharWrapping;
    self.outputLabel.textColor = [UIColor colorWithWhite:0.86 alpha:1.0];
    self.outputLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.outputLabel.text = @"No diagnostic has run.";
    [self.stackView addArrangedSubview:self.outputLabel];
}

- (UIButton *)makeButtonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.backgroundColor = [UIColor colorWithRed:0.10 green:0.40 blue:0.53 alpha:1.0];
    button.layer.cornerRadius = 10;
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [button.heightAnchor constraintEqualToConstant:48].active = YES;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (NSURL *)bundledResourceURLForName:(NSString *)name
                           extension:(NSString *)extension
                          directory:(NSString *)directory {
    NSString *path = [[NSBundle mainBundle] pathForResource:name
                                                     ofType:extension
                                                inDirectory:directory];
    return path.length ? [NSURL fileURLWithPath:path] : nil;
}

- (NSURL *)cacheRootURL {
    NSURL *caches = [[[NSFileManager defaultManager]
        URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] firstObject];
    return [caches URLByAppendingPathComponent:@"V121Provenance" isDirectory:YES];
}

- (NSURL *)journalURL {
    return [[self cacheRootURL] URLByAppendingPathComponent:@"attempt-journal.plist"
                                                 isDirectory:NO];
}

- (BOOL)journalExistsOrIsInvalid {
    NSURL *url = [self journalURL];
    if (![[NSFileManager defaultManager] fileExistsAtPath:url.path]) return NO;
    NSDictionary *journal = [NSDictionary dictionaryWithContentsOfURL:url];
    if (![journal isKindOfClass:[NSDictionary class]]
        || ![journal[@"schema"] isEqual:kJournalSchema]) {
        return YES;
    }
    NSDictionary *modes = journal[@"modes"];
    if (![modes isKindOfClass:[NSDictionary class]]) return YES;
    if (![journal[@"run_claimed"] isKindOfClass:[NSNumber class]]) return YES;
    NSString *unsignedState = modes[@"unsigned-page"];
    NSString *signedState = modes[@"signed-page"];
    if (unsignedState == nil || signedState == nil) return YES;
    return ![unsignedState isEqual:@"not_started"]
        || ![signedState isEqual:@"not_started"]
        || [journal[@"run_claimed"] boolValue];
}

- (void)refreshControls {
    BOOL canPrepare = self.localResourcesPresent
        && !self.replayLocked
        && !self.operationRunning
        && !self.prepared;
    self.prepareButton.enabled = canPrepare;
    self.prepareButton.alpha = canPrepare ? 1.0 : 0.5;

    BOOL canRun = self.prepared
        && !self.replayLocked
        && !self.operationRunning;
    self.runButton.enabled = canRun;
    self.runButton.alpha = canRun ? 1.0 : 0.5;
}

- (BOOL)loadBundledPayload:(NSData **)payloadData
               licenseData:(NSData **)licenseData
              manifestData:(NSData **)manifestData
                    reason:(NSString **)reason {
    NSURL *imageURL = [self bundledResourceURLForName:@"OriginalImage"
                                             extension:@"raw"
                                            directory:nil];
    NSURL *licenseURL = [self bundledResourceURLForName:@"ChatGPT"
                                               extension:@"sinf"
                                              directory:@"EmbeddedLicense"];
    NSURL *manifestURL = [self bundledResourceURLForName:@"Manifest"
                                                extension:@"plist"
                                               directory:@"EmbeddedLicense"];
    if (imageURL == nil || licenseURL == nil || manifestURL == nil) {
        if (reason) *reason = @"NO_LOCAL_PAYLOAD";
        return NO;
    }

    NSData *wrapper = [NSData dataWithContentsOfURL:imageURL];
    NSData *license = [NSData dataWithContentsOfURL:licenseURL];
    NSData *manifest = [NSData dataWithContentsOfURL:manifestURL];
    if (wrapper == nil || license == nil || manifest == nil) {
        if (reason) *reason = @"NO_LOCAL_PAYLOAD";
        return NO;
    }
    const NSUInteger expectedWrapperSize = kWrapperPrefixSize + kOriginalImageSize;
    if (wrapper.length != expectedWrapperSize) {
        if (reason) *reason = @"wrapper_length_mismatch";
        return NO;
    }
    const uint8_t *bytes = (const uint8_t *)wrapper.bytes;
    if (memcmp(bytes, "FP54RAW!", 8) != 0) {
        if (reason) *reason = @"wrapper_magic_mismatch";
        return NO;
    }
    for (NSUInteger i = 8; i < kWrapperPrefixSize; ++i) {
        if (bytes[i] != 0) {
            if (reason) *reason = @"wrapper_padding_not_zero";
            return NO;
        }
    }

    NSData *image = [wrapper subdataWithRange:NSMakeRange(kWrapperPrefixSize,
                                                          kOriginalImageSize)];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(image.bytes, (CC_LONG)image.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    if (![hex isEqualToString:[NSString stringWithUTF8String:kExpectedImageSHA256]]) {
        if (reason) *reason = @"original_image_sha256_mismatch";
        return NO;
    }

    if (payloadData) *payloadData = image;
    if (licenseData) *licenseData = license;
    if (manifestData) *manifestData = manifest;
    if (reason) *reason = @"payload_sha256_verified";
    return YES;
}

- (BOOL)createDirectory:(NSURL *)url
       intermediateDirs:(BOOL)intermediate
                 reason:(NSString **)reason {
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtURL:url
                                  withIntermediateDirectories:intermediate
                                                   attributes:nil
                                                        error:&error]) {
        if (reason) *reason = @"cache_directory_creation_failed";
        return NO;
    }
    return YES;
}

- (BOOL)writeNewData:(NSData *)data toURL:(NSURL *)url reason:(NSString **)reason {
    NSFileManager *manager = [NSFileManager defaultManager];
    if ([manager fileExistsAtPath:url.path]) {
        if (reason) *reason = @"refusing_to_overwrite_existing_file";
        return NO;
    }
    NSError *error = nil;
    if (![data writeToURL:url options:NSDataWritingAtomic error:&error]) {
        if (reason) *reason = @"cache_file_write_failed";
        return NO;
    }
    return YES;
}

- (NSNumber *)fileNumberAtURL:(NSURL *)url {
    NSError *error = nil;
    NSDictionary *attributes = [[NSFileManager defaultManager]
        attributesOfItemAtPath:url.path error:&error];
    id number = attributes[NSFileSystemFileNumber];
    return [number isKindOfClass:[NSNumber class]] ? number : nil;
}

- (NSString *)sha256ForData:(NSData *)data {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

- (BOOL)prepareCopiesWithReason:(NSString **)reason {
    NSData *image = nil;
    NSData *license = nil;
    NSData *manifest = nil;
    if (![self loadBundledPayload:&image licenseData:&license
                     manifestData:&manifest reason:reason]) {
        return NO;
    }
    if (self.replayLocked) {
        if (reason) *reason = @"NO_REPLAY";
        return NO;
    }

    NSURL *root = [self cacheRootURL];
    if (![self createDirectory:root intermediateDirs:YES reason:reason]) return NO;
    NSString *sessionID = [NSUUID UUID].UUIDString;
    NSURL *session = [root URLByAppendingPathComponent:sessionID isDirectory:YES];
    if ([[NSFileManager defaultManager] fileExistsAtPath:session.path]) {
        if (reason) *reason = @"unique_cache_directory_collision";
        return NO;
    }
    if (![self createDirectory:session intermediateDirs:NO reason:reason]) return NO;

    NSURL *unsignedDirectory = [session URLByAppendingPathComponent:@"unsigned" isDirectory:YES];
    NSURL *signedDirectory = [session URLByAppendingPathComponent:@"signed" isDirectory:YES];
    NSURL *unsignedSCInfo = [unsignedDirectory URLByAppendingPathComponent:@"SC_Info" isDirectory:YES];
    NSURL *signedSCInfo = [signedDirectory URLByAppendingPathComponent:@"SC_Info" isDirectory:YES];
    BOOL created = [self createDirectory:unsignedDirectory intermediateDirs:NO reason:reason]
        && [self createDirectory:signedDirectory intermediateDirs:NO reason:reason]
        && [self createDirectory:unsignedSCInfo intermediateDirs:NO reason:reason]
        && [self createDirectory:signedSCInfo intermediateDirs:NO reason:reason];
    if (!created) return NO;

    NSURL *unsignedImage = [unsignedDirectory URLByAppendingPathComponent:@"ChatGPT" isDirectory:NO];
    NSURL *signedImage = [signedDirectory URLByAppendingPathComponent:@"ChatGPT" isDirectory:NO];
    NSURL *unsignedLicense = [unsignedSCInfo URLByAppendingPathComponent:@"ChatGPT.sinf" isDirectory:NO];
    NSURL *signedLicense = [signedSCInfo URLByAppendingPathComponent:@"ChatGPT.sinf" isDirectory:NO];
    NSURL *unsignedManifest = [unsignedSCInfo URLByAppendingPathComponent:@"Manifest.plist" isDirectory:NO];
    NSURL *signedManifest = [signedSCInfo URLByAppendingPathComponent:@"Manifest.plist" isDirectory:NO];
    if (![self writeNewData:image toURL:unsignedImage reason:reason]
        || ![self writeNewData:image toURL:signedImage reason:reason]
        || ![self writeNewData:license toURL:unsignedLicense reason:reason]
        || ![self writeNewData:license toURL:signedLicense reason:reason]
        || ![self writeNewData:manifest toURL:unsignedManifest reason:reason]
        || ![self writeNewData:manifest toURL:signedManifest reason:reason]) {
        return NO;
    }

    NSNumber *unsignedInode = [self fileNumberAtURL:unsignedImage];
    NSNumber *signedInode = [self fileNumberAtURL:signedImage];
    if (unsignedInode == nil || signedInode == nil || [unsignedInode isEqualToNumber:signedInode]) {
        if (reason) *reason = @"image_copies_do_not_have_distinct_inodes";
        return NO;
    }

    self.sessionURL = session;
    self.sessionID = sessionID;
    self.unsignedImageURL = unsignedImage;
    self.signedImageURL = signedImage;
    if (reason) *reason = @"prepared_two_distinct_inode_images";
    return YES;
}

- (NSDictionary *)readJournal {
    NSURL *url = [self journalURL];
    if (![[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
        return @{
            @"schema": kJournalSchema,
            @"run_claimed": @NO,
            @"session_id": @"",
            @"modes": @{
                @"unsigned-page": @"not_started",
                @"signed-page": @"not_started"
            }
        };
    }
    NSDictionary *journal = [NSDictionary dictionaryWithContentsOfURL:url];
    if (![journal isKindOfClass:[NSDictionary class]]
        || ![journal[@"schema"] isEqual:kJournalSchema]
        || ![journal[@"modes"] isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    return journal;
}

- (BOOL)writeJournal:(NSDictionary *)journal {
    if (journal == nil) return NO;
    NSURL *root = [self cacheRootURL];
    NSString *reason = nil;
    if (![self createDirectory:root intermediateDirs:YES reason:&reason]) return NO;
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:journal
                                                             format:NSPropertyListXMLFormat_v1_0
                                                            options:0
                                                              error:&error];
    return data != nil && [data writeToURL:[self journalURL]
                                   options:NSDataWritingAtomic
                                     error:&error];
}

- (BOOL)claimRunForSession {
    NSDictionary *journal = [self readJournal];
    if (journal == nil || [journal[@"run_claimed"] boolValue]) return NO;
    NSDictionary *modes = journal[@"modes"];
    if (![modes[@"unsigned-page"] isEqual:@"not_started"]
        || ![modes[@"signed-page"] isEqual:@"not_started"]) {
        return NO;
    }
    NSMutableDictionary *updated = [journal mutableCopy];
    updated[@"run_claimed"] = @YES;
    updated[@"session_id"] = self.sessionID ?: @"";
    return [self writeJournal:updated];
}

- (BOOL)recordMode:(NSString *)modeName state:(NSString *)state
           summary:(NSDictionary *)summary {
    NSDictionary *journal = [self readJournal];
    if (journal == nil || ![journal[@"run_claimed"] boolValue]
        || ![journal[@"session_id"] isEqual:self.sessionID ?: @""]) {
        return NO;
    }
    NSDictionary *modes = journal[@"modes"];
    NSMutableDictionary *updatedModes = [modes mutableCopy];
    updatedModes[modeName] = state;
    NSMutableDictionary *updated = [journal mutableCopy];
    updated[@"modes"] = updatedModes;
    if (summary != nil) {
        NSMutableDictionary *summaries = [journal[@"summaries"] mutableCopy] ?: [NSMutableDictionary new];
        summaries[modeName] = summary;
        updated[@"summaries"] = summaries;
    }
    return [self writeJournal:updated];
}

- (BOOL)verifyCopiesBeforeMapping:(NSString **)reason {
    if (self.unsignedImageURL == nil || self.signedImageURL == nil) {
        if (reason) *reason = @"prepared_image_paths_unavailable";
        return NO;
    }
    NSData *unsignedData = [NSData dataWithContentsOfURL:self.unsignedImageURL];
    NSData *signedData = [NSData dataWithContentsOfURL:self.signedImageURL];
    if (unsignedData == nil || signedData == nil
        || unsignedData.length != kOriginalImageSize
        || signedData.length != kOriginalImageSize
        || ![[self sha256ForData:unsignedData] isEqualToString:
             [NSString stringWithUTF8String:kExpectedImageSHA256]]
        || ![[self sha256ForData:signedData] isEqualToString:
             [NSString stringWithUTF8String:kExpectedImageSHA256]]) {
        if (reason) *reason = @"pre_mapping_image_sha256_mismatch";
        return NO;
    }
    NSNumber *unsignedInode = [self fileNumberAtURL:self.unsignedImageURL];
    NSNumber *signedInode = [self fileNumberAtURL:self.signedImageURL];
    if (unsignedInode == nil || signedInode == nil || [unsignedInode isEqualToNumber:signedInode]) {
        if (reason) *reason = @"pre_mapping_images_not_distinct_inodes";
        return NO;
    }

    NSData *expectedLicense = [NSData dataWithContentsOfURL:
        [self bundledResourceURLForName:@"ChatGPT" extension:@"sinf" directory:@"EmbeddedLicense"]];
    NSData *expectedManifest = [NSData dataWithContentsOfURL:
        [self bundledResourceURLForName:@"Manifest" extension:@"plist" directory:@"EmbeddedLicense"]];
    NSURL *unsignedSCInfo = [self.unsignedImageURL.URLByDeletingLastPathComponent
        URLByAppendingPathComponent:@"SC_Info" isDirectory:YES];
    NSURL *signedSCInfo = [self.signedImageURL.URLByDeletingLastPathComponent
        URLByAppendingPathComponent:@"SC_Info" isDirectory:YES];
    NSData *unsignedLicense = [NSData dataWithContentsOfURL:
        [unsignedSCInfo URLByAppendingPathComponent:@"ChatGPT.sinf"]];
    NSData *signedLicense = [NSData dataWithContentsOfURL:
        [signedSCInfo URLByAppendingPathComponent:@"ChatGPT.sinf"]];
    NSData *unsignedManifest = [NSData dataWithContentsOfURL:
        [unsignedSCInfo URLByAppendingPathComponent:@"Manifest.plist"]];
    NSData *signedManifest = [NSData dataWithContentsOfURL:
        [signedSCInfo URLByAppendingPathComponent:@"Manifest.plist"]];
    if (expectedLicense == nil || expectedManifest == nil
        || ![unsignedLicense isEqualToData:expectedLicense]
        || ![signedLicense isEqualToData:expectedLicense]
        || ![unsignedManifest isEqualToData:expectedManifest]
        || ![signedManifest isEqualToData:expectedManifest]) {
        if (reason) *reason = @"pre_mapping_sc_info_mismatch";
        return NO;
    }
    if (reason) *reason = @"both_images_and_sc_info_reverified";
    return YES;
}

- (NSDictionary *)invokeDiagnosticMode:(NSString *)mode
                             imageURL:(NSURL *)imageURL
                               logURL:(NSURL *)logURL
                                error:(NSString **)reason {
    int logFD = open(logURL.fileSystemRepresentation,
                     O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (logFD < 0) {
        if (reason) *reason = @"diagnostic_log_create_failed";
        return nil;
    }
    int savedStdout = dup(STDOUT_FILENO);
    if (savedStdout < 0) {
        close(logFD);
        if (reason) *reason = @"stdout_backup_failed";
        return nil;
    }

    int diagnosticExit = -1;
    BOOL redirected = NO;
    BOOL restoreSucceeded = YES;
    fflush(stdout);
    if (dup2(logFD, STDOUT_FILENO) < 0) {
        if (reason) *reason = @"stdout_redirect_failed";
    } else {
        redirected = YES;
        const char *modeBytes = mode.UTF8String;
        const char *pathBytes = imageURL.fileSystemRepresentation;
        char *arguments[] = {
            (char *)"v121-map-diagnostic",
            (char *)modeBytes,
            (char *)pathBytes,
            NULL
        };
        @try {
            diagnosticExit = v121_diagnostic_main(3, arguments);
        } @finally {
            fflush(stdout);
            restoreSucceeded = dup2(savedStdout, STDOUT_FILENO) >= 0;
        }
    }
    if (redirected && !restoreSucceeded) {
        (void)dup2(savedStdout, STDOUT_FILENO);
    }
    (void)fsync(logFD);
    close(savedStdout);
    close(logFD);
    if (!restoreSucceeded) {
        if (reason) *reason = @"stdout_restore_failed";
        return nil;
    }

    NSData *logData = [NSData dataWithContentsOfURL:logURL];
    NSString *jsonText = logData != nil
        ? [[NSString alloc] initWithData:logData encoding:NSUTF8StringEncoding] : nil;
    if (jsonText == nil) {
        if (reason) *reason = @"diagnostic_json_log_unreadable";
        return nil;
    }
    NSString *trimmed = [jsonText stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSData *jsonData = [trimmed dataUsingEncoding:NSUTF8StringEncoding];
    NSError *parseError = nil;
    id object = jsonData != nil
        ? [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&parseError] : nil;
    if (![object isKindOfClass:[NSDictionary class]]) {
        if (reason) *reason = @"diagnostic_output_not_single_json_object";
        return @{
            @"exit_code": @(diagnosticExit),
            @"json_text": trimmed,
            @"json": @{}
        };
    }
    if (reason) *reason = @"diagnostic_json_captured";
    return @{
        @"exit_code": @(diagnosticExit),
        @"json_text": trimmed,
        @"json": object
    };
}

- (NSString *)summaryForMode:(NSString *)mode result:(NSDictionary *)result {
    NSDictionary *json = result[@"json"];
    NSString *status = [json[@"status"] isKindOfClass:[NSString class]]
        ? json[@"status"] : @"unknown";
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObjects:
        [NSString stringWithFormat:@"mode=%@", mode],
        [NSString stringWithFormat:@"exit=%@", result[@"exit_code"] ?: @"unknown"],
        [NSString stringWithFormat:@"status=%@", status], nil];
    for (NSString *key in @[@"reason", @"remap_attempted", @"remap_return",
                            @"remap_errno", @"read_attempted", @"kr",
                            @"received", @"changed_count"]) {
        id value = json[key];
        if (value != nil && value != [NSNull null]) {
            [parts addObject:[NSString stringWithFormat:@"%@=%@", key, value]];
        }
    }
    return [parts componentsJoinedByString:@"  "];
}

- (void)prepareAndInspectTapped:(id)sender {
    (void)sender;
    if (self.operationRunning || self.replayLocked || !self.localResourcesPresent) return;
    self.operationRunning = YES;
    [self refreshControls];
    self.statusLabel.text = @"Checking local wrapper and preparing isolated cache copies…";
    self.outputLabel.text = @"";

    dispatch_async(self.workerQueue, ^{
        NSString *reason = nil;
        BOOL prepared = [self prepareCopiesWithReason:&reason];
        NSDictionary *inspect = nil;
        if (prepared) {
            NSURL *logURL = [self.sessionURL URLByAppendingPathComponent:@"inspect.jsonl"];
            inspect = [self invokeDiagnosticMode:@"--inspect"
                                        imageURL:self.unsignedImageURL
                                          logURL:logURL
                                           error:&reason];
            NSDictionary *json = inspect[@"json"];
            prepared = inspect != nil
                && [inspect[@"exit_code"] intValue] == 0
                && [json[@"status"] isEqual:@"eligible"];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.operationRunning = NO;
            self.prepared = prepared;
            [self refreshControls];
            if (!prepared) {
                self.statusLabel.text = reason ?: @"preparation_or_inspect_failed";
                if (inspect[@"json_text"] != nil) {
                    self.outputLabel.text = [NSString stringWithFormat:
                        @"--inspect result\n%@",
                        inspect[@"json_text"]];
                }
                return;
            }
            self.statusLabel.text = @"Prepared two distinct-inode image copies. SHA-256 verified. Inspect completed; ready for the single explicit test run.";
            self.outputLabel.text = [NSString stringWithFormat:
                @"image_sha256_match=true\n--inspect summary\n%@\n\n--inspect JSON\n%@",
                [self summaryForMode:@"inspect" result:inspect],
                inspect[@"json_text"]];
        });
    });
}

- (void)runOnePageTestsTapped:(id)sender {
    (void)sender;
    if (!self.prepared || self.operationRunning || self.replayLocked) return;
    self.operationRunning = YES;
    self.replayLocked = YES;
    [self refreshControls];
    self.statusLabel.text = @"Claiming the one-shot run journal…";
    self.outputLabel.text = @"";

    dispatch_async(self.workerQueue, ^{
        NSMutableArray<NSString *> *displayParts = [NSMutableArray array];
        NSString *failureReason = nil;
        BOOL claimed = [self claimRunForSession];
        if (!claimed) {
            failureReason = @"NO_REPLAY: one-shot journal could not be claimed.";
        }

        if (claimed) {
            BOOL inputsValid = [self verifyCopiesBeforeMapping:&failureReason];
            if (!inputsValid) {
                failureReason = failureReason ?: @"pre_mapping_verification_failed";
            } else if (![self recordMode:@"unsigned-page" state:@"started" summary:nil]) {
                failureReason = @"journal_write_failed_before_unsigned_call";
            } else {
                NSURL *logURL = [self.sessionURL URLByAppendingPathComponent:@"unsigned-page.jsonl"];
                NSDictionary *unsignedResult = [self invokeDiagnosticMode:@"--unsigned-page"
                                                                 imageURL:self.unsignedImageURL
                                                                   logURL:logURL
                                                                    error:&failureReason];
                if (unsignedResult == nil) {
                    (void)[self recordMode:@"unsigned-page" state:@"started"
                                   summary:@{@"outcome": @"unknown_no_replay"}];
                    failureReason = failureReason ?: @"unsigned_page_call_outcome_unknown";
                } else {
                    [displayParts addObject:[NSString stringWithFormat:
                        @"--unsigned-page summary\n%@\n\n--unsigned-page JSON\n%@",
                        [self summaryForMode:@"unsigned-page" result:unsignedResult],
                        unsignedResult[@"json_text"]]];
                    NSDictionary *unsignedJournalSummary = @{
                        @"exit_code": unsignedResult[@"exit_code"] ?: @(-1),
                        @"status": unsignedResult[@"json"][@"status"] ?: @"unknown",
                        @"reason": unsignedResult[@"json"][@"reason"] ?: @"unknown"
                    };
                    if (![self recordMode:@"unsigned-page" state:@"completed"
                                  summary:unsignedJournalSummary]) {
                        failureReason = @"journal_write_failed_after_unsigned_call";
                    } else {
                        inputsValid = [self verifyCopiesBeforeMapping:&failureReason];
                        if (!inputsValid) {
                            failureReason = failureReason ?: @"pre_signed_mapping_verification_failed";
                        } else if (![self recordMode:@"signed-page" state:@"started" summary:nil]) {
                            failureReason = @"journal_write_failed_before_signed_call";
                        } else {
                            NSURL *signedLogURL = [self.sessionURL URLByAppendingPathComponent:@"signed-page.jsonl"];
                            NSDictionary *signedResult = [self invokeDiagnosticMode:@"--signed-page"
                                                                           imageURL:self.signedImageURL
                                                                             logURL:signedLogURL
                                                                              error:&failureReason];
                            if (signedResult == nil) {
                                (void)[self recordMode:@"signed-page" state:@"started"
                                               summary:@{@"outcome": @"unknown_no_replay"}];
                                failureReason = failureReason ?: @"signed_page_call_outcome_unknown";
                            } else {
                                [displayParts addObject:[NSString stringWithFormat:
                                    @"--signed-page summary\n%@\n\n--signed-page JSON\n%@",
                                    [self summaryForMode:@"signed-page" result:signedResult],
                                    signedResult[@"json_text"]]];
                                NSDictionary *signedJournalSummary = @{
                                    @"exit_code": signedResult[@"exit_code"] ?: @(-1),
                                    @"status": signedResult[@"json"][@"status"] ?: @"unknown",
                                    @"reason": signedResult[@"json"][@"reason"] ?: @"unknown"
                                };
                                if (![self recordMode:@"signed-page" state:@"completed"
                                              summary:signedJournalSummary]) {
                                    failureReason = @"journal_write_failed_after_signed_call";
                                }
                            }
                        }
                    }
                }
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            self.operationRunning = NO;
            self.replayLocked = YES;
            [self refreshControls];
            if (failureReason != nil) {
                self.statusLabel.text = [NSString stringWithFormat:
                    @"NO_REPLAY: %@ Any started mode will not be run again automatically.",
                    failureReason];
            } else {
                self.statusLabel.text = @"One-shot run finished. The journal blocks any replay.";
            }
            self.outputLabel.text = displayParts.count
                ? [displayParts componentsJoinedByString:@"\n\n----------------------------------------\n\n"]
                : @"No page diagnostic call was made.";
        });
    });
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([V121AppDelegate class]));
    }
}
