import AVFoundation
import Foundation

actor AVFoundationMediaService: MediaService {
    private let fileManager: FileManager
    private let session: URLSession
    private let exportDirectory: URL
    private let downloadDirectory: URL

    init(fileManager: FileManager = .default, session: URLSession? = nil) {
        self.fileManager = fileManager
        self.session = session ?? Self.makeDownloadSession()
        exportDirectory = fileManager.temporaryDirectory.appending(path: "OctonautMediaExports", directoryHint: .isDirectory)
        downloadDirectory = fileManager.temporaryDirectory.appending(path: "OctonautMediaDownloads", directoryHint: .isDirectory)
        try? fileManager.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
        Self.removeExpiredExports(in: exportDirectory, fileManager: fileManager)
        Self.removeExpiredExports(in: downloadDirectory, fileManager: fileManager)
    }

    func exportVideo(source: URL, audio: URL?, cleanupDate: Date?) async throws -> ExportJob {
        let id = UUID()
        let outputURL = exportDirectory.appending(path: "\(id.uuidString).mp4")
        var videoSource = source
        var audioSource = audio
        do {
            if let dashMedia = try await redditDASHMedia(for: source) {
                videoSource = dashMedia.video
                audioSource = dashMedia.audio
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Older Reddit posts may no longer have a DASH manifest. The
            // media URL from the listing remains the fallback in that case.
        }

        let localVideo = try await localMedia(for: videoSource)
        var filesToRemove = localVideo.isTemporary ? [localVideo.url] : []
        defer { filesToRemove.forEach { try? fileManager.removeItem(at: $0) } }

        var localAudioURL: URL?
        if let audioSource {
            do {
                let localAudio = try await localMedia(for: audioSource)
                localAudioURL = localAudio.url
                if localAudio.isTemporary { filesToRemove.append(localAudio.url) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Some Reddit posts advertise an audio rendition that no
                // longer exists. Saving the video is still useful in that case.
                localAudioURL = nil
            }
        }

        let asset = try await exportAsset(videoURL: localVideo.url, audioURL: localAudioURL)

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw DisplayableError(title: "Could not export video", message: "This video format cannot be exported.", isRetryable: false)
        }

        do {
            try await session.export(to: outputURL, as: .mp4)
            return ExportJob(
                id: id,
                progress: 1,
                outputURL: outputURL,
                isComplete: true,
                cleanupDate: cleanupDate ?? Calendar.current.date(byAdding: .day, value: 1, to: .now)
            )
        } catch is CancellationError {
            session.cancelExport()
            try? fileManager.removeItem(at: outputURL)
            throw CancellationError()
        } catch {
            try? fileManager.removeItem(at: outputURL)
            throw DisplayableError(title: "Could not export video", message: error.localizedDescription)
        }
    }

    func cancelExport(_ id: UUID) async {
        let outputURL = exportDirectory.appending(path: "\(id.uuidString).mp4")
        try? fileManager.removeItem(at: outputURL)
    }

    private func exportAsset(videoURL: URL, audioURL: URL?) async throws -> AVAsset {
        guard let audioURL, audioURL != videoURL else {
            return AVURLAsset(url: videoURL)
        }

        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)
        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        guard let videoTrack = videoTracks.first else {
            throw DisplayableError(title: "Could not export video", message: "The video stream has no video track.", isRetryable: false)
        }

        let videoDuration = try await videoAsset.load(.duration)
        let composition = AVMutableComposition()
        guard let compositionVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw DisplayableError(title: "Could not export video", message: "A video track could not be created.", isRetryable: false)
        }
        try compositionVideo.insertTimeRange(
            CMTimeRange(start: .zero, duration: videoDuration),
            of: videoTrack,
            at: .zero
        )
        compositionVideo.preferredTransform = try await videoTrack.load(.preferredTransform)

        if let audioTrack = audioTracks.first,
           let compositionAudio = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            let audioDuration = try await audioAsset.load(.duration)
            try compositionAudio.insertTimeRange(
                CMTimeRange(start: .zero, duration: CMTimeMinimum(videoDuration, audioDuration)),
                of: audioTrack,
                at: .zero
            )
        }
        return composition
    }

    private func redditDASHMedia(for sourceURL: URL) async throws -> RedditDASHManifest.Media? {
        guard let manifestURL = RedditDASHManifest.manifestURL(for: sourceURL) else { return nil }
        let request = try MediaDownloadTransport.request(for: manifestURL)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
        try MediaDownloadTransport.validate(response)
        return RedditDASHManifest.media(from: data, manifestURL: manifestURL)
    }

    private struct LocalMedia {
        let url: URL
        let isTemporary: Bool
    }

    private func localMedia(for sourceURL: URL) async throws -> LocalMedia {
        guard !sourceURL.isFileURL else {
            return LocalMedia(url: sourceURL, isTemporary: false)
        }

        // A downloaded HLS playlist cannot be moved away from its segment
        // URLs. AVFoundation must continue to resolve that asset remotely.
        guard sourceURL.pathExtension.lowercased() != "m3u8" else {
            return LocalMedia(url: sourceURL, isTemporary: false)
        }

        let request = try MediaDownloadTransport.request(for: sourceURL)
        let temporaryURL: URL
        let response: URLResponse
        do {
            (temporaryURL, response) = try await session.download(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DisplayableError(
                title: "Could not download video",
                message: "The video could not be downloaded. Try again."
            )
        }

        try MediaDownloadTransport.validate(response)
        let fileExtension = MediaDownloadTransport.fileExtension(for: sourceURL, response: response)
        let localURL = downloadDirectory
            .appending(path: UUID().uuidString)
            .appendingPathExtension(fileExtension)
        do {
            try fileManager.moveItem(at: temporaryURL, to: localURL)
            return LocalMedia(url: localURL, isTemporary: true)
        } catch {
            throw DisplayableError(
                title: "Could not download video",
                message: "The downloaded video could not be prepared. Try again."
            )
        }
    }

    private nonisolated static func makeDownloadSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 5 * 60
        return URLSession(
            configuration: configuration,
            delegate: MediaDownloadRedirectDelegate(),
            delegateQueue: nil
        )
    }

    private nonisolated static func removeExpiredExports(in exportDirectory: URL, fileManager: FileManager) {
        let cutoff = Date.now.addingTimeInterval(-24 * 60 * 60)
        guard let files = try? fileManager.contentsOfDirectory(
            at: exportDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        for file in files {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
            if let modified = values?.contentModificationDate, modified < cutoff {
                try? fileManager.removeItem(at: file)
            }
        }
    }
}

enum MediaDownloadTransport {
    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1"

    static func request(for url: URL) throws -> URLRequest {
        guard url.scheme?.lowercased() == "https" else {
            throw DisplayableError(
                title: "Could not download video",
                message: "Videos can only be downloaded over HTTPS.",
                isRetryable: false
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("video/*,audio/*,application/vnd.apple.mpegurl,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if isRedditMediaHost(url.host) {
            request.setValue("https://www.reddit.com/", forHTTPHeaderField: "Referer")
        }
        return request
    }

    static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw DisplayableError(
                title: "Could not download video",
                message: "The video server did not provide the file. Try again."
            )
        }
    }

    static func fileExtension(for sourceURL: URL, response: URLResponse) -> String {
        if let suggestedExtension = response.suggestedFilename.flatMap({ URL(filePath: $0).pathExtension }),
           !suggestedExtension.isEmpty {
            return suggestedExtension
        }
        if !sourceURL.pathExtension.isEmpty {
            return sourceURL.pathExtension
        }
        switch response.mimeType?.lowercased() {
        case "audio/mp4", "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        default: return "mp4"
        }
    }

    private static func isRedditMediaHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "v.redd.it"
            || host == "redditmedia.com"
            || host.hasSuffix(".redditmedia.com")
    }
}

enum RedditDASHManifest {
    struct Media: Equatable {
        let video: URL
        let audio: URL?
    }

    static func manifestURL(for mediaURL: URL) -> URL? {
        guard mediaURL.scheme?.lowercased() == "https",
              mediaURL.host?.lowercased() == "v.redd.it",
              var components = URLComponents(url: mediaURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let path = components.path as NSString
        let basePath = path.pathExtension.isEmpty
            ? components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            : path.deletingLastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !basePath.isEmpty else { return nil }
        components.path = "/\(basePath)/DASHPlaylist.mpd"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    static func media(from data: Data, manifestURL: URL) -> Media? {
        let delegate = ParserDelegate(manifestURL: manifestURL)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return nil }

        let video = delegate.tracks
            .filter { !$0.isAudio }
            .max { lhs, rhs in
                lhs.height == rhs.height
                    ? lhs.bandwidth < rhs.bandwidth
                    : lhs.height < rhs.height
            }
        let audio = delegate.tracks
            .filter(\.isAudio)
            .max { $0.bandwidth < $1.bandwidth }
        guard let video else { return nil }
        return Media(video: video.url, audio: audio?.url)
    }

    private struct Track {
        let url: URL
        let isAudio: Bool
        let height: Int
        let bandwidth: Int
    }

    private final class ParserDelegate: NSObject, XMLParserDelegate {
        private struct Representation {
            let contentType: String?
            let height: Int
            let bandwidth: Int
        }

        let manifestURL: URL
        var tracks: [Track] = []
        private var adaptationContentType: String?
        private var representation: Representation?
        private var baseURLText = ""
        private var isReadingBaseURL = false

        init(manifestURL: URL) {
            self.manifestURL = manifestURL
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            switch elementName {
            case "AdaptationSet":
                adaptationContentType = contentType(from: attributeDict)
            case "Representation":
                representation = Representation(
                    contentType: contentType(from: attributeDict) ?? adaptationContentType,
                    height: Int(attributeDict["height"] ?? "") ?? 0,
                    bandwidth: Int(attributeDict["bandwidth"] ?? "") ?? 0
                )
            case "BaseURL" where representation != nil:
                isReadingBaseURL = true
                baseURLText = ""
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if isReadingBaseURL { baseURLText += string }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            switch elementName {
            case "BaseURL":
                defer {
                    isReadingBaseURL = false
                    baseURLText = ""
                }
                guard let representation,
                      let url = trackURL(from: baseURLText) else { return }
                tracks.append(
                    Track(
                        url: url,
                        isAudio: representation.contentType == "audio"
                            || baseURLText.localizedCaseInsensitiveContains("audio"),
                        height: representation.height,
                        bandwidth: representation.bandwidth
                    )
                )
            case "Representation":
                representation = nil
            case "AdaptationSet":
                adaptationContentType = nil
            default:
                break
            }
        }

        private func contentType(from attributes: [String: String]) -> String? {
            (attributes["contentType"] ?? attributes["mimeType"]?.split(separator: "/").first.map(String.init))?
                .lowercased()
        }

        private func trackURL(from value: String) -> URL? {
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty,
                  let url = URL(string: value, relativeTo: manifestURL)?.absoluteURL,
                  url.scheme?.lowercased() == "https" else {
                return nil
            }
            return url
        }
    }
}

private final class MediaDownloadRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let redirectURL = request.url,
              redirectURL.scheme?.lowercased() == "https" else {
            completionHandler(nil)
            return
        }
        guard var safeRequest = try? MediaDownloadTransport.request(for: redirectURL) else {
            completionHandler(nil)
            return
        }
        if let referer = task.originalRequest?.value(forHTTPHeaderField: "Referer") {
            safeRequest.setValue(referer, forHTTPHeaderField: "Referer")
        }
        completionHandler(safeRequest)
    }
}
