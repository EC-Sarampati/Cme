import SwiftUI
import AVKit

struct FaceOpticalView: View {
    @ObservedObject var viewModel: VideoProcessingViewModel
    var body: some View {
        ZStack {
            if viewModel.processingState == .processing {
                VStack {
                    ProgressView(value: viewModel.progress)
                        .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                        .padding(.horizontal, 40)
                    Text("Analyzing video... \(Int(viewModel.progress * 100))%")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.8))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.6))
            } else if let image = viewModel.currentImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "video.circle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.gray)
                    Text("Ready for video input")
                        .foregroundColor(.gray)
                        .font(.headline)
                }
            }
        }
        .background(Color.black)
    }
}
