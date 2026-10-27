// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeetRec",
    platforms: [.macOS("14.5")],
    products: [
        .library(name: "MeetRecCore", targets: ["MeetRecCore"]),
        .library(name: "MeetRecUI", targets: ["MeetRecUI"]),
        .executable(name: "meetrec", targets: ["meetrec"]),
        .executable(name: "MeetRecApp", targets: ["MeetRecApp"]),
    ],
    targets: [
        .target(name: "CSupport"),
        .target(name: "MeetRecCore", dependencies: ["CSupport"]),
        .target(name: "MeetRecUI"),
        .executableTarget(name: "meetrec", dependencies: ["MeetRecCore"]),
        .executableTarget(name: "MeetRecApp", dependencies: ["MeetRecCore", "MeetRecUI"]),
        .testTarget(name: "MeetRecCoreTests", dependencies: ["MeetRecCore", "MeetRecUI", "CSupport"], exclude: ["Fixtures"]),
    ],
    swiftLanguageModes: [.v5]
)
