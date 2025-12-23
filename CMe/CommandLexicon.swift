import Foundation

struct CommandLexicon {
    static let audioToKeyword: [String: String] = [
        "eyes.wav": "eyes",
        "hand.wav": "hand",
        "smile.wav": "smile",
        "sunny.wav": "sunny",
        "tongue.wav": "tongue"
    ]

    static let synonyms: [String: [String]] = [
        "eyes": ["eyes","eye","open eyes","open your eyes","eyes open","look up","look at me"],
        "hand": ["hand","hands","close your hand","raise your hand","move your hand","open hand"],
        "smile": ["smile","smiling","show me a smile","give me a smile","show your smile"],
        "sunny": ["sunny","today is a sunny day","it's sunny","nice sunny day","bright day","the sun is out"],
        "tongue": ["tongue","stick out your tongue","stick tongue out","show tongue","put out your tongue"]
    ]

    static func canonical(forSelectedAudio filename: String) -> String? {
        audioToKeyword[filename.lowercased()]
    }

    static func matches(_ phrase: String, selectedCanonical: String) -> Bool {
        let lower = phrase.lowercased()
        guard let list = synonyms[selectedCanonical] else { return false }
        return list.contains { lower.contains($0) }
    }
}
