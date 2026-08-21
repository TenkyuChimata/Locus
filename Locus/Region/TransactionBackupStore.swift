import Foundation

struct RegionTransactionBackup {
    let directory: URL

    func saveMobileGestalt(_ data: Data) throws {
        try saveExact(data, name: "MobileGestalt.plist")
    }

    func saveMobileActivation(_ data: Data) throws {
        try saveExact(data, name: "MobileActivation-region_info.plist")
    }

    private func saveExact(_ data: Data, name: String) throws {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        guard try Data(contentsOf: url) == data else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

enum TransactionBackupStore {
    static func begin() throws -> RegionTransactionBackup {
        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = documents.appendingPathComponent(
            "Japan Region Transaction Backups",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        let name = formatter.string(from: Date()) + "_" + UUID().uuidString
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        return RegionTransactionBackup(directory: directory)
    }
}
