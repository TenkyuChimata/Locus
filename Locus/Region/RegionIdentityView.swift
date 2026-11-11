// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

struct RegionIdentityView: View {
    @EnvironmentObject private var service: RegionIdentityService
    @State private var action: PendingAction?
    private struct PendingAction: Identifiable {
        let module: RegionModule
        let restore: Bool
        var id: String { module.rawValue + String(restore) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Device") {
                    value("ProductType", service.productType)
                    value("OS Build", service.build)
                    value("CacheUUID", service.cacheUUID)
                    value("MobileGestalt Access", service.mobileGestaltAccess)
                    value("CacheExtra Region Settings", service.cacheExtraSupport)
                    value("CacheData Layout", service.cacheLayout)
                }
                Section("Individual Region Settings") {
                    ForEach(RegionModule.allCases.filter { $0 != .fullJapan }) { moduleRow($0) }
                }
                fullJapanSection
                if let detail = service.recoveryDetail {
                    Section("Recovery") {
                        Text(detail).font(.caption.monospaced()).textSelection(.enabled)
                        Button("Recover and Verify Original Bytes", role: .destructive) { service.recover() }
                            .disabled(service.isBusy)
                    }
                }
                if let detail = service.legacyBackupDetail {
                    Section("Legacy Backups") {
                        Text(detail).font(.caption).textSelection(.enabled)
                    }
                }
                if !service.comparisons.isEmpty {
                    Section("Last Write Comparison") {
                        ForEach(service.comparisons, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
                    }
                }
                if let result = service.operationResult {
                    Section("Last Operation") { Text(result).font(.caption).textSelection(.enabled) }
                }
                if let error = service.errorMessage {
                    Section("Error") { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                }
                Section {
                    Text("Restart the device and test the affected feature after applying. Readback confirms file contents; in-place writes are not power-loss atomic.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Japan Region")
            .toolbar {
                Button { service.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(service.isBusy).accessibilityLabel("Refresh Region Modules")
            }
            .task { service.refresh() }
            .sheet(item: $action, onDismiss: { service.cancelPrepared() }) { pending in
                NavigationStack {
                    List {
                        Section("Changes") {
                            ForEach(service.comparisons, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                        }
                        Text("Transaction backups saved and verified. Only the selected fields will change. Restore preserves unrelated changes.")
                            .font(.caption)
                        Text("In-place writes are not crash or power-loss atomic.").font(.caption).foregroundStyle(.secondary)
                        Button(pending.restore ? "Restore" : "Apply", role: .destructive) {
                            service.confirmPrepared()
                            action = nil
                        }.disabled(service.isBusy || service.prepared == nil)
                        Button("Cancel", role: .cancel) { action = nil }
                    }
                    .navigationTitle(pending.module.title).navigationBarTitleDisplayMode(.inline)
                }
            }
        }
    }

    private var fullJapanSection: some View {
        Section("Full Japan Region") {
            if let status = service.modules.first(where: { $0.module == .fullJapan }) {
                fullJapanValue("Verification", status.verification)
                fullJapanValue("Access Status", status.access)
            } else {
                fullJapanValue("Verification", nil)
            }
            Text("Applied means all six persistent cache settings match their targets. Restart, check runtime answers and test affected features separately; system region behavior is not verified by this status.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Use the individual statuses directly, never the composite strings.
            // Keep every field visible even when its status is unavailable.
            ForEach(RegionModule.allCases.filter { $0 != .fullJapan }) { module in
                fullJapanField(module)
            }

            if let status = service.modules.first(where: { $0.module == .fullJapan }) {
                Button {
                    if service.prepare(.fullJapan) { action = .init(module: .fullJapan, restore: false) }
                } label: {
                    Text("Review Changes").frame(maxWidth: .infinity)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.bordered)
                .disabled(service.isBusy || !status.canApply)
                Button {
                    if service.prepare(.fullJapan, restore: true) { action = .init(module: .fullJapan, restore: true) }
                } label: {
                    Text("Restore").frame(maxWidth: .infinity)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.bordered)
                .disabled(service.isBusy || !status.canRestore)
                fullJapanValue("Original Backup", status.originalAvailable ? "Available" : "Not yet saved")
                DisclosureGroup("Details") {
                    Text(status.detail).font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
        }
    }

    private func fullJapanField(_ module: RegionModule) -> some View {
        let status = service.modules.first(where: { $0.module == module })
        return VStack(alignment: .leading, spacing: 12) {
            Text(module.title).font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            fullJapanValue("Current", status?.cache)
            fullJapanValue("Target", status?.expected)
            DisclosureGroup("Runtime") {
                fullJapanValue("Runtime", status?.runtime)
            }
        }
        .padding(.vertical, 4)
    }

    private func fullJapanValue(_ title: String, _ text: String?) -> some View {
        let display = (text.flatMap { $0.isEmpty ? nil : $0 } ?? "Unavailable")
            .replacingOccurrences(of: "<unavailable>", with: "Unavailable")
            .replacingOccurrences(of: "<nil>", with: "Unavailable")
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(display).font(.body.monospaced()).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
    @ViewBuilder private func moduleRow(_ module: RegionModule) -> some View {
        if let status = service.modules.first(where: { $0.module == module }) {
            VStack(alignment: .leading, spacing: 8) {
                Text(module.title).font(.headline)
                value("Current", status.cache)
                value("Target", status.expected)
                value("Access Status", status.access)
                value("Verification", status.verification)
                HStack {
                    Button("Review Changes") {
                        if service.prepare(module) { action = .init(module: module, restore: false) }
                    }.disabled(service.isBusy || !status.canApply)
                    Spacer()
                    Button("Restore") {
                        if service.prepare(module, restore: true) { action = .init(module: module, restore: true) }
                    }.disabled(service.isBusy || !status.canRestore)
                }.buttonStyle(.bordered)
                DisclosureGroup("Details") {
                    value("Runtime", status.runtime)
                    value("Original Backup", status.originalAvailable ? "Available" : "Not yet saved")
                    Text(status.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        } else { Text(module.title).foregroundStyle(.secondary) }
    }
    private func value(_ title: String, _ text: String) -> some View {
        LabeledContent(title) {
            Text(text.isEmpty ? "<unavailable>" : text).font(.caption.monospaced())
                .multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }
}
