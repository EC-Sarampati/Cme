import Foundation
import AVFoundation
import Speech
import Combine

struct DetectedCommand {
    let command: String
    let time: TimeInterval
}

final class AudioCommandRecognizer: NSObject, ObservableObject {
    @Published var detectedCommand: String? = nil

    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?

    /// Live callback for camera recorder:
    ///   (normalizedCommand, timestampMsSinceEpoch)
    var onCommandDetected: ((String, Int) -> Void)?

    // Phrase dictionary for fuzzy matching
    private let phraseMap: [String: [String]] = [
        "eye":   ["eye", "eyes", "open your eyes", "look at me", "blink"],
        "hand":  ["hand", "hands", "close your hand", "raise your hand", "move your hand"],
        "smile": ["smile", "show me a smile", "smile please", "big smile"],
        "sunny": ["sunny", "today is a sunny day", "bright day", "good weather"],
        "tongue":["tongue", "show your tongue", "stick out your tongue"]
    ]

    override init() {
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        super.init()
    }

    deinit { stopListening() }

    // MARK: - Live Mic Listening

    func startListening() throws {
        var speechAuthErr: Error?
        let group = DispatchGroup()
        group.enter()
        SFSpeechRecognizer.requestAuthorization { status in
            if status != .authorized {
                speechAuthErr = NSError(
                    domain: "AudioCommandRecognizer",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey:
                               "Speech permission denied: \(status)"]
                )
            }
            group.leave()
        }
        group.wait()
        if let e = speechAuthErr { throw e }

        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            print("Mic permission: \(granted)")
        }

        stopListening()
        request = SFSpeechAudioBufferRecognitionRequest()
        request?.shouldReportPartialResults = true

        guard let recognizer = recognizer, recognizer.isAvailable else {
            throw NSError(
                domain: "AudioCommandRecognizer",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Recognizer not available"]
            )
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        print("AudioCommandRecognizer: startListening()")

        task = recognizer.recognitionTask(with: request!) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                let text = result.bestTranscription.formattedString.lowercased()

                print("LIVE_TRANSCRIPT: \(text)")

                if let cmd = self.matchCommand(in: text) {
                    self.detectedCommand = cmd

                    // absolute wall-clock ms; HeatmapProcessor uses same scale
                    let nowMs = Int(Date().timeIntervalSince1970 * 1000)

                    print("LIVE_CMD_DETECTED: \(cmd) at \(nowMs) ms")

                    // notify camera / heatmap
                    self.onCommandDetected?(cmd, nowMs)
                }
            }

            if let error = error {
                print("Speech recognition error:", error.localizedDescription)
                self.restartAfterDelay()
            }
        }
    }

    func stopListening() {
        print("AudioCommandRecognizer: stopListening()")
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
    }

    private func restartAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            print("Restarting speech recognizer after error…")
            try? self.startListening()
        }
    }

    // MARK: - Offline audio (from video) — unchanged

    func detectAudioCommands(from videoURL: URL) async -> [DetectedCommand] {
        return []
    }

    private func matchCommand(in text: String) -> String? {
        for (command, phrases) in phraseMap {
            if phrases.contains(where: { text.contains($0) }) {
                return command
            }
        }
        return nil
    }
}
