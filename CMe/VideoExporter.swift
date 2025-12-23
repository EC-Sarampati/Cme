import UIKit
import AVFoundation

class VideoExporter {
    func export(frames: [UIImage], to url: URL, completion: @escaping (Bool) -> Void) {
        guard let firstFrame = frames.first else { completion(false); return }
        let size = firstFrame.size
        
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: url, fileType: .mov) } catch {
            print("AVAssetWriter error: \(error)")
            completion(false)
            return
        }
        
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height
        ]
        
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        
        let queue = DispatchQueue(label: "video.export.queue")
        var frameCount: Int64 = 0
        let fps: Int32 = 30
        
        input.requestMediaDataWhenReady(on: queue) {
            while input.isReadyForMoreMediaData && frameCount < Int64(frames.count) {
                let frame = frames[Int(frameCount)]
                guard let buffer = self.pixelBuffer(from: frame, size: size) else { continue }
                let time = CMTime(value: frameCount, timescale: fps)
                adaptor.append(buffer, withPresentationTime: time)
                frameCount += 1
            }
            
            if frameCount >= Int64(frames.count) {
                input.markAsFinished()
                writer.finishWriting { completion(true) }
            }
        }
    }
    
    private func pixelBuffer(from image: UIImage, size: CGSize) -> CVPixelBuffer? {
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: true,
                     kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        var pxbuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         Int(size.width),
                                         Int(size.height),
                                         kCVPixelFormatType_32ARGB,
                                         attrs,
                                         &pxbuffer)
        guard status == kCVReturnSuccess, let buffer = pxbuffer else { return nil }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        let pxdata = CVPixelBufferGetBaseAddress(buffer)
        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: pxdata,
                                width: Int(size.width),
                                height: Int(size.height),
                                bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                space: rgbColorSpace,
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
        context?.draw(image.cgImage!, in: CGRect(origin: .zero, size: size))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
}
