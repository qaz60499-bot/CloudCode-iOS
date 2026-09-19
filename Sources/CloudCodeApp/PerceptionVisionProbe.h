#import "PerceptionProcessEvidence.h"
#import <Vision/Vision.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>

// A single controlled Vision attempt. No thumbnail, retry, provider, or backend fallback.
static NSDictionary *CCPerceptionVisionProbe(NSData *jpeg, NSString *initializer, NSString *language,
                                            BOOL cpuOnly, double pointWidth, double pointHeight, NSString *role) {
    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    NSMutableDictionary *record = [@{
        @"schemaVersion": @1, @"kind": @"vision-probe", @"initializer": initializer,
        @"processBefore": CCPerceptionProcessEvidence(role), @"jpegBytes": @(jpeg.length),
        @"screenPointWidth": @(pointWidth), @"screenPointHeight": @(pointHeight),
        @"elements": @[], @"status": @"invalid_input", @"orientation": @"up",
        @"retryCount": @0, @"cpuOnly": @(cpuOnly)
    } mutableCopy];
    if (jpeg.length == 0 || jpeg.length > 8 * 1024 * 1024 ||
        ![@[@"data", @"cgImage"] containsObject:initializer] ||
        ![@[@"en-US", @"zh-Hans"] containsObject:language]) { return record; }
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)jpeg, NULL);
    record[@"imageSourceCreated"] = @(source != NULL);
    if (!source) {
        record[@"status"] = @"imageio_source_failed";
        return record;
    }
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    record[@"imagePropertiesRead"] = @(properties != nil);
    NSNumber *width = properties[(id)kCGImagePropertyPixelWidth];
    NSNumber *height = properties[(id)kCGImagePropertyPixelHeight];
    record[@"pixelWidth"] = width ?: NSNull.null;
    record[@"pixelHeight"] = height ?: NSNull.null;
    if (width.unsignedLongValue == 0 || height.unsignedLongValue == 0 ||
        width.unsignedLongValue > 8192 || height.unsignedLongValue > 8192) {
        record[@"status"] = @"imageio_properties_failed";
        CFRelease(source);
        return record;
    }
    CGImageRef image = NULL;
    VNImageRequestHandler *handler = nil;
    if ([initializer isEqualToString:@"data"]) {
        handler = [[VNImageRequestHandler alloc] initWithData:jpeg orientation:kCGImagePropertyOrientationUp options:@{}];
        record[@"cgImageCreated"] = NSNull.null;
        record[@"bytesPerRow"] = NSNull.null;
        record[@"pixelFormat"] = @"Vision_internal_decode_not_observed";
    } else {
        image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
        record[@"cgImageCreated"] = @(image != NULL);
        if (image) {
            record[@"bytesPerRow"] = @(CGImageGetBytesPerRow(image));
            record[@"bitsPerPixel"] = @(CGImageGetBitsPerPixel(image));
            record[@"bitmapInfo"] = @(CGImageGetBitmapInfo(image));
            record[@"alphaInfo"] = @(CGImageGetAlphaInfo(image));
            record[@"cgImageWidth"] = @(CGImageGetWidth(image));
            record[@"cgImageHeight"] = @(CGImageGetHeight(image));
            handler = [[VNImageRequestHandler alloc] initWithCGImage:image orientation:kCGImagePropertyOrientationUp options:@{}];
        }
    }
    CFRelease(source);
    record[@"handlerCreated"] = @(handler != nil);
    if ([initializer isEqualToString:@"cgImage"] && !image) {
        record[@"status"] = @"imageio_cgimage_failed";
        record[@"processAfter"] = CCPerceptionProcessEvidence(role);
        record[@"latencyMS"] = @((CFAbsoluteTimeGetCurrent() - started) * 1000);
        return record;
    }
    if (!handler) {
        record[@"status"] = @"vision_handler_creation_failed";
        if (image) CGImageRelease(image);
        record[@"processAfter"] = CCPerceptionProcessEvidence(role);
        record[@"latencyMS"] = @((CFAbsoluteTimeGetCurrent() - started) * 1000);
        return record;
    }
    VNRecognizeTextRequest *request = [VNRecognizeTextRequest new];
    request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    request.recognitionLanguages = @[language];
    request.usesLanguageCorrection = NO;
    request.preferBackgroundProcessing = YES;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    request.usesCPUOnly = cpuOnly;
#pragma clang diagnostic pop
    record[@"requestRevision"] = @(request.revision);
    record[@"recognitionLevel"] = @"accurate";
    record[@"recognitionLanguages"] = request.recognitionLanguages;
    NSError *error = nil;
    record[@"visionPerformAttempted"] = @YES;
    BOOL ok = [handler performRequests:@[request] error:&error];
    if (image) CGImageRelease(image);
    record[@"errors"] = CCPerceptionErrorChain(error);
    record[@"status"] = ok && !error ? @"completed" : @"request_failed";
    NSMutableArray *elements = [NSMutableArray array];
    if (ok && !error) {
        for (VNRecognizedTextObservation *observation in request.results) {
            if (elements.count == 48) { break; }
            VNRecognizedText *candidate = [observation topCandidates:1].firstObject;
            if (!candidate) { continue; }
            CGRect box = observation.boundingBox;
            [elements addObject:@{
                @"text": [candidate.string substringToIndex:MIN(candidate.string.length, 256)],
                @"confidence": @(candidate.confidence),
                @"normalizedLowerLeft": @[@(box.origin.x), @(box.origin.y), @(box.size.width), @(box.size.height)],
                @"screenPointsTopLeft": @[@(box.origin.x * pointWidth), @((1 - CGRectGetMaxY(box)) * pointHeight),
                                          @(box.size.width * pointWidth), @(box.size.height * pointHeight)]
            }];
        }
    }
    record[@"elements"] = elements;
    record[@"processAfter"] = CCPerceptionProcessEvidence(role);
    record[@"latencyMS"] = @((CFAbsoluteTimeGetCurrent() - started) * 1000);
    return record;
}
