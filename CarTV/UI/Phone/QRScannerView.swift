import SwiftUI
@preconcurrency import AVFoundation
import Vision
import PhotosUI

/// Live camera QR scanner with a Photos fallback for QR images.
struct QRScannerView: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var authorized: Bool? = nil
    @State private var photoItem: PhotosPickerItem?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                switch authorized {
                case .some(true):
                    CameraPreview(onCode: handle).ignoresSafeArea()
                    scannerOverlay
                case .some(false):
                    VStack(spacing: Theme.s4) {
                        Image(systemName: "camera.fill").font(.system(size: 40)).foregroundStyle(Theme.inkMuted)
                        Text("Camera access is needed to scan.\nYou can also pick a QR code image from your photos").multilineTextAlignment(.center).foregroundStyle(Theme.ink)
                        Button("Open Settings") { if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) } }
                            .buttonStyle(.borderedProminent)
                    }.padding()
                case .none:
                    ProgressView()
                }
            }
            .navigationTitle("Scan QR code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    PhotosPicker(selection: $photoItem, matching: .images) { Image(systemName: "photo.on.rectangle") }
                }
            }
            .task {
                switch AVCaptureDevice.authorizationStatus(for: .video) {
                case .authorized: authorized = true
                case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .video)
                default: authorized = false
                }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data), let cg = img.cgImage else { return }
                    if let code = Self.detectQR(in: cg) { handle(code) } else { message = String(localized: "No QR code found") }
                    photoItem = nil
                }
            }
            .overlay(alignment: .bottom) {
                if let message {
                    BannerView(banner: ImportBanner(text: message, isError: true)).padding(.bottom, Theme.s8)
                        .task { try? await Task.sleep(for: .seconds(2)); self.message = nil }
                }
            }
        }
    }

    private var scannerOverlay: some View {
        VStack {
            Spacer()
            RoundedRectangle(cornerRadius: Theme.radiusL, style: .continuous)
                .strokeBorder(Theme.accent, lineWidth: 3)
                .frame(width: 240, height: 240)
            Text("Point at a QR code, or pick a photo from the top right")
                .font(Theme.Font.caption).foregroundStyle(.white.opacity(0.85)).padding(.top, Theme.s4)
            Spacer()
        }
    }

    private func handle(_ code: String) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if case .success = SubscriptionInput.detect(code) {
            onCode(code)
        } else {
            message = String(localized: "This QR code isn't a link")
        }
    }

    nonisolated static func detectQR(in image: CGImage) -> String? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(cgImage: image)
        try? handler.perform([request])
        return request.results?.first?.payloadStringValue
    }
}

struct CameraPreview: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController { ScannerController(onCode: onCode) }
    func updateUIViewController(_ vc: ScannerController, context: Context) {}
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let onCode: (String) -> Void
    private var fired = false

    init(onCode: @escaping (String) -> Void) { self.onCode = onCode; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.beginConfiguration()
        if session.canAddInput(input) { session.addInput(input) }
        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
        }
        session.commitConfiguration()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer
    }
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); previewLayer?.frame = view.bounds }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let s = session
        DispatchQueue.global(qos: .userInitiated).async { s.startRunning() }
    }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); session.stopRunning() }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let value = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        onMain { [weak self] in
            guard let self, !self.fired else { return }
            self.fired = true
            self.session.stopRunning()
            self.onCode(value)
        }
    }
}
