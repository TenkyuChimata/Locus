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
        try MobileGestaltAccess.shared().readCacheData()
    }
    func replace(_ file: RegionFile, expected: Data, replacement: Data) throws {
        try MobileGestaltAccess.shared().replaceCacheData(expected, with: replacement)
    }
}

nonisolated enum FullJapanState: String {
    case ready = "Ready", applied = "Applied", notApplied = "Not Applied"
    case unsupported = "Unsupported", recoveryRequired = "Recovery Required"
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
    @Published private(set) var cacheLayout = "Not verified"
    @Published private(set) var mobileGestaltAccess = "Unavailable"
    @Published private(set) var cacheExtraSupport = "Not verified"
    @Published private(set) var cacheUUID = "<unavailable>"
    @Published private(set) var prepared: RegionJournal?
    @Published private(set) var fullJapanState = FullJapanState.unsupported
    @Published private(set) var legacyBackupDetail: String?

    private let gestalt = MobileGestaltAccess.shared()
    private let backupRoot: URL?
    private let deviceID: String?
    private let fileAccess: RegionFileAccess
    private let layoutProvider: () -> RegionLayoutResolution
    private let deviceContext: () -> (productType: String, build: String)

    init(backupRoot: URL? = nil, access: RegionFileAccess? = nil,
         deviceContext: (() -> (productType: String, build: String))? = nil, deviceID: String? = nil,
         layoutProvider: @escaping () -> RegionLayoutResolution = { .current() }) {
        #if os(iOS)
        self.deviceID = deviceID ?? UIDevice.current.identifierForVendor?.uuidString
        #else
        self.deviceID = deviceID
        #endif
        self.layoutProvider = layoutProvider
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
        return .init(root: root, access: fileAccess, productType: context.productType, build: context.build, deviceID: deviceID, layoutProvider: layoutProvider)
    }

    func refresh() {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let context = deviceContext()
        build = context.build
        productType = context.productType
        var errors: [String] = []
        var raw: Data?
        var plist: [String: Any] = [:]
        do {
            raw = try fileAccess.read(.mobileGestalt)
            plist = try RegionPlist.parse(raw!).root
        } catch { errors.append("MobileGestalt: \(error.localizedDescription)") }
        var runtime: [String: Any] = [:]
        do {
            runtime = try gestalt.runtimeAnswers(for: RegionModule.allCases.filter { $0 != .fullJapan }.map(\.runtimeQuery)
                + RegionModuleMutation.regionInfoKeys)
        } catch { errors.append("Runtime: \(error.localizedDescription)") }
        cacheUUID = plist["CacheUUID"] as? String ?? "<unavailable>"
        let writeStatus = gestalt.cacheWriteAccessStatus()
        let writeAccess = (writeStatus["writable"] as? NSNumber)?.boolValue == true
        mobileGestaltAccess = writeAccess ? "Writable" : (raw == nil ? "Unavailable" : "Read-only")
        let runtimeLayout = layoutProvider()
        switch runtimeLayout {
        case .resolved(let layout):
            let uuid = (plist["CacheUUID"] as? String).flatMap(UUID.init(uuidString:))?.uuidString
            let length = (plist["CacheData"] as? Data)?.count
            cacheLayout = uuid == layout.cacheUUID && length == layout.slotCount * 9 && plist["CacheVersion"] as? String == build
                ? "Dynamically resolved; per-field validation required" : "Not verified — runtime/cache identity mismatch"
        case .rejected(let reason): cacheLayout = reason
        case .unavailable:
            cacheLayout = (try? RegionCacheMapping.layout(plist: plist, build: build, productType: productType,
                questions: [.greenTea], runtime: runtimeLayout)) == nil ? "Not verified" : "Device-verified static layout"
        }
        let assessments = RegionCacheMapping.assess(plist: plist, build: build, writeAccess: writeAccess, productType: productType, runtime: runtimeLayout)
        var transactionStore: RegionTransactionCoordinator?
        var blocked: String?
        recoveryDetail = nil
        legacyBackupDetail = nil
        do {
            let store = try coordinator()
            transactionStore = store
            let unfinished = try store.pending()
            if !unfinished.isEmpty {
                recoveryDetail = unfinished.map { journal in
                    journal.permitsCurrentRecovery
                        ? "\(journal.moduleName) / \(journal.phase.rawValue) / \(journal.id)"
                        : journal.legacyBlock
                }.joined(separator: "\n")
                blocked = "Recovery Required: resolve the unfinished transaction before changing MobileGestalt."
            }
            legacyBackupDetail = try store.legacyBackupDetail()
        } catch {
            blocked = error.localizedDescription
            recoveryDetail = blocked
            errors.append("Recovery: \(error.localizedDescription)")
        }
        if build.isEmpty || productType.isEmpty { blocked = "Running build or real ProductType is unavailable." }
        let extra = plist["CacheExtra"] as? [String: Any] ?? [:]
        var statuses: [RegionModuleStatus] = []
        for module in RegionModule.allCases where module != .fullJapan {
            var current = "<unavailable>"
            var runtimeValue = display(runtime[module.runtimeQuery])
            var access = "Unsupported", detail = blocked.map { $0 + "\n" } ?? ""
            var applicable = false, original = false, originalInvalid = false
            do { original = try transactionStore?.originalAvailable(for: module) ?? false }
            catch { originalInvalid = true; detail += "Original backup invalid: \(error.localizedDescription)\n" }
            if let question = module.question, let item = assessments.first(where: { $0.question == question }) {
                current = item.cacheValue.map(String.init) ?? "<unavailable>"
                access = item.status.rawValue
                detail += item.reason
                applicable = item.permitsMutation
            } else {
                do {
                    let key = try RegionModuleMutation.identityKey(module, extra: extra)
                    current = display(extra[key])
                    if module == .regionInfo { runtimeValue = display(runtime[key]) }
                    guard let raw else { throw JapanRegionError.invalidMobileGestalt }
                    _ = try RegionModuleMutation.plan(module: module, raw: raw, productType: productType, build: build, runtime: runtimeLayout)
                    applicable = writeAccess
                    access = writeAccess ? "Writable" : "Read-only"
                    detail += "Existing key: \(key)."
                    if !writeAccess { detail += " " + display(writeStatus["error"]) }
                } catch {
                    detail += error.localizedDescription
                    if module == .regionInfo {
                        current = RegionModuleMutation.regionInfoKeys.map { "\($0): \(display(extra[$0]))" }.joined(separator: "\n")
                    }
                }
            }
            var restoreReady = original && blocked == nil && applicable
            if restoreReady {
                do { _ = try transactionStore?.restorePlans(module: module) }
                catch { restoreReady = false; detail += " Restore unavailable: \(error.localizedDescription)" }
            }
            statuses.append(.init(module: module, cache: current, runtime: runtimeValue, expected: expected(module),
                access: access, verification: "Restart and runtime verification pending.", detail: detail,
                originalAvailable: original, canApply: applicable && blocked == nil && !originalInvalid,
                canRestore: restoreReady))
        }
        let extraCount = statuses.filter { $0.module.question == nil && ["Writable", "Read-only"].contains($0.access) }.count
        cacheExtraSupport = "\(extraCount)/3 fields verified"
        var fullOriginal = false, fullOriginalInvalid = false
        var fullDetail = "One MobileGestalt transaction for all six settings. File readback confirms these settings only. Restart, observe runtime answers and test affected features separately."
        do { fullOriginal = try transactionStore?.originalAvailable(for: .fullJapan) ?? false }
        catch { fullOriginalInvalid = true; fullDetail += " Original backup invalid: \(error.localizedDescription)" }
        var fullSupported = false, fullApplied = false
        do {
            guard let raw else { throw JapanRegionError.invalidMobileGestalt }
            let plan = try RegionModuleMutation.plan(module: .fullJapan, raw: raw, productType: productType, build: build, runtime: runtimeLayout)
            fullSupported = true
            fullApplied = plan.before == plan.after
        } catch { fullDetail += " " + error.localizedDescription }
        var fullRestore = fullOriginal && fullSupported && writeAccess && blocked == nil
        if fullRestore {
            do { _ = try transactionStore?.restorePlans(module: .fullJapan) }
            catch { fullRestore = false; fullDetail += " Restore unavailable: \(error.localizedDescription)" }
        }
        if blocked != nil || fullOriginalInvalid { fullJapanState = .recoveryRequired }
        else if !fullSupported { fullJapanState = .unsupported }
        else if fullApplied { fullJapanState = .applied }
        else { fullJapanState = writeAccess ? .ready : .notApplied }
        if let blocked { fullDetail += " " + blocked }
        if !writeAccess { fullDetail += " " + display(writeStatus["error"]) }
        let missing = statuses.filter { $0.access == "Unsupported" }.map { $0.module.title }
        if !missing.isEmpty { fullDetail += " Unavailable prerequisites: " + missing.joined(separator: ", ") + "." }
        let six = statuses
        statuses.append(.init(module: .fullJapan,
            cache: six.map { "\($0.module.title): \($0.cache)" }.joined(separator: "\n"),
            runtime: six.map { "\($0.module.title): \($0.runtime)" }.joined(separator: "\n"),
            expected: six.map { "\($0.module.title) = \($0.expected)" }.joined(separator: "\n"),
            access: fullSupported ? (writeAccess ? "Writable" : "Read-only") : "Unsupported",
            verification: fullJapanState.rawValue + (fullApplied ? " — Already Applied / No Changes Needed" : ""),
            detail: fullDetail, originalAvailable: fullOriginal,
            canApply: fullSupported && writeAccess && blocked == nil && !fullOriginalInvalid,
            canRestore: fullRestore))
        modules = statuses
        errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    /// Prepare the exact diff and verified full backups before enabling the
    /// confirmation button. The existing journal's prepared phase does no write.
    @discardableResult
    func prepare(_ module: RegionModule, restore: Bool = false) -> Bool {
        guard !isBusy, prepared == nil else { return false }
        refresh()
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
        run {
            try coordinator().commitPrepared(journal.id)
        }
    }

    func cancelPrepared() {
        guard !isBusy, let journal = prepared else { return }
        prepared = nil
        run { try coordinator().cancelPrepared(journal.id); return "Cancelled. No system file was written." }
    }

    private func applyPlans(_ module: RegionModule) throws -> [RegionWritePlan] {
        let raw = try fileAccess.read(.mobileGestalt)
        return [try RegionModuleMutation.plan(module: module, raw: raw, productType: productType, build: build, runtime: layoutProvider())]
    }

    func recover() { run { try coordinator().recoverPending() } }

    private func run(_ operation: () throws -> String) {
        guard !isBusy else { return }
        isBusy = true; errorMessage = nil; operationResult = nil
        var result: String?, failure: String?
        do { result = try operation() } catch { failure = error.localizedDescription }
        isBusy = false
        refresh()
        operationResult = result
        if let failure { errorMessage = failure }
    }

    private func expected(_ module: RegionModule) -> String {
        if let question = module.question { return String(question.target) }
        switch module {
        case .regionCode: return "J"
        case .regionInfo: return "J/A"
        case .regulatoryModel: return JapanRegionProfile.verified(for: productType)?.regulatoryModel ?? "No verified model"
        default: return "See prerequisites"
        }
    }
    private func display(_ value: Any?) -> String {
        DiagnosticValueFormatter.display(value)
    }
}
