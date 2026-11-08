// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Rivulet",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Rivulet", targets: ["Rivulet"]),
    ],
    targets: [
        .target(
            name: "RivuletCore",
            path: "Sources/RivuletCore"
        ),
        .executableTarget(
            name: "Rivulet",
            dependencies: ["RivuletCore"],
            path: "Sources/Rivulet"
        ),
        .testTarget(
            name: "RivuletCoreTests",
            dependencies: ["RivuletCore"],
            path: "Tests/RivuletCoreTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
