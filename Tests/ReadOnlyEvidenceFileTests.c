// SPDX-License-Identifier: GPL-3.0-only
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
static ssize_t testPread(int, void *, size_t, off_t);
static int testOpenat(int, const char *, int, ...);
static int testOpen(const char *, int, ...);
#define pread testPread
#define openat testOpenat
#define open testOpen
#include "../Locus/LowLevel/ReadOnlyEvidenceFile.c"
#undef pread
#undef openat
#undef open
static int fault, readCalls;
static void put(const char *path);
static const char *testPath;
static ssize_t testPread(int fd, void *buffer, size_t size, off_t offset)
{
    readCalls++;
    if (fault == 2 || (fault == 8 && readCalls >= 3)) { errno = EACCES; return -1; }
    ssize_t count = pread(fd, buffer, size, offset);
    if ((fault == 1 || fault == 3 || fault == 4) && readCalls == 2) {
        // Mutating ONLY a synthetic /tmp fixture to exercise concurrent writers.
        int writer = open(testPath, O_WRONLY);
        assert(writer >= 0);
        if (fault == 1) assert(pwrite(writer, "X", 1, 0) == 1);
        if (fault == 3) assert(ftruncate(writer, 2) == 0);
        if (fault == 4) {
            struct timespec times[2] = {{1, 0}, {2, 0}};
            assert(futimens(writer, times) == 0); // metadata-only change
        }
        assert(close(writer) == 0);
    }
    return count;
}
static int testOpenat(int fd, const char *path, int flags, ...)
{
    assert((flags & O_ACCMODE) == O_RDONLY);
    assert(flags & O_NOFOLLOW);
    assert(!(flags & (O_CREAT | O_TRUNC)));
    if (fault == 5) { errno = EACCES; return -1; }
    if (fault == 9) { errno = EPERM; return -1; }
    if (fault == 11 && (flags & O_DIRECTORY)) { errno = EPERM; return -1; }
    if (fault == 6 && readCalls >= 4) { errno = ENOENT; return -1; }
    if ((fault == 7 || fault == 10) && readCalls >= 4 && !strcmp(path, "input")) {
        char backup[PATH_MAX];
        snprintf(backup, sizeof(backup), "%s.old", testPath);
        assert(rename(testPath, backup) == 0);
        if (fault == 7) put(testPath); // Same bytes/size, different inode.
        else assert(symlink(backup, testPath) == 0);
    }
    return openat(fd, path, flags);
}
static int testOpen(const char *path, int flags, ...)
{
    assert(!strcmp(path, "/"));
    assert((flags & O_ACCMODE) == O_RDONLY && (flags & O_NOFOLLOW));
    assert(!(flags & (O_CREAT | O_TRUNC)));
    return open(path, flags);
}
static void put(const char *path)
{
    int fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0600);
    assert(fd >= 0 && write(fd, "fixture", 7) == 7 && close(fd) == 0);
}
static LocusEvidenceFile observe(const char *path, int selectedFault)
{
    testPath = path; fault = selectedFault; readCalls = 0;
    return LocusReadEvidenceFile(path);
}
int main(void)
{
    char temporary[] = "/tmp/LocusEvidenceFile.XXXXXX";
    assert(mkdtemp(temporary));
    char *root = realpath(temporary, NULL);
    assert(root);
    char path[PATH_MAX], link[PATH_MAX], nested[PATH_MAX], dirlink[PATH_MAX];
    snprintf(path, sizeof(path), "%s/input", root);
    snprintf(link, sizeof(link), "%s/link", root);
    snprintf(dirlink, sizeof(dirlink), "%s/parent", root);
    snprintf(nested, sizeof(nested), "%s/parent/input", root);
    put(path);
    LocusEvidenceFile r = observe(path, 0);
    assert(r.stable && r.error == 0 && r.length == 7 && r.metadataAvailable && r.namedAvailable);
    assert(!memcmp(r.first, "fixture", 7) && !memcmp(r.first, r.second, 7));
    LocusFreeEvidenceFile(&r);
    for (int i = 0; i < LocusEvidenceReadStepCount; i++) assert(r.steps[i].completed && r.steps[i].elapsedMilliseconds >= 0);
    for (int selected = 1; selected <= 10; selected++) {
        put(path);
        r = observe(path, selected);
        assert(!r.stable && r.error != 0);
        if (selected == 1 || selected == 4) assert(r.error == EBUSY && r.metadataAvailable);
        if (selected == 2 || selected == 3) assert(!r.first && !r.second);
        if (selected == 5) assert(r.error == EACCES);
        if (selected == 8) assert(r.error == EACCES && !r.first && r.steps[2].completed && !r.steps[4].completed);
        if (selected == 9) assert(r.error == EPERM && r.failedComponent > 0 && !r.first);
        if (selected == 7 || selected == 10) {
            if (selected == 7) assert(r.error == EBUSY && r.before.st_ino != r.namedAfter.st_ino);
            else { assert(!r.namedAvailable && r.error); assert(unlink(path) == 0); put(path); }
            char backup[PATH_MAX];
            snprintf(backup, sizeof(backup), "%s.old", path);
            assert(unlink(backup) == 0);
        }
        LocusFreeEvidenceFile(&r);
    }
    assert(symlink(path, link) == 0 && symlink(root, dirlink) == 0);
    r = observe(link, 0); assert(r.error && !r.stable); LocusFreeEvidenceFile(&r);
    r = observe(nested, 0); assert(r.error && !r.stable); LocusFreeEvidenceFile(&r);
    // Authorized callers use the very same no-follow reader, pinned to the
    // independently observed lease directory. No alias is trusted by spelling.
    struct stat parent;
    assert(stat(root, &parent) == 0);
    // A full-path file open can succeed while a policy denies opening an
    // ancestor directory for reading. This SIMULATES a scope difference; it
    // does not establish the cause of any device's EPERM.
    int direct = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    assert(direct >= 0 && close(direct) == 0);
    r = observe(path, 11); assert(r.error == EPERM && !r.first); LocusFreeEvidenceFile(&r);
    r = LocusReadEvidenceFileInDirectory(path, &parent);
    assert(r.error == EPERM && !r.first); LocusFreeEvidenceFile(&r);
    fault = 0; readCalls = 0;
    r = LocusReadEvidenceFileInDirectory(path, &parent);
    assert(r.stable && !r.error); LocusFreeEvidenceFile(&r);
    for (int selected = 1; selected <= 10; selected++) {
        put(path); testPath = path; fault = selected; readCalls = 0;
        r = LocusReadEvidenceFileInDirectory(path, &parent);
        assert(!r.stable && r.error);
        if (selected == 9) assert(r.error == EPERM);
        if (selected == 7 || selected == 10) {
            char backup[PATH_MAX]; snprintf(backup, sizeof(backup), "%s.old", path);
            assert(unlink(path) == 0 && unlink(backup) == 0); put(path);
        }
        LocusFreeEvidenceFile(&r);
    }
    fault = 0; readCalls = 0;
    r = LocusReadEvidenceFileInDirectory(link, &parent); assert(r.error); LocusFreeEvidenceFile(&r);
    r = LocusReadEvidenceFileInDirectory(nested, &parent); assert(r.error); LocusFreeEvidenceFile(&r);
    // Wrong-target symlink is refused as strictly as a correct-target alias.
    assert(unlink(link) == 0 && symlink("/does-not-exist", link) == 0);
    r = LocusReadEvidenceFileInDirectory(link, &parent); assert(r.error); LocusFreeEvidenceFile(&r);
    parent.st_ino++;
    r = LocusReadEvidenceFileInDirectory(path, &parent);
    assert(r.error == ESTALE && !r.first && !r.stable); LocusFreeEvidenceFile(&r);
    // Canonicalize only the created test fixture, never a production input.
    char *canonical = realpath(nested, NULL);
    assert(canonical);
    r = observe(canonical, 0); assert(r.stable && r.error == 0); LocusFreeEvidenceFile(&r);
    free(canonical);
    r = observe(root, 0); assert(r.error == EINVAL); LocusFreeEvidenceFile(&r);
    r = observe("relative", 0); assert(r.error == EINVAL); LocusFreeEvidenceFile(&r);
    int fd = open(path, O_WRONLY | O_TRUNC);
    assert(fd >= 0 && ftruncate(fd, 8 * 1024 * 1024 + 1) == 0 && close(fd) == 0);
    r = observe(path, 0); assert(r.error == EINVAL); LocusFreeEvidenceFile(&r);
    assert(unlink(link) == 0 && unlink(dirlink) == 0 && unlink(path) == 0 && rmdir(root) == 0);
    free(root);
    puts("PASS: actual read-only file reader in passive/authorized modes; stable double read, second-read failure, byte/size/metadata/inode changes, EPERM including ancestor scope, symlink parents/leaf/wrong-target/replacement, pinned parent and bounds; synthetic policy only");
}
