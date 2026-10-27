import SwiftUI
import AVKit
import AVFoundation

// iOS nie pozwala na nakładki systemowe. Jedyne okno, które pływa nad innymi
// aplikacjami (aparat, Instagram, TikTok…), to Obraz w Obrazie (PiP).
// Tekst zapisujemy jako prawdziwy film i odtwarzamy go AVPlayerem w PiP. Taki film
// odtwarza sam system, więc ▶︎/⏸ działa nawet wtedy, gdy TikTok przejmie dźwięk.
// (Wcześniejsza wersja z rysowaniem na żywo do AVSampleBufferDisplayLayer była nad TikTokiem wyłączana przez iOS.)

@main
struct TeleprompterApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
}

struct Preview: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

final class Prompter: NSObject, ObservableObject {
    static let width = 800, height = 450
    static let fps: Int32 = 30
    static let base = 50.0 // piksele na sekundę przy normalnej prędkości filmu; suwak zmienia tempo odtwarzania

    let view = PreviewView()
    let player = AVPlayer()
    @Published var isPlaying = false
    @Published var isPreparing = false
    var speed = base {
        didSet {
            player.defaultRate = Float(speed / Self.base) // tego tempa używa też ▶︎ w oknie PiP
            if player.rate > 0 { player.rate = player.defaultRate }
        }
    }

    private var pip: AVPictureInPictureController?
    private var job: Task<Void, Never>?
    private var file: URL?
    private var statusObservation: NSKeyValueObservation?

    override init() {
        super.init()
        // mixWithOthers: nie przerywa dźwięku TikToka ani nagrywania. Film nie ma ścieżki audio.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: .mixWithOthers)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.isMuted = true
        player.actionAtItemEnd = .pause
        let layer = view.layer as! AVPlayerLayer
        layer.player = player
        layer.videoGravity = .resizeAspect
        if AVPictureInPictureController.isPictureInPictureSupported() {
            pip = AVPictureInPictureController(playerLayer: layer)
            // Wyjście na ekran główny / do innej aplikacji w trakcie przewijania samo otwiera pływające okno.
            pip?.canStartPictureInPictureAutomaticallyFromInline = true
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] p, _ in
            DispatchQueue.main.async { self?.isPlaying = p.timeControlStatus != .paused }
        }
    }

    func setText(_ text: String, fontSize: Double) {
        job?.cancel()
        isPreparing = true
        job = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600)) // nie kodujemy filmu przy każdej literze
            guard !Task.isCancelled, let page = Self.renderPage(text, fontSize: fontSize) else { return }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
            do {
                try await Self.encode(page, to: url)
            } catch {
                if !Task.isCancelled { await MainActor.run { self?.isPreparing = false } }
                return
            }
            await MainActor.run { self?.show(url) }
        }
    }

    func toggle() {
        if player.rate > 0 { return player.pause() }
        if let item = player.currentItem, item.duration.isNumeric, item.currentTime() >= item.duration {
            player.seek(to: .zero)
        }
        player.play()
    }

    func rewind() {
        player.seek(to: .zero)
    }

    func togglePiP() {
        guard let pip else { return }
        pip.isPictureInPictureActive ? pip.stopPictureInPicture() : pip.startPictureInPicture()
    }

    private func show(_ url: URL) {
        let time = player.currentTime()
        let wasPlaying = player.rate > 0
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        if wasPlaying { player.play() }
        if let file { try? FileManager.default.removeItem(at: file) }
        file = url
        isPreparing = false
    }

    // ponytail: cały tekst jako jeden obraz (~1,4 MB na 1000 px wysokości); przy bardzo długich
    // skryptach (>30 min czytania) przejść na renderowanie tylko widocznego fragmentu.
    private static func renderPage(_ text: String, fontSize: Double) -> CGImage? {
        let w = CGFloat(width), h = CGFloat(height), pad: CGFloat = 32
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineSpacing = fontSize * 0.25
        let str = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: UIColor.white,
            .paragraphStyle: para,
        ])
        let textH = ceil(str.boundingRect(with: CGSize(width: w - 2 * pad, height: .greatestFiniteMagnitude),
                                          options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height)
        let top = h * 0.35
        let total = top + textH + h // dół = pusty ekran, żeby ostatnia linia mogła wyjechać
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: total), format: format).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: total))
            str.draw(with: CGRect(x: pad, y: top, width: w - 2 * pad, height: textH),
                     options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        }.cgImage
    }

    // Film: kadr 800×450 przesuwa się po obrazie z tekstem o `base / fps` pikseli na klatkę.
    private static func encode(_ page: CGImage, to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CancellationError() }
        writer.startSession(atSourceTime: .zero)

        let step = base / Double(fps)
        let maxOffset = Double(page.height - height)
        do {
            for i in 0...Int(maxOffset / step) {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
                guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? CancellationError() }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                guard let buffer else { continue }
                draw(page, offset: min(Double(i) * step, maxOffset), into: buffer)
                _ = adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
            }
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CancellationError() }
    }

    private static func draw(_ page: CGImage, offset: Double, into buffer: CVPixelBuffer) {
        guard let visible = page.cropping(to: CGRect(x: 0, y: Int(offset), width: width, height: height)) else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        ctx?.draw(visible, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
}

struct ContentView: View {
    @StateObject private var prompter = Prompter()
    @AppStorage("script") private var script = "Wklej tutaj swój tekst.\n\nNaciśnij „Pływające okno”, a potem przejdź do aparatu lub dowolnej innej aplikacji — tekst zostanie na wierzchu."
    @AppStorage("fontSize") private var fontSize = 48.0
    @AppStorage("speed") private var speed = 50.0
    @FocusState private var editing: Bool

    var body: some View {
        VStack(spacing: 14) {
            Preview(view: prompter.view)
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(.black)
                .overlay { if prompter.isPreparing { ProgressView().tint(.white) } }
                .clipShape(RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 12) {
                Button { prompter.rewind() } label: { Image(systemName: "backward.end.fill") }
                    .accessibilityLabel("Na początek")
                Button { prompter.toggle() } label: {
                    Image(systemName: prompter.isPlaying ? "pause.fill" : "play.fill")
                }
                .accessibilityLabel(prompter.isPlaying ? "Pauza" : "Start")
                Button { prompter.togglePiP() } label: { Label("Pływające okno", systemImage: "pip.enter") }
                    .buttonStyle(.borderedProminent)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(prompter.isPreparing)

            LabeledContent("Prędkość") { Slider(value: $speed, in: 10...200) }
            LabeledContent("Czcionka") { Slider(value: $fontSize, in: 24...96) }

            TextEditor(text: $script)
                .focused($editing)
                .padding(8)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.secondary.opacity(0.4)))
        }
        .padding()
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Gotowe") { editing = false }
            }
        }
        .onAppear {
            prompter.speed = speed
            prompter.setText(script, fontSize: fontSize)
        }
        .onChange(of: script) { prompter.setText(script, fontSize: fontSize) }
        .onChange(of: fontSize) { prompter.setText(script, fontSize: fontSize) }
        .onChange(of: speed) { prompter.speed = speed }
    }
}
