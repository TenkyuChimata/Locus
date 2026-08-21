//
//  MobileGestaltAccess.h
//  Locus
//
//  Focused low-level access to MobileGestalt. Runtime questions are always
//  read-only. Persistent writes are hard-gated to the one verified build.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MobileGestaltAccess : NSObject

+ (instancetype)shared;
+ (NSString *)currentOSBuild;
+ (BOOL)japanMutationBuildSupported;

- (nullable NSDictionary *)readCachePlistWithError:(NSError **)error
    NS_SWIFT_NAME(readCachePlist());
- (nullable NSData *)readCacheDataWithError:(NSError **)error
    NS_SWIFT_NAME(readCacheData());

- (BOOL)saveCachePlist:(NSDictionary *)plist error:(NSError **)error
    NS_SWIFT_NAME(saveCachePlist(_:));
- (BOOL)restoreCacheData:(NSData *)data error:(NSError **)error
    NS_SWIFT_NAME(restoreCacheData(_:));

- (nullable NSDictionary<NSString *, id> *)runtimeAnswersForQuestions:
    (NSArray<NSString *> *)questions
    error:(NSError **)error
    NS_SWIFT_NAME(runtimeAnswers(for:));

@end

NS_ASSUME_NONNULL_END
