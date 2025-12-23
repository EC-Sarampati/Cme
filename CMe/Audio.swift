import SwiftUI
import AVFoundation

class VideoViewModel: ObservableObject {
    @Published var image: Image? = nil
    @Published var significantFrameIndices: [Int] = []
    

    func loadFirstFrame(videoURL: URL) {
        //let videoURL = Bundle.main.url(forResource: "sample1", withExtension: "mp4")
        if let uiImage = getFirstFrame(fromVideo: videoURL) {
            image = Image(uiImage: uiImage)
        }
    }
    
    func loadVideoAndExtractFrames(videoURL: URL) -> [Int]{
        //let videoURL = Bundle.main.url(forResource: "sample1", withExtension: "mp4")
        return extractSignificantAudioChanges(in: videoURL, videoFrameRate: 30)
    }

    private func getFirstFrame(fromVideo videoURL: URL) -> UIImage? {
        
        let asset = AVAsset(url: videoURL)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true

        let time = CMTime(seconds: 0, preferredTimescale: 1)
        var actualTime = CMTime.zero
        do {
            let imageRef = try imageGenerator.copyCGImage(at: time, actualTime: &actualTime)
            return UIImage(cgImage: imageRef)
        } catch {
            print(error.localizedDescription)
            return nil
        }
    }
    
    func extractSignificantAudioChanges(in videoURL: URL, videoFrameRate: Float) -> [Int] {
        let asset = AVAsset(url: videoURL)
        guard let audioTrack = asset.tracks(withMediaType: .audio).first else {
            print("No audio track found in the video")
            return []
        }

        guard let assetReader = try? AVAssetReader(asset: asset) else {
            print("Unable to create AVAssetReader")
            return []
        }

        let audioOutputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMBitDepthKey: 16
        ]
        let assetReaderOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: audioOutputSettings)
        assetReader.add(assetReaderOutput)
        assetReader.startReading()

        var significantFrameIndices: [Int] = []
        var lastRMS: Float? = nil
        var frameCount: Int = 0
        let sampleRate = audioTrack.naturalTimeScale
        let samplesPerFrame = Int(Float(sampleRate) / videoFrameRate)
        var currentFrameSamples: [Float] = []
        var skipFrameCounter = 0

        while let sampleBuffer = assetReaderOutput.copyNextSampleBuffer() {
            if skipFrameCounter > 0 {
                skipFrameCounter -= 1
                if skipFrameCounter == 0 {
                    lastRMS = calculateRMS(sampleBuffer)
                }
                frameCount += 1
                continue
            }

            if let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                let length = CMBlockBufferGetDataLength(blockBuffer)
                var data = Data(count: length)
                data.withUnsafeMutableBytes { bytes in
                    CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: bytes)
                }

                currentFrameSamples.append(contentsOf: data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }.map { Float($0) / Float(Int16.max) })
                
                if currentFrameSamples.count >= samplesPerFrame {
                    let rms = sqrt(currentFrameSamples.reduce(0, { $0 + $1 * $1 }) / Float(currentFrameSamples.count))
                    if let lastRMS = lastRMS, rms - lastRMS > 0.06 {
                        significantFrameIndices.append(frameCount)
                        skipFrameCounter = 9
                    }
                    lastRMS = rms
                    currentFrameSamples.removeAll()
                    frameCount += 1
                }
            }
        }

        return significantFrameIndices
    }

    func calculateRMS(_ sampleBuffer: CMSampleBuffer) -> Float {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return 0.0
        }

        let length = CMBlockBufferGetDataLength(blockBuffer)
        var data = Data(count: length)
        data.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: bytes)
        }

        let frameSamples = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }.map { Float($0) / Float(Int16.max) }
        return sqrt(frameSamples.reduce(0, { $0 + $1 * $1 }) / Float(frameSamples.count))
    }

}
