import SwiftUI
import AppKit

// Settings: Library (folders, imports, metadata) and Plugins (each service Crate can use,
// switched on or off, with its own settings). iPod settings live on the iPod's own page.

@MainActor
final class SettingsUI: ObservableObject {
    @Published var folderSelection: String?
    @Published var ownToneStatus = ""
    @Published var testing: PluginID?
    @Published var password = ""
    @Published var trashSize: Int64 = 0
    @Published var passwordSaved = false
}

struct SettingsView: View {
    @EnvironmentObject var model: Model
    @AppStorage("settingsTab") var tab = "Library"
    var body: some View {
        TabView(selection: $tab) {
            Tab("Library", systemImage: "square.stack", value: "Library") { LibrarySettings() }
            Tab("Plugins", systemImage: "puzzlepiece.extension", value: "Plugins") { PluginSettings() }
        }
        .frame(width: 620, height: 600)
        .onAppear { if tab == "iPod" { tab = "Library" } }     // the iPod tab is gone: its settings are on the iPod page
    }
}

/// Picks a folder with the standard open panel.
@MainActor
func chooseFolder(_ message: String, start: String = "/Volumes") -> String? {
    let p = NSOpenPanel()
    p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
    p.message = message; p.prompt = "Choose"
    p.directoryURL = URL(fileURLWithPath: start)
    return p.runModal() == .OK ? p.url?.path : nil
}

struct FolderField: View {
    var title: String
    @Binding var path: String
    var help = ""
    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                FolderStatus(path: path)
                Text(path.isEmpty ? "None" : (path as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    .frame(maxWidth: 260, alignment: .trailing)
                Button("Choose…") { if let p = chooseFolder(help.isEmpty ? title : help, start: path) { path = p } }
            }
        }
        .help(help)
    }
}

/// A folder when it's there, a warning when not. Checked off the main thread: a share that isn't mounted
/// can hang a stat for seconds, and in the view's body that ran on every redraw.
struct FolderStatus: View {
    var path: String
    @State private var exists: Bool?
    var body: some View {
        Image(systemName: exists == false ? "exclamationmark.triangle.fill" : "folder.fill")
            .foregroundStyle(exists == false ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint))
            .help(exists == false ? "Not found – is the share mounted?" : path)
            .task(id: path) { let p = path; exists = await offMain { FileManager.default.fileExists(atPath: p) } }
    }
}

extension Model {
    struct LibrarySource { var title, detail, from, icon, help: String }

    /// Where the library's songs come from besides the music folders: plugins and the import folder.
    var librarySources: [LibrarySource] {
        var out: [LibrarySource] = []
        if on(.subsonic) {
            let host = URL(string: subsonic.url)?.host ?? subsonic.url
            out.append(.init(title: "Subsonic server", detail: [host, subsonic.musicFolder].filter { !$0.isEmpty }.joined(separator: " · "),
                             from: "Subsonic plugin", icon: PluginID.subsonic.icon,
                             help: "The server's songs; set up in Settings › Plugins › Subsonic"))
        }
        if on(.ownTone) {
            out.append(.init(title: "OwnTone", detail: URL(string: ownToneURL)?.host ?? ownToneURL, from: "OwnTone plugin",
                             icon: PluginID.ownTone.icon, help: "OwnTone's library; set up in Settings › Plugins › OwnTone"))
        }
        if !importRoot.isEmpty, !folders.contains(importRoot) {
            out.append(.init(title: "Import folder", detail: importRoot, from: "Imports", icon: "square.and.arrow.down",
                             help: "Always read, so new imports show up right away; set under Imports below"))
        }
        return out
    }
}

struct LibrarySettings: View {
    @EnvironmentObject var model: Model
    @AppStorage("menuBarExtra") private var menuBar = true
    @StateObject private var ui = SettingsUI()

    var body: some View {
        Form {
            Section {
                List(selection: $ui.folderSelection) {
                    ForEach(model.folders, id: \.self) { f in
                        HStack(spacing: 8) {
                            FolderStatus(path: f)
                            Text(f).lineLimit(1).truncationMode(.middle)
                        }
                        .tag(f)
                    }
                    // what else the library reads, so an empty list doesn't look like no music; these are set elsewhere
                    ForEach(model.librarySources, id: \.title) { src in
                        HStack(spacing: 8) {
                            Image(symbol: src.icon).foregroundStyle(.secondary).frame(width: 16)
                            Text(src.title).lineLimit(1)
                            Text(src.detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(src.from).font(.caption).foregroundStyle(.tertiary)
                        }
                        .selectionDisabled()
                        .help(src.help)
                    }
                }
                .frame(height: 110)
                .overlay { if model.folders.isEmpty && model.librarySources.isEmpty { Text("No folders").foregroundStyle(.secondary) } }
                HStack(spacing: 4) {
                    Button { if let p = chooseFolder("Choose a folder with music") , !model.folders.contains(p) { model.folders.append(p) } } label: {
                        Image(systemName: "plus").frame(width: 18)
                    }
                    Button { model.folders.removeAll { $0 == ui.folderSelection }; ui.folderSelection = nil } label: {
                        Image(systemName: "minus").frame(width: 18)
                    }
                    .disabled(ui.folderSelection == nil)
                    Spacer()
                    Button("Organise Files…") { model.organize = model.albums }.disabled(model.loading)
                    Button("Rescan Library") { Task { await model.reload() } }.disabled(model.loading)
                }
                .buttonStyle(.borderless)
            } header: { Text("Music Folders") } footer: {
                Text("Crate reads every audio file in these folders (Artist/Album/Track, or the files' tags). The grey rows come from plugins and the import folder; change them there.")
            }
            Section {
                FolderField(title: "Import into", path: model.$importFolder, help: "Where dropped files, imports and downloads go; empty: the music folder")
            } header: { Text("Imports") } footer: {
                Text("Files dropped on the window, Apple Music imports and finished Soulseek downloads go here as Artist/Album/ (downloads on the same share are moved, not copied). Left empty, that's the Subsonic server's music folder, else your first music folder, else ~/Music/Crate on this Mac.")
            }
            if model.on(.ownTone) || model.on(.subsonic) {
                Section {
                    ServerPathsEditor()
                } header: { Text("Server Paths") } footer: {
                    Text("Only when your OwnTone or Subsonic server sees the music under other paths than this Mac does, as in a container or on a NAS: its folder on the left, the same folder on this Mac on the right. Rescan the library after a change.")
                }
            }
            Section {
                SecureField("Discogs token", text: model.$discogsToken, prompt: Text("Optional"))
            } header: { Text("Metadata") } footer: {
                Text("Find Metadata… searches MusicBrainz. A personal token from discogs.com/settings/developers adds Discogs results.")
            }
            Section {
                Toggle("Show Crate in the menu bar", isOn: $menuBar)
                Toggle("Frogger features", isOn: $model.froggerFeatures)
                    .help("The frog sticker, hiding songs from the iPod's Artists and Albums, the Cover Studio and cover art on Sync, and the Frogger section on the iPod's page. Turn off for a stock iPod")
                SettingsTransferRow()
            } header: { Text("App") }
            Section {
                LabeledContent("Deleted from shares") {
                    HStack {
                        Text(ui.trashSize > 0 ? ByteCountFormatter.string(fromByteCount: ui.trashSize, countStyle: .file) : "Empty").foregroundStyle(.secondary)
                        Button("Show") { Task { await model.showCrateTrash() } }.disabled(ui.trashSize == 0)
                        Button("Empty Crate Trash", role: .destructive) { Task { await model.emptyCrateTrash(); ui.trashSize = 0 } }.disabled(ui.trashSize == 0)
                    }
                }
                .task { ui.trashSize = await model.crateTrashSize() }
            } header: { Text("Crate Trash") } footer: {
                Text("Network shares have no Trash, so Crate keeps what you delete there in a hidden .crate-trash folder until you empty it.")
            }
        }
        .formStyle(.grouped)
    }
}

struct PluginSettings: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var slsk: Slskd
    @EnvironmentObject var spot: SpotifyAPI
    @StateObject private var ui = SettingsUI()

    var body: some View {
        Form {
            ForEach(PluginID.allCases.filter { $0 != .ownTone || model.plugins.contains(.ownTone) }) { p in
                Section {
                    PluginHeader(plugin: p)
                    if model.on(p) { options(p) }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder func options(_ p: PluginID) -> some View {
        switch p {
        case .ownTone:
            TextField("Server", text: model.$ownToneURL, prompt: Text("http://host:3689"))
            LabeledContent("Status") {
                HStack {
                    Text(ui.ownToneStatus.isEmpty ? (model.libraryError ?? "\(model.playlists.count) playlists") : ui.ownToneStatus)
                        .foregroundStyle(.secondary).lineLimit(1)
                    Button("Test") {
                        ui.ownToneStatus = "Connecting…"
                        Task {
                            do {
                                let t = try await LibraryLoader.fromOwnTone(model.ownToneURL)
                                ui.ownToneStatus = "Connected, \(t.count) songs"
                            } catch { ui.ownToneStatus = error.localizedDescription }
                        }
                    }
                }
            }
        case .subsonic:
            SubsonicSettings(sub: model.subsonic)
            TagrSettings(tagr: model.tagr)
        case .musicAssistant:
            MusicAssistantSettings(ma: model.ma)
        case .spotify:
            Picker("Read from", selection: Binding(get: { spot.mode }, set: { spot.mode = $0; model.objectWillChange.send(); Task { await model.reload() } })) {
                Text("My Spotify account").tag("account")
                Text("OwnTone's library").tag("owntone")
            }
            if spot.direct {
                TextField("Client ID", text: spot.$clientID, prompt: Text("From your app on developer.spotify.com"))
                LabeledContent("Redirect URI") {
                    HStack {
                        Text(SpotifyAPI.redirect).textSelection(.enabled).foregroundStyle(.secondary).font(.callout.monospaced())
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(SpotifyAPI.redirect, forType: .string) } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless).help("Copy")
                    }
                }
                LabeledContent("Account") {
                    HStack {
                        if spot.connecting { ProgressView().controlSize(.small); Text("Finish the login in your browser…").foregroundStyle(.secondary) }
                        else if let e = spot.error { Text(e).foregroundStyle(.red).lineLimit(2) }
                        else if spot.connected { Text(spot.user.isEmpty ? "Connected" : "Connected as \(spot.user)").foregroundStyle(.secondary) }
                        if spot.connected {
                            Button("Disconnect") { spot.disconnect() }
                        } else {
                            Button("Connect…") { Task { await spot.connect(); if spot.connected { await model.reload() } } }
                                .disabled(spot.connecting || spot.clientID.isEmpty)
                        }
                    }
                }
                if !spot.connected {
                    Text("Make an app at developer.spotify.com › Dashboard (Web API), add the redirect URI above, then paste its Client ID here.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open Spotify Developer Dashboard") { NSWorkspace.shared.open(URL(string: "https://developer.spotify.com/dashboard")!) }
                        .buttonStyle(.link)
                }
            }
            Toggle("Only show albums you have no files for", isOn: $model.onlyMissing)
        case .soulseek:
            TextField("slskd address", text: slsk.$url, prompt: Text("http://host:5030"))
            TextField("Username", text: slsk.$user)
            LabeledContent("Password") {
                HStack {
                    SecureField("", text: $ui.password, prompt: Text(slsk.password.isEmpty ? "Your slskd web password" : "Saved in the Keychain – type to change"))
                        .onSubmit { savePassword() }
                    Button("Save") { savePassword() }.disabled(ui.password.isEmpty)
                }
            }
            if ui.passwordSaved {
                LabeledContent("") { Label("Saved", systemImage: "key.fill").font(.caption).foregroundStyle(.green) }
            }
            TextField("API key", text: slsk.$apiKey, prompt: Text("Optional, instead of the login"))
            FolderField(title: "Downloads folder", path: slsk.$downloadsFolder,
                        help: "slskd's download folder as this Mac sees it (on a mounted share)")
            Toggle("Import finished downloads into the library", isOn: slsk.$autoImport)
            LabeledContent("Quality") { QualityMenu() }
            LabeledContent("Status") {
                HStack {
                    if ui.testing == .soulseek { ProgressView().controlSize(.small) }
                    Text(slsk.error ?? (slsk.serverState.isEmpty ? (slsk.configured ? "Not checked" : "Not set up") : slsk.serverState))
                        .foregroundStyle(slsk.error == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red)).lineLimit(2)
                    Button("Test") { ui.testing = .soulseek; Task { await slsk.check(); ui.testing = nil } }
                        .disabled(!slsk.configured)
                }
            }
        case .youtube:
            LabeledContent("yt-dlp") {
                HStack {
                    Text(model.yt.binary.map { ($0 as NSString).abbreviatingWithTildeInPath + (model.yt.version.isEmpty ? "" : " (\(model.yt.version))") } ?? "Not installed")
                        .foregroundStyle(model.yt.binary == nil ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary)).lineLimit(1).truncationMode(.middle)
                    if model.yt.binary == nil {
                        Button(model.yt.installing ? "Downloading…" : "Download") { Task { await model.yt.install() } }.disabled(model.yt.installing)
                    } else if model.yt.binary == YouTube.ownCopy.path {
                        Button("Update") { Task { await model.yt.update() } }
                    }
                }
            }
            TextField("Path to yt-dlp", text: model.yt.$customPath, prompt: Text("Optional; found by itself (Homebrew, nix, MacPorts)"))
        case .appleMusic:
            LabeledContent("Library") {
                HStack {
                    Text(model.amError ?? (model.amAlbums.isEmpty ? "Read when you open Apple Music" : "\(model.amAlbums.count) albums"))
                        .foregroundStyle(.secondary).lineLimit(2)
                    Button("Reload") { Task { await model.loadAppleMusic() } }.disabled(model.amLoading)
                }
            }
            LabeledContent("Permission") {
                Button("Automation Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                }
            }
        }
    }
}

extension PluginSettings {
    func savePassword() {
        slsk.password = ui.password
        ui.passwordSaved = !slsk.password.isEmpty && slsk.password == ui.password
        ui.password = ""
        ui.testing = .soulseek
        Task { await slsk.check(); ui.testing = nil }
    }
}

struct SubsonicSettings: View {
    @EnvironmentObject var model: Model
    @ObservedObject var sub: Subsonic
    @StateObject private var ui = SettingsUI()

    var body: some View {
        TextField("Server", text: sub.$url, prompt: Text("http://host:4533"))
        TextField("Username", text: sub.$user)
        LabeledContent("Password") {
            HStack {
                SecureField("", text: $ui.password, prompt: Text(sub.password.isEmpty ? "Your password on the server" : "Saved – type to change"))
                    .onSubmit { save() }
                Button("Save") { save() }.disabled(ui.password.isEmpty)
            }
        }
        if ui.passwordSaved {
            LabeledContent("") { Label("Saved", systemImage: "key.fill").font(.caption).foregroundStyle(.green) }
        }
        Picker("Read songs", selection: sub.$useShare) {
            Text("From the share").tag(true)
            Text("Over the Subsonic API").tag(false)
        }
        .onChange(of: sub.useShare) { Task { await model.reload() } }
        if sub.useShare {
            FolderField(title: "Music folder", path: sub.$musicFolder, help: "The server's music folder as this Mac sees it (on a mounted share)")
        }
        LabeledContent("Status") {
            HStack {
                if ui.testing == .subsonic { ProgressView().controlSize(.small) }
                Text(sub.error ?? (sub.status.isEmpty ? (sub.configured ? "Not checked" : "Not set up") : sub.status))
                    .foregroundStyle(sub.error == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red)).lineLimit(2)
                Button("Test") { ui.testing = .subsonic; Task { await sub.check(); ui.testing = nil } }
                    .disabled(!sub.configured)
            }
        }
        Text(sub.useShare
             ? "Songs in the music folder are used from there, so Crate can edit their tags, covers and files (in Navidrome, turn on Report Real Path for the Crate player under Settings › Players); the rest are downloaded when a sync needs them."
             : "No share needed: songs are streamed, and downloaded when a sync needs them. Ratings and playlists are saved on the server. Files can.t be moved or deleted from here; tags can be edited with Tagr (below).")
            .font(.caption).foregroundStyle(.secondary)
    }

    /// Saves the password, logs in with it and, when that works, reads the server's library.
    func save() {
        sub.password = ui.password
        ui.passwordSaved = !sub.password.isEmpty && sub.password == ui.password
        ui.password = ""
        ui.testing = .subsonic
        Task {
            await sub.check(); ui.testing = nil
            if sub.error == nil { await model.reload() }
        }
    }
}

struct PluginHeader: View {
    @EnvironmentObject var model: Model
    var plugin: PluginID
    var body: some View {
        let on = Binding<Bool>(get: { model.plugins.contains(plugin) }, set: { model.setPlugin(plugin, $0) })
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: plugin.icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 34, height: 34).background(plugin.tint.gradient, in: .rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(plugin.name).font(.headline)
                Text(plugin.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let r = plugin.requires { Text("Needs \(r.name)").font(.caption).foregroundStyle(.tertiary) }
            }
            Spacer()
            Toggle("", isOn: on).toggleStyle(.switch).labelsHidden()
        }
        .padding(.vertical, 4)
    }
}
