// SPDX-License-Identifier: GPL-3.0-only
#include "InPlaceFileTransaction.h"
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

// Helpers return an explicit error code. errno is read only immediately after
// a failing syscall; successful calls may leave its value unspecified.
static int LocusExactBytes(int fd, const void *expected, size_t size)
{
    struct stat state;
    if (fstat(fd, &state)) return errno;
    if (!S_ISREG(state.st_mode) || state.st_size < 0 || (uintmax_t)state.st_size != size) return EIO;
    const unsigned char *bytes = expected;
    unsigned char block[8192];
    size_t offset = 0;
    while (offset < size) {
        size_t count = size - offset < sizeof(block) ? size - offset : sizeof(block);
        ssize_t got = pread(fd, block, count, (off_t)offset);
        if (got < 0) {
            int failure = errno;
            if (failure == EINTR) continue;
            return failure;
        }
        if (!got || memcmp(block, bytes + offset, (size_t)got)) return EIO;
        offset += (size_t)got;
    }
    if (fstat(fd, &state)) return errno;
    return state.st_size >= 0 && (uintmax_t)state.st_size == size ? 0 : EIO;
}

static int LocusSameInode(int fd, const char *path)
{
    struct stat opened, named;
    if (fstat(fd, &opened) || lstat(path, &named)) return errno;
    return S_ISREG(opened.st_mode) && S_ISREG(named.st_mode) && opened.st_nlink == 1 &&
        opened.st_dev == named.st_dev && opened.st_ino == named.st_ino ? 0 : EBUSY;
}

static int LocusWriteExact(int fd, const void *data, size_t size)
{
    if (ftruncate(fd, 0) || lseek(fd, 0, SEEK_SET) < 0) return errno;
    const unsigned char *bytes = data;
    size_t offset = 0;
    while (offset < size) {
        ssize_t count = write(fd, bytes + offset, size - offset);
        if (count < 0) {
            int failure = errno;
            if (failure == EINTR) continue;
            return failure;
        }
        if (!count) return EIO;
        offset += (size_t)count;
    }
    if (fsync(fd)) return errno;
    return LocusExactBytes(fd, data, size);
}

int LocusReplaceFile(const char *path, const void *expected, size_t expectedSize,
                     const void *replacement, size_t replacementSize,
                     LocusFileOutcome *outcome)
{
    if (outcome) *outcome = LocusFileUnchanged;
    if (!path || !expected || !replacement || !expectedSize || !replacementSize ||
        expectedSize > 32 * 1024 * 1024 || replacementSize > 32 * 1024 * 1024) {
        errno = EINVAL; return -1;
    }
    int fd = open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) return -1;
    int result = -1, failure = 0;
    if (flock(fd, LOCK_EX | LOCK_NB)) { failure = errno; goto done; }
    failure = LocusSameInode(fd, path);
    if (failure) goto done;
    failure = LocusExactBytes(fd, expected, expectedSize);
    if (failure) goto done;
    if (expectedSize == replacementSize && !memcmp(expected, replacement, expectedSize)) {
        // Recovery may revisit bytes whose preceding rollback fsync failed.
        // An idempotent request still establishes durable, exact contents.
        if (fsync(fd)) { failure = errno; goto done; }
        failure = LocusExactBytes(fd, expected, expectedSize);
        if (!failure) failure = LocusSameInode(fd, path);
        if (!failure) result = 0;
        goto done;
    }
    // Recheck immediately before truncation. flock excludes cooperating writers,
    // but cannot exclude arbitrary system daemons.
    failure = LocusSameInode(fd, path);
    if (!failure) failure = LocusExactBytes(fd, expected, expectedSize);
    if (failure) goto done;
    failure = LocusWriteExact(fd, replacement, replacementSize);
    if (!failure) failure = LocusSameInode(fd, path);
    if (!failure) {
        if (outcome) *outcome = LocusFileReplaced;
        result = 0;
    } else {
        // Roll back only the inode we opened, never a substituted path.
        int rollbackFailure = LocusWriteExact(fd, expected, expectedSize);
        if (!rollbackFailure) rollbackFailure = LocusSameInode(fd, path);
        if (outcome) *outcome = rollbackFailure ? LocusFileRecoveryRequired : LocusFileRolledBack;
    }
done:
    close(fd);
    errno = failure;
    return result;
}
