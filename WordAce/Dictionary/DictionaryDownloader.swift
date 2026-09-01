import Foundation
import CryptoKit
import Compression

@MainActor
@Observable
final class DictionaryDownloader: NSObject {

    enum State: Equatable {
        case idle
        case downloading(bytesReceived: Int64, bytesTotal: Int64)
        case verifying
        case installing
        case done
        case failed(String)

        var isTerminal: Bool {
            switch self {
            case .done, .failed: return true
            default: return false
            }
        }
    }

    private(set) var state: State = .idle

    nonisolated static var installedURL: URL? {
        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return appSupport.appendingPathComponent("dictionary.sqlite")
    }

    private static let installedSHAKey = "dictionaryInstalledSHA256"

    nonisolated static var isInstalled: Bool {
        guard let url = installedURL,
              FileManager.default.fileExists(atPath: url.path) else { return false }
        // A bundle update that ships a new checksum outdates the installed
        // file, so the loader reappears and fetches the new release.
        guard let expected = expectedSHA256 else { return true }
        return UserDefaults.standard.string(forKey: installedSHAKey) == expected
    }

    nonisolated static var isConfigured: Bool { remoteURL != nil }

    nonisolated private static var remoteURL: URL? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "DictionaryDownloadURL") as? String,
              let url = URL(string: s),
              url.scheme == "https" || url.scheme == "http"
        else { return nil }
        return url
    }

    nonisolated private static var expectedSHA256: String? {
        (Bundle.main.object(forInfoDictionaryKey: "DictionarySHA256") as? String)?
            .trimmed
            .lowercased()
            .nilIfEmpty
    }

    nonisolated private static var minBytes: Int64 {
        (Bundle.main.object(forInfoDictionaryKey: "DictionaryMinBytes") as? Int).map(Int64.init) ?? (1 * 1024 * 1024)
    }

    @ObservationIgnored private var task: URLSessionDownloadTask?
    // The Observation macro rewrites stored properties; `lazy` doesn't survive it.
    @ObservationIgnored private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForResource = 60 * 60
        cfg.allowsCellularAccess = true
        cfg.allowsExpensiveNetworkAccess = true
        cfg.allowsConstrainedNetworkAccess = true
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    func start() {
        guard case .idle = state else { return }
        guard let remote = Self.remoteURL else {
            setState(.failed("No DictionaryDownloadURL in Info.plist."))
            return
        }
        if Self.isInstalled {
            setState(.done)
            return
        }
        setState(.downloading(bytesReceived: 0, bytesTotal: -1))
        let task = session.downloadTask(with: URLRequest(url: remote))
        self.task = task
        task.resume()
    }

    func cancel() {
        task?.cancel()
        setState(.failed("Download cancelled."))
    }

    nonisolated fileprivate func handleFinishedDownload(tempURL: URL) {
        Task {
            // A cancel can land right after the download finishes; the terminal
            // state latch would hide every later state change, so don't verify
            // and install behind the user's back.
            guard await isProcessing else {
                try? FileManager.default.removeItem(at: tempURL)
                return
            }
            var payloadURL = tempURL
            do {
                await setState(.verifying)
                if Self.remoteURL?.pathExtension.lowercased() == "gz" {
                    payloadURL = try Self.gunzip(tempURL)
                    try? FileManager.default.removeItem(at: tempURL)
                }
                let attrs = try FileManager.default.attributesOfItem(atPath: payloadURL.path)
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                if size < Self.minBytes {
                    throw DownloadError("Downloaded file is too small (\(size) bytes) — likely an HTML error page.")
                }
                if let expected = Self.expectedSHA256 {
                    let actual = try Self.sha256Hex(of: payloadURL)
                    if actual != expected {
                        throw DownloadError("Checksum mismatch (expected \(expected), got \(actual)).")
                    }
                }

                // Re-check after the long gunzip/hash phase: a cancel landing
                // meanwhile must not install behind a "cancelled" UI.
                guard await isProcessing else {
                    try? FileManager.default.removeItem(at: payloadURL)
                    return
                }
                await setState(.installing)
                guard let dest = Self.installedURL else {
                    throw DownloadError("Could not locate Application Support directory.")
                }
                try FileManager.default.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: dest.path) {
                    _ = try FileManager.default.replaceItemAt(dest, withItemAt: payloadURL)
                } else {
                    try FileManager.default.moveItem(at: payloadURL, to: dest)
                }
                if let expected = Self.expectedSHA256 {
                    UserDefaults.standard.set(expected, forKey: Self.installedSHAKey)
                }
                var resDest = dest
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? resDest.setResourceValues(values)

                DictionaryService.shared.reload()
                await setState(.done)
            } catch {
                // Verification/install failed: don't strand a ~60 MB payload in tmp.
                try? FileManager.default.removeItem(at: payloadURL)
                await setState(.failed(error.localizedDescription))
            }
        }
    }

    nonisolated fileprivate func handleTaskFailure(_ error: Error) {
        Task { await setState(.failed(error.localizedDescription)) }
    }

    private var isProcessing: Bool { !state.isTerminal }

    // The single owner of state transitions: terminal states are sticky, and
    // progress updates cannot resurrect a run that moved past downloading.
    private func setState(_ new: State) {
        guard !state.isTerminal else { return }
        if case .downloading = new {
            switch state {
            case .idle, .downloading: break
            default: return
            }
        }
        state = new
        // URLSession retains its delegate until invalidated.
        if new.isTerminal, task != nil {
            task = nil
            session.finishTasksAndInvalidate()
        }
    }

    // Streams gunzip on disk using Apple's Compression framework. RFC 1952 header parsing.
    nonisolated fileprivate static func gunzip(_ src: URL) throws -> URL {
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictionary-\(UUID().uuidString).sqlite")
        FileManager.default.createFile(atPath: dst.path, contents: nil)
        do {
            return try gunzip(src, into: dst)
        } catch {
            try? FileManager.default.removeItem(at: dst)  // don't leak a partial file
            throw error
        }
    }

    nonisolated private static func gunzip(_ src: URL, into dst: URL) throws -> URL {
        let inHandle = try FileHandle(forReadingFrom: src)
        defer { try? inHandle.close() }
        let outHandle = try FileHandle(forWritingTo: dst)
        defer { try? outHandle.close() }

        try skipGzipHeader(inHandle)

        let bufferSize = 256 * 1024
        let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { dstBuffer.deallocate() }

        let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPtr.deallocate() }
        guard compression_stream_init(streamPtr, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw DownloadError("Failed to init decompressor.")
        }
        defer { compression_stream_destroy(streamPtr) }

        streamPtr.pointee.src_size = 0
        streamPtr.pointee.dst_ptr = dstBuffer
        streamPtr.pointee.dst_size = bufferSize

        var inputChunk: Data = Data()
        var inputPtr: UnsafeMutablePointer<UInt8>? = nil
        defer { inputPtr?.deallocate() }
        var eof = false

        while true {
            if streamPtr.pointee.src_size == 0 && !eof {
                inputChunk = (try inHandle.read(upToCount: bufferSize)) ?? Data()
                if inputChunk.isEmpty {
                    eof = true
                } else {
                    inputPtr?.deallocate()
                    let p = UnsafeMutablePointer<UInt8>.allocate(capacity: inputChunk.count)
                    inputChunk.copyBytes(to: p, count: inputChunk.count)
                    inputPtr = p
                    streamPtr.pointee.src_ptr = UnsafePointer(p)
                    streamPtr.pointee.src_size = inputChunk.count
                }
            }

            let flags: Int32 = eof ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            let status = compression_stream_process(streamPtr, flags)

            let written = bufferSize - streamPtr.pointee.dst_size
            if written > 0 {
                let data = Data(bytes: dstBuffer, count: written)
                try outHandle.write(contentsOf: data)
                streamPtr.pointee.dst_ptr = dstBuffer
                streamPtr.pointee.dst_size = bufferSize
            }

            switch status {
            case COMPRESSION_STATUS_OK:
                continue
            case COMPRESSION_STATUS_END:
                return dst
            default:
                throw DownloadError("Decompression failed (status \(status.rawValue)).")
            }
        }
    }

    nonisolated private static func skipGzipHeader(_ h: FileHandle) throws {
        guard let magic = try h.read(upToCount: 2), magic.count == 2,
              magic[0] == 0x1f, magic[1] == 0x8b else {
            throw DownloadError("Not a gzip file.")
        }
        guard let cmFlg = try h.read(upToCount: 2), cmFlg.count == 2 else {
            throw DownloadError("Truncated gzip header.")
        }
        let flg = cmFlg[1]
        _ = try h.read(upToCount: 6)
        if flg & 0x04 != 0 {
            guard let xlenData = try h.read(upToCount: 2), xlenData.count == 2 else {
                throw DownloadError("Truncated FEXTRA header.")
            }
            let xlen = Int(xlenData[0]) | (Int(xlenData[1]) << 8)
            _ = try h.read(upToCount: xlen)
        }
        if flg & 0x08 != 0 {
            while let b = try h.read(upToCount: 1), b.count == 1, b[0] != 0 {}
        }
        if flg & 0x10 != 0 {
            while let b = try h.read(upToCount: 1), b.count == 1, b[0] != 0 {}
        }
        if flg & 0x02 != 0 {
            _ = try h.read(upToCount: 2)
        }
    }

    nonisolated private static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private struct DownloadError: LocalizedError {
    let message: String
    init(_ m: String) { self.message = m }
    var errorDescription: String? { message }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension DictionaryDownloader: URLSessionDownloadDelegate {

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            self.setState(.downloading(
                bytesReceived: totalBytesWritten,
                bytesTotal: totalBytesExpectedToWrite
            ))
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // The temp URL is deleted when this callback returns; copy synchronously first.
        let tempCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictionary-\(UUID().uuidString).sqlite")
        do {
            try FileManager.default.moveItem(at: location, to: tempCopy)
        } catch {
            handleTaskFailure(error)
            return
        }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: tempCopy)
            handleTaskFailure(DownloadError("HTTP \(http.statusCode) from server."))
            return
        }
        handleFinishedDownload(tempURL: tempCopy)
    }

    nonisolated func urlSession(_ session: URLSession,
                                task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let error else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        handleTaskFailure(error)
    }
}
