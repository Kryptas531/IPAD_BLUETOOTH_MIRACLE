#if os(iOS)
import SwiftUI

/// All launches go through the paired TV session. No PC endpoint or credentials.
@MainActor
struct TVMediaView: View {
    let launch: (String) -> Void
    let acceptsTarget: () -> Bool
    @State private var tmdb = ""
    @State private var series = false
    @State private var error: String?

    var body: some View {
        DisclosureGroup("Actions on TV") {
            VStack(alignment: .leading, spacing: 10) {
                Button("Open Lampa on TV") { send(TVLaunchTarget.lampaHome) }
                Button("Lampa history on TV") { send(TVLaunchTarget.lampaHistory) }
                Text("History stays on TV. Choose the last file with the remote; this button does not automatically resume playback.")
                    .font(.caption).foregroundColor(.secondary)
                Picker("Card type", selection: $series) {
                    Text("Movie").tag(false)
                    Text("Series").tag(true)
                }.pickerStyle(.segmented)
                TextField("TMDB ID", text: $tmdb).keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                Button("Open TMDB card on TV") {
                    do { send(try TVLaunchTarget.tmdbCard(id: tmdb, series: series)) }
                    catch { self.error = "Enter a positive numeric TMDB ID." }
                }
                Text("Android chooses the HTTPS handler. If Lampa opens the card, choose Torrents there using the TV remote. Direct torrent chooser and last-file playback are not exposed by the paired TV protocol.")
                    .font(.caption).foregroundColor(.secondary)
                Text("TorrServer restart and newest-torrent playback in TV VLC need a TV-side control API. The paired remote only opens apps/links and sends keys; no Windows setup is needed.")
                    .font(.caption).foregroundColor(.secondary)
                if let error { Text(error).font(.caption).foregroundColor(.orange) }
            }.buttonStyle(.bordered)
        }
    }

    private func send(_ target: TVLaunchTarget) {
        guard acceptsTarget() else { error = "Connect to the paired TV first."; return }
        error = nil
        launch(target.wireLink)
    }
}
#endif
