import AVKit
import SwiftUI

/// Wraps chips onto multiple lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = proposal.width ?? rows.map(\.width).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for row in rows {
            for (index, x) in row.items {
                subviews[index].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y), proposal: .unspecified)
            }
        }
    }

    private struct Row { var items: [(Int, CGFloat)] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if rows[rows.count - 1].width > 0, rows[rows.count - 1].width + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            let x = rows[rows.count - 1].width
            rows[rows.count - 1].items.append((i, x))
            rows[rows.count - 1].width = x + size.width + spacing
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows.map { var r = $0; r.width = max(0, r.width - spacing); return r }
    }
}

struct MoodPicker: View {
    @Binding var mood: Mood?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Mood.allCases) { option in
                let selected = mood == option
                Button {
                    withAnimation(.spring(duration: 0.25)) { mood = selected ? nil : option }
                } label: {
                    Text(option.emoji)
                        .font(.system(size: 24))
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.05)))
                        .overlay(Circle().strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
                        .scaleEffect(selected ? 1.08 : 1)
                        .saturation(mood == nil || selected ? 1 : 0.3)
                }
                .buttonStyle(.plain)
                .help(option.label)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

struct TagChip: View {
    let text: String
    var prominent = false

    var body: some View {
        Text("#\(text)")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(prominent ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.07)))
            .foregroundStyle(prominent ? Color.accentColor : .secondary)
    }
}

/// Title, mood, tags and notes. Used after recording and when editing an entry.
struct MetadataForm: View {
    @Binding var draft: EntryDraft
    let titlePlaceholder: String
    let suggestedTags: [String]
    var focusTitle = false
    @FocusState private var titleFocused: Bool

    private var unusedSuggestions: [String] {
        let current = Set(draft.tags.map { $0.lowercased() })
        return suggestedTags.filter { !current.contains($0.lowercased()) }.prefix(10).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            field("Title") {
                TextField(titlePlaceholder, text: $draft.title)
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                    .focused($titleFocused)
            }

            field("How are you feeling?") {
                MoodPicker(mood: $draft.mood)
            }

            field("Tags") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("work, family, gratitude", text: $draft.tagsText)
                        .textFieldStyle(.roundedBorder)
                    if !unusedSuggestions.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(unusedSuggestions, id: \.self) { tag in
                                Button {
                                    draft.tagsText = (draft.tags + [tag]).joined(separator: ", ")
                                } label: {
                                    Label(tag, systemImage: "plus")
                                        .font(.caption)
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(Capsule().strokeBorder(Color.secondary.opacity(0.4)))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            field("Notes") {
                TextEditor(text: $draft.notes)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 90, maxHeight: 180)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            }
        }
        .onAppear { if focusTitle { titleFocused = true } }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            content()
        }
    }
}

struct SyncBadge: View {
    let entry: DiaryEntry

    var body: some View {
        Group {
            switch entry.sync {
            case .synced:
                Image(systemName: "checkmark.icloud.fill").foregroundStyle(.white)
            case .pending:
                Image(systemName: "icloud.and.arrow.up").foregroundStyle(.white)
            case .uploading(let p):
                ZStack {
                    Circle().stroke(.white.opacity(0.35), lineWidth: 2.5)
                    Circle().trim(from: 0, to: max(0.03, p)).stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear, value: p)
                }
                .frame(width: 14, height: 14)
            case .failed:
                Image(systemName: "exclamationmark.icloud.fill").foregroundStyle(.yellow)
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .padding(6)
        .background(.black.opacity(0.45), in: Circle())
        .help(helpText)
    }

    private var helpText: String {
        switch entry.sync {
        case .synced: "Saved in Google Drive"
        case .pending: "Waiting to upload"
        case .uploading(let p): "Uploading… \(Int(p * 100))%"
        case .failed(let message): "Upload failed: \(message). It will retry automatically."
        }
    }
}

struct AudioMeter: View {
    let level: Float
    private let bars = 12

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<bars, id: \.self) { i in
                let threshold = Float(i) / Float(bars)
                Capsule()
                    .fill(level > threshold ? color(for: i) : Color.white.opacity(0.2))
                    .frame(width: 3, height: 6 + CGFloat(i) * 1.1)
            }
        }
        .animation(.linear(duration: 0.08), value: level)
        .accessibilityLabel("Microphone level")
    }

    private func color(for i: Int) -> Color {
        i < bars * 2 / 3 ? .green : (i < bars - 1 ? .yellow : .red)
    }
}

struct ToastView: View {
    let toast: Toast

    var body: some View {
        Label(toast.message, systemImage: toast.systemImage)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

struct PlayerView: NSViewRepresentable {
    let url: URL
    var autoplay = false

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        view.videoGravity = .resizeAspect
        load(url, into: view)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if (view.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            load(url, into: view)
        }
    }

    private func load(_ url: URL, into view: AVPlayerView) {
        view.player?.pause()
        let player = AVPlayer(url: url)
        view.player = player
        if autoplay { player.play() }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

extension Int64 {
    var byteString: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
