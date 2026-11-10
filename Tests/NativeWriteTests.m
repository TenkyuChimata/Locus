// SPDX-License-Identifier: GPL-3.0-only
// Actual Objective-C bridge and C writer, redirected to a temporary file.
// No device/system path or sandbox grant is accessed.
#import <Foundation/Foundation.h>
#import <assert.h>
#import <sys/stat.h>
#import "../Locus/LowLevel/MobileGestaltAccess.m"

@interface TestGestaltAccess : MobileGestaltAccess
@property(nonatomic) NSUInteger probes;
@end
@implementation TestGestaltAccess
- (BOOL)acquireLeaseRequiringWrite:(BOOL)write error:(NSError **)error
{
    (void)write;
    self.probes++;
    if (error) *error = nil;
    return YES;
}
@end
int main(void)
{
    @autoreleasepool {
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        assert([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:NO attributes:nil error:NULL]);
        NSString *path = [directory stringByAppendingPathComponent:@"cache.plist"];
        NSData *before = [NSPropertyListSerialization dataWithPropertyList:@{@"CacheExtra": @{@"field": @"before"}}
            format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
        NSData *after = [NSPropertyListSerialization dataWithPropertyList:@{@"CacheExtra": @{@"field": @"after"}}
            format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
        assert([before writeToFile:path atomically:NO]);
        struct stat a, b;
        assert(!lstat(path.fileSystemRepresentation, &a));
        TestGestaltAccess *access = [TestGestaltAccess new];
        access.plistPath = path;
        assert([access.cacheWriteAccessStatus[@"writable"] boolValue]);
        NSError *error = nil;
        assert([access replaceCacheData:before withData:after error:&error] && !error);
        assert([[access readCacheDataWithError:&error] isEqual:after]);
        assert(![access replaceCacheData:before withData:before error:&error] && error);
        assert([[access readCacheDataWithError:NULL] isEqual:after]);
        assert([access replaceCacheData:after withData:before error:&error] && !error);
        assert([[access readCacheDataWithError:NULL] isEqual:before]);
        assert(!lstat(path.fileSystemRepresentation, &b) && a.st_ino == b.st_ino);
        assert(access.probes >= 7);
        assert([NSFileManager.defaultManager removeItemAtPath:directory error:NULL]);
        puts("PASS: actual MobileGestalt bridge CAS, byte readback, stale refusal and inode retention (temporary file)");
    }
}
