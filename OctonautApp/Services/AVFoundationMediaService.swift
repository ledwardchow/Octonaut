import AVFoundation
import Foundation

actor AVFoundationMediaService: MediaService {
    private let fileManager: FileManager
    private let exportDirectory: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        exportDirectory = fileManager.temporaryDirectory.appending(path: "OctonautMediaExports", directoryHint: .isDirectory)
        try? fileManager.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        Self.removeExpiredExports(in: exportDirectory, fileManager: fileManager)
    }

    func exportVideo(source: URL, audio: URL?, cleanupDate: Date?) async throws -> ExportJob {
        let id = UUID()
        let outputURL = exportDirectory.appending(path: "\(id.uuidString).mp4")
        let asset = try await exportAsset(videoURL: source, audioURL: audio)

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
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
