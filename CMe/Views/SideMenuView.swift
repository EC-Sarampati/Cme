import SwiftUI

struct SideMenuView: View {
    @Binding var isOpen: Bool
    @Binding var selectedAudio: String
    var audioCommands: [String]
    var onPickVideo: () -> Void
    var onRecordVideo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 25) {
            Text("Menu")
                .font(.largeTitle.bold())
                .foregroundColor(.white)
                .padding(.top, 60)
            VStack(alignment: .leading, spacing: 10) {
                Text("Select Audio Command")
                    .font(.headline)
                    .foregroundColor(.white.opacity(0.9))

                Picker("Audio Command", selection: $selectedAudio) {
                    ForEach(audioCommands, id: \.self) { command in
                        Text(command.capitalized).tag(command)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                .frame(maxWidth: .infinity)
                .padding(10)
                .background(Color.white.opacity(0.15))
                .cornerRadius(10)
            }

            Divider().background(Color.white.opacity(0.3))

            Button(action: onPickVideo) {
                Label("Pick Video", systemImage: "film")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.vertical, 8)
            }

            Button(action: onRecordVideo) {
                Label("Record Live", systemImage: "video.fill")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.vertical, 8)
            }

            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: 280, alignment: .leading)
        .background(
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(.systemIndigo),
                    Color(.systemPurple)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .cornerRadius(0)
        .shadow(radius: 10)
    }
}
