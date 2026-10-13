// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OpenMouse",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OpenMouse", targets: ["OpenMouse"]),
    ],
    targets: [
        .target(name: "OpenMouseCore"),
        .executableTarget(
            name: "OpenMouse",
            dependencies: ["OpenMouseCore"],
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
