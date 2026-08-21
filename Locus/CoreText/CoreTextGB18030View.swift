import SwiftUI
import UIKit

struct CoreTextGB18030View: View {
    @State private var probe: [String: Any] = [:]
    @State private var result: [String: Any] = [:]
    @State private var baselineImage: UIImage?
    @State private var forcedImage: UIImage?
    @State private var restoredImage: UIImage?
    @State private var errorMessage: String?
    @State private var isRunning = false

    var body: some View {
        NavigationStack {
            List {
                Section("Capability") {
                    valueRow("OS Build", probe["build"])
                    valueRow("Exact Build Supported", probe["buildSupported"])
                    valueRow("CoreText Loaded", probe["coreTextLoaded"])
                    valueRow("Address Validated", probe["addressValidated"])
                    valueRow("Image", probe["imageName"])
                    valueRow("Cached Byte Address", probe["cachedBoolRuntimeAddress"])
                    valueRow("Cached Predicate Byte", probe["cachedByte"])
                    valueRow("Once Complete", probe["onceComplete"])

                    if let validationError = probe["validationError"],
                       !(validationError is NSNull) {
                        Text(display(validationError))
                            .font(.caption.monospaced())
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                }

                Section {
                    Button {
                        runExperiment()
                    } label: {
                        HStack {
                            Label("Run Experimental Override", systemImage: "memorychip")
                            Spacer()
                            if isRunning { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(
                        isRunning
                        || !boolean(probe["buildSupported"])
                        || !boolean(probe["addressValidated"])
                    )

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.monospaced())
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("Process-Local Experiment")
                } footer: {
                    Text(
                        "The public UIKit/CoreText rendering path initializes the predicate. "
                        + "Only its already-writable cached byte is temporarily forced false, then restored in cleanup. "
                        + "No system file, page protection, or once token is changed."
                    )
                }

                if !result.isEmpty {
                    Section("Result / Restoration") {
                        valueRow("Original Byte", result["originalCachedByte"])
                        valueRow("Forced Byte", result["forcedCachedByte"])
                        valueRow("Restored Byte", result["restoredCachedByte"])
                        valueRow("Restore Verified", result["restoreVerified"])
                        valueRow("Transition Verified", result["predicateTransitionVerified"])
                        valueRow("Page Protection Changed", result["pageProtectionChanged"])
                        valueRow("Once Token Modified", result["onceTokenModified"])
                    }

                    comparisonImage("Baseline", image: baselineImage)
                    comparisonImage("Forced False", image: forcedImage)
                    comparisonImage("Restored", image: restoredImage)
                }
            }
            .navigationTitle("CoreText GB18030")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        refreshProbe()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isRunning)
                    .accessibilityLabel("Refresh CoreText Probe")
                }
            }
            .task { refreshProbe() }
        }
    }

    @ViewBuilder
    private func comparisonImage(_ title: String, image: UIImage?) -> some View {
        if let image {
            Section(title) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("\(title) Taiwan flag rendering sample")
            }
        }
    }

    private func refreshProbe() {
        guard !isRunning else { return }
        errorMessage = nil
        do {
            probe = try CoreTextGB18030Service.probe()
        } catch {
            probe = [:]
            errorMessage = error.localizedDescription
        }
    }

    private func runExperiment() {
        guard !isRunning else { return }
        isRunning = true
        errorMessage = nil
        result = [:]
        baselineImage = nil
        forcedImage = nil
        restoredImage = nil

        Task { @MainActor in
            await Task.yield()
            do {
                let experiment = try CoreTextGB18030Service
                    .runGB18030RenderingExperiment()
                result = experiment
                baselineImage = image(experiment["baselinePNG"])
                forcedImage = image(experiment["forcedPNG"])
                restoredImage = image(experiment["restoredPNG"])
            } catch {
                errorMessage = error.localizedDescription
            }
            isRunning = false
            refreshProbe()
        }
    }

    private func image(_ value: Any?) -> UIImage? {
        (value as? Data).flatMap(UIImage.init(data:))
    }

    private func valueRow(_ title: String, _ value: Any?) -> some View {
        LabeledContent(title) {
            Text(display(value))
                .font(.caption.monospaced())
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func boolean(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }

    private func display(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "<nil>" }
        if let number = value as? NSNumber,
           CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }
        if let data = value as? Data { return "Data(\(data.count) bytes)" }
        return String(describing: value)
    }
}
