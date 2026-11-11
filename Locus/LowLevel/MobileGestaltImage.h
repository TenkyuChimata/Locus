// SPDX-License-Identifier: GPL-3.0-only
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Copies only an already loaded system image. No queries, hooks or writes.
@interface MobileGestaltImage : NSObject
+ (nullable NSDictionary<NSString *, id> *)snapshotWithError:(NSError **)error
    NS_SWIFT_NAME(snapshot());
@end
NS_ASSUME_NONNULL_END
