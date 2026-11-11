// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 huamidev
// Layout matching and Boolean checks informed by GestaltX; see notices.
import Foundation

nonisolated enum RegionCacheQuestion: String, CaseIterable, Sendable {
    case greenTea = "green-tea", notGreenTea = "not-green-tea", wapi
    var key: String {
        switch self {
        case .greenTea: return "iyfxmLogGVIaH7aEgqwcIA"
        case .notGreenTea: return "4snMZS8LJkSctKypt2m+xA"
        case .wapi: return "hiHut/WR+B9Lx/vd0WyeNg"
        }
    }
    var target: Bool { self == .notGreenTea }
}

enum CacheMappingStatus: String {
    case unavailable = "Unsupported", readOnly = "Read-only", writable = "Writable"
}

struct CacheMappingAssessment {
    let question: RegionCacheQuestion
    let status: CacheMappingStatus
    let reason: String
    let cacheValue: Bool?
    var permitsMutation: Bool { status == .writable }
}

enum RegionCacheMapping {
    // Device-observed type-11 slots, confirmed against the persistent cache on
    // iPhone18,3 / iOS 27.2 / 24B119. Never extrapolate to another build or UUID.
    static let cacheUUID = "48CB1FAC-755B-435F-9A01-A20E5D810EA9"
    private static let slots: [RegionCacheQuestion: Int] = [.greenTea: 383, .notGreenTea: 506, .wapi: 694]

    static func question(atValueOffset offset: Int) -> RegionCacheQuestion? {
        slots.first(where: { $0.value * 8 == offset })?.key
    }

    static func layout(plist: [String: Any], build: String, productType: String,
                       questions: [RegionCacheQuestion], runtime: RegionLayoutResolution = .current()) throws -> JapanRegionCacheLayout {
        guard !build.isEmpty, plist["CacheVersion"] as? String == build else { throw JapanRegionError.staleCache }
        guard let uuid = (plist["CacheUUID"] as? String).flatMap(UUID.init(uuidString:)) else {
            throw RegionOperationError("Missing or invalid CacheUUID.")
        }
        guard let data = plist["CacheData"] as? Data else { throw JapanRegionError.missingCacheData }
        let resolvedSlots: [RegionCacheQuestion: Int]
        let count: Int
        let binding: RegionLayoutBinding?
        switch runtime {
        case .rejected(let reason): throw RegionOperationError(reason)
        case .resolved(let dynamic):
            guard dynamic.cacheUUID == uuid.uuidString, dynamic.slotCount * 9 == data.count else {
                throw RegionOperationError("Runtime CacheUUID or CacheData length differs from the current cache.")
            }
            if productType == "iPhone18,3", build == "24B119" {
                guard dynamic.cacheUUID == cacheUUID, dynamic.slotCount == 720 else {
                    throw RegionOperationError("Dynamic layout conflicts with the device-verified static layout.")
                }
                try dynamic.validateStaticAgreement(slots)
            }
            let proof = try dynamic.binding(for: questions)
            binding = proof; count = proof.slotCount
            resolvedSlots = Dictionary(uniqueKeysWithValues: zip(questions, proof.descriptors.map(\.slot)))
        case .unavailable:
            guard productType == "iPhone18,3", build == "24B119", uuid.uuidString == cacheUUID, data.count == 6480 else {
                throw RegionOperationError("No verified dynamic descriptor layout. Static fallback requires iPhone18,3 / 24B119 / the verified CacheUUID and length.")
            }
            binding = nil; count = 720; resolvedSlots = slots
        }
        guard let extra = plist["CacheExtra"] as? [String: Any] else { throw JapanRegionError.invalidMobileGestalt }
        guard !questions.isEmpty, Set(questions).count == questions.count else { throw JapanRegionError.invalidCachePatchLayout }
        for question in questions where extra[question.key] != nil || extra[question.rawValue] != nil {
            throw RegionOperationError("CacheExtra overrides \(question.rawValue); editing its CacheData slot is blocked.")
        }
        let layout = JapanRegionCacheLayout(size: data.count, slotCount: count, fields: questions.map {
            .init(question: $0.rawValue, slot: resolvedSlots[$0]!, value: $0.target)
        }, binding: binding)
        try layout.validate(data)
        return layout
    }

    static func assess(plist: [String: Any], build: String, writeAccess: Bool,
                       productType: String, runtime: RegionLayoutResolution = .current()) -> [CacheMappingAssessment] {
        RegionCacheQuestion.allCases.map { question in
            do {
                let layout = try layout(plist: plist, build: build, productType: productType, questions: [question], runtime: runtime)
                let value = (plist["CacheData"] as! Data)[layout.fields[0].slot * 8] == 1
                return .init(question: question, status: writeAccess ? .writable : .readOnly,
                    reason: layout.sourceDescription + (writeAccess ? "." : "; file write access is unavailable."), cacheValue: value)
            } catch {
                return .init(question: question, status: .unavailable, reason: error.localizedDescription, cacheValue: nil)
            }
        }
    }
}
