// SPDX-License-Identifier: GPL-3.0-only
// Synthetic plist files through the production C writer and Swift coordinator.
import Foundation

func encode(_ root: [String: Any]) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
}
func expect(_ condition: Bool) { precondition(condition) }
@discardableResult
func refuses(_ message: String, _ operation: () throws -> Void) -> String {
    do { try operation(); fatalError("Expected refusal: " + message) }
    catch { return error.localizedDescription }
}
final class DiskAccess: RegionFileAccess {
    let url: URL
    var writes = 0
    var failAfterWrite = false
    init(_ url: URL) { self.url = url }
    func read(_ file: RegionFile) throws -> Data {
        precondition(file == .mobileGestalt)
        return try Data(contentsOf: url)
    }
    func replace(_ file: RegionFile, expected: Data, replacement: Data) throws {
        precondition(file == .mobileGestalt)
        var outcome = LocusFileUnchanged
        let rc = expected.withUnsafeBytes { before in replacement.withUnsafeBytes { after in
            LocusReplaceFile(url.path, before.baseAddress, before.count, after.baseAddress, after.count, &outcome)
        }}
        guard rc == 0 else { throw RegionOperationError("C writer failed: \(outcome.rawValue)") }
        writes += 1
        if failAfterWrite { failAfterWrite = false; throw RegionOperationError("injected error after disk write") }
    }
}
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LocusCacheWrites-" + UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: directory) }
var data = Data(repeating: 0, count: 6480)
for slot in [383, 506, 694] { data[5760 + slot] = 1 }
data[383 * 8] = 1; data[694 * 8] = 1; data[32] = 123
let original = try encode(["CacheUUID": RegionCacheMapping.cacheUUID, "CacheVersion": "24B119", "CacheData": data,
    "CacheExtra": ["re6Zb+zwFKJNlkQTUeT+/w": "synthetic-device", "unrelated": "keep"]])
let io = DiskAccess(directory.appendingPathComponent("cache.plist"))
try original.write(to: io.url)
let store = RegionTransactionCoordinator(root: directory.appendingPathComponent("backups"), access: io,
    productType: "iPhone18,3", build: "24B119", deviceID: "test-device")
func plan(_ module: RegionModule) throws -> RegionWritePlan {
    try RegionModuleMutation.plan(module: module, raw: io.read(.mobileGestalt), productType: "iPhone18,3", build: "24B119")
}
let first = try plan(.greenTea)
let prepared = try store.prepare(module: .greenTea, plans: [first])!
expect(try io.writes == 0 && io.read(.mobileGestalt) == original)
let backup = store.root.appendingPathComponent(prepared.id).appendingPathComponent("mobileGestalt.before.plist")
expect(try Data(contentsOf: backup) == original)
expect(!(try store.originalAvailable(for: .greenTea))) // Preview does not claim a first edit.
try store.cancelPrepared(prepared.id)
expect(try io.writes == 0 && store.pending().isEmpty)

for module in [RegionModule.greenTea, .notGreenTea, .wapi] {
    _ = try store.apply(module: module, plans: [plan(module)])
    expect(try store.originalAvailable(for: module))
}
expect(io.writes == 3)
_ = try store.apply(module: .wapi, plans: [plan(.wapi)])
expect(io.writes == 3) // Idempotent Apply does not rewrite the file.
let applied = try io.read(.mobileGestalt)
let appliedData = try RegionPlist.parse(applied).root["CacheData"] as! Data
expect(Set(data.indices.filter { data[$0] != appliedData[$0] }) == [3064, 4048, 5552])
expect(try Data(contentsOf: backup) == original)

// Restore one option without reverting later system or other module changes.
var external = try RegionPlist.parse(applied).root
var extras = external["CacheExtra"] as! [String: Any]
extras["unrelated"] = "new-system-value"; external["CacheExtra"] = extras
var unrelatedData = appliedData; unrelatedData[32] = 99; external["CacheData"] = unrelatedData
try encode(external).write(to: io.url)
_ = try store.restore(module: .greenTea)
let restored = try RegionPlist.parse(io.read(.mobileGestalt)).root
let restoredData = restored["CacheData"] as! Data
expect(restoredData[3064] == 1 && restoredData[4048] == 1 && restoredData[5552] == 0 && restoredData[32] == 99)
expect((restored["CacheExtra"] as! [String: Any])["unrelated"] as? String == "new-system-value")

// The same model/build on another device cannot use this backup.
let otherDevice = RegionTransactionCoordinator(root: store.root, access: io, productType: "iPhone18,3", build: "24B119", deviceID: "another-device")
refuses("device identity") { _ = try otherDevice.restore(module: .wapi) }

// Approval applies to these exact bytes, even if the change is unrelated.
let stalePreview = try store.prepare(module: .greenTea, plans: [plan(.greenTea)])!
var drift = restored; drift["system-update"] = true
let driftBytes = try encode(drift); try driftBytes.write(to: io.url)
let writesBeforeDrift = io.writes
refuses("external change before Apply") { _ = try store.commitPrepared(stalePreview.id) }
expect(try io.writes == writesBeforeDrift && io.read(.mobileGestalt) == driftBytes)
expect(try store.pending().isEmpty)

// A write really reaches the C writer; coordinator recovery also uses it.
io.failAfterWrite = true
let failure = refuses("write failure") { _ = try store.apply(module: .greenTea, plans: [plan(.greenTea)]) }
expect(failure.contains("Rollback verified"))
expect(try io.writes == writesBeforeDrift + 2 && io.read(.mobileGestalt) == driftBytes)
expect(try store.pending().isEmpty)

// A corrupt backup prevents confirmation. The prepared journal is unwritten.
let corrupt = try store.prepare(module: .greenTea, plans: [plan(.greenTea)])!
try Data([1]).write(to: store.root.appendingPathComponent(corrupt.id).appendingPathComponent("mobileGestalt.before.plist"))
let writesBeforeCorruption = io.writes
refuses("backup corruption") { _ = try store.commitPrepared(corrupt.id) }
expect(io.writes == writesBeforeCorruption)
_ = try store.recoverPending()

// Restore repeats layout and target validity checks, including new overrides.
for (key, value) in [("CacheVersion", "24B120" as Any), ("CacheUUID", "00000000-0000-4000-8000-000000000001" as Any)] {
    var incompatible = drift; incompatible[key] = value; try encode(incompatible).write(to: io.url)
    refuses("incompatible restore") { _ = try store.restore(module: .wapi) }
}
var overridden = drift, overrideExtra = drift["CacheExtra"] as! [String: Any]
overrideExtra["wapi"] = false; overridden["CacheExtra"] = overrideExtra
try encode(overridden).write(to: io.url)
refuses("restore override") { _ = try store.restore(module: .wapi) }
expect(io.writes == writesBeforeCorruption)
var invalid = drift, invalidData = drift["CacheData"] as! Data
invalidData[5760 + 694] = 0; invalid["CacheData"] = invalidData
try encode(invalid).write(to: io.url)
refuses("restore invalid validity") { _ = try store.restore(module: .wapi) }
expect(io.writes == writesBeforeCorruption)
print("PASS: synthetic plist disk writes, preview/backup/cancel, three one-byte edits, readback, scoped restore, external drift, device/layout refusal and real rollback")
