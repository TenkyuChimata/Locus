// SPDX-License-Identifier: GPL-3.0-only
// Locus-owned, non-recursive App Group workspace handling.
#ifndef LOCUS_WORSE_QUERY_WORKSPACE_H
#define LOCUS_WORSE_QUERY_WORKSPACE_H
#include <stdbool.h>
#include <sys/types.h>

typedef struct {
    int libraryFD;
    int lockFD;
    bool movedCaches;
    bool linked;
    dev_t linkDevice;
    ino_t linkInode;
    // Historical observations survive End; never used to authorize operations.
    bool lockOpened, cachesWereMoved, linkWasCreated, cleanupAttempted;
    int cleanupError;
    double cleanupMilliseconds;
} LocusQueryWorkspace;

// Returns an errno value. Existing Caches data is moved aside, never deleted.
// A leftover backup/link from an interrupted operation is refused, not erased.
int LocusQueryWorkspaceBegin(const char *library, const char *target,
                            LocusQueryWorkspace *workspace);
int LocusQueryWorkspaceEnd(LocusQueryWorkspace *workspace, const char *target);
#endif
