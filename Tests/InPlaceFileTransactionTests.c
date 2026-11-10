// SPDX-License-Identifier: GPL-3.0-only
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static ssize_t FaultWrite(int, const void *, size_t);
static int FaultSync(int);
#define write FaultWrite
#define fsync FaultSync
#include "../Locus/LowLevel/InPlaceFileTransaction.c"
#undef write
#undef fsync
static int partial;
static int syncFailures;
static ssize_t FaultWrite(int fd, const void *bytes, size_t size)
{
    if (partial == 1) { partial = 2; return write(fd, bytes, 1); }
    if (partial == 2) { partial = 0; errno = ENOSPC; return -1; }
    return write(fd, bytes, size);
}
static int FaultSync(int fd)
{
    if (syncFailures) { syncFailures--; errno = EIO; return -1; }
    return fsync(fd);
}
static void exact(const char *path, const char *bytes)
{
    int fd = open(path, O_RDONLY);
    assert(fd >= 0 && LocusExactBytes(fd, bytes, strlen(bytes)) == 0);
    close(fd);
}
int main(void)
{
    char directory[] = "/tmp/LocusCAS.XXXXXX";
    assert(mkdtemp(directory));
    char path[256], alias[256];
    snprintf(path, sizeof(path), "%s/cache", directory);
    snprintf(alias, sizeof(alias), "%s/link", directory);
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
    assert(fd >= 0 && write(fd, "original", 8) == 8);
    close(fd);
    struct stat before, after;
    assert(!stat(path, &before));
    LocusFileOutcome outcome;
    int locked = open(path, O_RDWR);
    assert(locked >= 0 && !flock(locked, LOCK_EX | LOCK_NB));
    assert(LocusReplaceFile(path, "original", 8, "new", 3, &outcome) == -1);
    assert(outcome == LocusFileUnchanged);
    close(locked);
    assert(LocusReplaceFile(path, "stale", 5, "new", 3, &outcome) == -1);
    assert(outcome == LocusFileUnchanged); exact(path, "original");
    for (int fault = 0; fault < 4; fault++) {
        partial = fault == 1;
        syncFailures = fault == 2 ? 1 : fault == 3 ? 2 : 0;
        int rc = LocusReplaceFile(path, "original", 8, "replacement", 11, &outcome);
        if (!fault) {
            assert(!rc && outcome == LocusFileReplaced); exact(path, "replacement");
            assert(!LocusReplaceFile(path, "replacement", 11, "original", 8, &outcome));
        } else {
            assert(rc == -1);
            assert(outcome == (fault == 3 ? LocusFileRecoveryRequired : LocusFileRolledBack));
            exact(path, "original");
        }
    }
    assert(!LocusReplaceFile(path, "original", 8, "original", 8, &outcome));
    assert(outcome == LocusFileUnchanged);
    syncFailures = 1;
    assert(LocusReplaceFile(path, "original", 8, "original", 8, &outcome) == -1);
    assert(!LocusReplaceFile(path, "original", 8, "original", 8, &outcome));
    assert(!symlink(path, alias));
    assert(LocusReplaceFile(alias, "original", 8, "new", 3, &outcome) == -1);
    unlink(alias);
    assert(!link(path, alias));
    assert(LocusReplaceFile(path, "original", 8, "new", 3, &outcome) == -1);
    unlink(alias);
    assert(!stat(path, &after) && before.st_ino == after.st_ino);
    exact(path, "original");
    unlink(path);
    assert(LocusReplaceFile(path, "original", 8, "new", 3, &outcome) == -1 && errno == ENOENT);
    assert(access(path, F_OK) == -1);
    rmdir(directory);
    puts("PASS: in-place CAS, inode, idempotence, stale/symlink/hardlink refusal, partial/fsync rollback and recovery outcome");
}
