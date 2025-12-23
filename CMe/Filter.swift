import Foundation

enum TransferFunctionError: Error {
    case improperTransferFunction(String)
}

func relativeDegree(zeros z: [Any], poles p: [Any]) throws -> Int {
    let degree = p.count - z.count
    if degree < 0 {
        throw TransferFunctionError.improperTransferFunction("Improper transfer function. Must have at least as many poles as zeros.")
    }
    return degree
}
struct Complex: Comparable {
    var real: Double
    var imaginary: Double

    init(real: Double, imaginary: Double) {
        self.real = real
        self.imaginary = imaginary
    }

    static func + (left: Complex, right: Complex) -> Complex {
        return Complex(real: left.real + right.real, imaginary: left.imaginary + right.imaginary)
    }

    static func - (left: Complex, right: Complex) -> Complex {
        return Complex(real: left.real - right.real, imaginary: left.imaginary - right.imaginary)
    }

    static func * (left: Complex, right: Complex) -> Complex {
        let real = left.real * right.real - left.imaginary * right.imaginary
        let imaginary = left.real * right.imaginary + left.imaginary * right.real
        return Complex(real: real, imaginary: imaginary)
    }

    func magnitude() -> Double {
        return sqrt(real * real + imaginary * imaginary)
    }

    static func exp(_ complex: Complex) -> Complex {
        let exponent = Foundation.exp(complex.real)
        let realPart = exponent * cos(complex.imaginary)
        let imaginaryPart = exponent * sin(complex.imaginary)
        return Complex(real: realPart, imaginary: imaginaryPart)
    }
    
    static prefix func - (complex: Complex) -> Complex {
        return Complex(real: -complex.real, imaginary: -complex.imaginary)
    }
    
    static func * (complex: Complex, multiplier: Double) -> Complex {
        return Complex(real: complex.real * multiplier, imaginary: complex.imaginary * multiplier)
    }

    static func * (multiplier: Double, complex: Complex) -> Complex {
        return Complex(real: complex.real * multiplier, imaginary: complex.imaginary * multiplier)
    }
    
    static func / (left: Complex, right: Complex) -> Complex {
        let divisor = right.real * right.real + right.imaginary * right.imaginary
        let realPart = (left.real * right.real + left.imaginary * right.imaginary) / divisor
        let imaginaryPart = (left.imaginary * right.real - left.real * right.imaginary) / divisor
        return Complex(real: realPart, imaginary: imaginaryPart)
    }
    
    static func < (lhs: Complex, rhs: Complex) -> Bool {
        if lhs.real == rhs.real {
            return lhs.imaginary < rhs.imaginary
        }
        return lhs.real < rhs.real
    }

}

func buttap(N: Int) throws -> (zeros: [Complex], poles: [Complex], gain: Double) {
    guard N >= 0 else {
        throw NSError(domain: "ButterworthFilterError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Filter order must be a nonnegative integer"])
    }

    let zeros: [Complex] = []
    var poles: [Complex] = []
    let m = stride(from: -N + 1, to: N, by: 2)

    for element in m {
        let pole = Complex.exp(Complex(real: 0, imaginary: Double.pi * Double(element) / (2.0 * Double(N))))
        poles.append(-pole)
    }

    let gain: Double = 1
    return (zeros, poles, gain)
}

//func butter(N: Int, Wn: [Double], analog: Bool = false, fs: Double? = nil) throws -> (z: [Complex], p: [Complex], k: Double) {
//    var Wn = Wn
//    if let fs = fs {
//        Wn = Wn.map { $0 * 2 / fs }
//    }
//
//    if Wn.contains(where: { $0 <= 0 }) {
//        throw NSError(domain: "FilterError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Filter critical frequencies must be greater than 0"])
//    }
//
//    if Wn.count > 1 && !(Wn[0] < Wn[1]) {
//        throw NSError(domain: "FilterError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Wn[0] must be less than Wn[1]"])
//    }
//
//    var (z, p, k) = try buttap(N: N)
//
//    let fs = 2.0
//    let warped = Wn.map { 2 * fs * tan(Double.pi * $0 / fs) }
//
//    if Wn.count != 1 {
//        throw NSError(domain: "FilterError", code: 3, userInfo: [NSLocalizedDescriptionKey: "Must specify a single critical frequency Wn for lowpass or highpass filter"])
//    }
//
//    (z, p, k) = lp2lp_zpk(z, p, k, wo: warped[0])
//
//    (z, p, k) = bilinear_zpk(z, p, k, fs: fs)
//
//    return zpk2sos(z, p, k, analog: analog)
//}

func lp2lp_zpk(z: [Complex], p: [Complex], k: Double, wo: Double) -> (z: [Complex], p: [Complex], k: Double) {
    let degree = p.count - z.count
    guard degree >= 0 else {
        fatalError("Improper transfer function. Must have at least as many poles as zeros.")
    }

    let z_lp = z.map { $0 * wo }
    let p_lp = p.map { $0 * wo }
    let k_lp = k * pow(wo, Double(degree))

    return (z_lp, p_lp, k_lp)
}


func bilinear_zpk(z: [Complex], p: [Complex], k: Double, fs: Double) -> (z: [Complex], p: [Complex], k: Double) {
    let degree = p.count - z.count
    guard degree >= 0 else {
        fatalError("Improper transfer function. Must have at least as many poles as zeros.")
    }

    let fs2 = 2.0 * fs

    // Bilinear transform the poles and zeros
    let z_z = z.map { Complex(real: $0.real + fs2, imaginary: $0.imaginary) / Complex(real: $0.real - fs2, imaginary: $0.imaginary) }
    let p_z = p.map { Complex(real: $0.real + fs2, imaginary: $0.imaginary) / Complex(real: $0.real - fs2, imaginary: $0.imaginary) }

    // Any zeros that were at infinity get moved to the Nyquist frequency
    let z_z_withNyquist = z_z + Array(repeating: Complex(real: -1, imaginary: 0), count: degree)

    let numerator = z_z_withNyquist.reduce(Complex(real: 1, imaginary: 0)) { acc, z in
        acc * (Complex(real: fs2, imaginary: 0) - z)
    }

    let denominator = p_z.reduce(Complex(real: 1, imaginary: 0)) { acc, p in
        acc * (Complex(real: fs2, imaginary: 0) - p)
    }

    let k_z = k * (numerator.real / denominator.real)

    return (z_z_withNyquist, p_z, k_z)
}

func sortComplex(_ a: [Complex]) -> [Complex] {
    return a.sorted()
}

func atleast_1d(_ arys: Any...) -> Any {
    
    var res: [Any] = []
    for ary in arys {
        let aryArray = asanyarray(ary)
        if aryArray.count == 1 {
            res.append(aryArray[0])
        } else {
            res.append(aryArray)
        }
    }
    
    if res.count == 1 {
        return res[0]
    } else {
        return res
    }
}

func asanyarray(_ input: Any) -> [Double] {
    if let array = input as? [Double] {
        return array
    } else if let scalar = input as? Double {
        return [scalar]
    } else {
        fatalError("Unsupported input type")
    }
}

func convolve_full(a: [Double], v: [Double]) -> [Double] {
    let n = a.count
    let m = v.count
    let size = n + m - 1
    var result = [Double](repeating: 0.0, count: size)

    for i in 0..<n {
        for j in 0..<m {
            result[i + j] += a[i] * v[j]
        }
    }

    return result
}
