#if os(iOS)
import SwiftUI
import Foundation
import Security

private final class MediaNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
private enum MediaAction: String, Encodable {
    case capabilities, torrents, newest, files, play, web, restart, card, resume
}
private struct MediaRequest: Encodable {
    var action: MediaAction
    var id: String? = nil
    var file: Int? = nil
    var tmdb: String? = nil
    var kind: String? = nil
}
private struct MediaEntry: Decodable, Identifiable {
    let id: String
    let name: String
}
private struct MediaFile: Decodable, Identifiable {
    let id: Int
    let name: String
}
private struct MediaReply: Decodable {
    var lampa: Bool?; var resume: Bool?; var restart: Bool?; var vlc: Bool?; var newest: Bool?
    var torrents: [MediaEntry]?; var files: [MediaFile]?
    var id: String?; var url: String?; var message: String?; var error: String?
}

@MainActor
struct TVMediaView: View {
    let launch: (String) -> Void
    let acceptsTarget: () -> Bool
    @Environment(\.openURL) private var openURL
    @AppStorage("tv.media.endpoint") private var endpoint = ""
    @State private var token = ""
    @State private var tmdb = ""
    @State private var series = false
    @State private var capabilities: MediaReply?
    @State private var torrents: [MediaEntry] = []
    @State private var files: [MediaFile] = []
    @State private var torrent = ""
    @State private var message = "Configure a trusted HTTPS bridge to enable media actions."
    @State private var busy = false
    @State private var operation: Task<Void, Never>?
    @State private var confirmRestart = false
    private let service = "io.github.jqssun.btremote.tv-media"

    var body: some View {
        DisclosureGroup("TV Actions") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("https://Windows-LAN-host:9443", text: $endpoint)
                    .textInputAutocapitalization(.never).disableAutocorrection(true)
                SecureField("Bridge token", text: $token)
                Button("Save and check capabilities") {
                    guard saveToken() else { message = "Keychain save failed"; return }
                    capabilities = nil; torrents = []; files = []; torrent = ""
                    perform(MediaRequest(action: .capabilities)) { capabilities = $0 }
                }
                Text(message).font(.caption).foregroundColor(.secondary)
                if let capabilities {
                    Text("Lampa: \(capabilities.lampa == true ? "adapter configured" : "unavailable") · VLC: \(capabilities.vlc == true ? "installed" : "unavailable")")
                        .font(.caption)
                    Picker("Card type", selection: $series) {
                        Text("Movie").tag(false); Text("Series").tag(true)
                    }.pickerStyle(.segmented)
                    TextField("TMDB ID", text: $tmdb).keyboardType(.numberPad)
                    Button("Lampa card / torrent chooser") {
                        perform(MediaRequest(action: .card, tmdb: tmdb, kind: series ? "tv" : "movie"), receive: launchReply)
                    }.disabled(capabilities.lampa != true)
                    Button("Resume last viewed file on TV") {
                        perform(MediaRequest(action: .resume), receive: launchReply)
                    }.disabled(capabilities.resume != true)
                    HStack {
                        Button("Browse torrents") {
                            perform(MediaRequest(action: .torrents)) { torrents = $0.torrents ?? []; files = []; torrent = "" }
                        }
                        Button("Most recent torrent") {
                            perform(MediaRequest(action: .newest)) { reply in
                                if let id = reply.id { selectTorrent(id) }
                            }
                        }.disabled(capabilities.newest != true)
                    }
                    ForEach(torrents) { item in
                        Button(item.name) { selectTorrent(item.id) }
                    }
                    if !torrent.isEmpty {
                        Text(files.isEmpty ? "No resolved files yet. Retry selecting this torrent." : "Choose a file explicitly for Windows VLC.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    if capabilities.newest != true {
                        Text("Most recent unavailable: addition timestamps not configured. Browse manually.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    ForEach(files) { file in
                        Button("Play in Windows VLC: \(file.name)") {
                            perform(MediaRequest(action: .play, id: torrent, file: file.id)) { message = $0.message ?? "Request accepted" }
                        }.disabled(capabilities.vlc != true)
                    }
                    Button("Open TorrServer web UI on iPad") {
                        perform(MediaRequest(action: .web)) { reply in
                            if let raw = reply.url, let url = URL(string: raw), url.scheme == "https" { openURL(url) }
                        }
                    }
                    Button("Restart local TorrServer") { confirmRestart = true }
                        .disabled(capabilities.restart != true)
                }
            }.textFieldStyle(.roundedBorder).buttonStyle(.bordered).disabled(busy)
        }
        .confirmationDialog("Restart the bridge-owned TorrServer?", isPresented: $confirmRestart, titleVisibility: .visible) {
            Button("Restart") { perform(MediaRequest(action: .restart)) { message = $0.message ?? "Ready" } }
        }
        .onAppear { loadToken() }
        .onDisappear { operation?.cancel(); busy = false }
        .onChange(of: endpoint) { _ in capabilities = nil; operation?.cancel(); busy = false }
        .onChange(of: token) { _ in capabilities = nil; operation?.cancel(); busy = false }
    }

    private func selectTorrent(_ id: String) {
        torrent = id; files = []
        perform(MediaRequest(action: .files, id: id)) { files = $0.files ?? [] }
    }
    private func launchReply(_ reply: MediaReply) {
        if let url = reply.url { launch(url); message = "TV link sent; check the TV. Playback is not confirmed." }
    }
    private func perform(_ body: MediaRequest, receive: @escaping @MainActor (MediaReply) -> Void) {
        guard acceptsTarget(), let base = URL(string: endpoint), base.scheme == "https",
              base.host != nil, base.user == nil, base.password == nil, base.query == nil,
              base.fragment == nil, base.path.isEmpty || base.path == "/", token.count >= 32 else {
            message = "Enter a trusted HTTPS origin and token (32+ characters)."; return
        }
        busy = true
        operation = Task { @MainActor in
            defer { busy = false }
            do {
                var request = URLRequest(url: base.appendingPathComponent("actions"))
                request.httpMethod = "POST"; request.timeoutInterval = 20
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(body)
                // Ephemeral session: no persisted cookies, cache, or credentials; standard TLS trust.
                let session = URLSession(configuration: .ephemeral, delegate: MediaNoRedirect(), delegateQueue: nil)
                defer { session.invalidateAndCancel() }
                let (data, response) = try await session.data(for: request)
                guard !Task.isCancelled, acceptsTarget() else { return }
                let reply = try JSONDecoder().decode(MediaReply.self, from: data)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    message = reply.error ?? "Bridge rejected request"; return
                }
                message = "Bridge connected"; receive(reply)
            } catch {
                if !Task.isCancelled { message = "Bridge unavailable. Check HTTPS trust, address and local configuration." }
            }
        }
    }
    private var keyQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "token"]
    }
    private func loadToken() {
        var query = keyQuery
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
            token = String(data: data, encoding: .utf8) ?? ""
        }
    }
    private func saveToken() -> Bool {
        let values: [String: Any] = [kSecValueData as String: Data(token.utf8)]
        let status = SecItemUpdate(keyQuery as CFDictionary, values as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var query = keyQuery.merging(values) { _, new in new }
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }
}
#endif
