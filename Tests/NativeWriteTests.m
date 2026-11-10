// SPDX-License-Identifier: GPL-3.0-only
// Execute the actual in-place writers against temporary files, with one-shot
// partial-write/fsync faults. No system path or sandbox grant is accessed.
#import <Foundation/Foundation.h>
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

static ssize_t TestWrite(int, const void *, size_t);
static int TestSync(int);
#define write TestWrite
#define fsync TestSync
#if LOCUS_TEST_ACTIVATION
#import "../Locus/LowLevel/MobileActivationRegionAccess.m"
#define Rewrite LocusRewriteExistingActivationFile
#else
#import "../Locus/LowLevel/MobileGestaltAccess.m"
#define Rewrite LocusRewriteExistingFile
#endif
#undef write
#undef fsync

static int partialWrite;
static BOOL failSync;
static ssize_t TestWrite(int fd, const void *data, size_t size)
{
    if (partialWrite == 1 && size > 1) { partialWrite = 2; return write(fd, data, 1); }
    if (partialWrite == 2) { partialWrite = 0; errno = ENOSPC; return -1; }
    return write(fd, data, size);
}
static int TestSync(int fd)
{
    if (failSync) { failSync = NO; errno = EIO; return -1; }
    return fsync(fd);
}

int main(void)
{
    @autoreleasepool {
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        assert([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:NO attributes:nil error:NULL]);
        NSString *path = [directory stringByAppendingPathComponent:@"original.plist"];
        const unsigned char raw[] = {0, 0xFF, 3, 27, 10, 0};
        NSData *original = [NSData dataWithBytes:raw length:sizeof(raw)];
        NSData *replacement = [@"different replacement bytes" dataUsingEncoding:NSUTF8StringEncoding];
        assert([original writeToFile:path atomically:NO]);
        struct stat before, after;
        assert(lstat(path.fileSystemRepresentation, &before) == 0);
        NSError *error = nil;
        assert(Rewrite(path, replacement, 20, &error) && error == nil);
        assert(lstat(path.fileSystemRepresentation, &after) == 0 && after.st_ino == before.st_ino);
        assert([[NSData dataWithContentsOfFile:path] isEqualToData:replacement]);
        assert(Rewrite(path, original, 20, &error));
        partialWrite = 1;
        assert(!Rewrite(path, replacement, 20, &error) && error);
        assert([[NSData dataWithContentsOfFile:path] isEqualToData:original]);
        failSync = YES;
        assert(!Rewrite(path, replacement, 20, &error) && error);
        assert([[NSData dataWithContentsOfFile:path] isEqualToData:original]);
        NSString *alias = [directory stringByAppendingPathComponent:@"alias.plist"];
        assert([NSFileManager.defaultManager createSymbolicLinkAtPath:alias withDestinationPath:path error:NULL]);
        assert(!Rewrite(alias, replacement, 20, &error));
        assert([[NSData dataWithContentsOfFile:path] isEqualToData:original]);
        assert(lstat(path.fileSystemRepresentation, &after) == 0 && after.st_ino == before.st_ino);
        assert([NSFileManager.defaultManager removeItemAtPath:directory error:NULL]);
        puts("PASS: actual in-place writer, inode retention, partial-write rollback, fsync rollback and symlink refusal");
    }
}
