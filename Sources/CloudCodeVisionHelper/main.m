#import <Foundation/Foundation.h>
#import <Vision/Vision.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import <math.h>
#import <stdio.h>
#import <string.h>
#import <unistd.h>
#import "../CloudCodeApp/PerceptionVisionProbe.h"

extern void *objc_autoreleasePoolPush(void);

static NSString * const CloudCodeVisionProtocolMarker = @"cloudcode-vision-helper-protocol=1";
static const NSUInteger CloudCodeVisionMaxInputBytes = 8 * 1024 * 1024;
static const NSUInteger CloudCodeVisionMaxOutputBytes = 64 * 1024;

static void CloudCodeVisionStage(const char *stage, NSError *error)
{
    fprintf(stderr, "vision-helper: stage=%s pid=%d ppid=%d uid=%d time=%.3f errorDomain=%s errorCode=%ld\n",
        stage, getpid(), getppid(), getuid(), CFAbsoluteTimeGetCurrent(),
        error.domain.UTF8String ?: "none", (long)error.code);
}

static void CloudCodePrintJSON(NSDictionary *payload)
{
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&error];
    if (!data || error || data.length == 0 || data.length > CloudCodeVisionMaxOutputBytes) {
        fprintf(stderr, "vision-helper: JSON serialization failed or exceeded output bound\n");
        return;
    }
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    CloudCodeVisionStage("stdout-json-completed", nil);
}

static BOOL CloudCodeIsBoundedTempJPEG(NSString *path)
{
    NSString *normalized = [path isKindOfClass:NSString.class] ? path.stringByStandardizingPath : nil;
    if (normalized.length == 0) { return NO; }
    NSString *filename = normalized.lastPathComponent;
    NSString *parent = normalized.stringByDeletingLastPathComponent;
    BOOL appContainer = [normalized hasPrefix:@"/var/mobile/Containers/Data/Application/"]
        || [normalized hasPrefix:@"/private/var/mobile/Containers/Data/Application/"];
    return appContainer
        && [parent.lastPathComponent isEqualToString:@"tmp"]
        && [filename hasPrefix:@"CloudCode-GUI-OCR-"]
        && [[filename.pathExtension lowercaseString] isEqualToString:@"jpg"];
}

static NSArray<NSString *> *CloudCodePreferredLanguages(VNRequestTextRecognitionLevel level)
{
    VNRecognizeTextRequest *probe = [[VNRecognizeTextRequest alloc] init];
    probe.recognitionLevel = level;
    NSError *error = nil;
    NSArray<NSString *> *supported = [probe supportedRecognitionLanguagesAndReturnError:&error] ?: @[];
    if (error) { return @[]; }
    NSMutableArray<NSString *> *preferred = [NSMutableArray array];
    for (NSString *language in @[@"zh-Hans", @"en-US"]) {
        if ([supported containsObject:language]) { [preferred addObject:language]; }
    }
    return preferred;
}

static VNRecognizeTextRequest *CloudCodeMakeRequest(BOOL cpuOnly, BOOL forceAccurate, NSString **levelName)
{
    VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] init];
    request.usesLanguageCorrection = NO;
    request.minimumTextHeight = 0.020f;
    request.preferBackgroundProcessing = YES;

    NSArray<NSString *> *fastLanguages = CloudCodePreferredLanguages(VNRequestTextRecognitionLevelFast);
    if (!forceAccurate && [fastLanguages containsObject:@"zh-Hans"]) {
        request.recognitionLevel = VNRequestTextRecognitionLevelFast;
        request.recognitionLanguages = fastLanguages;
        if (levelName) { *levelName = @"fast"; }
    } else {
        request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
        NSArray<NSString *> *accurateLanguages = CloudCodePreferredLanguages(VNRequestTextRecognitionLevelAccurate);
        if (accurateLanguages.count > 0) {
            request.recognitionLanguages = accurateLanguages;
        } else if (@available(iOS 16.0, *)) {
            request.automaticallyDetectsLanguage = YES;
        }
        if (levelName) { *levelName = @"accurate"; }
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    request.usesCPUOnly = cpuOnly;
#pragma clang diagnostic pop
    return request;
}

static NSError *CloudCodePerformOCR(CGImageRef image, VNRecognizeTextRequest **requestOut, BOOL cpuOnly, BOOL forceAccurate, NSString **levelName)
{
    VNRecognizeTextRequest *request = CloudCodeMakeRequest(cpuOnly, forceAccurate, levelName);
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
    NSError *error = nil;
    CloudCodeVisionStage("vision-request-start", nil);
    BOOL ok = [handler performRequests:@[request] error:&error];
    CloudCodeVisionStage("vision-request-completed", error);
    if (requestOut) { *requestOut = request; }
    if (ok && !error) { return nil; }
    return error ?: [NSError errorWithDomain:@"CloudCodeVisionHelper" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Vision request failed without NSError"}];
}

static NSError *CloudCodePerformFastFallbackOCR(CGImageRef image, VNRecognizeTextRequest **requestOut, NSString **levelName)
{
    VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] init];
    request.recognitionLevel = VNRequestTextRecognitionLevelFast;
    request.usesLanguageCorrection = NO;
    request.minimumTextHeight = 0.012f;
    request.preferBackgroundProcessing = YES;
    if (@available(iOS 16.0, *)) { request.automaticallyDetectsLanguage = YES; }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    request.usesCPUOnly = YES;
#pragma clang diagnostic pop
    if (levelName) { *levelName = @"fast"; }
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
    NSError *error = nil;
    CloudCodeVisionStage("vision-fast-fallback-start", nil);
    BOOL ok = [handler performRequests:@[request] error:&error];
    CloudCodeVisionStage("vision-fast-fallback-completed", error);
    if (requestOut) { *requestOut = request; }
    if (ok && !error) { return nil; }
    return error ?: [NSError errorWithDomain:@"CloudCodeVisionHelper" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Fast fallback Vision request failed without NSError"}];
}

static int CloudCodeOCRFile(NSString *path, NSUInteger maximumElements, BOOL forceAccurate)
{
    CFAbsoluteTime startedAt = CFAbsoluteTimeGetCurrent();
    if (!CloudCodeIsBoundedTempJPEG(path)) {
        fprintf(stderr, "vision-helper: rejected input path outside app tmp boundary\n");
        return 71;
    }

    NSError *readError = nil;
    NSData *jpeg = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:&readError];
    if (!jpeg || jpeg.length == 0 || jpeg.length > CloudCodeVisionMaxInputBytes) {
        fprintf(stderr, "vision-helper: bounded JPEG read failed: %s\n", readError.localizedDescription.UTF8String ?: "invalid-or-oversized-input");
        return 71;
    }

    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)jpeg, NULL);
    CGImageRef image = source ? CGImageSourceCreateImageAtIndex(source, 0, NULL) : NULL;
    if (source) { CFRelease(source); }
    if (!image) {
        fprintf(stderr, "vision-helper: JPEG could not be decoded to CGImage\n");
        return 71;
    }

    size_t pixelWidth = MAX((size_t)1, CGImageGetWidth(image));
    size_t pixelHeight = MAX((size_t)1, CGImageGetHeight(image));
    NSUInteger boundedMaximum = MIN(MAX(maximumElements, (NSUInteger)1), (NSUInteger)48);

    NSString *recognitionLevelName = nil;
    VNRecognizeTextRequest *request = nil;
    // This helper exists specifically to provide a normal, non-root Vision execution context when
    // the host App cannot finish OCR while backgrounded. Do not first enter GPU/ANE/CoreVideo paths
    // that already failed on-device with CoreVideo -6662 / CoreML code 0 and then repeat the work.
    NSError *primaryError = CloudCodePerformOCR(image, &request, YES, forceAccurate, &recognitionLevelName);
    BOOL cpuFallbackUsed = NO;
    NSError *finalError = primaryError;
    NSString *backendName = @"vision_helper_public_api";

    if (primaryError) {
        // A fresh helper process is valuable only if it does materially less work after the same
        // public Vision pipeline fails. Retry once with Apple's fast recognizer on an ImageIO
        // thumbnail. This reduces both model and image memory pressure and specifically gives
        // CoreVideo allocation failures (-6662) a cheaper path instead of repeating accurate OCR.
        CGImageSourceRef fallbackSource = CGImageSourceCreateWithData((__bridge CFDataRef)jpeg, NULL);
        NSDictionary *thumbnailOptions = @{
            (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
            (id)kCGImageSourceThumbnailMaxPixelSize: @640,
            (id)kCGImageSourceCreateThumbnailWithTransform: @YES
        };
        CGImageRef fallbackImage = fallbackSource ? CGImageSourceCreateThumbnailAtIndex(fallbackSource, 0, (__bridge CFDictionaryRef)thumbnailOptions) : NULL;
        if (fallbackSource) { CFRelease(fallbackSource); }
        if (fallbackImage) {
            cpuFallbackUsed = YES;
            backendName = @"vision_helper_public_api_fast_thumbnail_fallback";
            finalError = CloudCodePerformFastFallbackOCR(fallbackImage, &request, &recognitionLevelName);
            CGImageRelease(fallbackImage);
        }
    }

    if (finalError) {
        NSDictionary *failure = @{
            @"status": @"unavailable_request_failed",
            @"screenPointWidth": @(pixelWidth),
            @"screenPointHeight": @(pixelHeight),
            @"latencyMS": @((NSInteger)MAX(0.0, (CFAbsoluteTimeGetCurrent() - startedAt) * 1000.0)),
            @"recognitionLevel": recognitionLevelName ?: @"unknown",
            @"backend": backendName,
            @"cpuFallbackUsed": @(cpuFallbackUsed),
            @"errorDomain": finalError.domain ?: @"",
            @"errorCode": @(finalError.code),
            @"primaryErrorDomain": primaryError.domain ?: @"",
            @"primaryErrorCode": @(primaryError.code),
            @"elements": @[]
        };
        CloudCodePrintJSON(failure);
        CGImageRelease(image);
        return 0;
    }

    NSMutableArray<NSDictionary *> *elements = [NSMutableArray arrayWithCapacity:boundedMaximum];
    NSMutableArray<NSString *> *textParts = [NSMutableArray array];
    NSUInteger textCharacters = 0;
    NSArray<VNRecognizedTextObservation *> *observations = request.results ?: @[];
    observations = [observations sortedArrayUsingComparator:^NSComparisonResult(VNRecognizedTextObservation *lhs, VNRecognizedTextObservation *rhs) {
        CGFloat lhsTop = 1.0 - CGRectGetMaxY(lhs.boundingBox);
        CGFloat rhsTop = 1.0 - CGRectGetMaxY(rhs.boundingBox);
        if (fabs(lhsTop - rhsTop) > 0.015) {
            return lhsTop < rhsTop ? NSOrderedAscending : NSOrderedDescending;
        }
        if (lhs.boundingBox.origin.x == rhs.boundingBox.origin.x) { return NSOrderedSame; }
        return lhs.boundingBox.origin.x < rhs.boundingBox.origin.x ? NSOrderedAscending : NSOrderedDescending;
    }];

    for (VNRecognizedTextObservation *observation in observations) {
        if (elements.count >= boundedMaximum) { break; }
        VNRecognizedText *candidate = [observation topCandidates:1].firstObject;
        if (!candidate || candidate.confidence < 0.12f) { continue; }
        NSString *cleaned = [[candidate.string stringByReplacingOccurrencesOfString:@"\n" withString:@" "]
            stringByReplacingOccurrencesOfString:@"\r" withString:@" "];
        cleaned = [cleaned stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (cleaned.length == 0) { continue; }
        NSString *text = cleaned.length > 120 ? [cleaned substringToIndex:120] : cleaned;
        CGRect box = observation.boundingBox;
        double minX = MAX(0.0, MIN(1.0, box.origin.x));
        double minY = MAX(0.0, MIN(1.0, box.origin.y));
        double maxX = MAX(0.0, MIN(1.0, CGRectGetMaxX(box)));
        double maxY = MAX(0.0, MIN(1.0, CGRectGetMaxY(box)));
        if (maxX <= minX || maxY <= minY) { continue; }
        double x = minX * (double)pixelWidth;
        double y = (1.0 - maxY) * (double)pixelHeight;
        double width = (maxX - minX) * (double)pixelWidth;
        double height = (maxY - minY) * (double)pixelHeight;
        [elements addObject:@{
            @"text": text,
            @"confidence": @(round((double)candidate.confidence * 1000.0) / 1000.0),
            @"x": @(round(x * 10.0) / 10.0),
            @"y": @(round(y * 10.0) / 10.0),
            @"width": @(round(width * 10.0) / 10.0),
            @"height": @(round(height * 10.0) / 10.0)
        }];
        if (textCharacters < 4096) {
            NSUInteger remaining = 4096 - textCharacters;
            NSString *part = text.length > remaining ? [text substringToIndex:remaining] : text;
            [textParts addObject:part];
            textCharacters += part.length + 3;
        }
    }

    NSDictionary *payload = @{
        @"status": elements.count > 0 ? @"recognized" : @"available_empty",
        @"screenPointWidth": @(pixelWidth),
        @"screenPointHeight": @(pixelHeight),
        @"latencyMS": @((NSInteger)MAX(0.0, (CFAbsoluteTimeGetCurrent() - startedAt) * 1000.0)),
        @"recognitionLevel": recognitionLevelName ?: @"unknown",
        @"backend": backendName,
        @"cpuFallbackUsed": @(cpuFallbackUsed),
        @"visibleText": [textParts componentsJoinedByString:@" | "],
        @"elements": elements
    };
    CloudCodePrintJSON(payload);
    CGImageRelease(image);
    return 0;
}

static int CloudCodeRunOneShotVisionCommand(int argc, char *argv[])
{
    // OCR must run as the ordinary mobile user. Do not declare this binary in TSRootBinaries:
    // that list is reserved for helpers that need TrollStore's special root-helper permissions.
    // Root/persona-99 Vision was proven unstable on iOS 16.6, so fail closed on elevation.
    if (getuid() == 0 || geteuid() == 0) {
        fprintf(stderr, "vision-helper: root execution is forbidden\n");
        return 77;
    }
    if (argc < 2) {
        fprintf(stderr, "vision-helper: missing command\n");
        return 64;
    }
    NSString *command = [NSString stringWithUTF8String:argv[1]];
    if ([command isEqualToString:@"probe-ocr-file"]) {
        if (argc != 8) { return 64; }
        NSString *path = [NSString stringWithUTF8String:argv[2]];
        if (!CloudCodeIsBoundedTempJPEG(path)) { return 71; }
        // Process identity is written synchronously before the first Vision call so pre-/post-main
        // deaths can be distinguished even when no OCR result survives.
        NSData *entry = [NSJSONSerialization dataWithJSONObject:CCPerceptionProcessEvidence(@"vision_helper") options:0 error:nil];
        if (entry) { fwrite(entry.bytes, 1, entry.length, stderr); fputc('\n', stderr); }
        NSData *jpeg = [NSData dataWithContentsOfFile:path options:0 error:nil];
        NSDictionary *result = CCPerceptionVisionProbe(jpeg, [NSString stringWithUTF8String:argv[3]],
            [NSString stringWithUTF8String:argv[4]], atoi(argv[5]) != 0, atof(argv[6]), atof(argv[7]), @"vision_helper");
        CloudCodePrintJSON(result);
        return 0;
    }
    if ([command isEqualToString:@"probe"]) {
        fprintf(stdout, "%s\n", CloudCodeVisionProtocolMarker.UTF8String);
        return 0;
    }
    if ([command isEqualToString:@"ocr-file"]) {
        if (argc < 4) {
            fprintf(stderr, "vision-helper: ocr-file requires path and maximumElements\n");
            return 64;
        }
        NSString *path = [NSString stringWithUTF8String:argv[2]];
        NSInteger parsed = [[NSString stringWithUTF8String:argv[3]] integerValue];
        NSUInteger maximumElements = (NSUInteger)MIN(MAX(parsed, 1), 48);
        BOOL forceAccurate = argc >= 5 && strcmp(argv[4], "accurate") == 0;
        return CloudCodeOCRFile(path, maximumElements, forceAccurate);
    }
    fprintf(stderr, "vision-helper: unsupported command\n");
    return 64;
}

int main(int argc, char *argv[])
{
    // Vision/CoreML/CoreVideo may retain process-global objects whose autorelease teardown blocks
    // after the final OCR JSON has already been produced on the TrollStore iOS 16.6 device. Match
    // the root/GUI one-shot contract: make observable writes synchronous, keep one process-lifetime
    // pool, and terminate without ARC/Foundation/Vision teardown after dispatch.
    (void)setvbuf(stdout, NULL, _IONBF, 0);
    (void)setvbuf(stderr, NULL, _IONBF, 0);
    (void)objc_autoreleasePoolPush();
    CloudCodeVisionStage("startup", nil);
    int result = CloudCodeRunOneShotVisionCommand(argc, argv);
    CloudCodeVisionStage("exit", nil);
    _exit(result);
}
