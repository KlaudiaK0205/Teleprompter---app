import SwiftUI
import AVKit
import AVFoundation

// iOS nie pozwala na nakładki systemowe. Jedyne okno, które pływa nad innymi
// aplikacjami (aparat, Instagram, TikTok…), to Obraz w Obrazie (PiP).
// Dlatego tekst renderujemy jako „wideo” do AVSampleBufferDisplayLayer i wysyłamy do PiP.

@main
struct TeleprompterApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
}

struct Preview: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

final class Prompter: NSObject, ObservableObject, AVPictureInPictureSampleBufferPlaybackDelegate {
    static let width = 800, height = 450

    let view = PreviewView()
    var displayLayer: AVSampleBufferDisplayLayer { view.layer as! AVSampleBufferDisplayLayer }
    @Published var isPlaying = false
    var speed = 60.0 // piksele na sekundę

    private var pip: AVPictureInPictureController?
    private var page: CGImage?
    private var offset = 0.0
    private var last = CACurrentMediaTime()
    private var pool: CVPixelBufferPool?
    private let engine = AVAudioEngine()
    private let silence = AVAudioPlayerNode()
    // DIAGNOSTYKA: żółta linijka na dole okna PiP. Usunąć po znalezieniu problemu z TikTokiem.
    private var frame = 0
    private var events: [String] = []
    private func log(_ s: String) { events = Array((events + ["\(frame):\(s)"]).suffix(3)) }

    override init() {
        super.init()
        setUpSilence()
        displayLayer.videoGravity = .resizeAspect
        if AVPictureInPictureController.isPictureInPictureSupported() {
            pip = AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self))
            // Wyjście na ekran główny / do innej aplikacji samo otwiera pływające okno.
            pip?.canStartPictureInPictureAutomaticallyFromInline = true
        }
        // Timer, nie CADisplayLink: działa też w tle, gdy PiP jest aktywne.
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
    }

    // iOS usypia aplikację w tle, gdy inna (np. TikTok) zabierze dźwięk — wtedy PiP zamarza.
    // Grająca w pętli cisza, zmiksowana z innymi, utrzymuje aplikację przy życiu,
    // nie przerywa dźwięku TikToka i nie trafia do nagrania.
    private func setUpSilence() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: .mixWithOthers)
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.attach(silence)
        engine.connect(silence, to: engine.mainMixerNode, format: format)
        silence.volume = 0
        if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)) {
            buffer.frameLength = buffer.frameCapacity
            silence.scheduleBuffer(buffer, at: nil, options: .loops)
        }
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let began = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
            self?.log(began ? "przerwa+" : "przerwa-")
            self?.startSilence()
        }
        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            self?.log("cfg")
            self?.startSilence()
        }
        startSilence()
    }

    private func startSilence() {
        do { try AVAudioSession.sharedInstance().setActive(true) } catch { log("sesja err \((error as NSError).code)") }
        if !engine.isRunning {
            do { try engine.start() } catch { log("engine err \((error as NSError).code)") }
        }
        if engine.isRunning && !silence.isPlaying { silence.play() }
    }

    private var maxOffset: Double { Double((page?.height ?? Self.height) - Self.height) }

    // ponytail: cały tekst jako jeden obraz (~1,4 MB na 1000 px wysokości); przy bardzo długich
    // skryptach (>30 min czytania) przejść na renderowanie tylko widocznego fragmentu.
    func setText(_ text: String, fontSize: Double) {
        let w = CGFloat(Self.width), h = CGFloat(Self.height), pad: CGFloat = 32
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
        page = UIGraphicsImageRenderer(size: CGSize(width: w, height: total), format: format).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: total))
            str.draw(with: CGRect(x: pad, y: top, width: w - 2 * pad, height: textH),
                     options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        }.cgImage
        offset = min(offset, maxOffset)
        draw()
    }

    func toggle() {
        isPlaying.toggle()
        pip?.invalidatePlaybackState()
    }

    func rewind() {
        offset = 0
        draw()
    }

    func togglePiP() {
        guard let pip else { return }
        pip.isPictureInPictureActive ? pip.stopPictureInPicture() : pip.startPictureInPicture()
    }

    private func tick() {
        let now = CACurrentMediaTime()
        defer { last = now }
        if isPlaying {
            offset = min(offset + speed * (now - last), maxOffset)
            if offset >= maxOffset {
                isPlaying = false
                pip?.invalidatePlaybackState()
            }
        }
        draw() // także w pauzie, żeby licznik klatek pokazywał, czy aplikacja żyje
    }

    private func draw() {
        guard let page, let visible = page.cropping(to: CGRect(x: 0, y: Int(offset), width: Self.width, height: Self.height)) else { return }
        if pool == nil {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: Self.width,
                kCVPixelBufferHeightKey: Self.height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        }
        var buffer: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return }

        CVPixelBufferLockBaseAddress(buffer, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Self.width, height: Self.height,
                            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        ctx?.draw(visible, in: CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
        if let ctx {
            frame += 1
            let s = AVAudioSession.sharedInstance()
            let status = "#\(frame) play:\(isPlaying ? 1 : 0) eng:\(engine.isRunning ? 1 : 0) inne:\(s.isOtherAudioPlaying ? 1 : 0) | "
                + events.joined(separator: " · ")
            ctx.saveGState()
            ctx.translateBy(x: 0, y: CGFloat(Self.height))
            ctx.scaleBy(x: 1, y: -1)
            UIGraphicsPushContext(ctx)
            (status as NSString).draw(at: CGPoint(x: 8, y: CGFloat(Self.height) - 26), withAttributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 16, weight: .regular),
                .foregroundColor: UIColor.yellow,
            ])
            UIGraphicsPopContext()
            ctx.restoreGState()
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if displayLayer.status == .failed { displayLayer.flush() }
        displayLayer.enqueue(sample)
    }

    // MARK: przyciski w oknie PiP

    func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {
        log("set\(playing ? 1 : 0)")
        // ponytail: zgadujemy, że to iOS pauzuje nas, gdy inna aplikacja gra dźwięk — wtedy przewijamy dalej.
        // Ceną jest brak pauzy w tej sytuacji; diagnostyka pokaże, czy założenie jest trafne.
        if !playing && UIApplication.shared.applicationState == .background && AVAudioSession.sharedInstance().isOtherAudioPlaying {
            log("ignor")
            c.invalidatePlaybackState()
            return
        }
        if playing { startSilence() }
        isPlaying = playing
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity) // „na żywo” = brak paska postępu
    }

    func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool {
        !isPlaying
    }

    func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        offset = min(max(0, offset + skipInterval.seconds * speed), maxOffset)
        draw()
        completionHandler()
    }
}

struct ContentView: View {
    @StateObject private var prompter = Prompter()
    @AppStorage("script") private var script = "Wklej tutaj swój tekst.\n\nNaciśnij „Pływające okno”, a potem przejdź do aparatu lub dowolnej innej aplikacji — tekst zostanie na wierzchu."
    @AppStorage("fontSize") private var fontSize = 48.0
    @AppStorage("speed") private var speed = 60.0
    @FocusState private var editing: Bool

    var body: some View {
        VStack(spacing: 14) {
            Preview(view: prompter.view)
                .aspectRatio(16 / 9, contentMode: .fit)
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

            LabeledContent("Prędkość") { Slider(value: $speed, in: 10...250) }
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
