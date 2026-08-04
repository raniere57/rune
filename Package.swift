// swift-tools-version: 6.0
import PackageDescription

let package = Package(
	name: "Rune",
	platforms: [.macOS(.v14)],
	products: [
		.executable(name: "Rune", targets: ["Rune"]),
		.library(name: "RuneKit", targets: ["RuneKit"]),
	],
	targets: [
		.executableTarget(
			name: "Rune",
			dependencies: ["RuneKit"],
			path: "Sources/Rune"
		),
		.target(
			name: "RuneKit",
			path: "Sources/RuneKit"
		),
		.testTarget(
			name: "RuneKitTests",
			dependencies: ["RuneKit"],
			path: "Tests/RuneKitTests"
		),
	]
)
