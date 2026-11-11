// SPDX-License-Identifier: GPL-3.0-only
// Actual service; native MobileGestalt APIs are simulated. No device access.
import Foundation

MainActor.assumeIsolated {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let unsupported = RegionIdentityService(backupRoot: temporary.appendingPathComponent("unknown"),
        deviceContext: { ("unknown-model", "fixture-build") })
    unsupported.refresh()
    assert(unsupported.modules.count == 7 && RegionModule.allCases.count == 7)
    assert(unsupported.modules.first { $0.module == .regionCode }!.canApply)
    assert(!unsupported.modules.first { $0.module == .regulatoryModel }!.canApply)
    assert(!unsupported.modules.first { $0.module == .fullJapan }!.canApply)
    assert(unsupported.fullJapanState == .unsupported)
    assert(!unsupported.prepare(.fullJapan) && !Fixture.events.contains("writeMG"))

    var known = try! RegionPlist.parse(Fixture.baseline).root
    var bytes = Data(repeating: 0, count: 6480)
    for slot in [383, 506, 694] { bytes[5760 + slot] = 1 }
    bytes[3064] = 1; bytes[5552] = 1
    known["CacheData"] = bytes; known["CacheVersion"] = "24B119"
    known["CacheUUID"] = "48CB1FAC-755B-435F-9A01-A20E5D810EA9"
    let baseline = try! PropertyListSerialization.data(fromPropertyList: known, format: .binary, options: 0)
    Fixture.gestalt = baseline
    let service = RegionIdentityService(backupRoot: temporary.appendingPathComponent("known"),
        deviceContext: { ("iPhone18,3", "24B119") }, deviceID: "simulated-device")
    @MainActor func status(_ module: RegionModule) -> RegionModuleStatus {
        service.modules.first { $0.module == module }!
    }
    service.refresh()
    assert(service.modules.allSatisfy(\.canApply) && service.fullJapanState == .ready)
    assert(service.recoveryDetail == nil)
    for module in RegionModule.allCases where module != .fullJapan {
        Fixture.events = []
        assert(service.prepare(module))
        assert(service.prepared?.entries.count == 1 && service.prepared?.entries[0].file == .mobileGestalt)
        assert(service.prepared?.phase == .prepared && !Fixture.events.contains("writeMG"))
        service.confirmPrepared()
        assert(service.errorMessage == nil && status(module).canRestore)
        assert(Fixture.events.filter { $0 == "writeMG" }.count == 1)
        assert(!service.prepare(module)) // Already applied; keep its first original.
        assert(service.operationResult == RegionTransactionCoordinator.unchangedMessage)
        assert(service.prepare(module, restore: true))
        assert(Fixture.events.filter { $0 == "writeMG" }.count == 1)
        service.confirmPrepared()
        assert(service.errorMessage == nil && Fixture.gestalt == baseline)
    }
    Fixture.events = []
    assert(service.prepare(.fullJapan))
    assert(service.comparisons.count == 6)
    assert(service.comparisons.contains("green-tea: true → false"))
    assert(service.prepared?.schemaVersion == 2 && service.prepared?.entries.count == 1)
    assert(!Fixture.events.contains("writeMG"))
    service.cancelPrepared()
    assert(service.prepared == nil && Fixture.gestalt == baseline && !status(.fullJapan).originalAvailable)
    assert(service.fullJapanState == .ready)
    assert(service.prepare(.fullJapan))
    service.confirmPrepared()
    assert(service.errorMessage == nil && Fixture.events.filter { $0 == "writeMG" }.count == 1)
    assert(service.fullJapanState == .applied && status(.fullJapan).canRestore)
    assert(status(.fullJapan).verification.contains("No Changes Needed"))
    assert(status(.fullJapan).detail.contains("Restart"))
    assert(!service.prepare(.fullJapan) && service.prepared == nil)
    assert(service.operationResult == RegionTransactionCoordinator.unchangedMessage)
    assert(Fixture.events.filter { $0 == "writeMG" }.count == 1)
    assert(service.prepare(.fullJapan, restore: true))
    service.confirmPrepared()
    assert(service.errorMessage == nil && Fixture.gestalt == baseline)
    assert(service.fullJapanState == .ready)

    // Source bytes are frozen by Review, including unrelated values.
    assert(service.prepare(.fullJapan))
    var drift = known; drift["external"] = true
    Fixture.gestalt = try! PropertyListSerialization.data(fromPropertyList: drift, format: .binary, options: 0)
    let writes = Fixture.events.filter { $0 == "writeMG" }.count
    service.confirmPrepared()
    assert(service.errorMessage?.contains("Source changed") == true)
    assert(Fixture.events.filter { $0 == "writeMG" }.count == writes)
    Fixture.gestalt = baseline
    Fixture.writable = false
    service.refresh()
    assert(service.fullJapanState == .notApplied && service.modules.allSatisfy { !$0.canApply && !$0.canRestore })
    assert(!service.prepare(.fullJapan) && Fixture.gestalt == baseline)
    Fixture.writable = true
    // Permission can disappear after confirmation preparation.
    assert(service.prepare(.fullJapan))
    Fixture.writable = false
    service.confirmPrepared()
    assert(service.errorMessage != nil && Fixture.gestalt == baseline)
    Fixture.writable = true
    service.recover()
    assert(service.errorMessage == nil && service.recoveryDetail == nil)

    // Invalidating one Boolean never enables a partial composite operation.
    var invalid = known, invalidBytes = bytes
    invalidBytes[5760 + 694] = 0; invalid["CacheData"] = invalidBytes
    Fixture.gestalt = try! PropertyListSerialization.data(fromPropertyList: invalid, format: .binary, options: 0)
    service.refresh()
    assert(service.fullJapanState == .unsupported && !status(.fullJapan).canApply)
    assert(status(.greenTea).canApply && !status(.wapi).canApply)
    assert(!service.prepare(.fullJapan))
    Fixture.gestalt = baseline

    // Runtime failure neither claims post-restart success nor changes persistent support.
    Fixture.runtimeError = true
    service.refresh()
    assert(service.fullJapanState == .ready && service.errorMessage?.contains("Runtime") == true)
    Fixture.runtimeError = false
    let diagnostics = RuntimeDiagnosticsService()
    diagnostics.refresh()
    assert(diagnostics.errorMessage == nil && diagnostics.cacheStatus == "Readable")
    Fixture.runtimeError = true
    diagnostics.refresh()
    assert(diagnostics.runtimeAnswers.isEmpty && diagnostics.errorMessage != nil)
    Fixture.runtimeError = false
    assert(!Fixture.queries.contains { $0.contains("RegionalBehavior") || $0.contains("SoftwareBehavior") })
    assert(Fixture.events.allSatisfy { ["readMG", "writeMG", "runtimeMG"].contains($0) })
    // A new model/build with one missing descriptor exposes independent actions.
    var image = try! RegionPlist.parse(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("base.plist"))).root
    let complete = RegionLayoutResolution.resolved(try! MobileGestaltRuntimeLayout.scan(image))
    var sections = image["sections"] as! [[String: Any]]
    for key in ["data", "pointers"] {
        var data = sections[2][key] as! Data
        data.replaceSubrange(176..<240, with: Data(repeating: 0, count: 64))
        sections[2][key] = data
    }
    image["sections"] = sections
    var dynamic = RegionLayoutResolution.resolved(try! MobileGestaltRuntimeLayout.scan(image))
    var generic = known, genericData = Data(repeating: 0, count: 144)
    for slot in [2,7,13] { genericData[128 + slot] = 1 }
    genericData[16] = 1; genericData[104] = 1
    generic["CacheData"] = genericData; generic["CacheVersion"] = "25D123"
    generic["CacheUUID"] = "5E9DE961-58CA-4602-BB9A-576AC561936B"
    Fixture.gestalt = try! PropertyListSerialization.data(fromPropertyList: generic, format: .binary, options: 0)
    let flexible = RegionIdentityService(backupRoot: temporary.appendingPathComponent("dynamic"),
        deviceContext: { ("iPad16,3-A", "25D123") }, deviceID: "dynamic-device", layoutProvider: { dynamic })
    flexible.refresh()
    assert(flexible.modules.filter { ![.wapi, .fullJapan].contains($0.module) }.allSatisfy(\.canApply))
    assert(!flexible.modules.first { $0.module == .wapi }!.canApply)
    assert(!flexible.modules.first { $0.module == .fullJapan }!.canApply)
    assert(flexible.modules.first { $0.module == .fullJapan }!.detail.contains("wapi"))
    assert(flexible.cacheExtraSupport == "3/3 fields verified" && flexible.mobileGestaltAccess == "Writable")
    assert(!flexible.prepare(.fullJapan))
    assert(flexible.prepare(.regionCode)); flexible.confirmPrepared()
    assert(flexible.errorMessage == nil)
    dynamic = complete; flexible.refresh()
    assert(flexible.modules.allSatisfy(\.canApply))
    assert(flexible.prepare(.fullJapan)); flexible.confirmPrepared()
    assert(flexible.fullJapanState == .applied && flexible.errorMessage == nil)
    print("PASS: dynamic service availability, missing wapi isolation, new device/build and composite apply (simulated APIs)")
    print("PASS: six individual service Apply/Restore, composite review/cancel/confirm/no-op, permissions, recovery, drift and ordinary MobileGestalt diagnostics (simulated native APIs)")
}
