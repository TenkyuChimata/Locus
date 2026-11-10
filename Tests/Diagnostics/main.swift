// SPDX-License-Identifier: GPL-3.0-only
// Synthetic observations; no device UUIDs, raw metadata or system access.
import Foundation

typealias Summary = MobileActivationDiagnosticSummary
let probes: [String: Any] = [
    "afterLease.privateVar.directory.open=opened": 23,
    "afterLease.var.directory.open=opened": 23,
    "afterLease.aliases=same-directory": 23,
    "beforeLease.aliases=identity-unconfirmed": 24,
    "afterLease.privateVar.hidden.lstat=regular-file": 23,
    "afterLease.privateVar.hidden.stat=regular-file": 23,
    "afterLease.privateVar.hidden.relative-lstat=regular-file": 23,
    "afterLease.privateVar.hidden.open=NSPOSIXErrorDomain:1": 23,
    "afterLease.privateVar.plain.relative-lstat=NSPOSIXErrorDomain:2": 18,
    "afterLease.privateVar.plain.lookup-not-found-with-open-parent": 18,
    "afterLease.privateVar.plain.fstat=directory": 5,
    "beforeLease.privateVar.directory.open=NSPOSIXErrorDomain:1": 24
]
let errors: [String: Any] = [
    "privateVar -> NSCocoaErrorDomain:257 -> NSPOSIXErrorDomain:1": 23,
    "privateVar -> NSCocoaErrorDomain:260 -> NSPOSIXErrorDomain:2": 18,
    "privateVar -> NSCocoaErrorDomain:256 -> NSPOSIXErrorDomain:21": 5,
    "var -> NSCocoaErrorDomain:257 -> NSPOSIXErrorDomain:1": 23,
    "var -> NSCocoaErrorDomain:260 -> NSPOSIXErrorDomain:2": 18,
    "var -> NSCocoaErrorDomain:256 -> NSPOSIXErrorDomain:21": 5
]
let discovery: [String: Any] = ["metadataPathProbes": probes, "metadataReadErrors": errors]
let groups = Summary.probeGroups(discovery)
let after = groups.first { $0.id == "afterLease.privateVar" }!
assert(after.rows.first { $0.id.hasSuffix("hidden.lstat") }?.value == "regular file: 23")
assert(after.rows.first { $0.id.hasSuffix("hidden.stat") }?.value == "regular file: 23")
assert(after.rows.first { $0.id.hasSuffix("hidden.relative-lstat") }?.value == "regular file: 23")
assert(after.rows.first { $0.id.hasSuffix("hidden.open") }?.value == "NSPOSIXErrorDomain 1 (EPERM): 23")
assert(after.rows.first { $0.id.hasSuffix("plain.fstat") }?.value == "directory: 5")
assert(!after.rows.contains { $0.id.contains("lookup-not-found-with-open-parent") })
assert(Summary.aliasRows(discovery).first?.value == "same directory: 23")
let errorRows = Summary.readErrorRows(discovery)
assert(errorRows.count == 6)
assert(errorRows.filter { $0.title.hasPrefix("/private/var →") }.count == 3)
assert(errorRows.filter { $0.title.hasPrefix("/var →") }.count == 3)
assert(errorRows.reduce(0) { $0 + Int($1.value)! } == 92) // requests, not 92 distinct files
assert(errorRows.contains { $0.title.contains("NSCocoaErrorDomain:256 → NSPOSIXErrorDomain:21") && $0.value == "5" })
assert(Summary.probeGroups([:]).isEmpty && Summary.readErrorRows([:]).isEmpty)
assert(Summary.probeGroups(["metadataPathProbes": [
    "afterLease.var.hidden.open=opened": true,
    "afterLease.var.hidden.stat=regular-file": -1
]]).isEmpty)
let unknown = Summary.probeGroups(["metadataPathProbes": [
    "afterLease.var.hidden.open=DO-NOT-EXPORT": 1
]])
assert(unknown.first?.rows.first?.value == "unrecognized outcome: 1")
print("PASS: per-operation probe counts, alias separation, complete read errors, directory-open semantics and missing observations")
