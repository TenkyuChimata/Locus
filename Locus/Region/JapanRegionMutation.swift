import Foundation

enum JapanRegionMutation {
    static let regionCodeKey = "h63QSdBCiT/z0WU6rdQv6Q"
    static let regionInfoKey = "yK+xavymRGZ3xWc1tb8XDg"
    static let regulatoryModelKey = "97JDvERpVwO+GHtthIh7hA"

    static func validate(
        plist: [String: Any],
        profile: JapanRegionProfile,
        build: String
    ) throws {
        guard let extra = plist["CacheExtra"] as? [String: Any],
              [regionCodeKey, regionInfoKey, regulatoryModelKey].allSatisfy({
                  guard let value = extra[$0] as? String else { return false }
                  return !value.isEmpty
              }) else {
            throw JapanRegionError.invalidMobileGestalt
        }
        _ = try JapanRegionCacheLayout.resolve(plist: plist, build: build)
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
              let cacheData = plist["CacheData"] as? Data else {
            throw JapanRegionError.invalidMobileGestalt
        }

        // Software identity only. Hardware identity answers are never written.
        cacheExtra[regionCodeKey] = "J"
        cacheExtra[regionInfoKey] = "J/A"
        cacheExtra[regulatoryModelKey] = profile.regulatoryModel

        let layout = try JapanRegionCacheLayout.resolve(plist: plist, build: build)
        let updatedCacheData = try layout.applying(to: cacheData)

        var result = plist
        result["CacheExtra"] = cacheExtra
        result["CacheData"] = updatedCacheData
        return result
    }

    static func isApplied(
        to plist: [String: Any],
        profile: JapanRegionProfile,
        build: String
    ) -> Bool {
        guard let cacheExtra = plist["CacheExtra"] as? [String: Any],
              let cacheData = plist["CacheData"] as? Data,
              let layout = try? JapanRegionCacheLayout.resolve(plist: plist, build: build),
              cacheExtra[regionCodeKey] as? String == "J",
              cacheExtra[regionInfoKey] as? String == "J/A",
              cacheExtra[regulatoryModelKey] as? String == profile.regulatoryModel else {
            return false
        }
        return layout.isApplied(to: cacheData)
    }
}

enum JapanRegionError: LocalizedError {
    case unverifiedCacheSemantics
    case staleCache
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
        case .unverifiedCacheSemantics:
            "CacheData question-to-slot semantics are unverified. A reviewed CacheUUID/descriptor mapping is required; matching length or OS build is insufficient. Diagnostics remain available."
        case .staleCache:
            "The MobileGestalt cache version does not match the running system. Refusing stale data."
        case .unsupportedProductType(let productType):
            "No verified Japan profile exists for \(productType.isEmpty ? "<unknown>" : productType). Hardware identity will not be spoofed."
        case .invalidMobileGestalt:
            "The MobileGestalt plist or CacheExtra dictionary is invalid."
        case .missingCacheData:
            "MobileGestalt CacheData is missing."
        case .unexpectedCacheDataSize(let size):
            "CacheData has an unverified size (\(size) bytes); refusing mutation."
        case .invalidCachePatchLayout:
            "The CacheData boolean slots, validity flags, or mutation bounds are invalid."
        case .activationVerificationFailed:
            "MobileActivation did not contain JP, J/A, and SoftwareBehaviors 25 after writing."
        case .mobileGestaltVerificationFailed:
            "MobileGestalt did not contain every expected Japan-region value after writing."
        case .rollbackFailed(let primary, let rollback):
            "The operation failed: \(primary)\nRollback also failed: \(rollback)"
        }
    }
}
