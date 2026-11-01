// IPA Total V118: independent iOS16.6 licensed-IPA memory-map capability probe.
// Does not decrypt/export an IPA, spoof OS, touch fairplayd or run the official app.
// Original license/binary are embedded only in the locally assembled unsigned IPA.
// Never upload target app, SC_Info or app credentials to a CI service.
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <mach-o/loader.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

typedef int (*fp_remap_fn)(void *, size_t, uint32_t, uint32_t, uint32_t);

static int fp_remap(void *addr, size_t size, uint32_t cryptid, uint32_t cpu, uint32_t subtype) {
    fp_remap_fn f = (fp_remap_fn)dlsym(RTLD_DEFAULT, "mremap_encrypted");
    if (f) return f(addr, size, cryptid, cpu, subtype);
#if defined(__arm64__)
    // SYS_mremap_encrypted = 489 on the tested public Darwin syscall table.
    // Only use on this helper's own read-only mapped bytes.
    register uint64_t x0 __asm__("x0") = (uint64_t)addr;
    register uint64_t x1 __asm__("x1") = size;
    register uint64_t x2 __asm__("x2") = cryptid;
    register uint64_t x3 __asm__("x3") = cpu;
    register uint64_t x4 __asm__("x4") = subtype;
    register uint64_t x16 __asm__("x16") = 489;
    uint64_t failure = 1;
    __asm__ volatile("svc #0x80\n\tcset %[failure], cs"
                     : "+r"(x0), "+r"(x1), [failure]"=r"(failure)
                     : "r"(x2), "r"(x3), "r"(x4), "r"(x16)
                     : "memory", "cc");
    if (failure) { errno = (int)x0; return -1; }
    return (int)x0;
#else
    errno = ENOSYS;
    return -1;
#endif
}

static NSString *probe(void) {
    NSString *path = [[NSBundle.mainBundle.resourcePath
                      stringByAppendingPathComponent:@"EmbeddedPayload/ChatGPT"]
                      stringByAppendingPathComponent:@"ChatGPT"];
    int fd = open(path.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) return @"NO_LOCAL_EMBEDDED_TEST_IMAGE";
    // V121: TrollStore changed this nested Mach-O despite omission of its
    // Info.plist. cryptid=1 alone did not prove the original signature survived.
    // Fail before remap unless the full pinned V117 image is byte-identical.
    const size_t originalSize = 551440;
    uint8_t expected[CC_SHA256_DIGEST_LENGTH] = {
        0x9c,0x6b,0x55,0xca,0xa0,0x18,0x02,0x76,0xb9,0x17,0x5c,0xc9,0x49,0xec,0x36,0x78,
        0x22,0x2f,0x28,0x76,0x72,0xa1,0xc5,0xff,0xf3,0xcb,0xc5,0x7a,0x79,0xd7,0xae,0xb0
    };
    uint8_t actual[CC_SHA256_DIGEST_LENGTH];
    struct stat originalStat = {0};
    if (fstat(fd, &originalStat) != 0 || originalStat.st_size != originalSize) {
        close(fd); return @"EMBEDDED_IMAGE_CHANGED_OR_UNREADABLE; remap NOT attempted";
    }
    uint8_t *imageBytes = malloc(originalSize);
    if (!imageBytes || pread(fd, imageBytes, originalSize, 0) != originalSize) {
        free(imageBytes); close(fd);
        return @"EMBEDDED_IMAGE_CHANGED_OR_UNREADABLE; remap NOT attempted";
    }
    CC_SHA256(imageBytes, (CC_LONG)originalSize, actual);
    free(imageBytes);
    if (memcmp(expected, actual, sizeof(expected)) != 0) {
        close(fd); return @"EMBEDDED_IMAGE_HASH_MISMATCH; remap NOT attempted";
    }
    struct mach_header_64 mh = {0};
    if (pread(fd, &mh, sizeof(mh), 0) != sizeof(mh)
        || mh.magic != MH_MAGIC_64 || mh.cputype != CPU_TYPE_ARM64
        || mh.ncmds > 256 || mh.sizeofcmds > 262144) {
        close(fd); return @"BAD_MACHO_HEADER";
    }
    uint8_t *cmd = calloc(1, mh.sizeofcmds);
    if (!cmd || pread(fd, cmd, mh.sizeofcmds, sizeof(mh)) != mh.sizeofcmds) {
        free(cmd); close(fd); return @"BAD_MACHO_COMMANDS";
    }
    uint32_t cryptoff = 0, cryptsize = 0, cryptid = 0;
    uint32_t pos = 0;
    for (uint32_t n = 0; n < mh.ncmds; n++) {
        if (pos + 8 > mh.sizeofcmds) break;
        struct load_command *lc = (struct load_command *)(cmd + pos);
        if (lc->cmdsize < 8 || pos + lc->cmdsize > mh.sizeofcmds) break;
        if (lc->cmd == LC_ENCRYPTION_INFO_64 && lc->cmdsize >= sizeof(struct encryption_info_command_64)) {
            struct encryption_info_command_64 *e = (void *)lc;
            cryptoff = e->cryptoff; cryptsize = e->cryptsize; cryptid = e->cryptid;
            break;
        }
        pos += lc->cmdsize;
    }
    free(cmd);
    struct stat st = {0};
    int ok = fstat(fd, &st);
    size_t pg = (size_t)getpagesize();
    if (ok != 0 || cryptid != 1 || !cryptsize || !cryptoff ||
        cryptoff % pg || (uint64_t)cryptoff + cryptsize > (uint64_t)st.st_size) {
        close(fd); return @"IMAGE_NOT_ELIGIBLE_FOR_BOUNDED_TEST";
    }
    const size_t chunkSize = 4096;
    if (cryptsize < chunkSize) { close(fd); return @"ENCRYPTED_SPAN_TOO_SHORT"; }
    uint8_t before[chunkSize], after[chunkSize];
    if (pread(fd, before, chunkSize, cryptoff) != chunkSize) {
        close(fd); return @"READ_BEFORE_FAILED";
    }
    size_t extent = ((size_t)cryptoff + cryptsize + pg - 1) & ~(pg - 1);
    uint8_t *base = mmap(NULL, extent, PROT_READ, MAP_PRIVATE, fd, 0);
    if (base == MAP_FAILED) {
        int err = errno; close(fd);
        return [NSString stringWithFormat:@"MMAP_READ_FAILED errno=%d", err];
    }
    errno = 0;
    // First try the read-only FairPlay mapping path (cryptid=2). No PROT_EXEC.
    int result = fp_remap(base + cryptoff, cryptsize, 2, mh.cputype, mh.cpusubtype);
    int err = errno;
    kern_return_t kr = KERN_FAILURE;
    vm_size_t received = 0;
    size_t changed = 0;
    if (result == 0) {
        kr = vm_read_overwrite(mach_task_self(),
                (vm_address_t)(base + cryptoff), (vm_size_t)chunkSize,
                (vm_address_t)after, &received);
        if (kr == KERN_SUCCESS && received == chunkSize) {
            for (size_t i=0; i < chunkSize; i++) changed += before[i] != after[i];
        }
    }
    munmap(base, extent); close(fd);
    if (result != 0) {
        return [NSString stringWithFormat:
                @"iOS %@\nProtected original SHA256: verified\n"
                 @"mremap cryptid2=%d errno=%d\n"
                 @"Read page: NOT ATTEMPTED\nChanged bytes: NOT MEASURED\n"
                 @"This is NOT ChatGPT.",
                 UIDevice.currentDevice.systemVersion, result, err];
    }
    // No plaintext bytes, license IDs, keys or addresses in the result.
    return [NSString stringWithFormat:
            @"iOS %@\nProtected original: YES\nmremap cryptid2=%d errno=%d\n"
             @"Read page kr=%d bytes=%lu\nChanged bytes=%lu/4096\n"
             @"Success requires separate executable/ABI validation; this is NOT ChatGPT.",
             UIDevice.currentDevice.systemVersion, result, err, kr,
             (unsigned long)received, (unsigned long)changed];
}

@interface IPAProbeAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation IPAProbeAppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *c = [UIViewController new];
    c.view.backgroundColor = [UIColor colorWithRed:0.05 green:0.09 blue:0.16 alpha:1];
    UILabel *status = [[UILabel alloc] initWithFrame:CGRectZero];
    status.translatesAutoresizingMaskIntoConstraints = NO;
    status.textColor = UIColor.whiteColor;
    status.numberOfLines = 0;
    status.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    status.text = @"IPA / 16.6 FairPlay\n\nProbe ready. Tap Test once.\nNever the official ChatGPT app.";
    [c.view addSubview:status];
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:@"Test local FairPlay map" forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.backgroundColor = [UIColor colorWithRed:0.10 green:0.42 blue:0.52 alpha:1];
    button.layer.cornerRadius = 12;
    [c.view addSubview:button];
    [NSLayoutConstraint activateConstraints:@[
        [status.leadingAnchor constraintEqualToAnchor:c.view.leadingAnchor constant:22],
        [status.trailingAnchor constraintEqualToAnchor:c.view.trailingAnchor constant:-22],
        [status.topAnchor constraintEqualToAnchor:c.view.safeAreaLayoutGuide.topAnchor constant:40],
        [button.leadingAnchor constraintEqualToAnchor:c.view.leadingAnchor constant:20],
        [button.trailingAnchor constraintEqualToAnchor:c.view.trailingAnchor constant:-20],
        [button.heightAnchor constraintEqualToConstant:50],
        [button.bottomAnchor constraintEqualToAnchor:c.view.safeAreaLayoutGuide.bottomAnchor constant:-30],
    ]];
    UIAction *action = [UIAction actionWithHandler:^(__kindof UIAction *unused) {
        button.enabled = NO;
        status.text = @"Testing the isolated embedded image…";
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *res = probe();
            dispatch_async(dispatch_get_main_queue(), ^{
                status.text = res; button.enabled = YES;
            });
        });
    }];
    [button addAction:action forControlEvents:UIControlEventTouchUpInside];
    self.window.rootViewController = c;
    [self.window makeKeyAndVisible];
    return YES;
}
@end
int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([IPAProbeAppDelegate class]));
    }
}
