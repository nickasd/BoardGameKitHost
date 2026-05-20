// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "BoardGameKitHost",
    platforms: [
        .macOS(.v12), .iOS(.v15), .tvOS(.v15)
    ],
    products: [
        .library(
            name: "BoardGameKitHost",
            targets: ["BoardGameKitHost"]
        ),
    ],
    targets: [
        .target(
            name: "BoardGameKitHost"
        ),

    ],
    swiftLanguageModes: [.v6]
)
