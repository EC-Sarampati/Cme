import Foundation
import AVFoundation
import UIKit
import Photos

final class VideoCreator {
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var frameCount: Int64 = 0
    private let fps: Int32
    private let width: Int
    private let height: Int
    let outputURL: URL

    // MARK: - Init
    init?(outputURL: URL, width: Int = 1080, height: Int = 2160, fps: Int32 = 30) {
        self.outputURL = outputURL
        self.width = width
        self.height = height
        self.fps = fps
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height
            ]
            writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            writerInput?.expectsMediaDataInRealTime = false

            adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: writerInput!,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height
                ])

            if let writerInput = writerInput, let writer = writer, writer.canAdd(writerInput) {
                writer.add(writerInput)
            }

            writer?.startWriting()
            writer?.startSession(atSourceTime: .zero)
        } catch {
            print("AVAssetWriter init error:", error.localizedDescription)
            return nil
        }
    }

    // MARK: - Frame append
    private func append(image: UIImage) {
        guard let adaptor = adaptor,
              let input = writerInput,
              input.isReadyForMoreMediaData,
              let buffer = Self.toPixelBuffer(uiimage: image, width: width, height: height)
        else { return }

        let frameTime = CMTime(value: frameCount, timescale: fps)
        adaptor.append(buffer, withPresentationTime: frameTime)
        frameCount += 1
    }

    // MARK: - Public interface
    func addImageToVideo(image: UIImage) {
        append(image: image)
    }

    func finish(_ completion: @escaping (Bool) -> Void) {
        writerInput?.markAsFinished()
        writer?.finishWriting { [weak self] in
            guard let self else { completion(false); return }
            completion(self.writer?.status == .completed)
        }
    }

    
    func saveVideoToPhotoLibrary(completion: @escaping (Result<Void, Error>) -> Void) {
        let fileURL = self.outputURL

        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
        }) { success, error in
            DispatchQueue.main.async {
                if success {
                    print("Saved to Photos successfully.")
                    completion(.success(()))
                } else {
                    print("Save failed:", error?.localizedDescription ?? "unknown error")
                    completion(.failure(error ?? NSError(domain: "SaveError", code: -1)))
                }
            }
        }
    }

    // MARK: - Helpers
    static func toPixelBuffer(uiimage: UIImage, width: Int, height: Int) -> CVPixelBuffer? {
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue as Any,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue as Any
        ] as CFDictionary

        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         width,
                                         height,
                                         kCVPixelFormatType_32ARGB,
                                         attrs,
                                         &pb)
        guard status == kCVReturnSuccess, let pixelBuffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let data = CVPixelBufferGetBaseAddress(pixelBuffer)
        let rgb = CGColorSpaceCreateDeviceRGB()

        guard let ctx = CGContext(data: data,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                  space: rgb,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
        else { return nil }

        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        if let cg = uiimage.cgImage {
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixelBuffer
    }
}

// MARK: - Utility
func generateOutputPath() -> URL {
    let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let stamp = Int(Date().timeIntervalSince1970)
    return documentsDirectory.appendingPathComponent("CMe_Heatmap_\(stamp).mp4")
}
