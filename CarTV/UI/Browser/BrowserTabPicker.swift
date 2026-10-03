import SwiftUI

struct BrowserTabPicker: View {
    let tabs: BrowserTabs
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: Theme.s4) {
            HStack {
                Text("Tabs").font(Theme.Font.title2)
                Spacer()
                Button { tabs.add(); onDone() } label: {
                    Label("New tab", systemImage: "plus").padding(Theme.s3).contentShape(Rectangle())
                }
                .buttonStyle(CarFocusButtonStyle(radius: Theme.radiusS))
                Button(action: onDone) {
                    Image(systemName: "xmark").frame(width: 48, height: 48).contentShape(Rectangle())
                }
                .buttonStyle(CarFocusButtonStyle(radius: Theme.radiusS)).accessibilityLabel("Done")
            }
            ScrollView {
                LazyVStack(spacing: Theme.s3) {
                    ForEach(tabs.sessions) { session in
                        HStack(spacing: 0) {
                            Button { tabs.select(session); onDone() } label: {
                                HStack(spacing: Theme.s3) {
                                    Image(systemName: session.id == tabs.selectedID ? "checkmark.circle.fill" : "globe")
                                        .foregroundStyle(Theme.accent)
                                    VStack(alignment: .leading, spacing: Theme.s1) {
                                        Text(session.pageTitle.isEmpty ? "New tab" : session.pageTitle)
                                            .font(Theme.Font.headline).lineLimit(1)
                                        Text(session.url.host ?? "Browse").font(Theme.Font.caption).foregroundStyle(Theme.inkMuted).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(Theme.s4).frame(maxWidth: .infinity, minHeight: 64).contentShape(Rectangle())
                            }
                            .buttonStyle(CarFocusButtonStyle(radius: Theme.radiusM))
                            Button { tabs.close(session) } label: {
                                Image(systemName: "xmark").frame(width: 52, height: 64).contentShape(Rectangle())
                            }
                            .buttonStyle(CarPressStyle()).accessibilityLabel("Close tab")
                        }
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusM))
                    }
                }
            }
        }
        .foregroundStyle(Theme.ink)
    }
}
