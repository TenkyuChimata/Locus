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
                Section("Real Device / Loaded Binary") {
                    value("ProductType", service.productType)
                    value("OS Build", service.build)
                    value("MobileGestalt LC_UUID", service.binaryUUID)
                }
                moduleSection("Region Identity", [.regionCode, .regionInfo, .regulatoryModel])
                moduleSection("Region Cache Behaviors", [.greenTea, .notGreenTea, .wapi])
                moduleSection("Additional Capabilities", [.intelligence])
                Section {
                    Button("Refresh MobileActivation Research") { service.refreshResearch() }
                        .disabled(service.isBusy)
                    moduleRow(.mobileActivation)
                    NavigationLink("CoreText GB18030 Experiment") { CoreTextGB18030View() }
                    Text("CoreText changes only a reviewed byte in this process temporarily. It is independent of system RegionalBehaviorGB18030.")
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
                Section("Verification After Restart") {
                    Text("Fully restart the device, reopen Locus, refresh Diagnostics and compare runtime answers. Test each feature separately. A cache write or a matching MGCopyAnswer does not establish functional availability.")
                    Text("Apple Intelligence: record the capability flag, Settings visibility, model download and actual service use as four separate results. Hardware, account, language and server restrictions may still apply.")
                    Text("Original means the exact value before this module's first Locus edit. An existing J/A value is never assumed to be the factory value. Existing transaction backups are retained.")
                }.font(.caption)
            }
            .navigationTitle("Japan Region")
            .toolbar {
                Button { service.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(service.isBusy).accessibilityLabel("Refresh Region Modules")
            }
            .task { service.refresh() }
            .sheet(item: $action) { pending in
                NavigationStack {
                    List {
                        if let status = service.modules.first(where: { $0.module == pending.module }) {
                            value("Current Cache Value", status.cache)
                            value("Current Runtime Value", status.runtime)
                            value("Expected Value", pending.restore ? "Exact saved pre-Locus value" : status.expected)
                            Text("Complete original bytes and SHA-256 checksums are saved before writing. Only this module's allowed keys or bytes may change. Restore preserves other modules. A full device restart is required for independent runtime verification.")
                                .font(.caption)
                        }
                        Button(pending.restore ? "Restore and Verify" : "Apply and Verify", role: .destructive) {
                            action = nil
                            if pending.restore { service.restore(pending.module) }
                            else { service.apply(pending.module) }
                        }
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
            DisclosureGroup(module.title) {
                value("Current Cache Value", status.cache)
                value("Current Runtime Value", status.runtime)
                value("Expected Value", status.expected)
                value("Mapping / Access Status", status.access)
                value("Verification Status", status.verification)
                value("Original Value Available", status.originalAvailable ? "Yes · pre-Locus baseline" : "No")
                Text(status.detail).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Button("Apply", role: .destructive) { action = .init(module: module, restore: false) }
                        .disabled(service.isBusy || !status.canApply)
                    Spacer()
                    Button("Restore") { action = .init(module: module, restore: true) }
                        .disabled(service.isBusy || !status.canRestore)
                }.buttonStyle(.bordered)
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
