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
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <unistd.h>

typedef CFTypeRef (*MGCopyAnswerFunction)(
    CFStringRef question,
    CFDictionaryRef _Nullable options
);

static NSString * const LocusGestaltFileName =
    @"com.apple.MobileGestalt.plist";
static NSString * const LocusGestaltReadDirectory =
    @"/private/var/containers/Shared/SystemGroup/"
     "systemgroup.com.apple.mobilegestaltcache/Library/Caches";
static NSString * const LocusGestaltLeaseDirectory =
    @"/var/containers/Shared/SystemGroup/"
     "systemgroup.com.apple.mobilegestaltcache/Library/Caches";

static NSError *LocusGestaltError(NSInteger code, NSString *message)
{
    return [NSError errorWithDomain:@"io.github.tenkyuchimata.locus.mobilegestalt"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static BOOL LocusProbeCacheFile(NSString *path, BOOL writeAccess)
{
    int fd = open(path.fileSystemRepresentation, (writeAccess ? O_RDWR : O_RDONLY) |
                  O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) return NO;
    struct stat state;
    int failure = 0;
    if (fstat(fd, &state) != 0) failure = errno;
    else if (!S_ISREG(state.st_mode) || (writeAccess && state.st_nlink != 1)) failure = EINVAL;
    close(fd);
    errno = failure;
    return failure == 0;
}

@interface MobileGestaltAccess ()
@property(nonatomic, strong, nullable) WorseQueryLease *lease;
@property(nonatomic, copy, nullable) NSString *plistPath;
@end

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

- (BOOL)acquireLeaseRequiringWrite:(BOOL)requiringWrite
                             error:(NSError **)error
{
    NSString *readPath = [LocusGestaltReadDirectory
        stringByAppendingPathComponent:LocusGestaltFileName];
    if (self.lease.isActive && [self.plistPath isEqualToString:readPath]) {
        if (LocusProbeCacheFile(readPath, requiringWrite)) {
            if (error) {
                *error = nil;
            }
            return YES;
        }
    }

    [self.lease invalidate];
    self.lease = nil;
    self.plistPath = nil;

    if (!WorseQueryBridgeAvailable()) {
        if (error) {
            *error = LocusGestaltError(2, @"worse_query is unavailable.");
        }
        return NO;
    }

    // Upstream's App Group part query targets the existing cache directory.
    NSString *leasePath = LocusGestaltLeaseDirectory;
    NSString *leaseDetail = nil;
    WorseQueryLease *lease = [WorseQueryLease leaseForPath:leasePath
                                                 error:&leaseDetail];
    if (!lease) {
        if (error) {
            *error = LocusGestaltError(
                3,
                leaseDetail ?: @"Could not acquire the MobileGestalt sandbox extension."
            );
        }
        return NO;
    }

    if (!LocusProbeCacheFile(readPath, requiringWrite)) {
        int accessError = errno;
        [lease invalidate];
        if (error) {
            *error = LocusGestaltError(
                4,
                [NSString stringWithFormat:
                    @"The MobileGestalt backing file is not %@ (errno=%d).",
                    requiringWrite ? @"writable" : @"readable",
                    accessError]
            );
        }
        return NO;
    }

    self.lease = lease;
    self.plistPath = readPath;
    if (error) {
        *error = nil;
    }
    return YES;
}

- (NSData *)readCacheDataWithError:(NSError **)error
{
    @synchronized (self) {
        if (![self acquireLeaseRequiringWrite:NO error:error]) {
            return nil;
        }

        NSError *readError = nil;
        NSData *data = [NSData dataWithContentsOfFile:self.plistPath
                                              options:NSDataReadingMappedIfSafe
                                                error:&readError];
        if (!data && error) {
            *error = readError ?: LocusGestaltError(5, @"Failed to read MobileGestalt.");
        } else if (error) {
            *error = nil;
        }
        return data ? [NSData dataWithData:data] : nil;
    }
}

- (NSDictionary<NSString *, id> *)cacheWriteAccessStatus
{
    @synchronized (self) {
        NSError *error = nil;
        BOOL writable = [self acquireLeaseRequiringWrite:YES error:&error];
        return @{@"writable": @(writable), @"error": error.localizedDescription ?: (id)NSNull.null};
    }
}

- (BOOL)replaceCacheData:(NSData *)expected withData:(NSData *)replacement error:(NSError **)error
{
    @synchronized (self) {
        if (![self acquireLeaseRequiringWrite:YES error:error]) return NO;
        LocusFileOutcome outcome = LocusFileUnchanged;
        int rc = LocusReplaceFile(self.plistPath.fileSystemRepresentation, expected.bytes, expected.length,
                                  replacement.bytes, replacement.length, &outcome);
        if (rc != 0 && error) *error = LocusGestaltError(50,
            [NSString stringWithFormat:@"MobileGestalt compare-and-replace failed (errno=%d, outcome=%d: 0=unchanged, 2=rollback verified, 3=recovery required).", errno, outcome]);
        if (rc == 0 && error) *error = nil;
        return rc == 0;
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
