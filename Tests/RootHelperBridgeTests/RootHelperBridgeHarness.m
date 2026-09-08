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

        NSString *testDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [[NSFileManager defaultManager] createDirectoryAtPath:testDirectory withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *child = [testDirectory stringByAppendingPathComponent:@"CloudCodeBridgeTestChild"];
        Require([[NSFileManager defaultManager] createSymbolicLinkAtPath:child withDestinationPath:@"/bin/sh" error:nil], @"create isolated transport test child");
        result = CloudCodeSpawnHelperWithSeparatedOutput(child, @[@"-c", @"kill -KILL $$"], NO, 2, &standardOutput, &standardError);
        Require(result == -5009, @"external/self SIGKILL must retain signal result, not parent timeout");
        NSData *recordData = [[standardError componentsSeparatedByString:@"\n"].lastObject dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *record = [NSJSONSerialization JSONObjectWithData:recordData options:0 error:nil];
        Require([record[@"signal"] intValue] == 9 && ![record[@"parentTimeout"] boolValue], @"signal-only termination evidence must not claim parent timeout");
        result = CloudCodeSpawnHelperWithSeparatedOutput(child, @[@"-c", @"sleep 2"], NO, 0.1, &standardOutput, &standardError);
        recordData = [[standardError componentsSeparatedByString:@"\n"].lastObject dataUsingEncoding:NSUTF8StringEncoding];
        record = [NSJSONSerialization JSONObjectWithData:recordData options:0 error:nil];
        Require(result != -5009 && [record[@"parentTimeout"] boolValue], @"parent timeout kill must be distinguishable from unknown system SIGKILL");
        [[NSFileManager defaultManager] removeItemAtPath:testDirectory error:nil];

        printf("PASS: helper output transport isolates stdout/stderr, preserves the 1 MiB boundary, detects truncation, and enforces timeout\n");
        return 0;
    }
}
