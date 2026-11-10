// SPDX-License-Identifier: GPL-3.0-only
#import "MobileGestaltEvidence.h"
#import "ReadOnlyEvidenceFile.h"
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

NSDictionary<NSString *, id> *LocusCopyMobileGestaltEvidenceFile(void)
{
    // Do not call MobileGestaltAccess's lease path: it can create App Group
    // symlinks and query ContainerManager. Denied direct reads are evidence.
    LocusEvidenceFile file = LocusReadEvidenceFile("/private/var/containers/Shared/SystemGroup/"
        "systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist");
    NSMutableDictionary *result = [@{@"stable": @(file.stable), @"errno": @(file.error),
        @"stage": @(file.stage), @"source": @"MobileGestalt backing plist (direct read, no lease)"} mutableCopy];
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
