import Foundation

// MARK: - Minimal WebDAV client (FlClash: Tools -> 备份与恢复 ->
// WebDAV 远程备份)
// FlClash backs up to a WebDAV server (account + file name +
// connectivity indicator). This is a small purpose-built client:
// PROPFIND to test the account, PUT to upload a backup zip, GET to
// download it. Basic auth only, matching what FlClash's WebDAV
// accounts use. The backup zip itself is produced by BackupStore.

struct WebDAVAccount: Codable, Equatable {
    var url: String
    var username: String
    var password: String
    var fileName: String
}

enum WebDAVError: LocalizedError {
    case invalidURL
    case httpStatus(Int)
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "WebDAV 地址无效"
        case .httpStatus(let code): return "WebDAV 返回 HTTP \(code)"
        case .network(let error): return error.localizedDescription
        }
    }
}

struct WebDAVClient {
    let account: WebDAVAccount

    private var baseURL: URL? {
        URL(string: account.url.trimmingCharacters(in: .whitespaces))
    }

    private func request(for url: URL, method: String, body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if !account.username.isEmpty {
            let credentials = "\(account.username):\(account.password)"
            if let data = credentials.data(using: .utf8) {
                request.setValue("Basic \(data.base64EncodedString())", forHTTPHeaderField: "Authorization")
            }
        }
        return request
    }

    private func checkStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw WebDAVError.httpStatus(http.statusCode)
        }
    }

    /// PROPFIND on the base URL: proves the account and server work.
    func testConnection() async throws {
        guard let base = baseURL else { throw WebDAVError.invalidURL }
        let request = request(for: base, method: "PROPFIND")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            try checkStatus(response)
        } catch let error as WebDAVError {
            throw error
        } catch {
            throw WebDAVError.network(error)
        }
    }

    /// Upload the backup zip as the account's file name.
    func upload(_ data: Data) async throws {
        guard let base = baseURL else { throw WebDAVError.invalidURL }
        let target = base.appendingPathComponent(account.fileName.isEmpty ? "concord-ios-backup.zip" : account.fileName)
        let request = request(for: target, method: "PUT", body: data)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            try checkStatus(response)
        } catch let error as WebDAVError {
            throw error
        } catch {
            throw WebDAVError.network(error)
        }
    }

    /// Download the backup zip from the account's file name.
    func download() async throws -> Data {
        guard let base = baseURL else { throw WebDAVError.invalidURL }
        let target = base.appendingPathComponent(account.fileName.isEmpty ? "concord-ios-backup.zip" : account.fileName)
        let request = request(for: target, method: "GET")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try checkStatus(response)
            return data
        } catch let error as WebDAVError {
            throw error
        } catch {
            throw WebDAVError.network(error)
        }
    }
}
