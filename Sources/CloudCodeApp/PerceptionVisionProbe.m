#import "PerceptionVisionProbe.h"

NSString *CloudCodeVisionProbeJSON(NSData *jpeg, NSString *initializer, NSString *language,
                                  BOOL cpuOnly, double pointWidth, double pointHeight) {
    @autoreleasepool {
        NSDictionary *result = CCPerceptionVisionProbe(jpeg, initializer, language, cpuOnly, pointWidth, pointHeight, @"app_process");
        NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:nil];
        return json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : @"{\"status\":\"serialization_failed\"}";
    }
}
