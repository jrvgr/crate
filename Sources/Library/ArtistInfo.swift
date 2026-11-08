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
    var version: Int?             // ArtistLookup.version it was fetched with; older ones are fetched again
    var partial: Bool?            // a request failed (MusicBrainz rate limit, network): fetched again soon
}

enum ArtistLookup {
    static let version = 3        // 2: singles and compilations in the discography; 3: refetch lookups that half failed
    static var url: URL { PodCache.dir.appendingPathComponent("artist-info.json") }
    static func load() -> [String: ArtistInfo] { (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: ArtistInfo].self, from: $0) } ?? [:] }
    static func save(_ c: [String: ArtistInfo]) { try? JSONEncoder().encode(c).write(to: url) }

    static func fetch(_ name: String) async -> ArtistInfo? {
        var c = URLComponents(string: "https://musicbrainz.org/ws/2/artist/")!
        c.queryItems = [.init(name: "query", value: "artist:\"\(name)\""), .init(name: "fmt", value: "json"), .init(name: "limit", value: "3")]
        guard let j = try? await MusicBrainz.get(c.url!),
              let a = ((j["artists"] as? [[String: Any]]) ?? []).first(where: { ($0["score"] as? Int ?? 0) >= 90 }),
              let id = a["id"] as? String else { return nil }
        var info = ArtistInfo(mbid: id, version: version)
        info.area = (a["area"] as? [String: Any])?["name"] as? String ?? ""
        info.kind = a["type"] as? String ?? ""
        let span = a["life-span"] as? [String: Any]
        info.lifeSpan = [span?["begin"] as? String, span?["end"] as? String].compactMap { $0?.prefix(4).description }.joined(separator: "–")
        try? await Task.sleep(for: .seconds(1.1))
        // discography: albums (compilations and soundtracks too), EPs and singles; no live records, remixes or DJ mixes
        let skip: Set<String> = ["Live", "Remix", "DJ-mix", "Interview", "Demo", "Audiobook", "Audio drama", "Spokenword", "Field recording"]
        var groups: [[String: Any]] = [], offset = 0
        while offset < 500 {
            guard let rg = try? await MusicBrainz.get(URL(string: "https://musicbrainz.org/ws/2/release-group?artist=\(id)&type=album|ep|single&limit=100&offset=\(offset)&fmt=json")!),
                  let page = rg["release-groups"] as? [[String: Any]] else { info.partial = true; break }
            groups += page; offset += 100
            if page.count < 100 || offset >= rg["release-group-count"] as? Int ?? 0 { break }
            try? await Task.sleep(for: .seconds(1.1))
        }
        info.releases = groups.compactMap { g in
            let secondary = (g["secondary-types"] as? [String]) ?? []
            guard skip.isDisjoint(with: secondary), let gid = g["id"] as? String else { return nil }
            return ReleaseGroup(id: gid, title: g["title"] as? String ?? "", type: g["primary-type"] as? String ?? "",
                                date: g["first-release-date"] as? String ?? "")
        }.sorted { ($0.date.isEmpty ? "9999" : $0.date) < ($1.date.isEmpty ? "9999" : $1.date) }
        try? await Task.sleep(for: .seconds(1.1))
        // bio and photo: MusicBrainz → Wikidata → English Wikipedia. A failed request marks the lookup
        // partial (fetched again soon); an artist without a Wikipedia page just has no bio.
        guard let rels = try? await MusicBrainz.get(URL(string: "https://musicbrainz.org/ws/2/artist/\(id)?inc=url-rels&fmt=json")!) else {
            info.partial = true; return info
        }
        guard let wd = ((rels["relations"] as? [[String: Any]]) ?? []).first(where: { $0["type"] as? String == "wikidata" }),
              let qid = ((wd["url"] as? [String: Any])?["resource"] as? String)?.split(separator: "/").last else { return info }
        guard let w = await json("https://www.wikidata.org/wiki/Special:EntityData/\(qid).json") else { info.partial = true; return info }
        guard let entity = (w["entities"] as? [String: Any])?[String(qid)] as? [String: Any],
              let title = ((entity["sitelinks"] as? [String: Any])?["enwiki"] as? [String: Any])?["title"] as? String,
              let enc = title.replacingOccurrences(of: " ", with: "_").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return info }
        guard let s = await json("https://en.wikipedia.org/api/rest_v1/page/summary/\(enc)") else { info.partial = true; return info }
        info.bio = s["extract"] as? String ?? ""
        info.photo = ((s["originalimage"] as? [String: Any]) ?? (s["thumbnail"] as? [String: Any]))?["source"] as? String ?? ""
        info.wikipedia = ((s["content_urls"] as? [String: Any])?["desktop"] as? [String: Any])?["page"] as? String ?? ""
        return info
    }

    /// A JSON object from Wikidata or Wikipedia, nil when the request failed.
    private static func json(_ url: String) async -> [String: Any]? {
        var r = URLRequest(url: URL(string: url)!); r.setValue(MusicBrainz.agent, forHTTPHeaderField: "User-Agent"); r.timeoutInterval = 20
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }
}

extension Model {
    func loadArtistInfo(_ name: String) async {
        let k = name.lowercased()
        if let i = artistInfo[k], i.version == ArtistLookup.version,
           Date().timeIntervalSince(i.fetched) < (i.partial == true ? 120 : 30 * 86400) { return }
        guard name != "Various Artists", !artistLoading.contains(k) else { return }
        artistLoading.insert(k); artistFailed.remove(k); defer { artistLoading.remove(k) }
        if var info = await ArtistLookup.fetch(name) {
            // a half-failed lookup doesn't wipe a good one from before
            if info.partial == true, let old = artistInfo[k], old.partial != true {
                if info.releases.isEmpty { info.releases = old.releases }
                if info.bio.isEmpty { (info.bio, info.photo, info.wikipedia) = (old.bio, old.photo, old.wikipedia) }
            }
            artistInfo[k] = info
            ArtistLookup.save(artistInfo)
        } else if artistInfo[k] == nil {
            artistFailed.insert(k)
        }
    }
}

/// The bio under an artist's header: three lines from Wikipedia, where it's from, and the link for the rest.
/// While it loads, placeholder lines hold its place so the page doesn't move when it arrives.
struct ArtistExtras: View {
    @EnvironmentObject var model: Model
    var artist: Artist

    var body: some View {
        let info = model.artistInfo[artist.id]
        Group {
            if let info, !info.bio.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(info.bio).lineSpacing(3).lineLimit(3).textSelection(.enabled)
                    HStack(spacing: 12) {
                        if !info.area.isEmpty { Label(info.area, systemImage: "mappin.and.ellipse") }
                        if !info.lifeSpan.isEmpty { Label(info.lifeSpan, systemImage: "calendar") }
                        if let u = URL(string: info.wikipedia), !info.wikipedia.isEmpty { Link("More on Wikipedia", destination: u) }
                    }
                    .font(.callout).foregroundStyle(.secondary)
                }
            } else if model.artistLoading.contains(artist.id) {
                Text(String(repeating: "Loading the artist's story ", count: 30)).lineSpacing(3).lineLimit(3).redacted(reason: .placeholder)
            }
        }
        .frame(maxWidth: 820, alignment: .leading)
        .task(id: artist.id) { await model.loadArtistInfo(artist.name) }
    }
}

/// A release MusicBrainz lists that the library doesn't have, as a compact row that opens its page.
struct MissingRow: View {
    @EnvironmentObject var model: Model
    var release: ReleaseGroup
    var artist: String

    var body: some View {
        NavigationLink(value: Route.release(release, artist: artist)) {
            HStack(spacing: 10) {
                CachedImage(url: release.cover, seed: release.id)
                    .frame(width: 44, height: 44).clipShape(.rect(cornerRadius: 6, style: .continuous)).opacity(0.7)
                VStack(alignment: .leading, spacing: 2) {
                    Text(release.title).lineLimit(1)
                    Text(release.year > 0 ? String(release.year) : "Year unknown").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if model.on(.soulseek) { Button("Find on Soulseek", systemImage: "arrow.down.circle") { model.findOnSoulseek(artist, release.title) } }
            LidarrButton(artist: artist, album: release.title)
        }
    }
}

/// A song on a MusicBrainz release.
struct ReleaseTrack: Identifiable {
    var id: String
    var number: Int
    var title: String
    var lengthMs: Int
}

extension ArtistLookup {
    /// The songs of a release group's earliest official edition (one request: its editions with their recordings).
    static func tracks(_ group: String) async -> [ReleaseTrack]? {
        guard let j = try? await MusicBrainz.get(URL(string: "https://musicbrainz.org/ws/2/release?release-group=\(group)&inc=recordings&limit=25&fmt=json")!) else { return nil }
        let editions = (j["releases"] as? [[String: Any]]) ?? []
        let date = { (r: [String: Any]) in (r["date"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "9999" }
        let pick = editions.filter { $0["status"] as? String == "Official" }.min { date($0) < date($1) } ?? editions.first
        guard let media = pick?["media"] as? [[String: Any]] else { return nil }
        var n = 0
        return media.flatMap { m in ((m["tracks"] as? [[String: Any]]) ?? []).map { t in
            n += 1
            return ReleaseTrack(id: t["id"] as? String ?? "\(n)", number: n, title: t["title"] as? String ?? "", lengthMs: t["length"] as? Int ?? 0)
        } }
    }
}
