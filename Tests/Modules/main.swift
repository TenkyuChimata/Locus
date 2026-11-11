// SPDX-License-Identifier: GPL-3.0-only
// Synthetic cache data only; no device access or Apple binary fixtures.
import Foundation

var checks = 0
func expect(_ condition: Bool, _ message: String = "") {
    checks += 1
    precondition(condition, message)
}
func rejects(_ body: () throws -> Void) {
    do { try body(); fatalError("Expected rejection") } catch { checks += 1 }
}
func encode(_ root: [String: Any], format: PropertyListSerialization.PropertyListFormat = .binary) -> Data {
    try! PropertyListSerialization.data(fromPropertyList: root, format: format, options: 0)
}
func root(_ bytes: Data) -> [String: Any] { try! RegionPlist.parse(bytes).root }
func extra(_ bytes: Data) -> [String: Any] { root(bytes)["CacheExtra"] as! [String: Any] }
let uuid = "48CB1FAC-755B-435F-9A01-A20E5D810EA9"
let build = "24B119"
let profile = "iPhone18,3"
let code = JapanRegionMutation.regionCodeKey, info = RegionModuleMutation.regionInfoKeys[0]
let modernInfo = RegionModuleMutation.regionInfoKeys[1]
let ai = "A62OafQ85EJAiiqKn4agtg" // Untouched non-target sentinel.
let model = JapanRegionMutation.regulatoryModelKey
var baseline: [String: Any] = ["CacheExtra": [code: "CH", info: "CH/A", model: "A9999", "hardware": "preserve", "number": 512, ai: false] as [String: Any],
    "CacheUUID": uuid, "CacheVersion": build, "CacheData": Data(repeating: 0, count: 6480), "other": [1, 2, 3]]
var baselineData = baseline["CacheData"] as! Data
for slot in [383, 506, 694] { baselineData[5760 + slot] = 1 }
baselineData[383 * 8] = 1; baselineData[694 * 8] = 1
baseline["CacheData"] = baselineData
let baselineBytes = encode(baseline)

for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
    for module in [RegionModule.regionCode, .regionInfo, .regulatoryModel] {
        let original = encode(baseline, format: format)
        let plan = try RegionModuleMutation.plan(module: module, raw: original, productType: profile)
        try plan.scope.validate(before: original, after: plan.after)
        let restored = try plan.scope.restoring(original: original, applied: plan.after, current: plan.after)
        expect(restored == original, "Exact source bytes restored")
        expect(try RegionPlist.parse(plan.after).format == format)
        expect(RegionPlist.equal(root(original)["CacheData"], root(plan.after)["CacheData"]))
        expect(extra(plan.after)["hardware"] as? String == "preserve")
    }
}
for key in [info, modernInfo] {
    var fixture = baseline
    fixture["CacheExtra"] = [code: "CH", key: "CH/A"]
    let plan = try RegionModuleMutation.plan(module: .regionInfo, raw: encode(fixture), productType: "unknown")
    expect(extra(plan.after)[key] as? String == "J/A")
    expect(extra(plan.after)[code] as? String == "CH")
    expect(extra(plan.after)[key == info ? modernInfo : info] == nil)
}
for suffixes in [[:], [info: "CH/A", modernInfo: "CH/A"], [info: "CH/A", modernInfo: "J/A"]] {
    var fixture = baseline; fixture["CacheExtra"] = suffixes
    rejects { _ = try RegionModuleMutation.plan(module: .regionInfo, raw: encode(fixture), productType: profile) }
}
for malformed in [0, true, Data([1])] as [Any] {
    var fixture = baseline; fixture["CacheExtra"] = [code: malformed]
    rejects { _ = try RegionModuleMutation.plan(module: .regionCode, raw: encode(fixture), productType: profile) }
}
expect(JapanRegionProfile.verified(for: profile)?.regulatoryModel == "A3519")
// Inspect an Optional<String> so a nil check does not require the profile's
// actor-isolated Equatable conformance in this top-level test context.
expect(JapanRegionProfile.verified(for: "unknown")?.productType == nil)
rejects { _ = try RegionModuleMutation.plan(module: .regulatoryModel, raw: baselineBytes, productType: "unknown") }
var identityOnly = baseline
identityOnly.removeValue(forKey: "CacheData"); identityOnly.removeValue(forKey: "CacheUUID"); identityOnly.removeValue(forKey: "CacheVersion")
_ = try RegionModuleMutation.plan(module: .regionCode, raw: encode(identityOnly), productType: "unknown")
checks += 1
func assess(_ fixture: [String: Any] = baseline, writable: Bool = true) -> [CacheMappingAssessment] {
    RegionCacheMapping.assess(plist: fixture, build: build, writeAccess: writable, productType: profile)
}
expect(assess().allSatisfy(\.permitsMutation))
expect(assess(writable: false).allSatisfy { $0.status == .readOnly && !$0.permitsMutation })
for (key, value) in [("CacheUUID", "00000000-0000-4000-8000-000000000001"), ("CacheVersion", "stale")] {
    var changed = baseline; changed[key] = value
    expect(assess(changed).allSatisfy { !$0.permitsMutation })
}
for (product, version) in [("iPhone18,3", "24B120"), ("iPhone18,2", build)] {
    expect(RegionCacheMapping.assess(plist: baseline, build: version, writeAccess: true, productType: product).allSatisfy { !$0.permitsMutation })
}
for size in [0, 6479, 6489] {
    var changed = baseline; changed["CacheData"] = Data(repeating: 0, count: size)
    expect(assess(changed).allSatisfy { !$0.permitsMutation })
}
for offset in [383 * 8, 383 * 8 + 1, 5760 + 383] {
    var changed = baseline, data = baselineData
    data[offset] = 2; changed["CacheData"] = data
    expect(!assess(changed)[0].permitsMutation)
    rejects { _ = try RegionModuleMutation.plan(module: .greenTea, raw: encode(changed), productType: profile, build: build) }
}
var invalid = baseline, invalidData = baselineData
invalidData[5760 + 383] = 0; invalid["CacheData"] = invalidData
expect(!assess(invalid)[0].permitsMutation)
for alias in [RegionCacheQuestion.wapi.key, "wapi"] {
    var changed = baseline; changed["CacheExtra"] = [alias: true]
    expect(!assess(changed)[2].permitsMutation)
    expect(assess(changed)[0].permitsMutation, "Each cache option remains independent")
}
for (module, slot) in zip([RegionModule.greenTea, .notGreenTea, .wapi], [383, 506, 694]) {
    var fixture = baseline, data = baselineData
    data[56] = 99; fixture["CacheData"] = data
    let raw = encode(fixture)
    let plan = try RegionModuleMutation.plan(module: module, raw: raw, productType: profile, build: build)
    expect(plan.scope.byteOffsets == [slot * 8])
    let afterData = root(plan.after)["CacheData"] as! Data
    expect(Set(data.indices.filter { data[$0] != afterData[$0] }) == [slot * 8])
    expect(try plan.scope.restoring(original: raw, applied: plan.after, current: plan.after) == raw)
    expect((root(plan.after)["CacheData"] as! Data)[56] == 99)
    var unrelated = root(plan.after), bytes = unrelated["CacheData"] as! Data
    bytes[40] ^= 1; unrelated["CacheData"] = bytes
    rejects { try plan.scope.validate(before: raw, after: encode(unrelated)) }
}

final class MemoryAccess: RegionFileAccess {
    var data: [RegionFile: Data]
    var events: [RegionFile] = []
    var callback: ((RegionFile, Data, Data, MemoryAccess) throws -> Void)?
    var readFault: ((RegionFile, MemoryAccess) throws -> Void)?
    init(_ initial: [RegionFile: Data]) { data = initial }
    func read(_ file: RegionFile) throws -> Data {
        try readFault?(file, self)
        return data[file]!
    }
    func replace(_ file: RegionFile, expected: Data, replacement: Data) throws {
        guard data[file] == expected else { throw RegionOperationError("CAS mismatch") }
        events.append(file)
        if let callback { try callback(file, expected, replacement, self) }
        else { data[file] = replacement }
    }
}
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("LocusModuleTests-" + UUID().uuidString)
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
func store(_ access: MemoryAccess, _ name: String) -> RegionTransactionCoordinator {
    .init(root: temporary.appendingPathComponent(name), access: access, productType: profile, build: build)
}
func plan(_ module: RegionModule, _ bytes: Data) throws -> RegionWritePlan {
    try RegionModuleMutation.plan(module: module, raw: bytes, productType: profile, build: build)
}
let access = MemoryAccess([.mobileGestalt: baselineBytes])
let coordinator = store(access, "independence")
for module in [RegionModule.regionCode, .regionInfo, .regulatoryModel, .greenTea, .notGreenTea, .wapi] {
    _ = try coordinator.apply(module: module, plans: [plan(module, access.data[.mobileGestalt]!)])
}
let originalPointer = coordinator.root.appendingPathComponent("originals/regionCode.plist")
let pointer = try Data(contentsOf: originalPointer)
let writes = access.events.count
_ = try coordinator.apply(module: .regionCode, plans: [plan(.regionCode, access.data[.mobileGestalt]!)])
expect(access.events.count == writes)
expect(try Data(contentsOf: originalPointer) == pointer)
_ = try coordinator.restore(module: .regionCode)
expect(extra(access.data[.mobileGestalt]!)[code] as? String == "CH")
expect(extra(access.data[.mobileGestalt]!)[info] as? String == "J/A")
expect((extra(access.data[.mobileGestalt]!)[ai] as? NSNumber)?.boolValue == false)
for module in [RegionModule.regulatoryModel, .greenTea, .notGreenTea, .wapi] { _ = try coordinator.restore(module: module) }
_ = try coordinator.restore(module: .regionInfo)
expect(RegionPlist.equal(root(access.data[.mobileGestalt]!), baseline))
_ = try coordinator.apply(module: .regionCode, plans: [plan(.regionCode, access.data[.mobileGestalt]!)])
expect(try Data(contentsOf: originalPointer) == pointer)
expect(try coordinator.pending().isEmpty)

// A currently hand-edited J value is not made into an invented original.
let manual = try plan(.regionCode, baselineBytes).after
let handEdited = MemoryAccess([.mobileGestalt: manual])
let manualStore = store(handEdited, "manual")
_ = try manualStore.apply(module: .regionCode, plans: [plan(.regionCode, manual)])
expect(!(try manualStore.originalAvailable(for: .regionCode)))

let mgPlan = try plan(.regionCode, baselineBytes)
let fullMG = try plan(.fullJapan, baselineBytes)
expect(fullMG.file == .mobileGestalt && fullMG.comparison.count == 6)
expect(fullMG.scope.extraKeys == [code, info, model])
expect(Set(fullMG.scope.byteOffsets) == [3064, 4048, 5552])
expect(JapanRegionMutation.isApplied(to: root(fullMG.after), profile: JapanRegionProfile.verified(for: profile)!, build: build))
expect((extra(fullMG.after)[ai] as? NSNumber)?.boolValue == false)
expect(try plan(.fullJapan, fullMG.after).after == fullMG.after)
let fullManual = MemoryAccess([.mobileGestalt: fullMG.after])
let fullManualStore = store(fullManual, "already-full")
_ = try fullManualStore.apply(module: .fullJapan, plans: [plan(.fullJapan, fullMG.after)])
expect(try fullManual.events.isEmpty && !fullManualStore.originalAvailable(for: .fullJapan))
// Every non-target value survives, including all non-target cache bytes.
try fullMG.scope.validate(before: baselineBytes, after: fullMG.after)
let fullData = root(fullMG.after)["CacheData"] as! Data
expect(baselineData.indices.allSatisfy { [3064,4048,5552].contains($0) || baselineData[$0] == fullData[$0] })
for module in RegionModule.allCases where module != .fullJapan {
    let onlyOne = try plan(module, baselineBytes)
    let combinedScope = RegionWritePlan(file: .mobileGestalt, before: baselineBytes, after: onlyOne.after, scope: fullMG.scope)
    let memory = MemoryAccess([.mobileGestalt: baselineBytes])
    rejects { _ = try store(memory, "partial-" + module.rawValue).apply(module: .fullJapan, plans: [combinedScope]) }
    expect(memory.events.isEmpty)
}
for key in [code, info, model] {
    var broken = baseline, fields = extra(baselineBytes); fields[key] = 1; broken["CacheExtra"] = fields
    rejects { _ = try plan(.fullJapan, encode(broken)) }
}
for slot in [383,506,694] {
    for offset in [slot * 8, slot * 8 + 1, 5760 + slot] {
        var broken = baseline, bytes = baselineData; bytes[offset] = 2; broken["CacheData"] = bytes
        rejects { _ = try plan(.fullJapan, encode(broken)) }
    }
    var broken = baseline, bytes = baselineData; bytes[5760 + slot] = 0; broken["CacheData"] = bytes
    rejects { _ = try plan(.fullJapan, encode(broken)) }
}
for (key, value) in [("CacheVersion", "24B120"), ("CacheUUID", UUID().uuidString)] {
    var broken = baseline; broken[key] = value
    rejects { _ = try plan(.fullJapan, encode(broken)) }
}
for (product, version) in [("unknown", build), (profile, "24B120")] {
    rejects { _ = try RegionModuleMutation.plan(module: .fullJapan, raw: baselineBytes, productType: product, build: version) }
}
for question in RegionCacheQuestion.allCases {
    var broken = baseline, fields = extra(baselineBytes); fields[question.key] = false; broken["CacheExtra"] = fields
    rejects { _ = try plan(.fullJapan, encode(broken)) }
}
let guessedIO = MemoryAccess([.mobileGestalt: baselineBytes])
var guessedRoot = baseline, guessedData = baselineData
guessedData[16] = 1; guessedRoot["CacheData"] = guessedData
let guessedScope = RegionPatchScope(byteOffsets: Array(16..<24) + [66], cacheUUID: uuid, cacheVersion: build, cacheLength: 6480)
let guessedPlan = RegionWritePlan(file: .mobileGestalt, before: baselineBytes, after: encode(guessedRoot), scope: guessedScope)
rejects { _ = try store(guessedIO, "guessed").apply(module: .greenTea, plans: [guessedPlan]) }
let incompleteIO = MemoryAccess([.mobileGestalt: baselineBytes])
let incompleteStore = store(incompleteIO, "incomplete-full")
rejects { _ = try incompleteStore.apply(module: .fullJapan, plans: [mgPlan]) }
rejects { _ = try incompleteStore.apply(module: .fullJapan, plans: [fullMG, fullMG]) }
rejects { _ = try incompleteStore.apply(module: .regionCode, plans: [fullMG]) }
expect(incompleteIO.events.isEmpty)
let noContextStore = RegionTransactionCoordinator(root: incompleteStore.root, access: incompleteIO, productType: "", build: "")
rejects { _ = try noContextStore.apply(module: .regionCode, plans: [mgPlan]) }
for fault in 0..<3 {
    let memory = MemoryAccess([.mobileGestalt: baselineBytes])
    let transaction = store(memory, "fault\(fault)")
    var injected = false
    memory.callback = { file, _, replacement, io in
        let pending = try transaction.pending().first!
        expect(pending.entries.count == 1)
        expect(pending.phase == .writing || injected)
        let before = try Data(contentsOf: transaction.root.appendingPathComponent(pending.id).appendingPathComponent("mobileGestalt.before.plist"))
        expect(before == (pending.operation == "apply" ? baselineBytes : fullMG.after))
        if !injected && fault != 0 {
            injected = true
            io.data[file] = fault == 2 ? Data([1,2,3]) : replacement
            throw RegionOperationError("injected write failure")
        }
        io.data[file] = replacement
    }
    if fault == 0 {
        _ = try transaction.apply(module: .fullJapan, plans: [fullMG])
        expect(memory.events == [.mobileGestalt])
        expect(try transaction.pending().isEmpty)
        let pointerURL = transaction.root.appendingPathComponent("originals/fullJapan-v2.plist")
        let pointer = try Data(contentsOf: pointerURL)
        _ = try transaction.apply(module: .fullJapan, plans: [plan(.fullJapan, memory.data[.mobileGestalt]!)])
        expect(try memory.events.count == 1 && Data(contentsOf: pointerURL) == pointer)
        _ = try transaction.restore(module: .fullJapan)
        expect(memory.data[.mobileGestalt] == baselineBytes)
    } else {
        rejects { _ = try transaction.apply(module: .fullJapan, plans: [fullMG]) }
        if fault == 2 {
            expect(try transaction.pending().first?.phase == .recoveryRequired)
            rejects { _ = try transaction.apply(module: .regionCode, plans: [mgPlan]) }
            rejects { _ = try store(memory, "fault\(fault)").recoverPending() }
        } else {
            expect(memory.data[.mobileGestalt] == baselineBytes)
            expect(try transaction.pending().isEmpty)
            expect(memory.events == [.mobileGestalt,.mobileGestalt])
        }
    }
}
for finalRead in [false, true] {
    let memory = MemoryAccess([.mobileGestalt: baselineBytes])
    let transaction = store(memory, "read-fault-\(finalRead)")
    var reads = 0, injected = false
    memory.readFault = { _, io in
        if !injected && io.events.count == 1 {
            reads += 1
            if reads == (finalRead ? 2 : 1) { injected = true; throw RegionOperationError("injected verification read failure") }
        }
    }
    rejects { _ = try transaction.apply(module: .fullJapan, plans: [fullMG]) }
    expect(memory.data[.mobileGestalt] == baselineBytes)
    expect(try transaction.pending().isEmpty)
}
let failedRollbackIO = MemoryAccess([.mobileGestalt: baselineBytes])
let failedRollbackStore = store(failedRollbackIO, "rollback-failure")
failedRollbackIO.callback = { file, _, replacement, io in
    if io.events.count == 2 { throw RegionOperationError("injected rollback failure") }
    io.data[file] = replacement
    throw RegionOperationError("injected failure after write")
}
rejects { _ = try failedRollbackStore.apply(module: .fullJapan, plans: [fullMG]) }
expect(try failedRollbackStore.pending().first?.phase == .recoveryRequired)
failedRollbackIO.callback = nil
_ = try store(failedRollbackIO, "rollback-failure").recoverPending()
expect(failedRollbackIO.data[.mobileGestalt] == baselineBytes)
// A failed commit/rollback-intent save retains the verified replacement and blocks further writes.
let metadataIO = MemoryAccess([.mobileGestalt: baselineBytes])
let metadataStore = store(metadataIO, "metadata-failure")
metadataIO.callback = { file, _, replacement, io in
    io.data[file] = replacement
    let pending = try metadataStore.pending().first!
    let path = metadataStore.root.appendingPathComponent(pending.id).appendingPathComponent("journal.plist")
    try FileManager.default.removeItem(at: path)
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
}
rejects { _ = try metadataStore.apply(module: .fullJapan, plans: [fullMG]) }
expect(metadataIO.events == [.mobileGestalt] && metadataIO.data[.mobileGestalt] == fullMG.after)
rejects { _ = try metadataStore.pending() }
rejects { _ = try metadataStore.apply(module: .regionCode, plans: [plan(.regionCode, metadataIO.data[.mobileGestalt]!)]) }

// Full Restore retains unrelated later root, extra and data changes.
let scopedIO = MemoryAccess([.mobileGestalt: baselineBytes]), scopedStoreName = "full-scoped"
let scopedStore = store(scopedIO, scopedStoreName)
_ = try scopedStore.apply(module: .fullJapan, plans: [fullMG])
var scopedRoot = root(scopedIO.data[.mobileGestalt]!), scopedExtra = extra(scopedIO.data[.mobileGestalt]!)
scopedExtra["hardware"] = "external-value"; scopedRoot["CacheExtra"] = scopedExtra
scopedRoot["other"] = "external-root"
var scopedData = fullData; scopedData[56] = 123; scopedRoot["CacheData"] = scopedData
scopedIO.data[.mobileGestalt] = encode(scopedRoot)
_ = try scopedStore.restore(module: .fullJapan)
let scopedRestored = root(scopedIO.data[.mobileGestalt]!), scopedRestoredExtra = extra(scopedIO.data[.mobileGestalt]!)
expect(scopedRestoredExtra["hardware"] as? String == "external-value" && scopedRestored["other"] as? String == "external-root")
expect([code,info,model].allSatisfy { RegionPlist.equal(scopedRestoredExtra[$0], extra(baselineBytes)[$0]) })
let scopedRestoredData = scopedRestored["CacheData"] as! Data
expect(scopedRestoredData[56] == 123 && [3064,4048,5552].allSatisfy { scopedRestoredData[$0] == baselineData[$0] })
// Target edits, UUID/version changes and backup corruption block Full Restore.
for key in [code, "CacheUUID", "CacheVersion"] {
    var changed = root(fullMG.after)
    if key == code { var fields = extra(fullMG.after); fields[code] = "LL"; changed["CacheExtra"] = fields }
    else { changed[key] = "external" }
    scopedIO.data[.mobileGestalt] = encode(changed)
    let writes = scopedIO.events.count
    rejects { _ = try scopedStore.restore(module: .fullJapan) }
    expect(scopedIO.events.count == writes)
}
scopedIO.data[.mobileGestalt] = baselineBytes
let fullReview = try scopedStore.prepare(module: .fullJapan, plans: [fullMG])!
try Data([9]).write(to: scopedStore.root.appendingPathComponent(fullReview.id).appendingPathComponent("mobileGestalt.after.plist"))
let writesBeforeCorruption = scopedIO.events.count
rejects { _ = try scopedStore.commitPrepared(fullReview.id) }
expect(scopedIO.events.count == writesBeforeCorruption)
_ = try scopedStore.recoverPending()

let driftIO = MemoryAccess([.mobileGestalt: baselineBytes])
let driftStore = store(driftIO, "target-drift")
_ = try driftStore.apply(module: .regionCode, plans: [mgPlan])
var externalRoot = root(driftIO.data[.mobileGestalt]!), externalExtra = extra(driftIO.data[.mobileGestalt]!)
externalExtra[code] = "LL"; externalRoot["CacheExtra"] = externalExtra
driftIO.data[.mobileGestalt] = encode(externalRoot)
let driftWrites = driftIO.events.count
rejects { _ = try driftStore.apply(module: .regionCode, plans: [plan(.regionCode, driftIO.data[.mobileGestalt]!)]) }
rejects { _ = try driftStore.restore(module: .regionCode) }
expect(driftIO.events.count == driftWrites)
let wrongBuild = RegionTransactionCoordinator(root: driftStore.root, access: driftIO, productType: profile, build: "other-build")
rejects { _ = try wrongBuild.originalAvailable(for: .regionCode) }
for key in ["CacheUUID", "CacheVersion"] {
    var changed = root(mgPlan.after); changed[key] = "external"
    driftIO.data[.mobileGestalt] = encode(changed)
    rejects { _ = try driftStore.restore(module: .regionCode) }
}

// Relaunch after termination between system write and durable commit.
let crashIO = MemoryAccess([.mobileGestalt: baselineBytes])
let crashStore = store(crashIO, "crash")
_ = try crashStore.apply(module: .regionCode, plans: [mgPlan])
let originalRecord = try PropertyListDecoder().decode([String:String].self,
    from: Data(contentsOf: crashStore.root.appendingPathComponent("originals/regionCode.plist")))
let journalURL = crashStore.root.appendingPathComponent(originalRecord["transaction"]!).appendingPathComponent("journal.plist")
var journal = try PropertyListDecoder().decode(RegionJournal.self, from: Data(contentsOf: journalURL))
journal.phase = .writing
try PropertyListEncoder().encode(journal).write(to: journalURL)
let relaunched = store(crashIO, "crash")
expect(try relaunched.pending().count == 1)
_ = try relaunched.recoverPending()
expect(crashIO.data[.mobileGestalt] == baselineBytes)
expect(try relaunched.pending().isEmpty)

// A prepared journal has complete backups but no system writes yet.
journal.phase = .prepared
try PropertyListEncoder().encode(journal).write(to: journalURL)
let unrelatedExternal = encode(["CacheExtra": [code: "LL"]])
crashIO.data[.mobileGestalt] = unrelatedExternal
_ = try relaunched.recoverPending()
expect(crashIO.data[.mobileGestalt] == unrelatedExternal) // No system write in prepared phase; preserve external edits.
crashIO.data[.mobileGestalt] = baselineBytes
// Interrupting backup creation is recognizable even if raw backup files are incomplete.
journal.phase = .preparing
try PropertyListEncoder().encode(journal).write(to: journalURL)
_ = try relaunched.recoverPending()
expect(try relaunched.pending().isEmpty)

// Backup corruption, external edits, unauthorized keys/bytes and backup failure.
try Data([9]).write(to: journalURL.deletingLastPathComponent().appendingPathComponent("mobileGestalt.before.plist"))
rejects { _ = try relaunched.apply(module: .regionCode, plans: [mgPlan]) }
let external = MemoryAccess([.mobileGestalt: manual])
rejects { _ = try store(external, "stale").apply(module: .regionCode, plans: [mgPlan]) }
expect(external.events.isEmpty)
var wrongRoot = root(mgPlan.after); wrongRoot["other"] = "damage"
rejects { try mgPlan.scope.validate(before: baselineBytes, after: encode(wrongRoot)) }
let forbidden = RegionWritePlan(file: .mobileGestalt, before: baselineBytes, after: encode(wrongRoot), scope: .init(rootKeys: ["other"]))
let forbiddenIO = MemoryAccess([.mobileGestalt: baselineBytes])
rejects { _ = try store(forbiddenIO, "forbidden").apply(module: .regionCode, plans: [forbidden]) }
let unavailableRoot = temporary.appendingPathComponent("not-a-directory")
try Data([1]).write(to: unavailableRoot)
let failedBackup = RegionTransactionCoordinator(root: unavailableRoot, access: forbiddenIO, productType: profile, build: build)
rejects { _ = try failedBackup.apply(module: .regionCode, plans: [mgPlan]) }
expect(forbiddenIO.events.isEmpty)
expect(RegionBackupDigest.sha256(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
expect(RegionBackupDigest.sha256(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
print("PASS: \(checks) actual Swift module, layout, whitelist, backup, restore, rollback and interruption checks (synthetic host data only)")
