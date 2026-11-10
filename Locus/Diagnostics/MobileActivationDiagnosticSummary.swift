// SPDX-License-Identifier: GPL-3.0-only
import CoreFoundation
import Foundation

/// Each row represents one operation. Counts from stat, lstat and relative
/// lookup describe repeated observations of a target, never distinct files.
enum MobileActivationDiagnosticSummary {
    struct Row: Identifiable {
        let id: String
        let title: String
        let value: String
    }

    struct ProbeGroup: Identifiable {
        let id: String
        let title: String
        let rows: [Row]
    }

    static func probeGroups(_ discovery: [String: Any]) -> [ProbeGroup] {
        let probes = discovery["metadataPathProbes"] as? [String: Any] ?? [:]
        var groups: [ProbeGroup] = []
        for (phase, phaseTitle) in [("afterLease", "After lease"), ("beforeLease", "Before lease")] {
            for (alias, aliasTitle) in [("privateVar", "/private/var"), ("var", "/var")] {
                let prefix = "\(phase).\(alias)"
                var rows: [Row] = []
                for (target, targetTitle) in [("directory", "Directory"), ("hidden", "Hidden metadata"), ("plain", "Plain candidate")] {
                    for (operation, operationTitle) in [
                        ("lstat", "lstat"), ("stat", "stat"), ("relative-lstat", "relative lookup"),
                        ("open", "read-only open"), ("fstat", "opened object type")
                    ] {
                        let key = "\(prefix).\(target).\(operation)"
                        if let value = distribution(probes, prefix: key + "=") {
                            rows.append(Row(id: key, title: "\(targetTitle) · \(operationTitle)", value: value))
                        }
                    }
                }
                if !rows.isEmpty {
                    groups.append(ProbeGroup(id: prefix, title: "\(phaseTitle) · \(aliasTitle)", rows: rows))
                }
            }
        }
        return groups
    }

    static func aliasRows(_ discovery: [String: Any]) -> [Row] {
        let probes = discovery["metadataPathProbes"] as? [String: Any] ?? [:]
        return [("afterLease", "Aliases after lease"), ("beforeLease", "Aliases before lease")].compactMap { phase, title in
            guard let value = distribution(probes, prefix: "\(phase).aliases=") else { return nil }
            return Row(id: phase, title: title, value: value)
        }
    }

    static func readErrorRows(_ discovery: [String: Any]) -> [Row] {
        let errors = discovery["metadataReadErrors"] as? [String: Any] ?? [:]
        return errors.keys.sorted().compactMap { key in
            guard let count = parseCount(errors[key]) else { return nil }
            let title = key.replacingOccurrences(of: "privateVar ->", with: "/private/var →")
                .replacingOccurrences(of: "var ->", with: "/var →")
                .replacingOccurrences(of: " -> ", with: " → ")
            return Row(id: key, title: title, value: String(count))
        }
    }

    private static func distribution(_ probes: [String: Any], prefix: String) -> String? {
        let entries = probes.keys.filter { $0.hasPrefix(prefix) }.sorted().compactMap { key -> String? in
            guard let count = parseCount(probes[key]) else { return nil }
            let raw = String(key.dropFirst(prefix.count))
            return "\(outcome(raw)): \(count)"
        }
        return entries.isEmpty ? nil : entries.joined(separator: "; ")
    }

    private static func parseCount(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = Int(number.stringValue), integer >= 0 else { return nil }
        return integer
    }

    private static func outcome(_ raw: String) -> String {
        let states = ["opened", "regular-file", "directory", "symlink", "other",
                      "same-directory", "different-directories", "identity-unconfirmed"]
        if states.contains(raw) { return raw.replacingOccurrences(of: "-", with: " ") }
        let prefix = "NSPOSIXErrorDomain:"
        if raw.hasPrefix(prefix), let code = Int(raw.dropFirst(prefix.count)) {
            let name = [1: "EPERM", 2: "ENOENT", 13: "EACCES", 21: "EISDIR"][code]
            return "NSPOSIXErrorDomain \(code)" + (name.map { " (\($0))" } ?? "")
        }
        return "unrecognized outcome"
    }
}
