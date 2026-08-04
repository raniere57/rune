import RuneKit

// `--diagnose [saída.png]` builds the real status item and panel, reports their
// geometry, and optionally renders the panel to a PNG. Useful precisely because
// a menu bar app has no window to inspect from the outside.
let arguments = CommandLine.arguments
if arguments.contains("--diagnose") {
	let index = arguments.firstIndex(of: "--diagnose")!
	let output = arguments.count > index + 1 ? arguments[index + 1] : nil
	Diagnostics.run(outputPath: output)
}

RuneMain.run()
