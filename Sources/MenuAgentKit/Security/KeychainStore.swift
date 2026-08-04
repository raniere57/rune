import Foundation
import Security

/// Generic-password storage for the OpenCode Zen API key.
///
/// The key exists in exactly two places: the login keychain, and the
/// environment of the `omp` child process. It is never written to
/// `UserDefaults`, a plist, a log line, or an error message.
public enum KeychainStore {
	public enum Failure: Error, LocalizedError {
		case notFound
		case unexpectedData
		case osStatus(OSStatus)

		public var errorDescription: String? {
			switch self {
			case .notFound: return "No API key stored in the keychain."
			case .unexpectedData: return "Keychain item is not valid UTF-8."
			case .osStatus(let status):
				let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
				return "Keychain error: \(message)"
			}
		}
	}

	public static func read(
		service: String = AppConfiguration.keychainService,
		account: String = AppConfiguration.keychainAccount
	) throws -> String {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
			kSecReturnData as String: true,
			kSecMatchLimit as String: kSecMatchLimitOne,
		]

		var item: CFTypeRef?
		let status = SecItemCopyMatching(query as CFDictionary, &item)
		switch status {
		case errSecSuccess:
			guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
				throw Failure.unexpectedData
			}
			return value.trimmingCharacters(in: .whitespacesAndNewlines)
		case errSecItemNotFound:
			throw Failure.notFound
		default:
			throw Failure.osStatus(status)
		}
	}

	/// Convenience for the launch path, where a missing key is an expected
	/// first-run state rather than an error.
	public static func readIfPresent(
		service: String = AppConfiguration.keychainService,
		account: String = AppConfiguration.keychainAccount
	) -> String? {
		try? read(service: service, account: account)
	}

	public static func write(
		_ value: String,
		service: String = AppConfiguration.keychainService,
		account: String = AppConfiguration.keychainAccount
	) throws {
		let data = Data(value.utf8)
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
		]

		let update: [String: Any] = [kSecValueData as String: data]
		let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
		if updateStatus == errSecSuccess { return }
		guard updateStatus == errSecItemNotFound else { throw Failure.osStatus(updateStatus) }

		var insert = query
		insert[kSecValueData as String] = data
		insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
		let addStatus = SecItemAdd(insert as CFDictionary, nil)
		guard addStatus == errSecSuccess else { throw Failure.osStatus(addStatus) }
	}

	public static func delete(
		service: String = AppConfiguration.keychainService,
		account: String = AppConfiguration.keychainAccount
	) throws {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
		]
		let status = SecItemDelete(query as CFDictionary)
		guard status == errSecSuccess || status == errSecItemNotFound else {
			throw Failure.osStatus(status)
		}
	}

	/// Shown verbatim in the conversation when no key is stored. Deliberately
	/// the exact thing to type, since there is no settings screen.
	public static var setupInstructions: String {
		"""
		Nenhuma chave do OpenCode Zen encontrada no Keychain.

		Digite aqui mesmo:
		  /key sk-suachave

		O valor vai direto para o Keychain — não fica no histórico nem no log.
		Alternativa pelo terminal: ./scripts/set-opencode-key.sh
		"""
	}
}
