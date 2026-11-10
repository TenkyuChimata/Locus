//
//  MobileGestaltAccess.h
//  Locus
//
//  Focused low-level access to MobileGestalt. Runtime questions are always
//  read-only. Japan Region validates its data layout before persistent writes.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MobileGestaltAccess : NSObject

+ (instancetype)shared;
+ (NSString *)currentOSBuild;
- (NSDictionary<NSString *, id> *)cacheWriteAccessStatus
    NS_SWIFT_NAME(cacheWriteAccessStatus());
- (BOOL)replaceCacheData:(NSData *)expected withData:(NSData *)replacement error:(NSError **)error
    NS_SWIFT_NAME(replaceCacheData(_:with:));

- (nullable NSDictionary *)readCachePlistWithError:(NSError **)error
    NS_SWIFT_NAME(readCachePlist());
- (nullable NSData *)readCacheDataWithError:(NSError **)error
    NS_SWIFT_NAME(readCacheData());

- (nullable NSDictionary<NSString *, id> *)runtimeAnswersForQuestions:
    (NSArray<NSString *> *)questions
    error:(NSError **)error
    NS_SWIFT_NAME(runtimeAnswers(for:));

@end

NS_ASSUME_NONNULL_END
