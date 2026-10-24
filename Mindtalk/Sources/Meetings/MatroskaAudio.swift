import Foundation

/// The sound out of a WebM or Matroska file (.webm, .mkv, .mka), which macOS can't open
/// although it decodes what's inside: Opus and Vorbis are put in an Ogg file, AAC in an
/// ADTS file, FLAC and MP3 in their own, as they are, nothing decoded or changed. Then it imports like any file.
/// Recordings from Chrome, Meet, Loom and Discord are WebM with Opus.
enum MatroskaAudio {
    enum Failure: Error { case notMatroska, noAudio, unsupported(String) }

    static let extensions: Set<String> = ["webm", "mkv", "mka"]

    /// The sound as a file macOS reads, written next to `folder`; nil when the file
    /// isn't WebM or Matroska. Throws when it is but its sound can't be taken out.
    static func remux(_ url: URL, into folder: URL) throws -> URL? {
        guard extensions.contains(url.pathExtension.lowercased()) else { return nil }
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        var parser = Parser(data: data)
        let (track, packets) = try parser.audio()
        switch track.codec {
        case "A_OPUS":
            let out = folder.appendingPathComponent("remux-\(UUID().uuidString).opus")
            try OggWriter.write(to: out, headers: [track.privateData, opusTags], packets: packets,
                                rate: 48_000, preSkip: opusPreSkip(track.privateData))
            return out
        case "A_VORBIS":
            let headers = try xiphHeaders(track.privateData)
            let out = folder.appendingPathComponent("remux-\(UUID().uuidString).ogg")
            try OggWriter.write(to: out, headers: headers, packets: packets, rate: track.rate, preSkip: 0)
            return out
        case "A_FLAC":
            // CodecPrivate is the stream's "fLaC" and its metadata; the frames follow as in a .flac.
            let out = folder.appendingPathComponent("remux-\(UUID().uuidString).flac")
            try writeRaw(to: out, head: track.privateData, packets: packets)
            return out
        case "A_MPEG/L3", "A_MPEG/L2":
            let out = folder.appendingPathComponent("remux-\(UUID().uuidString).mp3")
            try writeRaw(to: out, head: Data(), packets: packets)
            return out
        case let codec where codec.hasPrefix("A_AAC"):
            let out = folder.appendingPathComponent("remux-\(UUID().uuidString).aac")
            try writeADTS(to: out, config: track.privateData, packets: packets)
            return out
        default:
            throw Failure.unsupported(track.codec)
        }
    }

    // MARK: Reading the file

    struct Track {
        var number: UInt64 = 0
        var type: UInt64 = 0
        var codec = ""
        var privateData = Data()
        var rate: Double = 48_000
    }

    /// One frame of sound and when it starts, in seconds.
    struct Packet {
        let data: Data
        let time: Double
    }

    /// Walks the file once, front to back. The containers it needs (Segment, Tracks,
    /// Cluster…) are stepped into rather than over, so the "unknown size" a browser
    /// writes while it records (it can't know the length yet) is no trouble.
    struct Parser {
        let data: Data
        private var at: Int

        init(data: Data) {
            self.data = data
            at = data.startIndex
        }

        private static let containers: Set<UInt32> = [
            0x1853_8067,    // Segment
            0x1654_AE6B,    // Tracks
            0xAE,           // TrackEntry
            0xE1,           // Audio
            0x1F43_B675,    // Cluster
            0xA0,           // BlockGroup
        ]

        mutating func audio() throws -> (Track, [Packet]) {
            guard read(id: true) == 0x1A45_DFA3 else { throw Failure.notMatroska }     // EBML header
            guard let size = read(id: false) else { throw Failure.notMatroska }
            at += Int(size)
            var tracks: [Track] = []
            var scale = 1_000_000.0          // ns per timestamp tick
            var clusterTime: Int64 = 0
            var chosen: Track?
            var packets: [Packet] = []
            while at < data.endIndex {
                guard let id = read(id: true), let size = read(id: false) else { break }
                let unknown = size == Self.unknownSize
                if Self.containers.contains(UInt32(truncatingIfNeeded: id)) {
                    if id == 0xAE { tracks.append(Track()) }
                    continue                                  // into it, whatever its size
                }
                // Cut off at the end (a recording that stopped mid-write): what came before is kept.
                guard !unknown, size < UInt64(Int.max), at + Int(size) <= data.endIndex else { break }
                let body = data[at..<(at + Int(size))]
                at += Int(size)
                switch id {
                case 0x2A_D7B1: scale = Double(uint(body))
                case 0xD7: if !tracks.isEmpty { tracks[tracks.count - 1].number = uint(body) }
                case 0x83: if !tracks.isEmpty { tracks[tracks.count - 1].type = uint(body) }
                case 0x86: if !tracks.isEmpty { tracks[tracks.count - 1].codec = String(decoding: body, as: UTF8.self) }
                case 0x63A2: if !tracks.isEmpty { tracks[tracks.count - 1].privateData = Data(body) }
                case 0xB5: if !tracks.isEmpty { tracks[tracks.count - 1].rate = float(body) }
                case 0xE7: clusterTime = Int64(bitPattern: uint(body))
                case 0xA3, 0xA1:             // SimpleBlock, Block
                    if chosen == nil {
                        // The first sound track with a codec this can carry, as the import takes one.
                        chosen = tracks.first { $0.type == 2 && Self.carried($0.codec) }
                        if chosen == nil, tracks.contains(where: { $0.type == 2 }) {
                            throw Failure.unsupported(tracks.first { $0.type == 2 }!.codec)
                        }
                    }
                    guard let track = chosen else { continue }
                    try block(body, track: track, clusterTime: clusterTime, scale: scale, into: &packets)
                default:
                    break
                }
            }
            if chosen == nil { chosen = tracks.first { $0.type == 2 && Self.carried($0.codec) } }
            guard let track = chosen, !packets.isEmpty else {
                if let other = tracks.first(where: { $0.type == 2 }), !Self.carried(other.codec) { throw Failure.unsupported(other.codec) }
                throw Failure.noAudio
            }
            return (track, packets)
        }

        static func carried(_ codec: String) -> Bool {
            ["A_OPUS", "A_VORBIS", "A_FLAC", "A_MPEG/L3", "A_MPEG/L2"].contains(codec) || codec.hasPrefix("A_AAC")
        }

        static let unknownSize = UInt64.max

        /// A block's frames, laced or not, for the chosen track.
        private func block(_ body: Data, track: Track, clusterTime: Int64, scale: Double, into packets: inout [Packet]) throws {
            var i = body.startIndex
            guard let number = Self.vint(body, &i, keepMarker: false), number == track.number, i + 3 <= body.endIndex else { return }
            let relative = Int16(bitPattern: UInt16(body[i]) << 8 | UInt16(body[i + 1]))
            let flags = body[i + 2]
            i += 3
            let time = Double(clusterTime + Int64(relative)) * scale / 1_000_000_000
            var sizes: [Int] = []
            switch (flags >> 1) & 0x03 {
            case 0:
                sizes = [body.endIndex - i]
            case 1:                          // Xiph
                guard i < body.endIndex else { return }
                let count = Int(body[i]) + 1
                i += 1
                for _ in 0..<(count - 1) {
                    var n = 0
                    while i < body.endIndex { let b = Int(body[i]); i += 1; n += b; if b < 255 { break } }
                    sizes.append(n)
                }
                sizes.append(body.endIndex - i - sizes.reduce(0, +))
            case 2:                          // fixed
                guard i < body.endIndex else { return }
                let count = Int(body[i]) + 1
                i += 1
                let each = (body.endIndex - i) / count
                sizes = Array(repeating: each, count: count)
            default:                         // EBML
                guard i < body.endIndex else { return }
                let count = Int(body[i]) + 1
                i += 1
                guard let first = Self.vint(body, &i, keepMarker: false) else { return }
                var last = Int(first)
                sizes.append(last)
                for _ in 1..<max(1, count - 1) {
                    guard let raw = Self.signedVint(body, &i) else { return }
                    last += raw
                    sizes.append(last)
                }
                sizes.append(body.endIndex - i - sizes.reduce(0, +))
            }
            for size in sizes {
                guard size > 0, i + size <= body.endIndex else { return }
                packets.append(Packet(data: Data(body[i..<(i + size)]), time: time))
                i += size
            }
        }

        /// An element id (marker kept) or size (marker taken off) at the cursor.
        private mutating func read(id: Bool) -> UInt64? {
            var i = at
            guard let v = Self.vint(data, &i, keepMarker: id) else { return nil }
            at = i
            return v
        }

        static func vint(_ d: Data, _ i: inout Int, keepMarker: Bool) -> UInt64? {
            guard i < d.endIndex else { return nil }
            let first = d[i]
            guard first != 0 else { return nil }
            let length = first.leadingZeroBitCount + 1
            guard i + length <= d.endIndex else { return nil }
            var value = UInt64(keepMarker ? first : first & (0xFF >> length))
            var allOnes = value == UInt64(0xFF >> length)
            for k in 1..<length {
                value = value << 8 | UInt64(d[i + k])
                allOnes = allOnes && d[i + k] == 0xFF
            }
            i += length
            if !keepMarker, allOnes { return unknownSize }
            return value
        }

        /// A signed EBML lace size: the number less half its range.
        static func signedVint(_ d: Data, _ i: inout Int) -> Int? {
            guard i < d.endIndex else { return nil }
            let length = d[i].leadingZeroBitCount + 1
            guard let raw = vint(d, &i, keepMarker: false), raw != unknownSize else { return nil }
            return Int(raw) - (1 << (7 * length - 1) - 1)
        }

        private func uint(_ d: Data) -> UInt64 { d.reduce(0) { $0 << 8 | UInt64($1) } }

        private func float(_ d: Data) -> Double {
            let bits = uint(d)
            return d.count == 4 ? Double(Float(bitPattern: UInt32(bits))) : Double(bitPattern: bits)
        }
    }

    // MARK: Opus and Vorbis, in Ogg

    /// The OpusHead's pre-skip: the samples the decoder throws away at the start.
    private static func opusPreSkip(_ head: Data) -> Int {
        let b = Array(head)
        guard b.count >= 12 else { return 0 }
        return Int(b[10]) | Int(b[11]) << 8
    }

    /// An Ogg Opus file needs a tags packet after the head; Matroska keeps none.
    private static var opusTags: Data {
        var d = Data("OpusTags".utf8)
        let vendor = Data("Mindtalk".utf8)
        d.append(contentsOf: le32(vendor.count)); d.append(vendor)
        d.append(contentsOf: le32(0))
        return d
    }

    /// Vorbis's three headers, Xiph-laced in CodecPrivate.
    private static func xiphHeaders(_ d: Data) throws -> [Data] {
        let b = Array(d)
        guard let count = b.first.map({ Int($0) + 1 }), count == 3 else { throw Failure.noAudio }
        var i = 1
        var sizes: [Int] = []
        for _ in 0..<(count - 1) {
            var n = 0
            while i < b.count { let v = Int(b[i]); i += 1; n += v; if v < 255 { break } }
            sizes.append(n)
        }
        var out: [Data] = []
        for size in sizes {
            guard i + size <= b.count else { throw Failure.noAudio }
            out.append(Data(b[i..<(i + size)])); i += size
        }
        out.append(Data(b[i...]))
        return out
    }

    static func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }

    enum OggWriter {
        /// The headers on pages of their own, then each frame on its page, the page's
        /// position the sample where the next frame begins.
        static func write(to url: URL, headers: [Data], packets: [Packet], rate: Double, preSkip: Int) throws {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            let serial = UInt32.random(in: 1...UInt32.max)
            var sequence: UInt32 = 0
            func write(_ packet: Data, granule: Int64, first: Bool, last: Bool) throws {
                try file.write(contentsOf: try page(packet, granule: granule, serial: serial, sequence: sequence, first: first, last: last))
                sequence += 1
            }
            for (k, header) in headers.enumerated() { try write(header, granule: 0, first: k == 0, last: false) }
            let start = packets.first?.time ?? 0
            for (k, packet) in packets.enumerated() {
                let next = k + 1 < packets.count ? packets[k + 1].time
                    : packet.time + (k > 0 ? packet.time - packets[k - 1].time : 0.02)
                let granule = Int64(preSkip) + Int64(((next - start) * rate).rounded())
                try write(packet.data, granule: granule, first: false, last: k == packets.count - 1)
            }
        }

        /// One packet on one page. A sound frame is never near the 64 KB a page holds.
        static func page(_ packet: Data, granule: Int64, serial: UInt32, sequence: UInt32, first: Bool, last: Bool) throws -> Data {
            var segments: [UInt8] = []
            var left = packet.count
            while left >= 255 { segments.append(255); left -= 255 }
            segments.append(UInt8(left))
            guard segments.count <= 255 else { throw Failure.unsupported("frame too large") }
            return rawPage(packet, segments: segments, granule: granule, serial: serial, sequence: sequence,
                           flags: (first ? 2 : 0) | (last ? 4 : 0))
        }

        private static func rawPage(_ body: Data, segments: [UInt8], granule: Int64, serial: UInt32, sequence: UInt32, flags: UInt8) -> Data {
            var p = Data("OggS".utf8)
            p.append(0)                                        // version
            p.append(flags)
            p.append(contentsOf: (0..<8).map { UInt8((UInt64(bitPattern: granule) >> (8 * $0)) & 0xFF) })
            p.append(contentsOf: (0..<4).map { UInt8((serial >> (8 * $0)) & 0xFF) })
            p.append(contentsOf: (0..<4).map { UInt8((sequence >> (8 * $0)) & 0xFF) })
            p.append(contentsOf: [0, 0, 0, 0])                 // checksum, filled in below
            p.append(UInt8(segments.count))
            p.append(contentsOf: segments)
            p.append(body)
            let crc = checksum(p)
            for k in 0..<4 { p[p.startIndex + 22 + k] = UInt8((crc >> (8 * UInt32(k))) & 0xFF) }
            return p
        }

        private static let table: [UInt32] = (0..<256).map { i in
            var r = UInt32(i) << 24
            for _ in 0..<8 { r = r & 0x8000_0000 != 0 ? (r << 1) ^ 0x04C1_1DB7 : r << 1 }
            return r
        }

        static func checksum(_ d: Data) -> UInt32 {
            var crc: UInt32 = 0
            for b in d { crc = (crc << 8) ^ table[Int(((crc >> 24) ^ UInt32(b)) & 0xFF)] }
            return crc
        }
    }

    // MARK: FLAC and MP3, as they are

    private static func writeRaw(to url: URL, head: Data, packets: [Packet]) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.write(contentsOf: head)
        for packet in packets { try file.write(contentsOf: packet.data) }
    }

    // MARK: AAC, as ADTS

    /// Each frame with the 7-byte header an .aac file has, from the AudioSpecificConfig.
    private static func writeADTS(to url: URL, config: Data, packets: [Packet]) throws {
        let c = Array(config)
        guard c.count >= 2 else { throw Failure.unsupported("A_AAC") }
        let object = Int(c[0] >> 3)
        let frequency = Int((c[0] & 0x07) << 1 | c[1] >> 7)
        let channels = Int((c[1] >> 3) & 0x0F)
        guard (1...4).contains(object), frequency < 13, channels > 0 else { throw Failure.unsupported("A_AAC") }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        for packet in packets {
            let length = packet.data.count + 7
            var h = [UInt8](repeating: 0, count: 7)
            h[0] = 0xFF
            h[1] = 0xF1                                        // MPEG-4, no CRC
            h[2] = UInt8((object - 1) << 6 | frequency << 2 | channels >> 2)
            h[3] = UInt8((channels & 3) << 6 | length >> 11)
            h[4] = UInt8((length >> 3) & 0xFF)
            h[5] = UInt8((length & 7) << 5 | 0x1F)
            h[6] = 0xFC
            try file.write(contentsOf: Data(h) + packet.data)
        }
    }
}
