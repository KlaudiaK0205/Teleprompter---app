import SwiftUI
import AVKit
import AVFoundation

// iOS nie pozwala na nakładki systemowe. Jedyne okno, które pływa nad innymi
// aplikacjami (aparat, Instagram, TikTok…), to Obraz w Obrazie (PiP).
// Okno „filmowe” (AVPlayer / sample buffer) iOS chowa i wyłącza, gdy inna aplikacja nagrywa aparatem.
// Okno „rozmowy wideo” (jak FaceTime) zostaje, więc używamy tego typu: w PiP jest zwykły,
// żywy widok z tekstem, przesuwany przez nas.

@main
struct TeleprompterApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

// Tekst rysowany w stałej skali 800×450 i powiększany/zmniejszany do rozmiaru okna.
final class TextView: UIView {
    static let size = CGSize(width: 800, height: 450)
    let label = UILabel()
    private let stage = UIView()

    var offset: CGFloat = 0 { didSet { setNeedsLayout() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        label.numberOfLines = 0
        stage.bounds = CGRect(origin: .zero, size: Self.size)
        stage.addSubview(label)
        addSubview(stage)
    }

    required init?(coder: NSCoder) { fatalError() }

    // ponytail: cały tekst w jednym UILabel; przy bardzo długich skryptach (>30 min czytania)
    // przejść na rysowanie tylko widocznego fragmentu.
    var textHeight: CGFloat {
        ceil(label.sizeThatFits(CGSize(width: Self.size.width - 64, height: .greatestFiniteMagnitude)).height)
    }

    override func layoutSubviews() {
        stage.center = CGPoint(x: bounds.midX, y: bounds.midY)
        let s = min(bounds.width / Self.size.width, bounds.height / Self.size.height)
        stage.transform = CGAffineTransform(scaleX: s, y: s)
        label.frame = CGRect(x: 32, y: Self.size.height * 0.35 - offset, width: Self.size.width - 64, height: textHeight)
    }
}

struct Preview: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

final class Prompter: NSObject, ObservableObject {
    let inline = TextView()
    @Published var isPlaying = false
    var speed = 50.0 // punkty na sekundę (w skali 800×450)

    private let floating = TextView()
    private let call = AVPictureInPictureVideoCallViewController()
    private var pip: AVPictureInPictureController?
    private let engine = AVAudioEngine()
    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0
    private var end: CGFloat = 0
    private var offset: CGFloat = 0 {
        didSet { inline.offset = offset; floating.offset = offset }
    }

    override init() {
        super.init()
        // Sesja jak w aplikacji do rozmów wideo. mixWithOthers: nie przerywa dźwięku ani nagrywania TikToka.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .videoChat, options: [.mixWithOthers, .defaultToSpeaker])
        try? session.setActive(true)
        startSilence()

        call.preferredContentSize = TextView.size
        floating.frame = call.view.bounds
        floating.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        call.view.addSubview(floating)
        // Stuknięcie w tekst = start/pauza (w aplikacji i — jeśli iOS przepuści dotyk — w pływającym oknie).
        inline.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggle)))
        floating.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggle)))

        if AVPictureInPictureController.isPictureInPictureSupported() {
            pip = AVPictureInPictureController(contentSource: .init(activeVideoCallSourceView: inline, contentViewController: call))
            pip?.canStartPictureInPictureAutomaticallyFromInline = true
        }
    }

    // Cisza w głośniku trzyma aplikację przy życiu w tle, żeby tekst dalej się przesuwał.
    // TikTok przestawia audio (AVAudioEngineConfigurationChange) i silnik staje — wtedy go wznawiamy.
    private func startSilence() {
        let silence = AVAudioSourceNode { _, _, _, buffers in
            for b in UnsafeMutableAudioBufferListPointer(buffers) { memset(b.mData, 0, Int(b.mDataByteSize)) }
            return noErr
        }
        engine.attach(silence)
        engine.connect(silence, to: engine.mainMixerNode, format: nil)
        try? engine.start()
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            try? self?.engine.start()
        }
    }

    func setText(_ text: String, fontSize: Double) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineSpacing = fontSize * 0.25
        let str = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: UIColor.white,
            .paragraphStyle: para,
        ])
        inline.label.attributedText = str
        floating.label.attributedText = str
        end = TextView.size.height * 0.35 + inline.textHeight // ostatnia linia wyjeżdża poza górę
        offset = min(offset, end)
    }

    @objc func toggle() {
        if let timer {
            timer.invalidate()
            self.timer = nil
            isPlaying = false
            return
        }
        if offset >= end { offset = 0 }
        lastTick = CACurrentMediaTime()
        let t = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        isPlaying = true
    }

    private func tick() {
        let now = CACurrentMediaTime()
        offset = min(offset + CGFloat(speed * (now - lastTick)), end)
        lastTick = now
        if offset >= end { toggle() }
    }

    func rewind() {
        offset = 0
    }

    func togglePiP() {
        guard let pip else { return }
        pip.isPictureInPictureActive ? pip.stopPictureInPicture() : pip.startPictureInPicture()
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
            Preview(view: prompter.inline)
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(.black)
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
