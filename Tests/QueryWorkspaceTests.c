// SPDX-License-Identifier: GPL-3.0-only
// Real temporary directories; no iOS access or sandbox escape is executed.
#include "WorseQueryWorkspace.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static void writeFile(int directory, const char *name, const char *value)
{
    int fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL, 0600);
    assert(fd >= 0);
    assert(write(fd, value, strlen(value)) == (ssize_t)strlen(value));
    assert(close(fd) == 0);
}

int main(void)
{
    char root[] = "/tmp/LocusWorkspaceTests.XXXXXX";
    assert(mkdtemp(root));
    char library[PATH_MAX];
    assert(snprintf(library, sizeof(library), "%s/Library", root) > 0);
    assert(mkdir(library, 0700) == 0);
    int fd = open(library, O_RDONLY | O_DIRECTORY);
    assert(fd >= 0);
    assert(mkdirat(fd, "Caches", 0700) == 0);
    int cache = openat(fd, "Caches", O_RDONLY | O_DIRECTORY);
    assert(cache >= 0);
    writeFile(cache, "user-data", "must survive exactly");
    assert(mkdirat(cache, "nested", 0700) == 0);
    struct stat before, after;
    assert(fstat(cache, &before) == 0);

    LocusQueryWorkspace workspace, competing;
    const char *target = "/var/containers/Shared/SystemGroup/test/Library/Caches";
    // Successful query and both failed-query paths share this exact cleanup.
    for (int i = 0; i < 5; i++) {
        assert(LocusQueryWorkspaceBegin(library, target, &workspace) == 0);
        assert(LocusQueryWorkspaceBegin(library, target, &competing) != 0);
        assert(LocusQueryWorkspaceEnd(&workspace, target) == 0);
        assert(LocusQueryWorkspaceEnd(&workspace, target) == 0); // idempotent
        assert(fstatat(fd, "Caches", &after, AT_SYMLINK_NOFOLLOW) == 0);
        assert(before.st_ino == after.st_ino && before.st_dev == after.st_dev);
        int saved = openat(cache, "user-data", O_RDONLY);
        char contents[32] = {0};
        assert(read(saved, contents, sizeof(contents)) == 20);
        assert(strcmp(contents, "must survive exactly") == 0);
        close(saved);
    }
    // An interrupted operation preserves its original nonempty directory.
    assert(LocusQueryWorkspaceBegin(library, target, &workspace) == 0);
    assert(unlinkat(fd, "Caches", 0) == 0);
    assert(symlinkat("/foreign-target", fd, "Caches") == 0);
    assert(LocusQueryWorkspaceEnd(&workspace, target) == ESTALE);
    assert(fstatat(fd, ".locus-worse-query-caches", &after, AT_SYMLINK_NOFOLLOW) == 0);
    assert(before.st_ino == after.st_ino);
    assert(LocusQueryWorkspaceBegin(library, target, &competing) == EEXIST);
    assert(unlinkat(fd, "Caches", 0) == 0); // test-owned recovery only
    assert(renameat(fd, ".locus-worse-query-caches", fd, "Caches") == 0);

    assert(renameat(fd, "Caches", fd, "saved-by-test") == 0);
    assert(symlinkat("/foreign-target", fd, "Caches") == 0);
    assert(LocusQueryWorkspaceBegin(library, target, &workspace) == ELOOP);
    assert(unlinkat(fd, "Caches", 0) == 0);
    writeFile(fd, "Caches", "a regular file");
    assert(LocusQueryWorkspaceBegin(library, target, &workspace) == ELOOP);
    assert(unlinkat(fd, "Caches", 0) == 0);
    // No pre-existing Caches directory is a valid, reversible state too.
    assert(LocusQueryWorkspaceBegin(library, target, &workspace) == 0);
    assert(LocusQueryWorkspaceEnd(&workspace, target) == 0);
    assert(fstatat(fd, "Caches", &after, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT);
    assert(LocusQueryWorkspaceBegin(library, "relative", &workspace) == EINVAL);
    char alias[PATH_MAX];
    snprintf(alias, sizeof(alias), "%s/Alias", root);
    assert(symlink(library, alias) == 0);
    assert(LocusQueryWorkspaceBegin(alias, target, &workspace) != 0);
    assert(unlink(alias) == 0);

    assert(unlinkat(cache, "user-data", 0) == 0);
    assert(unlinkat(cache, "nested", AT_REMOVEDIR) == 0);
    close(cache);
    assert(unlinkat(fd, "saved-by-test", AT_REMOVEDIR) == 0);
    assert(unlinkat(fd, ".locus-worse-query.lock", 0) == 0);
    close(fd);
    assert(rmdir(library) == 0);
    assert(rmdir(root) == 0);
    puts("PASS: workspace preservation, inode identity, locking, refusal, interrupted cleanup, retry");
}
