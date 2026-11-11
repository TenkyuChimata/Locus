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
    print("PASS: six individual service Apply/Restore, composite review/cancel/confirm/no-op, permissions, recovery, drift and ordinary MobileGestalt diagnostics (simulated native APIs)")
}
