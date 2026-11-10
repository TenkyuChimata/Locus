// SPDX-License-Identifier: GPL-3.0-only
#include "ReadOnlyEvidenceFile.h"
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int openWithoutLinks(const char *path)
{
    if (!path || path[0] != '/' || strlen(path) > 4096) { errno = EINVAL; return -1; }
    char *copy = strdup(path), *cursor = NULL;
    if (!copy) return -1;
    int fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    char *part = strtok_r(copy, "/", &cursor);
    if (!part) { free(copy); if (fd >= 0) close(fd); errno = EINVAL; return -1; }
    while (fd >= 0 && part) {
        char *next = strtok_r(NULL, "/", &cursor);
        if (!strcmp(part, ".") || !strcmp(part, "..")) { close(fd); fd = -1; errno = EINVAL; break; }
        int child = openat(fd, part, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK |
                           (next ? O_DIRECTORY : 0));
        int saved = errno;
        close(fd);
        fd = child;
        errno = saved;
        part = next;
    }
    int saved = errno;
    free(copy);
    errno = saved;
    return fd;
}

static bool sameMetadata(struct stat a, struct stat b)
{
#if defined(__APPLE__)
    bool times = a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec;
#else
    bool times = a.st_mtim.tv_sec == b.st_mtim.tv_sec && a.st_mtim.tv_nsec == b.st_mtim.tv_nsec &&
        a.st_ctim.tv_sec == b.st_ctim.tv_sec && a.st_ctim.tv_nsec == b.st_ctim.tv_nsec;
#endif
    return times && a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size &&
        a.st_mode == b.st_mode && a.st_uid == b.st_uid && a.st_gid == b.st_gid && a.st_nlink == b.st_nlink;
}

static int readExactly(int fd, unsigned char *bytes, size_t length)
{
    size_t offset = 0;
    while (offset < length) {
        ssize_t count = pread(fd, bytes + offset, length - offset, (off_t)offset);
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) return errno;
        if (!count) return EBUSY;
        offset += (size_t)count;
    }
    unsigned char extra;
    ssize_t count;
    do { count = pread(fd, &extra, 1, (off_t)length); } while (count < 0 && errno == EINTR);
    return count < 0 ? errno : count ? EBUSY : 0;
}

LocusEvidenceFile LocusReadEvidenceFile(const char *path)
{
    LocusEvidenceFile r = { .stage = "open-read-only-no-follow" };
    int fd = openWithoutLinks(path);
    if (fd < 0) { r.error = errno; return r; }
    r.stage = "fstat-before";
    if (fstat(fd, &r.before)) { r.error = errno; goto done; }
    r.stage = "regular-file-and-size";
    if (!S_ISREG(r.before.st_mode) || r.before.st_size <= 0 || r.before.st_size > 8 * 1024 * 1024) {
        r.error = EINVAL; goto done;
    }
    r.length = (size_t)r.before.st_size;
    r.first = malloc(r.length);
    r.second = malloc(r.length);
    if (!r.first || !r.second) { r.error = ENOMEM; goto done; }
    r.stage = "first-pread";
    if ((r.error = readExactly(fd, r.first, r.length))) goto done;
    r.stage = "fstat-between";
    if (fstat(fd, &r.between)) { r.error = errno; goto done; }
    r.stage = "second-pread-same-fd";
    if ((r.error = readExactly(fd, r.second, r.length))) goto done;
    r.stage = "fstat-after";
    if (fstat(fd, &r.after)) { r.error = errno; goto done; }
    r.metadataAvailable = true;
    r.stage = "reopen-path-without-links";
    int named = openWithoutLinks(path);
    if (named < 0) { r.error = errno; goto done; }
    int rc = fstat(named, &r.namedAfter), saved = errno;
    close(named);
    if (rc) { r.error = saved; goto done; }
    r.namedAvailable = true;
    r.stage = "compare-bytes-and-metadata";
    r.stable = sameMetadata(r.before, r.between) && sameMetadata(r.before, r.after) &&
        sameMetadata(r.before, r.namedAfter) && !memcmp(r.first, r.second, r.length);
    if (!r.stable) r.error = EBUSY;
done:
    close(fd);
    // Partial reads must never be parsed or hashed as complete observations.
    if (!r.metadataAvailable) { free(r.first); free(r.second); r.first = r.second = NULL; }
    return r;
}

void LocusFreeEvidenceFile(LocusEvidenceFile *r)
{
    free(r->first); free(r->second);
    r->first = r->second = NULL;
}
