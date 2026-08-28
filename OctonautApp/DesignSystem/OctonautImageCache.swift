import Foundation
import UIKit

private actor OctonautImageDataCache {
    static let shared = OctonautImageDataCache()

    private let cache: URLCache
    private let session: URLSession
    private var inFlight: [URL: Task<Data, Error>] = [:]

    init() {
        let cache = URLCache(
            memoryCapacity: 64 * 1_024 * 1_024,
            diskCapacity: 500 * 1_024 * 1_024,
            diskPath: "OctonautImages"
        )
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = cache
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        self.cache = cache
        self.session = URLSession(configuration: configuration)
    }

    func data(for url: URL) async throws -> Data {
        if let task = inFlight[url] {
            return try await task.value
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad

        if let cached = cache.cachedResponse(for: request) {
            return cached.data
        }

        let task = Task { [session, cache] in
            let (data, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode) {
                throw URLError(.badServerResponse)
            }
            guard !data.isEmpty else { throw URLError(.zeroByteResource) }

            // Reddit's image hosts do not always return cache headers that are
            // useful to an app feed. Store a replaceable local copy explicitly.
            cache.storeCachedResponse(
                CachedURLResponse(response: response, data: data, storagePolicy: .allowed),
                for: request
            )
            return data
        }
        inFlight[url] = task

        do {
            let data = try await task.value
            inFlight[url] = nil
            return data
        } catch {
            inFlight[url] = nil
            throw error
        }
    }

    func configure(diskCapacityMB: Int) {
        cache.diskCapacity = max(diskCapacityMB, 1) * 1_024 * 1_024
    }

    func diskUsage() -> Int {
        cache.currentDiskUsage
    }

    func removeAll() {
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        cache.removeAllCachedResponses()
    }
}

@MainActor
enum OctonautImageCache {
    private static let decodedImages: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.totalCostLimit = 96 * 1_024 * 1_024
        return cache
    }()

    static func image(for url: URL) async throws -> UIImage {
        if let image = cachedImage(for: url) {
            return image
        }

        let data = try await OctonautImageDataCache.shared.data(for: url)
        guard !Task.isCancelled else { throw CancellationError() }
        guard let image = UIImage(data: data) else { throw URLError(.cannotDecodeContentData) }
        decodedImages.setObject(image, forKey: url as NSURL, cost: data.count)
        return image
    }

    static func cachedImage(for url: URL) -> UIImage? {
        decodedImages.object(forKey: url as NSURL)
    }

    static func configure(diskCapacityMB: Int) async {
        await OctonautImageDataCache.shared.configure(diskCapacityMB: diskCapacityMB)
    }

    static func diskUsage() async -> Int {
        await OctonautImageDataCache.shared.diskUsage()
    }

    static func removeAll() async {
        decodedImages.removeAllObjects()
        await OctonautImageDataCache.shared.removeAll()
    }
}
