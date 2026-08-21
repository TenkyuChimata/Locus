//
//  MobileActivationRegionAccess.m
//  Locus
//
//  ContainerManager and inode-fallback behavior retained from the
//  MIT-licensed GestaltEdit research implementation.
//

#import "MobileActivationRegionAccess.h"
#import "BadQueryBridge.h"
#import "MobileGestaltAccess.h"

#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <stdint.h>
#import <unistd.h>

typedef char * _Nullable (*LocusSystemGroupResolver)(
    uint64_t argument0,
    const char *identifier,
    uint64_t *status
);

typedef CFDictionaryRef _Nullable (*LocusCopyDeviceRegionInfo)(
    CFErrorRef _Nullable * _Nullable error
);

static NSString * const LocusActivationFramework =
    @"/System/Library/PrivateFrameworks/"
     "MobileActivation.framework/MobileActivation";
static NSString * const LocusActivationSystemGroup =
    @"systemgroup.com.apple.mobileactivationd";
static NSString * const LocusActivationRelativePath =
    @"Library/region_info/region_info.plist";
static NSString * const LocusSystemGroupRoot =
    @"/var/containers/Shared/SystemGroup";
static NSString * const LocusMetadataHidden =
    @".com.apple.mobile_container_manager.metadata.plist";
static NSString * const LocusMetadataPlain =
    @"com.apple.mobile_container_manager.metadata.plist";
static NSString * const LocusMetadataIdentifier = @"MCMMetadataIdentifier";
static const uint64_t LocusSystemGroupInodeLimit = 2000000ULL;

static NSString *LocusCachedActivationSystemGroupPath = nil;

static NSError *LocusActivationError(NSInteger code, NSString *message)
{
    return [NSError errorWithDomain:@"io.github.tenkyuchimata.locus.mobileactivation"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString *LocusPrivateVarPath(NSString *path)
{
    return [path hasPrefix:@"/var/"]
        ? [@"/private" stringByAppendingString:path]
        : path;
}

static NSString *LocusLeaseAliasPath(NSString *path)
{
    if ([path hasPrefix:@"/private/var/"]) {
        NSString *suffix = [path substringFromIndex:@"/private/var/".length];
        return [@"/var/" stringByAppendingString:suffix];
    }
    return path;
}

static NSString * _Nullable LocusExistingKey(
    NSDictionary *dictionary,
    NSArray<NSString *> *keys
)
{
    for (NSString *key in keys) {
        if (dictionary[key] != nil) {
            return key;
        }
    }
    return nil;
}

static id _Nullable LocusFirstValue(
    NSDictionary *dictionary,
    NSArray<NSString *> *keys
)
{
    NSString *key = LocusExistingKey(dictionary, keys);
    return key ? dictionary[key] : nil;
}

static NSArray<NSString *> *LocusCountryKeys(void)
{
    return @[@"DeviceRegionCountryCode", @"CountryCode", @"Region"];
}

static NSArray<NSString *> *LocusRegionKeys(void)
{
    return @[@"DeviceRegionRegionInfo", @"RegionInfo"];
}

static NSArray<NSString *> *LocusBehaviorKeys(void)
{
    return @[@"DeviceRegionSoftwareBehaviors", @"SoftwareBehaviors"];
}

static BOOL LocusWriteAll(int fd, NSData *data)
{
    const uint8_t *bytes = data.bytes;
    NSUInteger remaining = data.length;
    while (remaining > 0) {
        ssize_t written = write(fd, bytes, remaining);
        if (written < 0 && errno == EINTR) {
            continue;
        }
        if (written <= 0) {
            return NO;
        }
        bytes += written;
        remaining -= (NSUInteger)written;
    }
    return YES;
}

static BOOL LocusRewriteDescriptor(int fd, NSData *data)
{
    return fd >= 0 && data &&
        ftruncate(fd, 0) == 0 &&
        lseek(fd, 0, SEEK_SET) >= 0 &&
        LocusWriteAll(fd, data) &&
        fsync(fd) == 0;
}

static BOOL LocusRewriteExistingActivationFile(
    NSString *path,
    NSData *replacement,
    NSInteger errorCode,
    NSError **error
)
{
    NSError *readError = nil;
    NSData *original = [NSData dataWithContentsOfFile:path
                                              options:0
                                                error:&readError];
    if (!original) {
        if (error) {
            *error = readError ?: LocusActivationError(
                errorCode,
                @"Could not read the original MobileActivation region data."
            );
        }
        return NO;
    }

    int fd = open(path.fileSystemRepresentation,
                  O_WRONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) {
        if (error) {
            *error = LocusActivationError(
                errorCode + 1,
                [NSString stringWithFormat:
                    @"Could not open region_info.plist for an in-place rewrite (errno=%d).",
                    errno]
            );
        }
        return NO;
    }

    BOOL wrote = LocusRewriteDescriptor(fd, replacement);
    int writeErrno = errno;
    if (!wrote) {
        (void)LocusRewriteDescriptor(fd, original);
        close(fd);
        if (error) {
            *error = LocusActivationError(
                errorCode + 2,
                [NSString stringWithFormat:
                    @"region_info.plist rewrite failed (errno=%d); original bytes were restored best-effort.",
                    writeErrno]
            );
        }
        return NO;
    }
    close(fd);

    NSData *verification = [NSData dataWithContentsOfFile:path];
    if (![verification isEqualToData:replacement]) {
        int rollbackFD = open(path.fileSystemRepresentation,
                              O_WRONLY | O_CLOEXEC | O_NOFOLLOW);
        if (rollbackFD >= 0) {
            (void)LocusRewriteDescriptor(rollbackFD, original);
            close(rollbackFD);
        }
        if (error) {
            *error = LocusActivationError(
                errorCode + 3,
                @"region_info.plist verification failed; original bytes were restored best-effort."
            );
        }
        return NO;
    }

    if (error) {
        *error = nil;
    }
    return YES;
}

static NSString * _Nullable LocusResolveSystemGroupNormally(
    NSNumber * _Nullable *statusOut,
    NSString * _Nullable *detailOut
)
{
    if (statusOut) {
        *statusOut = nil;
    }
    if (detailOut) {
        *detailOut = nil;
    }

    // Ensure libsystem_containermanager is loaded before resolving its private
    // symbol from RTLD_DEFAULT. This does not issue a container query.
    (void)BadQueryBridgeAvailable();
    dlerror();
    LocusSystemGroupResolver resolver =
        (LocusSystemGroupResolver)dlsym(
            RTLD_DEFAULT,
            "container_system_group_path_for_identifier"
        );
    const char *symbolError = dlerror();
    if (!resolver || symbolError) {
        if (detailOut) {
            *detailOut = [NSString stringWithFormat:
                @"ContainerManager resolver unavailable: %s",
                symbolError ?: "symbol unavailable"];
        }
        return nil;
    }

    uint64_t status = 1;
    char *pathBytes = resolver(0, LocusActivationSystemGroup.UTF8String, &status);
    if (statusOut) {
        *statusOut = @(status);
    }
    if (!pathBytes) {
        if (detailOut) {
            *detailOut = [NSString stringWithFormat:
                @"ContainerManager returned NULL (status=%llu).",
                (unsigned long long)status];
        }
        return nil;
    }

    // The private resolver's release ABI is not independently established.
    // Retaining this tiny process-lifetime string avoids an unsafe free.
    NSString *path = [NSString stringWithUTF8String:pathBytes];
    if (!path && detailOut) {
        *detailOut = @"ContainerManager returned a non-UTF-8 path.";
    }
    return path;
}

static NSString * _Nullable LocusResolveSystemGroupWithFallback(
    NSError **error
)
{
    NSString *normalPath = LocusResolveSystemGroupNormally(NULL, NULL);
    if (normalPath.length > 0) {
        if (error) {
            *error = nil;
        }
        return normalPath;
    }

    @synchronized (MobileActivationRegionAccess.class) {
        if (LocusCachedActivationSystemGroupPath.length > 0) {
            if (error) {
                *error = nil;
            }
            return [LocusCachedActivationSystemGroupPath copy];
        }
    }

    if (!BadQueryBridgeAvailable()) {
        if (error) {
            *error = LocusActivationError(
                10,
                @"bad_query is unavailable while resolving the MobileActivation SystemGroup."
            );
        }
        return nil;
    }

    NSString *listDetail = nil;
    NSArray<NSString *> *candidates = BadQueryListImmediateChildren(
        LocusSystemGroupRoot,
        LocusSystemGroupInodeLimit,
        &listDetail
    );
    if (!candidates) {
        if (error) {
            *error = LocusActivationError(
                11,
                listDetail ?: @"Could not enumerate SystemGroup candidates."
            );
        }
        return nil;
    }

    for (NSString *candidate in candidates) {
        if (![[NSUUID alloc] initWithUUIDString:candidate.lastPathComponent]) {
            continue;
        }
        for (NSString *metadataName in @[LocusMetadataHidden, LocusMetadataPlain]) {
            NSString *leasePath = [candidate stringByAppendingPathComponent:metadataName];
            NSString *readPath = LocusPrivateVarPath(leasePath);
            BadQueryLease *lease = [BadQueryLease leaseForPath:leasePath error:NULL];
            if (!lease) {
                continue;
            }
            NSData *data = [NSData dataWithContentsOfFile:readPath];
            [lease invalidate];
            if (!data) {
                continue;
            }

            id plist = [NSPropertyListSerialization propertyListWithData:data
                                                                  options:0
                                                                   format:NULL
                                                                    error:NULL];
            if (![plist isKindOfClass:NSDictionary.class]) {
                continue;
            }
            NSDictionary *metadata = (NSDictionary *)plist;
            if (![metadata[LocusMetadataIdentifier] isEqual:LocusActivationSystemGroup]) {
                continue;
            }

            @synchronized (MobileActivationRegionAccess.class) {
                LocusCachedActivationSystemGroupPath = [candidate copy];
            }
            if (error) {
                *error = nil;
            }
            return candidate;
        }
    }

    if (error) {
        *error = LocusActivationError(
            12,
            @"The bounded inode scan did not locate the MobileActivation SystemGroup."
        );
    }
    return nil;
}

static BadQueryLease * _Nullable LocusAcquireRegionLease(
    NSString * _Nullable *readPathOut,
    NSError **error
)
{
    NSString *groupPath = LocusResolveSystemGroupWithFallback(error);
    if (groupPath.length == 0) {
        return nil;
    }

    NSString *candidate = [groupPath
        stringByAppendingPathComponent:LocusActivationRelativePath];
    NSString *leasePath = LocusLeaseAliasPath(candidate);
    NSString *readPath = LocusPrivateVarPath(leasePath);
    NSString *leaseDetail = nil;
    BadQueryLease *lease = [BadQueryLease leaseForPath:leasePath
                                                 error:&leaseDetail];
    if (!lease) {
        if (error) {
            *error = LocusActivationError(
                13,
                leaseDetail ?: @"Could not acquire the region_info.plist sandbox extension."
            );
        }
        return nil;
    }

    if (readPathOut) {
        *readPathOut = readPath;
    }
    if (error) {
        *error = nil;
    }
    return lease;
}

static NSDictionary * _Nullable LocusParsePlistData(
    NSData *data,
    NSPropertyListMutabilityOptions options,
    NSPropertyListFormat *formatOut,
    NSError **error
)
{
    NSPropertyListFormat format = NSPropertyListBinaryFormat_v1_0;
    id plist = [NSPropertyListSerialization propertyListWithData:data
                                                         options:options
                                                          format:&format
                                                           error:error];
    if (![plist isKindOfClass:NSDictionary.class]) {
        return nil;
    }
    if (formatOut) {
        *formatOut = format;
    }
    return plist;
}

@implementation MobileActivationRegionAccess

+ (instancetype)shared
{
    static MobileActivationRegionAccess *access;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        access = [MobileActivationRegionAccess new];
    });
    return access;
}

- (NSData *)readRegionDataWithError:(NSError **)error
{
    NSString *readPath = nil;
    BadQueryLease *lease = LocusAcquireRegionLease(&readPath, error);
    if (!lease) {
        return nil;
    }

    @try {
        NSError *readError = nil;
        NSData *data = [NSData dataWithContentsOfFile:readPath
                                              options:NSDataReadingMappedIfSafe
                                                error:&readError];
        if (!data) {
            if (error) {
                *error = readError ?: LocusActivationError(
                    20,
                    @"Failed to read region_info.plist."
                );
            }
            return nil;
        }
        if (error) {
            *error = nil;
        }
        return [NSData dataWithData:data];
    } @finally {
        [lease invalidate];
    }
}

- (BOOL)applyJapanRegionWithError:(NSError **)error
{
    if (![MobileGestaltAccess japanMutationBuildSupported]) {
        if (error) {
            *error = LocusActivationError(
                21,
                @"MobileActivation Japan mutation is disabled outside exact build 24A5390f."
            );
        }
        return NO;
    }

    NSString *readPath = nil;
    BadQueryLease *lease = LocusAcquireRegionLease(&readPath, error);
    if (!lease) {
        return NO;
    }

    @try {
        NSData *original = [NSData dataWithContentsOfFile:readPath];
        if (!original) {
            if (error) {
                *error = LocusActivationError(22, @"Failed to read region_info.plist before mutation.");
            }
            return NO;
        }

        NSPropertyListFormat format = NSPropertyListBinaryFormat_v1_0;
        NSError *parseError = nil;
        NSDictionary *parsed = LocusParsePlistData(
            original,
            NSPropertyListMutableContainers,
            &format,
            &parseError
        );
        if (!parsed) {
            if (error) {
                *error = parseError ?: LocusActivationError(23, @"region_info.plist is not a dictionary.");
            }
            return NO;
        }

        NSMutableDictionary *region = [parsed mutableCopy];
        NSString *countryKey = LocusExistingKey(region, LocusCountryKeys());
        NSString *regionKey = LocusExistingKey(region, LocusRegionKeys());
        NSString *behaviorKey = LocusExistingKey(region, LocusBehaviorKeys());
        if (!countryKey || !regionKey || !behaviorKey) {
            if (error) {
                *error = LocusActivationError(
                    24,
                    [NSString stringWithFormat:
                        @"Unexpected region_info.plist schema; existing keys: %@",
                        [[region allKeys] componentsJoinedByString:@", "]]
                );
            }
            return NO;
        }

        region[countryKey] = @"JP";
        region[regionKey] = @"J/A";
        // MobileGestaltExtensions validates this value as CFString.
        region[behaviorKey] = @"25";

        if (format != NSPropertyListXMLFormat_v1_0 &&
            format != NSPropertyListBinaryFormat_v1_0) {
            format = NSPropertyListBinaryFormat_v1_0;
        }
        NSError *serializationError = nil;
        NSData *updated = [NSPropertyListSerialization
            dataWithPropertyList:region
                          format:format
                         options:0
                           error:&serializationError];
        if (!updated) {
            if (error) {
                *error = serializationError ?: LocusActivationError(25, @"Failed to serialize region_info.plist.");
            }
            return NO;
        }

        if (!LocusRewriteExistingActivationFile(readPath, updated, 30, error)) {
            return NO;
        }

        NSData *verificationData = [NSData dataWithContentsOfFile:readPath];
        NSDictionary *verification = verificationData
            ? LocusParsePlistData(verificationData, 0, NULL, NULL)
            : nil;
        BOOL valid = verification.count > 0 &&
            [LocusFirstValue(verification, LocusCountryKeys()) isEqual:@"JP"] &&
            [LocusFirstValue(verification, LocusRegionKeys()) isEqual:@"J/A"] &&
            [LocusFirstValue(verification, LocusBehaviorKeys()) isEqual:@"25"];
        if (!valid) {
            if (error) {
                *error = LocusActivationError(34, @"Japan region_info.plist verification failed.");
            }
            return NO;
        }

        if (error) {
            *error = nil;
        }
        return YES;
    } @finally {
        [lease invalidate];
    }
}

- (BOOL)restoreRegionData:(NSData *)data error:(NSError **)error
{
    if (![MobileGestaltAccess japanMutationBuildSupported]) {
        if (error) {
            *error = LocusActivationError(
                40,
                @"MobileActivation restore is disabled outside exact build 24A5390f."
            );
        }
        return NO;
    }
    if (![data isKindOfClass:NSData.class] || data.length == 0) {
        if (error) {
            *error = LocusActivationError(41, @"The MobileActivation backup is empty.");
        }
        return NO;
    }

    NSString *readPath = nil;
    BadQueryLease *lease = LocusAcquireRegionLease(&readPath, error);
    if (!lease) {
        return NO;
    }
    @try {
        return LocusRewriteExistingActivationFile(readPath, data, 42, error);
    } @finally {
        [lease invalidate];
    }
}

- (NSDictionary<NSString *, id> *)regionDiagnostics
{
    NSMutableDictionary<NSString *, id> *result = [NSMutableDictionary dictionary];

    NSNumber *resolverStatus = nil;
    NSString *resolverDetail = nil;
    NSString *normalGroupPath = LocusResolveSystemGroupNormally(
        &resolverStatus,
        &resolverDetail
    );
    result[@"resolverSucceeded"] = @(normalGroupPath.length > 0);
    result[@"resolverStatus"] = resolverStatus ?: NSNull.null;
    result[@"resolverDetail"] = resolverDetail ?: NSNull.null;

    NSString *readPath = nil;
    NSError *leaseError = nil;
    BadQueryLease *lease = LocusAcquireRegionLease(&readPath, &leaseError);
    result[@"resolvedBackingPath"] = readPath ?: NSNull.null;
    result[@"backingReadSucceeded"] = @NO;
    result[@"backingReadError"] = leaseError.localizedDescription ?: NSNull.null;
    result[@"backingCountryCode"] = NSNull.null;
    result[@"backingRegionInfo"] = NSNull.null;
    result[@"backingSoftwareBehaviors"] = NSNull.null;

    if (lease) {
        @try {
            NSError *readError = nil;
            NSData *data = [NSData dataWithContentsOfFile:readPath
                                                  options:NSDataReadingMappedIfSafe
                                                    error:&readError];
            NSDictionary *backing = data
                ? LocusParsePlistData(data, 0, NULL, &readError)
                : nil;
            if (backing) {
                result[@"backingReadSucceeded"] = @YES;
                result[@"backingReadError"] = NSNull.null;
                result[@"backingCountryCode"] =
                    LocusFirstValue(backing, LocusCountryKeys()) ?: NSNull.null;
                result[@"backingRegionInfo"] =
                    LocusFirstValue(backing, LocusRegionKeys()) ?: NSNull.null;
                result[@"backingSoftwareBehaviors"] =
                    LocusFirstValue(backing, LocusBehaviorKeys()) ?: NSNull.null;
            } else {
                result[@"backingReadError"] =
                    readError.localizedDescription ?: @"Could not parse the backing plist.";
            }
        } @finally {
            [lease invalidate];
        }
    }

    result[@"effectiveCallSucceeded"] = @NO;
    result[@"effectiveCountryCode"] = NSNull.null;
    result[@"effectiveRegionInfo"] = NSNull.null;
    result[@"effectiveSoftwareBehaviors"] = NSNull.null;
    result[@"effectiveErrorDomain"] = NSNull.null;
    result[@"effectiveErrorCode"] = NSNull.null;
    result[@"effectiveErrorDescription"] = NSNull.null;

    void *handle = dlopen(LocusActivationFramework.fileSystemRepresentation,
                          RTLD_LAZY | RTLD_LOCAL);
    if (!handle) {
        result[@"effectiveErrorDescription"] = [NSString stringWithFormat:
            @"Could not load MobileActivation: %s", dlerror() ?: "unknown error"];
        return [result copy];
    }

    LocusCopyDeviceRegionInfo copyRegion =
        (LocusCopyDeviceRegionInfo)dlsym(handle, "MAECopyDeviceRegionInfoWithError");
    NSString * const *countryKey =
        (NSString * const *)dlsym(handle, "kMADeviceRegionCountryCode");
    NSString * const *regionKey =
        (NSString * const *)dlsym(handle, "kMADeviceRegionRegionInfo");
    NSString * const *behaviorKey =
        (NSString * const *)dlsym(handle, "kMADeviceRegionSoftwareBehaviors");
    if (!copyRegion || !countryKey || !*countryKey ||
        !regionKey || !*regionKey || !behaviorKey || !*behaviorKey) {
        result[@"effectiveErrorDescription"] =
            @"Required MobileActivation device-region symbols are unavailable.";
        dlclose(handle);
        return [result copy];
    }

    CFErrorRef apiErrorRef = NULL;
    CFDictionaryRef dictionaryRef = copyRegion(&apiErrorRef);
    NSError *apiError = apiErrorRef ? (__bridge NSError *)apiErrorRef : nil;
    if (dictionaryRef && CFGetTypeID(dictionaryRef) == CFDictionaryGetTypeID()) {
        NSDictionary *dictionary = (__bridge NSDictionary *)dictionaryRef;
        result[@"effectiveCallSucceeded"] = @YES;
        result[@"effectiveCountryCode"] = dictionary[*countryKey] ?: NSNull.null;
        result[@"effectiveRegionInfo"] = dictionary[*regionKey] ?: NSNull.null;
        result[@"effectiveSoftwareBehaviors"] = dictionary[*behaviorKey] ?: NSNull.null;
    }
    if (apiError) {
        result[@"effectiveErrorDomain"] = apiError.domain ?: NSNull.null;
        result[@"effectiveErrorCode"] = @(apiError.code);
        result[@"effectiveErrorDescription"] =
            apiError.localizedDescription ?: NSNull.null;
    }

    if (dictionaryRef) {
        CFRelease(dictionaryRef);
    }
    // The ownership of this private out-error is not independently known;
    // match the verified implementation and do not release apiErrorRef.
    dlclose(handle);

    return [result copy];
}

@end
