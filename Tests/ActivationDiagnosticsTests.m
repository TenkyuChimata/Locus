// SPDX-License-Identifier: GPL-3.0-only
// macOS host regression: real plist/files, simulated resolver/lease/effective API.
// No device access or system-file mutation is performed.
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <sys/stat.h>
#import <assert.h>
#import <objc/runtime.h>
#import <string.h>
#import <fcntl.h>
#import <unistd.h>
#import <stdlib.h>
#import "../Locus/LowLevel/WorseQueryBridge.h"

static void *TestOpen(const char *, int);
static void *TestSymbol(void *, const char *);
static int TestClose(void *);
static int TestStat(const char *, struct stat *);
static int TestFollowStat(const char *, struct stat *);
static int TestFileOpen(const char *, int, ...);
static int TestFileClose(int);
#define dlopen TestOpen
#define dlsym TestSymbol
#define dlclose TestClose
#define lstat TestStat
#define stat(...) TestFollowStat(__VA_ARGS__)
#define open TestFileOpen
#define close TestFileClose
#import "../Locus/LowLevel/MobileActivationRegionAccess.m"
#undef dlopen
#undef dlsym
#undef dlclose
#undef lstat
#undef stat
#undef open
#undef close

static NSString *normalPath, *configurationError;
static NSArray<NSString *> *candidates;
static BOOL failLease, failFramework, failSymbol, failAPI;
static NSUInteger resolverCalls, acquired, invalidated;
static BOOL queryEnabled, queryThrows, realStats, namedEnabled, denyPrivateMetadata;
static BOOL queryIncomplete, queryErrorAvailable = YES, queryNullResult;
static BOOL denyHiddenOpen;
static NSArray<NSDictionary *> *queryObjects;
static NSUInteger queriesCreated, queriesFreed, openDescriptors;
static NSUInteger librariesOpened, librariesClosed;
static NSString *namedFixture;
static NSString *privateNamedDirectory;
static NSString *countryKey = @"CountryCode", *regionKey = @"RegionInfo", *behaviorKey = @"SoftwareBehaviors";

static char *Resolve(uint64_t argument, const char *identifier, uint64_t *status)
{
    assert(argument == 0 && strcmp(identifier, LocusActivationSystemGroup.UTF8String) == 0);
    resolverCalls++;
    *status = normalPath ? 0 : 55;
    return normalPath ? (char *)normalPath.UTF8String : NULL;
}
static CFDictionaryRef CopyRegion(CFErrorRef *error)
{
    if (failAPI) {
        *error = CFErrorCreate(NULL, CFSTR("test.mobileactivation"), 42,
            (__bridge CFDictionaryRef)@{NSLocalizedDescriptionKey: @"Device region is unsupported."});
        return NULL;
    }
    return CFBridgingRetain(@{countryKey: @"CN", regionKey: @"CH/A", behaviorKey: @"321"});
}
static const char *DescribeStatus(uint64_t status)
{
    return status == 55 ? "SIMULATED_STATUS_55" : "SIMULATED_SUCCESS";
}
static void *QueryCreate(void) { queriesCreated++; return malloc(1); }
static void QueryClass(void *query, uint64_t value) { assert(query && value == 13); }
static void QueryFree(void *query) { queriesFreed++; free(query); }
static const char *ObjectPath(void *object)
{
    NSDictionary *value = (__bridge NSDictionary *)object;
    return [value[@"path"] UTF8String];
}
static const char *ObjectIdentifier(void *object)
{
    NSDictionary *value = (__bridge NSDictionary *)object;
    return [value[@"identifier"] UTF8String];
}
static bool QueryIterate(void *query, bool (^visit)(void *))
{
    assert(query);
    if (queryThrows) @throw [NSException exceptionWithName:@"SimulatedQueryFailure" reason:nil userInfo:nil];
    if (queryNullResult && !visit(NULL)) return false;
    for (NSDictionary *object in queryObjects) if (!visit((__bridge void *)object)) return false;
    return !queryIncomplete;
}
static void *QueryLastError(void *query) { assert(query); return queryIncomplete ? (void *)2 : NULL; }
static uint64_t QueryErrorType(void *error) { assert(error == (void *)2); return 55; }
static int QueryPOSIXError(void *error) { assert(error == (void *)2); return EPERM; }
static void *TestOpen(const char *path, int flags)
{
    (void)path; (void)flags;
    if (failFramework) return NULL;
    librariesOpened++;
    return (void *)1;
}
static void *TestSymbol(void *handle, const char *name)
{
    (void)handle;
    if (!strcmp(name, "container_system_group_path_for_identifier")) return (void *)Resolve;
    if (!strcmp(name, "container_get_error_description")) return (void *)DescribeStatus;
    if (failSymbol) return NULL;
    if (queryEnabled) {
        if (!strcmp(name, "container_query_create")) return (void *)QueryCreate;
        if (!strcmp(name, "container_query_set_class")) return (void *)QueryClass;
        if (!strcmp(name, "container_query_iterate_results_sync")) return (void *)QueryIterate;
        if (!strcmp(name, "container_query_free")) return (void *)QueryFree;
        if (!strcmp(name, "container_object_get_path")) return (void *)ObjectPath;
        if (!strcmp(name, "container_object_get_identifier")) return (void *)ObjectIdentifier;
        if (queryErrorAvailable) {
            if (!strcmp(name, "container_query_get_last_error")) return (void *)QueryLastError;
            if (!strcmp(name, "container_error_get_type")) return (void *)QueryErrorType;
            if (!strcmp(name, "container_error_get_posix_errno")) return (void *)QueryPOSIXError;
        }
    }
    if (!strcmp(name, "MAECopyDeviceRegionInfoWithError")) return (void *)CopyRegion;
    if (!strcmp(name, "kMADeviceRegionCountryCode")) return &countryKey;
    if (!strcmp(name, "kMADeviceRegionRegionInfo")) return &regionKey;
    if (!strcmp(name, "kMADeviceRegionSoftwareBehaviors")) return &behaviorKey;
    return NULL;
}
static int TestClose(void *handle) { assert(handle); librariesClosed++; return 0; }
static int TestStat(const char *path, struct stat *state)
{
    if (realStats) return lstat(path, state);
    errno = EACCES;
    return -1; // denied metadata must remain unknown, never "missing"
}
static int TestFollowStat(const char *path, struct stat *state)
{
    if (strstr(path, "/containers/Shared/SystemGroup")) { errno = ENOENT; return -1; }
    return stat(path, state);
}
static int TestFileOpen(const char *path, int flags, ...)
{
    NSString *actual = [NSString stringWithUTF8String:path];
    if (denyHiddenOpen && [actual.lastPathComponent isEqual:LocusMetadataHidden]) {
        errno = EPERM;
        return -1;
    }
    NSString *named = [LocusSystemGroupRoot stringByAppendingPathComponent:LocusActivationSystemGroup];
    if (namedEnabled && ([actual isEqual:named] || [actual isEqual:LocusPrivateVarPath(named)])) {
        actual = [actual isEqual:LocusPrivateVarPath(named)] && privateNamedDirectory ?
            privateNamedDirectory : namedFixture.stringByDeletingLastPathComponent;
    } else if (strstr(path, "/containers/Shared/SystemGroup")) { errno = ENOENT; return -1; }
    int fd = open(actual.fileSystemRepresentation, flags);
    if (fd >= 0) openDescriptors++;
    return fd;
}
static int TestFileClose(int fd)
{
    assert(openDescriptors > 0); openDescriptors--;
    return close(fd);
}

// Only the exact synthetic named metadata path is mapped to a temporary file.
// Actual SystemGroup data is never read by this test.
@interface NSData (LocusTestRead)
+ (NSData *)locusTestRead:(NSString *)path options:(NSDataReadingOptions)options error:(NSError **)error;
@end
@implementation NSData (LocusTestRead)
+ (NSData *)locusTestRead:(NSString *)path options:(NSDataReadingOptions)options error:(NSError **)error
{
    NSString *named = [[LocusSystemGroupRoot stringByAppendingPathComponent:LocusActivationSystemGroup]
        stringByAppendingPathComponent:LocusMetadataHidden];
    if (strstr(path.fileSystemRepresentation, "/containers/Shared/SystemGroup")) {
        if (namedEnabled && ([path isEqual:named] || [path isEqual:LocusPrivateVarPath(named)])) {
            if (!denyPrivateMetadata || [path isEqual:named]) {
                return [self locusTestRead:namedFixture options:options error:error];
            }
        }
        if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:260 userInfo:@{
            NSUnderlyingErrorKey: [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOENT userInfo:nil]
        }];
        return nil;
    }
    return [self locusTestRead:path options:options error:error];
}
@end
BOOL WorseQueryBridgeAvailable(void) { return YES; }
NSString *WorseQueryAccessConfigurationError(void) { return configurationError; }
NSArray<NSString *> *WorseQueryListImmediateChildren(NSString *path, uint64_t limit, NSString **error)
{
    assert([path isEqual:LocusSystemGroupRoot] && limit == 2000000);
    if (error) *error = candidates ? nil : @"simulated statfs denial (errno=13)";
    return candidates;
}
@interface WorseQueryLease ()
@property(nonatomic, readwrite, getter=isActive) BOOL active;
@property(nonatomic, copy, readwrite) NSString *targetPath;
@end
@implementation WorseQueryLease
+ (instancetype)leaseForPath:(NSString *)path error:(NSString **)error
{
    BOOL named = [path.lastPathComponent isEqual:LocusActivationSystemGroup];
    if (failLease || (named && !namedEnabled)) {
        if (error) *error = @"simulated lease denial";
        return nil;
    }
    WorseQueryLease *lease = [self new];
    lease.active = YES; lease.targetPath = path; acquired++;
    if (error) *error = nil;
    return lease;
}
- (void)invalidate { if (_active) { _active = NO; invalidated++; } }
@end

static NSDictionary *Probe(void)
{
    NSUInteger before = resolverCalls;
    NSDictionary *result = [MobileActivationRegionAccess.shared regionDiagnostics];
    assert(resolverCalls == before + 1); // status and direct read use one attempt
    assert(acquired == invalidated);
    assert(queriesCreated == queriesFreed && openDescriptors == 0);
    assert(librariesOpened == librariesClosed);
    return result;
}
static void WritePlist(id value, NSString *path)
{
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:value
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    assert([data writeToFile:path atomically:NO]);
}

static void CheckIdentityQueries(void)
{
    queryEnabled = YES;
    NSString *named = [LocusSystemGroupRoot stringByAppendingPathComponent:LocusActivationSystemGroup];
    NSDictionary *object = @{@"path": named, @"identifier": LocusActivationSystemGroup};
    NSMutableDictionary *summary = [NSMutableDictionary new];
    queryObjects = @[object];
    assert([LocusFindSystemGroupByQuery(summary) isEqual:named]);
    assert([summary[@"identityQuery"][@"status"] isEqual:@"matched"]);
    assert([summary[@"identityQuery"][@"apiAvailable"] boolValue]);
    assert([summary[@"identityQuery"][@"iterationCompleted"] boolValue]);
    queryObjects = @[object, @{@"path": LocusPrivateVarPath(named), @"identifier": LocusActivationSystemGroup}];
    assert([LocusFindSystemGroupByQuery(summary) isEqual:named]); // same normalized identity
    NSString *other = [LocusSystemGroupRoot stringByAppendingPathComponent:@"00000000-0000-4000-8000-000000000001"];
    queryObjects = @[object, @{@"path": other, @"identifier": LocusActivationSystemGroup}];
    assert(!LocusFindSystemGroupByQuery(summary));
    assert([summary[@"identityQuery"][@"status"] isEqual:@"ambiguous-matches"]);
    for (NSString *bad in @[@"/tmp/unrelated", [named stringByAppendingPathComponent:@"nested"],
                            [LocusSystemGroupRoot stringByAppendingPathComponent:@"../escape"]]) {
        queryObjects = @[@{@"path": bad, @"identifier": LocusActivationSystemGroup}];
        assert(!LocusFindSystemGroupByQuery(summary));
        assert([summary[@"identityQuery"][@"status"] isEqual:@"invalid-match-path"]);
    }
    queryObjects = @[@{@"path": named, @"identifier": @"unrelated"}];
    assert(!LocusFindSystemGroupByQuery(summary));
    assert([summary[@"identityQuery"][@"status"] isEqual:@"no-visible-match"]);
    // A successful empty visible list and a failed query used to share the
    // same status. No matching result from an incomplete query may be trusted.
    queryObjects = @[];
    assert(!LocusFindSystemGroupByQuery(summary));
    assert([summary[@"identityQuery"][@"iterationCompleted"] boolValue]);
    assert([summary[@"identityQuery"][@"results"] intValue] == 0);
    queryIncomplete = YES;
    assert(!LocusFindSystemGroupByQuery(summary));
    assert([summary[@"identityQuery"][@"status"] isEqual:@"iteration-failed"]);
    assert([summary[@"identityQuery"][@"queryErrorType"] intValue] == 55);
    assert([summary[@"identityQuery"][@"queryErrorPOSIXCode"] intValue] == EPERM);
    assert(![summary[@"identityQuery"][@"iterationCompleted"] boolValue]);
    queryObjects = @[object];
    assert(!LocusFindSystemGroupByQuery(summary));
    queryErrorAvailable = NO;
    assert(!LocusFindSystemGroupByQuery(summary));
    assert(summary[@"identityQuery"][@"queryErrorType"] == nil);
    queryErrorAvailable = YES; queryIncomplete = NO;
    queryNullResult = YES;
    assert(!LocusFindSystemGroupByQuery(summary));
    assert([summary[@"identityQuery"][@"status"] isEqual:@"invalid-result-object"]);
    assert([summary[@"identityQuery"][@"callbacks"] intValue] == 2);
    assert([summary[@"identityQuery"][@"results"] intValue] == 1);
    queryNullResult = NO;
    NSMutableArray *many = [NSMutableArray new];
    for (NSUInteger i = 0; i < 513; i++) [many addObject:object];
    queryObjects = many;
    assert(!LocusFindSystemGroupByQuery(summary));
    assert([summary[@"identityQuery"][@"status"] isEqual:@"result-limit-reached"]);
    queryThrows = YES;
    assert(!LocusFindSystemGroupByQuery(summary));
    assert([summary[@"identityQuery"][@"status"] isEqual:@"query-exception"]);
    assert(![summary[@"identityQuery"][@"iterationReturned"] boolValue]);
    assert(summary[@"identityQuery"][@"iterationCompleted"] == NSNull.null);
    queryThrows = NO; queryEnabled = NO; queryObjects = nil;
    assert(!LocusFindSystemGroupByQuery(summary));
    assert([summary[@"identityQuery"][@"status"] isEqual:@"unavailable"]);
    assert(queriesCreated == queriesFreed);
    assert(librariesOpened == librariesClosed);
}
int main(void)
{
    @autoreleasepool {
        NSString *temporary = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSString *directory = [temporary stringByAppendingPathComponent:@"Library/region_info"];
        NSFileManager *files = NSFileManager.defaultManager;
        assert([files createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL]);
        Method read = class_getClassMethod(NSData.class, @selector(dataWithContentsOfFile:options:error:));
        Method testRead = class_getClassMethod(NSData.class, @selector(locusTestRead:options:error:));
        method_exchangeImplementations(read, testRead);
        CheckIdentityQueries();
        NSDictionary *result;
        configurationError = @"simulated signing mismatch";
        failAPI = YES;
        result = Probe();
        assert([result[@"backingStage"] isEqual:@"access-configuration"]);
        assert([result[@"resolverStatus"] unsignedLongLongValue] == 55);
        assert([result[@"resolverStatusName"] isEqual:@"SIMULATED_STATUS_55"]);
        assert([result[@"effectiveStage"] isEqual:@"api-error"]);
        assert([result[@"effectiveErrorDomain"] isEqual:@"test.mobileactivation"]);
        assert([result[@"effectiveErrorCode"] intValue] == 42);

        configurationError = nil;
        result = Probe();
        assert([result[@"backingStage"] isEqual:@"inode-enumeration"]);
        candidates = @[];
        result = Probe();
        assert([result[@"backingStage"] isEqual:@"systemgroup-discovery"]);

        candidates = @[temporary];
        failLease = YES;
        result = Probe();
        assert([result[@"discovery"][@"metadataLeaseFailures"] intValue] == 2);
        failLease = NO;
        result = Probe();
        assert([result[@"discovery"][@"metadataReadFailures"] intValue] == 2);
        assert([result[@"discovery"][@"metadataFilesAttempted"] intValue] == 2);
        assert([result[@"discovery"][@"metadataDirectoriesLeased"] intValue] == 1);
        assert([result[@"discovery"][@"namedMetadataLeaseFailures"] intValue] == 1);
        assert([result[@"discovery"][@"uuidMetadataLeaseFailures"] intValue] == 0);
        assert(result[@"discovery"][@"lastMetadataReadFailure"] != nil);
        assert(result[@"discovery"][@"lastMetadataLeaseFailure"] != nil);
        NSString *metadata = [temporary stringByAppendingPathComponent:LocusMetadataHidden];
        WritePlist(@[@"wrong root"], metadata);
        result = Probe();
        assert([result[@"discovery"][@"metadataParseFailures"] intValue] == 1);
        WritePlist(@{LocusMetadataIdentifier: @"unrelated-systemgroup"}, metadata);
        result = Probe();
        assert([result[@"discovery"][@"metadataIdentifierMismatches"] intValue] == 1);

        WritePlist(@{LocusMetadataIdentifier: LocusActivationSystemGroup}, metadata);
        realStats = YES;
        NSMutableDictionary *pathSummary = [NSMutableDictionary new];
        struct stat identity;
        assert(LocusProbeMetadataDirectory(temporary, @"control", pathSummary, &identity));
        assert([pathSummary[@"control.hidden.lstat=regular-file"] intValue] == 1);
        assert([pathSummary[@"control.hidden.fstat=regular-file"] intValue] == 1);
        assert([pathSummary[@"control.plain.lookup-not-found-with-open-parent"] intValue] == 1);
        denyHiddenOpen = YES;
        NSMutableDictionary *deniedSummary = [NSMutableDictionary new];
        assert(LocusProbeMetadataDirectory(temporary, @"denied", deniedSummary, &identity));
        assert([deniedSummary[@"denied.hidden.lstat=regular-file"] intValue] == 1);
        assert([deniedSummary[@"denied.hidden.relative-lstat=regular-file"] intValue] == 1);
        assert([deniedSummary[@"denied.hidden.open=NSPOSIXErrorDomain:1"] intValue] == 1);
        assert(deniedSummary[@"denied.hidden.fstat=regular-file"] == nil);
        denyHiddenOpen = NO;
        assert(openDescriptors == 0);
        realStats = NO;
        result = Probe();
        assert([result[@"discovery"][@"source"] isEqual:@"inode-metadata-match"]);
        assert([result[@"backingStage"] isEqual:@"file-read"]);
        assert([result[@"backingErrorDetails"][@"errors"] count] > 0);
        assert([result[@"backingPathState"][@"code"] intValue] == EACCES);
        assert(![result[@"resolvedBackingPath"] containsString:temporary.lastPathComponent]);

        failLease = YES;
        result = Probe();
        assert([result[@"backingStage"] isEqual:@"region-lease"]);
        assert(result[@"resolvedBackingPath"] != NSNull.null);
        failLease = NO;
        normalPath = temporary;
        result = Probe();
        assert(![result[@"backingReadSucceeded"] boolValue]); // resolver path outside SystemGroup is refused
        normalPath = nil;
        LocusCachedActivationSystemGroupPath = temporary; // earlier synthetic metadata identity match
        NSString *backing = [directory stringByAppendingPathComponent:@"region_info.plist"];
        WritePlist(@[@"wrong root"], backing);
        result = Probe();
        assert([result[@"backingStage"] isEqual:@"plist-parse"]);
        assert([result[@"backingErrorDetails"][@"errors"][0][@"code"] intValue] == 23);

        WritePlist(@{@"CountryCode": @"CN", @"RegionInfo": @"CH/A", @"SoftwareBehaviors": @321}, backing);
        result = Probe();
        assert([result[@"backingReadSucceeded"] boolValue]);
        assert(![result[@"mutationSchemaSupported"] boolValue]); // readable != safe to write
        assert([result[@"mutationSchemaErrorDetails"][@"errors"][0][@"code"] intValue] == 24);
        WritePlist(@{@"CountryCode": @"CN", @"RegionInfo": @"CH/A", @"SoftwareBehaviors": @"321"}, backing);
        NSData *original = [NSData dataWithContentsOfFile:backing];
        failAPI = NO;
        result = Probe();
        assert([result[@"backingStage"] isEqual:@"complete"]);
        assert([result[@"backingSchemaValid"] boolValue]);
        assert([result[@"backingWriteAccessAvailable"] boolValue]); // temporary regular file only; probe does not mutate it
        assert(![result[@"mutationSchemaSupported"] boolValue]); // schema shape alone is not binary verification
        assert([result[@"effectiveStage"] isEqual:@"complete"]);
        assert([original isEqual:[NSData dataWithContentsOfFile:backing]]);

        // Identifier-named container omitted from the inode results. Only a
        // matching metadata identifier may recover it, including /var-only reads.
        LocusCachedActivationSystemGroupPath = nil;
        normalPath = nil; candidates = @[];
        namedFixture = metadata; namedEnabled = YES; denyPrivateMetadata = YES;
        NSMutableDictionary *namedDiagnostics = [NSMutableDictionary new];
        NSError *discoveryError = nil;
        NSString *namedPath = LocusResolveSystemGroupWithFallback(&discoveryError, namedDiagnostics);
        assert([namedPath isEqual:[LocusSystemGroupRoot stringByAppendingPathComponent:LocusActivationSystemGroup]]);
        assert(!discoveryError);
        assert([namedDiagnostics[@"discovery"][@"source"] isEqual:@"named-metadata-match"]);
        assert([namedDiagnostics[@"discovery"][@"metadataAliasReadRecoveries"] intValue] == 1);
        assert(![namedDiagnostics[@"discovery"][@"namedCandidateInScan"] boolValue]);
        assert(acquired == invalidated && openDescriptors == 0);
        LocusCachedActivationSystemGroupPath = nil;
        privateNamedDirectory = directory;
        NSMutableDictionary *differentAliases = [NSMutableDictionary new];
        assert(!LocusResolveSystemGroupWithFallback(&discoveryError, differentAliases));
        assert([differentAliases[@"discovery"][@"metadataAliasIdentityFailures"] intValue] == 1);
        assert(acquired == invalidated && openDescriptors == 0);
        privateNamedDirectory = nil;
        WritePlist(@{LocusMetadataIdentifier: @"unrelated"}, metadata);
        assert(!LocusResolveSystemGroupWithFallback(&discoveryError, [NSMutableDictionary new]));
        assert(discoveryError.code == 12); // path name alone must never match
        namedEnabled = NO; denyPrivateMetadata = NO; normalPath = temporary;

        failSymbol = YES;
        result = Probe();
        assert([result[@"effectiveStage"] isEqual:@"symbol-resolution"]);
        failSymbol = NO; failFramework = YES;
        result = Probe();
        assert([result[@"effectiveStage"] isEqual:@"framework-load"]);
        assert([files removeItemAtPath:temporary error:NULL]);
        method_exchangeImplementations(read, testRead);
        puts("PASS: activation phase/error separation, redaction, read-only schema checks and lease cleanup (simulated APIs)");
    }
}
