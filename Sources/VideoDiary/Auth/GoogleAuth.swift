import AppKit
import CryptoKit
import Foundation

struct OAuthCredentials: Codable, Equatable {
    var clientID: String
    var clientSecret: String
}

private struct OAuthTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var expiry: Date
}

private struct TokenResponse: Decodable {
    let access_token: String
    let expires_in: Int
    let refresh_token: String?
}

enum AuthError: LocalizedError {
    case missingCredentials
    case notSignedIn
    case reauthRequired
    case stateMismatch
    case denied(String)
    case tokenExchange(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials: "Add your Google OAuth client ID first."
        case .notSignedIn: "Not connected to Google Drive."
        case .reauthRequired: "Your Google session expired. Please sign in again."
        case .stateMismatch: "Sign-in response didn't match the request. Please try again."
        case .denied(let reason): reason == "access_denied" ? "Access wasn't granted." : "Google sign-in failed: \(reason)"
        case .tokenExchange(let body): "Couldn't finish sign-in. \(body)"
        }
    }
}

/// Google OAuth 2.0 for installed apps: system browser + loopback redirect + PKCE.
@MainActor
final class GoogleAuth: ObservableObject {
    static let scope = "https://www.googleapis.com/auth/drive"

    @Published private(set) var isSignedIn = false
    @Published private(set) var isSigningIn = false
    @Published private(set) var credentials: OAuthCredentials?
    @Published private(set) var accountName: String?
    @Published private(set) var accountEmail: String?

    let hasBundledCredentials: Bool

    private var tokens: OAuthTokens?
    private var refreshTask: Task<String, Error>?
    private var server: LoopbackServer?

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let id = (info["GoogleClientID"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let secret = (info["GoogleClientSecret"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let bundled = !id.isEmpty && !id.hasPrefix("$(")
        hasBundledCredentials = bundled
        credentials = bundled
            ? OAuthCredentials(clientID: id, clientSecret: secret)
            : Keychain.get(OAuthCredentials.self, for: "oauth.credentials")
        tokens = Keychain.get(OAuthTokens.self, for: "oauth.tokens")
        isSignedIn = tokens != nil
        accountName = UserDefaults.standard.string(forKey: Prefs.accountName)
        accountEmail = UserDefaults.standard.string(forKey: Prefs.accountEmail)
    }

    func saveCredentials(clientID: String, clientSecret: String) {
        let creds = OAuthCredentials(
            clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines),
            clientSecret: clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        credentials = creds
        Keychain.set(creds, for: "oauth.credentials")
    }

    func setAccount(name: String?, email: String?) {
        accountName = name
        accountEmail = email
        UserDefaults.standard.set(name, forKey: Prefs.accountName)
        UserDefaults.standard.set(email, forKey: Prefs.accountEmail)
    }

    // MARK: Sign in

    func signIn() async throws {
        guard let creds = credentials, !creds.clientID.isEmpty else { throw AuthError.missingCredentials }
        isSigningIn = true
        defer { isSigningIn = false; server = nil }

        let verifier = Self.randomURLSafe(bytes: 32)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafe(bytes: 16)

        let server = LoopbackServer()
        self.server = server
        let port = try await server.start()
        let redirect = "http://127.0.0.1:\(port)"

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: creds.clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        NSWorkspace.shared.open(comps.url!)

        let callback = try await server.waitForCallback()
        NSApp.activate(ignoringOtherApps: true)

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") { throw AuthError.denied(error) }
        guard value("state") == state else { throw AuthError.stateMismatch }
        guard let code = value("code") else { throw AuthError.denied("no code") }

        let response = try await tokenRequest([
            "code": code,
            "client_id": creds.clientID,
            "client_secret": creds.clientSecret,
            "redirect_uri": redirect,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ])
        guard let refresh = response.refresh_token else {
            throw AuthError.tokenExchange("Google didn't return a refresh token.")
        }
        store(OAuthTokens(accessToken: response.access_token, refreshToken: refresh,
                          expiry: Date().addingTimeInterval(TimeInterval(response.expires_in))))
    }

    func cancelSignIn() {
        server?.cancel()
    }

    func signOut() {
        if let token = tokens?.refreshToken {
            var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data("token=\(token)".utf8)
            URLSession.shared.dataTask(with: req).resume()
        }
        clearTokens()
    }

    private func clearTokens() {
        tokens = nil
        isSignedIn = false
        Keychain.delete("oauth.tokens")
        setAccount(name: nil, email: nil)
    }

    private func store(_ t: OAuthTokens) {
        tokens = t
        isSignedIn = true
        Keychain.set(t, for: "oauth.tokens")
    }

    // MARK: Tokens

    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let tokens else { throw AuthError.notSignedIn }
        if !forceRefresh, tokens.expiry > Date().addingTimeInterval(60) {
            return tokens.accessToken
        }
        if let running = refreshTask { return try await running.value }
        let task = Task { try await self.refresh() }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func refresh() async throws -> String {
        guard let creds = credentials, let current = tokens else { throw AuthError.notSignedIn }
        do {
            let r = try await tokenRequest([
                "client_id": creds.clientID,
                "client_secret": creds.clientSecret,
                "refresh_token": current.refreshToken,
                "grant_type": "refresh_token",
            ])
            store(OAuthTokens(accessToken: r.access_token, refreshToken: r.refresh_token ?? current.refreshToken,
                              expiry: Date().addingTimeInterval(TimeInterval(r.expires_in))))
            return r.access_token
        } catch AuthError.tokenExchange(let body) where body.contains("invalid_grant") {
            clearTokens()
            throw AuthError.reauthRequired
        }
    }

    private func tokenRequest(_ form: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .urlUnreserved) ?? value)"
        }.joined(separator: "&").utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AuthError.tokenExchange(String(decoding: data, as: UTF8.self))
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    // MARK: Helpers

    private static func randomURLSafe(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
