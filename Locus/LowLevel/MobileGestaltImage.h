// SPDX-License-Identifier: GPL-3.0-only
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// Read-only snapshots of the current process, never a different on-disk dylib.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *LocusCopyMobileGestaltImage(void);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *LocusLoadedImageIdentity(NSString *path);
NS_ASSUME_NONNULL_END
