#import <Foundation/Foundation.h>
#import "RootHelperBridge.h"
#import <time.h>
#import <dispatch/dispatch.h>
#import <unistd.h>

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

        // A helper may close its output before it exits (private framework teardown/hang).
        // Polling its persistent POLLHUP previously burned a core until the deadline.
        clock_t cpuStart = clock();
        NSDate *wallStart = [NSDate date];
        result = Run(@[@"-c", @"exec 1>&- 2>&-; sleep 1"], 2, &standardOutput, &standardError);
        double cpuSeconds = (double)(clock() - cpuStart) / CLOCKS_PER_SEC;
        Require(result == 0 && -wallStart.timeIntervalSinceNow >= 0.8, @"closed output must still wait for process exit");
        Require(cpuSeconds < 0.25, @"closed pipes must sleep, not busy-poll POLLHUP");

        for (int iteration = 0; iteration < 30; iteration++) {
            result = Run(@[@"-c", @"printf bounded"], 2, &standardOutput, &standardError);
            Require(result == 0 && [standardOutput isEqualToString:@"bounded"], @"reaped one-shot must release admission slot for repeated requests");
        }

        NSString *testDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [[NSFileManager defaultManager] createDirectoryAtPath:testDirectory withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *child = [testDirectory stringByAppendingPathComponent:@"CloudCodeBridgeTestChild"];
        Require([[NSFileManager defaultManager] createSymbolicLinkAtPath:child withDestinationPath:@"/bin/sh" error:nil], @"create isolated transport test child");
        NSString *ready = [testDirectory stringByAppendingPathComponent:@"ready"];
        dispatch_group_t group = dispatch_group_create();
        __block NSInteger concurrentResult = -1;
        dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            concurrentResult = CloudCodeSpawnHelperWithSeparatedOutput(child,
                @[@"-c", @"touch \"$1\"; sleep 0.5", @"test", ready], NO, 2, NULL, NULL);
        });
        NSDate *readyDeadline = [NSDate dateWithTimeIntervalSinceNow:1];
        while (![[NSFileManager defaultManager] fileExistsAtPath:ready] && readyDeadline.timeIntervalSinceNow > 0) { usleep(10000); }
        Require([[NSFileManager defaultManager] fileExistsAtPath:ready], @"concurrent fixture must actually start before admission assertion");
        result = CloudCodeSpawnHelperWithSeparatedOutput(child, @[@"-c", @"exit 0"], NO, 2, &standardOutput, &standardError);
        Require(result < 0 && [standardError containsString:@"runtime_degraded"], @"same-command overlap must fail closed without spawning another helper");
        Require(dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) == 0 && concurrentResult == 0,
            @"original helper must finish and release its registry slot");

        NSString *axHelper = [testDirectory stringByAppendingPathComponent:@"CloudCodeRootHelper"];
        NSString *axReady = [testDirectory stringByAppendingPathComponent:@"ax-ready"];
        NSString *axScript = @"#!/bin/sh\nif [ -n \"$2\" ]; then touch \"$2\"; fi\nsleep 0.5\n";
        Require([axScript writeToFile:axHelper atomically:YES encoding:NSUTF8StringEncoding error:nil], @"create AX admission test helper");
        Require([[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0755} ofItemAtPath:axHelper error:nil], @"make AX admission test helper executable");
        __block NSInteger axConcurrentResult = -1;
        dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            axConcurrentResult = CloudCodeSpawnHelperWithSeparatedOutput(axHelper,
                @[@"gui-tree-json", axReady], NO, 2, NULL, NULL);
        });
        readyDeadline = [NSDate dateWithTimeIntervalSinceNow:1];
        while (![[NSFileManager defaultManager] fileExistsAtPath:axReady] && readyDeadline.timeIntervalSinceNow > 0) { usleep(10000); }
        Require([[NSFileManager defaultManager] fileExistsAtPath:axReady], @"AX lease fixture must actually start before overlap assertion");
        standardOutput = nil;
        standardError = nil;
        result = CloudCodeSpawnHelperWithSeparatedOutput(axHelper, @[@"gui-focused-text-input-json"], NO, 2, &standardOutput, &standardError);
        Require(result < 0 && [standardError containsString:@"serialized AX lease"],
            @"different AX commands must share one admission key and never overlap the system Automation lease");
        Require(dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) == 0 && axConcurrentResult == 0,
            @"first AX lease helper must finish and release the shared admission key");
        result = CloudCodeSpawnHelperWithSeparatedOutput(axHelper, @[@"gui-focused-text-input-json"], NO, 2, &standardOutput, &standardError);
        Require(result == 0, @"serialized AX admission key must be reusable after the prior helper exits");

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
