import SwiftUI
import AVFoundation
import MediaPipeTasksVision
import UIKit
import CoreVideo

// Initializes and calls the MediaPipe APIs for face landmarkers.
class FaceLandmarkerService: NSObject {
    var faceLandmarker: FaceLandmarker?
    private(set) var runningMode = RunningMode.image
    private var numFaces = 1
    private var minFaceDetectionConfidence: Float = 0.5
    private var minFacePresenceConfidence: Float = 0.5
    private var minTrackingConfidence: Float = 0.5
    var modelPath: String
    
    // MARK: - Custom Initializer
    private init?(modelPath: String?, numFaces: Int, minFaceDetectionConfidence: Float, minFacePresenceConfidence: Float, minTrackingConfidence: Float, runningMode:RunningMode) {
        guard let modelPath = modelPath else { return nil }
        self.modelPath = modelPath
        self.numFaces = numFaces
        self.minFaceDetectionConfidence = minFaceDetectionConfidence
        self.minFacePresenceConfidence = minFacePresenceConfidence
        self.minTrackingConfidence = minTrackingConfidence
        self.runningMode = runningMode
        super.init()
        
        createFaceLandmarker()
    }
    
    private func createFaceLandmarker() {
        let faceLandmarkerOptions = FaceLandmarkerOptions()
        faceLandmarkerOptions.runningMode = runningMode
        faceLandmarkerOptions.numFaces = self.numFaces
        faceLandmarkerOptions.minFaceDetectionConfidence = self.minFaceDetectionConfidence
        faceLandmarkerOptions.minFacePresenceConfidence = self.minFacePresenceConfidence
        faceLandmarkerOptions.minTrackingConfidence = self.minTrackingConfidence
        faceLandmarkerOptions.baseOptions.modelAssetPath = modelPath
        faceLandmarkerOptions.outputFaceBlendshapes = true
        
        
        //      if runningMode == .liveStream {
        //        faceDetectorOptions.faceDetectorLiveStreamDelegate = self
        //      }
        do {
            faceLandmarker = try FaceLandmarker(options: faceLandmarkerOptions)
        }
        catch {
            print(error)
        }
    }
    
    static func stillImageLandmarkerService(
        modelPath: String?,
        numFaces: Int,
        minFaceDetectionConfidence: Float,
        minFacePresenceConfidence: Float,
        minTrackingConfidence: Float,
        runningMode:RunningMode) -> FaceLandmarkerService? {
            let faceLandmarkerService = FaceLandmarkerService(
                modelPath: modelPath,
                numFaces: numFaces,
                minFaceDetectionConfidence: minFaceDetectionConfidence,
                minFacePresenceConfidence: minFacePresenceConfidence,
                minTrackingConfidence: minTrackingConfidence,
                runningMode:.image)
            
            return faceLandmarkerService
        }
    
    static func videoLandmarkerService(
        modelPath: String?,
        numFaces: Int,
        minFaceDetectionConfidence: Float,
        minFacePresenceConfidence: Float,
        minTrackingConfidence: Float,
        runningMode:RunningMode) -> FaceLandmarkerService? {
            let faceLandmarkerService = FaceLandmarkerService(
                modelPath: modelPath,
                numFaces: numFaces,
                minFaceDetectionConfidence: minFaceDetectionConfidence,
                minFacePresenceConfidence: minFacePresenceConfidence,
                minTrackingConfidence: minTrackingConfidence,
                runningMode:.video)
            return faceLandmarkerService
        }
    
    // MARK: - Landmark Methods for Different Modes
    /**
     This method returns a FaceLandmarkerResult object and infrenceTime after receiving an image
     **/
    func detect(image: UIImage) -> ResultBundle? {
        guard let mpImage = try? MPImage(uiImage: image) else {
            return nil
        }
        print(image.imageOrientation.rawValue)
        do{
            let startDate = Date()
            let result = try? faceLandmarker?.detect(image: mpImage)
            let inferenceTime = Date().timeIntervalSince(startDate) * 1000
            return ResultBundle(inferenceTime: inferenceTime, faceLandmarkerResults: [result])
        } catch {
            print(error)
            return nil
        }
    }
    
    /**
     This method return FaceLandmarkerResult and infrenceTime when receive videoFrame
     **/
    func detectAsync(videoFrame: CMSampleBuffer, orientation: UIImage.Orientation, timeStamps: Int) {
        guard let faceLandmarker = faceLandmarker,let image = try? MPImage(sampleBuffer: videoFrame, orientation: orientation) else { return }
        do {
            try faceLandmarker.detectAsync(image: image, timestampInMilliseconds: timeStamps)
        } catch {
            print(error)
        }
    }
    
    /**
     This method returns a FaceLandmarkerResults object and infrenceTime when receiving videoUrl and inferenceIntervalInMilliseconds
     **/
    func detect(
        url: URL,
        durationInMilliseconds: Double,
        inferenceIntervalInMilliseconds: Double) async -> ResultBundle? {
            let startDate = Date()
            let videoAsset: AVAsset = AVAsset(url: url)
//            get the total length of the videos to do while loop
//            guard let durationInMilliseconds = try? await videoAsset.load(.duration).seconds * 1000 else { return nil }
//            print(durationInMilliseconds)
            
            
            let assetGenerator = imageGenerator(with: videoAsset)
            
            let frameCount = Int(durationInMilliseconds / inferenceIntervalInMilliseconds)
            
            let faceDetectorResultTuple = await detectObjectsInFramesGenerated(
                by: assetGenerator,
                totalFrameCount: frameCount,
                atIntervalsOf: inferenceIntervalInMilliseconds)
            
            return ResultBundle(
                inferenceTime: Date().timeIntervalSince(startDate) / Double(frameCount) * 1000,
                faceLandmarkerResults: faceDetectorResultTuple.faceLandmarkerResults,
                size: faceDetectorResultTuple.videoSize)
        }
    
    private func imageGenerator(with videoAsset: AVAsset) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: videoAsset)
        generator.requestedTimeToleranceBefore = CMTimeMake(value: 1, timescale: 25)
        generator.requestedTimeToleranceAfter = CMTimeMake(value: 1, timescale: 25)
        generator.appliesPreferredTrackTransform = true
        
        return generator
    }
    
    private func detectObjectsInFramesGenerated(
        by assetGenerator: AVAssetImageGenerator,
        totalFrameCount frameCount: Int,
        atIntervalsOf inferenceIntervalMs: Double) async
    -> (faceLandmarkerResults: [FaceLandmarkerResult?], videoSize: CGSize)  {
        var faceLandmarkerResults: [FaceLandmarkerResult?] = []
        var videoSize: CGSize = .zero
        
        for i in 0..<frameCount {
            let timestampMs = Int(inferenceIntervalMs) * i // ms
            let image: CGImage
            do {
                let time = CMTime(value: Int64(timestampMs), timescale: 1000)
                //        CMTime(seconds: Double(timestampMs) / 1000, preferredTimescale: 1000)
                (image, _) = try await assetGenerator.image(at: time)
                //image = try assetGenerator.copyCGImage(at: time, actualTime: nil)
            } catch {
                print(error)
                return (faceLandmarkerResults, videoSize)
            }
            
            let uiImage = UIImage(cgImage:image)
            videoSize = uiImage.size
            
            do {
                let result = try faceLandmarker?.detect(
                    videoFrame: MPImage(uiImage: uiImage),
                    timestampInMilliseconds: timestampMs)
                faceLandmarkerResults.append(result)
            } catch {
                print(error)
                faceLandmarkerResults.append(nil)
            }
        }
        
        return (faceLandmarkerResults, videoSize)
    }
    
}


/**
 * Initializes a new `FaceLandmarkerResult` with the given array of landmarks, blendshapes,
 * facialTransformationMatrixes and timestamp (in milliseconds).
 *
 * @param faceLandmarks An array of `NormalizedLandmark` objects.
 * @param faceBlendshapes An array of `Classifications` objects.
 * @param facialTransformationMatrixes An array of flattended matrices.
 * @param timestampInMilliseconds The timestamp (in milliseconds) for this result.
 *
 * @return An instance of `FaceLandmarkerResult` initialized with the given array of detections and
 * timestamp (in milliseconds).
 */

struct ResultBundle {
    let inferenceTime: Double
    let faceLandmarkerResults: [FaceLandmarkerResult?]
    var size: CGSize = .zero
}

