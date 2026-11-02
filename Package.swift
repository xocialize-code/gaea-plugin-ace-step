// swift-tools-version: 6.2
import PackageDescription

// gaea-plugin-ace-step: ACE Studio and StepFun's ACE-Step 1.5 (MIT weights) as a Gaea plugin on MES Audio
// 0.1's audio.compose. One worker executable built on GaeaPluginKit over mlx-ace-step-swift, packaged as a
// signed .gaeaplugin by scripts/build-plugin.sh.
//
// ace-step-inproc is not part of the plugin: it runs the same package in-process through MLXServeEngine, with the same
// dependency resolution and requests, as the reference a run through Gaea is compared against.
//
// GAEA_PLUGIN_KIT_PATH points the kit at a local checkout while you work on both.
let kitPath = Context.environment["GAEA_PLUGIN_KIT_PATH"]

let package = Package(
    name: "gaea-plugin-ace-step",
    platforms: [.macOS(.v26)], // mlx-engine-swift's MLXToolKit requires macOS 26
    dependencies: [
        kitPath.map { .package(path: $0) }
            ?? .package(url: "https://github.com/xocialize-code/gaea-plugin-kit.git", from: "0.8.0"),
        .package(url: "https://github.com/xocialize/mlx-ace-step-swift.git", exact: "0.3.0"),
        .package(url: "https://github.com/xocialize/mlx-engine-swift.git", from: "0.73.1"),
    ],
    targets: [
        .target(
            name: "ACEStepPlugin",
            dependencies: [
                .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"),
                .product(name: "MLXACEStep", package: "mlx-ace-step-swift"),
                .product(name: "MLXToolKit", package: "mlx-engine-swift"),
            ]
        ),
        .executableTarget(
            name: "gaea-ace-step-worker",
            dependencies: [
                "ACEStepPlugin",
                .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"),
            ]
        ),
        .executableTarget(
            name: "ace-step-inproc",
            dependencies: [
                "ACEStepPlugin",
                .product(name: "GaeaProtocol", package: "gaea-plugin-kit"),
                .product(name: "MLXACEStep", package: "mlx-ace-step-swift"),
                .product(name: "MLXToolKit", package: "mlx-engine-swift"),
                .product(name: "MLXServeCore", package: "mlx-engine-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "ACEStepPluginTests", dependencies: ["ACEStepPlugin", .product(name: "MLXACEStep", package: "mlx-ace-step-swift")]),
    ]
)
