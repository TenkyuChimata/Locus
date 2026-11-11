// SPDX-License-Identifier: GPL-3.0-only
#ifndef LOCUS_READ_ONLY_EVIDENCE_FILE_H
#define LOCUS_READ_ONLY_EVIDENCE_FILE_H
#include <stdbool.h>
#include <stddef.h>
#include <sys/stat.h>
enum { LocusEvidenceReadStepCount = 7 };
typedef struct {
    bool attempted, completed;
    int error;
    double elapsedMilliseconds;
} LocusEvidenceReadStep;
typedef struct {
    unsigned char *first, *second;
    size_t length;
    struct stat before, between, after, namedAfter;
    bool metadataAvailable, namedAvailable, stable;
    int error;
    const char *stage;
    // Numeric component ordinal only; never publish a path component.
    unsigned failedComponent;
    LocusEvidenceReadStep steps[LocusEvidenceReadStepCount];
} LocusEvidenceFile;
// Only O_RDONLY opens; every path component rejects symlinks. No leases.
LocusEvidenceFile LocusReadEvidenceFile(const char *absolutePath);
// Authorized callers pin the requested directory's identity. Links remain
// forbidden in every component, including the authorization target directory.
LocusEvidenceFile LocusReadEvidenceFileInDirectory(const char *absolutePath,
                                                  const struct stat *expectedParent);
void LocusFreeEvidenceFile(LocusEvidenceFile *result);
#endif
