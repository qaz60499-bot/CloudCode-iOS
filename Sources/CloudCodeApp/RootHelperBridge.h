#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSInteger CloudCodeSpawnRootHelper(NSString *path, NSArray<NSString *> *arguments);
FOUNDATION_EXPORT NSInteger CloudCodeSpawnRootHelperWithOutput(NSString *path, NSArray<NSString *> *arguments, NSString * _Nullable * _Nullable diagnostic);
FOUNDATION_EXPORT NSInteger CloudCodeSpawnHelperWithOutput(NSString *path, NSArray<NSString *> *arguments, BOOL asRoot, NSTimeInterval timeout, NSString * _Nullable * _Nullable diagnostic);

NS_ASSUME_NONNULL_END
