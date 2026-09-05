#import <Foundation/Foundation.h>
#import "RootHelperBridge.h"

static void Require(BOOL condition, NSString *message)
{
    if (condition) { return; }
    fprintf(stderr, "FAIL: %s\n", message.UTF8String ?: "unknown");
    exit(1);
}

static NSInteger Run(NSArray<NSString *> *arguments, NSTimeInterval timeout, NSString **standardOutput, NSString **standardError)
{
    return CloudCodeSpawnHelperWithSeparatedOutput(@"/bin/sh", arguments, NO, timeout, standardOutput, standardError);
}

int main(void)
{
    @autoreleasepool {
        NSString *standardOutput = nil;
        NSString *standardError = nil;

        NSInteger result = Run(@[@"-c", @"printf PAYLOAD; printf DIAGNOSTIC >&2"], 2.0, &standardOutput, &standardError);
        Require(result == 0, @"separated stdout/stderr command must exit successfully");
        Require([standardOutput isEqualToString:@"PAYLOAD"], @"stdout payload must remain isolated");
        Require([standardError isEqualToString:@"DIAGNOSTIC"], @"stderr diagnostics must remain isolated");

        standardOutput = nil;
        standardError = nil;
        result = Run(@[@"-c", @"python3 -c 'import sys; sys.stdout.write(\"A\" * (1024 * 1024))'"], 4.0, &standardOutput, &standardError);
        Require(result == 0, @"exact 1 MiB stdout boundary must remain valid");
        Require(standardOutput.length == 1024 * 1024, @"exact 1 MiB stdout must be captured completely");
        Require(standardError.length == 0, @"exact-boundary stdout must not synthesize diagnostics");

        standardOutput = nil;
        standardError = nil;
        result = Run(@[@"-c", @"python3 -c 'import sys; sys.stdout.write(\"B\" * (1024 * 1024 + 1))'"], 4.0, &standardOutput, &standardError);
        Require(result < 0, @"stdout above capture limit must fail closed");
        Require([standardError containsString:@"stdout capture truncated"], @"stdout truncation must be explicit in diagnostics");

        standardOutput = nil;
        standardError = nil;
        result = Run(@[@"-c", @"sleep 2"], 0.1, &standardOutput, &standardError);
        Require(result < 0, @"helper timeout must fail closed");
        Require([standardError containsString:@"timed out"], @"helper timeout must be observable in stderr diagnostics");

        printf("PASS: helper output transport isolates stdout/stderr, preserves the 1 MiB boundary, detects truncation, and enforces timeout\n");
        return 0;
    }
}
