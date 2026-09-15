// swift-tools-version: 5.9
// Wraps the official MobileVLCKit binary from download.videolan.org.
// Run Scripts/fetch-vlckit.sh once after cloning to populate Vendor/.
import PackageDescription

let package = Package(
    name: "VLCKit",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "MobileVLCKit", targets: ["MobileVLCKit"])
    ],
    targets: [
        .binaryTarget(
            name: "MobileVLCKit",
            path: "Vendor/MobileVLCKit.xcframework"
        )
    ]
)
