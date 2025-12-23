import Foundation
import AVFoundation
import UIKit
import MediaPipeTasksVision
import Photos
import CoreImage

@MainActor
final class VideoProcessingViewModel: ObservableObject {
    
    struct SessionResult {
        let rawVideoURL: URL
        let heatmapVideoURL: URL?
        let landmarksJSONURL: URL?
    }

    @Published var lastSessionResult: SessionResult? = nil
    @Published var landmarksJSONURL: URL? = nil

    @Published var currentImage: UIImage?
    @Published var isProcessingVideo = false
    @Published var isCompressingVideo = false
    @Published var progress: Double = 0.0
    @Published var processingState: ProcessingState = .start
    
    @Published var isCompleted = false
    @Published var outputVideoPath: URL? = nil

    // Kept for compatibility with the older path (non_updatedprocessFullVideo)
    private var videoCreator: VideoCreator?
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    // MARK: - Helper (audio → frame ranges)

    private func mapCommandsToFrames(
        commands: [DetectedCommand],
        fps: Double,
        totalFrames: Int
    ) -> [(Range<Int>, String)] {
        var mapped: [(Range<Int>, String)] = []
        for (i, cmd) in commands.enumerated() {
            let start = Int(cmd.time * fps)
            let end = (i + 1 < commands.count) ? Int(commands[i + 1].time * fps) : totalFrames
            mapped.append((start..<end, cmd.command))
        }
        return mapped
    }

    // MARK: - OLD (kept for reference / not used from UI)

    func non_updatedprocessFullVideo(url: URL, featureType: String) async {
        guard !featureType.isEmpty else { return }

        // UI: start
        processingState = .processing
        isProcessingVideo = true
        progress = 0
        isCompleted = false
        currentImage = nil

        print("PROCESS_FULL_VIDEO_START url=\(url.lastPathComponent) feature=\(featureType)")

        // 1) Detect audio commands (eye/hand/smile/…)
        let audioRecognizer = AudioCommandRecognizer()
        let detectedCommands = await audioRecognizer.detectAudioCommands(from: url)
        print("Detected commands:",
              detectedCommands.map { "\($0.command)@\($0.time)" }.joined(separator: ", "))

        // 2) Frame info
        var (intervalMs, totalFrames) = await getVideoInterval(imageCap: url)
        if totalFrames == 0 { totalFrames = 1 }
        let fps = Int32(max(1, round(1000.0 / max(1.0, intervalMs))))
        print("Source: \(fps) fps, \(totalFrames) frames, interval=\(intervalMs)ms")

        let mappedSegments = mapCommandsToFrames(
            commands: detectedCommands,
            fps: Double(fps),
            totalFrames: totalFrames
        )

        // === Performance knobs ===
        let frameStride = 5
        let workSize = CGSize(width: 360, height: 640)
        let outSize = CGSize(width: workSize.width, height: workSize.height * 2)
        let fpsOut = max(Int32(5), fps / Int32(frameStride))

        // 3) Setup writer (match outSize & fpsOut)
        let outputPath = generateOutputPath()
        videoCreator = VideoCreator(
            outputURL: outputPath,
            width: Int(outSize.width),
            height: Int(outSize.height),
            fps: fpsOut
        )

        // 4) Load model (once)
        guard
            let modelPath = Bundle.main.path(forResource: "face_landmarker", ofType: "task"),
            let service = FaceLandmarkerService.videoLandmarkerService(
                modelPath: modelPath,
                numFaces: 1,
                minFaceDetectionConfidence: 0.5,
                minFacePresenceConfidence: 0.5,
                minTrackingConfidence: 0.3,
                runningMode: .video
            ),
            let landmarker = service.faceLandmarker
        else {
            print("Could not initialize FaceLandmarker")
            processingState = .completed
            isProcessingVideo = false
            return
        }

        // 5) Frame generator + canonical transform
        let asset = AVAsset(url: url)
        let track = asset.tracks(withMediaType: .video).first
        let preferredTransform = track?.preferredTransform ?? .identity

        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = false
        generator.maximumSize = workSize

        // Reference frame refresh every ~10s of source video
        let refreshIntervalFrames = max(Int(fps) * 10, 1)

        var refFrame: UIImage?
        var refGray: UIImage?

        var prevMask: CVPixelBuffer?
        var prevFeature: [[Int]]?

        // 6) Optional precompute face mask + feature once (fast path)
        do {
            let (m, f) = await createMask(
                url: url,
                featureType: featureType,
                inferenceIntervalMs: intervalMs,
                totalFrame: totalFrames
            )
            prevMask = m
            prevFeature = f
        }

        var processedSteps = 0
        let totalSteps = Int(ceil(Double(totalFrames) / Double(frameStride)))

        // 7) Frame loop (stride to reduce load)
        for frameCount in stride(from: 0, to: totalFrames, by: frameStride) {
            autoreleasepool {
                let timestampMs = Int(intervalMs) * frameCount

                // Extract current frame (raw CGImage, untransformed)
                guard let cg = try? generator.copyCGImage(
                    at: CMTime(value: Int64(timestampMs), timescale: 1000),
                    actualTime: nil
                ) else {
                    print("Skipping frame \(frameCount) (image gen failed)")
                    processedSteps += 1
                    if processedSteps % 3 == 0 {
                        self.progress = Double(processedSteps) / Double(totalSteps)
                    }
                    return
                }

                // Apply the real video transform so pixel coords match landmarks
                var currentFrame = UIImage(cgImage: cg).applying(transform: preferredTransform)

                // Force to upright to normalize orientation metadata
                currentFrame = UIImage(
                    cgImage: currentFrame.cgImage!,
                    scale: 1.0,
                    orientation: .up
                )

                // Resize to your working resolution
                guard let currentFrameResized = resizeImage(currentFrame, toSize: workSize) else {
                    print("Skipping frame \(frameCount) (resize failed)")
                    processedSteps += 1
                    if processedSteps % 3 == 0 {
                        self.progress = Double(processedSteps) / Double(totalSteps)
                    }
                    return
                }

                // Initialize / refresh reference frame + its grayscale
                if frameCount == 0 {
                    refFrame = currentFrameResized
                    refGray = convertToGrayscale(image: currentFrameResized)
                    self.currentImage = currentFrameResized
                } else if frameCount % refreshIntervalFrames == 0 {
                    refFrame = currentFrameResized
                    refGray = convertToGrayscale(image: currentFrameResized)
                }

                // Active command (default to provided featureType if none active)
                let activeCommand = mappedSegments.first(where: { $0.0.contains(frameCount) })?.1
                    ?? featureType

                do {
                    // Detect landmarks on current frame
                    let mpImage = try MPImage(uiImage: currentFrameResized)
                    let result = try landmarker.detect(
                        videoFrame: mpImage,
                        timestampInMilliseconds: timestampMs
                    )

                    var useMask: CVPixelBuffer? = nil
                    var useFeature: [[Int]]? = nil

                    if let landmarks = result.faceLandmarks.first {
                        let curMask = landmarksToFaceMask(
                            imageSize: currentFrameResized.size,
                            landmarks: landmarks
                        )
                        let curFeature = landmarksToFeature(
                            imageSize: currentFrameResized.size,
                            landmarks: landmarks,
                            featureType: activeCommand
                        )
                        useMask = curMask ?? prevMask
                        useFeature = curFeature ?? prevFeature
                    } else {
                        useMask = prevMask
                        useFeature = prevFeature
                        if useMask == nil || useFeature == nil {
                            print("No landmarks & no fallback for frame \(frameCount) — skipping")
                            processedSteps += 1
                            if processedSteps % 3 == 0 {
                                self.progress = Double(processedSteps) / Double(totalSteps)
                            }
                            return
                        }
                    }

                    guard
                        let m = useMask,
                        let f = useFeature,
                        let grayRef = refGray,
                        let grayCur = convertToGrayscale(image: currentFrameResized)
                    else {
                        print("Missing mask/feature/gray for frame \(frameCount) — skipping")
                        processedSteps += 1
                        if processedSteps % 3 == 0 {
                            self.progress = Double(processedSteps) / Double(totalSteps)
                        }
                        return
                    }

                    let refMasked = applyMask(image: grayRef, mask: m)
                    let curMasked = applyMask(image: grayCur, mask: m)

                    let (landmarkValues, heatmap, _) = runPydic(
                        imgList: [refMasked, curMasked],
                        mask: m,
                        ptsList: f
                    )

                    let stats = computeHeatmapStats(matrix: heatmap)
                    print(
                        "DIC_STATS_IOS frame=\(frameCount) " +
                        "min=\(stats.min) max=\(stats.max) " +
                        "mean=\(stats.mean) meanAbs=\(stats.meanAbs) " +
                        "nonZero=\(stats.nonZeroCount)/\(stats.totalCount)"
                    )

                    let landmarkStr = landmarkValues
                        .map { String(format: "%.6f", $0) }
                        .joined(separator: ",")
                    print("DIC_LANDMARKS_IOS frame=\(frameCount) values=[\(landmarkStr)]")

                    if let heatImg = createBGRImageFromGrayMatrix(
                        grayMatrix: transpose(matrix: heatmap)
                    ),
                       let resizedHeat = resizeImage(heatImg, toSize: workSize),
                       let final = verticallyStackImages(
                        image1: currentFrameResized,
                        image2: resizedHeat
                       ) {

                        self.videoCreator?.addImageToVideo(image: final)

                        if processedSteps % 2 == 0 {
                            self.currentImage = final
                        }
                    }

                    prevMask = useMask
                    prevFeature = useFeature

                } catch {
                    print("Frame \(frameCount) error:", error.localizedDescription)
                }

                processedSteps += 1
                if processedSteps % 3 == 0 {
                    self.progress = Double(processedSteps) / Double(totalSteps)
                }

                if processedSteps % 30 == 0 {
                    self.ciContext.clearCaches()
                }
            }
        }

        videoCreator?.finish { [weak self] success in
            guard let self else { return }
            if success {
                print("Video created:",
                      self.videoCreator?.outputURL.lastPathComponent ?? "unknown")

                Task {
                    let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                    if status == .authorized || status == .limited {
                        self.videoCreator?.saveVideoToPhotoLibrary { result in
                            switch result {
                            case .success(): print("Saved to Photos")
                            case .failure(let e): print("Save error:", e.localizedDescription)
                            }
                        }
                    } else {
                        print("No Photos permission — skipping save")
                    }

                    self.outputVideoPath = self.videoCreator?.outputURL
                    self.processingState = .completed
                    self.isProcessingVideo = false
                    self.isCompleted = true
                    self.progress = 1.0
                    print("🏁 Processing completed safely.")
                }

            } else {
                print("Video writing failed.")
                self.processingState = .completed
                self.isProcessingVideo = false
            }
        }
    }

    // MARK: - New Offline full-video processing (used by LiveRecorder & Gallery)
    //
    // This path:
    //   • Streams frames with AVAssetReader (memory safe)
    //   • Uses FaceLandmarker + landmarksToFaceMask (same as HeatmapProcessor)
    //   • Uses PyDIC with [refMasked, curMasked]
    //   • Applies smoothing + motion floor like HeatmapProcessor
    //   • Stacks [original frame on top, heatmap below] and writes to VideoCreator

    func processFullVideo(inputURL: URL, feature: String) async {
        print("PROCESS_FULL_VIDEO_START url=\(inputURL.lastPathComponent) feature=\(feature)")

        // Initial UI state (we are on MainActor)
        isProcessingVideo = true
        isCompleted = false
        progress = 0.0
        processingState = .processing

        // Tune these if needed
        let frameStride = 8
        let workSize = CGSize(width: 270, height: 480)

        // Smoothing params to match HeatmapProcessor
        let smoothingAlpha: Double = 0.3
        let motionFloor: Double = 0.015

        do {
            let (intervalMs, totalFrames) = await getVideoInterval(imageCap: inputURL)
            let fps = max(1.0, 1000.0 / max(1.0, intervalMs))  // approximate fps
            print("Source: \(fps) fps, \(totalFrames) frames, interval=\(intervalMs)ms")

            let refreshSeconds = 2.0
            let refreshIntervalFrames = max(
                1,
                Int((refreshSeconds * fps) / Double(frameStride))
            )

            // Prepare AVAssetReader
            let asset = AVAsset(url: inputURL)
            guard let track = asset.tracks(withMediaType: .video).first else {
                print("No video track found")
                isProcessingVideo = false
                processingState = .completed
                return
            }

            let reader = try AVAssetReader(asset: asset)
            let trackOutput = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
                ]
            )
            reader.add(trackOutput)

            guard reader.startReading() else {
                print("AVAssetReader failed: \(reader.error?.localizedDescription ?? "unknown")")
                isProcessingVideo = false
                processingState = .completed
                return
            }

            // Video writer for stacked (frame + heatmap)
            let fpsOut = max(Int32(5), Int32(fps / Double(frameStride)))
            let outHeight = Int(workSize.height * 2.0)
            let outputURL = generateOutputPath()

            guard let videoCreator = VideoCreator(
                outputURL: outputURL,
                width: Int(workSize.width),
                height: outHeight,
                fps: fpsOut
            ) else {
                print("VideoCreator init failed")
                isProcessingVideo = false
                processingState = .completed
                return
            }

            // Local CIContext for off-main processing
            let localCIContext = CIContext(options: [.cacheIntermediates: false])

            // Local FaceLandmarker (not shared with live HeatmapProcessor)
            guard
                let modelPath = Bundle.main.path(forResource: "face_landmarker", ofType: "task"),
                let service = FaceLandmarkerService.videoLandmarkerService(
                    modelPath: modelPath,
                    numFaces: 1,
                    minFaceDetectionConfidence: 0.5,
                    minFacePresenceConfidence: 0.5,
                    minTrackingConfidence: 0.3,
                    runningMode: .video
                ),
                let landmarker = service.faceLandmarker
            else {
                print("Could not initialize FaceLandmarker for offline processing")
                isProcessingVideo = false
                processingState = .completed
                return
            }

            var refGray: UIImage? = nil
            var frameIndex = 0
            var processedSteps = 0
            let totalSteps = max(1, totalFrames / frameStride)
            var previousHeatmap: [[Double?]]? = nil

            while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
                autoreleasepool {
                    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                        frameIndex += 1
                        return
                    }

                    // Respect stride to reduce compute
                    if frameIndex % frameStride != 0 {
                        frameIndex += 1
                        return
                    }

                    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
                    guard let cg = localCIContext.createCGImage(ciImage, from: ciImage.extent) else {
                        frameIndex += 1
                        return
                    }

                    var currentFrame = UIImage(cgImage: cg)
                    // Normalize orientation & resize for consistency with preview
                    currentFrame = UIImage(
                        cgImage: currentFrame.cgImage!,
                        scale: 1.0,
                        orientation: .up
                    )

                    guard let resizedFrame = resizeImage(currentFrame, toSize: workSize) else {
                        frameIndex += 1
                        return
                    }

                    guard let currentGray = convertToGrayscale(image: resizedFrame) else {
                        frameIndex += 1
                        return
                    }

                    // Initialize or periodically refresh reference frame
                    if refGray == nil {
                        refGray = currentGray
                        self.currentImage = resizedFrame
                    } else if (frameIndex / frameStride) % refreshIntervalFrames == 0 {
                        refGray = currentGray
                    }

                    guard let referenceGray = refGray else {
                        frameIndex += 1
                        return
                    }

                    do {
                        // Detect face landmarks on current color frame
                        let mpImage = try MPImage(uiImage: resizedFrame)
                        let timestampMs = Int(Double(frameIndex) * (1000.0 / fps))
                        let result = try landmarker.detect(
                            videoFrame: mpImage,
                            timestampInMilliseconds: timestampMs
                        )

                        guard let landmarks = result.faceLandmarks.first else {
                            frameIndex += 1
                            return
                        }

                        guard let maskBuffer = landmarksToFaceMask(
                            imageSize: resizedFrame.size,
                            landmarks: landmarks
                        ) else {
                            frameIndex += 1
                            return
                        }

                        // Apply masked region (face only) on reference & current gray
                        let refMaskedCI = applyMask(image: referenceGray, mask: maskBuffer)
                        let curMaskedCI = applyMask(image: currentGray, mask: maskBuffer)

                        // PyDIC: same as HeatmapProcessor, but offline
                        let (_, rawHeatmap, _) = runPydic(
                            imgList: [refMaskedCI, curMaskedCI],
                            mask: maskBuffer,
                            ptsList: []
                        )

                        // Smooth + threshold to reduce jitter
                        let smoothed = smoothHeatmapOffline(
                            previous: previousHeatmap,
                            current: rawHeatmap,
                            alpha: smoothingAlpha
                        )
                        let thresholded = applyMotionFloorOffline(
                            to: smoothed,
                            floor: motionFloor
                        )
                        previousHeatmap = thresholded

                        if let heatImgRaw = createBGRImageFromGrayMatrix(
                            grayMatrix: transpose(matrix: thresholded)
                        ) {
                            // Mirror horizontally to match front-camera style preview
                            let heatMirrored = UIImage(
                                cgImage: heatImgRaw.cgImage!,
                                scale: 1.0,
                                orientation: .upMirrored
                            )

                            // Resize heatmap to match workSize exactly
                            let heatResized = resizeImage(
                                heatMirrored,
                                toSize: workSize
                            ) ?? heatMirrored

                            if let stacked = verticallyStackImages(
                                image1: resizedFrame,
                                image2: heatResized
                            ) {
                                videoCreator.addImageToVideo(image: stacked)

                                processedSteps += 1
                                if processedSteps % 3 == 0 {
                                    self.progress = Double(processedSteps) / Double(totalSteps)
                                    self.currentImage = stacked
                                }
                            }
                        }

                    } catch {
                        print("Offline heatmap frame error:", error.localizedDescription)
                    }

                    localCIContext.clearCaches()
                    frameIndex += 1
                }

                // Give the executor a chance to schedule UI work
                if frameIndex % (frameStride * 10) == 0 {
                    await Task.yield()
                }
            }

            // Finalize the video and update UI
            videoCreator.finish { success in
                let finalURL = videoCreator.outputURL   // non-optional URL your VideoCreator wrote

                Task { @MainActor in
                    self.outputVideoPath = finalURL
                    self.isProcessingVideo = false
                    self.isCompleted = success
                    self.processingState = .completed

                    print("Offline processing complete: \(finalURL.lastPathComponent)")

                    // Save the overlay video to Photos
                    let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                    if status == .authorized || status == .limited {
                        videoCreator.saveVideoToPhotoLibrary { result in
                            switch result {
                            case .success():
                                print("Saved heatmap overlay video to Photos")
                            case .failure(let err):
                                print("Failed to save overlay to Photos:", err.localizedDescription)
                            }
                        }
                    } else {
                        print("No Photos permission for saving overlay video")
                    }
                }
            }

        } catch {
            print("processFullVideo error: \(error)")
            isProcessingVideo = false
            processingState = .completed
        }
    }

    // MARK: - Python-style offline processing for uploaded videos
    //
    // This function mimics Python's preprocess.py but now uses the same
    // frame extraction + orientation logic as the older working path
    // (non_updatedprocessFullVideo), so face landmarks are actually detected.
    //
    //  • Uses AVAssetImageGenerator + track.preferredTransform
    //  • Uses FaceLandmarker in .video mode with detect(videoFrame:timestamp)
    //  • Uses ALL landmarks as ptsList (per-landmark displacements)
    //  • Writes a stacked [original | heatmap] video and saves to Photos
    //
    func processFullVideoPythonStyle(inputURL: URL) async {
        print("PYTHON_STYLE_PROCESS_START url=\(inputURL.lastPathComponent)")

        // ---- UI state ----
        isProcessingVideo = true
        isCompleted = false
        progress = 0.0
        processingState = .processing
        currentImage = nil

        // ---- 1) Basic timing info (interval + fps) ----
        let (intervalMsRaw, totalFramesRaw) = await getVideoInterval(imageCap: inputURL)
        var intervalMs = intervalMsRaw
        var totalFrames = totalFramesRaw

        // Guard against weird zero values
        if intervalMs <= 0 {
            intervalMs = 33.3333  // ~30 fps fallback
        }
        if totalFrames <= 0 {
            totalFrames = 1
        }

        let fps = max(1.0, 1000.0 / intervalMs)   // approximate FPS from interval
        print("Python-style source: fps=\(fps), totalFrames=\(totalFrames), intervalMs=\(intervalMs)")

        guard totalFrames > 0 else {
            print("No frames in video")
            isProcessingVideo = false
            processingState = .completed
            return
        }

        // ---- 2) Detect audio commands (optional) ----
        let audioRecognizer = AudioCommandRecognizer()
        let detectedCommands = await audioRecognizer.detectAudioCommands(from: inputURL)

        if detectedCommands.isEmpty {
            print("No audio commands detected (speech error or silent). Proceeding with visual only.")
        }

        let commandFrameIndices: [Int] = detectedCommands
            .map { Int(round($0.time * fps)) }
            .sorted()

        let referPreSeconds = 10.0   // REFER_PRE_M = 10
        let refThresholdFrames: [Int] = commandFrameIndices.map { cmdFrame in
            max(0, cmdFrame - Int(referPreSeconds * fps))
        }

        print("Python-style commands: \(detectedCommands.map { "\($0.command)@\($0.time)s" })")
        print("Ref thresholds (frames): \(refThresholdFrames)")

        // ---- 3) Asset + ImageGenerator (same as old working path) ----
        let asset = AVAsset(url: inputURL)
        guard let track = asset.tracks(withMediaType: .video).first else {
            print("No video track found")
            isProcessingVideo = false
            processingState = .completed
            return
        }

        let preferredTransform = track.preferredTransform
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = false   // we apply transform manually
        let workSize = CGSize(width: 270, height: 480)
        generator.maximumSize = workSize

        // ---- 4) Video writer for stacked (frame + heatmap) ----
        let outHeight = Int(workSize.height * 2.0)
        let fpsOut = Int32(max(5.0, fps))   // roughly match source fps

        let outputURL = generateOutputPath()
        guard let videoCreator = VideoCreator(
            outputURL: outputURL,
            width: Int(workSize.width),
            height: outHeight,
            fps: fpsOut
        ) else {
            print("VideoCreator init failed (Python-style)")
            isProcessingVideo = false
            processingState = .completed
            return
        }

        // ---- 5) FaceLandmarker (match old working config) ----
        guard
            let modelPath = Bundle.main.path(forResource: "face_landmarker", ofType: "task"),
            let service = FaceLandmarkerService.videoLandmarkerService(
                modelPath: modelPath,
                numFaces: 1,
                minFaceDetectionConfidence: 0.5,
                minFacePresenceConfidence: 0.5,
                minTrackingConfidence: 0.3,
                runningMode: .video
            ),
            let landmarker = service.faceLandmarker
        else {
            print("Could not initialize FaceLandmarker for Python-style offline processing")
            isProcessingVideo = false
            processingState = .completed
            return
        }

        // ---- 6) Python-style reference / frame state ----
        var refGray: UIImage? = nil
        var trialIndex = 0

        var previousMask: CVPixelBuffer? = nil
        var previousFeatures: [[Int]]? = nil
        var previousGray: UIImage? = nil

        // Optional: store displacement like Python's full_heatmap_x/y/features
        var allLandmarkDisplacements: [[Double]] = []
        var allLandmarkPoints: [[[Int]]] = []

        let totalSteps = max(1, totalFrames)
        var processedSteps = 0
        var writtenFrames = 0

        // ---- 7) Frame loop using AVAssetImageGenerator (no AVAssetReader) ----
        for frameIndex in 0..<totalFrames {
            autoreleasepool {
                let timestampMs = Int(intervalMs * Double(frameIndex))
                let time = CMTime(value: Int64(timestampMs), timescale: 1000)

                // Grab frame
                guard let cg = try? generator.copyCGImage(at: time, actualTime: nil) else {
                    print("Failed to grab frame \(frameIndex)")
                    return
                }

                // Apply track preferred transform, then normalize to .up
                var colorFrame = UIImage(cgImage: cg).applying(transform: preferredTransform)
                colorFrame = UIImage(
                    cgImage: colorFrame.cgImage!,
                    scale: 1.0,
                    orientation: .up
                )

                guard let resizedFrame = resizeImage(colorFrame, toSize: workSize),
                      let currentGray = convertToGrayscale(image: resizedFrame)
                else {
                    print("Resize/gray failed at frame \(frameIndex)")
                    return
                }

                // ---- Landmarks, mask, features ----
                var maskBuffer: CVPixelBuffer? = nil
                var features: [[Int]]? = nil

                do {
                    let mpImage = try MPImage(uiImage: resizedFrame)
                    let result = try landmarker.detect(
                        videoFrame: mpImage,
                        timestampInMilliseconds: timestampMs
                    )

                    if let lms = result.faceLandmarks.first {
                        maskBuffer = landmarksToFaceMask(
                            imageSize: resizedFrame.size,
                            landmarks: lms
                        )
                        // Python-style: use ALL landmarks as ptsList
                        features = allLandmarksToFeatures(
                            imageSize: resizedFrame.size,
                            landmarks: lms
                        )
                    } else {
                        print("No face landmarks at frame \(frameIndex)")
                    }
                } catch {
                    print("Python-style frame \(frameIndex) landmark error: \(error.localizedDescription)")
                }

                // Fallback to previous valid data if current detection fails
                var effectiveGray = currentGray
                if maskBuffer == nil || features == nil {
                    if let prevMask = previousMask,
                       let prevPts = previousFeatures,
                       let prevGray = previousGray {
                        maskBuffer = prevMask
                        features = prevPts
                        effectiveGray = prevGray
                        print("Using previous mask/features at frame \(frameIndex)")
                    } else {
                        // No landmarks at all yet, just skip this frame but DO NOT abort
                        return
                    }
                }

                guard let mask = maskBuffer, let pts = features else {
                    print("Still no mask/features at frame \(frameIndex)")
                    return
                }

                previousMask = mask
                previousFeatures = pts
                previousGray = effectiveGray

                // ---- Reference frame logic: ref = frame ~10s before each command ----
                if refGray == nil {
                    refGray = effectiveGray
                }

                if trialIndex < refThresholdFrames.count &&
                    frameIndex >= refThresholdFrames[trialIndex] {
                    refGray = effectiveGray
                    print("Python-style: updated refGray at frame=\(frameIndex) for trial \(trialIndex)")
                    trialIndex += 1
                }

                guard let referenceGray = refGray else {
                    print("Missing refGray at frame \(frameIndex)")
                    return
                }

                // ---- Apply mask to reference & current gray (ROI only) ----
                let refMaskedCI = applyMask(image: referenceGray, mask: mask)
                let curMaskedCI = applyMask(image: effectiveGray, mask: mask)

                // ---- Run PyDIC with ALL landmarks as ptsList ----
                let (landmarkValues, heatmap, landmarkPts) = runPydic(
                    imgList: [refMaskedCI, curMaskedCI],
                    mask: mask,
                    ptsList: pts
                )

                allLandmarkDisplacements.append(landmarkValues)
                allLandmarkPoints.append(landmarkPts)

                // ---- Build heatmap image ----
                if let heatImgRaw = createBGRImageFromGrayMatrix(
                    grayMatrix: transpose(matrix: heatmap)
                ) {
                    // Resize heatmap to match workSize exactly
                    let heatResized = resizeImage(
                        heatImgRaw,
                        toSize: workSize
                    ) ?? heatImgRaw

                    if let stacked = verticallyStackImages(
                        image1: resizedFrame,
                        image2: heatResized
                    ) {
                        videoCreator.addImageToVideo(image: stacked)
                        writtenFrames += 1

                        processedSteps += 1
                        if processedSteps % 10 == 0 {
                            self.progress = Double(processedSteps) / Double(totalSteps)
                            self.currentImage = stacked
                        }
                    } else {
                        print("Failed to stack images at frame \(frameIndex)")
                    }
                } else {
                    print("Heatmap image creation failed at frame \(frameIndex)")
                }
            }

            // Let the executor breathe a bit
            if frameIndex % 60 == 0 {
                await Task.yield()
            }
        }

        // ---- 8) Finish video + update UI ----
        videoCreator.finish { success in
            let finalURL = videoCreator.outputURL

            Task { @MainActor in
                print("Python-style offline processing complete: \(finalURL.lastPathComponent)")
                print("Frames processed: \(totalFrames)")
                print("Landmark displacement frames: \(allLandmarkDisplacements.count)")
                print("Written video frames: \(writtenFrames)")

                self.outputVideoPath = finalURL
                self.isProcessingVideo = false
                self.isCompleted = success && writtenFrames > 0
                self.processingState = .completed
                self.progress = 1.0

                // Only attempt saving to Photos if we actually wrote frames
                guard writtenFrames > 0 else {
                    print("No frames written to overlay video – skipping Photos save to avoid PHPhotosErrorDomain 3302.")
                    return
                }

                let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                if status == .authorized || status == .limited {
                    PHPhotoLibrary.shared().performChanges({
                        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: finalURL)
                    }) { ok, error in
                        DispatchQueue.main.async {
                            if ok {
                                print("Saved Python-style overlay video to Photos")
                            } else {
                                print("Failed to save Python-style overlay video:", error?.localizedDescription ?? "unknown")
                            }
                        }
                    }
                } else {
                    print("No Photos permission for saving Python-style overlay video")
                }
            }
        }
    }

    
//    func processFullVideoPythonStyle(inputURL: URL) async {
//        print("PYTHON_STYLE_PROCESS_START url=\(inputURL.lastPathComponent)")
//
//        // ---- UI state ----
//        isProcessingVideo = true
//        isCompleted = false
//        progress = 0.0
//        processingState = .processing
//        currentImage = nil
//
//        // ---- 1) Basic timing info (interval + fps) ----
//        let (intervalMs, totalFrames) = await getVideoInterval(imageCap: inputURL)
//        let fps = max(1.0, 1000.0 / max(1.0, intervalMs))   // approximate FPS from interval
//        print("Python-style source: fps=\(fps), totalFrames=\(totalFrames), intervalMs=\(intervalMs)")
//
//        guard totalFrames > 0 else {
//            print("No frames in video")
//            isProcessingVideo = false
//            processingState = .completed
//            return
//        }
//
//        // ---- 2) Detect audio commands (optional) ----
//        let audioRecognizer = AudioCommandRecognizer()
//        let detectedCommands = await audioRecognizer.detectAudioCommands(from: inputURL)
//
//        if detectedCommands.isEmpty {
//            print("No audio commands detected (speech error or silent). Proceeding with visual only.")
//        }
//
//        let commandFrameIndices: [Int] = detectedCommands
//            .map { Int(round($0.time * fps)) }
//            .sorted()
//
//        let referPreSeconds = 10.0   // REFER_PRE_M = 10
//        let refThresholdFrames: [Int] = commandFrameIndices.map { cmdFrame in
//            max(0, cmdFrame - Int(referPreSeconds * fps))
//        }
//
//        print("Python-style commands: \(detectedCommands.map { "\($0.command)@\($0.time)s" })")
//        print("Ref thresholds (frames): \(refThresholdFrames)")
//
//        // ---- 3) Prepare AVAssetReader ----
//        let asset = AVAsset(url: inputURL)
//        guard let track = asset.tracks(withMediaType: .video).first else {
//            print("No video track found")
//            isProcessingVideo = false
//            processingState = .completed
//            return
//        }
//
//        let reader: AVAssetReader
//        do {
//            reader = try AVAssetReader(asset: asset)
//        } catch {
//            print("AVAssetReader init failed: \(error)")
//            isProcessingVideo = false
//            processingState = .completed
//            return
//        }
//
//        let trackOutput = AVAssetReaderTrackOutput(
//            track: track,
//            outputSettings: [
//                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
//            ]
//        )
//        reader.add(trackOutput)
//
//        guard reader.startReading() else {
//            print("AVAssetReader failed: \(reader.error?.localizedDescription ?? "unknown")")
//            isProcessingVideo = false
//            processingState = .completed
//            return
//        }
//
//        // ---- 4) Video writer for stacked (frame + heatmap) ----
//        let workSize = CGSize(width: 270, height: 480)
//        let outHeight = Int(workSize.height * 2.0)         // top: frame, bottom: heatmap
//        let fpsOut = Int32(max(5.0, fps))                  // roughly match source fps
//
//        let outputURL = generateOutputPath()
//        guard let videoCreator = VideoCreator(
//            outputURL: outputURL,
//            width: Int(workSize.width),
//            height: outHeight,
//            fps: fpsOut
//        ) else {
//            print("VideoCreator init failed (Python-style)")
//            isProcessingVideo = false
//            processingState = .completed
//            return
//        }
//
//        let localCIContext = CIContext(options: [.cacheIntermediates: false])
//
//        // ---- 5) FaceLandmarker ----
//        guard
//            let modelPath = Bundle.main.path(forResource: "face_landmarker", ofType: "task"),
//            let service = FaceLandmarkerService.videoLandmarkerService(
//                modelPath: modelPath,
//                numFaces: 1,
//                minFaceDetectionConfidence: 0.5,
//                minFacePresenceConfidence: 0.5,
//                minTrackingConfidence: 0.3,
//                runningMode: .image   // we call detect(videoFrame:...), this is ok in Tasks iOS
//            ),
//            let landmarker = service.faceLandmarker
//        else {
//            print("Could not initialize FaceLandmarker for Python-style offline processing")
//            isProcessingVideo = false
//            processingState = .completed
//            return
//        }
//
//        // ---- 6) Python-style reference / frame state ----
//        var refGray: UIImage? = nil
//        var frameIndex = 0
//        var trialIndex = 0
//
//        var previousMask: CVPixelBuffer? = nil
//        var previousFeatures: [[Int]]? = nil
//        var previousGray: UIImage? = nil
//
//        // For smoothing / motion floor (match HeatmapProcessor)
//        let smoothingAlpha: Double = 0.3
//        let motionFloor: Double = 0.015
//        var previousHeatmap: [[Double?]]? = nil
//
//        // Optional: store displacement like Python's full_heatmap_x/y/features
//        var allLandmarkDisplacements: [[Double]] = []
//        var allLandmarkPoints: [[[Int]]] = []
//
//        let totalSteps = max(1, totalFrames)
//        var processedSteps = 0
//        var writtenFrames = 0    // track frames actually written to overlay video
//
//        // ---- 7) Frame loop (no stride, like Python) ----
//        while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
//            autoreleasepool {
//                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
//                    print("No pixelBuffer at frame \(frameIndex)")
//                    frameIndex += 1
//                    return
//                }
//
//                let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
//                guard let cg = localCIContext.createCGImage(ciImage, from: ciImage.extent) else {
//                    print("Failed to create CGImage at frame \(frameIndex)")
//                    frameIndex += 1
//                    return
//                }
//
//                // Raw frame -> upright UIImage
//                var colorFrame = UIImage(cgImage: cg)
//                colorFrame = UIImage(
//                    cgImage: colorFrame.cgImage!,
//                    scale: 1.0,
//                    orientation: .up
//                )
//
//                guard let resizedFrame = resizeImage(colorFrame, toSize: workSize),
//                      let currentGray = convertToGrayscale(image: resizedFrame) else {
//                    print("Resize/gray failed at frame \(frameIndex)")
//                    frameIndex += 1
//                    return
//                }
//
//                // ---- Landmarks, mask, features ----
//                var maskBuffer: CVPixelBuffer? = nil
//                var features: [[Int]]? = nil
//
//                do {
//                    let mpImage = try MPImage(uiImage: resizedFrame)
//                    let timestampMs = Int(Double(frameIndex) * (1000.0 / fps))
//                    let result = try landmarker.detect(
//                        videoFrame: mpImage,
//                        timestampInMilliseconds: timestampMs
//                    )
//
//                    if let lms = result.faceLandmarks.first {
//                        maskBuffer = landmarksToFaceMask(
//                            imageSize: resizedFrame.size,
//                            landmarks: lms
//                        )
//                        features = allLandmarksToFeatures(
//                            imageSize: resizedFrame.size,
//                            landmarks: lms
//                        )
//                    } else {
//                        print("No face landmarks at frame \(frameIndex)")
//                    }
//                } catch {
//                    print("Python-style frame \(frameIndex) landmark error: \(error.localizedDescription)")
//                }
//
//                // Fallback to previous valid data if current detection fails
//                var effectiveGray = currentGray
//                if maskBuffer == nil || features == nil {
//                    if let prevMask = previousMask,
//                       let prevPts = previousFeatures,
//                       let prevGray = previousGray {
//                        maskBuffer = prevMask
//                        features = prevPts
//                        effectiveGray = prevGray
//                        print("Using previous mask/features at frame \(frameIndex)")
//                    } else {
//                        // No landmarks at all yet, just skip this frame but DO NOT abort the whole video
//                        frameIndex += 1
//                        return
//                    }
//                }
//
//                guard let mask = maskBuffer, let pts = features else {
//                    print("Still no mask/features at frame \(frameIndex)")
//                    frameIndex += 1
//                    return
//                }
//
//                previousMask = mask
//                previousFeatures = pts
//                previousGray = effectiveGray
//
//                // ---- Reference frame logic: ref = frame ~10s before each command ----
//                if refGray == nil {
//                    refGray = effectiveGray
//                }
//
//                if trialIndex < refThresholdFrames.count &&
//                    frameIndex >= refThresholdFrames[trialIndex] {
//                    refGray = effectiveGray
//                    print("Python-style: updated refGray at frame=\(frameIndex) for trial \(trialIndex)")
//                    trialIndex += 1
//                }
//
//                guard let referenceGray = refGray else {
//                    print("Missing refGray at frame \(frameIndex)")
//                    frameIndex += 1
//                    return
//                }
//
//                // ---- Apply mask to reference & current gray (ROI only) ----
//                let refMaskedCI = applyMask(image: referenceGray, mask: mask)
//                let curMaskedCI = applyMask(image: effectiveGray, mask: mask)
//
//                // ---- Run PyDIC with ALL landmarks as ptsList ----
//                let (landmarkValues, rawHeatmap, landmarkPts) = runPydic(
//                    imgList: [refMaskedCI, curMaskedCI],
//                    mask: mask,
//                    ptsList: pts
//                )
//
//                allLandmarkDisplacements.append(landmarkValues)
//                allLandmarkPoints.append(landmarkPts)
//
//                // ---- Smooth + motion floor to match live HeatmapProcessor ----
//                let smoothed = smoothHeatmapOffline(
//                    previous: previousHeatmap,
//                    current: rawHeatmap,
//                    alpha: smoothingAlpha
//                )
//                let thresholded = applyMotionFloorOffline(
//                    to: smoothed,
//                    floor: motionFloor
//                )
//                previousHeatmap = thresholded
//
//                // ---- Build heatmap image (match HeatmapProcessor style) ----
//                if let heatImgRaw = createBGRImageFromGrayMatrix(
//                    grayMatrix: transpose(matrix: thresholded)
//                ) {
//                    // 1) Mirror heatmap horizontally like fixHeatmapOrientation(.upMirrored)
//                    let heatMirrored = UIImage(
//                        cgImage: heatImgRaw.cgImage!,
//                        scale: 1.0,
//                        orientation: .upMirrored
//                    )
//
//                    // 2) Resize heatmap to workSize (270×480) – same aspect as live, lower res
//                    let heatResized = resizeImage(
//                        heatMirrored,
//                        toSize: workSize
//                    ) ?? heatMirrored
//
//                    // 3) Mirror original frame so it matches the selfie-style orientation
//                    let mirroredFrame = UIImage(
//                        cgImage: resizedFrame.cgImage!,
//                        scale: 1.0,
//                        orientation: .upMirrored
//                    )
//
//                    // 4) Stack original (top) + heatmap (bottom) -> 270×960, as VideoCreator expects
//                    if let stacked = verticallyStackImages(
//                        image1: mirroredFrame,
//                        image2: heatResized
//                    ) {
//                        videoCreator.addImageToVideo(image: stacked)
//                        writtenFrames += 1
//
//                        processedSteps += 1
//                        if processedSteps % 10 == 0 {
//                            self.progress = Double(processedSteps) / Double(totalSteps)
//                            self.currentImage = stacked
//                        }
//                    } else {
//                        print("Failed to stack images at frame \(frameIndex)")
//                    }
//                } else {
//                    print("Heatmap image creation failed at frame \(frameIndex)")
//                }
//
//                localCIContext.clearCaches()
//                frameIndex += 1
//            }
//
//            if frameIndex % 60 == 0 {
//                await Task.yield()
//            }
//        }
//
//        // ---- 8) Finish video + update UI ----
//        videoCreator.finish { success in
//            let finalURL = videoCreator.outputURL
//
//            Task { @MainActor in
//                print("Python-style offline processing complete: \(finalURL.lastPathComponent)")
//                print("Frames processed: \(frameIndex)")
//                print("Landmark displacement frames: \(allLandmarkDisplacements.count)")
//                print("Written video frames: \(writtenFrames)")
//
//                self.outputVideoPath = finalURL
//                self.isProcessingVideo = false
//                self.isCompleted = success && writtenFrames > 0
//                self.processingState = .completed
//                self.progress = 1.0
//
//                // Only attempt saving to Photos if we actually wrote frames
//                guard writtenFrames > 0 else {
//                    print("No frames written to overlay video – skipping Photos save to avoid PHPhotosErrorDomain 3302.")
//                    return
//                }
//
//                let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
//                if status == .authorized || status == .limited {
//                    PHPhotoLibrary.shared().performChanges({
//                        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: finalURL)
//                    }) { ok, error in
//                        DispatchQueue.main.async {
//                            if ok {
//                                print("Saved Python-style overlay video to Photos")
//                            } else {
//                                print("Failed to save Python-style overlay video:", error?.localizedDescription ?? "unknown")
//                            }
//                        }
//                    }
//                } else {
//                    print("No Photos permission for saving Python-style overlay video")
//                }
//            }
//        }
//    }


    // MARK: - Local helpers (older path still uses these)

    /// CIImage -> UIImage (resized) using this view model's CIContext
    private func makeUIImage(from ciImage: CIImage, targetSize: CGSize) -> UIImage? {
        guard let cg = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        let ui = UIImage(cgImage: cg)
        return resizeImage(ui, toSize: targetSize)
    }

    /// Compute a heatmap (UIImage) from reference & current grayscale frames using runPydic
    /// (This is the older full-frame version, currently not used by the new offline path.)
    private func computeHeatmap(reference: UIImage, current: UIImage) -> UIImage? {
        guard
            let refCI = CIImage(image: reference),
            let curCI = CIImage(image: current)
        else { return nil }

        // Build a full-white mask covering the whole frame
        let whiteCI = CIImage(color: .white).cropped(to: refCI.extent)
        guard let maskBuffer = pixelBuffer(ciimage: whiteCI) else { return nil }

        let (_, heat, _) = runPydic(
            imgList: [refCI, curCI],
            mask: maskBuffer,
            ptsList: []
        )

        guard let heatImg = createBGRImageFromGrayMatrix(
            grayMatrix: transpose(matrix: heat)
        ) else {
            return nil
        }
        return heatImg
    }

    /// Simple wrapper around your global verticallyStackImages helper
    private func stackImagesVertically(top: UIImage, bottom: UIImage) -> UIImage? {
        return verticallyStackImages(image1: top, image2: bottom)
    }

    // MARK: - Output path helper

    private func generateOutputPath() -> URL {
        let fileName = "CMe_Heatmap_\(Date().timeIntervalSince1970).mp4"
        return FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
    }
}

// MARK: - Orientation-safe image transform

extension UIImage {
    /// Applies an affine transform and re-anchors to positive coordinates so the output isn't cropped.
    func applying(transform: CGAffineTransform) -> UIImage {
        let inputCI = CIImage(cgImage: self.cgImage!)
        let transformed = inputCI.transformed(by: transform)
        let rect = transformed.extent
        let fixed = transformed.transformed(
            by: CGAffineTransform(translationX: -rect.origin.x, y: -rect.origin.y)
        )
        let context = CIContext(options: nil)
        if let cgOut = context.createCGImage(fixed, from: fixed.extent) {
            return UIImage(cgImage: cgOut)
        }
        return self
    }
}

// MARK: - Offline heatmap smoothing helpers (share logic with live HeatmapProcessor)

/// Exponential smoothing between previous and current heatmap ([[Double?]])
fileprivate func smoothHeatmapOffline(
    previous: [[Double?]]?,
    current: [[Double?]],
    alpha: Double
) -> [[Double?]] {
    guard let previous = previous,
          previous.count == current.count,
          previous.first?.count == current.first?.count
    else {
        // No previous or mismatched sizes: just use current
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

/// Zero out very small motion to avoid flickering heatmap
fileprivate func applyMotionFloorOffline(
    to heatmap: [[Double?]],
    floor: Double
) -> [[Double?]] {
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

// MARK: - Helper to use all landmarks as ptsList (Python-style)

/// Convert *all* Mediapipe landmarks to pixel coordinates (like Python does)
func allLandmarksToFeatures(
    imageSize: CGSize,
    landmarks: [NormalizedLandmark]
) -> [[Int]] {
    var features: [[Int]] = []
    for lm in landmarks {
        let px = normalizeToPixelCoord(
            landmark: lm,
            imageWidth: Int(imageSize.width),
            imageHeight: Int(imageSize.height)
        )
        features.append(px)
    }
    return features
}
