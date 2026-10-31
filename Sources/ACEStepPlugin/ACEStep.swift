import Foundation
import GaeaPluginKit
import GaeaProtocol
import MLXACEStep
import MLXToolKit

// gaea-plugin-ace-step: ACE Studio and StepFun's ACE-Step 1.5 (MIT; the MLX port, mlx-ace-step-swift, is MIT) on MES Audio
// 0.1's audio.compose (media-engine-spec v0.7.0, Gaea AB-T-0399). One model, the song generator: a caption and lyrics give a
// 48 kHz stereo song of 10 to 600 s; no lyrics give an instrumental (Audio §3.5):
//
// - Lyrics: MES section tags ([verse], [pre-chorus], [chorus - anthemic, full band], …) as ACE-Step writes them ([Verse],
//   [Pre-Chorus], [Chorus - anthemic, full band]). Lyrics with no tag are one [Verse].
// - A reference recording lends its timbre; a source is reworked by an edit: cover (strength 0–1), repaint (start_s–end_s
//   made again) or extend (before_s and after_s added). An edit's song is as long as its source (plus the extension).
// - Anchors (bpm, key, time_signature) pin the planner; the ones it settled on come back as effective.anchors.
// - timestamps: true returns the sung lines' times ({lines: [{text, start_s, end_s}]}).
// - The planner samples, seeded by the job's seed, so the same request gives the same WAV, here and in ace-step-inproc.
//
// Three lanes, the planner's quant: int8 (the default), bf16 and int4, with the package's measured footprints. The DiT is
// distilled to eight fixed steps, so there is one quality tier.

public let modelID = "ace-step-1.5"
public let sampleRate = 48000, channels = 2
public let minSeconds = 10.0, maxSeconds = 600.0
public let languages = ACEStepPackage.vocalLanguages

/// The MES section tags (§3.5.1) and how ACE-Step writes them.
public let sections: [(mes: String, ace: String)] = [
    ("intro", "Intro"), ("verse", "Verse"), ("pre-chorus", "Pre-Chorus"), ("chorus", "Chorus"), ("bridge", "Bridge"),
    ("solo", "Solo"), ("instrumental", "Instrumental"), ("outro", "Outro"),
]

// MARK: - Lyrics

/// MES lyrics as ACE-Step reads them: each section tag in its spelling, a direction after a dash kept. A bracketed line that
/// isn't a section tag is dropped with `section_unsupported`; lyrics with no tag become one [Verse].
public func aceLyrics(_ text: String) -> (lyrics: String, warnings: [Warning]) {
    var out: [String] = []
    var dropped: [String] = []
    var tagged = false
    for raw in text.components(separatedBy: .newlines) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("["), line.hasSuffix("]"), !line.hasPrefix("\\[") else { out.append(raw); continue }
        let inner = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        let parts = inner.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        // "pre-chorus" has a dash of its own: the direction is what follows " - ".
        let name: String, direction: String?
        if let range = inner.range(of: " - ") {
            name = String(inner[..<range.lowerBound]); direction = String(inner[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        } else {
            name = parts.count == 2 && parts[0].lowercased() != "pre" ? String(parts[0]) : inner; direction = nil
        }
        guard let tag = sections.first(where: { $0.mes == name.trimmingCharacters(in: .whitespaces).lowercased() })?.ace else {
            if !dropped.contains(inner) { dropped.append(inner) }
            continue
        }
        tagged = true
        out.append(direction.map { "[\(tag) - \($0)]" } ?? "[\(tag)]")
    }
    var lyrics = out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    if !tagged, !lyrics.isEmpty { lyrics = "[Verse]\n" + lyrics }
    let warnings = dropped.map {
        Warning(code: "section_unsupported", message: "[\($0)] isn't a section ACE-Step knows; it was dropped.", param: "lyrics")
    }
    return (lyrics, warnings)
}

// MARK: - Planning

/// What a compose job asks of the package, validated.
public struct SongPlan: Sendable {
    public var caption: String
    public var lyrics: String
    public var language: String?
    public var seconds: Double?
    public var anchors: MusicAnchors?
    public var edit: JSONValue?
    public var timestamps: Bool
    public var seed: UInt64
    public var warnings: [Warning]
}

func refuse(_ message: String, _ param: String) -> GPPError {
    GPPError(.invalidRequest, message, detail: ["param": .string(param)])
}

public func songPlan(caption: String?, lyrics: String?, language: String?, seconds: Double?, anchors: JSONValue?, edit: JSONValue?,
                     timestamps: Bool, seed: UInt64) throws -> SongPlan {
    guard let caption = caption?.trimmingCharacters(in: .whitespacesAndNewlines), !caption.isEmpty else {
        throw refuse("audio.compose needs a caption: the style of the song.", "caption")
    }
    let (words, warnings) = aceLyrics(lyrics ?? "")
    if let seconds, edit == nil {
        guard seconds >= minSeconds, seconds <= maxSeconds else {
            throw refuse("ACE-Step composes songs of \(Int(minSeconds)) to \(Int(maxSeconds)) s.", "duration_s")
        }
    }
    var lang: String?
    if let tag = language {
        let primary = tag.lowercased().split(separator: "-").first.map(String.init) ?? ""
        guard languages.contains(primary) else { throw refuse("ACE-Step can't sing in \(tag).", "language") }
        lang = primary
    }
    var pinned: MusicAnchors?
    if let a = anchors?.objectValue {
        pinned = MusicAnchors(bpm: a["bpm"]?.doubleValue, key: a["key"]?.stringValue, timeSignature: a["time_signature"]?.stringValue)
    }
    return SongPlan(caption: caption, lyrics: words, language: lang, seconds: seconds, anchors: pinned, edit: edit,
                    timestamps: timestamps, seed: seed, warnings: warnings)
}

/// The engine request for a plan, with the source and reference read from the job's files.
public func request(_ plan: SongPlan, reference: Data?, source: Data?) throws -> MusicRequest {
    var musicEdit: MusicEdit?
    if let edit = plan.edit?.objectValue, let kind = edit["kind"]?.stringValue {
        guard let source else { throw refuse("An edit reworks a source; send the source input.", "source") }
        let audio = Audio(format: .wav, data: source, sampleRate: nil, channels: nil)
        switch kind {
        case "cover":
            musicEdit = MusicEdit(source: audio, operation: .cover(strength: edit["strength"]?.doubleValue ?? 0.5))
        case "repaint":
            guard let start = edit["start_s"]?.doubleValue, let end = edit["end_s"]?.doubleValue else {
                throw refuse("A repaint needs start_s and end_s.", "edit")
            }
            musicEdit = MusicEdit(source: audio, operation: .repaint(start: start, end: end))
        case "extend":
            musicEdit = MusicEdit(source: audio, operation: .extend(leading: edit["before_s"]?.doubleValue ?? 0,
                                                                    trailing: edit["after_s"]?.doubleValue ?? 0))
        default:
            throw refuse("ACE-Step doesn't make \(kind) edits.", "edit")
        }
    }
    return MusicRequest(caption: plan.caption, lyrics: plan.lyrics, durationSeconds: musicEdit == nil ? plan.seconds : nil,
                        seed: plan.seed, referenceAudio: reference.map { Audio(format: .wav, data: $0, sampleRate: nil, channels: nil) },
                        edit: musicEdit, anchors: plan.anchors, vocalLanguage: plan.language)
}

/// A 16-bit WAV's length in seconds.
public func seconds(_ wav: Data) -> Double? {
    guard wav.count >= 44, wav.prefix(4) == Data("RIFF".utf8) else { return nil }
    func u16(_ at: Int) -> Int { Int(wav[wav.startIndex + at]) | Int(wav[wav.startIndex + at + 1]) << 8 }
    func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
    let ch = u16(22), rate = u32(24), bits = u16(34)
    guard ch > 0, rate > 0, bits > 0 else { return nil }
    return Double(wav.count - 44) / Double(ch * bits / 8) / Double(rate)
}

/// How long the song must be, in frames, when MES says (Audio §3.5): an edit's is its source's, plus an extend's before_s and
/// after_s; a song asked for by duration_s is that long. Nil when the planner decides.
public func expectedFrames(_ plan: SongPlan, source: Data?) -> Int? {
    if let edit = plan.edit?.objectValue, let kind = edit["kind"]?.stringValue {
        guard let source, let d = seconds(source) else { return nil }
        let extra = kind == "extend" ? (edit["before_s"]?.doubleValue ?? 0) + (edit["after_s"]?.doubleValue ?? 0) : 0
        return Int(((d + extra) * Double(sampleRate)).rounded())
    }
    return plan.seconds.map { Int(($0 * Double(sampleRate)).rounded()) }
}

/// The package's 16-bit stereo WAV cut to `frames`. Its edits decode the latent rounded up to whole windows (an extend of
/// 1 + 2 + 1.5 s comes back 5.12 s), with the requested song at the start: the rest is cut off. A shorter song is kept.
public func cut(_ wav: Data, frames: Int) -> Data {
    let bytes = frames * channels * 2
    guard wav.count >= 44, wav.count - 44 > bytes else { return wav }
    var out = Data(wav.prefix(44))
    func put32(_ v: UInt32, at: Int) { withUnsafeBytes(of: v.littleEndian) { out.replaceSubrange(at..<at + 4, with: $0) } }
    put32(UInt32(36 + bytes), at: 4)
    put32(UInt32(bytes), at: 40)
    out.append(wav.subdata(in: (wav.startIndex + 44)..<(wav.startIndex + 44 + bytes)))
    return out
}

/// What a song's response says, as MES outputs and effective values.
public func effective(_ plan: SongPlan, response: MusicResponse, song: Data) -> [String: JSONValue] {
    var e: [String: JSONValue] = ["seed": .int(Int64(plan.seed))]
    if let s = seconds(song) { e["duration_s"] = .double((s * 1000).rounded() / 1000) }
    if let a = response.anchors, !a.isEmpty {
        var anchors: [String: JSONValue] = [:]
        if let bpm = a.bpm { anchors["bpm"] = .double(bpm) }
        if let key = a.key { anchors["key"] = .string(key) }
        if let ts = a.timeSignature { anchors["time_signature"] = .string(ts) }
        e["anchors"] = .object(anchors)
    }
    if let language = plan.language { e["language"] = .string(language) }
    return e
}

public func timestampsValue(_ lines: [MusicLyricTimestamp]) -> JSONValue {
    ["lines": .array(lines.map { line in
        var o: [String: JSONValue] = ["text": .string(line.text), "start_s": .double(line.start)]
        if let end = line.end { o["end_s"] = .double(end) }
        return .object(o)
    })]
}

public func seed(_ job: Job) -> UInt64 { job.seed.map { $0 & 0xFFFF_FFFF } ?? UInt64.random(in: 0..<(1 << 32)) }

let composeOperation = EngineOperation("audio.compose") { job, session in
    let plan = try songPlan(caption: try job.text("caption"), lyrics: try job.text("lyrics"), language: job.param("language")?.stringValue,
                            seconds: job.param("duration_s")?.doubleValue, anchors: job.param("anchors"), edit: job.param("edit"),
                            timestamps: job.param("timestamps")?.boolValue ?? false, seed: seed(job))
    let reference = try job.input("reference").map { try Data(contentsOf: $0) }
    let source = try job.input("source").map { try Data(contentsOf: $0) }
    guard let response = try await session.run(request(plan, reference: reference, source: source)) as? MusicResponse else {
        throw GPPError(.modelError, "ACE-Step returned no song.")
    }
    let song = expectedFrames(plan, source: source).map { cut(response.audio.data, frames: $0) } ?? response.audio.data
    let url = session.outputDir.appending(path: "song-0.wav")
    try song.write(to: url)
    var outputs: [Output] = [.file("song", url, mediaType: "audio/wav")]
    if plan.timestamps, let lines = response.timestamps { outputs.append(.value("timestamps", timestampsValue(lines))) }
    var warnings = plan.warnings
    if response.truncated {
        warnings.append(Warning(code: "song_truncated", message: "ACE-Step's plan ended before the lyrics did.", param: "lyrics"))
    }
    return RunResult(outputs: outputs, effective: effective(plan, response: response, song: song), warnings: warnings)
}

// MARK: - The plugin

public func lanes() -> [LaneDefinition] {
    [LaneDefinition(id: "int8", default: true, configuration: ACEStepConfiguration(quant: .int8)),
     LaneDefinition(id: "bf16", configuration: ACEStepConfiguration(quant: .bf16)),
     LaneDefinition(id: "int4", configuration: ACEStepConfiguration(quant: .int4))]
}

let composeModel = ModelDefinition.engine(ACEStepPackage.self, id: modelID, title: "ACE-Step 1.5", lanes: lanes(),
                                          operations: [composeOperation])

let composeOffer = PluginManifest.Offer(
    operation: "audio.compose", profile: "audio",
    model: [
        "id": .string(modelID), "title": "ACE-Step 1.5",
        "license": ["spdx": "MIT", "commercial_use": true, "terms_url": "https://github.com/ace-step/ACE-Step-1.5/blob/main/LICENSE"],
        "memory_class": "large", "speed_class": "fast", "quality_tiers": ["standard"],
        "notes": "Songs from a caption (genre, mood, instruments, the voice) and lyrics in [verse] / [chorus] sections, 10 to 600 s at 48 kHz stereo; no lyrics make an instrumental. Write the caption yourself and set language: the planner may rephrase the caption and picks a language when none is given. A reference lends its timbre; cover, repaint and extend rework a source. Covers and supplied lyrics may need the original song's rights; this model's licence doesn't grant them.",
        "supports": [
            "languages": .array(languages.map { .string($0) }), "instrumental": true, "reference": true,
            "edits": ["cover", "repaint", "extend"], "anchors": ["bpm", "key", "time_signature"], "timestamps": true,
            "sections": .array(sections.map { .string($0.mes) }), "sample_rate": .int(Int64(sampleRate)), "channels": .int(Int64(channels)),
        ],
        "limits": ["min_duration_s": .double(minSeconds), "max_duration_s": .double(maxSeconds), "max_source_s": .double(maxSeconds)],
    ])

public let aceStepPlugin = GaeaPluginDefinition(
    id: "com.xocialize.gaea.ace-step", version: "0.1.0", minGaea: "0.9.2", team: "CFZS6RXUCP",
    repo: "https://github.com/xocialize-code/gaea-plugin-ace-step", title: "ACE-Step 1.5",
    summary: "ACE-Step 1.5: songs from a caption and lyrics, or instrumentals, 10 to 600 s at 48 kHz stereo (MES audio.compose), with a reference's timbre, cover, repaint and extend edits, pinned anchors and line timestamps.",
    license: "MIT", executable: "gaea-ace-step-worker",
    models: [composeModel], offers: [composeOffer])
