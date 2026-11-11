// SPDX-License-Identifier: GPL-3.0-only
// Native API doubles for the actual service, using the real planner and journal.
import Foundation
#if !canImport(Combine)
protocol ObservableObject {}
@propertyWrapper struct Published<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
#endif

enum Fixture {
    static var writable = true
    static var denyActivation = true
    static var events: [String] = []
    static var runtime: [String: Any] = [:]
    static var runtimeError = false
    static var chosen: [String: Any] = [:]
    static var chosenError = false
    static var activationDiagnostics: [String: Any] = [
        "mutationSchemaSupported": false, "mutationSchemaError": "Identity / binary semantics unverified",
        "resolverSucceeded": false, "resolverStatus": 55,
        "discovery": ["source": "unresolved", "identityQuery": ["status": "iteration-failed", "queryErrorPOSIXCode": 1]],
        "backingStage": "systemgroup-discovery", "backingPathState": ["state": "not-observed"],
        "backingReadSucceeded": NSNull(), "backingSchemaValid": NSNull(), "backingWriteAccessAvailable": NSNull(),
        "binarySupported": false, "effectiveCallSucceeded": true, "effectiveStage": "complete",
        "effectiveCountryCode": "JP", "effectiveRegionInfo": "J/A", "effectiveSoftwareBehaviors": "25"
    ]
    static let baseline: Data = try! PropertyListSerialization.data(fromPropertyList: [
        "CacheExtra": [JapanRegionMutation.regionCodeKey: "CH", JapanRegionMutation.regionInfoKey: "CH/A",
                       JapanRegionMutation.regulatoryModelKey: "A9999", "hardware": "real"],
        "CacheVersion": "fixture-build", "CacheUUID": "00000000-0000-4000-8000-000000000001",
        "CacheData": Data(repeating: 0, count: 72)
    ], format: .binary, options: 0)
    static var gestalt = baseline
}
final class MobileGestaltAccess {
    static let instance = MobileGestaltAccess()
    static func shared() -> MobileGestaltAccess { instance }
    static func currentOSBuild() -> String { "fixture-build" }
    func readCacheData() throws -> Data { Fixture.events.append("readMG"); return Fixture.gestalt }
    func cacheWriteAccessStatus() -> [String: Any] { ["writable": Fixture.writable, "error": "simulated access"] }
    func runtimeAnswers(for questions: [String]) throws -> [String: Any] {
        Fixture.events.append("runtimeMG")
        if Fixture.runtimeError { throw RegionOperationError("simulated runtime failure") }
        return Dictionary(uniqueKeysWithValues: questions.map { ($0, Fixture.runtime[$0] ?? NSNull()) })
    }
    func readCachePlist() throws -> Any { try RegionPlist.parse(readCacheData()).root }
    func replaceCacheData(_ expected: Data, with replacement: Data) throws {
        guard Fixture.writable && Fixture.gestalt == expected else { throw RegionOperationError("stale or denied") }
        Fixture.events.append("writeMG"); Fixture.gestalt = replacement
    }
}
final class DeviceTreeAccess {
    static let instance = DeviceTreeAccess()
    static func shared() -> DeviceTreeAccess { instance }
    func chosenProperties(for names: [String]) throws -> [String: Any] {
        Fixture.events.append("readDT")
        if Fixture.chosenError { throw RegionOperationError("simulated DeviceTree failure") }
        return Dictionary(uniqueKeysWithValues: names.map { ($0, Fixture.chosen[$0] ?? NSNull()) })
    }
    func properties(at path: String) throws -> [String: Any] { [:] }
}
final class MobileActivationRegionAccess {
    static let instance = MobileActivationRegionAccess()
    static func shared() -> MobileActivationRegionAccess { instance }
    func regionDiagnostics() -> [String: Any] {
        Fixture.events.append("diagnoseMA")
        return Fixture.activationDiagnostics
    }
    func readRegionData() throws -> Data {
        Fixture.events.append("readMA")
        throw RegionOperationError("No verified MobileActivation identity")
    }
    func validateRegionData(_ data: Data) throws { throw RegionOperationError("unverified") }
    func replaceRegionData(_ expected: Data, with replacement: Data) throws {
        Fixture.events.append("writeMA")
        throw RegionOperationError("unverified")
    }
}
