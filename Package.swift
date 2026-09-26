// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "P4W",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "P4WCore", targets: ["P4WCore"]),
        .executable(name: "P4W", targets: ["P4W"]),
        .executable(name: "p4w-probe", targets: ["p4w-probe"]),
        .executable(name: "p4w-supervisor", targets: ["p4w-supervisor"]),
    ],
    targets: [
        // Shim mínimo en C: libproc no se expone en Swift, y estas dos cosas
        // (footprint real y árbol de procesos) no se pueden hacer de otra forma.
        .target(name: "P4WProc"),
        .target(
            name: "P4WCore",
            dependencies: ["P4WProc"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "P4W",
            dependencies: ["P4WCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "p4w-probe",
            dependencies: ["P4WCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "p4w-supervisor",
            dependencies: ["P4WCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
