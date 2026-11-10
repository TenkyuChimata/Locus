// SPDX-License-Identifier: GPL-3.0-only
import Foundation

MainActor.assumeIsolated {
    let gestaltBaseline = Fixture.initialGestalt
    let activationBaseline = Fixture.initialActivation
    // Repeated reads and scenario resets must reuse the exact source bytes,
    // even when a fresh dictionary would serialize in a different order.
    for _ in 0..<64 {
        assert(Fixture.initialGestalt == gestaltBaseline)
        assert(Fixture.initialActivation == activationBaseline)
        Fixture.reset(.none)
        assert(Fixture.gestalt == gestaltBaseline)
        assert(Fixture.activation == activationBaseline)
    }

    for fault in [Fixture.Fault.none, .backup, .activationPartial, .gestaltPartial,
                  .gestaltVerification, .finalActivationVerification, .rollback] {
        Fixture.reset(fault)
        let service = RegionIdentityService()
        service.applyJapanRegion()
        let writes = Fixture.events.filter { $0.hasPrefix("write") || $0.hasPrefix("restore") }
        if fault == .none {
            assert(service.errorMessage == nil && service.operationResult != nil)
            assert(writes == ["writeMA", "writeMG"])
        } else {
            assert(service.errorMessage != nil && service.operationResult == nil)
            assert(!service.shouldRespring)
            if fault == .backup {
                assert(writes.isEmpty)
            } else if fault == .activationPartial {
                assert(writes == ["writeMA", "restoreMA"])
            } else {
                assert(writes == ["writeMA", "writeMG", "restoreMG", "restoreMA"])
            }
            assert(Fixture.activation == Fixture.initialActivation)
            if fault != .rollback { assert(Fixture.gestalt == Fixture.initialGestalt) }
            else { assert(service.errorMessage!.contains("rollbackFailed")) }
        }
        if let firstWrite = Fixture.events.firstIndex(of: "writeMA") {
            assert(Fixture.events.firstIndex(of: "backupMG")! < firstWrite)
            assert(Fixture.events.firstIndex(of: "backupMA")! < firstWrite)
        }
        assert(!service.isBusy)
    }
    Fixture.reset(.none); Fixture.layoutKnown = false
    let service = RegionIdentityService()
    service.applyJapanRegion()
    assert(service.errorMessage != nil)
    assert(!Fixture.events.contains { $0.hasPrefix("write") })
    assert(Fixture.gestalt == Fixture.initialGestalt && Fixture.activation == Fixture.initialActivation)
    print("PASS: actual transaction orchestration with simulated I/O: backups before writes, success, partial failures, verification failures, reverse rollback, rollback failure, unknown layout")
}
