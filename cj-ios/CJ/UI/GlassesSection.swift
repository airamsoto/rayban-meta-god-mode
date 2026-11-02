import MWDATCore
import SwiftUI

/// Setup for the glasses: link CJ in the Meta AI app, allow the camera, and take a test photo.
struct GlassesSection: View {
    @ObservedObject var glasses: Glasses
    @State private var working = false
    @State private var message = ""
    @State private var photo: UIImage?
    @State private var deviceInfo = ""

    var body: some View {
        Section {
            if let error = glasses.configureError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            LabeledContent("Vinculación", value: registrationText)
            if glasses.registration == .registered {
                LabeledContent("Gafas detectadas", value: "\(glasses.devices)")
                Text(deviceInfo).font(.footnote).foregroundStyle(.secondary)
                    .onAppear { deviceInfo = glasses.describeDevices() }
                    .onChange(of: glasses.devices) { deviceInfo = glasses.describeDevices() }
                Button("Actualizar estado de las gafas") { deviceInfo = glasses.describeDevices() }
                    .font(.footnote)
                LabeledContent("Cámara", value: glasses.cameraGranted == true ? "Permitida" : "Sin permiso")
            }

            switch glasses.registration {
            case .registered:
                if glasses.cameraGranted != true {
                    action("Permitir cámara de las gafas", icon: "camera") { try await glasses.requestCamera() }
                }
                action("Hacer foto con las gafas", icon: "camera.shutter.button") {
                    photo = try await glasses.takePhoto().image
                    message = "Foto recibida de las gafas."
                }
                action("Desvincular gafas", icon: "link.badge.plus", role: .destructive) { try await glasses.unregister() }
            case .registering:
                Label("Esperando a la app Meta AI…", systemImage: "hourglass")
            default:
                action("Vincular gafas", icon: "link") { try await glasses.register() }
            }

            if !message.isEmpty {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            if let photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        } header: {
            Text("Gafas")
        } footer: {
            Text("Necesita el Modo Desarrollador en la app Meta AI: Ajustes → Información de la app → toca 5 veces la versión.")
        }
        .task { await glasses.refreshCameraPermission() }
    }

    private var registrationText: String {
        switch glasses.registration {
        case .registered: return "Vinculadas"
        case .registering: return "Vinculando…"
        case .available: return "Sin vincular"
        case .unavailable: return "No disponible"
        @unknown default: return "?"
        }
    }

    private func action(_ title: String, icon: String, role: ButtonRole? = nil,
                        _ run: @escaping () async throws -> Void) -> some View {
        Button(role: role) {
            Task {
                working = true
                message = ""
                defer { working = false }
                do { try await run() } catch { message = error.localizedDescription }
                deviceInfo = glasses.describeDevices()
            }
        } label: {
            HStack {
                Label(title, systemImage: icon)
                if working { Spacer(); ProgressView() }
            }
        }
        .disabled(working)
    }
}
