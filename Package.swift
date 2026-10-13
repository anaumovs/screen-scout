// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScreenScout",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ScreenScout", targets: ["ScreenScout"]),
               .executable(name: "ScoutVerify", targets: ["ScoutVerify"]),
               .executable(name: "ScoutCoreChecks", targets: ["ScoutCoreChecks"]),
               .executable(name: "ClickerChecks", targets: ["ClickerChecks"]),
               .executable(name: "ClickTestPad", targets: ["ClickTestPad"])],
    targets: [
        .target(name: "ScoutCore"),
        .target(name: "ScoutVision", dependencies: ["ScoutCore"]),
        .target(name: "ScoutClicker"),
        .executableTarget(name: "ScreenScout", dependencies: ["ScoutClicker"], exclude: ["WindowCapture.swift"]),
        .executableTarget(name: "ClickTestPad", dependencies: []),
        .executableTarget(name: "ClickerChecks", dependencies: ["ScoutClicker"], path: "Tests/ClickerChecks"),
        .executableTarget(name: "ScoutVerify", dependencies: ["ScoutCore", "ScoutVision"]),
        .executableTarget(name: "ScoutCoreChecks", dependencies: ["ScoutCore"], path: "Tests/ScoutCoreTests")
    ]
)
