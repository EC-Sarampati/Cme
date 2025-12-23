import Foundation

class Grid {
    // The Grid class is the main class of pydic. This class embeds a lot of useful
    // methods to treat and post-treat results.
    
    var gridX: [[Double?]]
    var gridY: [[Double?]]
    var sizeX: Double
    var sizeY: Double
    var dispX: [[Double?]]
    var dispY: [[Double?]]
    var dispXYIndi: [[Double?]]
    var strainXX: Double?
    var strainYY: Double?
    var strainXY: Double?
    var winsize: [Double]
    var referencePoint: [[Double?]]
    var correlatedPoint: [[Double?]]
    var disp: [[Double?]]
    var metaInfo: String?
    
    init(gridX: [[Double?]], gridY: [[Double?]], sizeX: Double, sizeY: Double) {
        self.gridX = gridX
        self.gridY = gridY
        self.sizeX = sizeX
        self.sizeY = sizeY
        
        self.dispX = []
        self.dispY = []
        self.dispXYIndi = []
        self.winsize = []
        self.referencePoint = []
        self.correlatedPoint = []
        self.disp = []
        
    }
    
    func addRawData(winsize: [Double], referencePoint: [[Double?]], correlatedPoint: [[Double?]], disp: [[Double?]]) {
        self.winsize = winsize
        self.referencePoint = referencePoint
        self.correlatedPoint = correlatedPoint
        self.disp = disp
    }
    
    func addMetaInfo(metaInfo: String) {
        self.metaInfo = metaInfo
    }
    
    func interpolateDisplacement(
        points: [[Double?]],
        disp: [[Double?]],
        method: String = "raw"
    ) {
        let dx = disp.map { $0[0] }
        let dy = disp.map { $0[1] }
        
        switch method {
        case "delaunay":
            // Implement Delaunay method
            // TO DO
            fatalError("Delaunay method not implemented")
            
        case "raw":
            self.dispX = self.gridX
            self.dispY = self.gridY
            self.dispXYIndi = self.gridX
            
            assert(self.dispX.count == self.dispY.count, "bad shape")
            assert(self.dispX[0].count == self.dispY[0].count, "bad shape")
            assert(dx.count == dy.count, "bad shape")
            assert(dispX.count * dispX[0].count == dx.count, "bad shape")

            var counter = 0
            for i in 0..<self.dispX.count {
                for j in 0..<self.dispX[i].count {
                    self.dispX[i][j] = dx[counter]
                    self.dispY[i][j] = dy[counter]
                    self.dispXYIndi[i][j] = sqrt(dx[counter]! * dx[counter]! + dy[counter]! * dy[counter]!)
                    counter += 1
                }
            }
            
        case "spline":
            // Implement Spline method
            // TODO
            fatalError("Spline method not implemented")
            
        default:
            // Implement Default method
            // TODO
            fatalError("Default method not implemented")
        }
    }
}
