import AppKit
import AVFoundation
import SwiftUI

enum MediaTools {
    /// Writes a 640px JPEG poster frame for the video and returns its URL.
    static func makeThumbnail(for video: URL, id: String) async -> URL? {
        let asset = AVURLAsset(url: video)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        guard let result = try? await generator.image(at: CMTime(seconds: 0.8, preferredTimescale: 600)) else { return nil }
        let rep = NSBitmapImageRep(cgImage: result.image)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.75]) else { return nil }
        let url = AppPaths.thumbnailURL(for: id)
        try? data.write(to: url, options: .atomic)
        await ThumbnailCache.shared.invalidate(id)
        return url
    }

    static func duration(of video: URL) async -> TimeInterval {
        guard let time = try? await AVURLAsset(url: video).load(.duration), time.seconds.isFinite else { return 0 }
        return time.seconds
    }
}

/// In-memory + on-disk thumbnail cache. Falls back to Drive's thumbnail when the
/// entry was recorded on another Mac.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    var drive: DriveClient?
    private let memory = NSCache<NSString, NSImage>()
    private var failed = Set<String>()

    func invalidate(_ id: String) {
        memory.removeObject(forKey: id as NSString)
        failed.remove(id)
    }

    func image(for entry: DiaryEntry) async -> NSImage? {
        let key = entry.id as NSString
        if let img = memory.object(forKey: key) { return img }

        let file = AppPaths.thumbnailURL(for: entry.id)
        if let img = NSImage(contentsOf: file) {
            memory.setObject(img, forKey: key)
            return img
        }

        if let local = entry.localVideoURL, await MediaTools.makeThumbnail(for: local, id: entry.id) != nil,
           let img = NSImage(contentsOf: file) {
            memory.setObject(img, forKey: key)
            return img
        }

        guard !failed.contains(entry.id), let link = entry.thumbnailLink, let drive else { return nil }
        // Ask Drive for a larger rendition than the default 220px.
        let sized = link.replacingOccurrences(of: #"=s\d+$"#, with: "=s640", options: .regularExpression)
        guard let url = URL(string: sized),
              let data = try? await drive.authorizedData(from: url),
              let img = NSImage(data: data) else {
            failed.insert(entry.id)
            return nil
        }
        try? data.write(to: file, options: .atomic)
        memory.setObject(img, forKey: key)
        return img
    }
}

struct EntryThumbnail: View {
    let entry: DiaryEntry
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.12)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                Image(systemName: "video.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .clipped()
        .task(id: "\(entry.id)|\(entry.thumbnailLink ?? "")|\(entry.localFileName ?? "")") {
            let img = await ThumbnailCache.shared.image(for: entry)
            withAnimation(.easeOut(duration: 0.2)) { image = img }
        }
    }
}
