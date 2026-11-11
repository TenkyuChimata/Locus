// SPDX-License-Identifier: GPL-3.0-only
#if canImport(Combine)
import Combine
#endif
import Foundation
#if os(iOS)
import UIKit
#endif

struct RegionModuleStatus: Identifiable {
    let module: RegionModule
    var id: RegionModule { module }
    let cache: String
    let runtime: String
    let expected: String
    let access: String
    let verification: String
    let detail: String
    let originalAvailable: Bool
    let canApply: Bool
    let canRestore: Bool
}

final class NativeRegionFileAccess: RegionFileAccess {
    func read(_ file: RegionFile) throws -> Data {
        switch file {
        case .mobileGestalt: return try MobileGestaltAccess.shared().readCacheData()
        case .mobileActivation: return try MobileActivationRegionAccess.shared().readRegionData()
        }
    }
    func replace(_ file: RegionFile, expected: Data, replacement: Data) throws {
        switch file {
        case .mobileGestalt: try MobileGestaltAccess.shared().replaceCacheData(expected, with: replacement)
        case .mobileActivation: try MobileActivationRegionAccess.shared().replaceRegionData(expected, with: replacement)
        }
    }
}

@MainActor
final class RegionIdentityService: ObservableObject {
    @Published private(set) var modules: [RegionModuleStatus] = []
    @Published private(set) var isBusy = false
    @Published private(set) var operationResult: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var recoveryDetail: String?
    @Published private(set) var comparisons: [String] = []
    @Published private(set) var build = ""
    @Published private(set) var productType = ""
    @Published private(set) var cacheUUID = "<unavailable>"
    @Published private(set) var prepared: RegionJournal?
    @Published var shouldRespring = false

    private let gestalt = MobileGestaltAccess.shared()
    private let activation = MobileActivationRegionAccess.shared()
    private let backupRoot: URL?
    private let deviceID: String?
    private let fileAccess: RegionFileAccess
    private let deviceContext: () -> (productType: String, build: String)
    private var activationInfo: [String: Any] = ["mutationSchemaSupported": false,
        "mutationSchemaError": "MobileActivation research has not been refreshed. Use its independent research refresh."]
    private var activationObservedAt: Date?

    init(backupRoot: URL? = nil, access: RegionFileAccess? = nil,
         deviceContext: (() -> (productType: String, build: String))? = nil, deviceID: String? = nil) {
        #if os(iOS)
        self.deviceID = deviceID ?? UIDevice.current.identifierForVendor?.uuidString
        #else
        self.deviceID = deviceID
        #endif
        self.backupRoot = backupRoot
        self.fileAccess = access ?? NativeRegionFileAccess()
        self.deviceContext = deviceContext ?? { (RealDeviceIdentity.productType, MobileGestaltAccess.currentOSBuild()) }
    }

    private func coordinator() throws -> RegionTransactionCoordinator {
        #if os(iOS)
        guard deviceID != nil else { throw RegionOperationError("Device identity is unavailable. Unlock the device and reopen Locus.") }
        #endif
        let root: URL
        if let backupRoot { root = backupRoot }
        else {
            root = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true).appendingPathComponent("Region Module Backups", isDirectory: true)
        }
        let context = deviceContext()
        return .init(root: root, access: fileAccess, productType: context.productType, build: context.build, deviceID: deviceID)
    }

    func refresh(includeActivation: Bool = false) {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let context = deviceContext()
        build = context.build
        productType = context.productType
        var errors: [String] = []
        // Independent identity/capability actions never require an activation
        // query or container scan. Explicit research/full actions refresh it
        // before making the MG queries in this observation.
        if includeActivation {
            activationInfo = activation.regionDiagnostics()
            activationObservedAt = Date()
        }
        var raw: Data?
        var plist: [String: Any] = [:]
        do {
            raw = try fileAccess.read(.mobileGestalt)
            plist = try RegionPlist.parse(raw!).root
        } catch { errors.append("MobileGestalt: \(error.localizedDescription)") }
        var runtime: [String: Any] = [:]
        do {
            runtime = try gestalt.runtimeAnswers(for: RegionModule.allCases.filter { $0 != .fullJapan && $0 != .mobileActivation }.map(\.runtimeQuery)
                + RegionModuleMutation.regionInfoKeys)
        } catch { errors.append("Runtime: \(error.localizedDescription)") }
        cacheUUID = plist["CacheUUID"] as? String ?? "<unavailable>"
        let writeStatus = gestalt.cacheWriteAccessStatus()
        let writeAccess = (writeStatus["writable"] as? NSNumber)?.boolValue == true
        let assessments = RegionCacheMapping.assess(plist: plist, build: build, writeAccess: writeAccess, productType: productType)
        var transactionStore: RegionTransactionCoordinator?
        var blocked: String?
        var pendingTransactions: [RegionJournal] = []
        do {
            let store = try coordinator()
            transactionStore = store
            let pending = try store.pending()
            pendingTransactions = pending.filter { $0.id != prepared?.id }
            recoveryDetail = pendingTransactions.isEmpty ? nil : pendingTransactions.map { "\($0.module.title): \($0.phase.rawValue) (\($0.id))" }.joined(separator: "\n")
        } catch {
            recoveryDetail = error.localizedDescription
            blocked = "Backup/journal inspection failed: \(error.localizedDescription)"
        }
        if build.isEmpty || productType.isEmpty { blocked = "Running build or real ProductType is unavailable." }
        let extra = plist["CacheExtra"] as? [String: Any] ?? [:]
        var statuses: [RegionModuleStatus] = []
        for module in RegionModule.allCases where module != .fullJapan {
            let source: RegionFile = module == .mobileActivation ? .mobileActivation : .mobileGestalt
            let moduleBlocked = blocked ?? (pendingTransactions.contains { $0.entries.contains { $0.file == source } }
                ? "Recover the unfinished transaction touching this source before writing." : nil)
            var current = "<unavailable>", runtimeValue = display(runtime[module.runtimeQuery])
            var access = "Unavailable", detail = moduleBlocked.map { $0 + "\n" } ?? "", applicable = false
            var original = false
            var originalInvalid = false
            do { original = try transactionStore?.originalAvailable(for: module) ?? false }
            catch { originalInvalid = true; detail += "Original backup invalid: \(error.localizedDescription)\n" }
            if module == .mobileActivation {
                current = "\(display(activationInfo["backingCountryCode"])) / \(display(activationInfo["backingRegionInfo"])) / \(display(activationInfo["backingSoftwareBehaviors"]))"
                runtimeValue = "\(display(activationInfo["effectiveCountryCode"])) / \(display(activationInfo["effectiveRegionInfo"])) / \(display(activationInfo["effectiveSoftwareBehaviors"]))"
                applicable = (activationInfo["mutationSchemaSupported"] as? NSNumber)?.boolValue == true
                access = applicable ? "Writable" : "Unsupported"
                detail += display(activationInfo["mutationSchemaError"])
                if let activationObservedAt {
                    detail += " Last explicit research observation: \(activationObservedAt.formatted(date: .abbreviated, time: .standard)). Refresh research to observe again."
                }
            } else if let question = module.question, let item = assessments.first(where: { $0.question == question }) {
                current = item.cacheValue.map(String.init) ?? "<unavailable>"
                access = item.status.rawValue
                detail += item.reason
                applicable = item.permitsMutation
            } else {
                do {
                    let key = try RegionModuleMutation.identityKey(module, extra: extra)
                    current = display(extra[key])
                    guard let raw else { throw JapanRegionError.invalidMobileGestalt }
                    _ = try RegionModuleMutation.plan(module: module, raw: raw, productType: productType, build: build)
                    applicable = writeAccess
                    access = writeAccess ? "Writable" : "Read-only"
                    detail += "Existing key: \(key). Independent of CacheData and MobileActivation."
                    if !writeAccess { detail += " " + display(writeStatus["error"]) }
                } catch {
                    access = "Unsupported"
                    detail += error.localizedDescription
                    if module == .regionInfo {
                        current = RegionModuleMutation.regionInfoKeys.map { "\($0): \(display(extra[$0]))" }.joined(separator: "\n")
                    }
                }
            }
            var restoreReady = original && moduleBlocked == nil && (module.question != nil || module == .mobileActivation ? applicable : writeAccess)
            if restoreReady {
                do { _ = try transactionStore?.restorePlans(module: module) }
                catch { restoreReady = false; detail += " Restore unavailable: \(error.localizedDescription)" }
            }
            statuses.append(.init(module: module, cache: current, runtime: runtimeValue, expected: expected(module),
                access: access, verification: "Persistent and current-process observations only. Restart/function verification pending.",
                detail: detail, originalAvailable: original, canApply: applicable && moduleBlocked == nil && !originalInvalid,
                canRestore: restoreReady))
        }
        let prerequisites = statuses.filter { $0.module != .intelligence }
        var fullReady = prerequisites.allSatisfy(\.canApply)
        var fullOriginal = false
        do { fullOriginal = try transactionStore?.originalAvailable(for: .fullJapan) ?? false }
        catch { fullReady = false; errors.append("Full transaction backup: \(error.localizedDescription)") }
        statuses.append(.init(module: .fullJapan, cache: "See individual source values above", runtime: "See independent runtime values above",
            expected: "J / J/A / verified model; false / true / false; activation JP / J/A / 25",
            access: fullReady ? "Writable" : "Unsupported",
            verification: "All persistent sources must pass together. AI capability is an independent option.",
            detail: prerequisites.map { "\($0.module.title): \($0.canApply ? "ready" : $0.access)" }.joined(separator: "\n"),
            originalAvailable: fullOriginal, canApply: fullReady, canRestore: fullOriginal && fullReady))
        modules = statuses
        errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    /// Prepare the exact diff and verified full backups before enabling the
    /// confirmation button. The existing journal's prepared phase does no write.
    @discardableResult
    func prepare(_ module: RegionModule, restore: Bool = false) -> Bool {
        guard !isBusy, prepared == nil else { return false }
        refresh(includeActivation: module == .mobileActivation || module == .fullJapan)
        guard let status = modules.first(where: { $0.module == module }), restore ? status.canRestore : status.canApply else {
            errorMessage = "\(module.title): no supported layout, writable path or compatible backup."
            return false
        }
        isBusy = true; errorMessage = nil; operationResult = nil; comparisons = []
        var failure: String?
        do {
            let store = try coordinator()
            let plans = try (restore ? store.restorePlans(module: module) : applyPlans(module))
            comparisons = plans.flatMap(\.comparison)
            prepared = try store.prepare(module: module, plans: plans, operation: restore ? "restore" : "apply")
            if prepared == nil { operationResult = RegionTransactionCoordinator.unchangedMessage }
        } catch { failure = error.localizedDescription }
        isBusy = false
        refresh()
        if let failure { errorMessage = failure }
        return prepared != nil
    }

    func confirmPrepared() {
        guard !isBusy, let journal = prepared else { return }
        prepared = nil
        run(refreshActivation: journal.module == .mobileActivation || journal.module == .fullJapan) {
            try coordinator().commitPrepared(journal.id)
        }
    }

    func cancelPrepared() {
        guard !isBusy, let journal = prepared else { return }
        prepared = nil
        run { try coordinator().cancelPrepared(journal.id); return "Cancelled. No system file was written." }
    }

    func apply(_ module: RegionModule) { if prepare(module) { confirmPrepared() } }
    func restore(_ module: RegionModule) { if prepare(module, restore: true) { confirmPrepared() } }

    private func applyPlans(_ module: RegionModule) throws -> [RegionWritePlan] {
        if module == .mobileActivation {
            let raw = try fileAccess.read(.mobileActivation)
            try activation.validateRegionData(raw)
            return [try RegionModuleMutation.activationPlan(raw: raw)]
        }
        if module == .fullJapan { return try fullPlans() }
        let raw = try fileAccess.read(.mobileGestalt)
        return [try RegionModuleMutation.plan(module: module, raw: raw, productType: productType, build: build)]
    }

    func recover() { run { try coordinator().recoverPending() } }
    func refreshResearch() { refresh(includeActivation: true) }
    func applyJapanRegion() { apply(.fullJapan) }

    private func run(refreshActivation: Bool = false, _ operation: () throws -> String) {
        guard !isBusy else { return }
        isBusy = true; errorMessage = nil; operationResult = nil; shouldRespring = false
        var result: String?, failure: String?
        do { result = try operation() } catch { failure = error.localizedDescription }
        isBusy = false
        refresh(includeActivation: refreshActivation)
        operationResult = result
        if let failure { errorMessage = failure }
    }

    private func fullPlans() throws -> [RegionWritePlan] {
        let mg = try fileAccess.read(.mobileGestalt)
        let parsed = try RegionPlist.parse(mg)
        guard let profile = JapanRegionProfile.verified(for: productType) else { throw JapanRegionError.unsupportedProductType(productType) }
        let modified = try JapanRegionMutation.applying(to: parsed.root, profile: profile, build: build)
        let layout = try JapanRegionCacheLayout.resolve(plist: parsed.root, build: build, productType: productType)
        let extra = parsed.root["CacheExtra"] as? [String: Any] ?? [:]
        let scope = RegionPatchScope(extraKeys: [JapanRegionMutation.regionCodeKey,
            try RegionModuleMutation.identityKey(.regionInfo, extra: extra), JapanRegionMutation.regulatoryModelKey],
            byteOffsets: layout.fields.map { $0.slot * 8 },
            cacheUUID: parsed.root["CacheUUID"] as? String, cacheVersion: parsed.root["CacheVersion"] as? String,
            cacheLength: (parsed.root["CacheData"] as? Data)?.count)
        let after = RegionPlist.equal(parsed.root, modified) ? mg :
            try PropertyListSerialization.data(fromPropertyList: modified, format: parsed.format, options: 0)
        let ma = try fileAccess.read(.mobileActivation)
        try activation.validateRegionData(ma)
        return [try RegionModuleMutation.activationPlan(raw: ma), .init(file: .mobileGestalt, before: mg, after: after, scope: scope)]
    }

    private func expected(_ module: RegionModule) -> String {
        if let question = module.question { return String(question.target) }
        switch module {
        case .regionCode: return "J"
        case .regionInfo: return "J/A"
        case .regulatoryModel: return JapanRegionProfile.verified(for: productType)?.regulatoryModel ?? "No verified model"
        case .intelligence: return "true / 1 (capability flag only)"
        case .mobileActivation: return "JP / J/A / 25 (0x19)"
        default: return "See prerequisites"
        }
    }
    private func display(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "<nil>" }
        return String(describing: value)
    }
}
