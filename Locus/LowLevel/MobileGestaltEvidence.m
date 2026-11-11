// SPDX-License-Identifier: GPL-3.0-only
#import "MobileGestaltEvidence.h"
#import "ReadOnlyEvidenceFile.h"
#import "WorseQueryBridge.h"
#import <errno.h>
#import <sys/sysctl.h>
#import <unistd.h>

static NSDictionary *metadata(struct stat value)
{
    return @{@"device": @((uint64_t)value.st_dev), @"inode": @((uint64_t)value.st_ino),
        @"size": @((int64_t)value.st_size), @"mode": @(value.st_mode),
        @"uid": @(value.st_uid), @"gid": @(value.st_gid), @"links": @(value.st_nlink),
        @"mtimeSeconds": @((int64_t)value.st_mtimespec.tv_sec), @"mtimeNanoseconds": @(value.st_mtimespec.tv_nsec),
        @"ctimeSeconds": @((int64_t)value.st_ctimespec.tv_sec), @"ctimeNanoseconds": @(value.st_ctimespec.tv_nsec)};
}

static const char *const backingPath = "/private/var/containers/Shared/SystemGroup/"
    "systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist";

static NSMutableDictionary *fileDictionary(LocusEvidenceFile file)
{
    NSMutableDictionary *result = [@{@"stable": @(file.stable), @"errno": @(file.error),
        @"stage": @(file.stage), @"failedComponent": @(file.failedComponent)} mutableCopy];
    NSArray *ids = @[@"read-only-fd-open", @"file-identity-validation", @"first-full-read",
        @"intermediate-metadata-check", @"second-full-read", @"final-metadata-check", @"path-identity-revalidation"];
    NSMutableArray *events = [NSMutableArray array];
    for (NSUInteger i = 0; i < LocusEvidenceReadStepCount; i++) {
        LocusEvidenceReadStep step = file.steps[i];
        [events addObject:@{@"id": ids[i], @"status": step.completed ? @"PASS" :
            (step.error == EBUSY || step.error == ESTALE ? @"FAIL" : @"INCOMPLETE"),
            @"elapsedMilliseconds": step.attempted ? @(step.elapsedMilliseconds) : (id)NSNull.null,
            @"errno": step.error ? @(step.error) : (id)NSNull.null,
            @"reason": !step.attempted ? @"not-executed" : step.completed ? @"read-step-completed" : @"read-step-unavailable",
            // A read may update access time even though no content is written.
            @"sideEffects": step.attempted && (i == 2 || i == 4) ? @"possible" : @"no"}];
    }
    result[@"readEvents"] = events;
    if (file.metadataAvailable) {
        result[@"before"] = metadata(file.before);
        result[@"between"] = metadata(file.between);
        result[@"after"] = metadata(file.after);
        result[@"first"] = [NSData dataWithBytes:file.first length:file.length];
        result[@"second"] = [NSData dataWithBytes:file.second length:file.length];
    }
    if (file.namedAvailable) result[@"namedAfter"] = metadata(file.namedAfter);
    LocusFreeEvidenceFile(&file);
    return result;
}

NSDictionary<NSString *, id> *LocusCopyMobileGestaltEvidenceFile(void)
{
    // Passive: no authorization, workspace, MG loading or query.
    return fileDictionary(LocusReadEvidenceFile(backingPath));
}

static void evidenceEvent(NSMutableDictionary *audit, NSString *stage, NSString *status,
                          NSTimeInterval start, id error, NSString *reason)
{
    [audit[@"events"] addObject:@{@"id": stage, @"status": status,
        @"elapsedMilliseconds": @((NSProcessInfo.processInfo.systemUptime - start) * 1000),
        @"errno": error ?: NSNull.null, @"reason": reason,
        @"sideEffects": [stage isEqualToString:@"authorization-result"] ? @"possible" : @"no"}];
}

NSDictionary<NSString *, id> *LocusCopyAuthorizedMobileGestaltEvidenceFile(BOOL userConfirmed)
{
    NSMutableDictionary *audit = [@{@"requested": @(userConfirmed), @"events": [NSMutableArray array]} mutableCopy];
    NSMutableDictionary *file = [@{@"stable": @NO, @"stage": @"authorization-not-confirmed"} mutableCopy];
    NSTimeInterval start = NSProcessInfo.processInfo.systemUptime;
    if (!userConfirmed) {
        evidenceEvent(audit, @"authorization-requested", @"INCOMPLETE", start, nil, @"user-not-confirmed");
        file[@"authorization"] = audit;
        return file;
    }
    // The bridge uses a temporary App Group symlink only during its query.
    // It restores that workspace BEFORE returning. Never read through it.
    NSDictionary *requestedEvent = @{@"id": @"authorization-requested", @"status": @"PASS",
        @"elapsedMilliseconds": @((NSProcessInfo.processInfo.systemUptime - start) * 1000),
        @"errno": NSNull.null, @"reason": @"user-confirmed", @"sideEffects": @"no"};
    WorseQueryLease *lease = [WorseQueryLease leaseForPath:@"/var/containers/Shared/SystemGroup/"
        "systemgroup.com.apple.mobilegestaltcache/Library/Caches" error:NULL audit:audit];
    // leaseForPath initializes the audit, so insert the request at its actual start.
    [audit[@"events"] insertObject:requestedEvent atIndex:0];
    audit[@"requested"] = @YES;
    audit[@"granted"] = @(lease != nil);
    evidenceEvent(audit, @"authorization-result", lease ? @"PASS" : @"INCOMPLETE", start,
                  audit[@"authorizationErrno"], lease ? @"lease-acquired-rights-not-introspected" :
                    (audit[@"failureReason"] ?: @"lease-not-acquired"));
    @try {
        if (lease) {
            NSNumber *device = audit[@"directoryDevice"], *inode = audit[@"directoryInode"];
            if (device && inode) {
                struct stat parent = {0};
                parent.st_dev = (dev_t)device.unsignedLongLongValue;
                parent.st_ino = (ino_t)inode.unsignedLongLongValue;
                evidenceEvent(audit, @"authorized-path-resolution", @"PASS", NSProcessInfo.processInfo.systemUptime,
                              nil, @"fixed-backing-path-selected-no-alias");
                file = fileDictionary(LocusReadEvidenceFileInDirectory(backingPath, &parent));
                [audit[@"events"] addObjectsFromArray:file[@"readEvents"]];
                [file removeObjectForKey:@"readEvents"];
            } else file[@"stage"] = @"authorization-directory-identity-unavailable";
        } else file[@"stage"] = @"authorization-unavailable";
    } @finally {
        [lease invalidateWithAudit:audit];
    }
    file[@"authorization"] = audit;
    return file;
}

static id sysctlString(const char *key)
{
    char buffer[256] = {0};
    size_t length = sizeof(buffer);
    if (sysctlbyname(key, buffer, &length, NULL, 0) || !length || length > sizeof(buffer) || buffer[length - 1])
        return NSNull.null;
    return [[NSString alloc] initWithBytes:buffer length:length - 1 encoding:NSUTF8StringEncoding] ?: (id)NSNull.null;
}

NSDictionary<NSString *, id> *LocusCopyEvidenceDeviceIdentity(void)
{
    NSOperatingSystemVersion os = NSProcessInfo.processInfo.operatingSystemVersion;
    NSString *version = [NSString stringWithFormat:@"%ld.%ld%@", (long)os.majorVersion, (long)os.minorVersion,
        os.patchVersion ? [NSString stringWithFormat:@".%ld", (long)os.patchVersion] : @""];
    return @{@"productType": sysctlString("hw.machine"), @"build": sysctlString("kern.osversion"),
        @"systemVersion": version, @"pid": @(getpid()),
        @"source": @"hw.machine / kern.osversion / NSProcessInfo; unavailable fields are null"};
}
