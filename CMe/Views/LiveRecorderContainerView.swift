
import SwiftUI
import AVFoundation

struct LiveRecorderContainerView: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    @ObservedObject var viewModel: VideoProcessingViewModel
    let selectedAudio: String

    func makeUIViewController(context: Context) -> CameraRecorderViewController {
        let controller = CameraRecorderViewController()
        controller.delegate = context.coordinator
        controller.viewModel = viewModel
        controller.selectedAudio = selectedAudio
        return controller
    }

    func updateUIViewController(_ uiViewController: CameraRecorderViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, CameraRecorderDelegate {
        let parent: LiveRecorderContainerView

        init(_ parent: LiveRecorderContainerView) {
            self.parent = parent
        }

        func didFinishRecording(rawVideoURL: URL,
                                heatmapVideoURL: URL?,
                                landmarksJSONURL: URL?) {
            print("🎞️ Recording finished:", rawVideoURL.lastPathComponent)

            Task { @MainActor in
                self.parent.viewModel.lastSessionResult = VideoProcessingViewModel.SessionResult(
                    rawVideoURL: rawVideoURL,
                    heatmapVideoURL: heatmapVideoURL,
                    landmarksJSONURL: landmarksJSONURL
                )
                // dismiss recorder UI
                self.parent.isPresented = false
            }
        }
    }
}
