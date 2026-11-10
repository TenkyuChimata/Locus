//
//  MobileActivationRegionAccess.m
//  Locus
//
//  ContainerManager and inode-fallback behavior retained from the
//  MIT-licensed GestaltEdit research implementation.
//

#import "MobileActivationRegionAccess.h"
#import "WorseQueryBridge.h"

#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <stdint.h>
#import <sys/stat.h>
#import <unistd.h>

typedef char * _Nullable (*LocusSystemGroupResolver)(
    uint64_t argument0,
    const char *identifier,
    uint64_t *status
);

typedef CFDictionaryRef _Nullable (*LocusCopyDeviceRegionInfo)(
    CFErrorRef _Nullable * _Nullable error
);

typedef const char * _Nullable (*LocusContainerErrorDescription)(uint64_t status);

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

// Diagnostics retain phases and error domains/codes, never metadata contents,
// sandbox tokens or per-container UUIDs. A denied stat is not absence evidence.
static NSString *LocusSafeDiagnosticText(NSString *text)
{
    NSRegularExpression *uuid = [NSRegularExpression regularExpressionWithPattern:
        @"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
        options:0 error:NULL];
    return [uuid stringByReplacingMatchesInString:text options:0
        range:NSMakeRange(0, text.length) withTemplate:@"<UUID>"];
}

static NSDictionary *LocusErrorDetails(NSError *error, NSString *stage)
{
    NSMutableArray *chain = [NSMutableArray array];
    NSError *current = error;
    for (NSUInteger depth = 0; current && depth < 4; depth++) {
        [chain addObject:@{@"domain": current.domain, @"code": @(current.code)}];
        id underlying = current.userInfo[NSUnderlyingErrorKey];
        current = [underlying isKindOfClass:NSError.class] ? underlying : nil;
    }
    return @{@"stage": stage, @"errors": chain};
}

static void LocusRecordFailure(NSMutableDictionary *diagnostics,
                               NSString *stage, NSError *error)
{
    diagnostics[@"backingStage"] = stage;
    diagnostics[@"backingErrorDetails"] = LocusErrorDetails(error, stage);
}

static NSDictionary *LocusPathState(NSString *path)
{
    struct stat state;
    if (lstat(path.fileSystemRepresentation, &state) != 0) {
        int code = errno;
        return @{@"state": @"stat-failed; existence unknown",
                 @"domain": NSPOSIXErrorDomain, @"code": @(code)};
    }
    NSString *kind = S_ISREG(state.st_mode) ? @"regular-file" :
        S_ISDIR(state.st_mode) ? @"directory" :
        S_ISLNK(state.st_mode) ? @"symlink" : @"other";
    return @{@"state": kind};
}

static void LocusIncrement(NSMutableDictionary *summary, NSString *key)
{
    summary[key] = @([summary[key] unsignedIntegerValue] + 1);
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
    (void)WorseQueryBridgeAvailable();
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
    NSError **error,
    NSMutableDictionary *diagnostics
)
{
    NSNumber *status = nil;
    NSString *detail = nil;
    NSString *normalPath = LocusResolveSystemGroupNormally(&status, &detail);
    diagnostics[@"resolverSucceeded"] = @(normalPath.length > 0);
    diagnostics[@"resolverStatus"] = status ?: NSNull.null;
    diagnostics[@"resolverDetail"] = detail ?: NSNull.null;
    // Ask this loaded ContainerManager for its enum label when available.
    // Never interpret its private status as errno or an MAE NSError code.
    NSString *statusName = nil;
    if (diagnostics && status) {
        LocusContainerErrorDescription describe = (LocusContainerErrorDescription)
            dlsym(RTLD_DEFAULT, "container_get_error_description");
        const char *name = describe ? describe(status.unsignedLongLongValue) : NULL;
        if (name) statusName = [NSString stringWithUTF8String:name];
    }
    diagnostics[@"resolverStatusName"] = statusName ?: NSNull.null;
    NSMutableDictionary *discovery = [NSMutableDictionary dictionaryWithDictionary:@{
        @"inodeLimit": @(LocusSystemGroupInodeLimit),
        @"source": @"unresolved",
        @"candidateCount": @0, @"uuidCandidateCount": @0,
        @"metadataLeaseFailures": @0, @"metadataReadFailures": @0,
        @"metadataParseFailures": @0, @"metadataIdentifierMismatches": @0
    }];
    diagnostics[@"discovery"] = discovery;
    if (normalPath.length > 0) {
        discovery[@"source"] = @"normal-resolver";
        if (error) {
            *error = nil;
        }
        return normalPath;
    }

    @synchronized (MobileActivationRegionAccess.class) {
        if (LocusCachedActivationSystemGroupPath.length > 0) {
            discovery[@"source"] = @"cached-metadata-match";
            if (error) {
                *error = nil;
            }
            return [LocusCachedActivationSystemGroupPath copy];
        }
    }

    NSString *configurationError = WorseQueryAccessConfigurationError();
    if (configurationError) {
        LocusRecordFailure(diagnostics, @"access-configuration",
                           LocusActivationError(10, configurationError));
        if (error) {
            *error = LocusActivationError(
                10,
                configurationError
            );
        }
        return nil;
    }

    NSString *listDetail = nil;
    NSArray<NSString *> *candidates = WorseQueryListImmediateChildren(
        LocusSystemGroupRoot,
        LocusSystemGroupInodeLimit,
        &listDetail
    );
    if (!candidates) {
        LocusRecordFailure(diagnostics, @"inode-enumeration",
            LocusActivationError(11, listDetail ?: @"SystemGroup enumeration failed."));
        if (error) {
            *error = LocusActivationError(
                11,
                listDetail ?: @"Could not enumerate SystemGroup candidates."
            );
        }
        return nil;
    }

    discovery[@"candidateCount"] = @(candidates.count);
    for (NSString *candidate in candidates) {
        if (![[NSUUID alloc] initWithUUIDString:candidate.lastPathComponent]) {
            continue;
        }
        LocusIncrement(discovery, @"uuidCandidateCount");
        for (NSString *metadataName in @[LocusMetadataHidden, LocusMetadataPlain]) {
            NSString *leasePath = [candidate stringByAppendingPathComponent:metadataName];
            NSString *readPath = LocusPrivateVarPath(leasePath);
            NSString *leaseDetail = nil;
            WorseQueryLease *lease = [WorseQueryLease leaseForPath:candidate error:&leaseDetail];
            if (!lease) {
                LocusIncrement(discovery, @"metadataLeaseFailures");
                discovery[@"lastMetadataFailure"] = LocusErrorDetails(
                    LocusActivationError(13, leaseDetail ?: @"Metadata lease failed."), @"metadata-lease");
                discovery[@"lastMetadataLeaseDetail"] = LocusSafeDiagnosticText(leaseDetail ?: @"Unavailable");
                continue;
            }
            NSError *metadataError = nil;
            NSData *data = nil;
            @try {
                data = [NSData dataWithContentsOfFile:readPath options:0 error:&metadataError];
            } @finally {
                [lease invalidate];
            }
            if (!data) {
                LocusIncrement(discovery, @"metadataReadFailures");
                discovery[@"lastMetadataFailure"] = LocusErrorDetails(
                    metadataError ?: LocusActivationError(20, @"Metadata read failed."), @"metadata-read");
                continue;
            }

            id plist = [NSPropertyListSerialization propertyListWithData:data
                                                                  options:0
                                                                   format:NULL
                                                                    error:&metadataError];
            if (![plist isKindOfClass:NSDictionary.class]) {
                LocusIncrement(discovery, @"metadataParseFailures");
                discovery[@"lastMetadataFailure"] = LocusErrorDetails(
                    metadataError ?: LocusActivationError(23, @"Metadata is not a dictionary."), @"metadata-parse");
                continue;
            }
            NSDictionary *metadata = (NSDictionary *)plist;
            if (![metadata[LocusMetadataIdentifier] isEqual:LocusActivationSystemGroup]) {
                LocusIncrement(discovery, @"metadataIdentifierMismatches");
                continue;
            }

            @synchronized (MobileActivationRegionAccess.class) {
                LocusCachedActivationSystemGroupPath = [candidate copy];
            }
            discovery[@"source"] = @"inode-metadata-match";
            if (error) {
                *error = nil;
            }
            return candidate;
        }
    }

    LocusRecordFailure(diagnostics, @"systemgroup-discovery",
        LocusActivationError(12, @"No matching metadata in the bounded scan; absence is not established."));
    if (error) {
        *error = LocusActivationError(
            12,
            @"The bounded inode scan did not locate the MobileActivation SystemGroup."
        );
    }
    return nil;
}

static WorseQueryLease * _Nullable LocusAcquireRegionLease(
    NSString * _Nullable *readPathOut,
    NSError **error,
    NSMutableDictionary *diagnostics
)
{
    NSString *groupPath = LocusResolveSystemGroupWithFallback(error, diagnostics);
    if (groupPath.length == 0) {
        return nil;
    }

    NSString *candidate = [groupPath
        stringByAppendingPathComponent:LocusActivationRelativePath];
    NSString *leasePath = LocusLeaseAliasPath(candidate);
    NSString *readPath = LocusPrivateVarPath(leasePath);
    // Keep the resolved path available even if acquiring the lease fails.
    if (readPathOut) *readPathOut = readPath;
    if (diagnostics) {
        diagnostics[@"regionLeaseTargetState"] = LocusPathState(leasePath.stringByDeletingLastPathComponent);
    }
    NSString *leaseDetail = nil;
    WorseQueryLease *lease = [WorseQueryLease leaseForPath:leasePath.stringByDeletingLastPathComponent
                                                 error:&leaseDetail];
    if (!lease) {
        LocusRecordFailure(diagnostics, @"region-lease",
            LocusActivationError(13, leaseDetail ?: @"Region lease failed."));
        @synchronized (MobileActivationRegionAccess.class) {
            LocusCachedActivationSystemGroupPath = nil;
        }
        if (error) {
            *error = LocusActivationError(
                13,
                leaseDetail ?: @"Could not acquire the region_info.plist sandbox extension."
            );
        }
        return nil;
    }

    diagnostics[@"backingStage"] = @"region-lease-acquired";
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
        if (plist && error) {
            *error = LocusActivationError(23, @"region_info.plist is not a dictionary.");
        }
        return nil;
    }
    if (formatOut) {
        *formatOut = format;
    }
    return plist;
}

static BOOL LocusValidateRegionSchema(NSDictionary *region, NSError **error)
{
    NSArray *families = @[LocusCountryKeys(), LocusRegionKeys(), LocusBehaviorKeys()];
    for (NSArray *keys in families) {
        NSUInteger count = 0;
        for (NSString *key in keys) if (region[key]) count++;
        if (count != 1 || ![LocusFirstValue(region, keys) isKindOfClass:NSString.class]) {
            if (error) *error = LocusActivationError(24, @"Unsupported MobileActivation schema: require one existing string field for country, region and SoftwareBehaviors; ambiguous aliases are refused.");
            return NO;
        }
    }
    NSString *country = LocusFirstValue(region, LocusCountryKeys());
    NSString *info = LocusFirstValue(region, LocusRegionKeys());
    NSString *behavior = LocusFirstValue(region, LocusBehaviorKeys());
    BOOL countryValid = [country rangeOfString:@"^[A-Z]{2}$" options:NSRegularExpressionSearch].location != NSNotFound;
    BOOL infoValid = [info rangeOfString:@"^[A-Z0-9]{1,4}/[A-Z]$" options:NSRegularExpressionSearch].location != NSNotFound;
    BOOL hexadecimal = [behavior hasPrefix:@"0x"] || [behavior hasPrefix:@"0X"];
    NSString *digits = hexadecimal ? [behavior substringFromIndex:2] : behavior;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:hexadecimal ? @"0123456789abcdefABCDEF" : @"0123456789"];
    unsigned long long number = 0;
    NSScanner *scanner = [NSScanner scannerWithString:digits];
    BOOL parsed = hexadecimal ? [scanner scanHexLongLong:&number] : [scanner scanUnsignedLongLong:&number];
    if (!countryValid || !infoValid || !digits.length ||
        [digits rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound ||
        !parsed || !scanner.isAtEnd || number > UINT32_MAX) {
        if (error) *error = LocusActivationError(24, @"Unsupported MobileActivation field semantics: expected country code, region code and a UInt32 string for SoftwareBehaviors.");
        return NO;
    }
    if (error) *error = nil;
    return YES;
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
    @synchronized (self) {
        NSString *readPath = nil;
        WorseQueryLease *lease = LocusAcquireRegionLease(&readPath, error, nil);
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
}

- (BOOL)applyJapanRegionWithError:(NSError **)error
{
    @synchronized (self) {
        NSString *readPath = nil;
        WorseQueryLease *lease = LocusAcquireRegionLease(&readPath, error, nil);
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

            if (!LocusValidateRegionSchema(parsed, error)) return NO;
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
}

- (BOOL)restoreRegionData:(NSData *)data error:(NSError **)error
{
    @synchronized (self) {
        if (![data isKindOfClass:NSData.class] || data.length == 0) {
            if (error) {
                *error = LocusActivationError(41, @"The MobileActivation backup is empty.");
            }
            return NO;
        }

        NSString *readPath = nil;
        WorseQueryLease *lease = LocusAcquireRegionLease(&readPath, error, nil);
        if (!lease) {
            return NO;
        }
        @try {
            return LocusRewriteExistingActivationFile(readPath, data, 42, error);
        } @finally {
            [lease invalidate];
        }
    }
}

- (BOOL)validateRegionData:(NSData *)data error:(NSError **)error
{
    NSDictionary *region = LocusParsePlistData(data, 0, NULL, error);
    if (!region) {
        if (error && !*error) *error = LocusActivationError(23, @"region_info.plist is not a dictionary.");
        return NO;
    }
    return LocusValidateRegionSchema(region, error);
}

- (NSDictionary<NSString *, id> *)regionDiagnostics
{
    @synchronized (self) {
        NSMutableDictionary<NSString *, id> *result = [NSMutableDictionary dictionary];

        NSString *readPath = nil;
        NSError *leaseError = nil;
        // One resolver observation belongs to this exact read attempt.
        WorseQueryLease *lease = LocusAcquireRegionLease(&readPath, &leaseError, result);
        result[@"resolvedBackingPath"] = readPath ? LocusSafeDiagnosticText(readPath) : (id)NSNull.null;
        result[@"backingPathState"] = @{@"state": @"not-observed"};
        result[@"backingReadSucceeded"] = @NO;
        result[@"backingReadError"] = leaseError
            ? LocusSafeDiagnosticText(leaseError.localizedDescription) : (id)NSNull.null;
        result[@"backingCountryCode"] = NSNull.null;
        result[@"backingRegionInfo"] = NSNull.null;
        result[@"backingSoftwareBehaviors"] = NSNull.null;
        result[@"mutationSchemaSupported"] = @NO;
        result[@"mutationSchemaErrorDetails"] = NSNull.null;
        result[@"mutationSchemaError"] = leaseError
            ? LocusSafeDiagnosticText(leaseError.localizedDescription) : @"Backing data unavailable.";

        if (lease) {
            @try {
                result[@"backingPathState"] = LocusPathState(readPath);
                NSError *readError = nil;
                NSData *data = [NSData dataWithContentsOfFile:readPath
                                                      options:NSDataReadingMappedIfSafe
                                                        error:&readError];
                BOOL bytesRead = data != nil;
                NSDictionary *backing = data
                    ? LocusParsePlistData(data, 0, NULL, &readError)
                    : nil;
                if (backing) {
                    NSError *schemaError = nil;
                    result[@"mutationSchemaSupported"] = @(LocusValidateRegionSchema(backing, &schemaError));
                    result[@"mutationSchemaError"] = schemaError.localizedDescription ?: NSNull.null;
                    result[@"mutationSchemaErrorDetails"] = schemaError
                        ? LocusErrorDetails(schemaError, @"schema-validation") : (id)NSNull.null;
                    result[@"backingReadSucceeded"] = @YES;
                    result[@"backingReadError"] = NSNull.null;
                    result[@"backingErrorDetails"] = NSNull.null;
                    result[@"backingStage"] = @"complete";
                    result[@"backingCountryCode"] =
                        LocusFirstValue(backing, LocusCountryKeys()) ?: NSNull.null;
                    result[@"backingRegionInfo"] =
                        LocusFirstValue(backing, LocusRegionKeys()) ?: NSNull.null;
                    result[@"backingSoftwareBehaviors"] =
                        LocusFirstValue(backing, LocusBehaviorKeys()) ?: NSNull.null;
                } else {
                    NSString *stage = bytesRead ? @"plist-parse" : @"file-read";
                    readError = readError ?: LocusActivationError(bytesRead ? 23 : 20,
                        bytesRead ? @"Could not parse the backing plist." : @"Could not read the backing plist.");
                    LocusRecordFailure(result, stage, readError);
                    result[@"backingReadError"] = LocusSafeDiagnosticText(readError.localizedDescription);
                    result[@"mutationSchemaError"] = result[@"backingReadError"];
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
        result[@"effectiveStage"] = @"framework-load";

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
            result[@"effectiveStage"] = @"symbol-resolution";
            dlclose(handle);
            return [result copy];
        }

        CFErrorRef apiErrorRef = NULL;
        CFDictionaryRef dictionaryRef = copyRegion(&apiErrorRef);
        result[@"effectiveStage"] = @"api-call";
        NSError *apiError = apiErrorRef ? (__bridge NSError *)apiErrorRef : nil;
        if (dictionaryRef && CFGetTypeID(dictionaryRef) == CFDictionaryGetTypeID()) {
            NSDictionary *dictionary = (__bridge NSDictionary *)dictionaryRef;
            result[@"effectiveCallSucceeded"] = @YES;
            result[@"effectiveStage"] = @"complete";
            result[@"effectiveCountryCode"] = dictionary[*countryKey] ?: NSNull.null;
            result[@"effectiveRegionInfo"] = dictionary[*regionKey] ?: NSNull.null;
            result[@"effectiveSoftwareBehaviors"] = dictionary[*behaviorKey] ?: NSNull.null;
        }
        if (apiError) {
            result[@"effectiveErrorDomain"] = apiError.domain ?: NSNull.null;
            result[@"effectiveErrorCode"] = @(apiError.code);
            result[@"effectiveErrorDescription"] =
                LocusSafeDiagnosticText(apiError.localizedDescription);
            result[@"effectiveStage"] = @"api-error";
        } else if (!dictionaryRef) {
            result[@"effectiveErrorDescription"] = @"API returned NULL without an error.";
        } else if (CFGetTypeID(dictionaryRef) != CFDictionaryGetTypeID()) {
            result[@"effectiveStage"] = @"api-result-type";
            result[@"effectiveErrorDescription"] = @"API returned a non-dictionary object.";
        }

        if (dictionaryRef) {
            CFRelease(dictionaryRef);
        }
        // The ownership of this private out-error is not independently known;
        // match the verified implementation and do not release apiErrorRef.
        dlclose(handle);

        return [result copy];
    }
}

@end
