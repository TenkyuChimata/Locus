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
                       questions: [RegionCacheQuestion]) throws -> JapanRegionCacheLayout {
        guard productType == "iPhone18,3", build == "24B119" else {
            throw RegionOperationError("No supported cache layout for this device/build.")
        }
        guard plist["CacheVersion"] as? String == build else { throw JapanRegionError.staleCache }
        guard let uuid = (plist["CacheUUID"] as? String).flatMap(UUID.init(uuidString:)),
              uuid.uuidString == cacheUUID else {
            throw RegionOperationError("CacheUUID does not match the supported layout.")
        }
        guard let data = plist["CacheData"] as? Data else { throw JapanRegionError.missingCacheData }
        guard data.count == 6480 else { throw JapanRegionError.unexpectedCacheDataSize(data.count) }
        guard let extra = plist["CacheExtra"] as? [String: Any] else { throw JapanRegionError.invalidMobileGestalt }
        guard !questions.isEmpty, Set(questions).count == questions.count else { throw JapanRegionError.invalidCachePatchLayout }
        for question in questions where extra[question.key] != nil || extra[question.rawValue] != nil {
            throw RegionOperationError("CacheExtra overrides \(question.rawValue); editing its CacheData slot is blocked.")
        }
        let layout = JapanRegionCacheLayout(size: 6480, slotCount: 720, fields: questions.map {
            .init(question: $0.rawValue, slot: slots[$0]!, value: $0.target)
        })
        try layout.validate(data)
        return layout
    }

    static func assess(plist: [String: Any], build: String, writeAccess: Bool,
                       productType: String) -> [CacheMappingAssessment] {
        RegionCacheQuestion.allCases.map { question in
            do {
                let layout = try layout(plist: plist, build: build, productType: productType, questions: [question])
                let value = (plist["CacheData"] as! Data)[layout.fields[0].slot * 8] == 1
                return .init(question: question, status: writeAccess ? .writable : .readOnly,
                    reason: writeAccess ? "Supported cache layout." : "Cache layout matches; file write access is unavailable.", cacheValue: value)
            } catch {
                return .init(question: question, status: .unavailable, reason: error.localizedDescription, cacheValue: nil)
            }
        }
    }
}
