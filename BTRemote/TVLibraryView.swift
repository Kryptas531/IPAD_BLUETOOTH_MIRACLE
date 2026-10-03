#if os(iOS)
import SwiftUI
import UIKit

@MainActor
struct TVLibraryView: View {
    @ObservedObject var store: TVLibraryStore
    @ObservedObject var client: TVRemoteClient
    let kind: TVLibraryKind
    let acceptsTarget: () -> Bool
    @State private var editing: TVLibraryItem?
    @State private var showLink = false
    @State private var linkGeneration: UInt64 = 0
    @State private var query = ""
    @State private var actionError: String?
    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 230), spacing: 12)]

    var body: some View {
        let generation = client.sessionGeneration
        VStack(alignment: .leading, spacing: 14) {
            libraryToolbar
            if !store.isReady {
                Text(store.errorMessage ?? "Library unavailable").foregroundColor(.orange)
                Button("Retry library") { store.reload() }
            } else {
                if let error = store.errorMessage { Text(error).font(.caption).foregroundColor(.orange) }
                if kind == .app { searchBar(generation: generation) }
                recent(generation: generation)
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(visibleItems) { item in tile(item, generation: generation) }
                }
                if visibleItems.isEmpty {
                    Text(kind == .app ? "Add the apps you use on your TV." : "Save videos, playlists and websites here, then open them on TV with one tap.")
                        .foregroundColor(.secondary).padding(.vertical)
                }
                Text("Apps must be installed on the TV. If a shortcut does not open, edit its launch link.")
                    .font(.caption).foregroundColor(.secondary)
            }
            if let error = actionError { Text(error).font(.caption).foregroundColor(.orange) }
            if let feedback = client.launchFeedback { Text(feedback).font(.caption).foregroundColor(.secondary) }
            if !client.canLaunchApps {
                Text(client.state == .connected ? "This TV service does not support opening apps or links." : "Connect to TV to open apps and bookmarks. You can edit your library offline.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .sheet(item: $editing) { item in
            TVLibraryEditor(item: item) { updated in store.upsert(updated) }
        }
        .sheet(isPresented: $showLink) {
            TVOpenLinkSheet(store: store, client: client, generation: linkGeneration, acceptsTarget: acceptsTarget)
        }
        .onChange(of: client.sessionGeneration) { _ in showLink = false; query = ""; actionError = nil }
        .onDisappear { showLink = false; query = "" }
    }

    private var visibleItems: [TVLibraryItem] {
        let items = store.library.items.filter { $0.kind == kind }
        return items.filter(\.favorite) + items.filter { !$0.favorite }
    }
    private var libraryToolbar: some View {
        HStack {
            Menu {
                Button("Create shortcut") {
                    editing = TVLibraryItem(title: "", kind: kind, target: "", symbol: kind == .app ? "app" : "bookmark")
                }
                if kind == .app {
                    ForEach(TVLibrary.catalog) { item in
                        Button("Add \(item.title)") { _ = store.upsert(item) }
                            .disabled(store.library.items.contains { $0.id == item.id })
                    }
                    if let package = client.currentApp {
                        Button("Save current TV app") {
                            editing = TVLibraryItem(title: friendlyName(package), kind: .app, target: package)
                        }
                    }
                }
            } label: { Label(kind == .app ? "Add app" : "Add bookmark", systemImage: "plus") }
                .disabled(!store.isReady)
            Spacer()
            Button {
                linkGeneration = client.sessionGeneration; showLink = true
            } label: { Label("Open link", systemImage: "link") }
        }.buttonStyle(.bordered)
    }

    private func searchBar(generation: UInt64) -> some View {
        HStack {
            TextField("Search YouTube on TV", text: $query)
                .textFieldStyle(.roundedBorder).submitLabel(.search)
                .onSubmit { search(generation) }
            Button { search(generation) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.bordered).disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !client.canLaunchApps)
        }
    }
    private func search(_ generation: UInt64) {
        guard acceptsTarget(), generation == client.sessionGeneration else { return }
        do {
            let target = try TVLaunchTarget.youtubeSearch(query)
            if client.launch(target, expectedGeneration: generation) { query = ""; actionError = nil }
            else { actionError = "TV cannot open this search on the current connection." }
        } catch { actionError = "Enter a search phrase of at most 512 characters." }
    }

    @ViewBuilder private func recent(generation: UInt64) -> some View {
        let items = store.library.recentItems.filter { $0.kind == kind }
        if !items.isEmpty {
            Text("Recent commands").font(.caption).foregroundColor(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(items) { item in
                        Button(item.title) { launch(item, generation: generation) }
                            .buttonStyle(.bordered).disabled(!client.canLaunchApps)
                    }
                }
            }
        }
    }
    private func tile(_ item: TVLibraryItem, generation: UInt64) -> some View {
        Button { launch(item, generation: generation) } label: {
            VStack(spacing: 10) {
                Image(systemName: item.symbol).font(.system(size: 30)).frame(height: 36)
                Text(item.title).font(.headline).lineLimit(2).multilineTextAlignment(.center)
                if item.favorite { Image(systemName: "star.fill").font(.caption).foregroundColor(.yellow) }
            }.frame(maxWidth: .infinity, minHeight: 118).padding(10)
                .background(groupFill).cornerRadius(16).contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit") { editing = item }
            Button(item.favorite ? "Remove from favorites" : "Favorite") { _ = store.toggleFavorite(item.id) }
            Button("Move earlier") { move(item, direction: -1) }
            Button("Move later") { move(item, direction: 1) }
            Button("Delete", role: .destructive) { _ = store.remove(item.id) }
        }
        .accessibilityHint(client.canLaunchApps ? "Open on TV. Long press to edit." : "TV not ready. Long press to edit.")
    }
    private func launch(_ item: TVLibraryItem, generation: UInt64) {
        guard acceptsTarget(), generation == client.sessionGeneration else { return }
        do {
            let target = try TVLaunchTarget.parse(item.target, kind: item.kind)
            guard client.launch(target, expectedGeneration: generation) else {
                actionError = "Connect to TV; its service must support app launch. Nothing was queued for later."; return
            }
            _ = store.recordLaunch(item.id); actionError = nil
        } catch { actionError = "This shortcut target is invalid. Long press the tile and choose Edit." }
    }
    private func move(_ item: TVLibraryItem, direction: Int) {
        let peers = store.library.items.filter { $0.kind == kind && $0.favorite == item.favorite }
        guard let index = peers.firstIndex(where: { $0.id == item.id }), peers.indices.contains(index + direction),
              let source = store.library.items.firstIndex(where: { $0.id == item.id }),
              let destination = store.library.items.firstIndex(where: { $0.id == peers[index + direction].id }) else { return }
        _ = store.move(item.id, by: destination - source)
    }
}

@MainActor
private struct TVLibraryEditor: View {
    @State var item: TVLibraryItem
    let save: (TVLibraryItem) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        NavigationView {
            Form {
                Section("Shortcut") {
                    TextField("Title", text: $item.title)
                    TextField(item.kind == .app ? "App package or launch link" : "Content or website URL", text: $item.target)
                        .textInputAutocapitalization(.never).disableAutocorrection(true)
                    Button("Paste target") {
                        if let value = UIPasteboard.general.string, value.utf8.count <= 8192 { item.target = value }
                        else { error = "Clipboard has no supported target, or it is too long." }
                    }
                    Toggle("Favorite", isOn: $item.favorite)
                }
                Section {
                    Text(item.kind == .app ? "Use an app-supported link or its Android package ID. Package shortcuts depend on the TV's app store; edit the target if it opens the store instead of the app." : "The TV opens this link using a compatible installed app or browser.")
                        .font(.caption).foregroundColor(.secondary)
                    if let error { Text(error).foregroundColor(.orange) }
                }
            }
            .navigationTitle(item.kind == .app ? "TV app" : "TV bookmark")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            _ = try TVLaunchTarget.parse(item.target, kind: item.kind)
                            if save(item) { dismiss() }
                            else { error = "Could not save. Use a nonempty title of at most 80 characters and a valid target; unlock the iPad and retry." }
                        } catch { self.error = "Enter a valid app package or URL. File and script links are not supported." }
                    }
                }
            }
        }.navigationViewStyle(.stack)
    }
}

@MainActor
private struct TVOpenLinkSheet: View {
    @ObservedObject var store: TVLibraryStore
    @ObservedObject var client: TVRemoteClient
    let generation: UInt64
    let acceptsTarget: () -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var target = ""
    @State private var title = ""
    @State private var message: String?

    var body: some View {
        NavigationView {
            Form {
                Section("Open on TV") {
                    TextField("Video, playlist or website URL", text: $target)
                        .textInputAutocapitalization(.never).disableAutocorrection(true)
                    Button("Paste link") {
                        if let value = UIPasteboard.general.string, value.utf8.count <= 8192 { target = value }
                        else { message = "Clipboard has no supported link, or it is too long." }
                    }
                    Button("Open on TV") {
                        guard acceptsTarget(), generation == client.sessionGeneration else { message = "Connection changed. Reopen this panel."; return }
                        do {
                            let link = try TVLaunchTarget.parse(target, kind: .bookmark)
                            if client.launch(link, expectedGeneration: generation) { message = "Command sent to TV. Check the TV screen." }
                            else { message = "Connect to a TV service that supports opening links." }
                        } catch { message = "Enter a valid URL. File and script links are not supported." }
                    }.disabled(!client.canLaunchApps || target.isEmpty)
                }
                Section("Save bookmark") {
                    TextField("Bookmark title", text: $title)
                    Button("Save bookmark") {
                        let item = TVLibraryItem(title: title, kind: .bookmark, target: target, symbol: "bookmark")
                        if store.upsert(item) { message = "Bookmark saved." }
                        else { message = "Could not save. Check title and URL, unlock the iPad and retry." }
                    }.disabled(title.isEmpty || target.isEmpty || !store.isReady)
                }
                if let message { Text(message).foregroundColor(.secondary) }
            }
            .navigationTitle("Link to TV")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.navigationViewStyle(.stack)
    }
}

func friendlyName(_ package: String) -> String {
    ["com.google.android.youtube.tv": "YouTube", "com.netflix.ninja": "Netflix",
     "org.xbmc.kodi": "Kodi", "com.spotify.tv.android": "Spotify",
     "ar.tvplayer.tv": "TiviMate", "com.teamsmart.videomanager.tv": "SmartTube"][package] ?? package
}
#endif
