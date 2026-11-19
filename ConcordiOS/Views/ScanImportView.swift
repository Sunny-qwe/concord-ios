import SwiftUI
import AVFoundation
import UIKit

// MARK: - Scan import (FlClash: lib/pages/scan.dart)
// Camera QR scanner for subscription / node-link import. A scanned
// code is handed back to the caller, which feeds the EXISTING
// UnifiedImportView import path — this view parses nothing itself.
// NOTE: the camera needs NSCameraUsageDescription in
// ConcordiOS/Info.plist (the coordinator adds it); without it the
// app crashes the moment the camera is requested.

struct ScanImportView: View {
    /// Called once with the scanned text (subscription URL or node
    /// link). The caller imports it through UnifiedImporter.
    var onScanned: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var authorization: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var invalidHint = false
    @State private var torchOn = false
    @State private var didScan = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                switch authorization {
                case .authorized:
                    QRScannerCameraView(
                        torchOn: $torchOn,
                        onCode: handleCode
                    )
                    .ignoresSafeArea()
                    scanOverlay
                case .denied, .restricted:
                    permissionDeniedView
                case .notDetermined:
                    ProgressView()
                        .tint(.white)
                @unknown default:
                    permissionDeniedView
                }
            }
            .navigationTitle("扫码导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .task {
                if authorization == .notDetermined {
                    let granted = await AVCaptureDevice.requestAccess(for: .video)
                    authorization = granted ? .authorized : .denied
                }
            }
        }
    }

    private var scanOverlay: some View {
        VStack {
            Spacer()
            RoundedRectangle(cornerRadius: 24)
                .stroke(Color.white, lineWidth: 2)
                .frame(width: 260, height: 260)
                .overlay(alignment: .topLeading) {
                    cornerMarks
                }
            Text(invalidHint ? "二维码不是订阅链接或节点链接" : "将订阅或节点二维码放入框内")
                .font(.system(size: 13))
                .foregroundStyle(invalidHint ? .red : .white)
                .padding(.top, 20)
            Button {
                torchOn.toggle()
            } label: {
                Image(systemName: torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Color.white.opacity(0.2), in: Circle())
            }
            .padding(.top, 28)
            Spacer()
        }
    }

    private static let cornerAlignments: [Alignment] = [.topLeading, .topTrailing, .bottomLeading, .bottomTrailing]

    private var cornerMarks: some View {
        ZStack {
            ForEach(Self.cornerAlignments.indices, id: \.self) { index in
                let alignment = Self.cornerAlignments[index]
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white)
                    .frame(width: 28, height: 4)
                    .frame(width: 260, height: 260, alignment: alignment)
            }
        }
    }

    private var permissionDeniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.7))
            Text("需要相机权限才能扫码")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
            Text("请在系统「设置 → Concord → 相机」中允许访问相机，然后返回这里重新扫码。也可以直接粘贴链接导入，不用扫码。")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("打开系统设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(ConcordTheme.accent)
            Button("直接粘贴链接导入") { dismiss() }
                .foregroundStyle(.white)
        }
    }

    /// Accepts subscription URLs and node share links; anything
    /// else flashes the invalid hint and keeps scanning.
    private func handleCode(_ code: String) {
        guard !didScan else { return }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch UnifiedImporter.kind(of: trimmed) {
        case .subscription, .nodeLink:
            didScan = true
            onScanned(trimmed)
            dismiss()
        case .unknown:
            invalidHint = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                invalidHint = false
            }
        }
    }
}

// MARK: - Camera preview + metadata output

private struct QRScannerCameraView: UIViewRepresentable {
    @Binding var torchOn: Bool
    var onCode: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    func makeUIView(context: Context) -> QRScannerPreviewView {
        let view = QRScannerPreviewView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: QRScannerPreviewView, context: Context) {
        context.coordinator.setTorch(on: torchOn)
    }

    static func dismantleUIView(_ uiView: QRScannerPreviewView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let onCode: (String) -> Void
        private let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "concord.qr-scanner")

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        private var attached = false

        func attach(to view: QRScannerPreviewView) {
            guard !attached else { return }
            attached = true
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: queue)
            output.metadataObjectTypes = [.qr]
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            view.attach(layer: layer)
            queue.async { [weak self] in
                self?.session.startRunning()
            }
        }

        func setTorch(on: Bool) {
            guard let device = AVCaptureDevice.default(for: .video),
                  device.hasTorch else { return }
            try? device.lockForConfiguration()
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
        }

        func stop() {
            queue.async { [weak self] in
                self?.session.stopRunning()
            }
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let code = object.stringValue else { return }
            Task { @MainActor in
                onCode(code)
            }
        }
    }
}

/// Plain UIView hosting the AVCaptureVideoPreviewLayer.
private final class QRScannerPreviewView: UIView {
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override class var layerClass: AnyClass { CALayer.self }

    func attach(layer: AVCaptureVideoPreviewLayer) {
        previewLayer?.removeFromSuperlayer()
        previewLayer = layer
        layer.frame = bounds
        self.layer.addSublayer(layer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }
}
