// SPDX-License-Identifier: GPL-3.0-only
// Persisted v1 dictionaries, including obsolete module/file names. No native APIs.
import Foundation

var checks = 0
func expect(_ value: Bool) { checks += 1; precondition(value) }
@discardableResult func refuses(_ operation: () throws -> Void) -> String {
    do { try operation(); fatalError("Expected refusal") }
    catch { checks += 1; return error.localizedDescription }
}
func encode(_ value: Any) -> Data {
    try! PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
}
final class OnlyGestalt: RegionFileAccess {
    var data: Data
    var reads = 0, writes = 0
    init(_ data: Data) { self.data = data }
    func read(_ file: RegionFile) throws -> Data { reads += 1; return data }
    func replace(_ file: RegionFile, expected: Data, replacement: Data) throws {
        expect(data == expected); writes += 1; data = replacement
    }
}
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("LocusLegacy-" + UUID().uuidString)
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let code = JapanRegionMutation.regionCodeKey, info = JapanRegionMutation.regionInfoKey, model = JapanRegionMutation.regulatoryModelKey
let ai = "A62OafQ85EJAiiqKn4agtg"
var bytes = Data(repeating: 0, count: 6480)
for slot in [383,506,694] { bytes[5760 + slot] = 1 }
bytes[3064] = 1; bytes[5552] = 1
let baseline = encode(["CacheExtra": [code: "CH", info: "CH/A", model: "A9999", ai: false],
    "CacheUUID": RegionCacheMapping.cacheUUID, "CacheVersion": "24B119", "CacheData": bytes])
let full = try RegionModuleMutation.plan(module: .fullJapan, raw: baseline, productType: "iPhone18,3", build: "24B119")
let identity = try RegionModuleMutation.plan(module: .regionCode, raw: baseline, productType: "iPhone18,3", build: "24B119")
func scope(_ plan: RegionWritePlan) -> [String: Any] {
    try! PropertyListSerialization.propertyList(from: PropertyListEncoder().encode(plan.scope), format: nil) as! [String: Any]
}
func entry(_ file: String, _ before: Data, _ after: Data, _ scope: [String: Any]) -> [String: Any] {
    ["file": file, "beforeSHA256": RegionBackupDigest.sha256(before), "afterSHA256": RegionBackupDigest.sha256(after), "scope": scope]
}
let activationBefore = encode(["CountryCode": "CN", "RegionInfo": "CH/A", "SoftwareBehaviors": "321"])
let activationAfter = encode(["CountryCode": "JP", "RegionInfo": "J/A", "SoftwareBehaviors": "25"])
let activationEntry = entry("mobileActivation", activationBefore, activationAfter,
    ["rootKeys": ["CountryCode", "RegionInfo", "SoftwareBehaviors"], "extraKeys": [], "byteOffsets": []])
let mgEntry = entry("mobileGestalt", baseline, full.after, scope(full))
var aiRoot = try RegionPlist.parse(baseline).root, aiExtra = (try RegionPlist.parse(baseline).root["CacheExtra"]) as! [String:Any]
aiExtra[ai] = true; aiRoot["CacheExtra"] = aiExtra
let aiAfter = encode(aiRoot)
let aiEntry = entry("mobileGestalt", baseline, aiAfter, ["extraKeys": [ai], "rootKeys": [], "byteOffsets": []])
func seed(_ root: URL, module: String, entries: [[String: Any]], phase: String, version: Int? = nil) throws -> (id: String, path: URL) {
    let id = UUID().uuidString
    let target = root.appendingPathComponent(id)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    var journal: [String:Any] = ["id": id, "module": module, "operation": "apply", "productType": "iPhone18,3",
        "build": "24B119", "created": Date(timeIntervalSince1970: 1), "entries": entries, "phase": phase]
    if let version { journal["schemaVersion"] = version }
    let path = target.appendingPathComponent("journal.plist")
    try encode(journal).write(to: path)
    for item in entries {
        let label = item["file"] as! String
        let before = label == "mobileActivation" ? activationBefore : baseline
        let after = label == "mobileActivation" ? activationAfter : module == "intelligence" ? aiAfter : module == "regionCode" ? identity.after : full.after
        try before.write(to: target.appendingPathComponent("\(label).before.plist"))
        try after.write(to: target.appendingPathComponent("\(label).after.plist"))
    }
    let originals = root.appendingPathComponent("originals")
    try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
    try encode(["transaction": id]).write(to: originals.appendingPathComponent("\(module).plist"))
    return (id, path)
}
func snapshot(_ url: URL) throws -> [String: Data] {
    let paths = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])!
    var files: [String:Data] = [:]
    for case let file as URL in paths where (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
        files[file.path] = try Data(contentsOf: file)
    }
    return files
}
func store(_ root: URL, _ io: OnlyGestalt) -> RegionTransactionCoordinator {
    .init(root: root, access: io, productType: "iPhone18,3", build: "24B119")
}
for (module, entries) in [("fullJapan", [mgEntry, activationEntry]), ("mobileActivation", [activationEntry]), ("intelligence", [aiEntry])] {
    for phase in RegionJournal.Phase.allTestValues {
        let root = temporary.appendingPathComponent(UUID().uuidString), io = OnlyGestalt(baseline)
        let seeded = try seed(root, module: module, entries: entries, phase: phase.rawValue)
        let transaction = store(root, io), saved = try snapshot(root)
        let decoded = try PropertyListDecoder().decode(RegionJournal.self, from: Data(contentsOf: seeded.path))
        expect(decoded.schemaVersion == nil && decoded.moduleName == module && !decoded.permitsCurrentRecovery)
        expect(!(try transaction.originalAvailable(for: .fullJapan)))
        let summary = try transaction.legacyBackupDetail()!
        expect(summary.contains(module) && !summary.contains("backup unavailable"))
        expect(try transaction.pending().count == (phase.unfinished ? 1 : 0))
        let restoreError = refuses { _ = try transaction.restore(module: .fullJapan) }
        expect(restoreError.contains("No compatible original backup"))
        if phase.unfinished {
            expect(refuses { _ = try transaction.recoverPending() }.contains("Legacy or unsupported"))
            refuses { _ = try transaction.prepare(module: .fullJapan, plans: [full]) }
            refuses { _ = try transaction.prepare(module: .regionCode, plans: [identity]) }
            refuses { _ = try transaction.commitPrepared(seeded.id) }
            try transaction.legacyBackupDetail().map { expect($0.contains("No automatic restore")) }
            expect(try snapshot(root) == saved)
            expect(io.writes == 0 && io.reads == 0)
        } else {
            _ = try transaction.recoverPending()
            expect(try snapshot(root) == saved && io.reads == 0 && io.writes == 0)
            _ = try transaction.apply(module: .fullJapan, plans: [full])
            expect(io.writes == 1)
            let pointer = root.appendingPathComponent("originals/fullJapan-v2.plist")
            expect(FileManager.default.fileExists(atPath: pointer.path))
            let record = try PropertyListDecoder().decode([String:String].self, from: Data(contentsOf: pointer))
            let journal = try PropertyListDecoder().decode(RegionJournal.self,
                from: Data(contentsOf: root.appendingPathComponent(record["transaction"]!).appendingPathComponent("journal.plist")))
            expect(journal.schemaVersion == 2 && journal.permitsCurrentRecovery && journal.entries.count == 1)
            for (path, value) in saved { expect(try Data(contentsOf: URL(fileURLWithPath: path)) == value) }
            _ = try transaction.restore(module: .fullJapan)
            expect(io.data == baseline)
        }
    }
}
// Safe v1 individual originals retain their names and exact Restore semantics.
for module in [RegionModule.regionCode, .greenTea] {
    let root = temporary.appendingPathComponent(UUID().uuidString)
    let plan = try RegionModuleMutation.plan(module: module, raw: baseline, productType: "iPhone18,3", build: "24B119")
    var savedScope = scope(plan)
    if module == .greenTea { savedScope["byteOffsets"] = Array(3064..<3072) + [5760 + 383] }
    let seeded = try seed(root, module: module.rawValue,
        entries: [entry("mobileGestalt", baseline, plan.after, savedScope)], phase: "committed")
    try plan.after.write(to: seeded.path.deletingLastPathComponent().appendingPathComponent("mobileGestalt.after.plist"))
    let io = OnlyGestalt(plan.after), transaction = store(root, io)
    let original = try Data(contentsOf: root.appendingPathComponent("originals/\(module.rawValue).plist"))
    expect(try transaction.originalAvailable(for: module))
    _ = try transaction.restore(module: module)
    expect(io.data == baseline && io.writes == 1)
    expect(try Data(contentsOf: root.appendingPathComponent("originals/\(module.rawValue).plist")) == original)
}
// Missing bytes, corrupt legacy metadata and ambiguous v1 Full Japan never become a v2 baseline.
let badRoot = temporary.appendingPathComponent("bad-backup"), badIO = OnlyGestalt(baseline)
let old = try seed(badRoot, module: "fullJapan", entries: [mgEntry,activationEntry], phase: "committed")
try FileManager.default.removeItem(at: old.path.deletingLastPathComponent().appendingPathComponent("mobileActivation.before.plist"))
expect(try store(badRoot, badIO).legacyBackupDetail()!.contains("backup unavailable"))
let originals = badRoot.appendingPathComponent("originals")
try Data(contentsOf: originals.appendingPathComponent("fullJapan.plist")).write(to: originals.appendingPathComponent("fullJapan-v2.plist"))
refuses { _ = try store(badRoot, badIO).originalAvailable(for: .fullJapan) }
refuses { _ = try store(badRoot, badIO).apply(module: .fullJapan, plans: [full]) }
expect(badIO.writes == 0)
for version in [nil, 2, 3] as [Int?] {
    let root = temporary.appendingPathComponent(UUID().uuidString), io = OnlyGestalt(baseline)
    let module = version == 2 ? "intelligence" : "fullJapan"
    let entries = version == 2 ? [aiEntry] : [mgEntry]
    let old = try seed(root, module: module, entries: entries, phase: "writing", version: version)
    let before = try Data(contentsOf: old.path)
    refuses { _ = try store(root, io).recoverPending() }
    expect(try Data(contentsOf: old.path) == before && io.writes == 0)
}
// A legacy journal arriving after Review blocks confirmation and the entire
// recovery batch without even closing the supported prepared transaction.
let mixedRoot = temporary.appendingPathComponent("mixed"), mixedIO = OnlyGestalt(baseline)
let mixedStore = store(mixedRoot, mixedIO)
let prepared = try mixedStore.prepare(module: .fullJapan, plans: [full])!
_ = try seed(mixedRoot, module: "mobileActivation", entries: [activationEntry], phase: "writing")
let mixedSnapshot = try snapshot(mixedRoot), mixedReads = mixedIO.reads
refuses { _ = try mixedStore.commitPrepared(prepared.id) }
refuses { _ = try mixedStore.recoverPending() }
expect(try snapshot(mixedRoot) == mixedSnapshot && mixedIO.writes == 0 && mixedIO.reads == mixedReads)
// Renaming an obsolete plan's module never authorizes its old write scope.
let spoofRoot = temporary.appendingPathComponent("spoof"), spoofIO = OnlyGestalt(baseline)
let spoof = try seed(spoofRoot, module: "regionCode", entries: [aiEntry], phase: "writing", version: 2)
try aiAfter.write(to: spoof.path.deletingLastPathComponent().appendingPathComponent("mobileGestalt.after.plist"))
refuses { _ = try store(spoofRoot, spoofIO).recoverPending() }
expect(spoofIO.writes == 0)
let malformedRoot = temporary.appendingPathComponent("malformed"), malformedIO = OnlyGestalt(baseline)
let malformed = try seed(malformedRoot, module: "fullJapan", entries: [mgEntry,activationEntry], phase: "writing")
try Data([9]).write(to: malformed.path)
refuses { _ = try store(malformedRoot, malformedIO).pending() }
refuses { _ = try store(malformedRoot, malformedIO).prepare(module: .fullJapan, plans: [full]) }
expect(try Data(contentsOf: malformed.path) == Data([9]) && malformedIO.writes == 0)
// No-op with already matching values creates neither a v2 pointer nor a transaction.
let appliedRoot = temporary.appendingPathComponent("already-applied"), appliedIO = OnlyGestalt(full.after)
_ = try seed(appliedRoot, module: "fullJapan", entries: [mgEntry,activationEntry], phase: "committed")
let preserved = try snapshot(appliedRoot)
let noOp = try RegionModuleMutation.plan(module: .fullJapan, raw: full.after, productType: "iPhone18,3", build: "24B119")
_ = try store(appliedRoot, appliedIO).apply(module: .fullJapan, plans: [noOp])
expect(try snapshot(appliedRoot) == preserved && appliedIO.writes == 0)
print("PASS: \(checks) legacy/new journal, immutable original, no obsolete access, fail-closed recovery and versioned Full Japan checks")

extension RegionJournal.Phase {
    static var allTestValues: [Self] { [.preparing,.prepared,.writing,.committed,.rollingBack,.rolledBack,.recoveryRequired] }
}
