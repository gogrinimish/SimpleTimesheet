// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SimpleTimesheet",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "SimpleTimesheetCore",
            targets: ["SimpleTimesheetCore"]
        ),
    ],
    dependencies: [
        // Skip dependencies commented out for now - can be re-enabled for Android support
        // .package(url: "https://source.skip.tools/skip.git", from: "1.0.0"),
        // .package(url: "https://source.skip.tools/skip-ui.git", from: "1.0.0"),
        // .package(url: "https://source.skip.tools/skip-foundation.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "SimpleTimesheetCore",
            dependencies: [],
            path: "Sources/SimpleTimesheetCore"
        ),
        .testTarget(
            name: "SimpleTimesheetCoreTests",
            dependencies: ["SimpleTimesheetCore"],
            path: "Tests/SimpleTimesheetCoreTests"
        ),
    ]
)
