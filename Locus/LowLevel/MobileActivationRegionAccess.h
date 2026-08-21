//
//  MobileActivationRegionAccess.h
//  Locus
//
//  Direct and effective MobileActivation device-region access. The backing
//  plist is always rewritten in place and its existing schema is preserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MobileActivationRegionAccess : NSObject

+ (instancetype)shared;

- (nullable NSData *)readRegionDataWithError:(NSError **)error
    NS_SWIFT_NAME(readRegionData());
- (BOOL)applyJapanRegionWithError:(NSError **)error
    NS_SWIFT_NAME(applyJapanRegion());
- (BOOL)restoreRegionData:(NSData *)data error:(NSError **)error
    NS_SWIFT_NAME(restoreRegionData(_:));

/// A concise comparison between the direct backing plist and the effective
/// MAECopyDeviceRegionInfoWithError result. This method is read-only.
- (NSDictionary<NSString *, id> *)regionDiagnostics
    NS_SWIFT_NAME(regionDiagnostics());

@end

NS_ASSUME_NONNULL_END
