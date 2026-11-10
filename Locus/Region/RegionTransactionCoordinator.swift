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
        let file: RegionFile
        let beforeSHA256: String
        let afterSHA256: String
        let scope: RegionPatchScope
    }
    let id: String
    let module: RegionModule
    let operation: String
    let productType: String
    let build: String
    let created: Date
    let entries: [Entry]
    var phase: Phase
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
    private let cacheImage: () -> [String: Any]
    private let cacheReviews: [ReviewedCacheSchema]
    private let cacheSystemVersion: String?
    private let fm = FileManager.default

    init(root: URL, access: RegionFileAccess, productType: String, build: String,
         cacheImage: @escaping () -> [String: Any] = { RegionCacheMapping.loadedImage() },
         cacheReviews: [ReviewedCacheSchema] = RegionCacheMapping.reviewed,
         cacheSystemVersion: String? = nil) {
        self.root = root; self.access = access; self.productType = productType; self.build = build
        self.cacheImage = cacheImage; self.cacheReviews = cacheReviews; self.cacheSystemVersion = cacheSystemVersion
    }

    func pending() throws -> [RegionJournal] {
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
                if journal.phase.unfinished { try validateTargets(module: journal.module, files: journal.entries.map(\.file)) }
                return journal.phase.unfinished ? journal : nil
            }.sorted { $0.created < $1.created }
    }

    func originalAvailable(for module: RegionModule) throws -> Bool {
        Self.serial.lock(); defer { Self.serial.unlock() }
        guard fm.fileExists(atPath: originalURL(module).path) else { return false }
        let journal = try original(module)
        _ = try plans(in: journal)
        return true
    }

    @discardableResult
    func apply(module: RegionModule, plans: [RegionWritePlan]) throws -> String {
        Self.serial.lock(); defer { Self.serial.unlock() }
        return try perform(module: module, plans: plans, operation: "apply")
    }

    @discardableResult
    func restore(module: RegionModule, preview: (([RegionWritePlan]) -> Void)? = nil) throws -> String {
        Self.serial.lock(); defer { Self.serial.unlock() }
        let journal = try original(module)
        let saved = try plans(in: journal)
        let restorePlans = try saved.map { plan -> RegionWritePlan in
            let current = try access.read(plan.file)
            let after = try plan.scope.restoring(original: plan.before, applied: plan.after, current: current)
            return .init(file: plan.file, before: current, after: after, scope: plan.scope)
        }
        preview?(restorePlans)
        return try perform(module: module, plans: restorePlans, operation: "restore")
    }

    func recoverPending() throws -> String {
        Self.serial.lock(); defer { Self.serial.unlock() }
        let journals = try pending()
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

    private func perform(module: RegionModule, plans: [RegionWritePlan], operation: String) throws -> String {
        guard !productType.isEmpty, !build.isEmpty else { throw RegionOperationError("Running ProductType/build must be known before a persistent operation.") }
        guard !plans.isEmpty, Set(plans.map(\.file)).count == plans.count else { throw RegionOperationError("Missing or duplicate transaction target.") }
        try validateTargets(module: module, files: plans.map(\.file))
        let requestedFiles = Set(plans.map(\.file))
        guard try pending().allSatisfy({ requestedFiles.isDisjoint(with: $0.entries.map(\.file)) }) else {
            throw RegionOperationError("Unfinished transaction detected for this source. Recover it before modifying the same file.")
        }
        for plan in plans {
            try validateAuthorization(module: module, file: plan.file, scope: plan.scope)
            try plan.scope.validate(before: plan.before, after: plan.after)
            if operation == "apply" { try validateCachePlan(module: module, plan: plan) }
            guard try access.read(plan.file) == plan.before else { throw RegionOperationError("Source changed since planning; nothing was written.") }
        }
        guard plans.contains(where: { $0.before != $0.after }) else {
            return "Already at the requested persistent value. No write or original-value claim was made. Runtime/function verification remains separate."
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
            build: build, created: Date(), entries: plans.map {
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
        if operation == "apply" && !fm.fileExists(atPath: originalURL(module).path) {
            let originals = root.appendingPathComponent("originals", isDirectory: true)
            try fm.createDirectory(at: originals, withIntermediateDirectories: true)
            try sync(root)
            try writeNew(try encode(["transaction": id]), to: originalURL(module))
        }
        var attempted: [RegionWritePlan] = []
        do {
            // Check every source again after backup I/O and before the first write.
            for plan in plans {
                guard try access.read(plan.file) == plan.before else { throw RegionOperationError("Source changed during backup; transaction refused.") }
                if operation == "apply" { try validateCachePlan(module: module, plan: plan) }
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
        let pointer = try decode([String: String].self, at: originalURL(module))
        guard let id = pointer["transaction"], UUID(uuidString: id) != nil else { throw RegionOperationError("Invalid original-value record.") }
        let journal = try decode(RegionJournal.self, at: root.appendingPathComponent(id).appendingPathComponent("journal.plist"))
        guard journal.id == id, journal.module == module, journal.operation == "apply" else { throw RegionOperationError("Original-value record mismatch.") }
        try checkContext(journal)
        return journal
    }

    private func checkContext(_ journal: RegionJournal) throws {
        guard journal.productType == productType, journal.build == build else {
            throw RegionOperationError("Backup belongs to another ProductType or build. Restore requires review after a system update.")
        }
    }

    private func plans(in journal: RegionJournal) throws -> [RegionWritePlan] {
        guard !journal.entries.isEmpty, Set(journal.entries.map(\.file)).count == journal.entries.count else { throw RegionOperationError("Invalid journal targets.") }
        try validateTargets(module: journal.module, files: journal.entries.map(\.file))
        return try journal.entries.map { entry in
            let before = try Data(contentsOf: bytesURL(journal, entry.file, "before"))
            let after = try Data(contentsOf: bytesURL(journal, entry.file, "after"))
            guard RegionBackupDigest.sha256(before) == entry.beforeSHA256,
                  RegionBackupDigest.sha256(after) == entry.afterSHA256 else { throw RegionOperationError("Backup checksum mismatch; no system write is authorized.") }
            try entry.scope.validate(before: before, after: after)
            try validateAuthorization(module: journal.module, file: entry.file, scope: entry.scope)
            return .init(file: entry.file, before: before, after: after, scope: entry.scope)
        }
    }

    private func validateTargets(module: RegionModule, files: [RegionFile]) throws {
        let expected: Set<RegionFile> = module == .fullJapan ? [.mobileGestalt, .mobileActivation]
            : module == .mobileActivation ? [.mobileActivation] : [.mobileGestalt]
        guard files.count == expected.count, Set(files) == expected else {
            throw RegionOperationError("Transaction is missing a required module source; partial Full Japan transactions are forbidden.")
        }
    }

    /// A persisted byte whitelist is a recovery boundary, never new mutation
    /// authority. Reassess the loaded image and exact source before applying.
    /// Restore/rollback retain the original journal's bounds and byte checks.
    private func validateCachePlan(module: RegionModule, plan: RegionWritePlan) throws {
        guard plan.file == .mobileGestalt, !plan.scope.byteOffsets.isEmpty else { return }
        let plist = try RegionPlist.parse(plan.before).root
        let assessments = RegionCacheMapping.assess(plist: plist, build: build,
            image: cacheImage(), writeAccess: true, reviews: cacheReviews,
            productType: productType, systemVersion: cacheSystemVersion)
        let questions = module == .fullJapan ? RegionCacheQuestion.allCases : module.question.map { [$0] } ?? []
        guard !questions.isEmpty else { throw JapanRegionError.unverifiedCacheSemantics }
        var offsets: Set<Int> = []
        guard let after = try RegionPlist.parse(plan.after).root["CacheData"] as? Data else {
            throw JapanRegionError.missingCacheData
        }
        for question in questions {
            let layout = try RegionCacheMapping.layout(for: question, assessments: assessments,
                plist: plist, productType: productType)
            guard layout.isApplied(to: after), let field = layout.fields.first else {
                throw JapanRegionError.invalidCachePatchLayout
            }
            offsets.formUnion(Array((field.slot * 8)..<(field.slot * 8 + 8)) + [layout.slotCount * 8 + field.slot])
        }
        guard offsets == Set(plan.scope.byteOffsets) else { throw JapanRegionError.unverifiedCacheSemantics }
    }

    private func validateAuthorization(module: RegionModule, file: RegionFile, scope: RegionPatchScope) throws {
        var authorized = false
        if file == .mobileActivation {
            let families = [["DeviceRegionCountryCode", "CountryCode", "Region"],
                            ["DeviceRegionRegionInfo", "RegionInfo"], ["DeviceRegionSoftwareBehaviors", "SoftwareBehaviors"]]
            authorized = (module == .mobileActivation || module == .fullJapan) && scope.extraKeys.isEmpty && scope.byteOffsets.isEmpty
                && scope.rootKeys.count == 3 && families.allSatisfy { Set($0).intersection(scope.rootKeys).count == 1 }
        } else if scope.rootKeys.isEmpty {
            switch module {
            case .regionCode: authorized = scope.extraKeys == [JapanRegionMutation.regionCodeKey] && scope.byteOffsets.isEmpty
            case .regionInfo: authorized = scope.extraKeys.count == 1 && RegionModuleMutation.regionInfoKeys.contains(scope.extraKeys[0]) && scope.byteOffsets.isEmpty
            case .regulatoryModel: authorized = scope.extraKeys == [JapanRegionMutation.regulatoryModelKey] && scope.byteOffsets.isEmpty
            case .intelligence: authorized = scope.extraKeys == [RegionModuleMutation.intelligenceKey] && scope.byteOffsets.isEmpty
            case .greenTea, .notGreenTea, .wapi, .fullJapan:
                if let size = scope.cacheLength, size > 0, size <= 16384 * 9, size.isMultiple(of: 9),
                   scope.cacheUUID.flatMap(UUID.init(uuidString:)) != nil, scope.cacheVersion?.isEmpty == false {
                    let slots = size / 9
                    let valueOffsets = scope.byteOffsets.filter { $0 < slots * 8 }
                    let targetSlots = Set(valueOffsets.map { $0 / 8 })
                    let permitted = Set(targetSlots.flatMap { Array(($0 * 8)..<($0 * 8 + 8)) + [slots * 8 + $0] })
                    authorized = targetSlots.count == (module == .fullJapan ? 3 : 1)
                        && targetSlots.allSatisfy { (0..<slots).contains($0) }
                        && permitted == Set(scope.byteOffsets) && scope.byteOffsets.count == permitted.count
                    if module == .fullJapan {
                        authorized = authorized && scope.extraKeys.count == 3
                            && scope.extraKeys.contains(JapanRegionMutation.regionCodeKey)
                            && scope.extraKeys.contains(JapanRegionMutation.regulatoryModelKey)
                            && RegionModuleMutation.regionInfoKeys.filter { scope.extraKeys.contains($0) }.count == 1
                    } else { authorized = authorized && scope.extraKeys.isEmpty }
                }
            default: break
            }
        }
        guard authorized else { throw RegionOperationError("Module write scope is outside the fixed region whitelist.") }
    }

    private func bytesURL(_ journal: RegionJournal, _ file: RegionFile, _ side: String) -> URL {
        root.appendingPathComponent(journal.id).appendingPathComponent("\(file.rawValue).\(side).plist")
    }
    private func originalURL(_ module: RegionModule) -> URL {
        root.appendingPathComponent("originals").appendingPathComponent("\(module.rawValue).plist")
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
