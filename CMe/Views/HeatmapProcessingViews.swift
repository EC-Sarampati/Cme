import SwiftUI
import UIKit

struct MatrixStyleProgressView: View {
    var progress: Double
    var body: some View {
        ZStack {
            Color.black.opacity(0.8)
                .frame(height: 30)
                .cornerRadius(15)

            HStack {
                Color.green
                    .frame(width: CGFloat(max(0, min(progress, 1))) * 300, height: 30)
                    .cornerRadius(15)
                Spacer(minLength: 0)
            }

            Text("Processing: \(Int(max(0, min(progress, 1)) * 100))%")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
        }
        .frame(width: 300, height: 30)
        .shadow(radius: 4)
    }
}

struct ImageViewer: View {
    var image: UIImage
    var body: some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
    }
}
