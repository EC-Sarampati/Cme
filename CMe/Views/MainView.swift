import SwiftUI
import AVKit

struct MainView: View {
    @State private var showMenu = false
    @State private var showVideoPicker = false
    @State private var showRecorder = false
    @State private var pickedVideoURL: URL?
    @State private var selectedAudio = "eye"
    @State private var heatmapPlayer: AVPlayer? = nil

    @StateObject private var viewModel = VideoProcessingViewModel()
    private let audioCommands = ["eye", "hand", "smile", "sunny", "tongue"]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                VStack(spacing: 0) {
                    if viewModel.isCompressingVideo {
                        VStack(spacing: 16) {
                            ProgressView("Compressing video...")
                                .progressViewStyle(CircularProgressViewStyle())
                            Text("Please wait while your video is being prepared")
                                .font(.footnote)
                                .foregroundColor(.gray)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.05))
                        .transition(.opacity)
                    }

                    else if viewModel.isProcessingVideo {
                        VStack(spacing: 20) {
                            if let image = viewModel.currentImage {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .cornerRadius(12)
                                    .frame(maxHeight: geo.size.height * 0.6)
                                    .padding()
                            } else {
                                ProgressView("Analyzing video...")
                                    .padding()
                            }
                            ProgressView(value: viewModel.progress)
                                .padding(.horizontal)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.05))
                    }

                    else if viewModel.isCompleted {
                        if let url = viewModel.outputVideoPath {
                            VStack {
                                if let player = heatmapPlayer {
                                    VideoPlayer(player: player)
                                        .onAppear { player.play() }
                                        .cornerRadius(12)
                                        .padding()
                                        .frame(width: geo.size.width * 0.9,
                                               height: min(geo.size.height * 0.6, 500))

                                    HStack(spacing: 25) {
                                        Button {
                                            player.seek(to: .zero)
                                            player.play()
                                        } label: {
                                            Label("Replay", systemImage: "arrow.clockwise.circle.fill")
                                                .font(.headline)
                                        }

                                        Button {
                                            if player.timeControlStatus == .paused {
                                                player.play()
                                            } else {
                                                player.pause()
                                            }
                                        } label: {
                                            Label(
                                                player.timeControlStatus == .paused ? "Play" : "Pause",
                                                systemImage: player.timeControlStatus == .paused
                                                    ? "play.circle.fill" : "pause.circle.fill"
                                            )
                                            .font(.headline)
                                        }
                                    }
                                    .padding(.bottom, 40)
                                } else {
                                    ProgressView("Loading final video...")
                                        .onAppear {
                                            heatmapPlayer = AVPlayer(url: url)
                                        }
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.black.opacity(0.05))
                        } else {
                            idlePlaceholder("✅ Processing complete — check Photos for saved result")
                        }
                    }

                    else {
                        idlePlaceholder("Pick or record a video from the menu to start")
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .background(Color(.systemBackground))
                .edgesIgnoringSafeArea(.all)

                VStack {
                    HStack {
                        Button(action: {
                            withAnimation(.spring()) { showMenu.toggle() }
                        }) {
                            Image(systemName: "line.horizontal.3")
                                .font(.title2)
                                .padding(10)
                                .background(Color.white.opacity(0.85))
                                .cornerRadius(8)
                                .shadow(radius: 4)
                        }
                        Spacer()
                    }
                    Spacer()
                }
                .padding(.top, 40)
                .padding(.horizontal)

                if showMenu {
                    SideMenuOverlay(
                        isOpen: $showMenu,
                        selectedAudio: $selectedAudio,
                        audioCommands: audioCommands,
                        showVideoPicker: $showVideoPicker,
                        showRecorder: $showRecorder
                    )
                    .transition(.move(edge: .leading))
                    .zIndex(2)
                }
            }
        }

        .sheet(isPresented: $showVideoPicker) {
            VideoPicker(
                showPicker: $showVideoPicker,
                videoURL: $pickedVideoURL,
                viewModel: viewModel,
                selectedAudio: selectedAudio
            )
            .presentationDetents([.large])
            .presentationCompactAdaptation(.fullScreenCover)
        }

        .fullScreenCover(isPresented: $showRecorder) {
            LiveRecorderContainerView(
                isPresented: $showRecorder,
                viewModel: viewModel,
                selectedAudio: selectedAudio
            )
            .ignoresSafeArea()
        }

        .onChange(of: pickedVideoURL) { url in
            guard let url else { return }
            print("🎥 Picked video ready:", url.lastPathComponent)
        }
        .onChange(of: viewModel.isCompleted) { done in
            if done, let path = viewModel.outputVideoPath {
                print("🎬 Final heatmap video ready:", path.lastPathComponent)
                heatmapPlayer = AVPlayer(url: path)
            }
        }
    }

    private func idlePlaceholder(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg.rectangle")
                .resizable()
                .scaledToFit()
                .frame(width: 60, height: 60)
                .foregroundColor(.gray)
            Text(text)
                .foregroundColor(.gray)
                .font(.headline)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.05))
    }
}


private struct SideMenuOverlay: View {
    @Binding var isOpen: Bool
    @Binding var selectedAudio: String
    var audioCommands: [String]
    @Binding var showVideoPicker: Bool
    @Binding var showRecorder: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Dimmed background
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation { isOpen = false } }

                // Slide-in menu
                SideMenuView(
                    isOpen: $isOpen,
                    selectedAudio: $selectedAudio,
                    audioCommands: audioCommands,
                    onPickVideo: {
                        showVideoPicker = true
                        withAnimation { isOpen = false }
                    },
                    onRecordVideo: {
                        showRecorder = true
                        withAnimation { isOpen = false }
                    }
                )
                .frame(width: min(geo.size.width * 0.75, 320))
                .offset(x: isOpen ? 0 : -min(geo.size.width * 0.75, 320))
                .animation(.spring(), value: isOpen)
                .shadow(radius: 10)
            }
        }
    }
}
