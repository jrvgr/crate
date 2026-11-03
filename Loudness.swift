import Foundation
import AVFoundation

// Sound Check: loudness per song (EBU R128 / ITU-R BS.1770 integrated loudness: K-weighting,
// 400 ms blocks, absolute and relative gates), turned into the iPod's Sound Check value (mhit
// 0x4C) so songs play at about the same volume when Sound Check is on in the iPod's settings.

enum Loudness {
    /// Integrated loudness in LUFS, or nil when the file can't be decoded.
    static func measure(_ path: String) -> Double? {
        guard let f = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
        let fmt = f.processingFormat, rate = fmt.sampleRate, channels = Int(fmt.channelCount)
        guard rate > 0, channels > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 65536) else { return nil }
        var filters = (0..<channels).map { _ in KWeighting(rate: rate) }
        let block = Int(rate * 0.4), hop = block / 4
        var energy: [Double] = []          // mean square per 100 ms hop, summed over channels
        var acc = 0.0, inHop = 0
        while f.framePosition < f.length {
            do { try f.read(into: buf) } catch { break }
            let n = Int(buf.frameLength); if n == 0 { break }
            guard let data = buf.floatChannelData else { return nil }
            for i in 0..<n {
                var s = 0.0
                for c in 0..<min(channels, 2) { let y = filters[c].process(Double(data[c][i])); s += y * y }
                acc += s; inHop += 1
                if inHop == hop { energy.append(acc / Double(hop)); acc = 0; inHop = 0 }
            }
        }
        guard energy.count >= 4 else { return nil }
        let blocks = (0...(energy.count - 4)).map { i in energy[i..<i + 4].reduce(0, +) / 4 }
        func lufs(_ ms: Double) -> Double { -0.691 + 10 * log10(max(ms, 1e-12)) }
        let gated = blocks.filter { lufs($0) > -70 }
        guard !gated.isEmpty else { return nil }
        let rel = lufs(gated.reduce(0, +) / Double(gated.count)) - 10
        let final = gated.filter { lufs($0) > rel }
        return lufs(final.reduce(0, +) / Double(max(final.count, 1)))
    }

    /// The iPod's Sound Check number for a loudness (reference -16 LUFS, like Apple's).
    static func soundCheck(_ lufs: Double) -> Int {
        let gain = max(-15, min(15, -16 - lufs))
        return Int((1000 * pow(10, -gain / 10)).rounded())
    }

    // cache: path -> (file size, LUFS), so nothing is measured twice
    static var url: URL { PodCache.dir.appendingPathComponent("loudness.json") }
    static func load() -> [String: [Double]] { (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: [Double]].self, from: $0) } ?? [:] }
    static func save(_ c: [String: [Double]]) { try? JSONEncoder().encode(c).write(to: url) }
}

/// The two K-weighting biquads (high shelf +4 dB at 1.5 kHz, high pass at 38 Hz), for any rate.
struct KWeighting {
    var a: [Biquad]
    init(rate: Double) {
        a = [Biquad.highShelf(rate: rate, f: 1681.97, gain: 3.99984, q: 0.70717),
             Biquad.highPass(rate: rate, f: 38.1355, q: 0.50033)]
    }
    mutating func process(_ x: Double) -> Double { a[1].process(a[0].process(x)) }
}

struct Biquad {
    var b0, b1, b2, a1, a2: Double
    var z1 = 0.0, z2 = 0.0
    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
    static func highShelf(rate: Double, f: Double, gain: Double, q: Double) -> Biquad {
        let A = pow(10, gain / 40), w = 2 * Double.pi * f / rate, alpha = sin(w) / (2 * q), c = cos(w), s = 2 * sqrt(A) * alpha
        let a0 = (A + 1) - (A - 1) * c + s
        return Biquad(b0: A * ((A + 1) + (A - 1) * c + s) / a0, b1: -2 * A * ((A - 1) + (A + 1) * c) / a0,
                      b2: A * ((A + 1) + (A - 1) * c - s) / a0, a1: 2 * ((A - 1) - (A + 1) * c) / a0, a2: ((A + 1) - (A - 1) * c - s) / a0)
    }
    static func highPass(rate: Double, f: Double, q: Double) -> Biquad {
        let w = 2 * Double.pi * f / rate, alpha = sin(w) / (2 * q), c = cos(w), a0 = 1 + alpha
        return Biquad(b0: (1 + c) / 2 / a0, b1: -(1 + c) / a0, b2: (1 + c) / 2 / a0, a1: -2 * c / a0, a2: (1 - alpha) / a0)
    }
}

extension ITunesDB {
    /// Sets Sound Check on a track record (0 = not measured).
    mutating func setSoundCheck(_ i: Int, _ value: Int) {
        guard var b = tracks[i].raw.map({ [UInt8]($0) }), b.count >= 0x50 else { return }
        for k in 0..<4 { b[0x4C + k] = UInt8(truncatingIfNeeded: value >> (k * 8)) }
        tracks[i].raw = Data(b)
    }
    func soundCheck(_ i: Int) -> Int {
        guard let r = tracks[i].raw, r.count >= 0x50 else { return 0 }
        let o = r.startIndex + 0x4C
        return Int(r[o]) | Int(r[o + 1]) << 8 | Int(r[o + 2]) << 16 | Int(r[o + 3]) << 24
    }
}
