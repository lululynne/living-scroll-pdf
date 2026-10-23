// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LivingScrollPDF",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LivingScrollPDF",
            path: "Sources/LivingScrollPDF",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Carbon"),
            ]
        )
    ]
)
