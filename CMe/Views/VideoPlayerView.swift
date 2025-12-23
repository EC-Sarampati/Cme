import SwiftUI
import AVKit

struct VideoPlayerView: View {
    let videoURL: URL
    let selectedAudio: String
    @ObservedObject var viewModel: VideoProcessingViewModel

    @State private var player: AVPlayer?
    @State private var timeObserver: Any?
    @State private var detectedFPS: Double = 30.0

    var body: some View {
        ZStack {
            if let player = player {
                VideoPlayer(player: player)
                    .onDisappear { cleanupPlayer() }
            } else {
                Color.black.opacity(0.2)
                ProgressView("Loading video…")
                    .foregroundColor(.white)
            }
        }
        .onAppear { setupPlayer() }
        .onChange(of: videoURL) { _ in setupPlayer() }
    }

    // MARK: - Setup player
    private func setupPlayer() {
        cleanupPlayer()

        let asset = AVAsset(url: videoURL)
        detectedFPS = detectFPS(of: asset)

        print("Detected video FPS:", detectedFPS)

        let newPlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        newPlayer.automaticallyWaitsToMinimizeStalling = false
        player = newPlayer

        // Add time observer to update frame previews in real time (if desired)
        let interval = CMTime(
            seconds: max(1.0 / detectedFPS, 1.0 / 30.0),
            preferredTimescale: 600
        )
        timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { _ in
            // Optional: in future, we can sync live frame previews here
        }

        newPlayer.playImmediately(atRate: 1.0)

        // Automatically trigger processing once playback starts
        // processFullVideo is NOT async, so no `await` and no `featureType:` label
//        Task {
//            await viewModel.processFullVideo(inputURL: videoURL, feature: selectedAudio) // chay: changed this for new view model remove task and await if replaced
//        }
    }

    // MARK: - Cleanup player
    private func cleanupPlayer() {
        if let obs = timeObserver, let player = player {
            player.removeTimeObserver(obs)
        }
        timeObserver = nil
        player?.pause()
        player = nil
    }

    // MARK: - FPS detection helper
    private func detectFPS(of asset: AVAsset) -> Double {
        guard let track = asset.tracks(withMediaType: .video).first else { return 30 }
        let fps = Double(track.nominalFrameRate)
        return fps > 0 ? fps : 30
    }
}
