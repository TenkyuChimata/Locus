//
//  MobileActivationRegionAccess.m
//  Locus
//
//  ContainerManager and inode-fallback behavior retained from the
//  MIT-licensed GestaltEdit research implementation.
//

#import "MobileActivationRegionAccess.h"
#import "WorseQueryBridge.h"
#import "InPlaceFileTransaction.h"
#import "MobileGestaltImage.h"

#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <stdint.h>
#import <stdbool.h>
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

static BOOL LocusActivationBinaryReviewed(void)
{
    // Registration requires an independent review tying this framework to the
    // daemon's storage path, existence conditions and region schema/consumer.
    // No matching current-system binary evidence has been supplied.
    NSSet<NSString *> *reviewed = [NSSet set];
    NSString *uuid = LocusLoadedImageIdentity(LocusActivationFramework)[@"binaryUUID"];
    return uuid && [reviewed containsObject:uuid];
}

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

static NSString *LocusFileKind(mode_t mode)
{
    return S_ISDIR(mode) ? @"directory" : S_ISREG(mode) ? @"regular-file" :
        S_ISLNK(mode) ? @"symlink" : @"other";
}

// Fixed labels and aggregate outcomes only: no paths, inode identities or data.
static void LocusProbeCount(NSMutableDictionary *summary, NSString *label,
                            int result, int code, const struct stat *state)
{
    NSString *outcome = result == 0 ? (state ? LocusFileKind(state->st_mode) : @"opened") :
        [NSString stringWithFormat:@"%@:%d", NSPOSIXErrorDomain, code];
    LocusIncrement(summary, [label stringByAppendingFormat:@"=%@", outcome]);
}

static BOOL LocusProbeMetadataDirectory(NSString *path, NSString *label,
                                        NSMutableDictionary *summary,
                                        struct stat *identity)
{
    struct stat state;
    int rc = lstat(path.fileSystemRepresentation, &state);
    int code = errno;
    LocusProbeCount(summary, [label stringByAppendingString:@".directory.lstat"], rc, code, &state);
    rc = stat(path.fileSystemRepresentation, &state);
    code = errno;
    LocusProbeCount(summary, [label stringByAppendingString:@".directory.stat"], rc, code, &state);
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    int directoryError = errno;
    BOOL identified = NO;
    @try {
        LocusProbeCount(summary, [label stringByAppendingString:@".directory.open"], fd < 0 ? -1 : 0, directoryError, NULL);
        if (fd >= 0) {
            rc = fstat(fd, identity);
            code = errno;
            LocusProbeCount(summary, [label stringByAppendingString:@".directory.fstat"], rc, code, identity);
            identified = rc == 0 && S_ISDIR(identity->st_mode);
        }
        for (NSString *name in @[LocusMetadataHidden, LocusMetadataPlain]) {
            NSString *kind = [name isEqual:LocusMetadataHidden] ? @"hidden" : @"plain";
            NSString *prefix = [label stringByAppendingFormat:@".%@", kind];
            NSString *file = [path stringByAppendingPathComponent:name];
            rc = lstat(file.fileSystemRepresentation, &state);
            code = errno;
            LocusProbeCount(summary, [prefix stringByAppendingString:@".lstat"], rc, code, &state);
            rc = stat(file.fileSystemRepresentation, &state);
            code = errno;
            LocusProbeCount(summary, [prefix stringByAppendingString:@".stat"], rc, code, &state);
            int metadataFD = open(file.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
            int openError = errno;
            if (metadataFD >= 0) {
                @try {
                    rc = fstat(metadataFD, &state);
                    code = errno;
                    LocusProbeCount(summary, [prefix stringByAppendingString:@".fstat"], rc, code, &state);
                } @finally {
                    close(metadataFD);
                }
            }
            LocusProbeCount(summary, [prefix stringByAppendingString:@".open"], metadataFD < 0 ? -1 : 0, openError, NULL);
            if (fd >= 0) {
                rc = fstatat(fd, name.fileSystemRepresentation, &state, AT_SYMLINK_NOFOLLOW);
                int lookupError = errno;
                LocusProbeCount(summary, [prefix stringByAppendingString:@".relative-lstat"], rc, lookupError, &state);
                if (rc != 0 && lookupError == ENOENT) {
                    LocusIncrement(summary, [prefix stringByAppendingString:@".lookup-not-found-with-open-parent"]);
                }
            }
        }
    } @finally {
        if (fd >= 0) close(fd);
    }
    return identified;
}

static void LocusCountMetadataReadError(NSMutableDictionary *discovery,
                                       NSString *alias, NSError *error)
{
    NSMutableDictionary *errors = discovery[@"metadataReadErrors"];
    if (!errors) discovery[@"metadataReadErrors"] = errors = [NSMutableDictionary new];
    NSMutableArray *parts = [NSMutableArray arrayWithObject:alias];
    for (NSDictionary *item in LocusErrorDetails(error, @"metadata-read")[@"errors"]) {
        [parts addObject:[NSString stringWithFormat:@"%@:%@", item[@"domain"], item[@"code"]]];
    }
    LocusIncrement(errors, [parts componentsJoinedByString:@" -> "]);
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

static void LocusProbeMetadataAliases(NSString *candidate, NSString *phase,
                                      NSMutableDictionary *discovery)
{
    if (!discovery) return;
    NSMutableDictionary *summary = discovery[@"metadataPathProbes"];
    if (!summary) discovery[@"metadataPathProbes"] = summary = [NSMutableDictionary new];
    NSString *alias = LocusLeaseAliasPath(candidate);
    struct stat left = {0}, right = {0};
    BOOL first = LocusProbeMetadataDirectory(alias, [phase stringByAppendingString:@".var"], summary, &left);
    BOOL second = LocusProbeMetadataDirectory(LocusPrivateVarPath(alias),
        [phase stringByAppendingString:@".privateVar"], summary, &right);
    NSString *identity = first && second ?
        (left.st_dev == right.st_dev && left.st_ino == right.st_ino ? @"same-directory" : @"different-directories") :
        @"identity-unconfirmed";
    LocusIncrement(summary, [phase stringByAppendingFormat:@".aliases=%@", identity]);
}

static BOOL LocusMetadataAliasesMatch(NSString *candidate)
{
    NSString *alias = LocusLeaseAliasPath(candidate);
    int left = open(alias.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    int right = -1;
    BOOL same = NO;
    @try {
        right = open(LocusPrivateVarPath(alias).fileSystemRepresentation,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        struct stat a, b;
        same = left >= 0 && right >= 0 && fstat(left, &a) == 0 && fstat(right, &b) == 0 &&
            a.st_dev == b.st_dev && a.st_ino == b.st_ino;
    } @finally {
        if (left >= 0) close(left);
        if (right >= 0) close(right);
    }
    return same;
}

static BOOL LocusIsSystemGroupCandidate(NSString *path)
{
    NSString *alias = LocusLeaseAliasPath(path);
    if (![alias isEqual:alias.stringByStandardizingPath] ||
        ![alias.stringByDeletingLastPathComponent isEqual:LocusSystemGroupRoot] ||
        [alias rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return NO;
    return [alias.lastPathComponent isEqual:LocusActivationSystemGroup] ||
        [[NSUUID alloc] initWithUUIDString:alias.lastPathComponent] != nil;
}

// One ordinary, read-only class-13 query. No flags/part/symlink/token operation.
// Identity must come from ContainerManager and the path must stay in scope.
static NSString *LocusFindSystemGroupByQuery(NSMutableDictionary *discovery)
{
    void *handle = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_LAZY | RTLD_LOCAL);
    NSMutableDictionary *summary = [NSMutableDictionary dictionaryWithDictionary:@{
        @"status": @"unavailable", @"resultLimit": @512, @"results": @0,
        @"identityMatches": @0, @"rejectedPaths": @0,
        @"apiAvailable": @NO, @"queryCreated": @NO,
        @"iterationStarted": @NO, @"iterationReturned": @NO,
        @"iterationCompleted": NSNull.null,
        @"queryErrorPresent": NSNull.null,
        @"enumerationRights": @"unverified; results are caller-visible only"
    }];
    discovery[@"identityQuery"] = summary;
    if (!handle) return nil;
    NSString *found = nil;
    @try {
        void *(*create)(void) = dlsym(handle, "container_query_create");
        void (*setClass)(void *, uint64_t) = dlsym(handle, "container_query_set_class");
        bool (*iterate)(void *, bool (^)(void *)) = dlsym(handle, "container_query_iterate_results_sync");
        void (*freeQuery)(void *) = dlsym(handle, "container_query_free");
        const char *(*getPath)(void *) = dlsym(handle, "container_object_get_path");
        const char *(*getIdentifier)(void *) = dlsym(handle, "container_object_get_identifier");
        if (!create || !setClass || !iterate || !freeQuery || !getPath || !getIdentifier) return nil;
        summary[@"apiAvailable"] = @YES;
        // The error is borrowed from the query and is inspected before free.
        // Never emit its message/path, and never treat its type as POSIX errno.
        void *(*getLastError)(void *) = dlsym(handle, "container_query_get_last_error");
        uint64_t (*getErrorType)(void *) = dlsym(handle, "container_error_get_type");
        int (*getPOSIXError)(void *) = dlsym(handle, "container_error_get_posix_errno");
        LocusContainerErrorDescription describeError = (LocusContainerErrorDescription)
            dlsym(handle, "container_get_error_description");
        summary[@"errorIntrospectionAvailable"] = @(getLastError != NULL);
        summary[@"errorTypeGetterAvailable"] = @(getErrorType != NULL);
        summary[@"errorPOSIXGetterAvailable"] = @(getPOSIXError != NULL);
        void *query = create();
        if (!query) { summary[@"status"] = @"query-create-failed"; return nil; }
        summary[@"queryCreated"] = @YES;
        @try {
            setClass(query, 13);
            __block NSUInteger count = 0;
            __block NSUInteger callbacks = 0;
            __block NSUInteger nullResults = 0;
            __block BOOL truncated = NO;
            NSMutableSet<NSString *> *matches = [NSMutableSet new];
            summary[@"iterationStarted"] = @YES;
            bool completed = iterate(query, ^bool(void *object) {
                if (callbacks >= 512) { truncated = YES; return false; }
                callbacks++;
                if (!object) { nullResults++; return true; }
                count++;
                const char *identifier = getIdentifier(object);
                if (!identifier || strcmp(identifier, LocusActivationSystemGroup.UTF8String)) return true;
                LocusIncrement(summary, @"identityMatches");
                const char *bytes = getPath(object);
                NSString *path = bytes ? [NSString stringWithUTF8String:bytes] : nil;
                if (path && LocusIsSystemGroupCandidate(path)) [matches addObject:LocusLeaseAliasPath(path)];
                else LocusIncrement(summary, @"rejectedPaths");
                return true;
            });
            summary[@"iterationReturned"] = @YES;
            summary[@"iterationCompleted"] = @(completed);
            summary[@"callbacks"] = @(callbacks);
            summary[@"nullResults"] = @(nullResults);
            summary[@"results"] = @(count);
            if (!completed && !truncated && getLastError) {
                void *queryError = getLastError(query);
                summary[@"queryErrorPresent"] = @(queryError != NULL);
                if (queryError && getErrorType) {
                    uint64_t type = getErrorType(queryError);
                    summary[@"queryErrorType"] = @(type);
                    const char *name = describeError ? describeError(type) : NULL;
                    if (name) {
                        NSString *text = [NSString stringWithUTF8String:name];
                        if (text) summary[@"queryErrorName"] = LocusSafeDiagnosticText(text);
                    }
                }
                if (queryError && getPOSIXError) {
                    summary[@"queryErrorPOSIXCode"] = @(getPOSIXError(queryError));
                }
            }
            BOOL rejected = [summary[@"rejectedPaths"] unsignedIntegerValue] > 0;
            summary[@"status"] = truncated ? @"result-limit-reached" : !completed ? @"iteration-failed" :
                nullResults ? @"invalid-result-object" : rejected ? @"invalid-match-path" :
                matches.count > 1 ? @"ambiguous-matches" : matches.count == 1 ? @"matched" : @"no-visible-match";
            if (completed && !truncated && !nullResults && !rejected && matches.count == 1) found = matches.anyObject;
        } @finally {
            freeQuery(query);
        }
    } @catch (NSException *exception) {
        (void)exception; // Never emit an exception reason containing private paths.
        summary[@"status"] = @"query-exception";
        found = nil;
    } @finally {
        dlclose(handle);
    }
    return found;
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
    diagnostics[@"resolverDetail"] = detail ? LocusSafeDiagnosticText(detail) : (id)NSNull.null;
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
        @"inodeScanPerformed": @NO,
        @"scanCoverage": @"bounded; completeness unproven",
        @"source": @"unresolved",
        @"candidateCount": @0, @"uuidCandidateCount": @0,
        @"metadataLeaseFailures": @0, @"metadataReadFailures": @0,
        @"metadataParseFailures": @0, @"metadataIdentifierMismatches": @0,
        @"metadataFilesAttempted": @0, @"metadataReadAttempts": @0,
        @"metadataDirectoriesLeased": @0, @"metadataPrimaryReadFailures": @0,
        @"metadataAliasReadRecoveries": @0, @"metadataAliasIdentityFailures": @0,
        @"uuidMetadataDirectoriesLeased": @0, @"namedMetadataDirectoriesLeased": @0,
        @"uuidMetadataLeaseFailures": @0, @"namedMetadataLeaseFailures": @0
    }];
    diagnostics[@"discovery"] = discovery;
    if (normalPath.length > 0) {
        if (!LocusIsSystemGroupCandidate(normalPath) || status.unsignedLongLongValue != 0) {
            NSError *identityError = LocusActivationError(12, @"Resolver path/status failed SystemGroup identity scope validation.");
            diagnostics[@"resolverSucceeded"] = @NO;
            diagnostics[@"resolverDetail"] = identityError.localizedDescription;
            LocusRecordFailure(diagnostics, @"resolver-identity", identityError);
            if (error) *error = identityError;
            return nil;
        }
        discovery[@"source"] = @"normal-resolver";
        if (error) {
            *error = nil;
        }
        return normalPath;
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

    NSString *queriedPath = LocusFindSystemGroupByQuery(discovery);
    if (queriedPath) {
        discovery[@"source"] = @"container-manager-identity-match";
        if (error) *error = nil;
        return queriedPath;
    }

    // A readable root with an inode beyond the limit is evidence that this
    // limit is not a volume-wide bound, not permission to extend the scan.
    struct stat rootState;
    if (stat(LocusSystemGroupRoot.fileSystemRepresentation, &rootState) == 0) {
        discovery[@"rootInodeAboveLimit"] = @((uint64_t)rootState.st_ino > LocusSystemGroupInodeLimit);
    } else {
        int code = errno;
        discovery[@"rootInodeError"] = @{@"domain": NSPOSIXErrorDomain, @"code": @(code)};
    }

    NSString *listDetail = nil;
    discovery[@"inodeScanPerformed"] = @YES;
    NSArray<NSString *> *candidates = WorseQueryListImmediateChildren(
        LocusSystemGroupRoot,
        LocusSystemGroupInodeLimit,
        &listDetail
    );
    if (!candidates) {
        discovery[@"inodeEnumerationError"] = LocusErrorDetails(
            LocusActivationError(11, listDetail ?: @"SystemGroup enumeration failed."), @"inode-enumeration");
    }

    discovery[@"candidateCount"] = @(candidates.count);
    // iOS 27 projects also use identifier-named SystemGroup children. Probe
    // only this known identifier, without expanding the inode range. It still
    // requires a metadata identity match; basename alone never authorizes it.
    NSMutableOrderedSet<NSString *> *metadataCandidates = [NSMutableOrderedSet new];
    // A previously identified path is only a candidate on the next operation.
    // Its metadata identity must be read again; a cached path is not authority.
    @synchronized (MobileActivationRegionAccess.class) {
        if (LocusCachedActivationSystemGroupPath) [metadataCandidates addObject:LocusCachedActivationSystemGroupPath];
    }
    for (NSString *candidate in candidates) [metadataCandidates addObject:LocusLeaseAliasPath(candidate)];
    NSString *named = [LocusSystemGroupRoot stringByAppendingPathComponent:LocusActivationSystemGroup];
    BOOL namedScanned = [metadataCandidates containsObject:named];
    discovery[@"namedCandidateInScan"] = @(namedScanned);
    [metadataCandidates addObject:named];
    for (NSString *candidate in metadataCandidates) {
        BOOL isUUID = [[NSUUID alloc] initWithUUIDString:candidate.lastPathComponent] != nil;
        BOOL isNamed = [candidate isEqual:named];
        if (!isUUID && !isNamed) {
            LocusIncrement(discovery, @"skippedNonTargetNames");
            continue;
        }
        LocusIncrement(discovery, isUUID ? @"uuidCandidateCount" : @"namedCandidateCount");
        if (diagnostics) LocusProbeMetadataAliases(candidate, @"beforeLease", discovery);
        NSString *leaseDetail = nil;
        // One directory lease covers both known metadata names and probes.
        WorseQueryLease *lease = [WorseQueryLease leaseForPath:candidate error:&leaseDetail];
        if (!lease) {
            LocusIncrement(discovery, @"metadataLeaseFailures");
            LocusIncrement(discovery, isNamed ? @"namedMetadataLeaseFailures" : @"uuidMetadataLeaseFailures");
            discovery[@"lastMetadataFailure"] = LocusErrorDetails(
                LocusActivationError(13, leaseDetail ?: @"Metadata lease failed."), @"metadata-lease");
            discovery[@"lastMetadataLeaseFailure"] = discovery[@"lastMetadataFailure"];
            discovery[@"lastMetadataLeaseDetail"] = LocusSafeDiagnosticText(leaseDetail ?: @"Unavailable");
            continue;
        }
        @try {
            LocusIncrement(discovery, @"metadataDirectoriesLeased");
            LocusIncrement(discovery, isNamed ? @"namedMetadataDirectoriesLeased" : @"uuidMetadataDirectoriesLeased");
            if (diagnostics) LocusProbeMetadataAliases(candidate, @"afterLease", discovery);
            for (NSString *metadataName in @[LocusMetadataHidden, LocusMetadataPlain]) {
                NSString *leasePath = [candidate stringByAppendingPathComponent:metadataName];
                NSString *readPath = LocusPrivateVarPath(leasePath);
                NSError *metadataError = nil;
                LocusIncrement(discovery, @"metadataFilesAttempted");
                LocusIncrement(discovery, @"metadataReadAttempts");
                NSData *data = [NSData dataWithContentsOfFile:readPath options:0 error:&metadataError];
                if (!data) {
                    LocusIncrement(discovery, @"metadataPrimaryReadFailures");
                    LocusCountMetadataReadError(discovery, @"privateVar", metadataError);
                    if (![readPath isEqual:leasePath]) {
                        metadataError = nil;
                        LocusIncrement(discovery, @"metadataReadAttempts");
                        data = [NSData dataWithContentsOfFile:leasePath options:0 error:&metadataError];
                        if (data) {
                            if (!LocusMetadataAliasesMatch(candidate)) {
                                LocusIncrement(discovery, @"metadataAliasIdentityFailures");
                                discovery[@"lastMetadataFailure"] = LocusErrorDetails(
                                    LocusActivationError(14, @"Metadata path aliases could not be confirmed as the same directory."),
                                    @"metadata-alias-identity");
                                discovery[@"lastMetadataAliasIdentityFailure"] = discovery[@"lastMetadataFailure"];
                                continue;
                            }
                            LocusIncrement(discovery, @"metadataAliasReadRecoveries");
                        } else LocusCountMetadataReadError(discovery, @"var", metadataError);
                    }
                }
                if (!data) {
                    LocusIncrement(discovery, @"metadataReadFailures");
                    discovery[@"lastMetadataFailure"] = LocusErrorDetails(
                        metadataError ?: LocusActivationError(20, @"Metadata read failed."), @"metadata-read");
                    discovery[@"lastMetadataReadFailure"] = discovery[@"lastMetadataFailure"];
                    continue;
                }

                metadataError = nil;
                id plist = [NSPropertyListSerialization propertyListWithData:data
                                                                      options:0
                                                                       format:NULL
                                                                        error:&metadataError];
                if (![plist isKindOfClass:NSDictionary.class]) {
                    LocusIncrement(discovery, @"metadataParseFailures");
                    discovery[@"lastMetadataFailure"] = LocusErrorDetails(
                        metadataError ?: LocusActivationError(23, @"Metadata is not a dictionary."), @"metadata-parse");
                    discovery[@"lastMetadataParseFailure"] = discovery[@"lastMetadataFailure"];
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
                discovery[@"source"] = isNamed ? @"named-metadata-match" : @"inode-metadata-match";
                if (error) {
                    *error = nil;
                }
                return candidate;
            }
        } @finally {
            [lease invalidate];
        }
    }

    if (!candidates) {
        NSError *enumerationError = LocusActivationError(11,
            listDetail ?: @"Could not enumerate SystemGroup candidates.");
        LocusRecordFailure(diagnostics, @"inode-enumeration", enumerationError);
        if (error) *error = enumerationError;
        return nil;
    }
    LocusRecordFailure(diagnostics, @"systemgroup-discovery",
        LocusActivationError(12, @"No matching metadata in the bounded scan; absence is not established."));
    if (error) {
        *error = LocusActivationError(
            12,
            @"No verified MobileActivation SystemGroup identity was found by the read-only query and bounded metadata probes. Absence is not established."
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

- (BOOL)replaceRegionData:(NSData *)expected withData:(NSData *)replacement error:(NSError **)error
{
    @synchronized (self) {
        NSString *path = nil;
        WorseQueryLease *lease = LocusAcquireRegionLease(&path, error, nil);
        if (!lease) return NO;
        @try {
            LocusFileOutcome outcome = LocusFileUnchanged;
            int rc = LocusReplaceFile(path.fileSystemRepresentation, expected.bytes, expected.length,
                                      replacement.bytes, replacement.length, &outcome);
            if (rc != 0 && error) *error = LocusActivationError(50,
                [NSString stringWithFormat:@"MobileActivation compare-and-replace failed (errno=%d, outcome=%d: 0=unchanged, 2=rollback verified, 3=recovery required).", errno, outcome]);
            if (rc == 0 && error) *error = nil;
            return rc == 0;
        } @finally { [lease invalidate]; }
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
        // NSNull means this check was not reached, not a negative observation.
        result[@"backingReadSucceeded"] = NSNull.null;
        result[@"backingReadError"] = leaseError
            ? LocusSafeDiagnosticText(leaseError.localizedDescription) : (id)NSNull.null;
        result[@"backingCountryCode"] = NSNull.null;
        result[@"backingRegionInfo"] = NSNull.null;
        result[@"backingSoftwareBehaviors"] = NSNull.null;
        result[@"mutationSchemaSupported"] = @NO;
        result[@"backingSchemaValid"] = NSNull.null;
        result[@"backingWriteAccessAvailable"] = NSNull.null;
        result[@"backingWriteAccessError"] = NSNull.null;
        result[@"binarySupported"] = NSNull.null;
        result[@"binaryUUID"] = NSNull.null;
        result[@"storagePathProvenance"] = @"Inherited relative-path hypothesis; requires current framework/daemon review. No file is created.";
        result[@"metadataDenialMeaning"] = @"Denied metadata reads do not establish region_info.plist absence or unreadability. File access requires an independently identified container.";
        result[@"mutationSchemaErrorDetails"] = NSNull.null;
        result[@"mutationSchemaError"] = leaseError
            ? LocusSafeDiagnosticText(leaseError.localizedDescription) : @"Backing data unavailable.";

        if (lease) {
            @try {
                result[@"backingPathState"] = LocusPathState(readPath);
                result[@"backingReadSucceeded"] = @NO;
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
                    result[@"backingSchemaValid"] = @(LocusValidateRegionSchema(backing, &schemaError));
                    result[@"mutationSchemaError"] = schemaError.localizedDescription ?:
                        @"Readable schema candidate; current MobileActivation storage/consumer binary semantics remain unreviewed.";
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
                    // A readable schema is not proof of write access. Probe the
                    // existing regular inode without creating or changing it.
                    int fd = open(readPath.fileSystemRepresentation, O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
                    int writeError = fd < 0 ? errno : 0;
                    BOOL writable = NO;
                    if (fd >= 0) {
                        struct stat state;
                        if (fstat(fd, &state) != 0) writeError = errno;
                        else if (!S_ISREG(state.st_mode) || state.st_nlink != 1) writeError = EINVAL;
                        else writable = YES;
                        close(fd);
                    }
                    result[@"backingWriteAccessAvailable"] = @(writable);
                    result[@"backingWriteAccessError"] = writable ? (id)NSNull.null :
                        [NSString stringWithFormat:@"Existing region file is not writable as a regular single-link inode (errno=%d).", writeError];
                } else {
                    BOOL unsupportedRoot = [readError.domain isEqual:@"io.github.tenkyuchimata.locus.mobileactivation"] && readError.code == 23;
                    NSString *stage = bytesRead ? (unsupportedRoot ? @"plist-root-type" : @"plist-parse") : @"file-read";
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
            result[@"effectiveErrorDescription"] = LocusSafeDiagnosticText([NSString stringWithFormat:
                @"Could not load MobileActivation: %s", dlerror() ?: "unknown error"]);
            return [result copy];
        }

        result[@"binaryUUID"] = LocusLoadedImageIdentity(LocusActivationFramework)[@"binaryUUID"] ?: NSNull.null;
        result[@"binarySupported"] = @(LocusActivationBinaryReviewed());
        result[@"mutationSchemaSupported"] = @([result[@"backingSchemaValid"] isEqual:@YES] &&
            [result[@"binarySupported"] isEqual:@YES] && [result[@"backingWriteAccessAvailable"] isEqual:@YES]);
        if ([result[@"binarySupported"] isEqual:@YES] && [result[@"backingSchemaValid"] isEqual:@YES] &&
            [result[@"backingWriteAccessAvailable"] isEqual:@NO]) result[@"mutationSchemaError"] = result[@"backingWriteAccessError"];
        if ([result[@"mutationSchemaSupported"] boolValue]) result[@"mutationSchemaError"] = NSNull.null;

        LocusCopyDeviceRegionInfo copyRegion =
            (LocusCopyDeviceRegionInfo)dlsym(handle, "MAECopyDeviceRegionInfoWithError");
        NSString * const *countryKey =
            (NSString * const *)dlsym(handle, "kMADeviceRegionCountryCode");
        NSString * const *regionKey =
            (NSString * const *)dlsym(handle, "kMADeviceRegionRegionInfo");
        NSString * const *behaviorKey =
            (NSString * const *)dlsym(handle, "kMADeviceRegionSoftwareBehaviors");
        NSMutableArray<NSString *> *missing = [NSMutableArray new];
        if (!copyRegion) [missing addObject:@"MAECopyDeviceRegionInfoWithError"];
        if (!countryKey || ![*countryKey isKindOfClass:NSString.class]) [missing addObject:@"kMADeviceRegionCountryCode"];
        if (!regionKey || ![*regionKey isKindOfClass:NSString.class]) [missing addObject:@"kMADeviceRegionRegionInfo"];
        if (!behaviorKey || ![*behaviorKey isKindOfClass:NSString.class]) [missing addObject:@"kMADeviceRegionSoftwareBehaviors"];
        if (missing.count) {
            result[@"effectiveErrorDescription"] = [@"Missing or invalid symbols: " stringByAppendingString:
                [missing componentsJoinedByString:@", "]];
            result[@"effectiveStage"] = @"symbol-resolution";
            dlclose(handle);
            return [result copy];
        }

        CFErrorRef apiErrorRef = NULL;
        CFDictionaryRef dictionaryRef = copyRegion(&apiErrorRef);
        result[@"effectiveStage"] = @"api-call";
        BOOL validError = apiErrorRef && CFGetTypeID(apiErrorRef) == CFErrorGetTypeID();
        NSError *apiError = validError ? (__bridge NSError *)apiErrorRef : nil;
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
        } else if (apiErrorRef) {
            result[@"effectiveStage"] = @"api-error-type";
            result[@"effectiveErrorDescription"] = @"API returned a non-CFError error object.";
        } else if (!dictionaryRef) {
            result[@"effectiveStage"] = @"api-empty-result";
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
