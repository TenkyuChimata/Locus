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

// Opt-in diagnostic audit. Contains private directory identity; do not export
// wholesale. No change to token rights or to the legacy lease API.
+ (nullable instancetype)leaseForPath:(NSString *)path
                                error:(NSString * _Nullable * _Nullable)error
                                audit:(NSMutableDictionary<NSString *, id> * _Nullable)audit;
- (void)invalidateWithAudit:(NSMutableDictionary<NSString *, id> * _Nullable)audit;

@end

FOUNDATION_EXPORT BOOL WorseQueryBridgeAvailable(void);
FOUNDATION_EXPORT NSString * _Nullable WorseQueryAccessConfigurationError(void);

//
// Enumerate immediate children without opening the parent directory.
//
// The existing fsgetpath/inode discovery primitive remains independent of grants.
//
// Returned paths use /var/... form when fsgetpath reports /private/var/....
//
FOUNDATION_EXPORT NSArray<NSString *> * _Nullable
WorseQueryListImmediateChildren(NSString *path,
                              uint64_t maxInode,
                              NSString * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END

