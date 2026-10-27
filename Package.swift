// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeetRec",
    platforms: [.macOS("14.5")],
    products: [
        .library(name: "MeetRecCore", targets: ["MeetRecCore"]),
        .executable(name: "meetrec", targets: ["meetrec"]),
        .executable(name: "MeetRecApp", targets: ["MeetRecApp"]),
    ],
    targets: [
        .target(name: "CSupport"),
        .target(name: "MeetRecCore", dependencies: ["CSupport"]),
        .executableTarget(name: "meetrec", dependencies: ["MeetRecCore"]),
        .executableTarget(name: "MeetRecApp", dependencies: ["MeetRecCore"]),
        .testTarget(name: "MeetRecCoreTests", dependencies: ["MeetRecCore", "CSupport"], exclude: ["Fixtures"]),
    ],
    swiftLanguageModes: [.v5]
)
