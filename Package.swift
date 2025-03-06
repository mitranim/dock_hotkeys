// swift-tools-version:5.5
import PackageDescription

let package = Package(
  name: "dock_hotkeys",
  platforms: [
    .macOS(.v12)
  ],
  products: [
    .executable(name: "dock_hotkeys", targets: ["dock_hotkeys"])
  ],
  targets: [
    .executableTarget(
      name: "dock_hotkeys",
      path: "src"
    )
  ]
)
