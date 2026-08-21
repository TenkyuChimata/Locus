import Foundation

enum JapanRegionMutation {
    static let verifiedBuild = "24A5390f"

    static let regionCodeKey = "h63QSdBCiT/z0WU6rdQv6Q"
    static let regionInfoKey = "yK+xavymRGZ3xWc1tb8XDg"
    static let regulatoryModelKey = "97JDvERpVwO+GHtthIh7hA"

    private struct CacheBooleanPatch {
        let cacheDataSize: Int
        let valueOffset: Int
        let validOffset: Int
        let value: Bool
    }

    // Exact MobileGestalt descriptor slots recovered only for 24A5390f.
    private static let patchesByBuild: [String: [CacheBooleanPatch]] = [
        verifiedBuild: [
            // green-tea: slot 0x17E
            .init(cacheDataSize: 0x1947, valueOffset: 0x0BF0, validOffset: 0x17F6, value: false),
            // not-green-tea: slot 0x1F9
            .init(cacheDataSize: 0x1947, valueOffset: 0x0FC8, validOffset: 0x1871, value: true),
            // wapi: slot 0x2B5
            .init(cacheDataSize: 0x1947, valueOffset: 0x15A8, validOffset: 0x192D, value: false)
        ]
    ]

    static func validate(
        plist: [String: Any],
        profile: JapanRegionProfile,
        build: String
    ) throws {
        guard build == verifiedBuild, let patches = patchesByBuild[build] else {
            throw JapanRegionError.unsupportedBuild(build)
        }
        guard plist["CacheExtra"] is [String: Any] else {
            throw JapanRegionError.invalidMobileGestalt
        }
        guard let cacheData = plist["CacheData"] as? Data else {
            throw JapanRegionError.missingCacheData
        }
        guard patches.allSatisfy({ $0.cacheDataSize == cacheData.count }) else {
            throw JapanRegionError.unexpectedCacheDataSize(cacheData.count)
        }
        guard JapanRegionProfile.verified(for: profile.productType) == profile else {
            throw JapanRegionError.unsupportedProductType(profile.productType)
        }
    }

    static func applying(
        to plist: [String: Any],
        profile: JapanRegionProfile,
        build: String
    ) throws -> [String: Any] {
        try validate(plist: plist, profile: profile, build: build)
        guard var cacheExtra = plist["CacheExtra"] as? [String: Any],
              var cacheData = plist["CacheData"] as? Data,
              let patches = patchesByBuild[build] else {
            throw JapanRegionError.invalidMobileGestalt
        }

        // Software identity only. Hardware identity answers are never written.
        cacheExtra[regionCodeKey] = "J"
        cacheExtra[regionInfoKey] = "J/A"
        cacheExtra[regulatoryModelKey] = profile.regulatoryModel

        for patch in patches {
            try apply(patch, to: &cacheData)
        }

        var result = plist
        result["CacheExtra"] = cacheExtra
        result["CacheData"] = cacheData
        return result
    }

    static func isApplied(
        to plist: [String: Any],
        profile: JapanRegionProfile,
        build: String
    ) -> Bool {
        guard let cacheExtra = plist["CacheExtra"] as? [String: Any],
              let cacheData = plist["CacheData"] as? Data,
              let patches = patchesByBuild[build],
              cacheExtra[regionCodeKey] as? String == "J",
              cacheExtra[regionInfoKey] as? String == "J/A",
              cacheExtra[regulatoryModelKey] as? String == profile.regulatoryModel else {
            return false
        }
        return patches.allSatisfy { isApplied($0, to: cacheData) }
    }

    private static func apply(_ patch: CacheBooleanPatch, to data: inout Data) throws {
        let end = patch.valueOffset + MemoryLayout<UInt64>.size
        guard data.count == patch.cacheDataSize,
              patch.valueOffset >= 0,
              end <= data.count,
              patch.validOffset >= 0,
              patch.validOffset < data.count else {
            throw JapanRegionError.invalidCachePatchLayout
        }

        var slot = Data(repeating: 0, count: MemoryLayout<UInt64>.size)
        slot[0] = patch.value ? 1 : 0
        data.replaceSubrange(patch.valueOffset..<end, with: slot)
        data[patch.validOffset] = 1
    }

    private static func isApplied(_ patch: CacheBooleanPatch, to data: Data) -> Bool {
        let end = patch.valueOffset + MemoryLayout<UInt64>.size
        guard data.count == patch.cacheDataSize,
              patch.valueOffset >= 0,
              end <= data.count,
              patch.validOffset >= 0,
              patch.validOffset < data.count else { return false }
        return data[patch.valueOffset] == (patch.value ? 1 : 0)
            && data[(patch.valueOffset + 1)..<end].allSatisfy { $0 == 0 }
            && data[patch.validOffset] == 1
    }
}

enum JapanRegionError: LocalizedError {
    case unsupportedBuild(String)
    case unsupportedProductType(String)
    case invalidMobileGestalt
    case missingCacheData
    case unexpectedCacheDataSize(Int)
    case invalidCachePatchLayout
    case activationVerificationFailed
    case mobileGestaltVerificationFailed
    case rollbackFailed(primary: String, rollback: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedBuild(let build):
            "Persistent mutation is verified only on Darwin build \(JapanRegionMutation.verifiedBuild). Current build: \(build.isEmpty ? "<unknown>" : build)."
        case .unsupportedProductType(let productType):
            "No verified Japan profile exists for \(productType.isEmpty ? "<unknown>" : productType). Hardware identity will not be spoofed."
        case .invalidMobileGestalt:
            "The MobileGestalt plist or CacheExtra dictionary is invalid."
        case .missingCacheData:
            "MobileGestalt CacheData is missing."
        case .unexpectedCacheDataSize(let size):
            "CacheData has an unverified size (\(size) bytes); refusing the exact-build patch."
        case .invalidCachePatchLayout:
            "The exact-build CacheData patch layout is invalid."
        case .activationVerificationFailed:
            "MobileActivation did not contain JP, J/A, and SoftwareBehaviors 25 after writing."
        case .mobileGestaltVerificationFailed:
            "MobileGestalt did not contain every expected Japan-region value after writing."
        case .rollbackFailed(let primary, let rollback):
            "The operation failed: \(primary)\nRollback also failed: \(rollback)"
        }
    }
}
