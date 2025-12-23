//
//  Math.swift

import Foundation
import Accelerate
import Accelerate.vecLib

func computeDispAndRemoveRigidTransform(P1: [[Double?]], P2: [[Double?]]) -> [[Double?]]{
    var A: [[Double?]] = []
    var B: [[Double?]] = []
    var removedIndices: [Int] = []
    
    for i in 0..<P1.count {
        if let xValue = P1[i][0], !xValue.isNaN {
            A.append(P1[i])
            B.append(P2[i])
        } else {
            assert(P1[i][0]?.isNaN ?? false && P1[i][1]?.isNaN ?? false &&
                   P2[i][0]?.isNaN ?? false && P2[i][1]?.isNaN ?? false,
                   "Mismatched NaN values at index \(i)")
            removedIndices.append(i)
        }
    }

    assert(A.count == B.count, "Mismatched lengths of A and B")
    let centroidA = centroid(points: A)
    let centroidB = centroid(points: B)
    let N = A.count
    
    // centre the points
    let AA = matrixSubtract(matrixA: A, matrixB: expandMatrixRow(matrix: centroidA, rowCount: N))
    let BB = matrixSubtract(matrixA: B, matrixB: expandMatrixRow(matrix: centroidB, rowCount: N))
    
    let H = matrixMultiply(matrixA: transpose(matrix: AA), matrixB: BB)
    let (U,S,V) = svd(x: H! )!
    let UT = transpose(matrix: U)
    let VT = transpose(matrix: V)
    var R = matrixMultiply(matrixA: VT, matrixB: UT)
    
    // special reflection case
    if (determinant(of:R!)! < 0) {
        print("Reflection detected")
        var thirdRow = VT[2]
        for i in 0..<thirdRow.count {
            thirdRow[i]! *= -1
        }
        R = matrixMultiply(matrixA: transpose(matrix: VT), matrixB: transpose(matrix: U))
    }

    // Compute T
    let T = matrixSubtract(matrixA: transpose(matrix: centroidB), matrixB: matrixMultiply(matrixA: R!, matrixB: transpose(matrix: centroidA))!)

    // Compute A2
    var A2 = matrixAddition(matrixA: matrixMultiply(matrixA: R!, matrixB: transpose(matrix: A))!, matrixB: expandMatrixCol(matrix: T, colCount: N))

    // Transpose A2 back to original shape
    A2 = transpose(matrix: A2)

    // Construct out array based on p1's content
    var out: [[Double?]] = []
    var j = 0
    for i in 0..<P1.count {
        if P1[i][0]!.isNaN {
            out.append(P1[i])
        } else {
            out.append(A2[j])
            j += 1
        }
    }
    
    let result = computeDisplacement(points: P2, pointsF: out)
    //printMatrix(matrix: result)
    
    return result
}
    
func centroid(points: [[Double?]]) -> [[Double?]] {
    let validPoints = points.compactMap { $0 }.filter { $0.count == 2 && $0[0] != nil && $0[1] != nil }
    
    // If there are no valid points, return nil.
    guard !validPoints.isEmpty else { return [[nil, nil]] }
    
    let sum = validPoints.reduce([0.0, 0.0]) { [$0[0] + ($1[0] ?? 0), $0[1] + ($1[1] ?? 0)] }
    let count = Double(validPoints.count)
    
    return [[sum[0] / count, sum[1] / count]]
}

func expandMatrixRow(matrix: [[Double?]], rowCount: Int) -> [[Double?]] {
    guard matrix.count == 1 else {
        fatalError("Input matrix should only have one row!")
    }

    return Array(repeating: matrix[0], count: rowCount)
}

func expandMatrixCol(matrix: [[Double?]], colCount: Int) -> [[Double?]] {
    var result = [[Double?]]()

    for row in matrix {
        if let firstValidValue = row.first(where: { $0 != nil }) {
            let expandedRow = Array(repeating: firstValidValue, count: colCount)
            result.append(expandedRow)
        } else {
            result.append(Array(repeating: nil, count: colCount))
        }
    }

    return result
}


func matrixSubtract(matrixA: [[Double?]], matrixB: [[Double?]]) -> [[Double?]] {
    guard matrixA.count == matrixB.count && matrixA[0].count == matrixB[0].count else {
        fatalError("Matrix dimensions do not match!")
    }
    
    var resultMatrix: [[Double?]] = []
    
    for i in 0..<matrixA.count {
        var resultRow: [Double?] = []
        
        for j in 0..<matrixA[i].count {
            if let valueA = matrixA[i][j], let valueB = matrixB[i][j] {
                resultRow.append(valueA - valueB)
            } else {
                resultRow.append(nil)
            }
        }
        resultMatrix.append(resultRow)
    }
    return resultMatrix
}

func matrixAddition(matrixA: [[Double?]], matrixB: [[Double?]]) -> [[Double?]] {
    guard matrixA.count == matrixB.count && matrixA[0].count == matrixB[0].count else {
        return []
    }

    var result = [[Double?]]()

    for i in 0..<matrixA.count {
        var row = [Double?]()
        for j in 0..<matrixA[i].count {
            if let valueA = matrixA[i][j], let valueB = matrixB[i][j] {
                row.append(valueA + valueB)
            } else {
                row.append(nil)
            }
        }
        result.append(row)
    }

    return result
}

func matrixMultiply(matrixA: [[Double?]], matrixB: [[Double?]]) -> [[Double?]]? {
    
    guard matrixA.count > 0, matrixB.count > 0, matrixA[0].count == matrixB.count else { return nil }

    var result: [[Double?]] = Array(repeating: Array(repeating: nil, count: matrixB[0].count), count: matrixA.count)

    for i in 0..<matrixA.count {
        for j in 0..<matrixB[0].count {
            var sum: Double = 0
            var allValid = true
            
            for k in 0..<matrixA[0].count {
                if let aValue = matrixA[i][k], let bValue = matrixB[k][j] {
                    sum += aValue * bValue
                } else {
                    allValid = false
                    break
                }
            }
            
            result[i][j] = allValid ? sum : nil
        }
    }
    return result
}

func transpose(matrix: [[Double?]]) -> [[Double?]] {
    guard matrix.count > 0 else { return [] }
    
    var transposed: [[Double?]] = []
    
    for i in 0..<matrix[0].count {
        var newRow: [Double?] = []
        for row in matrix {
            newRow.append(row[i])
        }
        transposed.append(newRow)
    }
    
    return transposed
}

func determinant(of matrix: [[Double?]]) -> Double? {
    // Ensure the matrix is square and non-empty
    guard !matrix.isEmpty && matrix.count == matrix[0].count else { return nil }

    var order = __CLPK_integer(matrix.count)
    
    // Try to convert the 2D matrix of optionals to a flat array of doubles
    var flatMatrix: [Double] = []
    for row in matrix {
        for value in row {
            guard let unwrappedValue = value else {
                print("Matrix contains nil values. Cannot compute determinant.")
                return nil
            }
            flatMatrix.append(unwrappedValue)
        }
    }
    
    var ipiv = [__CLPK_integer](repeating: 0, count: matrix.count)
    var error: __CLPK_integer = 0
    
    flatMatrix.withUnsafeMutableBufferPointer { matrixBuffer in
        ipiv.withUnsafeMutableBufferPointer { ipivBuffer in
            withUnsafeMutablePointer(to: &error) { error in
                withUnsafeMutablePointer(to: &order) { order in
                    _ = dgetrf_(order, order, matrixBuffer.baseAddress!, order, ipivBuffer.baseAddress!, error)
                }
            }
        }
    }
    
    if error != 0 {
        print("Matrix decomposition failed at step \(error).")
        return nil
    }
    
    var det: Double = 1.0
    for i in 0..<matrix.count {
        det *= flatMatrix[i*matrix.count + i]
        if ipiv[i] - 1 != i {
            det *= -1
        }
    }
    
    return det
}

func unwrapMatrix(_ matrix: [[Double?]]) -> [[Double]]? {
    var result = [[Double]]()
    for row in matrix {
        var newRow = [Double]()
        for value in row {
            guard let unwrappedValue = value else {
                return nil
            }
            newRow.append(unwrappedValue)
        }
        result.append(newRow)
    }
    return result
}

func svd(x:[[Double?]]) -> (u:[[Double]], s:[Double], v:[[Double]])? {
    guard let nonOptionalMatrix = unwrapMatrix(x) else {
            return nil
        }
    var JOBZ = Int8(UnicodeScalar("A").value)
    let m = nonOptionalMatrix.count
    let n = nonOptionalMatrix[0].count
    let flatMatrix = rowMajorToColMajor(rowMajor: nonOptionalMatrix)
    var M = __CLPK_integer(m)
    var N = __CLPK_integer(n)
    var A = flatMatrix
    var LDA = __CLPK_integer(m)
    var S = [__CLPK_doublereal](repeating: 0.0, count: min(m,n))
    var U = [__CLPK_doublereal](repeating: 0.0, count: m*m)
    var LDU = __CLPK_integer(m)
    var VT = [__CLPK_doublereal](repeating: 0.0, count: n*n)
    var LDVT = __CLPK_integer(n)
    let lwork = min(m,n)*(6+4*min(m,n))+max(m,n)
    var WORK = [__CLPK_doublereal](repeating: 0.0, count: lwork)
    var LWORK = __CLPK_integer(lwork)
    var IWORK = [__CLPK_integer](repeating: 0, count: 8*min(m,n))
    var INFO = __CLPK_integer(0)
    dgesdd_(&JOBZ, &M, &N, &A, &LDA, &S, &U, &LDU, &VT, &LDVT, &WORK, &LWORK, &IWORK, &INFO)
//    print(S)
//    var s = [Double](repeating: 0.0, count: m*n)
//    for ni in 0...n-1 {
//        s[ni*m+ni] = S[ni]
//    }
//    var v = [Double](repeating: 0.0, count: n*n)
//    vDSP_mtransD(VT, 1, &v, 1, vDSP_Length(n), vDSP_Length(n))
    let u_1 = colMajorToRowMajor(colMajor: U, rows: m, cols: m)
    let s_1 = S
    let v_1 = colMajorToRowMajor(colMajor: VT, rows: n, cols: n)
    return (u_1, s_1, v_1)
}

func rowMajorToColMajor(rowMajor: [[Double]]) -> [Double] {
    let rows = rowMajor.count
    let cols = rowMajor[0].count
    var colMajor: [Double] = []

    for j in 0..<cols {
        for i in 0..<rows {
            colMajor.append(rowMajor[i][j])
        }
    }

    return colMajor
}

func colMajorToRowMajor(colMajor: [Double], rows: Int, cols: Int) -> [[Double]] {
    var rowMajor: [[Double]] = Array(repeating: Array(repeating: 0.0, count: cols), count: rows)

    for j in 0..<cols {
        for i in 0..<rows {
            rowMajor[i][j] = colMajor[j * rows + i]
        }
    }

    return rowMajor
}

func testSVD() {
    let matrix: [[Double]] = [
        [1.0, 2.0],
        [3.0, 4.0],
        [5.0, 6.0],
        [7.0, 8.0]
        
    ]
    
    let result = svd(x: matrix)
    
    
    print("\nMatrix U:")
    printMatrix(matrix: result!.u)
    
//    print("\nMatrix Σ:")
//    printMatrix(matrix: result.s)
    
    print("\nMatrix VT:")
    printMatrix(matrix: result!.v)
}

func printMatrix(matrix: [[Double?]]) {
    for row in matrix {
        for value in row {
            if let validValue = value {
                print("\(validValue) ", terminator: "")
            } else {
                print("N/A ", terminator: "")
            }
        }
        print("")
    }
}

func computeDisplacement(points: [[Double?]], pointsF: [[Double?]]) -> [[Double?]] {
    assert(points.count == pointsF.count, "Lengths of point arrays must be equal")
    
    var values: [[Double?]] = []
    
    for (index, point) in points.enumerated() {
        let pointF = pointsF[index]
        
        // Ensure both points have valid data for x and y coordinates
        guard point.count >= 2, pointF.count >= 2,
              let x1 = point[0], let y1 = point[1],
              let x2 = pointF[0], let y2 = pointF[1] else {
            values.append([nil, nil])
            continue
        }
        
        let dx = x2 - x1
        let dy = y2 - y1
        values.append([dx, dy])
    }
    
    return values
}


