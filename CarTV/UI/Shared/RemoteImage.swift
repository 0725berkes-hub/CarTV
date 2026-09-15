import SwiftUI

/// Cached, downsampled async image. Shows `placeholder` until loaded or on failure.
struct RemoteImage<Placeholder: View>: View {
    let url: URL?
    var targetSize: CGSize
    var contentMode: ContentMode = .fit
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var failed = false

    /// Start from the cache synchronously so a re-created view never shows the
    /// placeholder for an image we already have. That placeholder→image fade on
    /// every identity change is what reads as "the artwork flickers".
    private var initial: UIImage? {
        guard let url else { return nil }
        return ImageLoader.shared.cached(url, targetSize: targetSize)
    }

    var body: some View {
        let shown = image ?? initial
        ZStack {
            if let image = shown {
                if contentMode == .fill {
                    // Let the parent decide the size; the image just fills and clips.
                    Color.clear
                        .overlay { Image(uiImage: image).resizable().scaledToFill() }
                        .clipped()
                } else {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
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
                withAnimation(.easeOut(duration: 0.18)) { image = loaded }
                failed = loaded == nil
            }
        }
    }
}
