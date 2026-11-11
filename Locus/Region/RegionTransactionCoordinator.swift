// SPDX-License-Identifier: GPL-3.0-only
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

protocol RegionFileAccess {
    func read(_ file: RegionFile) throws -> Data
    /// Must use compare-and-replace on the same opened inode, with verified
    /// best-effort rollback on write failure. Unknown contents are never forced.
    func replace(_ file: RegionFile, expected: Data, replacement: Data) throws
}

nonisolated struct RegionJournal: Codable, Sendable {
    nonisolated enum Phase: String, Codable, Sendable {
        case preparing, prepared, writing, committed, rollingBack, rolledBack, recoveryRequired
        var unfinished: Bool { self != .committed && self != .rolledBack }
    }
    nonisolated struct Entry: Codable, Sendable {
        // Preserve obsolete names as metadata, never as a file-access capability.
        let fileName: String
        var file: RegionFile? { RegionFile(rawValue: fileName) }
        let beforeSHA256: String
        let afterSHA256: String
        let scope: RegionPatchScope
        enum CodingKeys: String, CodingKey { case fileName = "file", beforeSHA256, afterSHA256, scope }
        init(file: RegionFile, beforeSHA256: String, afterSHA256: String, scope: RegionPatchScope) {
            fileName = file.rawValue; self.beforeSHA256 = beforeSHA256; self.afterSHA256 = afterSHA256; self.scope = scope
        }
    }
    let schemaVersion: Int? // Absent in v1. New Full Japan always requires v2.
    let id: String
    let moduleName: String
    var module: RegionModule? { RegionModule(rawValue: moduleName) }
    let operation: String
    let productType: String
    let build: String
    let deviceID: String? // Optional for existing journals; new device writes bind the app vendor ID.
    let created: Date
    let entries: [Entry]
    var phase: Phase
    enum CodingKeys: String, CodingKey {
        case schemaVersion, id, moduleName = "module", operation, productType, build, deviceID, created, entries, phase
    }
    init(id: String, module: RegionModule, operation: String, productType: String, build: String,
         deviceID: String?, created: Date, entries: [Entry], phase: Phase) {
        schemaVersion = 2; self.id = id; moduleName = module.rawValue; self.operation = operation
        self.productType = productType; self.build = build; self.deviceID = deviceID
        self.created = created; self.entries = entries; self.phase = phase
    }

    var permitsCurrentRecovery: Bool {
        guard let module, ["apply", "restore"].contains(operation),
              entries.count == 1, entries[0].file == .mobileGestalt else { return false }
        return schemaVersion == 2 || (schemaVersion == nil && module != .fullJapan)
    }
    var legacyBlock: String {
        "Legacy or unsupported transaction \(id) (\(moduleName), schema \(schemaVersion.map(String.init) ?? "1"), \(phase.rawValue)). No automatic restore is authorized. Preserve this app container and its original backups for manual recovery review."
    }
}

/// Every persistent module (including the composite) enters this coordinator.
/// Disk journals survive process termination; first module baselines are
/// immutable and describe the pre-Locus state, never an inferred factory state.
final class RegionTransactionCoordinator {
    private static let serial = NSRecursiveLock()
    let root: URL
    let access: RegionFileAccess
    let productType: String
    let build: String
    private let deviceID: String?
    private let layoutProvider: () -> RegionLayoutResolution
    private let fm = FileManager.default

    init(root: URL, access: RegionFileAccess, productType: String, build: String, deviceID: String? = nil,
         layoutProvider: @escaping () -> RegionLayoutResolution = { .current() }) {
        self.root = root; self.access = access; self.productType = productType; self.build = build; self.deviceID = deviceID
        self.layoutProvider = layoutProvider
    }

    private func journals() throws -> [RegionJournal] {
        Self.serial.lock(); defer { Self.serial.unlock() }
        guard fm.fileExists(atPath: root.path) else { return [] }
        return try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .compactMap { directory in
                let path = directory.appendingPathComponent("journal.plist")
                // Before the first journal is durable, system writes cannot start.
                guard fm.fileExists(atPath: path.path) else { return nil }
                let journal = try decode(RegionJournal.self, at: path)
                guard journal.id == directory.lastPathComponent else { throw RegionOperationError("Journal identity mismatch.") }
                return journal
            }.sorted { $0.created < $1.created }
    }

    func pending() throws -> [RegionJournal] {
        try journals().filter { $0.phase.unfinished }
    }

    /// Read app-owned metadata/backups only. Never opens obsolete system paths.
    func legacyBackupDetail() throws -> String? {
        Self.serial.lock(); defer { Self.serial.unlock() }
        var lines = try journals().filter { !$0.permitsCurrentRecovery }.map(\.legacyBlock)
        if fm.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("Japan Region Transaction Backups").path) {
            lines.append("Older Japan Region Transaction Backups folder retained. Its unjournaled backups cannot authorize current Restore; preserve them for manual recovery review.")
        }
        for name in ["fullJapan", "mobileActivation", "intelligence"] {
            let url = root.appendingPathComponent("originals/\(name).plist")
            guard fm.fileExists(atPath: url.path) else { continue }
            do {
                let pointer = try decode([String: String].self, at: url)
                guard let id = pointer["transaction"], UUID(uuidString: id) != nil else {
                    throw RegionOperationError("Invalid original pointer.")
                }
                let journal = try decode(RegionJournal.self, at: root.appendingPathComponent(id).appendingPathComponent("journal.plist"))
                guard journal.id == id, journal.moduleName == name, journal.operation == "apply" else {
                    throw RegionOperationError("Original record mismatch.")
                }
                for entry in journal.entries {
                    // Obsolete file labels are used only for these fixed local backup names.
                    guard ["mobileGestalt", "mobileActivation"].contains(entry.fileName) else {
                        throw RegionOperationError("Unknown legacy backup label.")
                    }
                    let directory = root.appendingPathComponent(id)
                    let before = try Data(contentsOf: directory.appendingPathComponent("\(entry.fileName).before.plist"))
                    let after = try Data(contentsOf: directory.appendingPathComponent("\(entry.fileName).after.plist"))
                    guard RegionBackupDigest.sha256(before) == entry.beforeSHA256,
                          RegionBackupDigest.sha256(after) == entry.afterSHA256 else {
                        throw RegionOperationError("Legacy backup checksum mismatch.")
                    }
                }
                lines.append("Legacy \(name) original retained (\(id)); excluded from current Restore and new Full Japan baselines.")
            } catch { lines.append("Legacy \(name) backup unavailable: \(error.localizedDescription) Original data retained; automatic restore blocked.") }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    func originalAvailable(for module: RegionModule) throws -> Bool {
        Self.serial.lock(); defer { Self.serial.unlock() }
        guard fm.fileExists(atPath: originalURL(module).path) else { return false }
        let journal = try original(module)
        _ = try plans(in: journal)
        return true
    }

    static let unchangedMessage = "No Changes Needed. Requested file values already match; no write or new original backup was created."

    @discardableResult
    func apply(module: RegionModule, plans: [RegionWritePlan]) throws -> String {
        Self.serial.lock(); defer { Self.serial.unlock() }
        guard let prepared = try prepare(module: module, plans: plans) else { return Self.unchangedMessage }
        return try commitPrepared(prepared.id)
    }

    func restorePlans(module: RegionModule) throws -> [RegionWritePlan] {
        Self.serial.lock(); defer { Self.serial.unlock() }
        let saved = try plans(in: original(module))
        return try saved.map { plan in
            let current = try access.read(plan.file)
            let after = try plan.scope.restoring(original: plan.before, applied: plan.after, current: current)
            let result = RegionWritePlan(file: plan.file, before: current, after: after, scope: plan.scope)
            try validateCachePlan(module: module, plan: result, applying: false)
            return result
        }
    }

    @discardableResult
    func restore(module: RegionModule, preview: (([RegionWritePlan]) -> Void)? = nil) throws -> String {
        Self.serial.lock(); defer { Self.serial.unlock() }
        let plans = try restorePlans(module: module)
        preview?(plans)
        guard let prepared = try prepare(module: module, plans: plans, operation: "restore") else { return Self.unchangedMessage }
        return try commitPrepared(prepared.id)
    }

    func cancelPrepared(_ id: String) throws {
        Self.serial.lock(); defer { Self.serial.unlock() }
        var journal = try preparedJournal(id)
        journal.phase = .rolledBack // Prepared means no system write has started.
        try save(journal)
    }

    private func preparedJournal(_ id: String) throws -> RegionJournal {
        guard UUID(uuidString: id) != nil else { throw RegionOperationError("Invalid prepared transaction.") }
        let journal = try decode(RegionJournal.self, at: root.appendingPathComponent(id).appendingPathComponent("journal.plist"))
        try checkContext(journal)
        try checkSupported(journal)
        guard journal.id == id, journal.phase == .prepared, ["apply", "restore"].contains(journal.operation) else {
            throw RegionOperationError("Transaction is no longer awaiting confirmation.")
        }
        return journal
    }

    func recoverPending() throws -> String {
        Self.serial.lock(); defer { Self.serial.unlock() }
        let journals = try pending()
        // Validate the whole recovery set before even closing an unwritten one.
        for journal in journals { try checkSupported(journal); try checkContext(journal) }
        var unwritten = 0
        var recovered = 0
        for var journal in journals.reversed() {
            try checkContext(journal)
            if journal.phase == .preparing || journal.phase == .prepared {
                // No system write is permitted in this phase, even when backup
                // creation was interrupted. Preserve all evidence for inspection.
                journal.phase = .rolledBack
                try save(journal)
                unwritten += 1
            } else {
                let saved = try plans(in: journal)
                try rollback(&journal, plans: saved)
                recovered += 1
            }
        }
        return journals.isEmpty ? "No unfinished transactions." : "Closed \(unwritten) unwritten transactions without changing system files. Recovered \(recovered) written transactions with exact source readback and sync."
    }

    /// Reuse the existing prepared journal for the confirmation UI. This saves
    /// and reads back complete backups without opening a system file for writing.
    func prepare(module: RegionModule, plans: [RegionWritePlan], operation: String = "apply") throws -> RegionJournal? {
        Self.serial.lock(); defer { Self.serial.unlock() }
        guard ["apply", "restore"].contains(operation) else { throw RegionOperationError("Unsupported operation.") }
        guard !productType.isEmpty, !build.isEmpty else { throw RegionOperationError("Running ProductType/build must be known before a persistent operation.") }
        guard !plans.isEmpty, Set(plans.map(\.file)).count == plans.count else { throw RegionOperationError("Missing or duplicate transaction target.") }
        if plans.contains(where: { $0.scope.layoutBinding != nil }), deviceID?.isEmpty != false {
            throw RegionOperationError("Dynamic transactions require a device identity.")
        }
        try validateTargets(module: module, files: plans.map(\.file))
        let requestedFiles = Set(plans.map(\.file))
        let unfinished = try pending()
        for journal in unfinished where !journal.permitsCurrentRecovery { throw RegionOperationError(journal.legacyBlock) }
        guard unfinished.allSatisfy({ requestedFiles.isDisjoint(with: $0.entries.compactMap(\.file)) }) else {
            throw RegionOperationError("Unfinished transaction detected for this source. Recover it before modifying the same file.")
        }
        for plan in plans {
            try validateAuthorization(module: module, file: plan.file, scope: plan.scope)
            try plan.scope.validate(before: plan.before, after: plan.after)
            try validateCachePlan(module: module, plan: plan, applying: operation == "apply")
            guard try access.read(plan.file) == plan.before else { throw RegionOperationError("Source changed since planning; nothing was written.") }
        }
        guard plans.contains(where: { $0.before != $0.after }) else {
            return nil
        }
        if operation == "apply", fm.fileExists(atPath: originalURL(module).path) {
            let saved = try self.plans(in: original(module))
            for previous in saved {
                guard let current = plans.first(where: { $0.file == previous.file }) else { throw RegionOperationError("Original transaction target mismatch.") }
                _ = try previous.scope.restoring(original: previous.before, applied: previous.after, current: current.before)
            }
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try sync(root.deletingLastPathComponent())
        let id = UUID().uuidString
        let directory = root.appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        try sync(root)
        var journal = RegionJournal(id: id, module: module, operation: operation, productType: productType,
            build: build, deviceID: deviceID, created: Date(), entries: plans.map {
                .init(file: $0.file, beforeSHA256: RegionBackupDigest.sha256($0.before),
                      afterSHA256: RegionBackupDigest.sha256($0.after), scope: $0.scope)
            }, phase: .preparing)
        try save(journal)
        for plan in plans {
            try writeNew(plan.before, to: bytesURL(journal, plan.file, "before"))
            try writeNew(plan.after, to: bytesURL(journal, plan.file, "after"))
        }
        _ = try self.plans(in: journal) // Hashes, exact backups and whitelist before any write.
        journal.phase = .prepared
        try save(journal)
        return journal
    }

    /// Confirm the exact saved preview; never silently replan after approval.
    func commitPrepared(_ id: String) throws -> String {
        Self.serial.lock(); defer { Self.serial.unlock() }
        var journal = try preparedJournal(id)
        for other in try pending() where other.id != id {
            try checkSupported(other)
            throw RegionOperationError("Another unfinished MobileGestalt transaction appeared after review; confirmation refused.")
        }
        let plans = try self.plans(in: journal)
        let module = journal.module!, operation = journal.operation
        var attempted: [RegionWritePlan] = []
        do {
            // Check every source again after backup I/O and before the first write.
            for plan in plans {
                guard try access.read(plan.file) == plan.before else { throw RegionOperationError("Source changed during backup; transaction refused.") }
                try validateCachePlan(module: module, plan: plan, applying: operation == "apply")
            }
            if operation == "apply" {
                if fm.fileExists(atPath: originalURL(module).path) {
                    for previous in try self.plans(in: original(module)) {
                        guard let current = plans.first(where: { $0.file == previous.file }) else {
                            throw RegionOperationError("Original transaction target mismatch.")
                        }
                        _ = try previous.scope.restoring(original: previous.before, applied: previous.after, current: current.before)
                    }
                } else {
                    let originals = root.appendingPathComponent("originals", isDirectory: true)
                    try fm.createDirectory(at: originals, withIntermediateDirectories: true)
                    try sync(root)
                    try writeNew(try encode(["transaction": id]), to: originalURL(module))
                }
            }
            journal.phase = .writing
            try save(journal)
            for plan in plans where plan.before != plan.after {
                attempted.append(plan)
                try access.replace(plan.file, expected: plan.before, replacement: plan.after)
                guard try access.read(plan.file) == plan.after else { throw RegionOperationError("Complete byte readback verification failed.") }
            }
            for plan in plans {
                guard try access.read(plan.file) == plan.after else { throw RegionOperationError("Final composite source verification failed.") }
            }
            journal.phase = .committed
            try save(journal)
            return "Persistent \(operation) verified by complete byte readback. Backup: \(id). Restart and test runtime answers and actual features separately."
        } catch {
            let primary = error.localizedDescription
            do {
                try rollback(&journal, plans: attempted)
            } catch {
                throw RegionOperationError("\(primary)\nRecovery required: \(error.localizedDescription). Journal: \(id). Exact original backups are retained.")
            }
            if attempted.isEmpty { throw RegionOperationError("\(primary)\nNo system write was attempted.") }
            throw RegionOperationError("\(primary)\nRollback verified for every attempted write. Journal: \(id).")
        }
    }

    private func rollback(_ journal: inout RegionJournal, plans: [RegionWritePlan]) throws {
        let completedSources = journal.phase == .committed
        journal.phase = .rollingBack
        do { try save(journal) } catch {
            // A failed commit-marker write may already have exposed a terminal
            // journal. Do not start a partial rollback until its new intent is
            // durable. In this case every source was already synced/read back
            // as the intended replacement; retain that consistent state.
            if completedSources {
                throw RegionOperationError("All source replacements were synced and verified. Rollback was not started because its journal intent could not be persisted: \(error.localizedDescription)")
            }
            // For write failures, the previously durable writing phase is
            // already recoverable. Attempt reverse rollback despite this error.
        }
        var failures: [String] = []
        for plan in plans.reversed() {
            do {
                try validateCachePlan(module: journal.module!, plan: plan, applying: false)
                let current = try access.read(plan.file)
                guard current == plan.before || current == plan.after else { throw RegionOperationError("Contents are neither the original nor the intended replacement; forced overwrite refused.") }
                // The native idempotent path also fsyncs. Byte equality alone
                // cannot repair an earlier rollback durability failure.
                try access.replace(plan.file, expected: current, replacement: plan.before)
                guard try access.read(plan.file) == plan.before else { throw RegionOperationError("Rollback readback mismatch.") }
            } catch { failures.append("\(plan.file.rawValue): \(error.localizedDescription)") }
        }
        journal.phase = failures.isEmpty ? .rolledBack : .recoveryRequired
        do { try save(journal) } catch { failures.append("Journal durability: \(error.localizedDescription)") }
        if !failures.isEmpty { throw RegionOperationError(failures.joined(separator: "\n")) }
    }

    private func original(_ module: RegionModule) throws -> RegionJournal {
        guard fm.fileExists(atPath: originalURL(module).path) else {
            throw RegionOperationError("No compatible original backup for \(module.title). Legacy backups are retained separately and cannot authorize this Restore.")
        }
        let pointer = try decode([String: String].self, at: originalURL(module))
        guard let id = pointer["transaction"], UUID(uuidString: id) != nil else { throw RegionOperationError("Invalid original-value record.") }
        let journal = try decode(RegionJournal.self, at: root.appendingPathComponent(id).appendingPathComponent("journal.plist"))
        guard journal.id == id, journal.module == module, journal.operation == "apply" else { throw RegionOperationError("Original-value record mismatch.") }
        try checkContext(journal)
        return journal
    }

    private func checkContext(_ journal: RegionJournal) throws {
        if journal.entries.contains(where: { $0.scope.layoutBinding != nil }) {
            guard let savedID = journal.deviceID, !savedID.isEmpty, savedID == deviceID else {
                throw RegionOperationError("Dynamic backup requires the same device identity; backup retained.")
            }
        }
        guard journal.productType == productType, journal.build == build,
              journal.deviceID == nil || journal.deviceID == deviceID else {
            throw RegionOperationError("Backup belongs to another device or build; restore is blocked.")
        }
    }

    private func plans(in journal: RegionJournal) throws -> [RegionWritePlan] {
        try checkSupported(journal)
        let module = journal.module!
        guard !journal.entries.isEmpty, Set(journal.entries.map(\.file)).count == journal.entries.count else { throw RegionOperationError("Invalid journal targets.") }
        try validateTargets(module: module, files: journal.entries.compactMap(\.file))
        return try journal.entries.map { entry in
            let file = entry.file!
            let before = try Data(contentsOf: bytesURL(journal, file, "before"))
            let after = try Data(contentsOf: bytesURL(journal, file, "after"))
            guard RegionBackupDigest.sha256(before) == entry.beforeSHA256,
                  RegionBackupDigest.sha256(after) == entry.afterSHA256 else { throw RegionOperationError("Backup checksum mismatch; no system write is authorized.") }
            try entry.scope.validate(before: before, after: after)
            try validateAuthorization(module: module, file: file, scope: entry.scope)
            let plan = RegionWritePlan(file: file, before: before, after: after, scope: entry.scope)
            try validateCachePlan(module: module, plan: plan, applying: false)
            return plan
        }
    }

    private func validateTargets(module: RegionModule, files: [RegionFile]) throws {
        guard files == [.mobileGestalt] else {
            throw RegionOperationError("Every current transaction requires exactly one MobileGestalt source.")
        }
    }

    private func checkSupported(_ journal: RegionJournal) throws {
        guard journal.permitsCurrentRecovery else { throw RegionOperationError(journal.legacyBlock) }
    }

    /// Both apply and restore revalidate the actual plist layout. A saved byte
    /// whitelist alone never authorizes an unknown layout or another question.
    private func validateCachePlan(module: RegionModule, plan: RegionWritePlan, applying: Bool) throws {
        let runtime = layoutProvider()
        let before = try RegionPlist.parse(plan.before).root
        let after = try RegionPlist.parse(plan.after).root
        guard !productType.isEmpty, !build.isEmpty else { throw RegionOperationError("Running device/build identity is unavailable.") }
        for root in [before, after] {
            try RegionModuleMutation.validateSource(root, productType: productType, build: build)
            guard let extra = root["CacheExtra"] as? [String: Any] else { throw JapanRegionError.invalidMobileGestalt }
            if module == .regionInfo || module == .fullJapan {
                let key = try RegionModuleMutation.identityKey(.regionInfo, extra: extra)
                guard plan.scope.extraKeys.contains(key) else { throw RegionOperationError("RegionInfo backup selects another key.") }
            }
            for key in plan.scope.extraKeys {
                guard let value = extra[key] as? String, !value.isEmpty else { throw JapanRegionError.invalidMobileGestalt }
            }
        }
        if module == .fullJapan {
            guard let profile = JapanRegionProfile.verified(for: productType) else {
                throw JapanRegionError.unsupportedProductType(productType)
            }
            try JapanRegionMutation.validate(plist: before, profile: profile, build: build, runtime: runtime)
            try JapanRegionMutation.validate(plist: after, profile: profile, build: build, runtime: runtime)
            if applying && !JapanRegionMutation.isApplied(to: after, profile: profile, build: build, runtime: runtime) {
                throw RegionOperationError("Full Japan requires all six target values; partial changes are forbidden.")
            }
        }
        if applying {
            let expected = try RegionModuleMutation.plan(module: module, raw: plan.before, productType: productType, build: build, runtime: runtime)
            guard RegionPlist.equal(after, try RegionPlist.parse(expected.after).root) else {
                throw RegionOperationError("Replacement does not equal the selected module's complete target configuration.")
            }
        }
        guard !plan.scope.byteOffsets.isEmpty else { return }
        let questions = module == .fullJapan ? RegionCacheQuestion.allCases : module.question.map { [$0] } ?? []
        let layout = try RegionCacheMapping.layout(plist: before, build: build, productType: productType, questions: questions, runtime: runtime)
        _ = try RegionCacheMapping.layout(plist: after, build: build, productType: productType, questions: questions, runtime: runtime)
        if let saved = plan.scope.layoutBinding {
            guard saved == layout.binding else { throw RegionOperationError("Saved descriptor key/slot/type/flags or image/layout identity changed; backup retained.") }
        } else {
            // Only the original strict static profile can authorize old journals
            // without descriptor metadata. A missing binding is never dynamic.
            guard productType == "iPhone18,3", build == "24B119",
                  (before["CacheUUID"] as? String).flatMap(UUID.init(uuidString:))?.uuidString == RegionCacheMapping.cacheUUID,
                  layout.size == 6480 else { throw JapanRegionError.unverifiedCacheSemantics }
        }
        let offsets = Set(layout.fields.map { $0.slot * 8 })
        // Accept existing journals with the older whole-Boolean/validity scope;
        // canonical Boolean and validity checks above still prevent extra edits.
        let legacy = Set(layout.fields.flatMap { Array(($0.slot * 8)..<($0.slot * 8 + 8)) + [layout.slotCount * 8 + $0.slot] })
        guard Set(plan.scope.byteOffsets) == offsets || Set(plan.scope.byteOffsets) == legacy else {
            throw JapanRegionError.unverifiedCacheSemantics
        }
        // Older scopes listed whole Boolean/validity storage. Compatibility
        // never authorizes changes beyond the three validated low bytes.
        guard let a = before["CacheData"] as? Data, let b = after["CacheData"] as? Data,
              a.indices.allSatisfy({ offsets.contains($0) || a[$0] == b[$0] }) else {
            throw JapanRegionError.invalidCachePatchLayout
        }
        if applying, let data = after["CacheData"] as? Data, !layout.isApplied(to: data) {
            throw JapanRegionError.invalidCachePatchLayout
        }
    }

    private func validateAuthorization(module: RegionModule, file: RegionFile, scope: RegionPatchScope) throws {
        var authorized = false
        if file == .mobileGestalt && scope.rootKeys.isEmpty {
            switch module {
            case .regionCode: authorized = scope.extraKeys == [JapanRegionMutation.regionCodeKey] && scope.byteOffsets.isEmpty
            case .regionInfo: authorized = scope.extraKeys.count == 1 && RegionModuleMutation.regionInfoKeys.contains(scope.extraKeys[0]) && scope.byteOffsets.isEmpty
            case .regulatoryModel: authorized = scope.extraKeys == [JapanRegionMutation.regulatoryModelKey] && scope.byteOffsets.isEmpty
            case .greenTea, .notGreenTea, .wapi, .fullJapan:
                if let size = scope.cacheLength, size > 0, size <= 16384 * 9, size.isMultiple(of: 9),
                   scope.cacheUUID.flatMap(UUID.init(uuidString:)) != nil, scope.cacheVersion?.isEmpty == false {
                    let slots = size / 9
                    let valueOffsets = scope.byteOffsets.filter { $0 < slots * 8 }
                    let targetSlots = Set(valueOffsets.map { $0 / 8 })
                    let permitted = Set(targetSlots.flatMap { Array(($0 * 8)..<($0 * 8 + 8)) + [slots * 8 + $0] })
                    authorized = targetSlots.count == (module == .fullJapan ? 3 : 1)
                        && targetSlots.allSatisfy { (0..<slots).contains($0) }
                        && (permitted == Set(scope.byteOffsets) || Set(targetSlots.map { $0 * 8 }) == Set(scope.byteOffsets))
                        && scope.byteOffsets.count == Set(scope.byteOffsets).count
                    if module == .fullJapan {
                        authorized = authorized && scope.extraKeys.count == 3
                            && scope.extraKeys.contains(JapanRegionMutation.regionCodeKey)
                            && scope.extraKeys.contains(JapanRegionMutation.regulatoryModelKey)
                            && RegionModuleMutation.regionInfoKeys.filter { scope.extraKeys.contains($0) }.count == 1
                    } else { authorized = authorized && scope.extraKeys.isEmpty }
                }
            }
        }
        guard authorized else { throw RegionOperationError("Module write scope is outside the fixed region whitelist.") }
    }

    private func bytesURL(_ journal: RegionJournal, _ file: RegionFile, _ side: String) -> URL {
        root.appendingPathComponent(journal.id).appendingPathComponent("\(file.rawValue).\(side).plist")
    }
    private func originalURL(_ module: RegionModule) -> URL {
        let name = module == .fullJapan ? "fullJapan-v2" : module.rawValue
        return root.appendingPathComponent("originals").appendingPathComponent("\(name).plist")
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        return try encoder.encode(value)
    }
    private func decode<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        try PropertyListDecoder().decode(type, from: Data(contentsOf: url))
    }
    private func save(_ journal: RegionJournal) throws {
        let path = root.appendingPathComponent(journal.id).appendingPathComponent("journal.plist")
        let data = try encode(journal)
        try data.write(to: path, options: .atomic)
        try sync(path); try sync(path.deletingLastPathComponent())
        guard try Data(contentsOf: path) == data else { throw RegionOperationError("Journal readback failed.") }
    }
    private func writeNew(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += count
            }
        }
        guard fsync(fd) == 0, try Data(contentsOf: url) == data else { throw RegionOperationError("Exact backup sync/readback failed.") }
        try sync(url.deletingLastPathComponent())
    }
    private func sync(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
