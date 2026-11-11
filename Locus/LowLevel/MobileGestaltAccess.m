//
//  MobileGestaltAccess.m
//  Locus
//
//  The in-place rewrite and worse_query lease behavior are retained from the
//  MIT-licensed GestaltEdit implementation. Replacing the backing inode is
//  deliberately avoided.
//

#import "MobileGestaltAccess.h"
#import "WorseQueryBridge.h"
#import "InPlaceFileTransaction.h"

#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <stdint.h>
#import <string.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <unistd.h>

typedef CFTypeRef (*MGCopyAnswerFunction)(
    CFStringRef question,
    CFDictionaryRef _Nullable options
);

// Fixed system path only. Ancestor symlinks are resolved by the OS; O_NOFOLLOW
// protects the final file, not each directory in this trusted system path.
static NSString * const LocusGestaltPath =
    @"/private/var/containers/Shared/SystemGroup/"
     "systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist";
static NSString * const LocusGestaltLeaseDirectory =
    @"/var/containers/Shared/SystemGroup/"
     "systemgroup.com.apple.mobilegestaltcache/Library/Caches";
static const off_t LocusGestaltMaxFileSize = 16 * 1024 * 1024;

static NSError *LocusGestaltError(NSInteger code, NSString *message)
{
    return [NSError errorWithDomain:@"io.github.tenkyuchimata.locus.mobilegestalt"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation MobileGestaltAccess

+ (instancetype)shared
{
    static MobileGestaltAccess *access;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        access = [MobileGestaltAccess new];
    });
    return access;
}

+ (NSString *)currentOSBuild
{
    size_t length = 0;
    if (sysctlbyname("kern.osversion", NULL, &length, NULL, 0) != 0 ||
        length == 0) {
        return @"";
    }

    NSMutableData *data = [NSMutableData dataWithLength:length];
    if (sysctlbyname("kern.osversion", data.mutableBytes, &length, NULL, 0) != 0) {
        return @"";
    }
    return [NSString stringWithUTF8String:data.bytes] ?: @"";
}

- (WorseQueryLease *)acquireLeaseWithError:(NSError **)error
{
    NSString *detail = nil;
    WorseQueryLease *lease = [WorseQueryLease leaseForPath:LocusGestaltLeaseDirectory error:&detail];
    if (error) *error = lease ? nil : LocusGestaltError(3, detail ?: @"MobileGestalt access denied.");
    return lease;
}

- (NSData *)readCacheDataWithError:(NSError **)error
{
    @synchronized (self) {
        WorseQueryLease *lease = [self acquireLeaseWithError:error];
        if (!lease) return nil;
        int fd = -1;
        @try {
            fd = open(LocusGestaltPath.fileSystemRepresentation,
                      O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
            if (fd < 0) {
                if (error) *error = LocusGestaltError(4,
                    [NSString stringWithFormat:@"Cannot open MobileGestalt: %s (errno=%d).", strerror(errno), errno]);
                return nil;
            }
            struct stat state;
            if (fstat(fd, &state) != 0) {
                if (error) *error = LocusGestaltError(5, @"Cannot inspect the MobileGestalt file.");
                return nil;
            }
            if (!S_ISREG(state.st_mode) || state.st_size <= 0 || state.st_size > LocusGestaltMaxFileSize) {
                if (error) *error = LocusGestaltError(6, @"MobileGestalt must be a nonempty regular file no larger than 16 MiB.");
                return nil;
            }
            NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)state.st_size];
            NSUInteger offset = 0;
            while (offset < data.length) {
                ssize_t count = read(fd, (uint8_t *)data.mutableBytes + offset, data.length - offset);
                if (count < 0 && errno == EINTR) continue;
                if (count <= 0) {
                    if (error) *error = LocusGestaltError(7, @"Could not read the complete MobileGestalt file. Refresh to retry.");
                    return nil;
                }
                offset += (NSUInteger)count;
            }
            if (error) *error = nil;
            return data;
        } @finally {
            if (fd >= 0) close(fd);
            [lease invalidate];
        }
    }
}

- (NSDictionary<NSString *, id> *)cacheWriteAccessStatus
{
    @synchronized (self) {
        NSError *error = nil;
        WorseQueryLease *lease = [self acquireLeaseWithError:&error];
        BOOL writable = NO;
        if (lease) {
            @try {
                int fd = open(LocusGestaltPath.fileSystemRepresentation,
                              O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
                if (fd >= 0) {
                    struct stat state;
                    writable = fstat(fd, &state) == 0 && S_ISREG(state.st_mode) && state.st_nlink == 1;
                    close(fd);
                }
                if (!writable) error = LocusGestaltError(4, @"The MobileGestalt file is not writable or is not a single-link regular file.");
            } @finally {
                [lease invalidate];
            }
        }
        return @{@"writable": @(writable), @"error": error.localizedDescription ?: (id)NSNull.null};
    }
}

- (BOOL)replaceCacheData:(NSData *)expected withData:(NSData *)replacement error:(NSError **)error
{
    @synchronized (self) {
        WorseQueryLease *lease = [self acquireLeaseWithError:error];
        if (!lease) return NO;
        @try {
            LocusFileOutcome outcome = LocusFileUnchanged;
            int rc = LocusReplaceFile(LocusGestaltPath.fileSystemRepresentation, expected.bytes, expected.length,
                                      replacement.bytes, replacement.length, &outcome);
            if (rc != 0 && error) *error = LocusGestaltError(50,
                [NSString stringWithFormat:@"MobileGestalt compare-and-replace failed (errno=%d, outcome=%d: 0=unchanged, 2=rollback verified, 3=recovery required).", errno, outcome]);
            if (rc == 0 && error) *error = nil;
            return rc == 0;
        } @finally {
            [lease invalidate];
        }
    }
}

- (NSDictionary *)readCachePlistWithError:(NSError **)error
{
    @synchronized (self) {
        NSData *data = [self readCacheDataWithError:error];
        if (!data) {
            return nil;
        }

        NSPropertyListFormat format = NSPropertyListBinaryFormat_v1_0;
        NSError *parseError = nil;
        id value = [NSPropertyListSerialization propertyListWithData:data
                                                             options:0
                                                              format:&format
                                                               error:&parseError];
        if (![value isKindOfClass:NSDictionary.class]) {
            if (error) {
                *error = parseError ?: LocusGestaltError(
                    6,
                    @"The MobileGestalt plist is not a dictionary."
                );
            }
            return nil;
        }
        if (error) {
            *error = nil;
        }
        return value;
    }
}

- (NSDictionary<NSString *, id> *)runtimeAnswersForQuestions:
    (NSArray<NSString *> *)questions
    error:(NSError **)error
{
    if (questions.count == 0) {
        if (error) {
            *error = nil;
        }
        return @{};
    }

    void *handle = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY | RTLD_LOCAL);
    if (!handle) {
        if (error) {
            *error = LocusGestaltError(
                40,
                [NSString stringWithFormat:@"Failed to load libMobileGestalt: %s",
                    dlerror() ?: "unknown error"]
            );
        }
        return nil;
    }

    dlerror();
    MGCopyAnswerFunction copyAnswer =
        (MGCopyAnswerFunction)dlsym(handle, "MGCopyAnswer");
    const char *symbolError = dlerror();
    if (!copyAnswer || symbolError) {
        if (error) {
            *error = LocusGestaltError(
                41,
                [NSString stringWithFormat:@"Failed to resolve MGCopyAnswer: %s",
                    symbolError ?: "symbol unavailable"]
            );
        }
        dlclose(handle);
        return nil;
    }

    NSMutableDictionary<NSString *, id> *answers =
        [NSMutableDictionary dictionaryWithCapacity:questions.count];
    for (NSString *question in questions) {
        if (![question isKindOfClass:NSString.class] || question.length == 0) {
            continue;
        }
        CFTypeRef answer = copyAnswer((__bridge CFStringRef)question, NULL);
        if (!answer) {
            answers[question] = NSNull.null;
        } else {
            answers[question] = (__bridge id)answer;
            CFRelease(answer);
        }
    }
    dlclose(handle);
    if (error) {
        *error = nil;
    }
    return [answers copy];
}

@end
