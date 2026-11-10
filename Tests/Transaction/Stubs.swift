// SPDX-License-Identifier: GPL-3.0-only
// Simulated dependencies for the actual RegionIdentityService orchestration.
// These types are never compiled into the app. No Apple cache layout is assumed.
import Foundation

@MainActor enum Fixture {
    enum Fault { case none, backup, activationPartial, gestaltPartial, gestaltVerification, finalActivationVerification, rollback }
    static var fault = Fault.none
    static var events: [String] = []
    static var gestalt = initialGestalt
    static var activation = initialActivation
    static var activationReads = 0
    static var layoutKnown = true
    static var initialGestalt: Data { encode(["CacheExtra": ["code": "CH", "info": "CH/A", "model": "old"]]) }
    static var initialActivation: Data { encode(["CountryCode": "CN", "RegionInfo": "CH/A", "SoftwareBehaviors": "7"]) }
    static func encode(_ value: [String: Any]) -> Data {
        try! PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }
    static func parse(_ data: Data) -> [String: Any] {
        try! PropertyListSerialization.propertyList(from: data, options: [], format: nil) as! [String: Any]
    }
    static func reset(_ fault: Fault) {
        self.fault = fault; events = []; gestalt = initialGestalt
        activation = initialActivation; activationReads = 0; layoutKnown = true
    }
}

struct JapanRegionProfile: Equatable, Sendable {
    let productType: String
    let regulatoryModel: String
    static func verified(for product: String) -> Self? {
        product == "iPhone17,3" ? .init(productType: product, regulatoryModel: "A3286") : nil
    }
}
enum RealDeviceIdentity { static var productType: String { "iPhone17,3" } }
enum JapanRegionError: LocalizedError {
    case invalidMobileGestalt, activationVerificationFailed, mobileGestaltVerificationFailed
    case unsupportedProductType(String)
    case rollbackFailed(primary: String, rollback: String)
    var errorDescription: String? { String(describing: self) }
}
@MainActor enum JapanRegionCacheLayout {
    static func resolve(plist: [String: Any], build: String) throws -> Bool {
        guard Fixture.layoutKnown else { throw CocoaError(.fileReadCorruptFile) }
        return true
    }
}
@MainActor enum JapanRegionMutation {
    static let regionCodeKey = "code", regionInfoKey = "info", regulatoryModelKey = "model"
    static func validate(plist: [String: Any], profile: JapanRegionProfile, build: String) throws {
        _ = try JapanRegionCacheLayout.resolve(plist: plist, build: build)
    }
    static func applying(to plist: [String: Any], profile: JapanRegionProfile, build: String) throws -> [String: Any] {
        try validate(plist: plist, profile: profile, build: build)
        var result = plist
        result["CacheExtra"] = [regionCodeKey: "J", regionInfoKey: "J/A", regulatoryModelKey: profile.regulatoryModel]
        return result
    }
    static func isApplied(to plist: [String: Any], profile: JapanRegionProfile, build: String) -> Bool {
        guard let extra = plist["CacheExtra"] as? [String: String] else { return false }
        return extra[regionCodeKey] == "J" && extra[regionInfoKey] == "J/A" && extra[regulatoryModelKey] == profile.regulatoryModel
    }
}
@MainActor final class MobileGestaltAccess {
    static let instance = MobileGestaltAccess()
    static func shared() -> MobileGestaltAccess { instance }
    static func currentOSBuild() -> String { "simulated-future-build" }
    func readCacheData() throws -> Data { Fixture.events.append("readMG"); return Fixture.gestalt }
    func readCachePlist() throws -> NSDictionary {
        if Fixture.fault == .gestaltVerification && Fixture.events.last == "writeMG" {
            throw CocoaError(.fileReadCorruptFile)
        }
        return Fixture.parse(try readCacheData()) as NSDictionary
    }
    func saveCachePlist(_ plist: [String: Any]) throws {
        Fixture.events.append("writeMG"); Fixture.gestalt = Fixture.encode(plist)
        if Fixture.fault == .gestaltPartial || Fixture.fault == .rollback { throw CocoaError(.fileWriteUnknown) }
    }
    func restoreCacheData(_ data: Data) throws {
        Fixture.events.append("restoreMG")
        if Fixture.fault == .rollback { throw CocoaError(.fileWriteUnknown) }
        Fixture.gestalt = data
    }
}
@MainActor final class MobileActivationRegionAccess {
    static let instance = MobileActivationRegionAccess()
    static func shared() -> MobileActivationRegionAccess { instance }
    func readRegionData() throws -> Data {
        Fixture.activationReads += 1; Fixture.events.append("readMA")
        if Fixture.fault == .finalActivationVerification && Fixture.activationReads == 3 { return Fixture.initialActivation }
        return Fixture.activation
    }
    func validateRegionData(_ data: Data) throws { Fixture.events.append("validateMA") }
    func applyJapanRegion() throws {
        Fixture.events.append("writeMA")
        Fixture.activation = Fixture.encode(["CountryCode": "JP", "RegionInfo": "J/A", "SoftwareBehaviors": "25"])
        if Fixture.fault == .activationPartial { throw CocoaError(.fileWriteUnknown) }
    }
    func restoreRegionData(_ data: Data) throws { Fixture.events.append("restoreMA"); Fixture.activation = data }
    func regionDiagnostics() -> [String: Any] {
        let plist = Fixture.parse(Fixture.activation)
        return ["backingReadSucceeded": true, "mutationSchemaSupported": true,
                "backingCountryCode": plist["CountryCode"]!, "backingRegionInfo": plist["RegionInfo"]!,
                "backingSoftwareBehaviors": plist["SoftwareBehaviors"]!]
    }
}
@MainActor enum TransactionBackupStore {
    static func begin() throws -> RegionTransactionBackup { .init() }
}
@MainActor struct RegionTransactionBackup {
    func saveMobileGestalt(_ data: Data) throws {
        assert(data == Fixture.initialGestalt); Fixture.events.append("backupMG")
    }
    func saveMobileActivation(_ data: Data) throws {
        assert(data == Fixture.initialActivation); Fixture.events.append("backupMA")
        if Fixture.fault == .backup { throw CocoaError(.fileWriteUnknown) }
    }
}
