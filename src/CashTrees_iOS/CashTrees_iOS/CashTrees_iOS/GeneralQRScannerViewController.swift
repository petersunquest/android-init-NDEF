//
//  GeneralQRScannerViewController.swift
//  CashTrees_iOS
//
//  Full-screen QR scanner for PWA bridge: camera + dimmed/blurred overlay + photo/file pick.
//

import AVFoundation
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import Vision

enum GeneralQRScanFilter {
    case anyText
    case recoveryCodeOnly
}

enum GeneralQRScanFailure: Equatable {
    case cancelled
    case cameraUnavailable
    case cameraPermissionDenied
    case qrNotFound
    case unsupportedFile
}

// MARK: - QR decode helpers

func qrCodePayloads(from image: UIImage) -> [String] {
    guard let ciImage = CIImage(image: image) else { return [] }
    var results: [String] = []

    let detector = CIDetector(
        ofType: CIDetectorTypeQRCode,
        context: nil,
        options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
    )
    let features = detector?.features(in: ciImage) as? [CIQRCodeFeature] ?? []
    for feature in features {
        if let raw = feature.messageString?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            results.append(raw)
        }
    }

    if results.isEmpty, #available(iOS 11.0, *) {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
        try? handler.perform([request])
        for barcode in request.results ?? [] {
            guard barcode.symbology == .qr,
                  let raw = barcode.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty
            else { continue }
            results.append(raw)
        }
    }

    return results
}

func firstQRCodePayload(from image: UIImage) -> String? {
    qrCodePayloads(from: image).first
}

private func isBase62RecoveryCode(_ raw: String) -> Bool {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (16...64).contains(trimmed.count) else { return false }
    let allowed = CharacterSet(charactersIn: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
}

func recoveryCodeCandidate(from raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if isBase62RecoveryCode(trimmed) { return trimmed }

    let queryKeys = ["MasterKey", "masterKey", "masterkey", "recoveryCode", "recoverCode", "code"]
    if let comp = URLComponents(string: trimmed) {
        for key in queryKeys {
            if let value = comp.queryItems?.first(where: { $0.name == key })?.value,
               isBase62RecoveryCode(value) {
                return value
            }
        }
        if let fragment = comp.fragment {
            var fragComp = URLComponents()
            fragComp.query = fragment
            for key in queryKeys {
                if let value = fragComp.queryItems?.first(where: { $0.name == key })?.value,
                   isBase62RecoveryCode(value) {
                    return value
                }
            }
        }
    }

    guard let regex = try? NSRegularExpression(pattern: "\\b[0-9A-Za-z]{16,64}\\b") else { return nil }
    let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
    for match in regex.matches(in: trimmed, range: range) {
        guard let r = Range(match.range, in: trimmed) else { continue }
        let token = String(trimmed[r])
        if isBase62RecoveryCode(token) { return token }
    }
    return nil
}

func resolveGeneralQRScanPayload(_ raw: String, filter: GeneralQRScanFilter) -> String? {
    switch filter {
    case .anyText:
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    case .recoveryCodeOnly:
        return recoveryCodeCandidate(from: raw)
    }
}

// MARK: - Scanner UI

final class GeneralQRScannerViewController: UIViewController,
    AVCaptureMetadataOutputObjectsDelegate,
    PHPickerViewControllerDelegate,
    UIDocumentPickerDelegate
{
    var filter: GeneralQRScanFilter = .anyText
    var onSuccess: ((String) -> Void)?
    var onFailure: ((GeneralQRScanFailure) -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var metadataOutput: AVCaptureMetadataOutput?
    private var scanSquareFrame: CGRect = .zero

    private let overlayContainer = UIView()
    private let titleLabel = UILabel()
    private let hintLabel = UILabel()
    private let chooseFileButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let squareBorderLayer = CAShapeLayer()

    private var didFinish = false
    private var cameraRunning = false
    private var pickingFromLibrary = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureChrome()
        configureCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        layoutScanOverlay()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopCamera()
        // Only treat as user cancel when the scanner is going away without a finished result.
        guard !didFinish, !pickingFromLibrary else { return }
        guard isBeingDismissed || isMovingFromParent || navigationController?.isBeingDismissed == true else {
            return
        }
        didFinish = true
        onFailure?(.cancelled)
    }

    // MARK: Camera

    private func configureCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupCaptureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.setupCaptureSession()
                    } else {
                        self?.finishFailure(.cameraPermissionDenied)
                    }
                }
            }
        default:
            finishFailure(.cameraPermissionDenied)
        }
    }

    private func setupCaptureSession() {
        guard previewLayer == nil else {
            startCamera()
            return
        }
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            finishFailure(.cameraUnavailable)
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            finishFailure(.cameraUnavailable)
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        output.metadataObjectTypes = [.qr]
        metadataOutput = output

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        previewLayer = layer

        startCamera()
    }

    private func startCamera() {
        guard !cameraRunning else { return }
        cameraRunning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    private func stopCamera() {
        cameraRunning = false
        if session.isRunning {
            session.stopRunning()
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !didFinish, !pickingFromLibrary,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let raw = object.stringValue,
              let resolved = resolveGeneralQRScanPayload(raw, filter: filter)
        else { return }
        finishSuccess(resolved)
    }

    // MARK: Overlay chrome

    private func applyChrome(
        to button: UIButton,
        title: String,
        font: UIFont,
        foreground: UIColor,
        background: UIColor,
        cornerRadius: CGFloat,
        contentInsets: NSDirectionalEdgeInsets
    ) {
        var config = UIButton.Configuration.plain()
        config.title = title
        config.baseForegroundColor = foreground
        config.background.backgroundColor = background
        config.background.cornerRadius = cornerRadius
        config.contentInsets = contentInsets
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = font
            return outgoing
        }
        button.configuration = config
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureChrome() {
        overlayContainer.backgroundColor = .clear
        overlayContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlayContainer)
        NSLayoutConstraint.activate([
            overlayContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlayContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlayContainer.topAnchor.constraint(equalTo: view.topAnchor),
            overlayContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        applyChrome(
            to: cancelButton,
            title: "Cancel",
            font: .systemFont(ofSize: 17, weight: .semibold),
            foreground: .white,
            background: UIColor.black.withAlphaComponent(0.45),
            cornerRadius: 18,
            contentInsets: NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
        )
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        overlayContainer.addSubview(cancelButton)

        titleLabel.text = "Scan QR Code"
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        overlayContainer.addSubview(titleLabel)

        hintLabel.text = "Align the code within the square"
        hintLabel.textColor = UIColor.white.withAlphaComponent(0.82)
        hintLabel.font = .systemFont(ofSize: 14, weight: .medium)
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 0
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        overlayContainer.addSubview(hintLabel)

        applyChrome(
            to: chooseFileButton,
            title: "Choose Photo or File",
            font: .systemFont(ofSize: 17, weight: .semibold),
            foreground: .white,
            background: UIColor(red: 21 / 255, green: 98 / 255, blue: 240 / 255, alpha: 0.92),
            cornerRadius: 14,
            contentInsets: NSDirectionalEdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20)
        )
        chooseFileButton.addTarget(self, action: #selector(chooseFileTapped), for: .touchUpInside)
        overlayContainer.addSubview(chooseFileButton)

        NSLayoutConstraint.activate([
            cancelButton.leadingAnchor.constraint(equalTo: overlayContainer.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            cancelButton.topAnchor.constraint(equalTo: overlayContainer.safeAreaLayoutGuide.topAnchor, constant: 12),
            titleLabel.centerXAnchor.constraint(equalTo: overlayContainer.centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: overlayContainer.safeAreaLayoutGuide.topAnchor, constant: 20),
            hintLabel.leadingAnchor.constraint(equalTo: overlayContainer.leadingAnchor, constant: 28),
            hintLabel.trailingAnchor.constraint(equalTo: overlayContainer.trailingAnchor, constant: -28),
            hintLabel.bottomAnchor.constraint(equalTo: chooseFileButton.topAnchor, constant: -18),
            chooseFileButton.leadingAnchor.constraint(equalTo: overlayContainer.leadingAnchor, constant: 24),
            chooseFileButton.trailingAnchor.constraint(equalTo: overlayContainer.trailingAnchor, constant: -24),
            chooseFileButton.bottomAnchor.constraint(equalTo: overlayContainer.safeAreaLayoutGuide.bottomAnchor, constant: -20),
        ])
    }

    private func layoutScanOverlay() {
        let side = min(view.bounds.width, view.bounds.height) * 0.68
        let originX = (view.bounds.width - side) / 2
        let originY = (view.bounds.height - side) / 2 - 28
        scanSquareFrame = CGRect(x: originX, y: max(originY, 120), width: side, height: side)

        overlayContainer.layer.sublayers?
            .filter { $0.name == "ct_qr_dim" || $0.name == "ct_qr_blur" }
            .forEach { $0.removeFromSuperlayer() }

        let dimPath = UIBezierPath(rect: overlayContainer.bounds)
        dimPath.append(UIBezierPath(roundedRect: scanSquareFrame, cornerRadius: 14))
        dimPath.usesEvenOddFillRule = true

        let dimLayer = CAShapeLayer()
        dimLayer.name = "ct_qr_dim"
        dimLayer.path = dimPath.cgPath
        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = UIColor.black.withAlphaComponent(0.52).cgColor
        overlayContainer.layer.insertSublayer(dimLayer, at: 0)

        let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        blurView.frame = overlayContainer.bounds
        blurView.alpha = 0.28
        blurView.isUserInteractionEnabled = false
        blurView.tag = 9101
        overlayContainer.viewWithTag(9101)?.removeFromSuperview()
        overlayContainer.insertSubview(blurView, at: 0)

        let blurMask = CAShapeLayer()
        blurMask.path = dimPath.cgPath
        blurMask.fillRule = .evenOdd
        blurView.layer.mask = blurMask

        squareBorderLayer.path = UIBezierPath(roundedRect: scanSquareFrame, cornerRadius: 14).cgPath
        squareBorderLayer.strokeColor = UIColor.white.withAlphaComponent(0.95).cgColor
        squareBorderLayer.fillColor = UIColor.clear.cgColor
        squareBorderLayer.lineWidth = 2
        if squareBorderLayer.superlayer == nil {
            overlayContainer.layer.addSublayer(squareBorderLayer)
        }

        if let output = metadataOutput, let preview = previewLayer {
            output.rectOfInterest = preview.metadataOutputRectConverted(fromLayerRect: scanSquareFrame)
        }
    }

    // MARK: Actions

    @objc private func cancelTapped() {
        finishFailure(.cancelled)
    }

    @objc private func chooseFileTapped() {
        stopCamera()
        pickingFromLibrary = true
        let sheet = UIAlertController(title: "Choose QR Image", message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Photo Library", style: .default) { [weak self] _ in
            self?.presentPhotoPicker()
        })
        sheet.addAction(UIAlertAction(title: "Browse Files", style: .default) { [weak self] _ in
            self?.presentDocumentPicker()
        })
        sheet.addAction(UIAlertAction(title: "Back to Camera", style: .cancel) { [weak self] _ in
            self?.pickingFromLibrary = false
            self?.startCamera()
        })
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = chooseFileButton
            popover.sourceRect = chooseFileButton.bounds
        }
        present(sheet, animated: true)
    }

    private func presentPhotoPicker() {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func presentDocumentPicker() {
        let types: [UTType] = [.image, .jpeg, .png, .heic, .gif]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true) { [weak self] in
            guard let self else { return }
            guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else {
                self.pickingFromLibrary = false
                self.startCamera()
                return
            }
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                DispatchQueue.main.async {
                    self.handlePickedImage(object as? UIImage)
                }
            }
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        controller.dismiss(animated: true) { [weak self] in
            guard let self, let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            let image = UIImage(contentsOfFile: url.path)
            self.handlePickedImage(image)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        controller.dismiss(animated: true) { [weak self] in
            self?.pickingFromLibrary = false
            self?.startCamera()
        }
    }

    private func handlePickedImage(_ image: UIImage?) {
        pickingFromLibrary = false
        guard let image else {
            showQrNotFoundAlert()
            return
        }
        let payloads = qrCodePayloads(from: image)
        for raw in payloads {
            if let resolved = resolveGeneralQRScanPayload(raw, filter: filter) {
                finishSuccess(resolved)
                return
            }
        }
        showQrNotFoundAlert()
    }

    private func showQrNotFoundAlert() {
        let message = filter == .recoveryCodeOnly
            ? "No recovery QR code was found in that image."
            : "No QR code was found in that image."
        let alert = UIAlertController(title: "QR Not Found", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Try Again", style: .default) { [weak self] _ in
            self?.startCamera()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.finishFailure(.qrNotFound)
        })
        present(alert, animated: true)
    }

    // MARK: Finish

    /// Dismiss scanner and any sheet/picker/alert it presented, then return control to the WebView host.
    private func closeScannerReturningToHost(completion: @escaping () -> Void) {
        stopCamera()
        if let presented = presentedViewController {
            presented.dismiss(animated: false) { [weak self] in
                self?.closeScannerReturningToHost(completion: completion)
            }
            return
        }
        if let host = presentingViewController {
            host.dismiss(animated: true, completion: completion)
            return
        }
        dismiss(animated: true, completion: completion)
    }

    private func finishSuccess(_ text: String) {
        guard !didFinish else { return }
        didFinish = true
        let payload = text
        closeScannerReturningToHost { [weak self] in
            self?.onSuccess?(payload)
        }
    }

    private func finishFailure(_ failure: GeneralQRScanFailure) {
        guard !didFinish else { return }
        didFinish = true
        let err = failure
        closeScannerReturningToHost { [weak self] in
            self?.onFailure?(err)
        }
    }
}
