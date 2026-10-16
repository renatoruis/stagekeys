import Foundation
import Observation

/// A sound file listed in the bucket.
struct RemoteSound: Codable, Equatable {
    var file: String
    var size: Int64
    var etag: String
}

/// Reads one page of an S3 ListObjectsV2 response.
final class ListBucketParser: NSObject, XMLParserDelegate {
    struct Page {
        var sounds: [RemoteSound]
        var next: String?
    }

    private var sounds: [RemoteSound] = []
    private var next: String?
    private var truncated = false
    private var object: [String: String]?
    private var text = ""

    static func parse(_ data: Data) -> Page? {
        let delegate = ListBucketParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return Page(sounds: delegate.sounds, next: delegate.truncated ? delegate.next : nil)
    }

    /// Only `.sf2` files at the bucket root count; hidden files are skipped.
    static func accepts(_ key: String) -> Bool {
        !key.contains("/") && !key.hasPrefix(".") && key.lowercased().hasSuffix(".sf2")
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "Contents" { object = [:] }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "Contents":
            if let object, let key = object["Key"], Self.accepts(key) {
                let etag = (object["ETag"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                sounds.append(RemoteSound(file: key, size: Int64(object["Size"] ?? "") ?? 0, etag: etag))
            }
            object = nil
        case "Key", "Size", "ETag":
            object?[name] = value
        case "NextContinuationToken":
            next = value
        case "IsTruncated":
            truncated = value == "true"
        default:
            break
        }
        text = ""
    }
}

/// Sounds listed in the public bucket and the copies downloaded to `Library/Sounds`.
@Observable
final class SoundLibrary {
    enum State: Equatable {
        case available
        case downloading(Double)
        case downloaded
        case update
        /// Downloaded, but no longer in the bucket.
        case removed
    }

    let folder: URL
    private(set) var remote: [RemoteSound] = []
    private(set) var fetched: Date?
    private(set) var refreshing = false
    private(set) var progress: [String: Double] = [:]
    private(set) var downloaded: [String: RemoteSound] = [:]
    var error: String?
    /// Called on the main thread when files are added to or removed from `folder`.
    var onChange: (() -> Void)?

    private let cacheURL: URL
    private let recordURL: URL
    @ObservationIgnored private var tasks: [String: URLSessionDownloadTask] = [:]
    @ObservationIgnored private lazy var session = URLSession(configuration: .default, delegate: delegate, delegateQueue: .main)
    @ObservationIgnored private let delegate = DownloadDelegate()

    init(libraryFolder: URL) {
        folder = ProcessInfo.processInfo.environment["STAGEKEYS_SOUNDS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? libraryFolder.appendingPathComponent("Sounds", isDirectory: true)
        cacheURL = libraryFolder.appendingPathComponent("remote.json")
        recordURL = folder.appendingPathComponent(".downloads.json")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: recordURL), let record = try? JSONDecoder().decode([String: RemoteSound].self, from: data) {
            downloaded = record
        }
        if let data = try? Data(contentsOf: cacheURL), let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.base == baseURL?.absoluteString {
            remote = cache.sounds
            fetched = cache.fetched
        }
        delegate.library = self
    }

    /// `soundsURL` in UserDefaults overrides `StageKeysSoundsURL` from Info.plist.
    var baseURL: URL? {
        let raw = UserDefaults.standard.string(forKey: "soundsURL") ?? Bundle.main.object(forInfoDictionaryKey: "StageKeysSoundsURL") as? String ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? nil : URL(string: trimmed)
    }

    var usedBytes: Int64 {
        localFiles().reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    func isLocal(_ file: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(file).path)
    }

    func state(_ file: String) -> State {
        if let value = progress[file] { return .downloading(value) }
        guard isLocal(file) else { return .available }
        guard fetched != nil, baseURL != nil else { return .downloaded }
        guard let listed = remote.first(where: { $0.file == file }) else { return .removed }
        if let record = downloaded[file] {
            return record.etag == listed.etag && record.size == listed.size ? .downloaded : .update
        }
        let size = (try? folder.appendingPathComponent(file).resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        return size == listed.size ? .downloaded : .update
    }

    func refreshIfStale() {
        guard baseURL != nil, !refreshing else { return }
        if let fetched, Date().timeIntervalSince(fetched) < 3600 { return }
        refresh()
    }

    func refresh() {
        guard let base = baseURL, !refreshing else { return }
        refreshing = true
        error = nil
        Task { @MainActor in
            do {
                var sounds: [RemoteSound] = []
                var token: String?
                repeat {
                    let query = "list-type=2" + (token.map { "&continuation-token=\(Self.encode($0, .alphanumerics.union(CharacterSet(charactersIn: "-._~"))))" } ?? "")
                    guard let url = URL(string: base.absoluteString + "/?" + query) else { throw URLError(.badURL) }
                    let (data, response) = try await URLSession.shared.data(from: url)
                    guard (response as? HTTPURLResponse)?.statusCode == 200, let page = ListBucketParser.parse(data) else {
                        throw URLError(.badServerResponse)
                    }
                    sounds += page.sounds
                    token = page.next
                } while token != nil
                remote = sounds.sorted { $0.file < $1.file }
                fetched = Date()
                write(Cache(base: base.absoluteString, fetched: fetched ?? Date(), sounds: remote), to: cacheURL)
            } catch {
                self.error = "Could not reach the sound library."
            }
            refreshing = false
        }
    }

    func download(_ file: String) {
        guard tasks[file] == nil, let base = baseURL,
              let url = URL(string: base.absoluteString + "/" + Self.encode(file, .urlPathAllowed.subtracting(CharacterSet(charactersIn: "+&;=/")))) else { return }
        let task = session.downloadTask(with: url)
        task.taskDescription = file
        tasks[file] = task
        progress[file] = 0
        error = nil
        task.resume()
    }

    func cancel(_ file: String) {
        tasks.removeValue(forKey: file)?.cancel()
        progress[file] = nil
    }

    func remove(_ file: String) {
        cancel(file)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
        downloaded[file] = nil
        write(downloaded, to: recordURL)
        onChange?()
    }

    private static func encode(_ text: String, _ allowed: CharacterSet) -> String {
        text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    private func localFiles() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "sf2" }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: Download delegate (main queue)

    fileprivate func didWrite(_ task: URLSessionDownloadTask, written: Int64, expected: Int64) {
        guard let file = task.taskDescription, tasks[file] === task else { return }
        let total = expected > 0 ? expected : remote.first(where: { $0.file == file })?.size ?? 0
        progress[file] = total > 0 ? min(1, Double(written) / Double(total)) : 0
    }

    /// Runs before the temporary file is deleted, so it is moved here.
    fileprivate func didFinish(_ task: URLSessionDownloadTask, at location: URL) {
        guard let file = task.taskDescription, tasks[file] === task else { return }
        let size = Int64((try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let listed = remote.first { $0.file == file }
        guard status == 200, size > 0, listed.map({ $0.size == size }) ?? true else {
            error = "Download of \(file) failed."
            return
        }
        let destination = folder.appendingPathComponent(file)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: location)
            } else {
                try FileManager.default.moveItem(at: location, to: destination)
            }
        } catch {
            self.error = "Could not save \(file)."
            return
        }
        let etag = listed?.etag ?? ((task.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag") ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        downloaded[file] = RemoteSound(file: file, size: size, etag: etag)
        write(downloaded, to: recordURL)
    }

    fileprivate func didComplete(_ task: URLSessionTask, error: Error?) {
        guard let file = task.taskDescription, tasks[file] === task else { return }
        tasks[file] = nil
        progress[file] = nil
        if let error, (error as? URLError)?.code != .cancelled {
            self.error = "Download of \(file) failed."
        }
        onChange?()
    }

    private struct Cache: Codable {
        var base: String
        var fetched: Date
        var sounds: [RemoteSound]
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    weak var library: SoundLibrary?

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        library?.didWrite(downloadTask, written: totalBytesWritten, expected: totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        library?.didFinish(downloadTask, at: location)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        library?.didComplete(task, error: error)
    }
}
