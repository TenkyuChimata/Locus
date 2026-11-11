// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Validated Boolean value slots and their existing validity bytes.
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
        try RegionCacheMapping.layout(plist: plist, build: build, productType: productType,
                                      questions: RegionCacheQuestion.allCases)
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
              !fields.isEmpty, Set(fields.map(\.slot)).count == fields.count,
              fields.allSatisfy({ (0..<slotCount).contains($0.slot) }),
              data[validBase..<size].allSatisfy({ $0 <= 1 }) else {
            throw JapanRegionError.invalidCachePatchLayout
        }
        for field in fields {
            let offset = field.slot * MemoryLayout<UInt64>.size
            // Invalid slots may be recomputed by the system; never make them valid.
            guard data[offset] <= 1,
                  data[(offset + 1)..<(offset + 8)].allSatisfy({ $0 == 0 }),
                  data[validBase + field.slot] == 1 else {
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
        }
        // Independently enforce the entire write set, including unchanged slots.
        let allowed = Set(fields.map { $0.slot * 8 })
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
