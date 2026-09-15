import SwiftUI

/// Cached, downsampled async image. Shows `placeholder` until loaded or on failure.
struct RemoteImage<Placeholder: View>: View {
    let url: URL?
    var targetSize: CGSize
    var contentMode: ContentMode = .fit
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                if contentMode == .fill {
                    // Let the parent decide the size; the image just fills and clips.
                    Color.clear
                        .overlay { Image(uiImage: image).resizable().scaledToFill() }
                        .clipped()
                        .transition(.opacity.animation(.easeOut(duration: 0.18)))
                } else {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .transition(.opacity.animation(.easeOut(duration: 0.18)))
                }
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            if let cached = ImageLoader.shared.cached(url, targetSize: targetSize) {
                image = cached
                return
            }
            image = nil
            failed = false
            let loaded = await ImageLoader.shared.image(for: url, targetSize: targetSize)
            if !Task.isCancelled {
                image = loaded
                failed = loaded == nil
            }
        }
    }
}
