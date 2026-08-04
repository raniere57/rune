import Foundation

/// The directory OMP is launched in.
///
/// OMP resolves its session store, project config, context files, and every
/// relative path from its own cwd, and cwd cannot be changed on a live process.
/// Changing workspace therefore restarts OMP — see `AgentCoordinator.changeWorkspace`.
public struct Workspace: Sendable, Equatable {
	public let url: URL

	public init(url: URL) {
		self.url = url.standardizedFileURL
	}

	public static let `default` = Workspace(url: AppConfiguration.defaultWorkspaceRoot)

	public var displayName: String {
		let home = FileManager.default.homeDirectoryForCurrentUser.path
		return url.path.hasPrefix(home)
			? "~" + url.path.dropFirst(home.count)
			: url.path
	}

	/// Falls back to the home directory when the configured root is missing, so
	/// a fresh machine without `~/Dev` still launches.
	public func resolvedExistingURL(fileManager: FileManager = .default) -> URL {
		var isDirectory: ObjCBool = false
		if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
			return url
		}
		return fileManager.homeDirectoryForCurrentUser
	}
}
