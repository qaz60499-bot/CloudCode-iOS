/*
 * Read-only macOS host probe for the AVAudioApplication public runtime ABI.
 *
 * This opens the host AVFAudio framework, reads two exported NSString globals,
 * and inspects Objective-C method encodings. It never invokes an AVAudio API,
 * requests permission, configures audio, or contacts an iOS device.
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <TargetConditionals.h>
#import <dlfcn.h>
#import <stdio.h>
#import <stdlib.h>

static NSString *ReadExportedString(void *handle, const char *name) {
    void *slotAddress = dlsym(handle, name);
    if (slotAddress == NULL) {
        return nil;
    }

    NSString * __unsafe_unretained const *slot =
        (NSString * __unsafe_unretained const *)slotAddress;
    return *slot;
}

static NSDictionary *DescribeMethod(Method method) {
    if (method == NULL) {
        return @{ @"present": @NO };
    }

    const char *encoding = method_getTypeEncoding(method);
    char *returnType = method_copyReturnType(method);
    NSMutableArray<NSString *> *argumentTypes = [NSMutableArray array];
    unsigned int argumentCount = method_getNumberOfArguments(method);
    for (unsigned int index = 0; index < argumentCount; index++) {
        char buffer[128] = {0};
        method_getArgumentType(method, index, buffer, sizeof(buffer));
        [argumentTypes addObject:[NSString stringWithUTF8String:buffer] ?: @""];
    }

    NSString *returnEncoding = returnType != NULL
        ? [NSString stringWithUTF8String:returnType]
        : @"";
    free(returnType);

    return @{
        @"present": @YES,
        @"typeEncoding": encoding != NULL ? [NSString stringWithUTF8String:encoding] : @"",
        @"returnTypeEncoding": returnEncoding,
        @"argumentCount": @(argumentCount),
        @"argumentTypes": argumentTypes,
    };
}

static NSDictionary *DescribeConstant(void *handle, const char *name) {
    NSString *value = ReadExportedString(handle, name);
    if (value == nil) {
        return @{ @"present": @NO };
    }
    return @{
        @"present": @YES,
        @"literal": value,
        @"utf8Length": @([value lengthOfBytesUsingEncoding:NSUTF8StringEncoding]),
    };
}

int main(void) {
    @autoreleasepool {
        const char *frameworkPath =
            "/System/Library/Frameworks/AVFAudio.framework/AVFAudio";
        void *handle = dlopen(frameworkPath, RTLD_LAZY | RTLD_LOCAL);
        if (handle == NULL) {
            const char *error = dlerror();
            fprintf(stderr, "V137 AVFAudio dlopen failed: %s\n",
                    error != NULL ? error : "unknown error");
            return 2;
        }

        Class cls = objc_getClass("AVAudioApplication");
        NSMutableDictionary *methods = [NSMutableDictionary dictionary];
        if (cls != Nil) {
            methods[@"+sharedInstance"] = DescribeMethod(
                class_getClassMethod(cls, sel_registerName("sharedInstance")));
            methods[@"+requestRecordPermissionWithCompletionHandler:"] = DescribeMethod(
                class_getClassMethod(cls, sel_registerName("requestRecordPermissionWithCompletionHandler:")));
            methods[@"-recordPermission"] = DescribeMethod(
                class_getInstanceMethod(cls, sel_registerName("recordPermission")));
            methods[@"-isInputMuted"] = DescribeMethod(
                class_getInstanceMethod(cls, sel_registerName("isInputMuted")));
            methods[@"-setInputMuted:error:"] = DescribeMethod(
                class_getInstanceMethod(cls, sel_registerName("setInputMuted:error:")));
            methods[@"-setInputMuteStateChangeHandler:error:"] = DescribeMethod(
                class_getInstanceMethod(cls, sel_registerName("setInputMuteStateChangeHandler:error:")));
        }

        const char *imagePath = cls != Nil ? class_getImageName(cls) : NULL;
        NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
#if TARGET_OS_SIMULATOR
        NSString *runtimeEnvironment = @"simulator";
#elif TARGET_OS_OSX
        NSString *runtimeEnvironment = @"macOS host";
#elif TARGET_OS_IPHONE
        NSString *runtimeEnvironment = @"iOS device";
#else
        NSString *runtimeEnvironment = @"other Apple runtime";
#endif
        NSString *osVersion = [NSString stringWithFormat:@"%ld.%ld.%ld",
            (long)version.majorVersion, (long)version.minorVersion,
            (long)version.patchVersion];
        NSDictionary *report = @{
            @"schema": @"ipa-total-ios166-v137-avaudio-runtime-probe/1",
            @"runtimeEnvironment": runtimeEnvironment,
            @"hostOS": osVersion,
            @"frameworkPath": [NSString stringWithUTF8String:frameworkPath],
            @"classPresent": cls != Nil ? @YES : @NO,
            @"classImage": imagePath != NULL ? [NSString stringWithUTF8String:imagePath] : @"",
            @"constants": @{
                @"AVAudioApplicationInputMuteStateChangeNotification":
                    DescribeConstant(handle, "AVAudioApplicationInputMuteStateChangeNotification"),
                @"AVAudioApplicationMuteStateKey":
                    DescribeConstant(handle, "AVAudioApplicationMuteStateKey"),
            },
            @"methods": methods,
            @"actionsInvoked": @[],
            @"scope": @"host AVFAudio runtime metadata only; no API calls or device access",
        };

        NSError *jsonError = nil;
        NSData *json = [NSJSONSerialization dataWithJSONObject:report
                                                       options:NSJSONWritingPrettyPrinted
                                                         error:&jsonError];
        if (json == nil) {
            fprintf(stderr, "V137 JSON serialization failed: %s\n",
                    jsonError.localizedDescription.UTF8String);
            dlclose(handle);
            return 3;
        }
        fwrite(json.bytes, 1, json.length, stdout);
        fputc('\n', stdout);
        dlclose(handle);
        return cls != Nil ? 0 : 4;
    }
}
