// SPDX-License-Identifier: GPL-3.0-only
// Compile the actual ObjC adapter; redirect its production file path into /tmp.
#import <Foundation/Foundation.h>
#import <assert.h>
#import <string.h>
#import <stdlib.h>
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
int main(void)
{
    @autoreleasepool {
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        assert([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:NO attributes:nil error:NULL]);
        NSString *path = [[directory stringByAppendingPathComponent:@"input"] stringByResolvingSymlinksInPath];
        char *pathCopy = strdup(path.fileSystemRepresentation);
        assert(pathCopy);
        fixturePath = pathCopy;
        NSData *fixture = [@"synthetic-only" dataUsingEncoding:NSUTF8StringEncoding];
        assert([fixture writeToFile:path atomically:YES]);
        NSDictionary *file = LocusCopyMobileGestaltEvidenceFile();
        assert([file[@"stable"] boolValue] && [file[@"errno"] intValue] == 0);
        assert([file[@"first"] isEqual:fixture] && [file[@"second"] isEqual:fixture]);
        assert([file[@"before"] isEqual:file[@"between"]] && [file[@"before"] isEqual:file[@"after"]]);
        assert([file[@"before"] isEqual:file[@"namedAfter"]]);
        assert(LocusCopyEvidenceDeviceIdentity()[@"productType"]); // macOS identity, never a claimed iPhone.
        assert([NSFileManager.defaultManager removeItemAtPath:path error:NULL]);
        file = LocusCopyMobileGestaltEvidenceFile();
        assert(![file[@"stable"] boolValue] && [file[@"errno"] intValue] != 0 && !file[@"first"]);
        assert([NSFileManager.defaultManager removeItemAtPath:directory error:NULL]);
        free(pathCopy);
        puts("PASS: actual Objective-C evidence adapter, same-fd metadata/bytes and unavailable file, synthetic /tmp fixture only");
    }
}
