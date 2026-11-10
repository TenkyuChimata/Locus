// SPDX-License-Identifier: GPL-3.0-only
// Compile the actual ObjC adapter; redirect its production file path into /tmp.
#import <Foundation/Foundation.h>
#import <assert.h>
#import <string.h>
#import <stdlib.h>
#import <stdio.h>
#import <errno.h>
#import "../Locus/LowLevel/ReadOnlyEvidenceFile.h"
static const char *fixturePath;
static LocusEvidenceFile TestRead(const char *path)
{
    assert(!strcmp(path, "/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist"));
    return LocusReadEvidenceFile(fixturePath);
}
#define LocusReadEvidenceFile TestRead
#import "../Locus/LowLevel/MobileGestaltEvidence.m"
#undef LocusReadEvidenceFile
static void Diagnose(NSDictionary *file, const char *label)
{
    fprintf(stderr, "Evidence file diagnostic (%s): stage=%s errno=%d stable=%s\n", label,
        [file[@"stage"] UTF8String] ?: "missing", [file[@"errno"] intValue],
        [file[@"stable"] boolValue] ? "true" : "false");
    if ([file[@"errno"] intValue]) fprintf(stderr, "  errno description: %s\n", strerror([file[@"errno"] intValue]));
    fflush(stderr);
}
int main(void)
{
    @autoreleasepool {
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        assert([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:NO attributes:nil error:NULL]);
        NSString *path = [[directory stringByAppendingPathComponent:@"input"] stringByResolvingSymlinksInPath];
        NSData *fixture = [@"synthetic-only" dataUsingEncoding:NSUTF8StringEncoding];
        assert([fixture writeToFile:path atomically:YES]);
        // Keep the old setup observable: establish whether its failure really
        // is a path/symlink refusal before supplying a canonical fixture path.
        fixturePath = path.fileSystemRepresentation;
        NSDictionary *candidate = LocusCopyMobileGestaltEvidenceFile();
        Diagnose(candidate, "before realpath (previous setup)");
        char *pathCopy = realpath(path.fileSystemRepresentation, NULL);
        if (!pathCopy) fprintf(stderr, "Fixture realpath failed: errno=%d (%s)\n", errno, strerror(errno));
        assert(pathCopy);
        BOOL samePath = !strcmp(path.fileSystemRepresentation, pathCopy);
        fprintf(stderr, "Fixture canonical path equals previous path: %s\n", samePath ? "true" : "false");
        fflush(stderr);
        if (![candidate[@"stable"] boolValue] || [candidate[@"errno"] intValue] != 0) {
            // A non-path failure must remain a failure, never a hidden retry.
            int failure = [candidate[@"errno"] intValue];
            assert(!samePath && [candidate[@"stage"] isEqual:@"open-read-only-no-follow"] &&
                (failure == ELOOP || failure == ENOTDIR));
        }
        fixturePath = pathCopy;
        NSDictionary *file = LocusCopyMobileGestaltEvidenceFile();
        Diagnose(file, "after realpath");
        assert([file[@"stable"] boolValue] && [file[@"errno"] intValue] == 0);
        assert([file[@"first"] isEqual:fixture] && [file[@"second"] isEqual:fixture]);
        assert([file[@"before"] isEqual:file[@"between"]] && [file[@"before"] isEqual:file[@"after"]]);
        assert([file[@"before"] isEqual:file[@"namedAfter"]]);
        assert(LocusCopyEvidenceDeviceIdentity()[@"productType"]); // macOS identity, never a claimed iPhone.
        assert([NSFileManager.defaultManager removeItemAtPath:path error:NULL]);
        file = LocusCopyMobileGestaltEvidenceFile();
        Diagnose(file, "removed fixture");
        assert(![file[@"stable"] boolValue] && [file[@"errno"] intValue] != 0 && !file[@"first"]);
        assert([NSFileManager.defaultManager removeItemAtPath:directory error:NULL]);
        free(pathCopy);
        puts("PASS: actual Objective-C evidence adapter, same-fd metadata/bytes and unavailable file, synthetic /tmp fixture only");
    }
}
