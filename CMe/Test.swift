import Foundation
import SwiftUI
import KDTree
import AVFoundation
import MediaPipeTasksVision
import UIKit
import CoreImage
import CoreVideo
import Vision
import Foundation
import Photos



//detectMask() Test

//            Task {
//                    image = await detectMask()
//
//            }


//Main test

//            let frame0 = UIImage(named: "frame_0")
//            image = frame0
//            let landmark0 = detectSilentFaceLandmarks(name: "frame_0", framenumber:0)
//            var masks0 : [[Int]]?
//            var features0 : [[Int]]?
//            var masks1 : [[Int]]?
//            var features1 : [[Int]]?
//            for faceLandmarkerResult in landmark0 {
//                if let landmarks = faceLandmarkerResult?.faceLandmarks{
//                    for face in landmarks{
//                        let Masks0 = landmarksToMask(imageSize: frame0!.size, landmarks: face)
//                        let Features0 = landmarksToFeature(imageSize: frame0!.size, landmarks: face, featureType: "mouth")
//                        masks0 = Masks0
//                        features0 = Features0
//                    }
//                }}
//            let frame1 = UIImage(named: "frame50")
//            let landmark1 = detectSilentFaceLandmarks(name: "frame50", framenumber:50)
//            for faceLandmarkerResult in landmark1 {
//                if let landmarks = faceLandmarkerResult?.faceLandmarks{
//                    for face in landmarks{
//                        let Masks1 = landmarksToMask(imageSize: frame1!.size, landmarks: face)
//                        let Features1 = landmarksToFeature(imageSize: frame1!.size, landmarks: face, featureType: "mouth")
//                        masks1 = Masks1
//                        features1 = Features1
//                    }
//                }}
//            let mask_frame0=applyMask(image: frame0!, mask: masks1)
//            let mask_frame1=applyMask(image: frame1!, mask: masks1)
//
//            var metaXInfo: (Double, Double, Double, Double)
//            var metaYInfo: (Double, Double, Double, Double)
//            var fullPoints : [[[Double?]]] = []
//            var heatmap : [[Double?]] = []
//            (_, heatmap, _ ) = runPydic(imgList: [mask_frame0!,mask_frame1!], mask: masks1!, ptsList:features1!)

//            (metaXInfo, metaYInfo, fullPoints) = initialize(imgList: [mask_frame0!,mask_frame1!], winSizePx: [85, 85], gridSizePx: [20, 20], areaOfInterest: "all")!
////
////            var testfullPoints : [[[Double?]]] = []
////            var fullPoints1 = parseAndReadFile(named: "points_in")
////            var fullPoints2 = parseAndReadFile(named: "final_point")
////            testfullPoints.append(fullPoints1)
////            testfullPoints.append(fullPoints2)
////
////
////            (_, heatmap, _ ) = readDicFilePlotting(metaXInfo: metaXInfo, metaYInfo: metaYInfo, pointList: testfullPoints, mask: masks1!, ptsList: features1!)
//                //Print the result
//            let bgrImage = createBGRImageFromGrayMatrix(grayMatrix:transpose(matrix: heatmap))
//            let resizedImage = resizeImage(bgrImage!, toSize: CGSize(width: 1920, height: 1080))
//            let final = verticallyStackImages(image1: frame1!, image2: resizedImage!)
//            let maxVal = heatmap.compactMap { $0.compactMap { $0 } }.flatMap { $0 }.max()
//            image = final


//SVD() Test

//            let p1: [[Double?]] = [
//                [1, 1],
//                [2, 2],
//                [3, 3]
//            ]
//
//            let p2: [[Double?]] = [
//                [1.5, 1.5],
//                [2.5, 2.5],
//                [3.5, 3.5]
//            ]
//
//            _ = computeDispAndRemoveRigidTransform(P1: p1, P2: p2)

//            Task {
//                await processOneVideo(url: videoURL)
//            }


//Get frames from Videos
func getFrame(atTime time: Double, fromVideo videoURL: URL) async -> UIImage? {
    let asset = AVURLAsset(url: videoURL)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    
    let timestamp = CMTime(seconds: time, preferredTimescale: 60)
    
    do {
        let (imageRef, actualTime) = try await generator.image(at: timestamp)
        print("Actual time is: \(actualTime)")
        return UIImage(cgImage: imageRef)
    } catch {
        print("Error generating image: \(error)")
        return nil
    }
}

//Load the frame and save ARGB of the image to the disk
func loadFrames(count: Int, fromVideo videoURL: URL) {
    Task {
        for i in 0..<count {
            if let frameImage = await getFrame(atTime: Double(i)/30.0, fromVideo: videoURL) {
                saveImageARGBToDisk(image: frameImage, frameNumber: i)
            }
        }
    }
}

//    //Load one image and save ARGB of the image to the disk
//    func loadImage() {
//        if let image = UIImage(named: "sampleImage") {
//            saveImageARGBToDisk(image: image, frameNumber: 1)
//            isImageLoaded = true
//        }
//    }

//Save ARGB of the image to the disk
func saveImageARGBToDisk(image: UIImage, frameNumber: Int) {
    if let cgImage = image.cgImage {
        let width = cgImage.width
        let height = cgImage.height
        
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            print("Error: Couldn't create color space.")
            return
        }
        
        let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: cgImage.bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo),
              let pixelBuffer = context.data else {
            print("Error: Couldn't create context or access pixel buffer.")
            return
        }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        let pixelData = pixelBuffer.bindMemory(to: UInt8.self, capacity: cgImage.bytesPerRow * height)
        var outputText = ""
        
        for y in 0..<height {
            for x in 0..<width {
                let pixelIndex = (y * width + x) * 4
                //*9/10
                //let A = pixelData[pixelIndex]
                let R = pixelData[pixelIndex + 1]
                let G = pixelData[pixelIndex + 2]
                let B = pixelData[pixelIndex + 3]
                outputText += "Pixel (\(x), \(y)): R=\(R) G=\(G) B=\(B)\n"
            }
        }
        
        // Append the pixel data of the current frame to the file
        let filename = getDocumentsDirectory().appendingPathComponent("swift_rgb_\(frameNumber).txt")
        if let data = outputText.data(using: .utf8) {
            do {
                try data.write(to: filename)
                print("Frame ARGB files are saved to: \(filename)")
            } catch {
                print("Error writing to file: \(error)")
            }
        }
    }
}

//Load the image and write it to the disk
func saveImageToDisk(image: UIImage, frame: Int) {
    if let data = image.pngData() {
        let filename = getDocumentsDirectory().appendingPathComponent("frame_\(frame)_at_swift.png")
        try? data.write(to: filename)
        print("Image saved to: \(filename)")
    }
}

//Save the image
//func getDocumentsDirectory() -> URL {
//    let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
//    return paths[0]
//}

//Test the silent image
func detectSilentFaceLandmarks(name: String, framenumber: Int) -> [FaceLandmarkerResult?]{
        let model_path = Bundle.main.path(forResource: "face_landmarker", ofType: "task")!
        //print(model_path)
        let service = FaceLandmarkerService.stillImageLandmarkerService(
            modelPath: model_path,
            numFaces: 1,
            minFaceDetectionConfidence: 0.5,
            minFacePresenceConfidence: 0.5,
            minTrackingConfidence: 0.3,
            runningMode: .image
        )
        
        let image = UIImage(named: name)
        let result = service?.detect(image: image!)
        let facelandmarkerResults = result?.faceLandmarkerResults
        saveFaceLandmarksToTxtFile(result: facelandmarkerResults!, frameNumber: framenumber)
        return facelandmarkerResults!
         
    }

//Save FaceLandmarks of the image to the disk
func saveFaceLandmarksToTxtFile(result: [FaceLandmarkerResult?], frameNumber: Int) {
    
    var outputText = "x, y\n"
    var frame = frameNumber
    for faceLandmarkerResult in result{
        if let landmarks = faceLandmarkerResult?.faceLandmarks{
            //landmarks is [[NormalizedLandmark]] type
            for face in landmarks{
                for landmark in face{
                    outputText += "\(landmark.x), \(landmark.y)\n"
                }
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
    
}

//Test the videos
func detectVideoFaceLandmarks(fromVideo videoURL: URL){
        let model_path = Bundle.main.path(forResource: "face_landmarker", ofType: "task")!
        //print(model_path)
        let service = FaceLandmarkerService.videoLandmarkerService(
            modelPath: model_path,
            numFaces: 1,
            minFaceDetectionConfidence: 0.5,
            minFacePresenceConfidence: 0.5,
            minTrackingConfidence: 0.5,
            runningMode: .video
        )
        
        Task{
            if let results = await service?.detect(url: videoURL, durationInMilliseconds: 100,
                                                  inferenceIntervalInMilliseconds: 20){
                let facelandmarkerResults = results.faceLandmarkerResults
                saveFaceLandmarksToTxtFile(result: facelandmarkerResults, frameNumber: 0)
            }
            
        }
    }

//Print [[[Double?]]]
func printTripleNestedArray(array: [[[Double?]]]) {
    for (i, twoDArray) in array.enumerated() {
        print("Layer \(i):")
        for oneDArray in twoDArray {
            let values = oneDArray.map { $0 != nil ? "\($0!)" : "nil" }
            print("[\(values.joined(separator: ", "))]")
        }
        print("\n")
    }
  }


//Reading the frames using AVAssetReader, it is another method to read the frame

//    func imageFromVideo(url: URL, frameNumber: Int) -> UIImage? {
//        let asset = AVAsset(url: url)
//
//        guard let track = asset.tracks(withMediaType: .video).first else {
//            return nil
//        }
//
//        let frameRate = track.nominalFrameRate
//        let frameTime = CMTimeMake(value: Int64(frameNumber), timescale: Int32(frameRate))
//
//        do {
//            let reader = try AVAssetReader(asset: asset)
//            let outputSettings: [String: Any] = [
//                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
//            ]
//
//            let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
//            reader.add(output)
//            reader.startReading()
//
//            while let sampleBuffer = output.copyNextSampleBuffer() {
//                if CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer) >= frameTime {
//                    guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
//                        return nil
//                    }
//
//                    let ciImage = CIImage(cvPixelBuffer: imageBuffer)
//                    let unpremultipliedImage = ciImage.unpremultiplyingAlpha()
//                    let context = CIContext()
//
//                    if let cgImage = context.createCGImage(unpremultipliedImage, from: unpremultipliedImage.extent) {
//                        return UIImage(cgImage: cgImage)
//                    }
//
//                    break
//                }
//            }
//        } catch {
//            print("Error extracting image from video: \(error)")
//        }
//
//        return nil
//    }

func saveMatrixToTextFile(matrix: [[Int]], withFileName fileName: String) {
    guard let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
        print("Documents directory not found")
        return
    }
    let fileURL = documentsDirectory.appendingPathComponent("\(fileName).txt")

    let stringRepresentation = matrix.map { row in
        row.map { String($0) }.joined(separator: " ")
    }.joined(separator: "\n")
    do {
        try stringRepresentation.write(to: fileURL, atomically: true, encoding: .utf8)
        print("Matrix was saved to: \(fileURL)")
    } catch {
        print("Failed to write matrix to text file: \(error)")
    }
}

func saveDoubleMatrixToTextFile(matrix: [[Double?]], named fileName: String) {
    guard let documentDirectoryUrl = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
        print("Document directory could not be found.")
        return
    }
    let fileUrl = documentDirectoryUrl.appendingPathComponent(fileName)

    let stringRepresentation = matrix.map { row in
        row.map { $0 != nil ? String(describing: $0!) : "nil" }.joined(separator: ", ")
    }.joined(separator: "\n")
    do {
        try stringRepresentation.write(to: fileUrl, atomically: true, encoding: .utf8)
        print("File saved successfully to: \(fileUrl.path)")
    } catch {
        print("Error saving file to directory: \(error)")
    }
}

func parseAndReadFile(named fileName: String) -> [[Double?]] {
    guard let path = Bundle.main.path(forResource: fileName, ofType: "txt") else {
        fatalError("File \(fileName).txt not found.")
    }
    
    do {
        let content = try String(contentsOfFile: path, encoding: .utf8)
        let rows = content.split(separator: "\n")
        return rows.map { row in
            let values = row.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                          .split(separator: " ")
                          .compactMap { Double($0) }
            return values.count > 0 ? values : [nil, nil]
        }
    } catch {
        fatalError("Unable to read the \(fileName).txt file: \(error).")
    }
}


//Test the createMaskOneFrame

//    func detectMask() async -> UIImage?{
//        var Masks2: [[Int]]?
//        var Features2: [[Int]]?
//        var img1: UIImage?
//        var img2: UIImage?
//        var time: Double = 0
//        var totalFrame : Int = 0
//
//
//        (time, totalFrame) = await getVideoInterval(imageCap: videoURL)


//Test the createMaskOneFrame

//        (_, _, img1) = await createMaskOneFrame(imageCap: videoURL, featureType: "mouth", frameNumber: 0, inferenceIntervalMs: time)
//        (Masks2, Features2, img2) = await createMaskOneFrame(imageCap: videoURL, featureType: "mouth", frameNumber: 50, inferenceIntervalMs: time)
//
//        let mask_frame0=applyMask(image: img1!, mask: Masks2)
//        let mask_frame1=applyMask(image: img2!, mask: Masks2)
//
//        var heatmap : [[Double?]] = []
//        (_, heatmap, _ ) = runPydic(imgList: [mask_frame0!,mask_frame1!], mask: Masks2!, ptsList:Features2!)
//        let bgrImage = createBGRImageFromGrayMatrix(grayMatrix:transpose(matrix: heatmap))
//        let resizedImage = resizeImage(bgrImage!, toSize: CGSize(width: 1920, height: 1080))
//        let final = verticallyStackImages(image1: img2!, image2: resizedImage!)


// Test createMask

//        (Masks2, Features2) = await createMask(imageCap: videoURL, featureType: "mouth", inferenceIntervalMs: time, totalFrame: totalFrame)
//        (_, _, img1) = await createMaskOneFrame(imageCap: videoURL, featureType: "mouth", frameNumber: 200, inferenceIntervalMs: time)
//
//        let mask_frame0=applyMask(image: img1!)
//
//        return mask_frame0
//    }
