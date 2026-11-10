// SPDX-License-Identifier: GPL-3.0-only
#ifndef LOCUS_IN_PLACE_FILE_TRANSACTION_H
#define LOCUS_IN_PLACE_FILE_TRANSACTION_H
#include <stddef.h>

typedef enum {
    LocusFileUnchanged = 0,
    LocusFileReplaced,
    LocusFileRolledBack,
    LocusFileRecoveryRequired
} LocusFileOutcome;

// Compare exact bytes on the opened, locked, regular inode before truncation.
// Never creates a file. On failure, reports whether exact rollback was verified.
int LocusReplaceFile(const char *path, const void *expected, size_t expectedSize,
                     const void *replacement, size_t replacementSize,
                     LocusFileOutcome *outcome);
#endif
