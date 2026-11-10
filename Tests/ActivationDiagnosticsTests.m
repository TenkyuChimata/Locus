// SPDX-License-Identifier: GPL-3.0-only
// macOS host regression: real plist/files, simulated resolver/lease/effective API.
// No device access or system-file mutation is performed.
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <sys/stat.h>
#import <assert.h>
#import "../Locus/LowLevel/WorseQueryBridge.h"

static void *TestOpen(const char *, int);
static void *TestSymbol(void *, const char *);
static int TestClose(void *);
static int TestStat(const char *, struct stat *);
#define dlopen TestOpen
#define dlsym TestSymbol
#define dlclose TestClose
#define lstat TestStat
#import "../Locus/LowLevel/MobileActivationRegionAccess.m"
#undef dlopen
#undef dlsym
#undef dlclose
#undef lstat

static NSString *normalPath, *configurationError;
static NSArray<NSString *> *candidates;
static BOOL failLease, failFramework, failSymbol, failAPI;
static NSUInteger resolverCalls, acquired, invalidated;
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
static void *TestOpen(const char *path, int flags)
{
    (void)path; (void)flags;
    return failFramework ? NULL : (void *)1;
}
static void *TestSymbol(void *handle, const char *name)
{
    (void)handle;
    if (!strcmp(name, "container_system_group_path_for_identifier")) return (void *)Resolve;
    if (!strcmp(name, "container_get_error_description")) return (void *)DescribeStatus;
    if (failSymbol) return NULL;
    if (!strcmp(name, "MAECopyDeviceRegionInfoWithError")) return (void *)CopyRegion;
    if (!strcmp(name, "kMADeviceRegionCountryCode")) return &countryKey;
    if (!strcmp(name, "kMADeviceRegionRegionInfo")) return &regionKey;
    if (!strcmp(name, "kMADeviceRegionSoftwareBehaviors")) return &behaviorKey;
    return NULL;
}
static int TestClose(void *handle) { (void)handle; return 0; }
static int TestStat(const char *path, struct stat *state)
{
    (void)path; (void)state;
    errno = EACCES;
    return -1; // denied metadata must remain unknown, never "missing"
}
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
    if (failLease) {
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
    return result;
}
static void WritePlist(id value, NSString *path)
{
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:value
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    assert([data writeToFile:path atomically:NO]);
}
int main(void)
{
    @autoreleasepool {
        NSString *temporary = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSString *directory = [temporary stringByAppendingPathComponent:@"Library/region_info"];
        NSFileManager *files = NSFileManager.defaultManager;
        assert([files createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL]);
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
        NSString *metadata = [temporary stringByAppendingPathComponent:LocusMetadataHidden];
        WritePlist(@[@"wrong root"], metadata);
        result = Probe();
        assert([result[@"discovery"][@"metadataParseFailures"] intValue] == 1);
        WritePlist(@{LocusMetadataIdentifier: @"unrelated-systemgroup"}, metadata);
        result = Probe();
        assert([result[@"discovery"][@"metadataIdentifierMismatches"] intValue] == 1);

        WritePlist(@{LocusMetadataIdentifier: LocusActivationSystemGroup}, metadata);
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
        assert([result[@"mutationSchemaSupported"] boolValue]);
        assert([result[@"effectiveStage"] isEqual:@"complete"]);
        assert([original isEqual:[NSData dataWithContentsOfFile:backing]]);

        failSymbol = YES;
        result = Probe();
        assert([result[@"effectiveStage"] isEqual:@"symbol-resolution"]);
        failSymbol = NO; failFramework = YES;
        result = Probe();
        assert([result[@"effectiveStage"] isEqual:@"framework-load"]);
        assert([files removeItemAtPath:temporary error:NULL]);
        puts("PASS: activation phase/error separation, redaction, read-only schema checks and lease cleanup (simulated APIs)");
    }
}
