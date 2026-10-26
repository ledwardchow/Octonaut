import AVFoundation
import AVKit
import Combine
import CoreMedia
import SwiftUI

/// Minutes stay unpadded for short clips so a GIF reads "0:03", and pad out
/// once the total is long enough that a jumping label would be distracting.
private func mediaTimeLabel(_ seconds: Double, totalDuration: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds)
    let secondsPart = total % 60
    let minutesPart = (total / 60) % 60
    let hoursPart = total / 3600
    if hoursPart > 0 {
        return String(
            format: totalDuration >= 36_000 ? "%02d:%02d:%02d" : "%d:%02d:%02d",
            hoursPart, minutesPart, secondsPart
        )
    }
    if totalDuration >= 600 { return String(format: "%02d:%02d", minutesPart, secondsPart) }
    return String(format: "%d:%02d", minutesPart, secondsPart)
}

/// Keeps AirPlay available after dropping `AVPlayerViewController`, whose own
/// controls cannot be inset and so collided with the viewer's chrome.
struct OctonautAirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .white
        picker.activeTintColor = .systemBlue
        picker.backgroundColor = .clear
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

/// Transport controls the viewer owns and lays out, so they share one
/// visibility state with the rest of the chrome instead of competing with it.
///
/// Visibility is deliberately not handled here: the viewer already has a
/// `showOverlay` state driving its close button and title block, and this sits
/// inside that same stack.
@MainActor
struct OctonautPlayerControls: View {
    let player: AVPlayer
    @Binding var isMuted: Bool
    /// Restarts the viewer's auto-hide timer so the chrome does not vanish
    /// while a control is being used.
    var onInteraction: () -> Void = {}

    @State private var isPlaying: Bool
    @State private var currentTime: Double
    @State private var duration: Double
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0
    @State private var lastPreviewSeekAt: TimeInterval = 0
    @State private var scrubGeneration = 0
    /// Measured from the track itself so the fill and thumb use the track
    /// width rather than the full bar width including the time labels.
    @State private var trackWidth: CGFloat = 1
    /// Defaults to true so the mute button stays enabled until proven
    /// otherwise; a GIF resolved to mp4 has no audio track and disables it.
    @State private var hasAudio = true

    /// The chrome is torn down and rebuilt each time it auto-hides and
    /// reappears, which resets `@State`. Seeding from the player here means
    /// the very first frame already shows the real playhead, instead of
    /// rendering at zero and animating across to catch up.
    init(
        player: AVPlayer,
        isMuted: Binding<Bool>,
        onInteraction: @escaping () -> Void = {}
    ) {
        self.player = player
        self._isMuted = isMuted
        self.onInteraction = onInteraction

        let elapsed = player.currentTime().seconds
        _currentTime = State(initialValue: elapsed.isFinite && elapsed >= 0 ? elapsed : 0)

        let total = player.currentItem?.duration.seconds ?? 0
        _duration = State(initialValue: total.isFinite && total > 0 ? total : 1)

        _isPlaying = State(initialValue: player.timeControlStatus == .playing)
    }

    /// 0...1 playhead position. Clamped and NaN-guarded so `GeometryReader`
    /// never receives an invalid width during player transitions.
    private var progress: Double {
        let ratio = (isScrubbing ? scrubValue : currentTime) / max(duration, 1)
        guard ratio.isFinite else { return 0 }
        return min(max(ratio, 0), 1)
    }

    var body: some View {
        VStack(spacing: 10) {
            transportRow
            seekBar
        }
        // KVO publishers emit their current value on subscription, so these
        // initialise state correctly before any change fires.
        .onReceive(player.publisher(for: \.timeControlStatus)) { status in
            isPlaying = (status == .playing)
        }
        .onReceive(player.publisher(for: \.isMuted)) { muted in
            isMuted = muted
        }
        // maxPublishers: .max(1) acts as switch-to-latest: when the item
        // changes, the previous duration stream is abandoned.
        .onReceive(
            player.publisher(for: \.currentItem)
                .flatMap(maxPublishers: .max(1)) { item -> AnyPublisher<CMTime, Never> in
                    guard let item else { return Just(.zero).eraseToAnyPublisher() }
                    return item.publisher(for: \.duration).eraseToAnyPublisher()
                }
                .compactMap { time -> Double? in
                    let seconds = time.seconds
                    return (seconds.isFinite && seconds > 0) ? seconds : nil
                }
        ) { loaded in
            duration = loaded
        }
        .onReceive(
            player.publisher(for: \.currentItem)
                .flatMap(maxPublishers: .max(1)) { item -> AnyPublisher<Bool, Never> in
                    guard let item else { return Just(true).eraseToAnyPublisher() }
                    return item.publisher(for: \.tracks)
                        .map { tracks in tracks.contains { $0.assetTrack?.mediaType == .audio } }
                        .eraseToAnyPublisher()
                }
        ) { audio in
            hasAudio = audio
        }
        .onReceive(Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()) { _ in
            guard !isScrubbing else { return }
            let time = player.currentTime().seconds
            if time.isFinite, time >= 0 { currentTime = time }
        }
        // The viewer behind this is black whatever the system is set to, so
        // the chrome on top of it is dark whatever the system is set to.
        //
        // Glass takes its material from the colour scheme rather than from
        // what is behind it, so in light mode these capsules render pale --
        // under symbols and time labels that are white for the black surface
        // they sit on. Setting the scheme rather than tinting the glass: a
        // tint on interactive glass reads as a button stuck in its pressed
        // state, and the symbols would still be wrong on anything untinted.
        .environment(\.colorScheme, .dark)
    }

    private var transportRow: some View {
        HStack(spacing: 12) {
            GlassEffectContainer(spacing: 20) {
                OctonautAirPlayButton()
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular.interactive())
                    .accessibilityLabel("AirPlay")
            }

            Spacer()

            GlassEffectContainer(spacing: 20) {
                HStack(spacing: 2) {
                    Button { seek(by: -10) } label: {
                        Image(systemName: "gobackward.10")
                            .font(.body)
                            .frame(width: 40, height: 40)
                            .foregroundStyle(.white)
                    }
                    .glassEffect(.regular.interactive())
                    .accessibilityLabel("Back 10 seconds")

                    Button {
                        if isPlaying {
                            player.pause()
                        } else {
                            if duration > 0, player.currentTime().seconds >= duration - 0.05 {
                                player.seek(to: .zero)
                            }
                            player.play()
                        }
                        onInteraction()
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: 46, height: 46)
                            .foregroundStyle(.white)
                    }
                    .glassEffect(.regular.interactive())
                    .accessibilityLabel(isPlaying ? "Pause" : "Play")

                    Button { seek(by: 10) } label: {
                        Image(systemName: "goforward.10")
                            .font(.body)
                            .frame(width: 40, height: 40)
                            .foregroundStyle(.white)
                    }
                    .glassEffect(.regular.interactive())
                    .accessibilityLabel("Forward 10 seconds")
                }
            }

            Spacer()

            GlassEffectContainer(spacing: 20) {
                Button {
                    isMuted.toggle()
                    player.isMuted = isMuted
                    onInteraction()
                } label: {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.body)
                        .frame(width: 40, height: 40)
                        .foregroundStyle(.white)
                }
                .disabled(!hasAudio)
                .opacity(hasAudio ? 1 : 0.4)
                .glassEffect(.regular.interactive())
                .accessibilityLabel(isMuted ? "Unmute" : "Mute")
            }
        }
    }

    private var seekBar: some View {
        HStack(spacing: 8) {
            Text(mediaTimeLabel(isScrubbing ? scrubValue : currentTime, totalDuration: duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.3))
                    .frame(height: 3)
                // Linear during playback to match the 0.25s tick; instant while
                // scrubbing or paused so the bar reacts without lag.
                Capsule()
                    .fill(.white)
                    .frame(width: max(0, trackWidth * progress), height: 3)
                    .animation(
                        isScrubbing || !isPlaying ? .none : .linear(duration: 0.25),
                        value: progress
                    )
                Circle()
                    .fill(.white)
                    .frame(width: isScrubbing ? 16 : 10, height: isScrubbing ? 16 : 10)
                    .offset(x: max(0, trackWidth * progress - (isScrubbing ? 8 : 5)))
                    .shadow(color: .black.opacity(0.25), radius: 2)
                    .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isScrubbing)
                    .animation(
                        isScrubbing || !isPlaying ? .none : .linear(duration: 0.25),
                        value: progress
                    )
            }
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { trackWidth = max(1, geometry.size.width) }
                        .onChange(of: geometry.size.width) { _, width in
                            trackWidth = max(1, width)
                        }
                }
            )
            .frame(height: 28)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isScrubbing = true
                        scrubGeneration &+= 1
                        let ratio = value.location.x / trackWidth
                        scrubValue = min(max(ratio, 0), 1) * duration
                        // Preview the video during the drag. Limit seeks so a
                        // fast finger does not queue a request for every touch
                        // event, then use an exact seek on release.
                        let now = ProcessInfo.processInfo.systemUptime
                        if now - lastPreviewSeekAt >= 0.08 {
                            lastPreviewSeekAt = now
                            let previewTolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
                            player.seek(
                                to: CMTime(seconds: scrubValue, preferredTimescale: 600),
                                toleranceBefore: previewTolerance,
                                toleranceAfter: previewTolerance
                            )
                        }
                        onInteraction()
                    }
                    .onEnded { _ in
                        let target = scrubValue
                        let generation = scrubGeneration
                        lastPreviewSeekAt = 0
                        player.currentItem?.cancelPendingSeeks()
                        player.seek(
                            to: CMTime(seconds: target, preferredTimescale: 600),
                            toleranceBefore: .zero,
                            toleranceAfter: .zero
                        ) { _ in
                            Task { @MainActor in
                                guard scrubGeneration == generation else { return }
                                currentTime = target
                                isScrubbing = false
                            }
                        }
                        onInteraction()
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Playback position")
            .accessibilityValue(
                "\(mediaTimeLabel(currentTime, totalDuration: duration)) of "
                    + mediaTimeLabel(duration, totalDuration: duration)
            )

            Text(mediaTimeLabel(duration, totalDuration: duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)
        }
    }

    private func seek(by seconds: Double) {
        let target = min(max(player.currentTime().seconds + seconds, 0), duration)
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        onInteraction()
    }
}
