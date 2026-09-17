import SwiftUI
import Core

/// View showing all activated devices for the current license
struct ActivatedDevicesView: View {
    let licenseKey: String
    @State private var devices: [ActivationAPI.DeviceInfo] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var machineLimit = 1
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(Theme.Text.display)
                    .foregroundStyle(.blue.gradient)

                Text("Activated Devices")
                    .font(.title.bold())

                Text("\(devices.count) of \(machineLimit) devices activated")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            if isLoading {
                ProgressView("Loading devices...")
                    .padding()
            } else if let error = error {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.red)

                    Text(error)
                        .font(.body)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                // Devices list
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(devices, id: \.deviceId) { device in
                            DeviceRow(
                                device: device,
                                isCurrentDevice: device.deviceId == DeviceIdentifier.getDeviceID(),
                                onDeactivate: {
                                    Task {
                                        await deactivateDevice(device)
                                    }
                                }
                            )
                        }

                        if devices.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "laptopcomputer")
                                    .font(Theme.Text.display)
                                    .foregroundStyle(.secondary)

                                Text("No devices activated")
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(40)
                        }
                    }
                    .padding()
                }
            }

            Spacer()

            // Close button
            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(width: 500, height: 500)
        .task {
            await loadDevices()
        }
    }

    private func loadDevices() async {
        isLoading = true
        error = nil

        do {
            let api = ActivationAPI()
            let response = try await api.verifyLicense(licenseKey)

            if response.valid, let activations = response.activations {
                devices = activations.devices
                machineLimit = activations.limit
            } else {
                error = response.error ?? "Failed to load devices"
            }
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    private func deactivateDevice(_ device: ActivationAPI.DeviceInfo) async {
        do {
            let api = ActivationAPI()
            _ = try await api.deactivateLicense(licenseKey, deviceId: device.deviceId)

            // Reload devices
            await loadDevices()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct DeviceRow: View {
    let device: ActivationAPI.DeviceInfo
    let isCurrentDevice: Bool
    let onDeactivate: () -> Void

    @State private var showingConfirmation = false

    var body: some View {
        HStack(spacing: 16) {
            // Device icon
            Image(systemName: isCurrentDevice ? "laptopcomputer" : "desktopcomputer")
                .font(Theme.Text.display)
                .foregroundStyle(isCurrentDevice ? .blue : .secondary)
                .frame(width: 48)

            // Device info
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(device.deviceName)
                        .font(.headline)

                    if isCurrentDevice {
                        Text("(This Mac)")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.2))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                    }
                }

                Text("Activated: \(formatDate(device.activatedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Last seen: \(formatDate(device.lastSeenAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Deactivate button
            if !isCurrentDevice {
                Button("Deactivate") {
                    showingConfirmation = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .confirmationDialog(
                    "Deactivate Device?",
                    isPresented: $showingConfirmation
                ) {
                    Button("Deactivate", role: .destructive) {
                        onDeactivate()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will remove \(device.deviceName) from your activated devices. You can reactivate it later if needed.")
                }
            }
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func formatDate(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: isoString) else {
            return isoString
        }

        let relativeFormatter = RelativeDateTimeFormatter()
        relativeFormatter.unitsStyle = .short
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

#Preview {
    ActivatedDevicesView(licenseKey: "MCP-test.key")
}
