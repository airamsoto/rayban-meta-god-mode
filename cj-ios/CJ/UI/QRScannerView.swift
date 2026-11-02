import AVFoundation
import SwiftUI

/// The pairing QR printed by `python -m cj.pair`: {"v": 1, "url": "http://<ip>:8765", "token": "..."}.
extension Pairing {
    init?(qr text: String) {
        struct Payload: Decodable { let url: String; let token: String }
        guard let data = text.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              !payload.url.isEmpty, !payload.token.isEmpty else { return nil }
        self.init(url: payload.url, token: payload.token)
    }
}

/// Full-screen camera that reads one QR code and hands its text back. Needs NSCameraUsageDescription.
struct QRScannerView: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var denied = false

    var body: some View {
        NavigationStack {
            ZStack {
                if denied {
                    ContentUnavailableView("Sin acceso a la cámara",
                                           systemImage: "camera.fill",
                                           description: Text("Actívalo en Ajustes → CJ → Cámara."))
                } else {
                    CameraQRReader { code in
                        onCode(code)
                        dismiss()
                    }
                    .ignoresSafeArea()
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(.white, lineWidth: 3)
                        .frame(width: 260, height: 260)
                    VStack {
                        Spacer()
                        Text("Apunta al QR que muestra run.sh en el Mac")
                            .padding(10)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.bottom, 40)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
            }
            .task {
                switch AVCaptureDevice.authorizationStatus(for: .video) {
                case .notDetermined: denied = !(await AVCaptureDevice.requestAccess(for: .video))
                case .authorized: denied = false
                default: denied = true
                }
            }
        }
    }
}

/// AVFoundation QR reader. Works on every iPhone, unlike VisionKit's DataScanner.
private struct CameraQRReader: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ReaderController {
        let controller = ReaderController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: ReaderController, context: Context) {}

    final class ReaderController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?
        private var done = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let camera = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: camera),
                  session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(layer)
            preview = layer
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            let session = session
            DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            session.stopRunning()
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !done, let code = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
            done = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onCode?(code)
        }
    }
}
