import SwiftUI
import AVKit
import AVFoundation
import Speech

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

// Tekst rysowany w stałej szerokości 800 i powiększany/zmniejszany do rozmiaru okna.
final class TextView: UIView {
    static let width: CGFloat = 800, pad: CGFloat = 32
    let label = UILabel()
    private let stage = UIView()

    var offset: CGFloat = 0 { didSet { setNeedsLayout() } }
    var stageHeight: CGFloat = 450 {
        didSet { stage.bounds.size.height = stageHeight; setNeedsLayout() }
    }
    var readingLine: CGFloat { stageHeight * 0.35 } // tu stoi czytana linijka

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        label.numberOfLines = 0
        stage.bounds = CGRect(x: 0, y: 0, width: Self.width, height: stageHeight)
        stage.addSubview(label)
        addSubview(stage)
    }

    required init?(coder: NSCoder) { fatalError() }

    // ponytail: cały tekst w jednym UILabel; przy bardzo długich skryptach (>30 min czytania)
    // przejść na rysowanie tylko widocznego fragmentu.
    var textHeight: CGFloat {
        ceil(label.sizeThatFits(CGSize(width: Self.width - 2 * Self.pad, height: .greatestFiniteMagnitude)).height)
    }

    override func layoutSubviews() {
        stage.center = CGPoint(x: bounds.midX, y: bounds.midY)
        let s = min(bounds.width / Self.width, bounds.height / stageHeight)
        stage.transform = CGAffineTransform(scaleX: s, y: s)
        label.frame = CGRect(x: Self.pad, y: readingLine - offset, width: Self.width - 2 * Self.pad, height: textHeight)
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
    var speed = 50.0 // punkty na sekundę (w skali szerokości 800)
    var followVoice = false {
        didSet {
            if followVoice && !oldValue {
                SFSpeechRecognizer.requestAuthorization { _ in }
                AVAudioApplication.requestRecordPermission { _ in }
            }
            if isPlaying && followVoice != oldValue { toggle() }
        }
    }

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

    // Przewijanie za głosem
    // ponytail: język rozpoznawania na sztywno polski; dodać wybór, gdy pojawią się skrypty w innych językach.
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "pl-PL"))
    private let mic = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var words: [String] = []   // słowa skryptu, bez wielkich liter i ogonków
    private var tops: [CGFloat] = []   // pozycja linijki każdego słowa
    private var cursor = 0             // ostatnie rozpoznane słowo skryptu
    private var target: CGFloat = 0

    override init() {
        super.init()
        // Sesja jak w aplikacji do rozmów wideo. mixWithOthers: nie przerywa dźwięku ani nagrywania TikToka.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .videoChat, options: [.mixWithOthers, .defaultToSpeaker])
        try? session.setActive(true)
        startSilence()

        call.preferredContentSize = CGSize(width: TextView.width, height: inline.stageHeight)
        floating.frame = call.view.bounds
        floating.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        call.view.addSubview(floating)
        // Stuknięcie w tekst = start/pauza.
        inline.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggle)))
        floating.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggle)))

        if AVPictureInPictureController.isPictureInPictureSupported() {
            pip = AVPictureInPictureController(contentSource: .init(activeVideoCallSourceView: inline, contentViewController: call))
            pip?.canStartPictureInPictureAutomaticallyFromInline = true
        }
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: mic, queue: .main) { [weak self] _ in
            guard let self, self.isPlaying, self.followVoice else { return }
            try? self.mic.start()
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

    func setWindowHeight(_ height: Double) {
        inline.stageHeight = height
        floating.stageHeight = height
        call.preferredContentSize = CGSize(width: TextView.width, height: height)
        end = inline.readingLine + inline.textHeight
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
        end = inline.readingLine + inline.textHeight // ostatnia linia wyjeżdża poza górę
        offset = min(offset, end)

        let tokens = Self.tokens(text)
        words = tokens.map { $0.word }
        tops = Self.lineTops(str, ranges: tokens.map { $0.range })
        cursor = min(cursor, max(words.count - 1, 0))
    }

    @objc func toggle() {
        if let timer {
            timer.invalidate()
            self.timer = nil
            isPlaying = false
            stopListening()
            return
        }
        if followVoice {
            target = offset
            startListening()
        } else if offset >= end {
            offset = 0
        }
        lastTick = CACurrentMediaTime()
        let t = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        isPlaying = true
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = now - lastTick
        lastTick = now
        if followVoice {
            offset += (target - offset) * CGFloat(min(1, dt * 4)) // płynny dojazd do czytanej linijki
            return
        }
        offset = min(offset + CGFloat(speed * dt), end)
        if offset >= end { toggle() }
    }

    func rewind() {
        offset = 0
        target = 0
        cursor = 0
    }

    func togglePiP() {
        guard let pip else { return }
        pip.isPictureInPictureActive ? pip.stopPictureInPicture() : pip.startPictureInPicture()
    }

    // MARK: - Głos

    private func startListening() {
        let input = mic.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return } // brak zgody na mikrofon
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        try? mic.start()
        newTask()
    }

    private func stopListening() {
        mic.stop()
        mic.inputNode.removeTap(onBus: 0)
        task?.cancel()
        task = nil
        request = nil
    }

    // Rozpoznawanie kończy się po ciszy albo po ~1 min (na serwerze Apple) — wtedy zaczynamy nowe.
    private func newTask() {
        guard let recognizer else { return }
        let r = SFSpeechAudioBufferRecognitionRequest()
        r.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { r.requiresOnDeviceRecognition = true }
        request = r
        task = recognizer.recognitionTask(with: r) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.request === r else { return }
                if let result { self.follow(result.bestTranscription.formattedString) }
                if error != nil || result?.isFinal == true {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if self.isPlaying && self.followVoice && self.request === r { self.newTask() }
                    }
                }
            }
        }
    }

    // Szukamy ostatnich 3 usłyszanych słów w skrypcie trochę przed bieżącym miejscem (tylko do przodu).
    private func follow(_ transcript: String) {
        let heard = Self.tokens(transcript).suffix(3).map { $0.word }
        guard !heard.isEmpty, !words.isEmpty else { return }
        var best = (score: 0, index: 0)
        for i in cursor..<min(cursor + 25, words.count) {
            var score = 0
            for (k, w) in heard.reversed().enumerated() where i - k >= 0 && words[i - k] == w { score += 1 }
            if score > best.score { best = (score: score, index: i) }
        }
        // Pojedyncze krótkie słowo („i”, „w”, „to”) jest wszędzie — po nim nie skaczemy.
        guard best.score >= 2 || (best.score == 1 && words[best.index].count >= 4) else { return }
        cursor = best.index
        target = tops[best.index]
    }

    static func tokens(_ s: String) -> [(word: String, range: NSRange)] {
        var out: [(word: String, range: NSRange)] = []
        s.enumerateSubstrings(in: s.startIndex..., options: .byWords) { w, r, _, _ in
            if let w { out.append((word: w.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil), range: NSRange(r, in: s))) }
        }
        return out
    }

    // Ten sam układ tekstu co w UILabel, żeby wiedzieć, w której linijce jest każde słowo.
    static func lineTops(_ str: NSAttributedString, ranges: [NSRange]) -> [CGFloat] {
        let storage = NSTextStorage(attributedString: str)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: TextView.width - 2 * TextView.pad, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        return ranges.map { layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: $0, actualCharacterRange: nil), in: container).minY }
    }
}

struct ContentView: View {
    @StateObject private var prompter = Prompter()
    @AppStorage("script") private var script = "Wklej tutaj swój tekst.\n\nNaciśnij „Pływające okno”, a potem przejdź do aparatu lub dowolnej innej aplikacji — tekst zostanie na wierzchu."
    @AppStorage("fontSize") private var fontSize = 48.0
    @AppStorage("speed") private var speed = 50.0
    @AppStorage("windowHeight") private var windowHeight = 450.0
    @AppStorage("followVoice") private var followVoice = false
    @FocusState private var editing: Bool

    var body: some View {
        VStack(spacing: 14) {
            Preview(view: prompter.inline)
                .aspectRatio(TextView.width / windowHeight, contentMode: .fit)
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

            Toggle("Przewijaj za głosem", isOn: $followVoice)
            LabeledContent("Prędkość") { Slider(value: $speed, in: 10...200) }
                .disabled(followVoice)
            LabeledContent("Czcionka") { Slider(value: $fontSize, in: 24...96) }
            LabeledContent("Wysokość okna") { Slider(value: $windowHeight, in: 150...450) }

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
            prompter.followVoice = followVoice
            prompter.setWindowHeight(windowHeight)
            prompter.setText(script, fontSize: fontSize)
        }
        .onChange(of: script) { prompter.setText(script, fontSize: fontSize) }
        .onChange(of: fontSize) { prompter.setText(script, fontSize: fontSize) }
        .onChange(of: speed) { prompter.speed = speed }
        .onChange(of: windowHeight) { prompter.setWindowHeight(windowHeight) }
        .onChange(of: followVoice) { prompter.followVoice = followVoice }
    }
}
