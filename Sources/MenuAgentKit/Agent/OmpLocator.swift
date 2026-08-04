import Foundation

/// Finds the `omp` binary.
///
/// A GUI app launched from Finder inherits a minimal `PATH` (typically
/// `/usr/bin:/bin:/usr/sbin:/sbin`), so the inherited environment alone is not
/// enough — Homebrew and per-user prefixes are probed explicitly.
public enum OmpLocator {
	public static func find(
		executableName: String = AppConfiguration.ompExecutableName,
		environment: [String: String] = ProcessInfo.processInfo.environment,
		additionalPaths: [String] = AppConfiguration.additionalSearchPaths,
		fileManager: FileManager = .default
	) -> URL? {
		let inherited = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
		var seen = Set<String>()
		let candidates = (inherited + additionalPaths).filter { seen.insert($0).inserted }

		for directory in candidates where !directory.isEmpty {
			let url = URL(fileURLWithPath: directory).appendingPathComponent(executableName)
			if fileManager.isExecutableFile(atPath: url.path) { return url }
		}
		return nil
	}

	/// `PATH` handed to the child, with our extra prefixes appended so tools
	/// OMP shells out to (git, node, ripgrep) resolve the same way they do in a
	/// login shell.
	public static func childPath(
		environment: [String: String] = ProcessInfo.processInfo.environment,
		additionalPaths: [String] = AppConfiguration.additionalSearchPaths
	) -> String {
		let inherited = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
		var seen = Set<String>()
		return (inherited + additionalPaths)
			.filter { !$0.isEmpty && seen.insert($0).inserted }
			.joined(separator: ":")
	}
}
