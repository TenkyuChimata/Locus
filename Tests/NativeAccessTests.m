// SPDX-License-Identifier: GPL-3.0-only
// macOS host tests. All ContainerManager/sandbox/signature APIs are simulated.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <sys/stat.h>
#import <xpc/xpc.h>
#include <assert.h>
#include <stdio.h>
#import "../Locus/LowLevel/MobileActivationRegionAccess.h"

static void *TestOpen(const char *, int);
static void *TestSymbol(void *, const char *);
static int TestClose(void *);
static int TestLstat(const char *, struct stat *);
#define dlopen TestOpen
#define dlsym TestSymbol
#define dlclose TestClose
#define lstat TestLstat
#import "../Locus/LowLevel/WorseQueryBridge.m"
#undef dlopen
#undef dlsym
#undef dlclose
#undef lstat

static NSArray *signedGroups;
static NSURL *groupRoot;
static BOOL containerAvailable = YES, releaseFails = NO, firstFlagFails = NO, tokenFails = NO;
static NSUInteger created, freed, consumed, released;
static uint64_t selectedFlags;
static const char *testTarget = "/var/containers/Shared/SystemGroup/test/Library/Caches";

static void *QueryCreate(void) { created++; return malloc(1); }
static void SetClass(void *q, uint64_t value) { (void)q; assert(value == 7); }
static void SetPart(void *q, uint64_t value) { (void)q; assert(value == 3); }
static void SetFlags(void *q, uint64_t value) { (void)q; selectedFlags = value; }
static void SetGroup(void *q, xpc_object_t value) { (void)q; assert(xpc_get_type(value) == XPC_TYPE_STRING); }
static void *QueryResult(void *q) { return firstFlagFails && selectedFlags == 0x8000000000ULL ? NULL : q; }
static void QueryFree(void *q) { freed++; free(q); }
static char *CopyToken(void *q) { (void)q; return tokenFails ? NULL : strdup("simulated-token"); }
static int64_t Consume(const char *token) { assert(strcmp(token, "simulated-token") == 0); return (int64_t)++consumed; }
static int Release(int64_t handle) { assert(handle > 0); released++; return releaseFails ? -1 : 0; }
static CFTypeRef Task(CFAllocatorRef allocator) { (void)allocator; return CFRetain(CFSTR("simulated-task")); }
static CFTypeRef Entitlement(CFTypeRef task, CFStringRef key, CFErrorRef *error)
{
    (void)task; (void)error;
    assert(CFEqual(key, CFSTR("com.apple.security.application-groups")));
    return signedGroups ? CFBridgingRetain(signedGroups) : NULL;
}
static void *TestOpen(const char *name, int flags) { (void)name; (void)flags; return (void *)1; }
static int TestClose(void *handle) { (void)handle; return 0; }
static void *TestSymbol(void *handle, const char *name)
{
    (void)handle;
#define SYMBOL(n, f) if (strcmp(name, n) == 0) return (void *)f
    SYMBOL("container_query_create", QueryCreate);
    SYMBOL("container_query_set_class", SetClass);
    SYMBOL("container_query_set_group_identifiers", SetGroup);
    SYMBOL("container_query_operation_set_flags", SetFlags);
    SYMBOL("container_query_operation_set_part", SetPart);
    SYMBOL("container_query_get_single_result", QueryResult);
    SYMBOL("container_query_free", QueryFree);
    SYMBOL("container_copy_sandbox_token", CopyToken);
    SYMBOL("sandbox_extension_consume", Consume);
    SYMBOL("sandbox_extension_release", Release);
    SYMBOL("SecTaskCreateFromSelf", Task);
    SYMBOL("SecTaskCopyValueForEntitlement", Entitlement);
#undef SYMBOL
    return NULL;
}
static int TestLstat(const char *path, struct stat *st)
{
    assert(strcmp(path, testTarget) == 0);
    memset(st, 0, sizeof(*st)); st->st_mode = S_IFDIR | 0700;
    return 0;
}
static NSURL *Container(id self, SEL selector, NSString *group)
{
    (void)self; (void)selector;
    return containerAvailable && [signedGroups containsObject:group] ? groupRoot : nil;
}
static NSData *Plist(NSDictionary *value, NSPropertyListFormat format)
{
    return [NSPropertyListSerialization dataWithPropertyList:value format:format options:0 error:NULL];
}

int main(void)
{
    @autoreleasepool {
        NSString *temporary = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        groupRoot = [NSURL fileURLWithPath:temporary isDirectory:YES];
        assert([NSFileManager.defaultManager createDirectoryAtURL:groupRoot withIntermediateDirectories:YES attributes:nil error:NULL]);
        Method method = class_getInstanceMethod(NSFileManager.class, @selector(containerURLForSecurityApplicationGroupIdentifier:));
        IMP original = method_setImplementation(method, (IMP)Container);
        NSString *detail = nil;
        assert(WorseQueryAccessConfigurationError() != nil); // no signed groups
        signedGroups = @[@"group.test.locus"];
        containerAvailable = NO;
        assert(WorseQueryAccessConfigurationError() != nil); // provisioning mismatch
        containerAvailable = YES;
        assert(WorseQueryAccessConfigurationError() == nil);
        signedGroups = @[@"group.a", @"group.b"];
        assert(WorseQueryAccessConfigurationError() != nil); // ambiguous groups
        signedGroups = @[@"group.test.locus"];
        NSString *path = [NSString stringWithUTF8String:testTarget];
        assert([WorseQueryLease leaseForPath:@"relative" error:&detail] == nil);
        assert([WorseQueryLease leaseForPath:@"/etc/passwd" error:&detail] == nil);
        firstFlagFails = YES;
        WorseQueryLease *one = [WorseQueryLease leaseForPath:path error:&detail];
        assert(one && !detail && created == 2 && freed == 2 && consumed == 1);
        WorseQueryLease *two = [WorseQueryLease leaseForPath:[@"/private" stringByAppendingString:path] error:&detail];
        assert(two && created == 2);
        [one invalidate]; [one invalidate];
        assert(!one.active && two.active && released == 0);
        [two invalidate]; assert(released == 1);
        firstFlagFails = NO;
        NSUInteger before = created;
        NSMutableArray *leases = [NSMutableArray array];
        dispatch_apply(24, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(size_t index) {
            (void)index;
            @autoreleasepool {
                WorseQueryLease *lease = [WorseQueryLease leaseForPath:path error:NULL];
                assert(lease);
                @synchronized (leases) { [leases addObject:lease]; }
            }
        });
        assert(created == before + 1);
        dispatch_apply(leases.count, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(size_t index) {
            [leases[index] invalidate];
        });
        assert(Grants().count == 0);
        @autoreleasepool {
            __unused WorseQueryLease *automatic = [WorseQueryLease leaseForPath:path error:NULL];
            assert(automatic);
        }
        assert(Grants().count == 0); // ARC deallocation releases its grant
        tokenFails = YES; before = created;
        assert([WorseQueryLease leaseForPath:path error:&detail] == nil && detail.length);
        assert(created == before + 2 && freed == created && Grants().count == 0);
        tokenFails = NO;
        WorseQueryLease *pending = [WorseQueryLease leaseForPath:path error:NULL];
        releaseFails = YES; [pending invalidate];
        assert(Grants().count == 1);
        assert([WorseQueryLease leaseForPath:path error:&detail] == nil);
        releaseFails = NO;
        WorseQueryLease *retried = [WorseQueryLease leaseForPath:path error:NULL];
        assert(retried); [retried invalidate]; assert(Grants().count == 0);

        MobileActivationRegionAccess *activation = MobileActivationRegionAccess.shared;
        NSDictionary *valid = @{@"CountryCode": @"CN", @"RegionInfo": @"CH/A", @"SoftwareBehaviors": @"0x19", @"untouched": @[@1, @2]};
        for (NSNumber *format in @[@(NSPropertyListXMLFormat_v1_0), @(NSPropertyListBinaryFormat_v1_0)]) {
            assert([activation validateRegionData:Plist(valid, format.integerValue) error:NULL]);
        }
        for (id bad in @[@25, @YES, @"-1", @"4294967296", @"25x", @"", @"0x", @[], @{}]) {
            NSMutableDictionary *invalid = [valid mutableCopy]; invalid[@"SoftwareBehaviors"] = bad;
            assert(![activation validateRegionData:Plist(invalid, NSPropertyListBinaryFormat_v1_0) error:NULL]);
        }
        NSMutableDictionary *ambiguous = [valid mutableCopy]; ambiguous[@"DeviceRegionCountryCode"] = @"JP";
        assert(![activation validateRegionData:Plist(ambiguous, NSPropertyListBinaryFormat_v1_0) error:NULL]);
        assert(![activation validateRegionData:[@"corrupt" dataUsingEncoding:NSUTF8StringEncoding] error:NULL]);
        method_setImplementation(method, original);
        assert([NSFileManager.defaultManager removeItemAtURL:groupRoot error:NULL]);
        puts("PASS: simulated signing/query/token lifecycle/concurrency/retry and actual activation schema parser");
    }
}
