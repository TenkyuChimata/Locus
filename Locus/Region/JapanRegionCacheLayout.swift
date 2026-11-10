// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// CacheUUID identifies a descriptor schema, not an OS build. A UUID may be
/// registered only after its three question-to-slot mappings have been audited
/// against libMobileGestalt. Equal lengths or equal boolean answers do not prove
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

    // Original recovered layout, retained without using its originating build
    // as authorization. Values are uint64 little-endian, followed by valid bytes.
    static let known1947 = JapanRegionCacheLayout(
        size: 0x1947, slotCount: 0x2CF,
        fields: [
            .init(question: "green-tea", slot: 0x17E, value: false),
            .init(question: "not-green-tea", slot: 0x1F9, value: true),
            .init(question: "wapi", slot: 0x2B5, value: false)
        ]
    )

    // The inherited source contains offsets but no CacheUUID or binary evidence.
    // Do not manufacture a fingerprint. Until a descriptor audit supplies one,
    // all persisted layouts are unknown and mutation fails closed, on every OS.
    static let reviewedSchemas: [String: JapanRegionCacheLayout] = [:]

    static func resolve(plist: [String: Any], build: String) throws -> Self {
        guard let uuid = plist["CacheUUID"] as? String,
              let parsedUUID = UUID(uuidString: uuid),
              let layout = reviewedSchemas[parsedUUID.uuidString] else {
            throw JapanRegionError.unverifiedCacheSemantics
        }
        guard let cacheVersion = plist["CacheVersion"] as? String,
              !build.isEmpty, cacheVersion == build else {
            throw JapanRegionError.staleCache
        }
        guard let data = plist["CacheData"] as? Data else {
            throw JapanRegionError.missingCacheData
        }
        try layout.validate(data)
        return layout
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
            result.replaceSubrange(offset..<(offset + 8),
                                   with: [field.value ? 1 : 0] + [UInt8](repeating: 0, count: 7))
            result[slotCount * 8 + field.slot] = 1
        }
        // Independently enforce the entire write set, including unchanged slots.
        let allowed = Set(fields.flatMap { field in
            Array((field.slot * 8)..<(field.slot * 8 + 8)) + [slotCount * 8 + field.slot]
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
