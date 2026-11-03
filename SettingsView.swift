import SwiftUI
import AppKit

// Settings: Library (folders, imports, metadata) and Plugins (each service Crate can use,
// switched on or off, with its own settings). iPod settings live on the iPod's own page.

@MainActor
final class SettingsUI: ObservableObject {
    @Published var folderSelection: String?
    @Published var ownToneStatus = ""
    @Published var testing: PluginID?
}

struct SettingsView: View {
    @EnvironmentObject var model: Model
    var body: some View {
        TabView {
            Tab("Library", systemImage: "square.stack") { LibrarySettings() }
            Tab("Plugins", systemImage: "puzzlepiece.extension") { PluginSettings() }
            Tab("iPod", systemImage: "ipod") { IPodSettingsInfo() }
        }
        .frame(width: 620, height: 600)
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
                Image(systemName: FileManager.default.fileExists(atPath: path) ? "folder.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(FileManager.default.fileExists(atPath: path) ? AnyShapeStyle(.tint) : AnyShapeStyle(.orange))
                    .help(FileManager.default.fileExists(atPath: path) ? path : "Not found – is the share mounted?")
                Text(path.isEmpty ? "None" : (path as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    .frame(maxWidth: 260, alignment: .trailing)
                Button("Choose…") { if let p = chooseFolder(help.isEmpty ? title : help, start: path) { path = p } }
            }
        }
        .help(help)
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
                            Image(systemName: FileManager.default.fileExists(atPath: f) ? "folder.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(FileManager.default.fileExists(atPath: f) ? AnyShapeStyle(.tint) : AnyShapeStyle(.orange))
                            Text(f).lineLimit(1).truncationMode(.middle)
                        }
                        .tag(f)
                    }
                }
                .frame(height: 110)
                .overlay { if model.folders.isEmpty { Text("No folders").foregroundStyle(.secondary) } }
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
                Text("Crate reads every audio file in these folders (Artist/Album/Track, or the files' tags).")
            }
            Section {
                FolderField(title: "Import into", path: model.$importFolder, help: "Where dropped files, imports and downloads are copied")
            } header: { Text("Imports") } footer: {
                Text("Files dropped on the window, Apple Music imports and finished Soulseek downloads are copied here as Artist/Album/. With OwnTone on, pick a folder inside its music folder so it picks them up.")
            }
            Section {
                Picker("Play music on", selection: model.player.$output) {
                    Text("This Mac").tag("mac")
                    if model.on(.ownTone) { Text("OwnTone's speakers").tag("owntone") }
                }
                Toggle("Show Crate in the menu bar", isOn: $menuBar)
            } header: { Text("App") }
            Section {
                SecureField("Discogs token", text: model.$discogsToken, prompt: Text("Optional"))
            } header: { Text("Metadata") } footer: {
                Text("Find Metadata… searches MusicBrainz. A personal token from discogs.com/settings/developers adds Discogs results.")
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
            ForEach(PluginID.allCases) { p in
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
            SecureField("Password", text: Binding(get: { slsk.password }, set: { slsk.password = $0 }))
            if !slsk.password.isEmpty {
                LabeledContent("") { Label("Saved in the Keychain", systemImage: "key.fill").font(.caption).foregroundStyle(.secondary) }
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

struct IPodSettingsInfo: View {
    @EnvironmentObject var model: Model
    var body: some View {
        Form {
            Section {
                if let i = model.ipod {
                    LabeledContent("Connected", value: "\(model.podName) – \(i.modelName)")
                    LabeledContent("Lossless converted to", value: "\(model.podSettings.aacKbps) kbps AAC")
                    LabeledContent("Eject after sync", value: model.podSettings.ejectAfterSync ? "On" : "Off")
                    Button("Open iPod Settings") { model.search = ""; model.pane = .ipod; NSApp.keyWindow?.close() }
                } else {
                    Text("No iPod connected").foregroundStyle(.secondary)
                }
            } footer: {
                Text("Each iPod keeps its own settings (name, conversion, On-The-Go, eject after sync) on its Summary page in the sidebar.")
            }
        }
        .formStyle(.grouped)
    }
}
