import ACEStepPlugin
import Foundation
import GaeaProtocol
import MLXACEStep
import MLXToolKit
import Testing

@Suite struct PlanTests {
    @Test func sectionTagsAreWrittenAsACEStepWritesThem() {
        let (lyrics, warnings) = aceLyrics("[verse]\nLights on the water\n[pre-chorus]\nHold on\n[chorus - anthemic, full band]\nRun all night\n[S1]\n[OUTRO]")
        #expect(lyrics == "[Verse]\nLights on the water\n[Pre-Chorus]\nHold on\n[Chorus - anthemic, full band]\nRun all night\n[Outro]")
        #expect(warnings.map(\.code) == ["section_unsupported"])
        #expect(aceLyrics("Just one line\nand another").lyrics == "[Verse]\nJust one line\nand another")
        #expect(aceLyrics("").lyrics == "")
    }

    func plan(_ edit: JSONValue? = nil, seconds: Double? = 30, language: String? = "en") throws -> SongPlan {
        try songPlan(caption: "Synth-pop.", lyrics: "[verse]\nHi", language: language, seconds: seconds, anchors: nil, edit: edit,
                     timestamps: false, seed: 5)
    }

    @Test func languagesAndDurations() throws {
        #expect(try plan(language: "en-GB").language == "en")
        #expect(throws: GPPError.self) { try plan(language: "tlh") }
        #expect(throws: GPPError.self) { try plan(seconds: 9) }
        #expect(throws: GPPError.self) { try plan(seconds: 601) }
        #expect(throws: GPPError.self) { try songPlan(caption: " ", lyrics: nil, language: nil, seconds: nil, anchors: nil, edit: nil, timestamps: false, seed: 1) }
    }

    func wav(seconds: Double, rate: Int = 48000, channels: Int = 2) -> Data {
        let bytes = Int(seconds * Double(rate)) * channels * 2
        var d = Data("RIFF".utf8) + Data(count: 4) + Data("WAVEfmt ".utf8)
        func put(_ v: some FixedWidthInteger) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        put(UInt32(16)); put(UInt16(1)); put(UInt16(channels)); put(UInt32(rate)); put(UInt32(rate * channels * 2)); put(UInt16(channels * 2)); put(UInt16(16))
        d.append(contentsOf: Array("data".utf8)); put(UInt32(bytes))
        return d + Data(count: bytes)
    }

    @Test func anEditsSongIsItsSourcesLengthPlusTheExtension() throws {
        let source = wav(seconds: 2, rate: 24000, channels: 1)
        #expect(expectedFrames(try plan(["kind": "extend", "before_s": 1, "after_s": 1.5]), source: source) == 216_000)
        #expect(expectedFrames(try plan(["kind": "repaint", "start_s": 0.5, "end_s": 1.5]), source: source) == 96_000)
        #expect(expectedFrames(try plan(["kind": "cover"]), source: source) == 96_000)
        #expect(expectedFrames(try plan(seconds: 10), source: nil) == 480_000)
        #expect(expectedFrames(try plan(seconds: nil), source: nil) == nil)
    }

    @Test func theCutKeepsTheStartAndFixesTheHeader() throws {
        let song = wav(seconds: 5.12)
        let cut4 = cut(song, frames: 216_000)
        #expect(cut4.count == 44 + 216_000 * 4)
        #expect(seconds(cut4) == 4.5)
        #expect(cut(song, frames: 300_000) == song)
    }

    @Test func editsBecomeThePackagesRequests() throws {
        let source = wav(seconds: 2)
        let extend = try request(try plan(["kind": "extend", "after_s": 3]), reference: nil, source: source)
        #expect(extend.edit?.operation == .extend(leading: 0, trailing: 3) && extend.durationSeconds == nil)
        let cover = try request(try plan(["kind": "cover"]), reference: source, source: source)
        #expect(cover.edit?.operation == .cover(strength: 0.5) && cover.referenceAudio != nil)
        #expect(throws: GPPError.self) { try request(try plan(["kind": "cover"]), reference: nil, source: nil) }
        let song = try request(try plan(seconds: 30), reference: nil, source: nil)
        #expect(song.durationSeconds == 30 && song.vocalLanguage == "en" && song.seed == 5)
    }
}
