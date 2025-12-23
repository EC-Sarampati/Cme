import UIKit
import CoreVideo
import MediaPipeTasksVision
import CoreImage

final class HeatmapProcessor: ObservableObject {
    @Published var heatmapImage: UIImage?

    private var service: FaceLandmarkerService?
    private var landmarker: FaceLandmarker?
    private let ciContext = CIContext()

    // For stabilizing live heatmaps
    private var previousGrayImage: UIImage?
    private var previousMask: CVPixelBuffer?
    private var previousHeatmap: [[Double?]]?

    // Smoothing & threshold params
    private let smoothingAlpha: Double = 0.3
    private let motionFloor: Double = 0.015

    /// ROI label: "eye", "smile", "tongue", etc. (used only for landmark selection)
    var roiFeatureType: String = ""

    /// Called whenever a new heatmap frame is ready (on main).
    /// We pass: heatmap image, landmark values, landmark points.
    var onHeatmapFrame: ((UIImage, [Double], [[Int]]) -> Void)?
    
    // MARK: - Baseline / audio-aware state

    /// Simple buffer entry for recent frames (used to pick baseline 5s before audio)
    private struct BufferedFrame {
        let timestampMs: Int
        let grayImage: UIImage
    }

    /// Circular-ish buffer of recent frames (last few seconds)
    private var frameBuffer: [BufferedFrame] = []

    /// How long (in ms) of history to keep in the buffer.
    /// 7000 ms = 7 seconds, enough to pick "5 seconds before audio".
    private let maxBufferDurationMs: Int = 7000

    /// Baseline (reference) gray image once selected.
    /// When this is non-nil, DIC uses this as reference for all future frames.
    private var baselineGrayImage: UIImage?

    /// Timestamp (ms since epoch or since recording start) at which audio command was detected.
    private var audioCommandTimeMs: Int?


    init() { setupLandmarker() }

    private func setupLandmarker() {
        guard
            let modelPath = Bundle.main.path(forResource: "face_landmarker", ofType: "task"),
            let svc = FaceLandmarkerService.videoLandmarkerService(
                modelPath: modelPath,
                numFaces: 1,
                minFaceDetectionConfidence: 0.5,
                minFacePresenceConfidence: 0.5,
                minTrackingConfidence: 0.3,
                runningMode: .image
            )
        else {
            print("Failed to init HeatmapProcessor")
            return
        }
        service = svc
        landmarker = svc.faceLandmarker
    }

    // MARK: - Main entry point from camera

    func processFrame(_ frame: UIImage) {
        guard let landmarker else { return }

        Task.detached { [weak self] in
            guard let self else { return }

            do {
                let mpImage = try MPImage(uiImage: frame)
                let result = try landmarker.detect(
                    videoFrame: mpImage,
                    timestampInMilliseconds: Int(Date().timeIntervalSince1970 * 1000)
                )

                guard let landmarks = result.faceLandmarks.first else { return }

                // Build ROI feature points for PyDIC (does NOT affect big heatmap)
                let featurePoints: [[Int]]
//                if self.roiFeatureType == "eye" ||
//                    self.roiFeatureType == "smile" ||
//                    self.roiFeatureType == "tongue" {
//                    featurePoints = landmarksToFeature(
//                        imageSize: frame.size,
//                        landmarks: landmarks,
//                        featureType: self.roiFeatureType
//                    ) ?? []
//                } else {
//                    // fallback: all landmarks
//                    featurePoints = allLandmarksToFeatures(
//                        imageSize: frame.size,
//                        landmarks: landmarks
//                    )
//                } chay: considering all the facial landmarks
                
                featurePoints = allLandmarksToFeatures(
                    imageSize: frame.size,
                    landmarks: landmarks
                )

                // Grayscale + face mask
                guard
                    let gray = convertToGrayscale(image: frame),
                    let maskBuffer = landmarksToFaceMask(
                        imageSize: frame.size,
                        landmarks: landmarks
                    )
                else {
                    return
                }

                let refGrayImage = self.selectReferenceGray(currentGray: gray)

                let refMaskedCI = applyMask(image: refGrayImage, mask: maskBuffer)
                let curMaskedCI = applyMask(image: gray, mask: maskBuffer)

                let (landmarkValues, rawHeatmap, landmarkPts) = runPydic(
                    imgList: [refMaskedCI, curMaskedCI],
                    mask: maskBuffer,
                    ptsList: featurePoints
                )

                // Smooth & threshold heatmap
                let smoothed = self.smoothHeatmap(
                    previous: self.previousHeatmap,
                    current: rawHeatmap,
                    alpha: self.smoothingAlpha
                )
                let thresholded = self.applyMotionFloor(
                    to: smoothed,
                    floor: self.motionFloor
                )

                if let heatImg = createBGRImageFromGrayMatrix(
                    grayMatrix: transpose(matrix: thresholded)
                ) {
                    let corrected = self.fixHeatmapOrientation(heatImg)
                    let display = resizeImage(
                        corrected,
                        toSize: CGSize(width: 540, height: 960)
                    ) ?? corrected

                    await MainActor.run {
                        
                        self.heatmapImage = display
                        
                        self.onHeatmapFrame?(display, landmarkValues, landmarkPts)
                    }
                }

                self.previousGrayImage = gray
                self.previousMask = maskBuffer
                self.previousHeatmap = thresholded

            } catch {
                print("Heatmap frame error:", error.localizedDescription)
            }
        }
    }

    // MARK: - Reference frame selection (CURRENT STRATEGY)
    //
    // This preserves the existing behaviour exactly:
    // reference = previousGrayImage if available, otherwise current frame.
    // Later you can comment this out and paste an alternative implementation
    // (e.g. "5 seconds before audio") with the same signature.

    private func selectReferenceGray(currentGray: UIImage) -> UIImage {
        return previousGrayImage ?? currentGray
    }
//    } chay: this is comparing the previous frame.
    
    // MARK: - Reference frame selection (VERSION A)
    // Baseline = frame ~5 seconds before audio command (if any),
    // otherwise fallback to previous behaviour (previousGrayImage vs current).

//    private func selectReferenceGray(currentGray: UIImage) -> UIImage {
//        // 1) Compute a timestamp for this frame (same time base as audio).
//        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
//
//        // 2) Append this frame to our short history buffer.
//        frameBuffer.append(BufferedFrame(timestampMs: nowMs, grayImage: currentGray))
//
//        // Prune old frames older than maxBufferDurationMs.
//        let cutoff = nowMs - maxBufferDurationMs
//        frameBuffer.removeAll { $0.timestampMs < cutoff }
//
//        // 3) If we already chose a baseline, always use it.
//        if let baseline = baselineGrayImage {
//            return baseline
//        }
//
//        // 4) If we know when audio occurred, try to pick a baseline ≈ 5s before it.
//        if let cmdTime = audioCommandTimeMs {
//            let target = cmdTime - 5000  // 5 seconds before command
//
//            // Candidates: frames whose timestamp <= target.
//            let candidates = frameBuffer.filter { $0.timestampMs <= target }
//
//            // Pick the frame closest to target (or fall back to earliest buffered frame).
//            if let chosen = candidates.min(by: {
//                abs($0.timestampMs - target) < abs($1.timestampMs - target)
//            }) ?? frameBuffer.first {
//                baselineGrayImage = chosen.grayImage
//                return chosen.grayImage
//            }
//        }
//
//        // 5) No audio yet or no suitable baseline frame:
//        //    behave exactly like old code (frame-to-frame).
//        return previousGrayImage ?? currentGray
//    }

    
    // MARK: - Reference frame selection (VERSION B)
    // Baseline = first valid frame if no audio yet;
    // if audio command arrives, switch baseline to frame ~5s before audio.

//    private func selectReferenceGray(currentGray: UIImage) -> UIImage {
//        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
//
//        // Maintain rolling buffer of recent frames.
//        frameBuffer.append(BufferedFrame(timestampMs: nowMs, grayImage: currentGray))
//        let cutoff = nowMs - maxBufferDurationMs
//        frameBuffer.removeAll { $0.timestampMs < cutoff }
//
//        // 1) If we already have a baseline, use it.
//        if let baseline = baselineGrayImage {
//            return baseline
//        }
//
//        // 2) If we know an audio time, try to select frame ≈ 5s before.
//        if let cmdTime = audioCommandTimeMs {
//            let target = cmdTime - 5000
//
//            let candidates = frameBuffer.filter { $0.timestampMs <= target }
//            if let chosen = candidates.min(by: {
//                abs($0.timestampMs - target) < abs($1.timestampMs - target)
//            }) ?? frameBuffer.first {
//                baselineGrayImage = chosen.grayImage
//                return chosen.grayImage
//            }
//        }
//
//        // 3) No audio yet and no baseline: default to "first valid frame" as baseline.
//        baselineGrayImage = currentGray
//        return currentGray
//    }


    // MARK: - Orientation Fix Helper

    private func fixHeatmapOrientation(_ image: UIImage) -> UIImage {
        return UIImage(cgImage: image.cgImage!, scale: 1.0, orientation: .upMirrored)
    }

    // MARK: - Heatmap smoothing helpers

    private func smoothHeatmap(previous: [[Double?]]?,
                               current: [[Double?]],
                               alpha: Double) -> [[Double?]] {
        guard let previous = previous,
              previous.count == current.count,
              previous.first?.count == current.first?.count
        else {
            return current
        }

        var result = current
        let rows = current.count
        let cols = current[0].count

        for i in 0..<rows {
            for j in 0..<cols {
                let p = previous[i][j] ?? 0.0
                let c = current[i][j] ?? 0.0
                let value = alpha * c + (1.0 - alpha) * p
                result[i][j] = value
            }
        }
        return result
    }

    private func applyMotionFloor(to heatmap: [[Double?]], floor: Double) -> [[Double?]] {
        var result = heatmap
        let rows = heatmap.count
        guard rows > 0 else { return result }
        let cols = heatmap[0].count

        for i in 0..<rows {
            for j in 0..<cols {
                let value = result[i][j] ?? 0.0
                if abs(value) < floor {
                    result[i][j] = 0.0
                } else {
                    result[i][j] = value
                }
            }
        }
        return result
    }
    
    // Call this from outside when an audio command is detected (eye/smile/tongue/etc.)
    func notifyAudioCommandDetected(at timestampMs: Int) {
        audioCommandTimeMs = timestampMs
    }
}
