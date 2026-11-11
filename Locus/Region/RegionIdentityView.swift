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
                }
                Section("Japan Region Identity") {
                    value("Six-field Acceptance", service.identityMatches ? "Values Match — Restart / Functions Not Verified" : "Not Verified / Values Differ")
                    ForEach([RegionModule.regionCode, .regionInfo, .regulatoryModel, .greenTea, .notGreenTea, .wapi]) { moduleRow($0) }
                }
                Section("Japan RegionalBehavior") {
                    RegionalBehaviorDiagnosticsContent(service: service.regionalDiagnostics, productType: service.productType,
                        build: service.build, activationRows: service.activationSourceDiagnostics)
                }
                moduleSection("Additional Capabilities", [.intelligence])
                Section {
                    Button("Refresh MobileActivation Research") { service.refreshResearch() }
                        .disabled(service.isBusy)
                    moduleRow(.mobileActivation)
                    NavigationLink("CoreText GB18030 Experiment") { CoreTextGB18030View() }
                    Text("CoreText normally reads RegionalBehaviorGB18030 and caches it with dispatch_once. The experiment is limited to Locus; Locale CN can also affect glyphs. A false MG value does not guarantee every glyph renders normally. Unreviewed binaries remain blocked.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("Advanced Research") }
                moduleSection("Full Japan Region", [.fullJapan])
                if let detail = service.recoveryDetail {
                    Section("Unfinished Transaction") {
                        Text(detail).font(.caption.monospaced()).textSelection(.enabled)
                        Button("Recover and Verify Original Bytes", role: .destructive) { service.recover() }
                            .disabled(service.isBusy)
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
                        Text("Original backup saved and verified. Only the selected fields will change. Restore preserves unrelated changes.")
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

    private func moduleSection(_ title: String, _ modules: [RegionModule]) -> some View {
        Section(title) { ForEach(modules) { moduleRow($0) } }
    }
    @ViewBuilder private func moduleRow(_ module: RegionModule) -> some View {
        if let status = service.modules.first(where: { $0.module == module }) {
            VStack(alignment: .leading, spacing: 8) {
                Text(module.title).font(.headline)
                value("Current", status.cache)
                value("Target", status.expected)
                value("Modification", status.access)
                value("Verification", status.verification)
                HStack {
                    if module != .fullJapan {
                        Button("Review Changes") {
                            if service.prepare(module) { action = .init(module: module, restore: false) }
                        }.disabled(service.isBusy || !status.canApply)
                    }
                    Spacer()
                    Button("Restore") {
                        if service.prepare(module, restore: true) { action = .init(module: module, restore: true) }
                    }.disabled(service.isBusy || !status.canRestore)
                }.buttonStyle(.bordered)
                DisclosureGroup("Details") {
                    value("Runtime", status.runtime)
                    value("Original Backup", status.originalAvailable ? "Available" : "Not yet saved")
                    Text(status.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if module == .mobileActivation {
                        DisclosureGroup("Access Diagnostics") {
                            ForEach(service.activationDiagnostics) { row in
                                value(row.title, row.value)
                            }
                        }
                    }
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
