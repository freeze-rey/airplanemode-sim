// swift-tools-version: 6.2
import PackageDescription

let commonSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
]

let package = Package(
    name: "AirplaneMode",
    platforms: [
        .macOS(.v15),
    ],
    targets: [
        .target(
            name: "AirplaneModeCore",
            path: "app/Sources/AirplaneModeCore",
            swiftSettings: commonSwiftSettings
        ),
        .executableTarget(
            name: "airplanemode",
            dependencies: ["AirplaneModeCore"],
            path: "app/Sources/AirplaneMode",
            swiftSettings: commonSwiftSettings
        ),
        .testTarget(
            name: "AirplaneModeCoreTests",
            dependencies: ["AirplaneModeCore"],
            path: "app/Tests/AirplaneModeCoreTests",
            swiftSettings: commonSwiftSettings
        ),
    ]
)
