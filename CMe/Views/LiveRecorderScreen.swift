
import SwiftUI

struct LiveRecorderScreen: View {
    @Binding var isPresented: Bool
    @ObservedObject var viewModel: VideoProcessingViewModel
    let selectedAudio: String

    @StateObject private var heatmapProcessor = HeatmapProcessor()

    // UI state
    @State private var showExpandedHeatmap = false
    @State private var showExpandedCamera = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                VStack(spacing: 0) {
                    ZStack(alignment: .topTrailing) {
                        LiveRecorderContainerView(
                            isPresented: $isPresented,
                            viewModel: viewModel,
                            selectedAudio: selectedAudio
                        )
                        .frame(height: showExpandedCamera
                               ? geo.size.height * 0.8
                               : geo.size.height * 0.5)
                        .clipped()
                        .animation(.easeInOut, value: showExpandedCamera)
                        Button {
                            withAnimation { showExpandedCamera.toggle() }
                        } label: {
                            Image(systemName: showExpandedCamera
                                  ? "arrow.down.right.and.arrow.up.left"
                                  : "arrow.up.left.and.arrow.down.right")
                                .padding(10)
                                .background(Color.black.opacity(0.5))
                                .clipShape(Circle())
                                .foregroundColor(.white)
                                .padding()
                        }
                    }

                    Divider().background(Color.white.opacity(0.5))
                    ZStack(alignment: .bottomTrailing) {
                        if let image = heatmapProcessor.heatmapImage {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .rotationEffect(.degrees(180))
                                .scaleEffect(x: -1, y: 1)
                                .frame(height: showExpandedHeatmap
                                       ? geo.size.height * 0.8
                                       : geo.size.height * 0.4)
                                .clipped()
                                .transition(.opacity)
                                .animation(.easeInOut, value: showExpandedHeatmap)
                        } else {
                            Color.black
                                .frame(height: geo.size.height * 0.4)
                        }
                        
                        Button {
                            withAnimation { showExpandedHeatmap.toggle() }
                        } label: {
                            Image(systemName: showExpandedHeatmap
                                  ? "arrow.down.right.and.arrow.up.left"
                                  : "arrow.up.left.and.arrow.down.right")
                                .padding(10)
                                .background(Color.black.opacity(0.5))
                                .clipShape(Circle())
                                .foregroundColor(.white)
                                .padding()
                        }
                    }
                }
                
                VStack {
                    Spacer()
                    Button(action: {
                        NotificationCenter.default.post(name: NSNotification.Name("ToggleRecording"), object: nil)
                    }) {
                        Circle()
                            .fill(.red)
                            .frame(width: 80, height: 80)
                            .overlay(Circle().stroke(.white, lineWidth: 4))
                            .shadow(radius: 10)
                    }
                    .padding(.bottom, 30)
                }
            }
            .ignoresSafeArea()
        }
    }
}
