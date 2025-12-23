import Foundation

/// Streams per-frame landmark data to a JSON array on disk, to avoid huge in-memory arrays.
final class LandmarksJSONWriter {
    let fileURL: URL

    private var handle: FileHandle?
    private var isFirstEntry = true

    init(fileURL: URL) throws {
        self.fileURL = fileURL

        print("LandmarksJSONWriter init → fileURL = \(fileURL.path)")

        // create empty file
        FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
        handle = try FileHandle(forWritingTo: fileURL)
        // open JSON array
        if let data = "[".data(using: .utf8) {
            try handle?.write(contentsOf: data)
        }
    }

    func append(frameIndex: Int,
                timestampMs: Int,
                values: [Double],
                points: [[Int]]) {
        guard let handle = handle else { return }

        let payload: [String: Any] = [
            "frameIndex": frameIndex,
            "timestampMs": timestampMs,
            "values": values,
            "points": points
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return
        }

        do {
            if !isFirstEntry {
                try handle.write(contentsOf: Data(",".utf8))
            } else {
                isFirstEntry = false
            }
            try handle.write(contentsOf: data)

            print("JSON_APPEND frame=\(frameIndex) ts=\(timestampMs) " +
                  "values=\(values.count) points=\(points.count)")
        } catch {
            print("LandmarksJSONWriter write error:", error.localizedDescription)
        }
    }

    func finish() {
        guard let handle = handle else { return }
        do {
            try handle.write(contentsOf: Data("]".utf8))
            try handle.close()
            
            print("LandmarksJSONWriter finished. JSON at: \(fileURL.path)")

        } catch {
            print("LandmarksJSONWriter close error:", error.localizedDescription)
        }
        self.handle = nil
    }
}
