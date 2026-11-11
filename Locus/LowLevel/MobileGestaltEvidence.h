// SPDX-License-Identifier: GPL-3.0-only
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// Private input for the Swift evaluator. Never serialize this dictionary directly.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *LocusCopyMobileGestaltEvidenceFile(void);
// User-confirmed opt-in only; NO returns an unavailable observation without a lease.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *LocusCopyAuthorizedMobileGestaltEvidenceFile(BOOL userConfirmed);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *LocusCopyEvidenceDeviceIdentity(void);
NS_ASSUME_NONNULL_END
