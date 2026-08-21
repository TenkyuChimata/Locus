//
//  BadQueryBridge.h
//  Locus
//
//  Path-based ContainerManager query derived from forcequitOS/bad_query.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BadQueryLease : NSObject

@property(nonatomic, copy, readonly) NSString *targetPath;
@property(nonatomic, readonly, getter=isActive) BOOL active;

+ (nullable instancetype)leaseForPath:(NSString *)path
                                error:(NSString * _Nullable * _Nullable)error;
- (void)invalidate;

@end

FOUNDATION_EXPORT BOOL BadQueryBridgeAvailable(void);

//
// Enumerate immediate children without opening the parent directory.
//
// This is the fsgetpath/inode-scan helper used by upstream bad_query for
// containers whose parent directory cannot normally be enumerated.
//
// Returned paths use /var/... form when fsgetpath reports /private/var/....
//
FOUNDATION_EXPORT NSArray<NSString *> * _Nullable
BadQueryListImmediateChildren(NSString *path,
                              uint64_t maxInode,
                              NSString * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
