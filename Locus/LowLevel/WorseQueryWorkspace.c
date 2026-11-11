// SPDX-License-Identifier: GPL-3.0-only
#include "WorseQueryWorkspace.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

static const char *const backupName = ".locus-worse-query-caches";

static void closeWorkspace(LocusQueryWorkspace *w)
{
    if (w->lockFD >= 0) { flock(w->lockFD, LOCK_UN); close(w->lockFD); }
    if (w->libraryFD >= 0) close(w->libraryFD);
    w->lockFD = w->libraryFD = -1;
}

int LocusQueryWorkspaceEnd(LocusQueryWorkspace *w, const char *target)
{
    int failure = 0;
    if (w->libraryFD < 0) return 0;
    if (w->linked) {
        struct stat st;
        char destination[PATH_MAX];
        ssize_t size = readlinkat(w->libraryFD, "Caches", destination, sizeof(destination));
        if (fstatat(w->libraryFD, "Caches", &st, AT_SYMLINK_NOFOLLOW) != 0 ||
            !S_ISLNK(st.st_mode) || st.st_dev != w->linkDevice ||
            st.st_ino != w->linkInode || size < 0 ||
            (size_t)size != strlen(target) || memcmp(destination, target, (size_t)size) != 0) {
            failure = ESTALE;
        } else if (unlinkat(w->libraryFD, "Caches", 0) != 0) {
            failure = errno;
        }
        w->linked = false;
    }
    if (!failure && w->movedCaches) {
        struct stat st;
        // Never overwrite a replacement created by another process.
        if (fstatat(w->libraryFD, "Caches", &st, AT_SYMLINK_NOFOLLOW) == 0)
            failure = EEXIST;
        else if (errno != ENOENT) failure = errno;
        else if (renameat(w->libraryFD, backupName, w->libraryFD, "Caches") != 0)
            failure = errno;
        else w->movedCaches = false;
    }
    if (!failure && fsync(w->libraryFD) != 0) failure = errno;
    closeWorkspace(w);
    return failure;
}

int LocusQueryWorkspaceBegin(const char *library, const char *target, LocusQueryWorkspace *w)
{
    *w = (LocusQueryWorkspace){ .libraryFD = -1, .lockFD = -1 };
    if (!library || !target || target[0] != '/' || strlen(target) >= PATH_MAX) return EINVAL;
    w->libraryFD = open(library, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (w->libraryFD < 0) return errno;
    w->lockFD = openat(w->libraryFD, ".locus-worse-query.lock",
                       O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
    struct stat lockStat;
    if (w->lockFD < 0 || fstat(w->lockFD, &lockStat) != 0) {
        int failure = errno;
        closeWorkspace(w);
        return failure;
    }
    if (!S_ISREG(lockStat.st_mode) || lockStat.st_nlink != 1) {
        closeWorkspace(w);
        return EINVAL;
    }
    if (flock(w->lockFD, LOCK_EX | LOCK_NB) != 0) {
        int failure = errno;
        closeWorkspace(w);
        return failure;
    }
    struct stat st;
    if (fstatat(w->libraryFD, backupName, &st, AT_SYMLINK_NOFOLLOW) == 0) {
        closeWorkspace(w);
        return EEXIST;
    }
    if (errno != ENOENT) {
        int failure = errno;
        closeWorkspace(w);
        return failure;
    }
    if (fstatat(w->libraryFD, "Caches", &st, AT_SYMLINK_NOFOLLOW) == 0) {
        if (!S_ISDIR(st.st_mode)) { closeWorkspace(w); return ELOOP; }
        if (renameat(w->libraryFD, "Caches", w->libraryFD, backupName) != 0) {
            int failure = errno; closeWorkspace(w); return failure;
        }
        w->movedCaches = true;
    } else if (errno != ENOENT) {
        int failure = errno; closeWorkspace(w); return failure;
    }
    if (symlinkat(target, w->libraryFD, "Caches") != 0) {
        int failure = errno;
        (void)LocusQueryWorkspaceEnd(w, target);
        return failure;
    }
    if (fstatat(w->libraryFD, "Caches", &st, AT_SYMLINK_NOFOLLOW) != 0) {
        int failure = errno;
        // Ownership cannot be established; preserve the link and backup.
        closeWorkspace(w);
        return failure;
    }
    w->linked = true;
    w->linkDevice = st.st_dev;
    w->linkInode = st.st_ino;
    if (fsync(w->libraryFD) != 0) {
        int failure = errno;
        (void)LocusQueryWorkspaceEnd(w, target);
        return failure;
    }
    return 0;
}
