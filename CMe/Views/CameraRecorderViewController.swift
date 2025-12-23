import UIKit
import AVFoundation
import Photos
import CoreVideo
import CoreImage
import MediaPipeTasksVision

protocol CameraRecorderDelegate: AnyObject {
    func didFinishRecording(rawVideoURL: URL, heatmapVideoURL: URL?, landmarksJSONURL: URL?)
}

final class CameraRecorderViewController: UIViewController,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureFileOutputRecordingDelegate {

    weak var delegate: CameraRecorderDelegate?
    var viewModel: VideoProcessingViewModel?
    /// "eye", "smile", "tongue", etc. (used for ROI selection in PyDIC)
    var selectedAudio: String = ""

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureMovieFileOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer?

    private var outputURL: URL?
    private var pulseLayer: CAShapeLayer?

    private let recordButton = UIButton(type: .custom)
    private let timerLabel = UILabel()
    private var recordingTimer: Timer?
    private var secondsElapsed = 0

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var lastUIUpdate: CFTimeInterval = 0

    private let heatmapView = UIImageView()
    private let heatmapProcessor = HeatmapProcessor()

    // Live-output writers
    private var heatmapVideoCreator: VideoCreator?
    private var heatmapVideoURL: URL?

    private var landmarksWriter: LandmarksJSONWriter?
    private var landmarksJSONURL: URL?
    private var heatmapFrameIndex: Int = 0
    private var recordingStartMs: Int = 0
    
    private let audioRecognizer = AudioCommandRecognizer()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        // Configure ROI type for PyDIC
        heatmapProcessor.roiFeatureType = selectedAudio
        
        audioRecognizer.onCommandDetected = { [weak self] command, timestampMs in
                guard let self else { return }

                // 1) Update ROI based on the command ("eye", "smile", "tongue", ...)
                self.heatmapProcessor.roiFeatureType = command

                // 2) Tell the heatmap baseline logic that an audio command occurred now
                self.heatmapProcessor.notifyAudioCommandDetected(at: timestampMs)
            }

        setupAudioSession()
        configureSession()
        setupUI()
        setupHeatmapView()
        setupHeatmapRecordingCallback()

        view.bringSubviewToFront(recordButton)
        view.bringSubviewToFront(timerLabel)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        pulseLayer?.position = recordButton.center
    }

    // MARK: - Audio session

    private func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord,
                                    mode: .videoRecording,
                                    options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            print("Audio session error: \(error)")
        }
    }

    // MARK: - Capture session

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .high

        guard let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: cam),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)

        if let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput) {
            session.addInput(micInput)
        }

        videoDataOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.setSampleBufferDelegate(
            self,
            queue: DispatchQueue(label: "video.buffer.queue", qos: .userInitiated)
        )
        if session.canAddOutput(videoDataOutput) { session.addOutput(videoDataOutput) }
        videoDataOutput.connection(with: .video)?.videoOrientation = .portrait

        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        videoOutput.connection(with: .video)?.videoOrientation = .portrait

        session.commitConfiguration()

        let pl = AVCaptureVideoPreviewLayer(session: session)
        pl.videoGravity = .resizeAspectFill
        pl.frame = view.bounds
        view.layer.addSublayer(pl)
        previewLayer = pl

        session.startRunning()
    }

    // MARK: - UI

    private func setupUI() {
        recordButton.backgroundColor = .red
        recordButton.layer.cornerRadius = 35
        recordButton.layer.borderColor = UIColor.white.withAlphaComponent(0.8).cgColor
        recordButton.layer.borderWidth = 3
        recordButton.translatesAutoresizingMaskIntoConstraints = false
        recordButton.addTarget(self, action: #selector(toggleRecording), for: .touchUpInside)
        view.addSubview(recordButton)

        timerLabel.text = "00:00"
        timerLabel.textColor = .white
        timerLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        timerLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(timerLabel)

        NSLayoutConstraint.activate([
            recordButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            recordButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -40),
            recordButton.widthAnchor.constraint(equalToConstant: 70),
            recordButton.heightAnchor.constraint(equalToConstant: 70),

            timerLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            timerLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])

        let layer = CAShapeLayer()
        layer.path = UIBezierPath(ovalIn: CGRect(x: -45, y: -45, width: 90, height: 90)).cgPath
        layer.position = recordButton.center
        layer.fillColor = UIColor.red.withAlphaComponent(0.3).cgColor
        layer.opacity = 0
        view.layer.insertSublayer(layer, below: recordButton.layer)
        pulseLayer = layer
    }

    private func setupHeatmapView() {
        let halfH = view.bounds.height / 2
        heatmapView.contentMode = .scaleAspectFit
        heatmapView.clipsToBounds = true
        heatmapView.backgroundColor = UIColor.black.withAlphaComponent(0.9)
        heatmapView.layer.cornerRadius = 16
        heatmapView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(heatmapView)

        NSLayoutConstraint.activate([
            heatmapView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            heatmapView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            heatmapView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            heatmapView.heightAnchor.constraint(equalToConstant: halfH)
        ])
        view.bringSubviewToFront(recordButton)
        view.bringSubviewToFront(timerLabel)
    }

    /// Hook: when HeatmapProcessor finishes a frame, write video + landmarks if recording.
    private func setupHeatmapRecordingCallback() {
        heatmapProcessor.onHeatmapFrame = { [weak self] image, values, points in
            guard let self else { return }
            guard self.videoOutput.isRecording else { return }

            self.heatmapFrameIndex += 1
            let nowMs = Int(Date().timeIntervalSince1970 * 1000)
            let base = self.recordingStartMs == 0 ? nowMs : self.recordingStartMs
            let ts = nowMs - base

            self.heatmapVideoCreator?.addImageToVideo(image: image)
            self.landmarksWriter?.append(
                frameIndex: self.heatmapFrameIndex,
                timestampMs: ts,
                values: values,
                points: points
            )
        }
    }

    // MARK: - Recording controls

    @objc private func toggleRecording() {
        videoOutput.isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        recordingStartMs = Int(Date().timeIntervalSince1970 * 1000)
        heatmapFrameIndex = 0

        do {
            try audioRecognizer.startListening()
        } catch {
            print("Audio startListening error:", error)
        }
        
        // Raw camera video
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rec_\(UUID().uuidString).mov")
        outputURL = tmp
        try? FileManager.default.removeItem(at: tmp)
        print("RECORD_START url=\(tmp.lastPathComponent)")
        videoOutput.startRecording(to: tmp, recordingDelegate: self)

        // Heatmap video writer (same size as live panel)
        let heatURL = generateOutputPath()
        heatmapVideoURL = heatURL
        heatmapVideoCreator = VideoCreator(
            outputURL: heatURL,
            width: 540,
            height: 960,
            fps: 15
        )

        // ✅ Landmarks JSON writer – save into Documents instead of tmp
        let jsonName = "CMe_Landmarks_\(Int(Date().timeIntervalSince1970)).json"

        // get app's Documents directory (visible in Files app → On My iPhone → CMe)
        let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let jsonURL = docsURL.appendingPathComponent(jsonName)

        print("Will write landmarks JSON to: \(jsonURL.path)")

        do {
            landmarksWriter = try LandmarksJSONWriter(fileURL: jsonURL)
            landmarksJSONURL = jsonURL
        } catch {
            print("Failed to create landmarks writer:", error.localizedDescription)
            landmarksWriter = nil
            landmarksJSONURL = nil
        }

        startPulse()
        secondsElapsed = 0
        timerLabel.text = "00:00"
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.secondsElapsed += 1
            self.timerLabel.text = String(
                format: "%02d:%02d",
                self.secondsElapsed / 60,
                self.secondsElapsed % 60
            )
        }
    }


    private func stopRecording() {
        guard videoOutput.isRecording else { return }
        videoOutput.stopRecording()
        stopPulse()
        recordingTimer?.invalidate()
        recordingTimer = nil
        
        audioRecognizer.stopListening()
    }

    private func startPulse() {
        guard let layer = pulseLayer else { return }
        let anim = CABasicAnimation(keyPath: "transform.scale")
        anim.fromValue = 1
        anim.toValue = 1.6
        anim.duration = 0.8
        anim.autoreverses = true
        anim.repeatCount = .infinity
        layer.opacity = 1
        layer.add(anim, forKey: "pulse")
    }

    private func stopPulse() {
        pulseLayer?.removeAllAnimations()
        pulseLayer?.opacity = 0
    }

    // MARK: - Capture delegate (live heatmap)

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let ci = CIImage(cvImageBuffer: pb)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }
        let frame = UIImage(cgImage: cg)

        let now = CACurrentMediaTime()
        if now - lastUIUpdate > 0.15 {
            lastUIUpdate = now
            heatmapProcessor.processFrame(frame)
        }

        if let liveHeat = heatmapProcessor.heatmapImage {
            DispatchQueue.main.async {
                self.heatmapView.image = liveHeat
            }
        }
    }

    // MARK: - Recording finished

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo url: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        if let error = error {
            print("Recording error: \(error)")
            heatmapVideoCreator = nil
            landmarksWriter?.finish()
            landmarksWriter = nil
            return
        }

        print("RECORD_DONE url=\(url.lastPathComponent)")
        let rawURL = url
        let heatURL = heatmapVideoURL
        let jsonURL = landmarksJSONURL

        // Stop landmarks JSON
        landmarksWriter?.finish()
        landmarksWriter = nil

        // Save raw video
        PHPhotoLibrary.requestAuthorization { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: rawURL)
            })
        }

        // Finish & save heatmap video
        heatmapVideoCreator?.finish { [weak self] success in
            guard let self else { return }
            print("Heatmap video finish:", success)

            if success, let creator = self.heatmapVideoCreator {
                creator.saveVideoToPhotoLibrary { result in
                    switch result {
                    case .success:
                        print("Heatmap video saved to Photos.")
                    case .failure(let err):
                        print("Failed to save heatmap video:", err.localizedDescription)
                    }
                }
            }

            DispatchQueue.main.async {
                self.delegate?.didFinishRecording(
                    rawVideoURL: rawURL,
                    heatmapVideoURL: heatURL,
                    landmarksJSONURL: jsonURL
                )
                
                if let jsonURL = jsonURL {
                    let activityVC = UIActivityViewController(
                        activityItems: [jsonURL],
                        applicationActivities: nil
                    )
                    activityVC.popoverPresentationController?.sourceView = self.view
                    self.present(activityVC, animated: true)
                }

            }

            self.heatmapVideoCreator = nil
        }
    }
}
