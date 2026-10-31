import ACEStepPlugin
import Foundation
import GaeaProtocol
import MLXACEStep
import MLXServeCore
import MLXToolKit

// The in-process reference for the plugin: ACE-Step 1.5 loaded by MLXServeEngine in this process, with the lane
// configuration and the requests the worker builds (ACEStepPlugin). The song is written to --out, and one JSON line of
// timings, the effective values and the timestamps' line count is printed. Not part of the plugin bundle.
//
//   ace-step-inproc --caption <text> [--lyrics <text> | --lyrics-file <path>] [--language en] [--duration 30]
//                   [--anchors '<JSON>'] [--edit '<MES edit JSON>' --source <wav>] [--reference <wav>] [--seed 42]
//                   [--lane int8 | bf16 | int4] [--models-root <dir>] [--out <wav>]

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}
func seconds(since start: ContinuousClock.Instant) -> Double {
    let d = ContinuousClock.now - start
    return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}
func json(_ s: String?) throws -> JSONValue? { try s.map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) } }

let laneID = option("--lane") ?? "int8"
let modelsRoot = URL(fileURLWithPath: option("--models-root")
                     ?? NSHomeDirectory() + "/Library/Application Support/MLXEngine/Models", isDirectory: true)
guard let lane = lanes().first(where: { $0.id == laneID }) else { fatalError("no lane \(laneID)") }
let lyrics = try option("--lyrics-file").map { try String(contentsOfFile: $0, encoding: .utf8) } ?? option("--lyrics")
let plan = try songPlan(caption: option("--caption"), lyrics: lyrics, language: option("--language"),
                        seconds: option("--duration").flatMap(Double.init), anchors: try json(option("--anchors")),
                        edit: try json(option("--edit")), timestamps: true, seed: UInt64(option("--seed") ?? "") ?? 42)
let reference = try option("--reference").map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
let source = try option("--source").map { try Data(contentsOf: URL(fileURLWithPath: $0)) }

// The budget Gaea sends a worker on a large Mac (wiresWeights off).
let engine = MLXServeEngine(workerBudget: WorkerBudget(ceilingBytes: 64_000_000_000, wiresWeights: false))
await engine.useModelStore(ModelStore(root: modelsRoot))
let id = PackageID(modelID)
_ = try await engine.register(ACEStepPackage.registration, configuration: lane.configuration, id: id)
var clock = ContinuousClock.now
_ = try await engine.prepare(.music, package: id)
var result: [String: Any] = ["model": modelID, "lane": laneID, "prepare_s": seconds(since: clock)]
clock = ContinuousClock.now
guard let response = try await engine.run(try request(plan, reference: reference, source: source), package: id) as? MusicResponse else {
    fatalError("ACE-Step returned no song")
}
result["run_s"] = seconds(since: clock)
let song = expectedFrames(plan, source: source).map { cut(response.audio.data, frames: $0) } ?? response.audio.data
if let out = option("--out") { try song.write(to: URL(fileURLWithPath: out)) }
let e = effective(plan, response: response, song: song)
result["effective"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(JSONValue.object(e)))
result["frames"] = (song.count - 44) / 4
result["model_frames"] = (response.audio.data.count - 44) / 4
result["truncated"] = response.truncated
result["timestamp_lines"] = response.timestamps?.count ?? 0
var usage = rusage()
getrusage(RUSAGE_SELF, &usage)
result["max_rss_gb"] = Double(usage.ru_maxrss) / 1e9
print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
