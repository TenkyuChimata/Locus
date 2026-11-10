// SPDX-License-Identifier: GPL-3.0-only
#ifndef LOCUS_READ_ONLY_EVIDENCE_FILE_H
#define LOCUS_READ_ONLY_EVIDENCE_FILE_H
#include <stdbool.h>
#include <stddef.h>
#include <sys/stat.h>
typedef struct {
    unsigned char *first, *second;
    size_t length;
    struct stat before, between, after, namedAfter;
    bool metadataAvailable, namedAvailable, stable;
    int error;
    const char *stage;
} LocusEvidenceFile;
// Only O_RDONLY opens; every path component rejects symlinks. No leases.
LocusEvidenceFile LocusReadEvidenceFile(const char *absolutePath);
void LocusFreeEvidenceFile(LocusEvidenceFile *result);
#endif
