import Foundation
import UIKit
import CoreImage
import Vision
import VisionKit
import simd
import KDTree
import Accelerate

func initialize(
    imgList: [CIImage],
    winSizePx: [Int],
    gridSizePx: [Int],
    areaOfInterest: String,
    deepFlow: Bool = false
) -> (metaXInfo: (Double, Double, Double, Double), metaYInfo:  (Double, Double, Double, Double), fullPoints: [[[Double?]]])? {
    
    
    assert(imgList.count > 1, "There are no images in the input")
//    let first = CFAbsoluteTimeGetCurrent()
    
    guard let imgRef = imgList.first else { return nil }
    let y1 = imgRef.extent.height
    let x1 = imgRef.extent.width
    var area : [(Int, Int)] = []
    var metaXInfo: (Double, Double, Double, Double)
    var metaYInfo: (Double, Double, Double, Double)
    var pointToProcess : [[Double?]]
    var finalPoint : [[Double?]]
    
    if (areaOfInterest == "all") {
        area.append((0, 0))
        area.append((Int(x1), Int(y1)))
    } else {
        print("Please pick your area of interest on the picture")
        // TODO: Implement the function to pick area of interest
    }
    
    var fullPoints : [[[Double?]]] = []
    var points: [[Double?]] = []
    let first = CFAbsoluteTimeGetCurrent()
   
    let pointsX: [Int] = Array(stride(from: area[0].0, to: area[1].0, by: gridSizePx[0]))
    let pointsY: [Int] = Array(stride(from: area[0].1, to: area[1].1, by: gridSizePx[1]))

    if (deepFlow != false) {
        assert(imgList.count > 1, "There is no image in the input")
        let pointsX = Array(stride(from: area[0].0, to: area[1].0, by: 1))
        let pointsY = Array(stride(from: area[0].1, to: area[1].1, by: 1))
        for x in pointsX {
            for y in pointsY {
                points.append([Double(x), Double(y)])
            }
        }
    }else{
        //Main case
        for x in pointsX {
            for y in pointsY {
                points.append([Double(x), Double(y)])
            }
        }
    }
    let fif = CFAbsoluteTimeGetCurrent()
    //print(fif - first)
    
    let pointsIn : [[Double?]] = removePointsOutside(points: points, area: area)

    guard let imgRef = imgList.first else {
        fatalError("Image list is empty!")
    }
    
    let xmin : Double = Double(pointsX.first!)
    let xmax : Double = Double(pointsX.last!)
    let xnum : Double = Double(pointsX.count)
    
    let ymin : Double = Double(pointsY.first!)
    let ymax : Double = Double(pointsY.last!)
    let ynum : Double = Double(pointsY.count)

    metaXInfo = (xmin, xmax, xnum, Double(winSizePx[0]))
    metaYInfo = (ymin, ymax, ynum, Double(winSizePx[1]))
    
    pointToProcess = pointsIn
    fullPoints.append(pointToProcess)

    for i in 0..<imgList.count-1 {
        let imageRef = imgList[0]
        let imageStr = imgList[i + 1]
        
        if (deepFlow != false) {
            finalPoint = calcOpticalFlowFarneback(from: imageRef, to: imageStr, points: pointsIn)!
            pointToProcess = finalPoint

        } else {
            //Main case
            finalPoint = calcOpticalFlowFarneback(from: imageRef, to: imageStr, points: pointsIn)!
            //finalPoint = calcOpticalFlowPyrLK(from: imageRef, to: imageStr, points: pointsIn)!
            pointToProcess = finalPoint
        }
        
        fullPoints.append(pointToProcess)
    }
    return (metaXInfo, metaYInfo, fullPoints)
}

func readDicFilePlotting(
    metaXInfo: (Double, Double, Double, Double),
    metaYInfo: (Double, Double, Double, Double),
    pointList: [[[Double?]]],
    mask: CVPixelBuffer,
    ptsList: [[Int]],//feature
    interpolation: String = "raw",
    saveImage: Bool = true,
    scaleDisp: Double = 1.0,
    scaleGrid: Double = 25.0,
    metaInfoFile: String? = nil
) -> ([Double], [[Double?]], [[Int]]) {
//    let first = CFAbsoluteTimeGetCurrent()
    let (xmin, xmax, xnum, winSizeX) = metaXInfo
    let (ymin, ymax, ynum, winSizeY) = metaYInfo
    let winSize = [winSizeX, winSizeY]
    let (gridX, gridY) = mgrid(xmin: xmin, xmax: xmax, xnum: xnum, ymin: ymin, ymax: ymax, ynum: ynum)
    
    
    let myGrid = Grid(gridX: gridX, gridY: gridY, sizeX: xnum, sizeY: ynum)
    let disp = computeDispAndRemoveRigidTransform(P1: pointList[1], P2: pointList[0])
    myGrid.addRawData(winsize: winSize, referencePoint: pointList[0], correlatedPoint: pointList[1], disp: disp)
    myGrid.interpolateDisplacement(points: pointList[0], disp: disp)
    
    CVPixelBufferLockBaseAddress(mask, CVPixelBufferLockFlags.readOnly)
    let baseAddress = CVPixelBufferGetBaseAddress(mask)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(mask)
    let width = CVPixelBufferGetWidth(mask)
    let height = CVPixelBufferGetHeight(mask)
    
    var fullDispXyIndi: [Int:Double] = [:]
    for i in 0..<myGrid.gridX.count {
        for j in 0..<myGrid.gridX[i].count {
               let x = Int(myGrid.gridX[i][j]!)
               let y = Int(myGrid.gridY[i][j]!)
               //x/y in Image and matrix is different
                if (x >= 0 && y >= 0 && x < width && y < height) {
                    let pixel = baseAddress?.advanced(by: y * bytesPerRow + x * 4)
                    let pixelData = pixel?.assumingMemoryBound(to: UInt32.self).pointee
                    let r = UInt8((pixelData! >> 24) & 255)
                    let g = UInt8((pixelData! >> 16) & 255)
                    let b = UInt8((pixelData! >> 8) & 255)
                    if r == 0 && g == 0 && b == 0 {
                        myGrid.dispXYIndi[i][j] = 0
                    }
            }
            fullDispXyIndi[Int(x*1060+y)] = myGrid.dispXYIndi[i][j]
            
        }
    }
    
    CVPixelBufferUnlockBaseAddress(mask, CVPixelBufferLockFlags.readOnly)
    
//    for pointArray in myGrid.dispXYIndi {
//        let filteredArray = pointArray.compactMap { $0 }
//        if !filteredArray.isEmpty {
//            let pointStrings = filteredArray.map { String($0) }
//            print("[" + pointStrings.joined(separator: ", ") + "]")
//        }
//    }
    var landmarkValue: [Double] = []
    var gridValues: [[Int]] = []
    for i in 0..<gridX.count {
        for j in 0..<gridX[i].count {
            gridValues.append([Int(gridX[i][j]), Int(gridY[i][j])])
        }
    }
    
    let gridValueCG: [CGPoint] = gridValues.compactMap { (pair) -> CGPoint? in
        guard pair.count == 2 else { return nil }
        return CGPoint(x: pair[0], y: pair[1])
    }
    
    let tree: KDTree<CGPoint> = KDTree(values: gridValueCG)
    for pt in ptsList {
        let index = tree.nearest(to: CGPoint(x: pt[0], y: pt[1]))
        landmarkValue.append(fullDispXyIndi[(Int(index!.x))*1060+(Int(index!.y))]!)
    }
    return (landmarkValue, myGrid.dispXYIndi, ptsList)
}

func removePointsOutside(points: [[Double?]], area: [(Int, Int)], shape: String = "box") -> [[Double?]] {
    let xmin = Double(area[0].0)
    let xmax = Double(area[1].0)
    let ymin = Double(area[0].1)
    let ymax = Double(area[1].1)
    
    var result: [[Double?]] = []
    
    for point in points {
        if point[0]! >= xmin && point[0]! <= xmax && point[1]! >= ymin && point[1]! <= ymax {
            result.append(point)
        }
    }
    return result
}

func addTextToImage(image: UIImage, text: String, at position: (Double, Double)) -> UIImage? {
    let textColor = UIColor.white
    let textFont = UIFont(name: "Helvetica Bold", size: 18)!
    
    let scale = UIScreen.main.scale
    UIGraphicsBeginImageContextWithOptions(image.size, false, scale)
    
    let textFontAttributes = [
        NSAttributedString.Key.font: textFont,
        NSAttributedString.Key.foregroundColor: textColor,
    ] as [NSAttributedString.Key : Any]
    
    image.draw(in: CGRect(origin: CGPoint.zero, size: image.size))
    
    let rect = CGRect(origin: CGPoint(x: position.0, y: position.1), size: image.size)
    text.draw(in: rect, withAttributes: textFontAttributes)
    
    let newImage = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()
    
    return newImage
}

//calcOpticalFlowFarneback
func calcOpticalFlowFarneback(from firstFrame: CIImage,
                                 to secondFrame: CIImage,
                                 points: [[Double?]]) -> [[Double?]]? {

    guard let toPixelBuffer = pixelBuffer(ciimage: secondFrame) else {
            return nil
        }
    guard let fromPixelBuffer = pixelBuffer(ciimage: firstFrame) else {
            return nil
        }
    
    let opticalFlowRequest = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: toPixelBuffer, options: [:])
    opticalFlowRequest.revision = VNGenerateOpticalFlowRequestRevision2
    opticalFlowRequest.computationAccuracy = .veryHigh

    let handler = VNImageRequestHandler(cvPixelBuffer: fromPixelBuffer, options: [:])
//    let first = CFAbsoluteTimeGetCurrent()
    try? handler.perform([opticalFlowRequest])
//    let fif = CFAbsoluteTimeGetCurrent()
//    print(fif - first)

    guard let results = opticalFlowRequest.results,
          let flowResults = results.first else { return nil }

    let flowData = flowResults.pixelBuffer

    var newPoints: [[Double?]] = []
    newPoints = applyOpticalFlowToPoints(points: points, flowData: flowData)
    return newPoints
}

//func pixelBuffer(ciimage: CIImage) -> CVPixelBuffer? {
//    let attributes: [String: Any] = [
//        kCVPixelBufferCGImageCompatibilityKey as String: true,
//        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
//    ]
//    
//    var pixelBuffer: CVPixelBuffer?
//    CVPixelBufferCreate(kCFAllocatorDefault, Int(ciimage.extent.width), Int(ciimage.extent.height), kCVPixelFormatType_32ARGB, attributes as CFDictionary, &pixelBuffer)
//    
//    let context = CIContext()
//    context.render(ciimage, to: pixelBuffer!)
//    
//    return pixelBuffer
//}

/// Shared CIContext for all CIImage → CVPixelBuffer conversions (avoids leaks)
private let sharedCIContext: CIContext = CIContext(options: [.cacheIntermediates: false])

func pixelBuffer(ciimage: CIImage) -> CVPixelBuffer? {
    let attributes: [String: Any] = [
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
    ]
    
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        Int(ciimage.extent.width),
        Int(ciimage.extent.height),
        kCVPixelFormatType_32ARGB,
        attributes as CFDictionary,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pb = pixelBuffer else {
        return nil
    }

    sharedCIContext.render(ciimage, to: pb)
    return pb
}


//calcOpticalFlowPyrLK
func calcOpticalFlowPyrLK(from firstFrame: CIImage,
                 to secondFrame: CIImage,
                 points: [[Double?]]) -> [[Double?]]? {
    
    let opticalFlowRequest = VNTrackOpticalFlowRequest()
    opticalFlowRequest.revision = VNTrackOpticalFlowRequestRevision1
    opticalFlowRequest.computationAccuracy = .low
    
    guard let firstToPixelBuffer = pixelBuffer(ciimage: firstFrame) else {
            return nil
        }
    guard let secondToPixelBuffer = pixelBuffer(ciimage: secondFrame) else {
            return nil
        }

    let handler1 = VNImageRequestHandler(cvPixelBuffer: firstToPixelBuffer)
    do {
        try handler1.perform([opticalFlowRequest])
    } catch {
        print("Error processing previousImage: \(error)")
        return nil
    }
    
    let handler2 = VNImageRequestHandler(cvPixelBuffer: secondToPixelBuffer)
    do {
        try handler2.perform([opticalFlowRequest])
    } catch {
        print("Error processing currentImage: \(error)")
        return nil
    }
    guard let results = opticalFlowRequest.results,
          let flowResults = results.first else { return nil }
    
    let flowData = flowResults.pixelBuffer

    var newPoints: [[Double?]] = []
    newPoints = applyOpticalFlowToPoints(points: points, flowData: flowData)
    return newPoints
}

func applyOpticalFlowToPoints(points: [[Double?]], flowData: CVPixelBuffer) -> [[Double?]] {
    var newPoints: [[Double?]] = []
    CVPixelBufferLockBaseAddress(flowData, CVPixelBufferLockFlags.readOnly)

    _ = CVPixelBufferGetWidth(flowData)
    _ = CVPixelBufferGetHeight(flowData)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(flowData)

    if let baseAddress = CVPixelBufferGetBaseAddress(flowData) {
        // Process each row
        for point in points{
            let x = Int(point[0]!)
            let y = Int(point[1]!)
            let currentRow = baseAddress.advanced(by: bytesPerRow * y)
            let pixelOffset = x * MemoryLayout<(Float, Float)>.size
            let flowDataPointer = currentRow.assumingMemoryBound(to: (Float, Float).self).advanced(by: pixelOffset / MemoryLayout<(Float, Float)>.size)
            let flowVector = flowDataPointer.pointee
            //print(flowVector)
            newPoints.append([point[0]! + Double(flowVector.0), point[1]! + Double(flowVector.1)])
        }
    }
    CVPixelBufferUnlockBaseAddress(flowData, CVPixelBufferLockFlags.readOnly)
//    //Print the result
//    for pointArray in newPoints {
//        let filteredArray = pointArray.compactMap { $0 }
//        if !filteredArray.isEmpty {
//            let pointStrings = filteredArray.map { String($0) }
//            print("[" + pointStrings.joined(separator: ", ") + "]")
//        }
//    }
    return newPoints
}

func mgrid(xmin: Double, xmax: Double, xnum: Double, ymin: Double, ymax: Double, ynum: Double) -> (gridX: [[Double]], gridY: [[Double]]) {
    let xStep = (xmax - xmin) / Double(xnum - 1)
    let yStep = (ymax - ymin) / Double(ynum - 1)

    var gridX: [[Double]] = []
    var gridY: [[Double]] = []

    for i in 0..<Int(xnum) {
        var rowX: [Double] = []
        var rowY: [Double] = []
        for j in 0..<Int(ynum) {
            rowX.append(xmin + Double(i) * xStep)
            rowY.append(ymin + Double(j) * yStep)
        }
        gridX.append(rowX)
        gridY.append(rowY)
    }

    return (gridX, gridY)
}

// MARK: - Shared stats helper for comparison logs

struct HeatmapStats {
    let min: Double
    let max: Double
    let mean: Double
    let meanAbs: Double
    let nonZeroCount: Int
    let totalCount: Int
}

func computeHeatmapStats(matrix: [[Double?]]) -> HeatmapStats {
    var minVal = Double.greatestFiniteMagnitude
    var maxVal = -Double.greatestFiniteMagnitude
    var sum: Double = 0.0
    var sumAbs: Double = 0.0
    var nonZero = 0
    var total = 0

    for row in matrix {
        for vOpt in row {
            guard let v = vOpt else { continue }
            total += 1
            if v < minVal { minVal = v }
            if v > maxVal { maxVal = v }
            sum += v
            sumAbs += abs(v)
            if v != 0.0 {
                nonZero += 1
            }
        }
    }

    if total == 0 {
        return HeatmapStats(
            min: 0,
            max: 0,
            mean: 0,
            meanAbs: 0,
            nonZeroCount: 0,
            totalCount: 0
        )
    }

    return HeatmapStats(
        min: minVal,
        max: maxVal,
        mean: sum / Double(total),
        meanAbs: sumAbs / Double(total),
        nonZeroCount: nonZero,
        totalCount: total
    )
}
    
func createBGRImageFromGrayMatrix(grayMatrix: [[Double?]]) -> UIImage? {
    let width = grayMatrix[0].count
    let height = grayMatrix.count
    
    let maxColor = grayMatrix.compactMap { $0.compactMap { $0 }.max() }.max() ?? 1.0

    UIGraphicsBeginImageContext(CGSize(width: width, height: height))
    guard let context = UIGraphicsGetCurrentContext() else {
        return nil
    }

    UIColor.white.set()
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    for y in 0..<height {
        for x in 0..<width {
            if let grayValue = grayMatrix[y][x] {
                
                let normalizedValue = grayValue / maxColor
                let baseColor = jetColorMap(value: normalizedValue)
                
                let color = baseColor.withAlphaComponent(0.4)
                color.set()
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
    }
    guard let bgrImage = UIGraphicsGetImageFromCurrentImageContext() else {
        UIGraphicsEndImageContext()
        return nil
    }

    return bgrImage
}

func jetColorMap(value: Double) -> UIColor {
    if value == 0 {
        return UIColor.clear
    }
    let fourValue = 4 * value
    let red = max(min(fourValue - 1.5, -fourValue + 4.5), 0.0)
    let green = max(min(fourValue - 0.5, -fourValue + 3.5), 0.0)
    let blue = max(min(fourValue + 0.5, -fourValue + 2.5), 0.0)

    return UIColor(
        red: CGFloat(red),
        green: CGFloat(green),
        blue: CGFloat(blue),
        alpha: 1
    )
}

func resizeImage(_ image: UIImage, toSize newSize: CGSize) -> UIImage? {
    UIGraphicsBeginImageContextWithOptions(newSize, false, UIScreen.main.scale)
    image.draw(in: CGRect(origin: .zero, size: newSize))
    let resizedImage = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()
    return resizedImage
}

func verticallyStackImages(image1: UIImage, image2: UIImage) -> UIImage? {
    let size = CGSize(width: max(image1.size.width, image2.size.width),
                      height: image1.size.height + image2.size.height)

    UIGraphicsBeginImageContextWithOptions(size, false, 0.0)
    image1.draw(in: CGRect(x: 0, y: 0, width: size.width, height: image1.size.height))
    image2.draw(in: CGRect(x: 0, y: image1.size.height, width: size.width, height: image2.size.height))
    let stackedImage = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()

    return stackedImage
}

func overlayImage(background: UIImage, overlay: UIImage) -> UIImage? {
    let newSize = background.size
    UIGraphicsBeginImageContextWithOptions(newSize, false, 0.0)

    background.draw(in: CGRect(origin: CGPoint.zero, size: newSize))
    overlay.draw(in: CGRect(origin: CGPoint.zero, size: newSize), blendMode: .normal, alpha: 0.3)

    let newImage = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()

    return newImage
}

func convertToGrayScale(image: UIImage) -> UIImage? {
    let context = CIContext(options: nil)
    guard let currentFilter = CIFilter(name: "CIPhotoEffectNoir") else { return nil }
    let beginImage = CIImage(image: image)
    currentFilter.setValue(beginImage, forKey: kCIInputImageKey)

    guard let output = currentFilter.outputImage,
          let cgimg = context.createCGImage(output, from: output.extent) else { return nil }

    return UIImage(cgImage: cgimg)
}
