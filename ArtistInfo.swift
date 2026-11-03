import SwiftUI

// Artist pages: a short bio and photo from Wikipedia (found through MusicBrainz → Wikidata), and
// the discography from MusicBrainz with what's in the library and what's missing. Cached in
// Application Support.

struct ReleaseGroup: Codable, Hashable, Identifiable {
    var id: String
    var title, type, date: String
    var year: Int { Int(date.prefix(4)) ?? 0 }
    var cover: URL? { URL(string: "https://coverartarchive.org/release-group/\(id)/front-250") }
}

struct ArtistInfo: Codable, Hashable {
    var mbid = "", bio = "", photo = "", wikipedia = ""
    var area = "", lifeSpan = "", kind = ""
    var releases: [ReleaseGroup] = []
    var fetched = Date()
}

enum ArtistLookup {
    static var url: URL { PodCache.dir.appendingPathComponent("artist-info.json") }
    static func load() -> [String: ArtistInfo] { (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: ArtistInfo].self, from: $0) } ?? [:] }
    static func save(_ c: [String: ArtistInfo]) { try? JSONEncoder().encode(c).write(to: url) }

    static func fetch(_ name: String) async -> ArtistInfo? {
        var c = URLComponents(string: "https://musicbrainz.org/ws/2/artist/")!
        c.queryItems = [.init(name: "query", value: "artist:\"\(name)\""), .init(name: "fmt", value: "json"), .init(name: "limit", value: "3")]
        guard let j = try? await MusicBrainz.get(c.url!),
              let a = ((j["artists"] as? [[String: Any]]) ?? []).first(where: { ($0["score"] as? Int ?? 0) >= 90 }),
              let id = a["id"] as? String else { return nil }
        var info = ArtistInfo(mbid: id)
        info.area = (a["area"] as? [String: Any])?["name"] as? String ?? ""
        info.kind = a["type"] as? String ?? ""
        let span = a["life-span"] as? [String: Any]
        info.lifeSpan = [span?["begin"] as? String, span?["end"] as? String].compactMap { $0?.prefix(4).description }.joined(separator: "–")
        try? await Task.sleep(for: .seconds(1.1))
        // discography: albums and EPs, no compilations or live records
        if let rg = try? await MusicBrainz.get(URL(string: "https://musicbrainz.org/ws/2/release-group?artist=\(id)&type=album|ep&limit=100&fmt=json")!) {
            info.releases = ((rg["release-groups"] as? [[String: Any]]) ?? []).compactMap { g in
                let secondary = (g["secondary-types"] as? [String]) ?? []
                guard secondary.isEmpty, let gid = g["id"] as? String else { return nil }
                return ReleaseGroup(id: gid, title: g["title"] as? String ?? "", type: g["primary-type"] as? String ?? "",
                                    date: g["first-release-date"] as? String ?? "")
            }.sorted { ($0.date.isEmpty ? "9999" : $0.date) < ($1.date.isEmpty ? "9999" : $1.date) }
        }
        try? await Task.sleep(for: .seconds(1.1))
        // bio and photo: MusicBrainz → Wikidata → English Wikipedia
        if let rels = try? await MusicBrainz.get(URL(string: "https://musicbrainz.org/ws/2/artist/\(id)?inc=url-rels&fmt=json")!),
           let wd = ((rels["relations"] as? [[String: Any]]) ?? []).first(where: { $0["type"] as? String == "wikidata" }),
           let qid = ((wd["url"] as? [String: Any])?["resource"] as? String)?.split(separator: "/").last,
           let (d, _) = try? await URLSession.shared.data(from: URL(string: "https://www.wikidata.org/wiki/Special:EntityData/\(qid).json")!),
           let w = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let entity = (w["entities"] as? [String: Any])?[String(qid)] as? [String: Any],
           let title = ((entity["sitelinks"] as? [String: Any])?["enwiki"] as? [String: Any])?["title"] as? String,
           let enc = title.replacingOccurrences(of: " ", with: "_").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let (sd, _) = try? await URLSession.shared.data(from: URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(enc)")!),
           let s = try? JSONSerialization.jsonObject(with: sd) as? [String: Any] {
            info.bio = s["extract"] as? String ?? ""
            info.photo = ((s["originalimage"] as? [String: Any]) ?? (s["thumbnail"] as? [String: Any]))?["source"] as? String ?? ""
            info.wikipedia = ((s["content_urls"] as? [String: Any])?["desktop"] as? [String: Any])?["page"] as? String ?? ""
        }
        return info
    }
}

extension Model {
    func loadArtistInfo(_ name: String) async {
        let k = name.lowercased()
        if let i = artistInfo[k], Date().timeIntervalSince(i.fetched) < 30 * 86400 { return }
        guard name != "Various Artists", !artistLoading.contains(k) else { return }
        artistLoading.insert(k); defer { artistLoading.remove(k) }
        if let info = await ArtistLookup.fetch(name) {
            artistInfo[k] = info
            ArtistLookup.save(artistInfo)
        }
    }
}

/// Bio and discography on an artist's page.
struct ArtistExtras: View {
    @EnvironmentObject var model: Model
    var artist: Artist
    private let columns = [GridItem(.adaptive(minimum: 130, maximum: 160), spacing: 18)]

    var body: some View {
        let info = model.artistInfo[artist.id]
        VStack(alignment: .leading, spacing: 24) {
            if let info, !info.bio.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("About").font(.title2.bold())
                    Text(info.bio).lineSpacing(3).textSelection(.enabled)
                    HStack(spacing: 12) {
                        if !info.area.isEmpty { Label(info.area, systemImage: "mappin.and.ellipse") }
                        if !info.lifeSpan.isEmpty { Label(info.lifeSpan, systemImage: "calendar") }
                        if let u = URL(string: info.wikipedia), !info.wikipedia.isEmpty { Link("Wikipedia", destination: u) }
                    }
                    .font(.callout).foregroundStyle(.secondary)
                }
                .padding(18).glassEffect(.regular, in: .rect(cornerRadius: 18))
            } else if model.artistLoading.contains(artist.id) {
                HStack { ProgressView().controlSize(.small); Text("Looking up \(artist.name)…").foregroundStyle(.secondary) }
            }
            if let info, !info.releases.isEmpty {
                let loose = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
                let owned = Set(artist.albums.map { loose($0.title) })
                let missing = info.releases.filter { !owned.contains(loose($0.title)) }
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Discography").font(.title2.bold())
                        Text("\(info.releases.count - missing.count) of \(info.releases.count) in your library").foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(info.releases) { r in
                            let have = owned.contains(loose(r.title))
                            VStack(alignment: .leading, spacing: 5) {
                                CachedImage(url: r.cover, seed: "ArtistInfo.swift:11")
                                    .frame(width: 130, height: 130).clipShape(.rect(cornerRadius: 10))
                                    .opacity(have ? 1 : 0.55)
                                    .overlay(alignment: .topTrailing) { if have { MarkBadge(mark: .onIPod, size: 22).help("In your library").padding(6) } }
                                Text(r.title).font(.callout.weight(.medium)).lineLimit(1)
                                Text([r.year > 0 ? "\(r.year)" : "", r.type].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .contentShape(.rect)
                            .contextMenu {
                                if !have, model.on(.soulseek) {
                                    Button("Find on Soulseek", systemImage: "arrow.down.circle") { model.findOnSoulseek(artist.name, r.title) }
                                }
                                if let a = artist.albums.first(where: { loose($0.title) == loose(r.title) }) {
                                    Button("Go to Album", systemImage: "square.stack") { model.path.append(.album(a)) }
                                }
                            }
                            .onTapGesture(count: 2) {
                                if let a = artist.albums.first(where: { loose($0.title) == loose(r.title) }) { model.path.append(.album(a)) }
                                else if model.on(.soulseek) { model.findOnSoulseek(artist.name, r.title) }
                            }
                        }
                    }
                }
            }
        }
        .task(id: artist.id) { await model.loadArtistInfo(artist.name) }
    }
}
