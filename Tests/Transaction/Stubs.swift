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
    static var events: [String] = []
    static var runtime: [String: Any] = [:]
    static var queries: [String] = []
    static var runtimeError = false
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
        Fixture.events.append("runtimeMG"); Fixture.queries += questions
        if Fixture.runtimeError { throw RegionOperationError("simulated runtime failure") }
        return Dictionary(uniqueKeysWithValues: questions.map { ($0, Fixture.runtime[$0] ?? NSNull()) })
    }
    func readCachePlist() throws -> Any { try RegionPlist.parse(readCacheData()).root }
    func replaceCacheData(_ expected: Data, with replacement: Data) throws {
        guard Fixture.writable && Fixture.gestalt == expected else { throw RegionOperationError("stale or denied") }
        Fixture.events.append("writeMG"); Fixture.gestalt = replacement
    }
}
