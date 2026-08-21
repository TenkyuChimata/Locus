//
//  DeviceTreeAccess.h
//  Locus
//
//  Read-only IOKit access. No method in this interface can write IORegistry.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DeviceTreeAccess : NSObject

+ (instancetype)shared;

- (nullable NSDictionary<NSString *, id> *)chosenPropertiesForNames:
    (NSArray<NSString *> *)names
    error:(NSError **)error
    NS_SWIFT_NAME(chosenProperties(for:));

- (nullable NSDictionary<NSString *, id> *)propertiesAtPath:(NSString *)path
    error:(NSError **)error
    NS_SWIFT_NAME(properties(at:));

@end

NS_ASSUME_NONNULL_END
