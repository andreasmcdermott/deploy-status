import Foundation

public enum ServiceError: LocalizedError {
    case message(String), unauthorized, rateLimit(Date)
    public var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .unauthorized: return "Your GitHub session expired. Reconnect in Settings."
        case .rateLimit(let date): return "GitHub paused requests until \(date.formatted(date: .omitted, time: .standard))."
        }
    }
}

public enum SignInMethod: String, Codable, CaseIterable {
    case cli = "GitHub CLI", personal = "Personal token", app = "GitHub App"
}

public struct Credential: Codable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiration: Date?
    public let clientID: String
    public let login: String
    // Credentials saved before alternate methods were available used device flow.
    private var method: SignInMethod?
    public var signInMethod: SignInMethod { method ?? .app }

    init(accessToken: String, refreshToken: String?, expiration: Date?, clientID: String, login: String,
         method: SignInMethod = .app) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiration = expiration
        self.clientID = clientID
        self.login = login
        self.method = method
    }

    public static func personal(token: String, login: String) -> Self {
        Self(accessToken: token, refreshToken: nil, expiration: nil, clientID: "", login: login, method: .personal)
    }

    public static func cli(login: String) -> Self {
        Self(accessToken: "", refreshToken: nil, expiration: nil, clientID: "", login: login, method: .cli)
    }
}

public struct DeviceCode: Decodable {
    public let deviceCode, userCode: String
    public let verificationUri: URL
    public let expiresIn, interval: Int
}

public struct OAuthReply: Decodable {
    public let accessToken, refreshToken, error, errorDescription: String?
    public let expiresIn: Int?
    public func credential(clientID: String, login: String) throws -> Credential {
        guard let accessToken else {
            throw ServiceError.message(errorDescription ?? error ?? "GitHub returned no access token.")
        }
        return Credential(accessToken: accessToken, refreshToken: refreshToken,
                          expiration: expiresIn.map { Date().addingTimeInterval(Double($0)) },
                          clientID: clientID, login: login)
    }
}

public final class GitHub {
    private let session: URLSession
    public init(session: URLSession = URLSession(configuration: .ephemeral)) { self.session = session }

    private func decode<T: Decodable>(_ type: T.Type, request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        switch http.statusCode {
        case 200..<300: break
        case 401: throw ServiceError.unauthorized
        default:
            if let seconds = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) {
                throw ServiceError.rateLimit(Date().addingTimeInterval(max(1, seconds)))
            }
            let message = (try? JSONDecoder().decode(APIError.self, from: data))?.message
            if http.statusCode == 429 || http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
                || (http.statusCode == 403 && message?.localizedCaseInsensitiveContains("rate limit") == true) {
                let date = http.value(forHTTPHeaderField: "X-RateLimit-Reset")
                    .flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
                throw ServiceError.rateLimit(date ?? Date().addingTimeInterval(60))
            }
            throw ServiceError.message("GitHub \(http.statusCode): \(message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode))")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do { return try decoder.decode(type, from: data) }
        catch {
            if let reply = try? decoder.decode(OAuthReply.self, from: data), let reason = reply.error {
                throw ServiceError.message(reply.errorDescription ?? reason)
            }
            throw error
        }
    }

    private struct APIError: Decodable { let message: String }
    private func oauth<T: Decodable>(_ path: String, fields: [String: String]) async throws -> T {
        var request = URLRequest(url: URL(string: "https://github.com/login/" + path)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(fields)
        return try await decode(T.self, request: request)
    }

    public func begin(clientID: String) async throws -> DeviceCode {
        try await oauth("device/code", fields: ["client_id": clientID])
    }

    public func authorize(clientID: String, code: DeviceCode) async throws -> OAuthReply {
        var interval = max(1, code.interval)
        let deadline = Date().addingTimeInterval(Double(code.expiresIn))
        while Date() < deadline {
            try await Task.sleep(for: .seconds(interval))
            try Task.checkCancellation()
            let reply: OAuthReply = try await oauth("oauth/access_token", fields: [
                "client_id": clientID, "device_code": code.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
            ])
            switch reply.error {
            case nil: return reply
            case "authorization_pending": continue
            case "slow_down": interval += 5
            default: throw ServiceError.message(reply.errorDescription ?? "GitHub authorization ended.")
            }
        }
        throw ServiceError.message("The sign-in code expired. Start sign-in again.")
    }

    public func renew(_ credential: Credential) async throws -> Credential {
        guard let refresh = credential.refreshToken else { throw ServiceError.unauthorized }
        let reply: OAuthReply = try await oauth("oauth/access_token", fields: [
            "client_id": credential.clientID, "refresh_token": refresh, "grant_type": "refresh_token"
        ])
        if reply.error == "bad_refresh_token" || reply.error == "invalid_grant" {
            throw ServiceError.unauthorized
        }
        return try reply.credential(clientID: credential.clientID, login: credential.login)
    }

    func get<T: Decodable>(_ path: String, token: String, query: [String: String] = [:]) async throws -> T {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = "api.github.com"
        parts.path = "/" + path
        if !query.isEmpty { parts.queryItems = query.map(URLQueryItem.init(name:value:)) }
        guard let url = parts.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return try await decode(T.self, request: request)
    }

    public func login(token: String) async throws -> String {
        struct User: Decodable { let login: String }
        let user: User = try await get("user", token: token)
        return user.login
    }

    public func repositories(token: String, method: SignInMethod) async throws -> [String] {
        struct Installation: Decodable { let id: Int }
        struct Installations: Decodable { let installations: [Installation] }
        struct Repo: Decodable { let fullName: String }
        struct Repositories: Decodable { let repositories: [Repo] }
        var repos = Set<String>()
        var page = 1
        if method != .app {
            while true {
                let batch: [Repo] = try await get("user/repos", token: token, query: paging(page))
                repos.formUnion(batch.map(\.fullName))
                if batch.count < 100 { return repos.sorted() }
                page += 1
            }
        }
        while true {
            let batch: Installations = try await get("user/installations", token: token, query: paging(page))
            for installation in batch.installations {
                var repoPage = 1
                while true {
                    let list: Repositories = try await get("user/installations/\(installation.id)/repositories",
                                                           token: token, query: paging(repoPage))
                    repos.formUnion(list.repositories.map(\.fullName))
                    if list.repositories.count < 100 { break }
                    repoPage += 1
                }
            }
            if batch.installations.count < 100 { break }
            page += 1
        }
        return repos.sorted()
    }

    func paging(_ page: Int) -> [String: String] { ["per_page": "100", "page": String(page)] }

    public func deployments(repo: String, environment: String? = nil, page: Int = 1,
                            count: Int = 50, token: String) async throws -> [Deployment] {
        var query = ["per_page": String(count), "page": String(page)]
        query["environment"] = environment
        return try await get("repos/\(repo)/deployments", token: token, query: query)
    }

    public func attempt(repo: String, deployment: Deployment, token: String) async throws -> Attempt {
        let statuses: [GitStatus] = try await get("repos/\(repo)/deployments/\(deployment.id)/statuses",
                                                 token: token, query: ["per_page": "100"])
        return Attempt(deployment, statuses: statuses)
    }
}
