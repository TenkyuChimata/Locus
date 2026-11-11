//
//  WorseQueryBridge.h
//  Locus
//
//  Scoped leases for the forcequitOS/worse_query App Group query.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WorseQueryLease : NSObject

@property(nonatomic, copy, readonly) NSString *targetPath;
@property(nonatomic, readonly, getter=isActive) BOOL active;

+ (nullable instancetype)leaseForPath:(NSString *)path
                                error:(NSString * _Nullable * _Nullable)error;
- (void)invalidate;

@end

FOUNDATION_EXPORT BOOL WorseQueryBridgeAvailable(void);
FOUNDATION_EXPORT NSString * _Nullable WorseQueryAccessConfigurationError(void);

NS_ASSUME_NONNULL_END
