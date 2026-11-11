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

struct RegionAccessDiagnosticRow: Identifiable {
    let title: String
    let value: String
    var id: String { title }
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

    // Present the existing read-only observation; evaluating rows performs no I/O.
    var activationDiagnostics: [RegionAccessDiagnosticRow] {
        let info = activationInfo
        let observed = activationObservedAt != nil
        let discovery = info["discovery"] as? [String: Any] ?? [:]
        func text(_ value: Any?, fallback: String = "Not Tested") -> String {
            guard let value, !(value is NSNull) else { return fallback }
            return String(describing: value)
        }
        func flag(_ key: String, yes: String = "Succeeded", no: String = "Failed") -> String {
            guard observed, let value = info[key] as? NSNumber else { return "Not Tested" }
            return value.boolValue ? yes : no
        }
        func errorDetails(_ value: Any?) -> String? {
            guard let details = value as? [String: Any], let errors = details["errors"] as? [[String: Any]] else { return nil }
            return ([text(details["stage"])] + errors.map {
                "\(text($0["domain"])):\(text($0["code"]))"
            }).joined(separator: " → ")
        }
        func errorText(_ details: Any?, _ message: Any?) -> String {
            let parts = [errorDetails(details), text(message, fallback: "")].compactMap { $0 }.filter { !$0.isEmpty }
            return parts.isEmpty ? (observed ? "None" : "Not Tested") : parts.joined(separator: " — ")
        }
        func pathState(_ value: Any?) -> String {
            guard let path = value as? [String: Any], let state = path["state"] as? String,
                  state != "not-observed" else { return "Not Tested" }
            // ENOENT applies to this candidate path; it does not disprove other locations.
            let label = path["code"] as? Int == 2 ? "Not found at candidate path" : state
            return label + (path["code"].map { " (\(text(path["domain"])):\($0))" } ?? "")
        }
        func row(_ title: String, _ value: String) -> RegionAccessDiagnosticRow { .init(title: title, value: value) }
        let source = discovery["source"] as? String
        let resolverCode = text(info["resolverStatus"], fallback: "")
        let resolverName = text(info["resolverStatusName"], fallback: "")
        let resolver = [flag("resolverSucceeded"), resolverCode, resolverName].filter { !$0.isEmpty }.joined(separator: " / ")
        var rows = [
            row("SystemGroup Resolution", observed ? (source != nil && source != "unresolved" ? "Succeeded" : "Failed") : "Not Tested"),
            row("Resolver Status", resolver),
            row("Resolver Detail", text(info["resolverDetail"], fallback: observed ? "None" : "Not Tested")),
            row("Discovery Source", text(source)),
            row("Backing File State", pathState(info["backingPathState"])),
            row("Backing Stage", text(info["backingStage"]))
        ]
        if info["backingStage"] as? String == "region-lease" {
            rows.append(row("Lease Target State", pathState(info["regionLeaseTargetState"])))
        }
        if let query = discovery["identityQuery"] as? [String: Any] {
            let codes = [query["queryErrorType"].map { "type=\($0)" }, query["queryErrorName"] as? String,
                         query["queryErrorPOSIXCode"].map { "POSIX=\($0)" }].compactMap { $0 }
            rows.append(row("Container Query", ([text(query["status"])] + codes).joined(separator: " / ")))
        }
        if let failure = discovery["lastMetadataFailure"] {
            rows.append(row("Metadata Failure", errorText(failure,
                (failure as? [String: Any])?["stage"] as? String == "metadata-lease" ? discovery["lastMetadataLeaseDetail"] : nil)))
        }
        if let readFailure = discovery["lastMetadataReadFailure"] {
            rows.append(row("Metadata Read Error", errorText(readFailure, nil)))
        }
        rows += [
            row("Backing Read", flag("backingReadSucceeded")),
            row("Read Error", errorText(info["backingErrorDetails"], observed ? info["backingReadError"] : nil)),
            row("Schema Valid", flag("backingSchemaValid", yes: "Valid", no: "Unsupported")),
            row("Write Access", flag("backingWriteAccessAvailable", yes: "Available (open only)", no: "Failed (writes unavailable)")),
            row("Write Error", info["backingWriteAccessAvailable"] is NSNumber ? errorText(nil, info["backingWriteAccessError"]) : "Not Tested")
        ]
        let apiDescription = text(info["effectiveErrorDescription"], fallback: "")
        let apiError = [text(info["effectiveErrorDomain"], fallback: ""), text(info["effectiveErrorCode"], fallback: ""),
                        apiDescription].filter { !$0.isEmpty }.joined(separator: " / ")
        rows += [
            row("MobileActivation API", flag("effectiveCallSucceeded", yes: apiError.isEmpty ? "Succeeded" : "Succeeded with error")),
            row("API Stage", text(info["effectiveStage"])),
            row("API Error", apiError.isEmpty ? (observed ? "None" : "Not Tested") : apiError)
        ]
        if (info["effectiveCallSucceeded"] as? NSNumber)?.boolValue == true {
            rows += [row("CountryCode", text(info["effectiveCountryCode"], fallback: "<nil>")),
                     row("RegionInfo", text(info["effectiveRegionInfo"], fallback: "<nil>")),
                     row("SoftwareBehaviors", text(info["effectiveSoftwareBehaviors"], fallback: "<nil>"))]
        }
        rows += [
            row("Binary Gate", flag("binarySupported", yes: "Reviewed", no: "Unreviewed (writes blocked)")),
            row("Mutation Schema", flag("mutationSchemaSupported", yes: "Supported", no: "Blocked")),
            row("Mutation Error", observed ? errorText(info["mutationSchemaErrorDetails"], info["mutationSchemaError"]) : "Not Tested")
        ]
        return rows
    }

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

    func refresh() {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let context = deviceContext()
        build = context.build
        productType = context.productType
        var errors: [String] = []
        // Reuse the last explicit research observation. Ordinary refresh and
        // MobileGestalt actions never query/scan MobileActivation containers.
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
        refresh()
        guard let status = modules.first(where: { $0.module == module }), restore ? status.canRestore : status.canApply else {
            errorMessage = "\(module.title): no supported layout, writable path or compatible backup."
            return false
        }
        // Retain a fresh mutation preflight if a future reviewed binary makes
        // this action available. It does not update the research display.
        if module == .mobileActivation || module == .fullJapan {
            let preflight = activation.regionDiagnostics()
            guard (preflight["mutationSchemaSupported"] as? NSNumber)?.boolValue == true else {
                errorMessage = display(preflight["mutationSchemaError"])
                return false
            }
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
    func refreshResearch() {
        guard !isBusy else { return }
        activationInfo = activation.regionDiagnostics()
        activationObservedAt = Date()
        refresh()
    }
    func applyJapanRegion() { apply(.fullJapan) }

    private func run(_ operation: () throws -> String) {
        guard !isBusy else { return }
        isBusy = true; errorMessage = nil; operationResult = nil; shouldRespring = false
        var result: String?, failure: String?
        do { result = try operation() } catch { failure = error.localizedDescription }
        isBusy = false
        refresh()
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
