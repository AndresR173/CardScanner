//
//  CardScannerViewController.swift
//  CardScanner
//
//  Created by Andres Rojas on 6/08/20.
//

import UIKit
import AVFoundation
import Vision

class CardScannerViewController: UIViewController {

    private let captureSession = AVCaptureSession()
    private lazy var previewLayer: AVCaptureVideoPreviewLayer = {
        let preview = AVCaptureVideoPreviewLayer(session: self.captureSession)
        preview.videoGravity = .resizeAspectFill
        return preview
    }()
    private let videoOutput = AVCaptureVideoDataOutput()

    private let requestHandler = VNSequenceRequestHandler()

    private var paymentCardRectangleObservation: VNRectangleObservation?

    private let PROCESSING_QUEUE = "camera_processing_queue"

    private lazy var closeButton: UIImageView = {
        let imageView = UIImageView(image: UIImage(systemName: "xmark.circle.fill"))
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.isUserInteractionEnabled = true
        imageView.tintColor = UIColor.white.withAlphaComponent(0.7)

        return imageView
    }()

    private lazy var previewContainer: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false

        return view
    }()

    private lazy var creditCardFrame: UIImageView = {
        let imageView = UIImageView(image: #imageLiteral(resourceName: "creditCardFrame"))
        imageView.translatesAutoresizingMaskIntoConstraints = false

        return imageView
    }()

    // MARK: - Initializers
    override func viewDidLoad() {
        super.viewDidLoad()
        self.setupAVCapture()
        setupUI()
        self.captureSession.startRunning()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        self.previewLayer.frame = self.view.bounds
    }

    // MARK: - Helpers

    private func setupUI() {
        view.addSubview(previewContainer)
        view.addSubview(closeButton)
        view.addSubview(creditCardFrame)
        closeButton.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(closeModal)))

        NSLayoutConstraint.activate([
            closeButton.heightAnchor.constraint(equalToConstant: 24),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.topAnchor.constraint(equalTo: view.readableContentGuide.topAnchor, constant: 8),
            closeButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            previewContainer.topAnchor.constraint(equalTo: view.topAnchor),
            previewContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            previewContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            creditCardFrame.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            creditCardFrame.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            creditCardFrame.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            creditCardFrame.heightAnchor.constraint(equalTo: creditCardFrame.widthAnchor, multiplier: 0.63)
        ])
    }

    @objc private func closeModal() {
        previewLayer.removeFromSuperlayer()
        captureSession.stopRunning()
        dismiss(animated: true)
    }
}

// MARK: - Camera Setup

extension CardScannerViewController {
    func setupAVCapture() {
        var deviceInput: AVCaptureDeviceInput!

        guard let videoDevice = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera],
                                                                 mediaType: .video,
                                                                 position: .back).devices.first else { return }
        do {
            deviceInput = try AVCaptureDeviceInput(device: videoDevice)
        } catch {
            print("Could not create video device input: \(error)")
            return
        }

        captureSession.beginConfiguration()

        guard captureSession.canAddInput(deviceInput) else {
            print("Could not add video device input to the session")
            captureSession.commitConfiguration()
            return
        }

        self.captureSession.addInput(deviceInput)

        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
            videoOutput.alwaysDiscardsLateVideoFrames = true
            self.videoOutput.videoSettings = [(kCVPixelBufferPixelFormatTypeKey as NSString) : NSNumber(value: kCVPixelFormatType_32BGRA)] as [String : Any]
            videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: PROCESSING_QUEUE))
        }

        let captureConnection = videoOutput.connection(with: .video)
        // Always process the frames
        captureConnection?.isEnabled = true
        captureConnection?.videoOrientation = .portrait

        captureSession.commitConfiguration()
        previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        self.previewContainer.layer.addSublayer(self.previewLayer)
        previewLayer.videoGravity = AVLayerVideoGravity.resizeAspectFill
        previewLayer.frame = previewContainer.bounds
    }
}

// MARK: Card Detection

extension CardScannerViewController {
    private func handleObservedPaymentCard(for observation: VNRectangleObservation, in frame: CVImageBuffer) {
        let request = VNTrackRectangleRequest(rectangleObservation: observation)
        request.trackingLevel = .fast

        try? self.requestHandler.perform([request], on: frame)

        guard let _ = (request.results as? [VNRectangleObservation])?.first else {
            self.paymentCardRectangleObservation = nil
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let (extractedNumber, expirationDate) = self.extractPaymentCardNumber(frame: frame, rectangle: observation)
            DispatchQueue.main.async {
                debugPrint("Card: \(extractedNumber ?? "") Expires: \(expirationDate ?? "")")
                //                            self.resultsHandler(extractedNumber)   b
            }
        }
    }

    private func extractPaymentCardNumber(frame: CVImageBuffer, rectangle: VNRectangleObservation) -> (String?,String?) {
        let cardPositionInImage = VNImageRectForNormalizedRect(rectangle.boundingBox, CVPixelBufferGetWidth(frame), CVPixelBufferGetHeight(frame))
        let ciImage = CIImage(cvImageBuffer: frame)
        let croppedImage = ciImage.cropped(to: cardPositionInImage)

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false

        let stillImageRequestHandler = VNImageRequestHandler(ciImage: croppedImage, options: [:])
        try? stillImageRequestHandler.perform([request])

        guard let texts = request.results as? [VNRecognizedTextObservation], texts.count > 0 else {
            // no text detected
            return (nil, nil)
        }

        let digitsRecognized = texts
            .flatMap({ $0.topCandidates(10).map({ $0.string }) })
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .map{ $0.replacingOccurrences(of: " ", with: "")}
            .filter({$0.count == 16})
            .filter({ CharacterSet.decimalDigits.isSuperset(of: CharacterSet(charactersIn: $0)) })

        guard let validNumber = digitsRecognized.first else { return (nil, nil) }

        let expirationRecognized = texts
            .flatMap({ $0.topCandidates(10).map({ $0.string as NSString }) })
            .compactMap({ getExpirationDate(from: $0) })
            .filter({ !$0.isEmpty }).first

        return (validNumber, expirationRecognized)
    }

    private func getExpirationDate(from string: NSString) -> String? {
        let pattern = "^(0[1-9]|1[0-2])\\/?([0-9]{4}|[0-9]{2})$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let matches = regex.matches(in: string as String, options: [],
                      range: NSRange(location: 0,
                                     length: string.length))
        let substrings = matches.map { string.substring(with: $0.range) }
        return substrings.first
    }

    private func checkDigits(_ digits: String) -> Bool {
        guard digits.count == 16, CharacterSet.decimalDigits.isSuperset(of: CharacterSet(charactersIn: digits)) else {
            return false
        }
        var digits = digits
        let checksum = digits.removeLast()
        let sum = digits.reversed()
            .enumerated()
            .map({ (index, element) -> Int in
                if (index % 2) == 0 {
                    let doubled = Int(String(element))!*2
                    return doubled > 9
                        ? Int(String(String(doubled).first!))! + Int(String(String(doubled).last!))!
                        : doubled
                } else {
                    return Int(String(element))!
                }
            })
            .reduce(0, { (res, next) in res + next })
        let checkDigitCalc = (sum * 9) % 10
        return Int(String(checksum))! == checkDigitCalc
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
//
extension CardScannerViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let frame = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        if let paymentCardRectangleObservation = self.paymentCardRectangleObservation {
            self.handleObservedPaymentCard(for: paymentCardRectangleObservation, in: frame)
        } else if let paymentCardRectangleObservation = self.detectPaymentCard(frame: frame) {
            self.paymentCardRectangleObservation = paymentCardRectangleObservation
        }
    }
}

// MARK: - Image Processing

extension CardScannerViewController {
    private func detectPaymentCard(frame: CVImageBuffer) -> VNRectangleObservation? {
        let rectangleDetectionRequest = VNDetectRectanglesRequest()
        rectangleDetectionRequest.minimumAspectRatio =  VNAspectRatio(1.3)
        rectangleDetectionRequest.maximumAspectRatio = VNAspectRatio(1.7)
        rectangleDetectionRequest.minimumSize = Float(0.3)
        rectangleDetectionRequest.minimumConfidence = 0.9
        rectangleDetectionRequest.quadratureTolerance = 15

        let textDetectionRequest = VNDetectTextRectanglesRequest()

        try? self.requestHandler.perform([rectangleDetectionRequest, textDetectionRequest], on: frame)

        guard let rectangle = (rectangleDetectionRequest.results as? [VNRectangleObservation])?.first,
              let text = (textDetectionRequest.results as? [VNTextObservation])?.first,
              rectangle.boundingBox.contains(text.boundingBox) else {
            // no credit card rectangle detected
            return nil
        }

        return rectangle
    }
}

