// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// CacheUUID is a candidate descriptor-schema key, not a proven binary identity.
/// Its relationship to the descriptor table must be established in the binary.
/// A UUID may be registered only after its three question-to-slot mappings have
/// been audited against libMobileGestalt. Equal lengths or equal answers do not prove
/// that mapping: in particular green-tea and wapi can have identical values.
struct JapanRegionCacheLayout {
    struct BooleanField {
        let question: String
        let slot: Int
        let value: Bool
    }

    let size: Int
    let slotCount: Int
    let fields: [BooleanField]

    static func resolve(plist: [String: Any], build: String, productType: String = "") throws -> Self {
        let assessments = RegionCacheMapping.assess(plist: plist, build: build,
            image: RegionCacheMapping.loadedImage(), writeAccess: false, productType: productType)
        if let data = plist["CacheData"] as? Data,
           assessments.count == RegionCacheQuestion.allCases.count,
           assessments.allSatisfy({ ($0.status == .binaryVerified || $0.status == .writable) && $0.valid == 1 }) {
            let layout = Self(size: data.count, slotCount: data.count / 9, fields: try assessments.map { item in
                guard let descriptor = item.descriptor else { throw JapanRegionError.unverifiedCacheSemantics }
                return .init(question: item.question.rawValue, slot: descriptor.slot, value: item.question.target)
            })
            try layout.validate(data)
            return layout
        }
        guard !build.isEmpty, plist["CacheVersion"] as? String == build else { throw JapanRegionError.staleCache }
        guard plist["CacheData"] is Data else { throw JapanRegionError.missingCacheData }
        throw JapanRegionError.unverifiedCacheSemantics
    }

    func validate(_ data: Data) throws {
        guard data.count == size else {
            throw JapanRegionError.unexpectedCacheDataSize(data.count)
        }
        guard size > 0, slotCount > 0, slotCount <= size / 9,
              slotCount * 9 == size else {
            throw JapanRegionError.invalidCachePatchLayout
        }
        let validBase = slotCount * MemoryLayout<UInt64>.size
        guard validBase + slotCount == size,
              Set(fields.map(\.slot)).count == fields.count,
              fields.allSatisfy({ (0..<slotCount).contains($0.slot) }),
              data[validBase..<size].allSatisfy({ $0 <= 1 }) else {
            throw JapanRegionError.invalidCachePatchLayout
        }
        for field in fields {
            let offset = field.slot * MemoryLayout<UInt64>.size
            // Only canonical booleans are accepted, including when invalid.
            guard data[offset] <= 1,
                  data[(offset + 1)..<(offset + 8)].allSatisfy({ $0 == 0 }) else {
                throw JapanRegionError.invalidCachePatchLayout
            }
        }
    }

    func applying(to original: Data) throws -> Data {
        try validate(original)
        var result = original
        for field in fields {
            let offset = field.slot * 8
            result[offset] = field.value ? 1 : 0
            result[slotCount * 8 + field.slot] = 1
        }
        // Independently enforce the entire write set, including unchanged slots.
        let allowed = Set(fields.flatMap { field in
            [field.slot * 8, slotCount * 8 + field.slot]
        })
        guard result.indices.allSatisfy({ result[$0] == original[$0] || allowed.contains($0) }) else {
            throw JapanRegionError.invalidCachePatchLayout
        }
        return result
    }

    func isApplied(to data: Data) -> Bool {
        guard (try? validate(data)) != nil else { return false }
        return fields.allSatisfy { field in
            data[field.slot * 8] == (field.value ? 1 : 0)
                && data[slotCount * 8 + field.slot] == 1
        }
    }
}
