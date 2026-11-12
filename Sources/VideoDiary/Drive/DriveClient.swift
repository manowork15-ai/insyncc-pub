import Foundation

struct DriveFile: Decodable, Hashable, Identifiable {
    struct VideoMediaMetadata: Decodable, Hashable {
        let durationMillis: String?
    }

    let id: String
    let name: String
    let mimeType: String?
    let parents: [String]?
    let appProperties: [String: String]?
    let description: String?
    let size: String?
    let thumbnailLink: String?
    let webViewLink: String?
    let createdTime: Date?
    let videoMediaMetadata: VideoMediaMetadata?
}

private struct DriveFileList: Decodable {
    let files: [DriveFile]
    let nextPageToken: String?
}

enum DriveError: LocalizedError {
    case http(status: Int, message: String)
    case invalidResponse
    case uploadSessionExpired

    var errorDescription: String? {
        switch self {
        case .http(let status, let message):
            if let msg = DriveError.googleMessage(message) { return "Google Drive: \(msg) (\(status))" }
            return "Google Drive returned an error (\(status))."
        case .invalidResponse: return "Unexpected response from Google Drive."
        case .uploadSessionExpired: return "The upload session expired. It will restart."
        }
    }

    private static func googleMessage(_ body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }
}

extension CharacterSet {
    static let urlUnreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
}

/// Thin client for the Google Drive v3 REST API.
final class DriveClient {
    typealias TokenProvider = (_ forceRefresh: Bool) async throws -> String

    static let folderMime = "application/vnd.google-apps.folder"
    static let fileFields = "id,name,mimeType,parents,appProperties,description,size,thumbnailLink,webViewLink,createdTime,videoMediaMetadata(durationMillis)"

    private let api = "https://www.googleapis.com/drive/v3"
    private let uploadAPI = "https://www.googleapis.com/upload/drive/v3/files"
    private let token: TokenProvider
    private let session: URLSession
    private let downloader = FileDownloader()
    private let decoder: JSONDecoder

    init(token: @escaping TokenProvider) {
        self.token = token
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        self.session = URLSession(configuration: config)

        let decoder = JSONDecoder()
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        decoder.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            if let date = withFraction.date(from: s) ?? plain.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath, debugDescription: "Bad date \(s)"))
        }
        self.decoder = decoder
    }

    // MARK: Plumbing

    private func url(_ base: String, _ query: [String: String] = [:]) -> URL {
        var comps = URLComponents(string: base)!
        if !query.isEmpty {
            comps.percentEncodedQueryItems = query.sorted { $0.key < $1.key }.map {
                URLQueryItem(name: $0.key, value: $0.value.addingPercentEncoding(withAllowedCharacters: .urlUnreserved))
            }
        }
        return comps.url!
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }

    /// Sends an authorised request, refreshing the token once on 401 and backing off on 429/5xx.
    private func send(_ request: URLRequest, body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        var forceRefresh = false
        while true {
            var req = request
            req.setValue("Bearer \(try await token(forceRefresh))", forHTTPHeaderField: "Authorization")
            let pair: (Data, URLResponse)
            if let body {
                pair = try await session.upload(for: req, from: body)
            } else {
                pair = try await session.data(for: req)
            }
            let (data, response) = pair
            guard let http = response as? HTTPURLResponse else { throw DriveError.invalidResponse }

            if http.statusCode == 401, !forceRefresh {
                forceRefresh = true
                continue
            }
            if (http.statusCode == 429 || http.statusCode >= 500), attempt < 4 {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt))) * 500_000_000)
                continue
            }
            return (data, http)
        }
    }

    private func json<T: Decodable>(_ request: URLRequest, body: Data? = nil) async throws -> T {
        let (data, http) = try await send(request, body: body)
        guard (200..<300).contains(http.statusCode) else {
            throw DriveError.http(status: http.statusCode, message: String(decoding: data, as: UTF8.self))
        }
        return try decoder.decode(T.self, from: data)
    }

    private func jsonRequest(_ url: URL, method: String, body: [String: Any]) throws -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    private func list(query q: String, fields: String, orderBy: String? = nil) async throws -> [DriveFile] {
        var all: [DriveFile] = []
        var pageToken: String?
        repeat {
            var params = ["q": q, "fields": "nextPageToken,files(\(fields))", "pageSize": "200", "spaces": "drive"]
            if let orderBy { params["orderBy"] = orderBy }
            if let pageToken { params["pageToken"] = pageToken }
            let page: DriveFileList = try await json(URLRequest(url: url("\(api)/files", params)))
            all += page.files
            pageToken = page.nextPageToken
        } while pageToken != nil
        return all
    }

    // MARK: Account

    struct About: Decodable {
        struct User: Decodable { let displayName: String?; let emailAddress: String? }
        let user: User
    }

    func about() async throws -> About {
        try await json(URLRequest(url: url("\(api)/about", ["fields": "user(displayName,emailAddress)"])))
    }

    // MARK: Folders

    func listFolders(in parent: String) async throws -> [DriveFile] {
        try await list(
            query: "'\(Self.escape(parent))' in parents and mimeType='\(Self.folderMime)' and trashed=false",
            fields: "id,name,mimeType",
            orderBy: "name_natural"
        )
    }

    func createFolder(named name: String, in parent: String) async throws -> DriveFile {
        let req = try jsonRequest(url("\(api)/files", ["fields": "id,name,mimeType"]), method: "POST",
                                  body: ["name": name, "mimeType": Self.folderMime, "parents": [parent]])
        return try await json(req)
    }

    func findOrCreateFolder(named name: String, in parent: String) async throws -> String {
        let existing = try await list(
            query: "name='\(Self.escape(name))' and '\(Self.escape(parent))' in parents and mimeType='\(Self.folderMime)' and trashed=false",
            fields: "id,name"
        )
        if let first = existing.first { return first.id }
        return try await createFolder(named: name, in: parent).id
    }

    func file(id: String) async throws -> DriveFile {
        try await json(URLRequest(url: url("\(api)/files/\(id)", ["fields": Self.fileFields])))
    }

    // MARK: Diary entries

    func listDiaryFiles() async throws -> [DriveFile] {
        try await list(
            query: "appProperties has { key='app' and value='\(DiaryLayout.appTag)' } and trashed=false",
            fields: Self.fileFields
        )
    }

    func updateFile(id: String, metadata: [String: Any]) async throws -> DriveFile {
        let req = try jsonRequest(url("\(api)/files/\(id)", ["fields": Self.fileFields]), method: "PATCH", body: metadata)
        return try await json(req)
    }

    func trash(id: String) async throws {
        let req = try jsonRequest(url("\(api)/files/\(id)", ["fields": "id"]), method: "PATCH", body: ["trashed": true])
        let (data, http) = try await send(req)
        guard (200..<300).contains(http.statusCode) || http.statusCode == 404 else {
            throw DriveError.http(status: http.statusCode, message: String(decoding: data, as: UTF8.self))
        }
    }

    // MARK: Resumable upload

    func startResumableUpload(metadata: [String: Any], mimeType: String, length: Int64) async throws -> URL {
        var req = try jsonRequest(url(uploadAPI, ["uploadType": "resumable", "fields": Self.fileFields]),
                                  method: "POST", body: metadata)
        req.setValue(mimeType, forHTTPHeaderField: "X-Upload-Content-Type")
        req.setValue(String(length), forHTTPHeaderField: "X-Upload-Content-Length")
        let (data, http) = try await send(req)
        guard (200..<300).contains(http.statusCode),
              let location = http.value(forHTTPHeaderField: "Location"),
              let sessionURL = URL(string: location) else {
            throw DriveError.http(status: http.statusCode, message: String(decoding: data, as: UTF8.self))
        }
        return sessionURL
    }

    private enum UploadStatus {
        case incomplete(next: Int64)
        case complete(DriveFile)
    }

    private func parseUpload(_ data: Data, _ http: HTTPURLResponse) throws -> UploadStatus {
        switch http.statusCode {
        case 200, 201:
            return .complete(try decoder.decode(DriveFile.self, from: data))
        case 308:
            // "Range: bytes=0-12345" means bytes 0...12345 are stored.
            if let range = http.value(forHTTPHeaderField: "Range"),
               let last = range.split(separator: "-").last, let n = Int64(last) {
                return .incomplete(next: n + 1)
            }
            return .incomplete(next: 0)
        case 404, 410:
            throw DriveError.uploadSessionExpired
        default:
            throw DriveError.http(status: http.statusCode, message: String(decoding: data, as: UTF8.self))
        }
    }

    /// Uploads (or resumes uploading) `fileURL` into an existing resumable session, in 8 MiB chunks.
    func upload(fileURL: URL, session sessionURL: URL, total: Int64,
                progress: @escaping (Double) -> Void) async throws -> DriveFile {
        var probe = URLRequest(url: sessionURL)
        probe.httpMethod = "PUT"
        probe.setValue("bytes */\(total)", forHTTPHeaderField: "Content-Range")
        let (probeData, probeHTTP) = try await send(probe, body: Data())

        var offset: Int64
        switch try parseUpload(probeData, probeHTTP) {
        case .complete(let file): progress(1); return file
        case .incomplete(let next): offset = next
        }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let chunkSize: Int64 = 8 * 1024 * 1024

        while true {
            try Task.checkCancellation()
            progress(Double(offset) / Double(max(total, 1)))
            try handle.seek(toOffset: UInt64(offset))
            let length = Int(min(chunkSize, total - offset))
            let chunk = try handle.read(upToCount: length) ?? Data()
            guard !chunk.isEmpty else { throw DriveError.invalidResponse }

            var req = URLRequest(url: sessionURL)
            req.httpMethod = "PUT"
            req.setValue("bytes \(offset)-\(offset + Int64(chunk.count) - 1)/\(total)", forHTTPHeaderField: "Content-Range")
            let (data, http) = try await send(req, body: chunk)
            switch try parseUpload(data, http) {
            case .complete(let file): progress(1); return file
            case .incomplete(let next): offset = next
            }
        }
    }

    // MARK: Downloads

    func download(fileID: String, to destination: URL, expectedSize: Int64,
                  progress: @escaping (Double) -> Void) async throws -> URL {
        var req = URLRequest(url: url("\(api)/files/\(fileID)", ["alt": "media"]))
        req.setValue("Bearer \(try await token(false))", forHTTPHeaderField: "Authorization")
        return try await downloader.download(req, to: destination, expectedSize: expectedSize, progress: progress)
    }

    func authorizedData(from url: URL) async throws -> Data {
        let (data, http) = try await send(URLRequest(url: url))
        guard (200..<300).contains(http.statusCode) else {
            throw DriveError.http(status: http.statusCode, message: "")
        }
        return data
    }
}

/// URLSession download wrapper that reports progress and moves the file into place.
private final class FileDownloader: NSObject, URLSessionDownloadDelegate {
    private struct Job {
        let destination: URL
        let expectedSize: Int64
        let progress: (Double) -> Void
        let completion: (Result<URL, Error>) -> Void
    }

    private let lock = NSLock()
    private var jobs: [Int: Job] = [:]
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    func download(_ request: URLRequest, to destination: URL, expectedSize: Int64,
                  progress: @escaping (Double) -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.downloadTask(with: request)
            let job = Job(destination: destination, expectedSize: expectedSize, progress: progress) {
                continuation.resume(with: $0)
            }
            lock.lock(); jobs[task.taskIdentifier] = job; lock.unlock()
            task.resume()
        }
    }

    private func take(_ id: Int) -> Job? {
        lock.lock(); defer { lock.unlock() }
        return jobs.removeValue(forKey: id)
    }

    private func peek(_ id: Int) -> Job? {
        lock.lock(); defer { lock.unlock() }
        return jobs[id]
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let job = peek(downloadTask.taskIdentifier) else { return }
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : job.expectedSize
        if expected > 0 { job.progress(min(1, Double(totalBytesWritten) / Double(expected))) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let job = take(downloadTask.taskIdentifier) else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            job.completion(.failure(DriveError.http(status: http.statusCode, message: "")))
            return
        }
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: job.destination.path) { try fm.removeItem(at: job.destination) }
            try fm.moveItem(at: location, to: job.destination)
            job.completion(.success(job.destination))
        } catch {
            job.completion(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let job = take(task.taskIdentifier) else { return }
        job.completion(.failure(error))
    }
}
