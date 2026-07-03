// swift-tools-version:5.6

import PackageDescription

let package = Package(
    name: "NativeHA",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(
            name: "NativeHACore",
            targets: ["NativeHACore"]
        ),
        .executable(
            name: "ha-probe",
            targets: ["HAProbe"]
        ),
        .executable(
            name: "NativeHAMac",
            targets: ["NativeHAMac"]
        ),
    ],
    targets: [
        .target(
            name: "NativeHACore"
        ),
        .executableTarget(
            name: "HAProbe",
            dependencies: ["NativeHACore"]
        ),
        .executableTarget(
            name: "NativeHAMac",
            dependencies: ["NativeHACore"]
        ),
        .testTarget(
            name: "NativeHACoreTests",
            dependencies: ["NativeHACore"]
        ),
    ]
)
