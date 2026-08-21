import Combine
import Foundation

enum RegionConfigurationState: Equatable, Sendable {
    case verified
    case japanLikeUnverified
    case notApplied
    case unavailable
}

struct RegionIdentitySnapshot {
    let build: String
    let productType: String
    let profile: JapanRegionProfile?
    let regionCode: String
    let regionInfo: String
    let regulatoryModel: String
    let activationCountry: String
    let activationRegion: String
    let activationBehaviors: String
    let exactBuildSupported: Bool
    let mutationPathReady: Bool
    let configurationState: RegionConfigurationState
    let readinessDetail: String
}

@MainActor
final class RegionIdentityService: ObservableObject {
    @Published private(set) var snapshot: RegionIdentitySnapshot?
    @Published private(set) var isBusy = false
    @Published private(set) var operationResult: String?
    @Published private(set) var errorMessage: String?
    @Published var shouldRespring = false

    private let gestalt = MobileGestaltAccess.shared()
    private let activation = MobileActivationRegionAccess.shared()

    func refresh() {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        let build = MobileGestaltAccess.currentOSBuild()
        let productType = RealDeviceIdentity.productType
        let profile = JapanRegionProfile.verified(for: productType)

        do {
            guard let plist = try gestalt.readCachePlist() as? [String: Any] else {
                throw JapanRegionError.invalidMobileGestalt
            }
            let cacheExtra = plist["CacheExtra"] as? [String: Any]
            let activationDiagnostics = activation.regionDiagnostics()
            let exactBuild = build == JapanRegionMutation.verifiedBuild
            let configurationState = classifyConfiguration(
                plist: plist,
                cacheExtra: cacheExtra,
                activationDiagnostics: activationDiagnostics,
                profile: profile,
                build: build
            )
            var ready = false
            var readiness = "Ready for verified transaction"

            if let profile {
                do {
                    try JapanRegionMutation.validate(
                        plist: plist,
                        profile: profile,
                        build: build
                    )
                    if (activationDiagnostics["backingReadSucceeded"] as? NSNumber)?.boolValue == true {
                        ready = true
                    } else {
                        readiness = "MobileActivation backing data is unavailable: "
                            + display(activationDiagnostics["backingReadError"])
                    }
                } catch {
                    readiness = error.localizedDescription
                }
            } else {
                if configurationState == .japanLikeUnverified {
                    readiness = "Existing Japan-like persistent identity detected, but no verified "
                        + "Japan profile exists for \(productType). Locus will not modify this device."
                } else {
                    readiness = JapanRegionError
                        .unsupportedProductType(productType)
                        .localizedDescription
                }
            }

            snapshot = RegionIdentitySnapshot(
                build: build,
                productType: productType,
                profile: profile,
                regionCode: display(cacheExtra?[JapanRegionMutation.regionCodeKey]),
                regionInfo: display(cacheExtra?[JapanRegionMutation.regionInfoKey]),
                regulatoryModel: display(cacheExtra?[JapanRegionMutation.regulatoryModelKey]),
                activationCountry: display(activationDiagnostics["backingCountryCode"]),
                activationRegion: display(activationDiagnostics["backingRegionInfo"]),
                activationBehaviors: display(activationDiagnostics["backingSoftwareBehaviors"]),
                exactBuildSupported: exactBuild,
                mutationPathReady: ready,
                configurationState: configurationState,
                readinessDetail: readiness
            )
        } catch {
            snapshot = RegionIdentitySnapshot(
                build: build,
                productType: productType,
                profile: profile,
                regionCode: "<unavailable>",
                regionInfo: "<unavailable>",
                regulatoryModel: "<unavailable>",
                activationCountry: "<unavailable>",
                activationRegion: "<unavailable>",
                activationBehaviors: "<unavailable>",
                exactBuildSupported: build == JapanRegionMutation.verifiedBuild,
                mutationPathReady: false,
                configurationState: .unavailable,
                readinessDetail: error.localizedDescription
            )
            errorMessage = error.localizedDescription
        }
    }

    func applyJapanRegion() {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        operationResult = nil
        shouldRespring = false

        var originalGestalt: Data?
        var originalActivation: Data?
        var wroteGestalt = false
        var wroteActivation = false

        do {
            let build = MobileGestaltAccess.currentOSBuild()
            let productType = RealDeviceIdentity.productType
            guard let profile = JapanRegionProfile.verified(for: productType) else {
                throw JapanRegionError.unsupportedProductType(productType)
            }
            guard build == JapanRegionMutation.verifiedBuild else {
                throw JapanRegionError.unsupportedBuild(build)
            }

            // Both exact source backups are durably created before either
            // persistent file is modified.
            let transactionBackup = try TransactionBackupStore.begin()
            let gestaltData = try gestalt.readCacheData()
            originalGestalt = gestaltData
            try transactionBackup.saveMobileGestalt(gestaltData)

            let activationData = try activation.readRegionData()
            originalActivation = activationData
            try transactionBackup.saveMobileActivation(activationData)

            guard let originalPlist = parsePlist(gestaltData) else {
                throw JapanRegionError.invalidMobileGestalt
            }
            let updatedPlist = try JapanRegionMutation.applying(
                to: originalPlist,
                profile: profile,
                build: build
            )

            wroteActivation = true
            try activation.applyJapanRegion()
            try verifyActivation()

            wroteGestalt = true
            try gestalt.saveCachePlist(updatedPlist)

            guard let verifiedPlist = try gestalt.readCachePlist() as? [String: Any],
                  JapanRegionMutation.isApplied(
                    to: verifiedPlist,
                    profile: profile,
                    build: build
                  ) else {
                throw JapanRegionError.mobileGestaltVerificationFailed
            }
            try verifyActivation()

            isBusy = false
            operationResult = "Verified both persistent sources. SpringBoard will refresh."
            refresh()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(900))
                shouldRespring = true
            }
        } catch {
            let primary = error
            var rollbackErrors: [String] = []

            // Reverse transaction order: MobileGestalt, then MobileActivation.
            if wroteGestalt, let originalGestalt {
                do {
                    try gestalt.restoreCacheData(originalGestalt)
                    guard try gestalt.readCacheData() == originalGestalt else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                } catch {
                    rollbackErrors.append("MobileGestalt: \(error.localizedDescription)")
                }
            }
            if wroteActivation, let originalActivation {
                do {
                    try activation.restoreRegionData(originalActivation)
                    guard try activation.readRegionData() == originalActivation else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                } catch {
                    rollbackErrors.append("MobileActivation: \(error.localizedDescription)")
                }
            }

            isBusy = false
            let finalError: String
            if rollbackErrors.isEmpty {
                finalError = primary.localizedDescription
            } else {
                finalError = JapanRegionError.rollbackFailed(
                    primary: primary.localizedDescription,
                    rollback: rollbackErrors.joined(separator: "\n")
                ).localizedDescription
            }
            refresh()
            errorMessage = finalError
        }
    }

    private func verifyActivation() throws {
        let data = try activation.readRegionData()
        guard let plist = parsePlist(data),
              stringValue(plist, keys: ["DeviceRegionCountryCode", "CountryCode", "Region"]) == "JP",
              stringValue(plist, keys: ["DeviceRegionRegionInfo", "RegionInfo"]) == "J/A",
              parseBehavior(plist, keys: ["DeviceRegionSoftwareBehaviors", "SoftwareBehaviors"]) == 0x19 else {
            throw JapanRegionError.activationVerificationFailed
        }
    }

    private func parsePlist(_ data: Data) -> [String: Any]? {
        try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any]
    }

    private func stringValue(_ plist: [String: Any], keys: [String]) -> String? {
        keys.lazy.compactMap { plist[$0] as? String }.first
    }

    private func parseBehavior(_ plist: [String: Any], keys: [String]) -> UInt32? {
        for key in keys {
            if let number = plist[key] as? NSNumber { return number.uint32Value }
            if let string = plist[key] as? String {
                let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if value.lowercased().hasPrefix("0x") {
                    return UInt32(value.dropFirst(2), radix: 16)
                }
                return UInt32(value, radix: 10)
            }
        }
        return nil
    }

    private func classifyConfiguration(
        plist: [String: Any],
        cacheExtra: [String: Any]?,
        activationDiagnostics: [String: Any],
        profile: JapanRegionProfile?,
        build: String
    ) -> RegionConfigurationState {
        guard let cacheExtra,
              (activationDiagnostics["backingReadSucceeded"] as? NSNumber)?.boolValue == true else {
            return .unavailable
        }

        let activationMatches = activationIsJapan(activationDiagnostics)
        if let profile {
            return JapanRegionMutation.isApplied(
                to: plist,
                profile: profile,
                build: build
            ) && activationMatches ? .verified : .notApplied
        }

        let mobileGestaltMatches = cacheExtra[JapanRegionMutation.regionCodeKey] as? String == "J"
            && cacheExtra[JapanRegionMutation.regionInfoKey] as? String == "J/A"
        return mobileGestaltMatches && activationMatches
            ? .japanLikeUnverified
            : .notApplied
    }

    private func activationIsJapan(_ diagnostics: [String: Any]) -> Bool {
        diagnostics["backingCountryCode"] as? String == "JP"
            && diagnostics["backingRegionInfo"] as? String == "J/A"
            && parseDisplayBehavior(diagnostics["backingSoftwareBehaviors"]) == 0x19
    }

    private func parseDisplayBehavior(_ value: Any?) -> UInt32? {
        if let number = value as? NSNumber { return number.uint32Value }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("0x") {
                return UInt32(trimmed.dropFirst(2), radix: 16)
            }
            return UInt32(trimmed, radix: 10)
        }
        return nil
    }

    private func display(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "<nil>" }
        return String(describing: value)
    }
}
