// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OpenMouse",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OpenMouse", targets: ["OpenMouse"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
    ],
    targets: [
        .target(name: "OpenMouseCore"),
        .executableTarget(
            name: "OpenMouse",
            dependencies: [
                "OpenMouseCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(name: "OpenMouseCoreTests", dependencies: ["OpenMouseCore"]),
    ]
)
