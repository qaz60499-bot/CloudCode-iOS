/*
 * V142 independent native dlopen ABI control (NOT AVAudioApplication).
 * A deliberately unique class name prevents system same-class conflicts.
 * Compile with -DV142_BAD_ABI for the negative ObjC method-encoding case.
 * This class is not an AVFAudio behavioral replacement.
 */
#import <Foundation/Foundation.h>
@interface IPACompatV142ProbeClass : NSObject
+ (instancetype)sharedInstance;
+ (void)requestRecordPermissionWithCompletionHandler:(void (^)(BOOL))response;
#ifndef V142_BAD_ABI
@property(nonatomic, readonly) NSInteger recordPermission;
#else
@property(nonatomic, readonly) int recordPermission;
#endif
- (BOOL)setInputMuted:(BOOL)muted error:(NSError **)error;
- (BOOL)isInputMuted;
- (BOOL)setInputMuteStateChangeHandler:(void (^)(BOOL))handler error:(NSError **)error;
@end

@implementation IPACompatV142ProbeClass
+ (instancetype)sharedInstance { return nil; }
+ (void)requestRecordPermissionWithCompletionHandler:(void (^)(BOOL))response { (void)response; }
#ifndef V142_BAD_ABI
- (NSInteger)recordPermission { return 0; }
#else
- (int)recordPermission { return 0; }
#endif
- (BOOL)setInputMuted:(BOOL)muted error:(NSError **)error {
    (void)muted; (void)error; return NO;
}
- (BOOL)isInputMuted { return NO; } // Unique ABI fixture only, not audio behavior.
- (BOOL)setInputMuteStateChangeHandler:(void (^)(BOOL))handler error:(NSError **)error {
    (void)handler; (void)error; return NO;
}
@end
