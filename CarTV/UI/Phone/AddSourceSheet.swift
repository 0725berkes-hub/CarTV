import SwiftUI
import PhotosUI
import Vision

struct AddSourceSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var name = ""
    @State private var phase: PlaylistImporter.Phase = .idle
    @State private var error: String?
    @State private var showScanner = false
    @State private var showXtream = false
    @State private var xHost = ""
    @State private var xUser = ""
    @State private var xPass = ""
    @State private var task: Task<Void, Never>?
    @FocusState private var focused: Bool

    private var detected: Result<SubscriptionInput, SubscriptionInput.Failure> { SubscriptionInput.detect(text) }
    private var isBusy: Bool { phase != .idle }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.s5) {
                    inputCard
                    if case .success(let input) = detected, !text.isEmpty { detectionHint(input) }
                    if let error { errorCard(error) }
                    quickActions
                    Text("Supports M3U/M3U8 links, Xtream logins, config files, or pasted M3U content.")
                        .font(Theme.Font.caption).foregroundStyle(Theme.inkFaint).padding(.horizontal, Theme.s1)
                }
                .padding(Theme.s4)
            }
            .background(Theme.ground.ignoresSafeArea())
            .navigationTitle("Add Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { task?.cancel(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { importNow() } label: {
                        if isBusy { ProgressView().controlSize(.small) } else { Text("Add").bold() }
                    }
                    .disabled(isBusy || (try? detected.get()) == nil)
                }
            }
            .sheet(isPresented: $showScanner) {
                QRScannerView { code in text = code; showScanner = false }
            }
            .sheet(isPresented: $showXtream) { xtreamSheet }
            .onAppear { if let s = UIPasteboard.general.string, text.isEmpty, case .success = SubscriptionInput.detect(s) { text = s } }
            .interactiveDismissDisabled(isBusy)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Pieces

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            Text("Link or M3U content").eyebrow()
            TextEditor(text: $text)
                .font(Theme.Font.mono)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 120, maxHeight: 200)
                .focused($focused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("https://example.com/playlist.m3u").font(Theme.Font.mono).foregroundStyle(Theme.inkFaint)
                            .padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                    }
                }
            Divider().overlay(Theme.hairline)
            Text("Name (optional)").eyebrow()
            TextField("My IPTV", text: $name).font(Theme.Font.body)
        }
        .glassCard(radius: Theme.radiusL)
    }

    private func detectionHint(_ input: SubscriptionInput) -> some View {
        let (symbol, label): (String, LocalizedStringResource) = switch input {
        case .remotePlaylist: ("antenna.radiowaves.left.and.right", "Subscription link")
        case .inlineM3U: ("doc.plaintext", "Pasted M3U list")
        case .singleStream: ("play.rectangle", "Single stream")
        case .xtream: ("person.badge.key", "Xtream login")
        case .multipleURLs(let u): ("link", "Found \(u.count) sources")
        }
        return HStack(spacing: Theme.s2) {
            Image(systemName: symbol).foregroundStyle(Theme.accent)
            Text(label).font(Theme.Font.caption).foregroundStyle(Theme.ink)
            Spacer()
            if case .saving(let d, let t) = phase { Text("\(d)/\(t)").font(Theme.Font.caption).monospacedDigit().foregroundStyle(Theme.inkMuted) }
            else if isBusy { Text(phaseText).font(Theme.Font.caption).foregroundStyle(Theme.inkMuted) }
        }
        .padding(.horizontal, Theme.s3).padding(.vertical, Theme.s2)
        .background(Theme.accent.opacity(0.1), in: Capsule())
    }

    private var phaseText: String {
        switch phase {
        case .downloading: String(localized: "Loading…")
        case .parsing: String(localized: "Parsing…")
        case .checking: String(localized: "Checking channels…")
        default: ""
        }
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: Theme.s2) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.amber)
            Text(message).font(Theme.Font.callout).foregroundStyle(Theme.ink)
        }
        .padding(Theme.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.amber.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
    }

    private var quickActions: some View {
        HStack(spacing: Theme.s2) {
            QuickAction(symbol: "qrcode.viewfinder", title: "Scan QR") { showScanner = true }
            QuickAction(symbol: "doc.on.clipboard", title: "Paste") { if let s = UIPasteboard.general.string { text = s } }
            QuickAction(symbol: "person.badge.key", title: "Xtream") { showXtream = true }
        }
    }

    private var xtreamSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://server:port", text: $xHost).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Username", text: $xUser).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $xPass)
                } footer: {
                    Text("We build the standard get.php M3U link from these details. Credentials stay on this device.")
                }
            }
            .navigationTitle("Xtream Codes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showXtream = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use") {
                        text = "\(xHost)|\(xUser)|\(xPass)"
                        if name.isEmpty { name = URL.lenient(xHost)?.host ?? "" }
                        showXtream = false
                    }.disabled(xHost.isEmpty || xUser.isEmpty || xPass.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: Import

    private func importNow() {
        guard case .success(let input) = detected else { return }
        error = nil
        focused = false
        task = Task {
            let importer = PlaylistImporter(container: env.modelContainer)
            do {
                phase = .downloading
                let summaries = try await importer.importInput(input, suggestedName: name.trimmed.nilIfEmpty) { phase = $0 }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                if env.settings.healthChecks {
                    for s in summaries { if let p = env.library.playlist(id: s.playlistID) { env.health.check(p) } }
                }
                dismiss()
            } catch is CancellationError {
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                self.error = error.localizedDescription
            }
            phase = .idle
        }
    }
}

struct QuickAction: View {
    let symbol: String
    let title: LocalizedStringResource
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: Theme.s2) {
                Image(systemName: symbol).font(.system(size: 22, weight: .medium)).foregroundStyle(Theme.accent)
                Text(title).font(Theme.Font.caption).foregroundStyle(Theme.ink)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.s4)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
    }
}
