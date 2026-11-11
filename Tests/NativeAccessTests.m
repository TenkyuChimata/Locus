// SPDX-License-Identifier: GPL-3.0-only
// macOS host tests. All ContainerManager/sandbox/signature APIs are simulated.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>
#import <xpc/xpc.h>
#include <assert.h>
#include <stdio.h>
#import "../Locus/LowLevel/InPlaceFileTransaction.h"

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

static int CacheOpen(const char *, int);
static int CacheReplace(const char *, const void *, size_t, const void *, size_t, LocusFileOutcome *);
#define open CacheOpen
#define LocusReplaceFile CacheReplace
#import "../Locus/LowLevel/MobileGestaltAccess.m"
#undef open
#undef LocusReplaceFile

static NSArray *signedGroups;
static NSURL *groupRoot;
static BOOL containerAvailable = YES, releaseFails = NO, firstFlagFails = NO, tokenFails = NO;
static NSUInteger created, freed, consumed, released;
static uint64_t selectedFlags;
static const char *testTarget = "/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches";
static NSString *cachePath;
static int cacheOpenError;
static NSUInteger cacheOpens;
static BOOL cleanupFault, firstConsumeFails, expectReadOnly = YES;

static void *QueryCreate(void) { created++; return malloc(1); }
static void SetClass(void *q, uint64_t value) { (void)q; assert(value == 7); }
static void SetPart(void *q, uint64_t value) { (void)q; assert(value == 3); }
static void SetFlags(void *q, uint64_t value) { (void)q; selectedFlags = value; }
static void SetGroup(void *q, xpc_object_t value) { (void)q; assert(xpc_get_type(value) == XPC_TYPE_STRING); }
static void *QueryResult(void *q) {
    if (cleanupFault) {
        NSString *link = [groupRoot.path stringByAppendingPathComponent:@"Library/Caches"];
        assert(unlink(link.fileSystemRepresentation) == 0);
        assert(symlink("/wrong-test-target", link.fileSystemRepresentation) == 0);
    }
    return firstFlagFails && selectedFlags == 0x8000000000ULL ? NULL : q;
}
static void QueryFree(void *q) { freed++; free(q); }
static char *CopyToken(void *q) { (void)q; return tokenFails ? NULL : strdup("simulated-token"); }
static int64_t Consume(const char *token) {
    assert(strcmp(token, "simulated-token") == 0);
    if (firstConsumeFails && selectedFlags == 0x8000000000ULL) { errno = EPERM; return -1; }
    return (int64_t)++consumed;
}
static int Release(int64_t handle) { assert(handle > 0); released++; if (releaseFails) { errno = EPERM; return -1; } return 0; }
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
// The app has no path override API. Redirect only its fixed path in this host
// test, then exercise real open/fstat/read and CAS on test-owned files.
static int CacheOpen(const char *path, int flags)
{
    assert(!strcmp(path, LocusGestaltPath.fileSystemRepresentation));
    cacheOpens++;
    assert(flags & O_NOFOLLOW);
    assert(!(flags & (O_CREAT | O_TRUNC)));
    if (expectReadOnly) assert((flags & O_ACCMODE) == O_RDONLY);
    if (cacheOpenError) { errno = cacheOpenError; return -1; }
    return open(cachePath.fileSystemRepresentation, flags);
}
static int CacheReplace(const char *path, const void *expected, size_t expectedSize,
                        const void *replacement, size_t replacementSize, LocusFileOutcome *outcome)
{
    assert(!expectReadOnly && !strcmp(path, LocusGestaltPath.fileSystemRepresentation));
    return LocusReplaceFile(cachePath.fileSystemRepresentation, expected, expectedSize, replacement, replacementSize, outcome);
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
        assert([WorseQueryLease leaseForPath:@"/var/containers/Shared/SystemGroup/test/Library/Caches" error:&detail] == nil);
        assert([WorseQueryLease leaseForPath:[path stringByAppendingString:@"/child"] error:&detail] == nil);
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

        // Actual bridge and MobileGestalt reader, simulated platform grants.
        testTarget = LocusGestaltLeaseDirectory.UTF8String;
        cachePath = [temporary stringByAppendingPathComponent:@"cache.plist"];
        MobileGestaltAccess *access = [MobileGestaltAccess new];
        NSError *error = nil;
        NSDictionary *plist = @{@"CacheUUID": @"test-uuid", @"CacheVersion": @"test-build",
            @"CacheData": [NSMutableData dataWithLength:72], @"CacheExtra": @{@"field": @"before"}};
        NSData *originalBytes = Plist(plist, NSPropertyListBinaryFormat_v1_0);
        for (NSNumber *format in @[@(NSPropertyListXMLFormat_v1_0), @(NSPropertyListBinaryFormat_v1_0)]) {
            NSData *bytes = Plist(plist, format.integerValue);
            assert([bytes writeToFile:cachePath atomically:NO]);
            NSUInteger openedBefore = cacheOpens;
            assert([[access readCachePlistWithError:&error] isEqual:plist] && !error);
            assert(cacheOpens == openedBefore + 1 && Grants().count == 0);
            assert([[NSData dataWithContentsOfFile:cachePath] isEqual:bytes]);
        }
        NSUInteger openedBefore = cacheOpens;
        tokenFails = YES;
        assert(![access readCacheDataWithError:&error] && error && cacheOpens == openedBefore);
        tokenFails = NO;
        cacheOpenError = EPERM;
        assert(![access readCacheDataWithError:&error] && error && Grants().count == 0);
        assert([error.localizedDescription containsString:@"errno=1"]);
        cacheOpenError = 0;
        assert(unlink(cachePath.fileSystemRepresentation) == 0);
        assert(![access readCacheDataWithError:&error] && error && Grants().count == 0);
        for (NSData *bad in @[[NSData data], [@"not a plist" dataUsingEncoding:NSUTF8StringEncoding]]) {
            assert([bad writeToFile:cachePath atomically:NO]);
            assert(![access readCachePlistWithError:&error] && error && Grants().count == 0);
        }
        NSData *arrayPlist = [NSPropertyListSerialization dataWithPropertyList:@[@1]
            format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
        assert([arrayPlist writeToFile:cachePath atomically:NO]);
        assert(![access readCachePlistWithError:&error] && error && Grants().count == 0);
        int oversized = open(cachePath.fileSystemRepresentation, O_WRONLY);
        assert(oversized >= 0 && ftruncate(oversized, 16 * 1024 * 1024 + 1) == 0);
        close(oversized);
        assert(![access readCacheDataWithError:&error] && error && Grants().count == 0);
        assert(unlink(cachePath.fileSystemRepresentation) == 0);
        assert(symlink("missing-target", cachePath.fileSystemRepresentation) == 0);
        assert(![access readCacheDataWithError:&error] && error && Grants().count == 0);
        assert(unlink(cachePath.fileSystemRepresentation) == 0);
        assert(mkdir(cachePath.fileSystemRepresentation, 0700) == 0);
        assert(![access readCacheDataWithError:&error] && error && Grants().count == 0);
        assert(rmdir(cachePath.fileSystemRepresentation) == 0);
        assert([originalBytes writeToFile:cachePath atomically:NO]);

        firstConsumeFails = YES;
        assert([access readCacheDataWithError:&error] && !error && Grants().count == 0);
        firstConsumeFails = NO;
        releaseFails = YES;
        assert([access readCacheDataWithError:&error] && Grants().count == 1);
        assert(![access readCacheDataWithError:&error] && error);
        releaseFails = NO;
        assert([access readCacheDataWithError:&error] && !error && Grants().count == 0);
        WorseQueryLease *shared = [WorseQueryLease leaseForPath:LocusGestaltLeaseDirectory error:NULL];
        NSUInteger queryBefore = created;
        assert([access readCacheDataWithError:&error] && created == queryBefore && shared.active);
        [shared invalidate]; assert(Grants().count == 0);
        cleanupFault = YES; openedBefore = cacheOpens;
        assert(![access readCacheDataWithError:&error] && error && cacheOpens == openedBefore && Grants().count == 0);
        cleanupFault = NO;
        NSString *leftover = [groupRoot.path stringByAppendingPathComponent:@"Library/Caches"];
        assert(unlink(leftover.fileSystemRepresentation) == 0); // test-owned recovery only

        // The separate write path still compares bytes and preserves the inode.
        expectReadOnly = NO;
        struct stat beforeWrite, afterWrite;
        assert(lstat(cachePath.fileSystemRepresentation, &beforeWrite) == 0);
        NSData *afterBytes = Plist(@{@"CacheExtra": @{@"field": @"after"}}, NSPropertyListBinaryFormat_v1_0);
        assert([access.cacheWriteAccessStatus[@"writable"] boolValue]);
        assert([access replaceCacheData:originalBytes withData:afterBytes error:&error] && !error);
        assert([[access readCacheDataWithError:&error] isEqual:afterBytes]);
        assert(![access replaceCacheData:originalBytes withData:originalBytes error:&error] && error);
        assert([access replaceCacheData:afterBytes withData:originalBytes error:&error] && !error);
        assert(lstat(cachePath.fileSystemRepresentation, &afterWrite) == 0 && beforeWrite.st_ino == afterWrite.st_ino);
        assert(Grants().count == 0);

        method_setImplementation(method, original);
        assert([NSFileManager.defaultManager removeItemAtURL:groupRoot error:NULL]);
        puts("PASS: signing/query/token lifecycle; single-open read-only plist reads and errors; grant cleanup/retry; actual MobileGestalt CAS. Host simulation only.");
    }
}
