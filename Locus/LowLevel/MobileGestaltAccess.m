//
//  MobileGestaltAccess.m
//  Locus
//
//  The in-place rewrite and bad_query lease behavior are retained from the
//  MIT-licensed GestaltEdit implementation. Replacing the backing inode is
//  deliberately avoided.
//

#import "MobileGestaltAccess.h"
#import "BadQueryBridge.h"

#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <stdint.h>
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
static NSString * const LocusVerifiedJapanBuild = @"24A5390f";

static NSError *LocusGestaltError(NSInteger code, NSString *message)
{
    return [NSError errorWithDomain:@"io.github.tenkyuchimata.locus.mobilegestalt"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static BOOL LocusWriteAll(int fd, NSData *data)
{
    const uint8_t *bytes = data.bytes;
    NSUInteger remaining = data.length;

    while (remaining > 0) {
        ssize_t written = write(fd, bytes, remaining);
        if (written < 0 && errno == EINTR) {
            continue;
        }
        if (written <= 0) {
            return NO;
        }
        bytes += written;
        remaining -= (NSUInteger)written;
    }
    return YES;
}

static BOOL LocusRewriteDescriptor(int fd, NSData *data)
{
    if (fd < 0 || !data || ftruncate(fd, 0) != 0 ||
        lseek(fd, 0, SEEK_SET) < 0 || !LocusWriteAll(fd, data) ||
        fsync(fd) != 0) {
        return NO;
    }
    return YES;
}

static BOOL LocusRewriteExistingFile(
    NSString *path,
    NSData *replacement,
    NSInteger errorCode,
    NSError **error
)
{
    NSError *readError = nil;
    NSData *original = [NSData dataWithContentsOfFile:path
                                              options:0
                                                error:&readError];
    if (!original) {
        if (error) {
            *error = readError ?: LocusGestaltError(
                errorCode,
                @"Could not read the original MobileGestalt bytes."
            );
        }
        return NO;
    }

    int fd = open(path.fileSystemRepresentation,
                  O_WRONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) {
        if (error) {
            *error = LocusGestaltError(
                errorCode + 1,
                [NSString stringWithFormat:
                    @"Could not open MobileGestalt for an in-place rewrite (errno=%d).",
                    errno]
            );
        }
        return NO;
    }

    BOOL wrote = LocusRewriteDescriptor(fd, replacement);
    int writeErrno = errno;
    if (!wrote) {
        (void)LocusRewriteDescriptor(fd, original);
        close(fd);
        if (error) {
            *error = LocusGestaltError(
                errorCode + 2,
                [NSString stringWithFormat:
                    @"MobileGestalt rewrite failed (errno=%d); original bytes were restored best-effort.",
                    writeErrno]
            );
        }
        return NO;
    }
    close(fd);

    NSData *verification = [NSData dataWithContentsOfFile:path];
    if (![verification isEqualToData:replacement]) {
        int rollbackFD = open(path.fileSystemRepresentation,
                              O_WRONLY | O_CLOEXEC | O_NOFOLLOW);
        if (rollbackFD >= 0) {
            (void)LocusRewriteDescriptor(rollbackFD, original);
            close(rollbackFD);
        }
        if (error) {
            *error = LocusGestaltError(
                errorCode + 3,
                @"MobileGestalt byte-for-byte verification failed; original bytes were restored best-effort."
            );
        }
        return NO;
    }

    if (error) {
        *error = nil;
    }
    return YES;
}

@interface MobileGestaltAccess ()
@property(nonatomic, strong, nullable) BadQueryLease *lease;
@property(nonatomic, copy, nullable) NSString *plistPath;
@property(nonatomic) NSPropertyListFormat lastReadFormat;
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

+ (BOOL)japanMutationBuildSupported
{
    return [[self currentOSBuild] isEqualToString:LocusVerifiedJapanBuild];
}

- (BOOL)acquireLeaseRequiringWrite:(BOOL)requiringWrite
                             error:(NSError **)error
{
    if (requiringWrite && ![MobileGestaltAccess japanMutationBuildSupported]) {
        NSString *currentBuild = [MobileGestaltAccess currentOSBuild];
        if (error) {
            *error = LocusGestaltError(
                1,
                [NSString stringWithFormat:
                    @"Japan Region mutation is verified only on %@; current build is %@.",
                    LocusVerifiedJapanBuild,
                    currentBuild.length > 0 ? currentBuild : @"<unknown>"]
            );
        }
        return NO;
    }

    NSString *readPath = [LocusGestaltReadDirectory
        stringByAppendingPathComponent:LocusGestaltFileName];
    if (self.lease.isActive && [self.plistPath isEqualToString:readPath]) {
        int flags = requiringWrite ? O_RDWR : O_RDONLY;
        int fd = open(readPath.fileSystemRepresentation,
                      flags | O_CLOEXEC | O_NOFOLLOW);
        if (fd >= 0) {
            close(fd);
            if (error) {
                *error = nil;
            }
            return YES;
        }
    }

    [self.lease invalidate];
    self.lease = nil;
    self.plistPath = nil;

    if (!BadQueryBridgeAvailable()) {
        if (error) {
            *error = LocusGestaltError(2, @"bad_query is unavailable.");
        }
        return NO;
    }

    NSString *leasePath = [LocusGestaltLeaseDirectory
        stringByAppendingPathComponent:LocusGestaltFileName];
    NSString *leaseDetail = nil;
    BadQueryLease *lease = [BadQueryLease leaseForPath:leasePath
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

    int flags = requiringWrite ? O_RDWR : O_RDONLY;
    int fd = open(readPath.fileSystemRepresentation,
                  flags | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) {
        [lease invalidate];
        if (error) {
            *error = LocusGestaltError(
                4,
                [NSString stringWithFormat:
                    @"The MobileGestalt backing file is not %@ (errno=%d).",
                    requiringWrite ? @"writable" : @"readable",
                    errno]
            );
        }
        return NO;
    }
    close(fd);

    self.lease = lease;
    self.plistPath = readPath;
    if (error) {
        *error = nil;
    }
    return YES;
}

- (NSData *)readCacheDataWithError:(NSError **)error
{
    if (![self acquireLeaseRequiringWrite:NO error:error]) {
        return nil;
    }

    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfFile:self.plistPath
                                          options:NSDataReadingMappedIfSafe
                                            error:&readError];
    if (data) {
        NSPropertyListFormat detectedFormat = NSPropertyListBinaryFormat_v1_0;
        id detected = [NSPropertyListSerialization propertyListWithData:data
                                                                 options:0
                                                                  format:&detectedFormat
                                                                   error:NULL];
        if ([detected isKindOfClass:NSDictionary.class]) {
            self.lastReadFormat = detectedFormat;
        }
    }
    if (!data && error) {
        *error = readError ?: LocusGestaltError(5, @"Failed to read MobileGestalt.");
    } else if (error) {
        *error = nil;
    }
    return data ? [NSData dataWithData:data] : nil;
}

- (NSDictionary *)readCachePlistWithError:(NSError **)error
{
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
    self.lastReadFormat = format;
    if (error) {
        *error = nil;
    }
    return value;
}

- (BOOL)saveCachePlist:(NSDictionary *)plist error:(NSError **)error
{
    if (![self acquireLeaseRequiringWrite:YES error:error]) {
        return NO;
    }
    if (![plist isKindOfClass:NSDictionary.class]) {
        if (error) {
            *error = LocusGestaltError(7, @"The MobileGestalt replacement is not a dictionary.");
        }
        return NO;
    }

    NSPropertyListFormat format = self.lastReadFormat;
    if (format != NSPropertyListXMLFormat_v1_0 &&
        format != NSPropertyListBinaryFormat_v1_0) {
        format = NSPropertyListBinaryFormat_v1_0;
    }
    NSError *serializationError = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist
                                                              format:format
                                                             options:0
                                                               error:&serializationError];
    if (!data) {
        if (error) {
            *error = serializationError ?: LocusGestaltError(
                8,
                @"Failed to serialize MobileGestalt."
            );
        }
        return NO;
    }
    return LocusRewriteExistingFile(self.plistPath, data, 20, error);
}

- (BOOL)restoreCacheData:(NSData *)data error:(NSError **)error
{
    if (![self acquireLeaseRequiringWrite:YES error:error]) {
        return NO;
    }
    if (![data isKindOfClass:NSData.class] || data.length == 0) {
        if (error) {
            *error = LocusGestaltError(30, @"The MobileGestalt backup is empty.");
        }
        return NO;
    }
    return LocusRewriteExistingFile(self.plistPath, data, 31, error);
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
