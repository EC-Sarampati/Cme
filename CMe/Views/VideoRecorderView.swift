
import SwiftUI
import AVFoundation

struct VideoRecorderView: UIViewControllerRepresentable {
    var selectedAudio: String
    @Binding var pickedVideoURL: URL?
    @ObservedObject var viewModel: VideoProcessingViewModel

    func makeUIViewController(context: Context) -> CameraRecorderViewController {
        let vc = CameraRecorderViewController()
        vc.delegate = context.coordinator
        vc.selectedAudio = selectedAudio
        vc.viewModel = viewModel
        return vc
    }

    func updateUIViewController(_ uiViewController: CameraRecorderViewController, context: Context) {
        uiViewController.selectedAudio = selectedAudio
        uiViewController.viewModel = viewModel
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, CameraRecorderDelegate {
        let parent: VideoRecorderView
        init(parent: VideoRecorderView) { self.parent = parent }

        func didFinishRecording(rawVideoURL: URL,
                                heatmapVideoURL: URL?,
                                landmarksJSONURL: URL?) {
            Task { @MainActor in
                self.parent.pickedVideoURL = rawVideoURL
                self.parent.viewModel.lastSessionResult = VideoProcessingViewModel.SessionResult(
                    rawVideoURL: rawVideoURL,
                    heatmapVideoURL: heatmapVideoURL,
                    landmarksJSONURL: landmarksJSONURL
                )
            }
        }
    }
}
