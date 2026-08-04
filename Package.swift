// swift-tools-version: 6.0
import PackageDescription

let package = Package(
	name: "MenuAgent",
	platforms: [.macOS(.v14)],
	products: [
		.executable(name: "MenuAgent", targets: ["MenuAgent"]),
		.library(name: "MenuAgentKit", targets: ["MenuAgentKit"]),
	],
	targets: [
		.executableTarget(
			name: "MenuAgent",
			dependencies: ["MenuAgentKit"],
			path: "Sources/MenuAgent"
		),
		.target(
			name: "MenuAgentKit",
			path: "Sources/MenuAgentKit"
		),
		.testTarget(
			name: "MenuAgentKitTests",
			dependencies: ["MenuAgentKit"],
			path: "Tests/MenuAgentKitTests"
		),
	]
)
