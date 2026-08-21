//
//  CoreTextGB18030Service.h
//  Locus
//
//  Exact-build, process-local CoreText diagnostics for iOS/iPadOS 27
//  build 24A5390f.
//
//  This helper never edits a system file, never calls mprotect/vm_protect,
//  and never writes CoreText's dispatch_once token. The mutation experiment
//  changes exactly one writable byte in this process and restores it before
//  returning.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CoreTextGB18030Service : NSObject

/// Read-only inspection of the loaded CoreText image and the exact-build
/// GB18030 cached predicate state.
+ (nullable NSDictionary<NSString *, id> *)probeWithError:
    (NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(probe());

/// Exact-build experiment for 24A5390f.
///
/// The method:
/// 1. validates CoreText's loaded-image base/slide and __DATA_DIRTY.__bss;
/// 2. validates that the target page is already readable + writable;
/// 3. renders a baseline Taiwan-flag sample through UIKit/CoreText so Apple's
///    normal rendering path can naturally initialize the recovered
///    IsGB18030ComplianceRequired dispatch_once state;
/// 4. refuses to mutate anything unless that once token is then complete;
/// 5. saves the cached GB18030 byte;
/// 6. writes only that one byte to 0;
/// 7. renders an in-process emoji sample while the byte is 0;
/// 8. restores the original byte in @finally and verifies restoration;
/// 9. renders a post-restore control sample.
///
/// The experiment intentionally does NOT make a direct arm64e function-pointer
/// call to CoreText's private C++ predicate and never writes or resets its once
/// token. The returned dictionary includes baseline, forced-false and restored
/// PNG data. No persistent state is changed.
+ (nullable NSDictionary<NSString *, id> *)runGB18030RenderingExperimentWithError:
    (NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(runGB18030RenderingExperiment());

@end

NS_ASSUME_NONNULL_END
