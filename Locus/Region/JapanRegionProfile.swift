import Darwin
import Foundation

struct JapanRegionProfile: Equatable, Sendable {
    let productType: String
    let marketingName: String
    let regulatoryModel: String

    static func verified(for productType: String) -> JapanRegionProfile? {
        let normalized = productType.split(separator: "-", maxSplits: 1)
            .first.map(String.init) ?? productType
        guard let values = verifiedModels[normalized] else { return nil }
        return JapanRegionProfile(
            productType: normalized,
            marketingName: values.0,
            regulatoryModel: values.1
        )
    }

    // This is the verified map inherited from the existing Japan-region
    // implementation. Unsupported ProductTypes are intentionally refused.
    private static let verifiedModels: [String: (String, String)] = [
        // iPhone 15 Pro
        "iPhone16,1": ("iPhone 15 Pro", "A3101"),
        "iPhone16,2": ("iPhone 15 Pro Max", "A3105"),

        // iPhone 16
        "iPhone17,1": ("iPhone 16 Pro", "A3292"),
        "iPhone17,2": ("iPhone 16 Pro Max", "A3295"),
        "iPhone17,3": ("iPhone 16", "A3286"),
        "iPhone17,4": ("iPhone 16 Plus", "A3289"),
        "iPhone17,5": ("iPhone 16e", "A3409"),

        // iPhone 17
        "iPhone18,1": ("iPhone 17 Pro", "A3522"),
        "iPhone18,2": ("iPhone 17 Pro Max", "A3525"),
        "iPhone18,3": ("iPhone 17", "A3519"),
        "iPhone18,4": ("iPhone Air", "A3516"),
        "iPhone18,5": ("iPhone 17e", "A3575"),

        // iPad Pro 11-inch (M1)
        // iPad13,4/5 = Wi-Fi, 8 GB / 16 GB RAM
        // iPad13,6/7 = Cellular, 8 GB / 16 GB RAM
        "iPad13,4": ("iPad Pro 11-inch (M1)", "A2377"),
        "iPad13,5": ("iPad Pro 11-inch (M1)", "A2377"),
        "iPad13,6": ("iPad Pro 11-inch (M1)", "A2459"),
        "iPad13,7": ("iPad Pro 11-inch (M1)", "A2459"),

        // iPad Pro 12.9-inch (M1)
        // iPad13,8/9 = Wi-Fi, 8 GB / 16 GB RAM
        // iPad13,10/11 = Cellular, 8 GB / 16 GB RAM
        "iPad13,8": ("iPad Pro 12.9-inch (M1)", "A2378"),
        "iPad13,9": ("iPad Pro 12.9-inch (M1)", "A2378"),
        "iPad13,10": ("iPad Pro 12.9-inch (M1)", "A2461"),
        "iPad13,11": ("iPad Pro 12.9-inch (M1)", "A2461"),

        // iPad Air (M1)
        "iPad13,16": ("iPad Air (M1)", "A2588"),
        "iPad13,17": ("iPad Air (M1)", "A2589"),

        // iPad Pro (M2)
        "iPad14,3": ("iPad Pro 11-inch (M2)", "A2759"),
        "iPad14,4": ("iPad Pro 11-inch (M2)", "A2761"),
        "iPad14,5": ("iPad Pro 12.9-inch (M2)", "A2436"),
        "iPad14,6": ("iPad Pro 12.9-inch (M2)", "A2437"),

        // iPad Air (M2)
        "iPad14,8": ("iPad Air 11-inch (M2)", "A2902"),
        "iPad14,9": ("iPad Air 11-inch (M2)", "A2903"),
        "iPad14,10": ("iPad Air 13-inch (M2)", "A2898"),
        "iPad14,11": ("iPad Air 13-inch (M2)", "A2899"),

        // iPad Air (M3)
        "iPad15,3": ("iPad Air 11-inch (M3)", "A3266"),
        "iPad15,4": ("iPad Air 11-inch (M3)", "A3267"),
        "iPad15,5": ("iPad Air 13-inch (M3)", "A3268"),
        "iPad15,6": ("iPad Air 13-inch (M3)", "A3269"),

        // iPad mini (A17 Pro)
        "iPad16,1": ("iPad mini (A17 Pro)", "A2993"),
        "iPad16,2": ("iPad mini (A17 Pro)", "A2995"),

        // iPad Pro (M4)
        "iPad16,3": ("iPad Pro 11-inch (M4)", "A2836"),
        "iPad16,4": ("iPad Pro 11-inch (M4)", "A2837"),
        "iPad16,5": ("iPad Pro 13-inch (M4)", "A2925"),
        "iPad16,6": ("iPad Pro 13-inch (M4)", "A2926"),

        // iPad Air (M4)
        "iPad16,8": ("iPad Air 11-inch (M4)", "A3459"),
        "iPad16,9": ("iPad Air 11-inch (M4)", "A3460"),
        "iPad16,10": ("iPad Air 13-inch (M4)", "A3461"),
        "iPad16,11": ("iPad Air 13-inch (M4)", "A3462"),

        // iPad Pro (M5)
        "iPad17,1": ("iPad Pro 11-inch (M5)", "A3357"),
        "iPad17,2": ("iPad Pro 11-inch (M5)", "A3358"),
        "iPad17,3": ("iPad Pro 13-inch (M5)", "A3360"),
        "iPad17,4": ("iPad Pro 13-inch (M5)", "A3361")
    ]
}

enum RealDeviceIdentity {
    static var productType: String {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0,
              size > 1 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &bytes, &size, nil, 0) == 0 else {
            return ""
        }
        return String(cString: bytes)
    }
}
