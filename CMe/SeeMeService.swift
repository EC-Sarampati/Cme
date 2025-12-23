import UIKit
import MediaPipeTasksVision
import AVFoundation
import SwiftUI
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins

/**
 @brief Get the basic information of a video.

 @discussion This function calculates the time interval for inference between each pair of frames in a given video file. It also returns the total number of frames in the video and the frame rate (FPS).

 @param url The URL of the video file.

 @return A tuple containing the average time interval in milliseconds between frames, the total number of frames, and the frame rate (FPS) of the video.
 */
func getVideoInterval(imageCap: URL) async -> (Double, Int){
    var inferenceIntervalMs: Double = 0
    var totalFrame: Int = 0
    let videoAsset: AVAsset = AVAsset(url: imageCap)
    let assetGenerator = AVAssetImageGenerator(asset: videoAsset)
    
    assetGenerator.requestedTimeToleranceBefore = CMTimeMake(value: 1, timescale: 25)
    assetGenerator.requestedTimeToleranceAfter = CMTimeMake(value: 1, timescale: 25)
    assetGenerator.appliesPreferredTrackTransform = true
    
    //    let durationInMilliseconds = try? await videoAsset.load(.duration).seconds * 1000
    let tracks = try? await videoAsset.loadTracks(withMediaType: .video)
    if let videoTrack = tracks?.first {
        guard let fps = try? await videoTrack.load(.nominalFrameRate) else {
            return (inferenceIntervalMs, totalFrame)}
        //duration In Seconds
        guard let durationInMilliseconds = try? await videoAsset.load(.duration).seconds else {
            return (inferenceIntervalMs, totalFrame)}
        _ = try! await videoTrack.load(.naturalSize)
        totalFrame = Int(round(durationInMilliseconds * Float64(fps)))
        let duration = durationInMilliseconds * 1000
        inferenceIntervalMs = Double(duration) / Double(totalFrame)
    }
    
    return (inferenceIntervalMs, totalFrame)
    
}

/**
 @brief Classifies the Region of Interest (ROI) based on the last character of the file name.

 @discussion This function analyzes the last character of a file name (without its extension) to determine the type of feature it represents in a video file. The feature is classified as either "eye" or "mouth" based on the last character: '2' indicates an "eye", whereas '1' or '3' indicate a "mouth". If the last character is not one of these, it signals an unrecognized format.

 @param url The URL of the file whose feature type needs to be classified.

 @return A String representing the classified feature type ("eye", "mouth", or an error message for unrecognized formats).
 */
func getROI(from url: URL) -> String {
    let fileNameWithoutExtension = url.deletingPathExtension().lastPathComponent

    if let lastCharacter = fileNameWithoutExtension.last {
        switch lastCharacter {
        case "2":
            print("The featureType is eye.")
            return "eye"
        case "1", "3":
            print("The featureType is mouth.")
            return "mouth"
        default:
            print("Unrecognized video format, the video file must end with 1, 2, or 3")
            return ""
        }
    } else {
        print("The file name is empty.")
        return ""
    }
}



func imageToMatrix(image: UIImage) -> [[Int]]? {
    guard let cgImage = image.cgImage else { return nil }
    
    let width = cgImage.width
    let height = cgImage.height
    
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let rawData = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height * 4)
    defer {
        rawData.deallocate()
    }
    
    let bytesPerPixel = 4
    let bytesPerRow = bytesPerPixel * width
    let bitsPerComponent = 8
    let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
    
    let context = CGContext(data: rawData, width: width, height: height, bitsPerComponent: bitsPerComponent, bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo)
    context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    
    var matrix: [[Int]] = Array(repeating: Array(repeating: 0, count: width), count: height)
    
    for y in 0..<height {
        for x in 0..<width {
            let byteIndex = (bytesPerRow * y) + x * bytesPerPixel
            let red = CGFloat(rawData[byteIndex]) / 255.0
            let green = CGFloat(rawData[byteIndex + 1]) / 255.0
            let blue = CGFloat(rawData[byteIndex + 2]) / 255.0
            
            // whether white
            if red > 0.9, green > 0.9, blue > 0.9 {
                matrix[y][x] = 255
            } else {
                matrix[y][x] = 0
            }
        }
    }
    return matrix
}

//Change To Gray
func convertToGrayscale(image: UIImage) -> UIImage? {
    guard let currentCGImage = image.cgImage else { return nil }
    
    let width = currentCGImage.width
    let height = currentCGImage.height
    
    let colorSpace = CGColorSpaceCreateDeviceGray()
    
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue).rawValue) else { return nil }
    
    let rect = CGRect(x: 0, y: 0, width: width, height: height)
    context.draw(currentCGImage, in: rect)
    
    guard let grayImage = context.makeImage() else { return nil }
    
    return UIImage(cgImage: grayImage)
}

//Save FaceLandmarks of the image to the disk
func saveFaceLandmarksToTxtFile(result: FaceLandmarkerResult, frameNumber: Int) {
    
    var outputText = "x, y\n"
    var frame = frameNumber
    let landmarks = result.faceLandmarks
    //landmarks is [[NormalizedLandmark]] type
    for face in landmarks{
        for landmark in face{
            outputText += "\(landmark.x), \(landmark.y)\n"
        }
    }
    // Append the pixel data of the current frame to the file
    let filename = getDocumentsDirectory().appendingPathComponent("Facelandmark_\(frame).txt")
    frame = frame + 1
    if let data = outputText.data(using: .utf8) {
        do {
            try data.write(to: filename)
            print("FaceLandmarks files are saved to: \(filename)")
        } catch {
            print("Error writing to file: \(error)")
        }
    }
}

//Save the image
func getDocumentsDirectory() -> URL {
    let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
    return paths[0]
}

func normalizeToPixelCoord(landmark: NormalizedLandmark, imageWidth: Int, imageHeight: Int) -> [Int] {
    let xPx = min(Int(floor(Double(landmark.x) * Double(imageWidth))), imageWidth - 1)
    let yPx = min(Int(floor(Double(landmark.y) * Double(imageHeight))), imageHeight - 1)
    return [xPx, yPx]
}

func mediapipeLineToPoint(lineList: [(Int, Int)]) -> [Int] {
    /*
    Convert mediapipe line list to a unique list of point indices. The lineList may contain multiple lines.
    e.g., [(10, 338), (338, 297), (332, 284), (284, 10)] to [10, 338, 297, 332, 284]
    */

    var indexSet = Set<Int>()
    for line in lineList {
        indexSet.insert(line.0)
        indexSet.insert(line.1)
    }
    // Convert the set back to an array to return a list of indices.
    return Array(indexSet).sorted() // Sorting is optional, if you need the points in a specific order.
}

func mediapipeLineToPointLine(lineList: [(Int, Int)]) -> [Int] {
    /*
    Convert mediapipe line to point line list, keep the line order.
    e.g. [(10, 338), (338, 297), (297, 332), (332, 284), (284, 10)] to [10, 338, 297, 332, 284]
    */

    var index: [Int] = []
    var lineSet: [Int: Int] = [:]

    // Convert the tuple list into a dictionary
    for line in lineList {
        lineSet[line.0] = line.1
    }

    // Append the first key of the dictionary to the index
    if let firstKey = lineSet.keys.first {
        index.append(firstKey)
    }

    // Traverse the dictionary based on the key-value connection and append to the index
    for _ in 0..<lineSet.count {
        if let nextValue = lineSet[index.last!] {
            index.append(nextValue)
        }
    }

    return index
}

/**
 @brief Converts a CGImage to a CVPixelBuffer representing a mask.

 @discussion This function utilizes the Vision framework to generate a foreground instance mask for the provided CGImage. It creates a `VNGenerateForegroundInstanceMaskRequest` to process the image, and then executes this request using a `VNImageRequestHandler`. The result is a mask highlighting the main instances (like subjects or objects) in the image, represented as a `CVPixelBuffer`. This can be particularly useful in image processing tasks where isolating certain elements from their background is necessary.

 @param CurFrame The CGImage representing the current frame to be processed.

 @return A CVPixelBuffer containing the generated mask. If the process fails, the function will cause a runtime error due to forced unwrapping of a nil optional.

 @warning This function uses forced unwrapping for the result (`res!`). In a production environment, it's recommended to handle the optional safely to avoid potential runtime crashes.
 */
//func landmarksToMask(CurFrame: UIImage) -> CVPixelBuffer {
//
//    var res : CVPixelBuffer?
//
//    guard let cgImage = CurFrame.cgImage else {
//        fatalError("Failed to get CGImage from UIImage")
//    }
//    let request = VNGenerateForegroundInstanceMaskRequest()
//
////    #if targetEnvironment(simulator)
////    request.usesCPUOnly = true
////    #endif
//
//    let handler = VNImageRequestHandler(cgImage: cgImage)
//
//    do {
//        try handler.perform([request])
//        guard let result = request.results?.first else {
//            fatalError("Unexpected result type from VNGenerateForegroundInstanceMaskRequest")
//        }
//        let output = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
//        res = output
//
//    } catch {
//        print("Failed to perform request: \(error)")
//    }
//    return res!
//
//}

func landmarksToFaceMask(imageSize: CGSize, landmarks: [NormalizedLandmark]) -> CVPixelBuffer? {
    // Face oval connection defines the outer boundary of the face
    let faceConnections = FaceLandmarker.faceOvalConnections()
    
    // Convert landmarks to pixel coordinates for the face oval
    var facePoints: [CGPoint] = []
    for conn in faceConnections {
        let startIdx = Int(conn.start)
        let point = normalizeToPixelCoord(
            landmark: landmarks[startIdx],
            imageWidth: Int(imageSize.width),
            imageHeight: Int(imageSize.height)
        )
        facePoints.append(CGPoint(x: point[0], y: point[1]))
    }
    
    // Create black background context
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let renderer = UIGraphicsImageRenderer(size: imageSize, format: format)
    let maskImage = renderer.image { ctx in
        UIColor.black.setFill()
        ctx.fill(CGRect(origin: .zero, size: imageSize))
        
        // Draw face oval as white filled polygon
        UIColor.white.setFill()
        let path = UIBezierPath()
        if let first = facePoints.first {
            path.move(to: first)
            for pt in facePoints.dropFirst() {
                path.addLine(to: pt)
            }
            path.close()
            path.fill()
        }
    }
    
    // Convert UIImage to CVPixelBuffer for downstream use
    return pixelBuffer(ciimage: CIImage(image: maskImage)!)
}

//func landmarksToMask(imageSize: CGSize, landmarks: [NormalizedLandmark]) -> [[Int]]? {
//    //    Convert landmarks generated by mediapipe to a mask
//    //    :param imageSize: size of columns in the image
//    //    :param landmarks: landmarks generated by mediapipe
//    //    :return: a boolean mask, same shape as the original image
//    var poly:[[Int]] = []
//    var polyIndex:[Int] = []
//    var lineList: [(Int, Int)] = []
//    //rightEyebrowConnections
//    //leftEyebrowConnections
//    //rightEyeConnections
//    //leftEyeConnections
//    //lipsConnections
//    //faceOvalConnections
//
//    //Creat Contour
//    for connection in FaceLandmarker.faceOvalConnections(){
//        lineList.append((Int(connection.start), Int(connection.end)))
//    }
//    polyIndex = mediapipeLineToPointLine(lineList: lineList)
//    for polyindex in polyIndex{
//        poly.append(normalizeToPixelCoord(landmark: landmarks[polyindex], imageWidth: Int(imageSize.width), imageHeight: Int(imageSize.height)))
//    }
//
//    //Create an image with the specified size
//    let format = UIGraphicsImageRendererFormat()
//    format.scale = 1
//    let renderer = UIGraphicsImageRenderer(size: imageSize, format: format)
//    let maskImage = renderer.image { context in
//        UIColor.black.setFill()
//        context.fill(CGRect(origin: .zero, size: imageSize))
//
//        let path = UIBezierPath()
//        if let firstPoint = poly.first {
//            path.move(to: CGPoint(x: firstPoint[0], y: firstPoint[1]))
//            for i in 1..<poly.count {
//                path.addLine(to: CGPoint(x: poly[i][0], y: poly[i][1]))
//            }
//            path.close()
//
//            UIColor.white.setFill()
//            path.fill()
//
//            //more white pixels
//            UIColor.white.setStroke()
//            path.lineWidth = 5
//            path.stroke()
//
//        }
//    }
//    return imageToMatrix(image: maskImage)
//}

/**
 @brief Converts facial landmarks to feature coordinates for specific facial features.

 @discussion This function processes facial landmarks to extract specific facial features like eyes or mouth. Based on the `featureType` parameter, it selects relevant landmarks and converts them into pixel coordinates corresponding to the provided image size. The function supports two feature types: "eye" and "mouth". For eyes, it uses a predefined set of landmark indices (`EYE_LANDMARKS`) to identify the regions around the eyes. For the mouth, it uses the `FaceLandmarker.lipsConnections()` method to determine the relevant landmarks. The landmarks are then normalized to pixel coordinates using the `normalizeToPixelCoord` function.

 @param imageSize The size of the image in which the landmarks are detected.
 @param landmarks An array of `NormalizedLandmark`, representing detected facial landmarks.
 @param featureType A string specifying the feature to extract, e.g., "eye" or "mouth".

 @return An optional array of arrays, where each sub-array contains pixel coordinates `[Int]` for a specific feature. Returns `nil` if an unrecognized feature type is provided.

 @note The function currently only supports "eye" and "mouth" as valid feature types. It logs an error message for any unrecognized type.
 */

func landmarksToFeature(imageSize: CGSize, landmarks: [NormalizedLandmark], featureType: String) -> [[Int]]? {
    var features:[[Int]] = []
    var polyIndex:[Int] = []
    var lineList: [(Int, Int)] = []
    //rightEyeConnections / leftEyeConnections / lipsConnections / faceOvalConnections
    if featureType == "eye" {
        //print("eye")
        //We use the wider set for eye detections : EYE_LANDMARKS
        polyIndex = [168, 193, 245, 128, 121, 120, 119, 118, 117, 111, 143, 139, 71, 68, 104, 69, 108,
                                     151, 337, 299, 333, 298, 301, 368, 372, 340, 346, 347, 348, 349, 350, 357, 465, 417,
                                     9, 107, 66, 105, 63, 70, 156, 336, 296, 334, 293, 300, 383,
                                     8, 55, 65, 52, 53, 46, 124, 35, 31, 228, 229, 230, 231, 232, 233, 244, 189,
                                     285, 295, 282, 283, 276, 353, 265,
                                     221, 222, 223, 224, 225, 113, 226, 25, 110, 24, 23, 22, 26, 112, 243, 190,
                                     56, 28, 27, 29, 30, 247, 130, 33, 7, 163, 144, 145, 153, 154, 155, 133, 173,
                                     157, 158, 159, 160, 161, 246,
                                     441, 442, 443, 444, 445, 342, 446, 261, 448, 449, 450, 451, 452, 453, 464, 413,
                                     286, 258, 257, 259, 260, 467, 359, 255, 339, 254, 253, 252, 256, 341, 463,
                                     414, 384, 385, 386, 387, 388, 466, 263, 249, 390, 373, 374, 380, 381, 382, 362, 308]

        for polyindex in polyIndex{
            features.append(normalizeToPixelCoord(landmark: landmarks[polyindex], imageWidth: Int(imageSize.width), imageHeight: Int(imageSize.height)))
        }
    } else if (featureType == "smile" || featureType == "tongue") {
        //print("mouth")
        for connection in FaceLandmarker.lipsConnections(){
            lineList.append((Int(connection.start), Int(connection.end)))
        }
        polyIndex = mediapipeLineToPoint(lineList: lineList)
        for polyindex in polyIndex{
            features.append(normalizeToPixelCoord(landmark: landmarks[polyindex], imageWidth: Int(imageSize.width), imageHeight: Int(imageSize.height)))
        }
    } else {
        print("Unrecognized feature type")
    }
    return features
}

func getOneFrame(imageCap: URL, frameNumber: Int, inferenceIntervalMs: Double) async -> UIImage?{
    var timestampMs = 0
    var Image:UIImage? = nil
    
    let videoAsset: AVAsset = AVAsset(url: imageCap)
    let assetGenerator = AVAssetImageGenerator(asset: videoAsset)
    
    assetGenerator.requestedTimeToleranceBefore = CMTimeMake(value: 1, timescale: 25)
    assetGenerator.requestedTimeToleranceAfter = CMTimeMake(value: 1, timescale: 25)
    assetGenerator.appliesPreferredTrackTransform = true
    
    timestampMs = Int(inferenceIntervalMs) * frameNumber // ms
    let image: CGImage
    do {
        let time = CMTime(value: Int64(timestampMs), timescale: 1000)
        //        CMTime(seconds: Double(timestampMs) / 1000, preferredTimescale: 1000)
        //(image, _) = try await assetGenerator.image(at: time)
        image = try assetGenerator.copyCGImage(at: time, actualTime: nil)
    } catch {
        print(error)
        return Image
    }
    
    return UIImage(cgImage: image)
}

func createMaskOneFrame(imageCap: URL, featureType: String, frameNumber: Int, inferenceIntervalMs: Double) async -> (CVPixelBuffer?, [[Int]]?, UIImage){
    var Masks: CVPixelBuffer?
    var Features: [[Int]]?
    var timestampMs = 0
    var Image: UIImage?
    
    let model_path = Bundle.main.path(forResource: "face_landmarker", ofType: "task")!
    let service = FaceLandmarkerService.videoLandmarkerService(
        modelPath: model_path,
        numFaces: 1,
        minFaceDetectionConfidence: 0.5,
        minFacePresenceConfidence: 0.5,
        minTrackingConfidence: 0.3,
        runningMode: .video
    )
    
    let videoAsset: AVAsset = AVAsset(url: imageCap)
    let assetGenerator = AVAssetImageGenerator(asset: videoAsset)
    
    assetGenerator.requestedTimeToleranceBefore = CMTimeMake(value: 1, timescale: 25)
    assetGenerator.requestedTimeToleranceAfter = CMTimeMake(value: 1, timescale: 25)
    assetGenerator.appliesPreferredTrackTransform = true
    
    timestampMs = Int(inferenceIntervalMs) * frameNumber // ms
    let image: CGImage
    do {
        let time = CMTime(value: Int64(timestampMs), timescale: 1000)
        //        CMTime(seconds: Double(timestampMs) / 1000, preferredTimescale: 1000)
        (image, _) = try await assetGenerator.image(at: time)
        //image = try assetGenerator.copyCGImage(at: time, actualTime: nil)
    } catch {
        print(error)
        return (Masks!, Features!, Image!)
    }

    let uiImage = UIImage(cgImage:image)
    Image = uiImage

    do {
        guard let result = try service?.faceLandmarker?.detect(
            videoFrame: MPImage(uiImage: uiImage),
            timestampInMilliseconds: timestampMs)else {
            return (Masks!, Features!, Image!) }
        let landmarks = result.faceLandmarks
        for landmark in landmarks{
            Masks = landmarksToFaceMask(imageSize: uiImage.size, landmarks: landmark)
            Features = landmarksToFeature(imageSize: uiImage.size, landmarks: landmark, featureType: featureType)
        }

//            saveFaceLandmarksToTxtFile(result: result, frameNumber: i)
    } catch {
        print(error)
        //faceLandmarkerResults.append(nil)
    }
    
    return (Masks!, Features!, Image!)
}

func createMask(
    url: URL,
    featureType: String,
    inferenceIntervalMs: Double,
    totalFrame: Int
) async -> (CVPixelBuffer?, [[Int]]) {
    var Masks: CVPixelBuffer?
    var Features: [[Int]]?
    var timestampMs = 0

    let model_path = Bundle.main.path(forResource: "face_landmarker", ofType: "task")!
    let service = FaceLandmarkerService.videoLandmarkerService(
        modelPath: model_path,
        numFaces: 1,
        minFaceDetectionConfidence: 0.5,
        minFacePresenceConfidence: 0.3,
        minTrackingConfidence: 0.3,
        runningMode: .video
    )

    let videoAsset = AVAsset(url: url)
    let assetGenerator = AVAssetImageGenerator(asset: videoAsset)
    assetGenerator.requestedTimeToleranceBefore = CMTimeMake(value: 1, timescale: 25)
    assetGenerator.requestedTimeToleranceAfter  = CMTimeMake(value: 1, timescale: 25)
    assetGenerator.appliesPreferredTrackTransform = true

    var frameNumber = 0
    let maxFramesToScan = min(totalFrame, 40)   // don’t scan too many frames

    var foundMask = false

    for i in 0..<maxFramesToScan {
        autoreleasepool {
            timestampMs = Int(inferenceIntervalMs) * i // ms

            // synchronous frame grab (no await here)
            let time = CMTime(value: Int64(timestampMs), timescale: 1000)
            guard let cgimage = try? assetGenerator.copyCGImage(at: time, actualTime: nil) else {
                print("Ignoring empty camera frame at frame \(i).")
                return
            }

            let uiImage = UIImage(cgImage: cgimage)

            do {
                guard let result = try service?.faceLandmarker?.detect(
                    videoFrame: MPImage(uiImage: uiImage),
                    timestampInMilliseconds: timestampMs
                ) else {
                    return
                }

                for landmark in result.faceLandmarks where landmark.count == 478 {
                    Masks = landmarksToFaceMask(imageSize: uiImage.size, landmarks: landmark)
                    Features = landmarksToFeature(imageSize: uiImage.size,
                                                  landmarks: landmark,
                                                  featureType: featureType)
                    foundMask = true
                    return   // exit this autoreleasepool iteration
                }
            } catch {
                print("FaceLandmarker error:", error)
                return
            }

            frameNumber += 1
        }

        if foundMask { break }
    }

    return (Masks, Features ?? [])
}

func todoapplyMask(image: UIImage, mask:CVPixelBuffer) -> CIImage{
        //    """
        //    Applies mask to images, changing everything outside the mask to a white background
        //
        //    :param image: numpy array, matrix representation of a image
        //    :param mask: numpy array, a boolean matrix, same shape as the image
        //    :return: None
        //    """
        let ciImage = CIImage(cgImage: image.cgImage!)
        let ciMask = CIImage(cvPixelBuffer: mask)
        let filter = CIFilter.blendWithMask()
        filter.inputImage = ciImage
        filter.maskImage = ciMask
        filter.backgroundImage = CIImage.empty()
        let res = filter.outputImage!
        return res
    
}

func applyMask(image: UIImage, mask: CVPixelBuffer) -> CIImage {
    let ciImage = CIImage(cgImage: image.cgImage!)
    let ciMask = CIImage(cvPixelBuffer: mask)
    
    // Create a fully transparent background image
    let transparentBackground = CIImage(color: .clear)
        .cropped(to: ciImage.extent)
    
    // Blend the original image with transparency outside the mask
    let filter = CIFilter.blendWithMask()
    filter.inputImage = ciImage
    filter.maskImage = ciMask
    filter.backgroundImage = transparentBackground
    
    guard let output = filter.outputImage else {
        print("⚠️ Failed to apply transparency mask")
        return ciImage
    }
    return output
}


func runPydic(imgList: [CIImage],
              mask: CVPixelBuffer,
              ptsList: [[Int]],
              correlWindSize: [Int] = [85, 85],
              correlGridsSize: [Int] = [20, 20],
              
              areaOfInterests: String = "all") -> ([Double], [[Double?]], [[Int]]){
        let (metaX, metaY, pointList) = initialize(imgList: imgList, winSizePx: correlWindSize, gridSizePx: correlGridsSize, areaOfInterest: areaOfInterests)!
        //(Int, Int) -> [[Double?]]
        return readDicFilePlotting(metaXInfo: metaX, metaYInfo: metaY, pointList: pointList, mask: mask, ptsList: ptsList)
}
//
//func createVideo(from images: [UIImage?], outputURL: URL, fps: Int32, completion: @escaping (Bool) -> Void) {
//    guard let firstImage = images.compactMap({ $0 }).first else {
//        completion(false)
//        return
//    }
//
//    let videoSettings: [String: Any] = [
//        AVVideoCodecKey: AVVideoCodecType.h264,
//        AVVideoWidthKey: NSNumber(value: Float(firstImage.size.width)),
//        AVVideoHeightKey: NSNumber(value: Float(firstImage.size.height))
//    ]
//
//    let writer = try! AVAssetWriter(outputURL: outputURL, fileType: .mp4)
//    let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
//    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: writerInput, sourcePixelBufferAttributes: nil)
//
//    writer.add(writerInput)
//    writer.startWriting()
//    writer.startSession(atSourceTime: .zero)
//
//    var frameCount = 0
//    let frameDuration = CMTime(value: 1, timescale: fps)
//    let queue = DispatchQueue(label: "mediaInputQueue")
//    writerInput.requestMediaDataWhenReady(on: queue) {
//        while writerInput.isReadyForMoreMediaData && frameCount < images.count {
//            if let image = images[frameCount], let buffer = pixelBuffer(from: image) {
//                let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(frameCount))
//                adaptor.append(buffer, withPresentationTime: presentationTime)
//                frameCount += 1
//            }
//        }
//
//        if frameCount >= images.count {
//            writerInput.markAsFinished()
//            writer.finishWriting {
//                DispatchQueue.main.async {
//                    completion(writer.status == .completed)
//                }
//            }
//        }
//    }
//}

func combineCGImagesVertically(image1: CGImage, image2: CGImage) -> CGImage? {
    let width = max(image1.width, image2.width)
    let height = image1.height + image2.height

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo) else {
        return nil
    }

    context.draw(image1, in: CGRect(x: 0, y: 0, width: image1.width, height: image1.height))
    context.draw(image2, in: CGRect(x: 0, y: image1.height, width: image2.width, height: image2.height))

    return context.makeImage()
}

/**
 @brief Draws facial landmarks on a given UIImage and returns the result as a CGImage.

 @discussion This function takes an UIImage and an array of facial landmarks, then draws these landmarks on the image. It first converts the normalized landmark coordinates to pixel coordinates suitable for the image size. It then creates a graphics context, draws the original image as the background, and draws each landmark as a small ellipse on the image. This function is particularly useful for visualizing the output of facial recognition or tracking algorithms.

 @param originalImage The UIImage on which landmarks are to be drawn.
 @param landmarks An array of `NormalizedLandmark` structures representing detected facial landmarks.

 @return An optional CGImage containing the original image with landmarks drawn on it. Returns `nil` if the graphics context cannot be created.

 @note The function assumes that the landmark coordinates are normalized (i.e., in the range of 0 to 1). These are converted to pixel coordinates based on the size of the original image.
 */
func drawLandmarksOnImage(originalImage: UIImage, landmarks: [NormalizedLandmark]) -> CGImage? {
    var features: [[Int]] = []

    // Convert normalized landmark coordinates to pixel coordinates
    for landmark in landmarks {
        let pixelCoord = normalizeToPixelCoord(landmark: landmark, imageWidth: Int(originalImage.size.width), imageHeight: Int(originalImage.size.height))
        features.append(pixelCoord)
    }

    // Begin a graphics context
    UIGraphicsBeginImageContextWithOptions(originalImage.size, false, 0)
    guard let context = UIGraphicsGetCurrentContext() else { return nil }

    // Draw the original image as the background
    originalImage.draw(at: CGPoint.zero)

    // Set properties for landmark drawing (like color and size)
    context.setStrokeColor(UIColor.red.cgColor)
    context.setLineWidth(2)

    // Draw landmarks
    for feature in features {
        let x = feature[0]
        let y = feature[1]
        let rect = CGRect(x: x, y: y, width: 5, height: 5)
        context.strokeEllipse(in: rect)
    }

    // Retrieve the image
    let newImage = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()

    return newImage?.cgImage
}

func drawLandmarksAndBlendshapesOnImage(originalImage: UIImage, blendshapes: [Classifications]) -> CGImage? {
    UIGraphicsBeginImageContextWithOptions(originalImage.size, false, 0)
    guard let context = UIGraphicsGetCurrentContext() else { return nil }

    // Draw the original image
    originalImage.draw(at: CGPoint.zero)
    var text: String = ""

    // Draw blendshapes information
    let fontSize: CGFloat = 60
    let font = UIFont.systemFont(ofSize: fontSize)
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = .right
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .paragraphStyle: paragraphStyle,
        .foregroundColor: UIColor.white
    ]
    var textY: CGFloat = 0 // Starting position for the text

    // Flatten and sort the categories by score in descending order
    let sortedCategories = blendshapes.flatMap { $0.categories }
                                      .sorted { $0.score > $1.score }

    for item in sortedCategories {
        if let categoryName = item.categoryName {
            let scoreString = String(format: "%.3f", item.score)
            text = "\(categoryName): \(scoreString)"
        }
        let textWidth = originalImage.size.width * 0.95
        let textX = originalImage.size.width - textWidth
        let textRect = CGRect(x: textX, y: textY, width: textWidth, height: fontSize * 1.2)
        text.draw(with: textRect, options: .usesLineFragmentOrigin, attributes: attrs, context: nil)
        textY += fontSize * 1.2 + 4 // Adjust for spacing
    }

    let newImage = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()

    return newImage?.cgImage
}


