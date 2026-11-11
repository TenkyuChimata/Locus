#if canImport(Combine)
import Combine
#endif
import Foundation
import CoreFoundation

struct RuntimeDiagnosticQuestion: Identifiable {
    enum Group: Equatable { case region, hardware }

    var id: String { query }
    let title: String
    let query: String
    let cacheKey: String?
    let group: Group
}

let runtimeDiagnosticQuestions: [RuntimeDiagnosticQuestion] = [
    .init(title: "RegionCode", query: "RegionCode", cacheKey: JapanRegionMutation.regionCodeKey, group: .region),
    // Distinct questions, not proven old/new aliases. Keep each cached value
    // paired with its own question; matching runtime answers do not merge them.
    .init(title: "RegionInfo", query: "RegionInfo", cacheKey: "zHeENZu+wbg7PUprwNwBWg", group: .region),
    .init(title: "RegionInfoFromSysconfig (direct key)", query: "yK+xavymRGZ3xWc1tb8XDg", cacheKey: "yK+xavymRGZ3xWc1tb8XDg", group: .region),
    .init(title: "RegionInfo (direct key)", query: "zHeENZu+wbg7PUprwNwBWg", cacheKey: "zHeENZu+wbg7PUprwNwBWg", group: .region),
    .init(title: "RegulatoryModelNumber", query: "RegulatoryModelNumber", cacheKey: JapanRegionMutation.regulatoryModelKey, group: .region),
    .init(title: "WSKU", query: "gD8SNRcHQeIxCAvsp+2vjA", cacheKey: "gD8SNRcHQeIxCAvsp+2vjA", group: .hardware),
    .init(title: "green-tea", query: "green-tea", cacheKey: "iyfxmLogGVIaH7aEgqwcIA", group: .region),
    .init(title: "not-green-tea", query: "not-green-tea", cacheKey: "4snMZS8LJkSctKypt2m+xA", group: .region),
    .init(title: "wapi", query: "wapi", cacheKey: "hiHut/WR+B9Lx/vd0WyeNg", group: .region),
    .init(title: "RestrictedCountryCodes", query: "RestrictedCountryCodes", cacheKey: "nSo8opze5rFk+EdBoR6tBw", group: .region),
    .init(title: "CountryOfOrigin", query: "CountryOfOrigin", cacheKey: "gizLvTWx1sMUYQ9EYr/N4g", group: .region),
    .init(title: "ProductType", query: "ProductType", cacheKey: "h9jDsbgj7xIVeIQ8S3/X3Q", group: .hardware),
    .init(title: "HardwarePlatform", query: "HardwarePlatform", cacheKey: "5pYKlGnYYBzGvAlIU8RjEQ", group: .hardware),
    .init(title: "HWModelStr", query: "HWModelStr", cacheKey: "/YYygAofPDbhrwToVsXdeA", group: .hardware)
]

@MainActor
final class RuntimeDiagnosticsService: ObservableObject {
    @Published private(set) var runtimeAnswers: [String: Any] = [:]
    @Published private(set) var cacheExtra: [String: Any] = [:]
    @Published private(set) var cacheInfo: [String: Any] = [:]
    @Published private(set) var cacheStatus = "Not read"
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        var errors: [String] = []
        let gestalt = MobileGestaltAccess.shared()

        do {
            if let plist = try gestalt.readCachePlist() as? [String: Any] {
                cacheExtra = plist["CacheExtra"] as? [String: Any] ?? [:]
                cacheInfo = [
                    "CacheUUID": plist["CacheUUID"] as? String ?? "<unavailable>",
                    "CacheVersion": plist["CacheVersion"] as? String ?? "<unavailable>"
                ]
                if let data = plist["CacheData"] as? Data { cacheInfo["CacheDataBytes"] = data.count }
                cacheStatus = "Readable"
            } else {
                cacheExtra = [:]
                cacheInfo = [:]
                cacheStatus = "Unavailable"
                errors.append("MobileGestalt cache: expected a dictionary.")
            }
        } catch {
            cacheExtra = [:]
            cacheInfo = [:]
            cacheStatus = "Unavailable"
            errors.append("MobileGestalt cache: \(error.localizedDescription)")
        }

        do {
            runtimeAnswers = try gestalt.runtimeAnswers(for: runtimeDiagnosticQuestions.map(\.query))
        } catch {
            runtimeAnswers = [:]
            errors.append("MobileGestalt runtime: \(error.localizedDescription)")
        }

        errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }
}

enum DiagnosticValueFormatter {
    static func display(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "<nil>" }
        if let data = value as? Data {
            let base64 = data.base64EncodedString()
            let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
            return "Base64: \(base64)\nHex: \(hex)"
        }
        if let array = value as? [Any] {
            return "[" + array.map { display($0) }.joined(separator: ", ") + "]"
        }
        if let dictionary = value as? [String: Any] {
            let entries = dictionary.sorted { $0.key < $1.key }
                .map { "\($0.key)=\(display($0.value))" }
            return "{ " + entries.joined(separator: ", ") + " }"
        }
        if let number = value as? NSNumber,
           CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }
        return String(describing: value)
    }
}
