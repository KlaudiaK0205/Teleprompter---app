import SwiftUI
import AVKit
import AVFoundation
import Speech
import UniformTypeIdentifiers

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
        // Okno rozmowy nie ma systemowego X, więc dokładamy własny w prawym górnym rogu.
        let close = UIButton(type: .close, primaryAction: UIAction { [weak self] _ in self?.pip?.stopPictureInPicture() })
        close.frame = CGRect(x: call.view.bounds.width - 40, y: 8, width: 32, height: 32)
        close.autoresizingMask = [.flexibleLeftMargin, .flexibleBottomMargin]
        close.accessibilityLabel = "Zamknij pływające okno"
        call.view.addSubview(close)
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

struct Script: Codable, Equatable {
    var text: String
    var file: String? = nil // nazwa pliku w folderze z iCloud Drive, jeśli skrypt stamtąd pochodzi
    var part: Int? = nil    // który fragment pliku (fragmenty oddziela linia „---”); nil = cały plik

    // Nazwa: plik bez rozszerzenia (cały plik) albo pierwsza niepusta linijka.
    var title: String {
        if let file, part == nil { return (file as NSString).deletingPathExtension }
        let line = plain.split(whereSeparator: \.isNewline).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return line.map { String($0.prefix(40)) } ?? "Nowy skrypt"
    }

    // Plik zbiorczy: skrypty oddzielone linijką z samych myślników (co najmniej trzech).
    static func split(_ text: String) -> [String] {
        var parts: [[Substring]] = [[]]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.count >= 3, t.allSatisfy({ $0 == "-" }) { parts.append([]) } else { parts[parts.count - 1].append(line) }
        }
        return parts.map { $0.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    // Do wyświetlenia: z .md zdejmujemy nagłówki (# ) i znaczniki (**pogrubienia**, [linki](…)).
    var plain: String {
        guard file?.lowercased().hasSuffix(".md") == true else { return text }
        return text.components(separatedBy: .newlines).map { line in
            var l = Substring(line)
            let hashes = l.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), l.dropFirst(hashes).first == " " { l = l.dropFirst(hashes + 1) } // #hashtagi zostają
            let md = try? AttributedString(markdown: String(l), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            return md.map { String($0.characters) } ?? String(l)
        }.joined(separator: "\n")
    }
}

struct ContentView: View {
    @StateObject private var prompter = Prompter()
    @State private var scripts = Self.loadScripts()
    @AppStorage("current") private var current = 0
    @State private var confirmDelete = false
    @State private var folder: URL? = Self.resolveFolder()
    @State private var pickFolder = false
    @Environment(\.scenePhase) private var phase
    @AppStorage("fontSize") private var fontSize = 48.0
    @AppStorage("speed") private var speed = 50.0
    @AppStorage("windowHeight") private var windowHeight = 450.0
    @AppStorage("followVoice") private var followVoice = false
    @FocusState private var editing: Bool

    // Zawsze jest co najmniej jeden skrypt (ostatniego nie da się usunąć).
    private var index: Int { min(max(current, 0), scripts.count - 1) }
    private var text: Binding<String> {
        Binding(get: { scripts[index].text }, set: {
            scripts[index].text = $0
            // Zmiany w skrypcie z folderu wracają do pliku, więc widać je też na komputerze.
            guard let file = scripts[index].file, let folder else { return }
            let url = folder.appendingPathComponent(file)
            var out = $0
            if let part = scripts[index].part { // w pliku zbiorczym podmieniamy tylko ten fragment
                guard let disk = Self.read(url) else { return }
                var parts = Script.split(disk)
                guard parts.indices.contains(part) else { return }
                parts[part] = $0
                out = parts.joined(separator: "\n\n---\n\n")
            }
            try? out.write(to: url, atomically: true, encoding: .utf8)
        })
    }

    private static func loadScripts() -> [Script] {
        let data = UserDefaults.standard.data(forKey: "scripts") ?? Data()
        if let saved = try? JSONDecoder().decode([Script].self, from: data), !saved.isEmpty { return saved }
        if let old = try? JSONDecoder().decode([String].self, from: data), !old.isEmpty { return old.map { Script(text: $0) } }
        // Pierwsze uruchomienie albo tekst z wersji sprzed listy skryptów.
        return [Script(text: UserDefaults.standard.string(forKey: "script") ?? "Wklej tutaj swój tekst.\n\nNaciśnij „Pływające okno”, a potem przejdź do aparatu lub dowolnej innej aplikacji — tekst zostanie na wierzchu.")]
    }

    // MARK: - Folder w iCloud Drive (pliki .txt i .md z komputera)

    private static func resolveFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: "folder") else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return nil }
        _ = url.startAccessingSecurityScopedResource() // dostęp na cały czas działania aplikacji
        if stale, let fresh = try? url.bookmarkData() { UserDefaults.standard.set(fresh, forKey: "folder") }
        return url
    }

    private func setFolder(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        UserDefaults.standard.set(try? url.bookmarkData(), forKey: "folder")
        folder = url
        syncFolder()
    }

    // Nowe pliki dopisujemy do listy, zmienione aktualizujemy. Usunięte z folderu zostają w aplikacji.
    private func syncFolder(retries: Int = 5) {
        guard let folder, let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        var downloading = false
        for url in urls {
            var name = url.lastPathComponent
            if name.hasPrefix("."), name.hasSuffix(".icloud") { name = String(name.dropFirst().dropLast(7)) } // jeszcze nie pobrany
            guard ["txt", "md"].contains((name as NSString).pathExtension.lowercased()) else { continue }
            guard name == url.lastPathComponent, let text = Self.read(url) else {
                try? FileManager.default.startDownloadingUbiquitousItem(at: folder.appendingPathComponent(name))
                downloading = true
                continue
            }
            let parts = Script.split(text)
            let ids: [Int?] = parts.count == 1 ? [nil] : parts.indices.map { Optional($0) }
            for (id, part) in zip(ids, parts) {
                if let i = scripts.firstIndex(where: { $0.file == name && $0.part == id }) {
                    if scripts[i].text != part { scripts[i].text = part }
                } else {
                    scripts.append(Script(text: part, file: name, part: id))
                }
            }
            scripts.removeAll { $0.file == name && !ids.contains($0.part) } // fragmenty usunięte z pliku
        }
        if scripts.isEmpty { scripts.append(Script(text: "")) }
        if downloading && retries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { syncFolder(retries: retries - 1) }
        }
    }

    // Notatnik zapisuje w UTF-8 (czasem z BOM), starsze pliki bywają w Windows-1250.
    private static func read(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1250)
        return text?.replacingOccurrences(of: "\u{FEFF}", with: "").replacingOccurrences(of: "\r\n", with: "\n")
    }

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

            HStack {
                Menu {
                    Picker("Skrypt", selection: $current) {
                        ForEach(scripts.indices, id: \.self) {
                            Label(scripts[$0].title, systemImage: scripts[$0].file == nil ? "doc.text" : "icloud").tag($0)
                        }
                    }
                    Divider()
                    Button("Nowy skrypt", systemImage: "plus") {
                        scripts.append(Script(text: ""))
                        current = scripts.count - 1
                        editing = true
                    }
                    Button("Usuń ten skrypt", systemImage: "trash", role: .destructive) { confirmDelete = true }
                        .disabled(scripts.count < 2)
                    Divider()
                    if folder != nil {
                        Button("Odśwież z folderu", systemImage: "arrow.clockwise") { syncFolder() }
                    }
                    Button(folder == nil ? "Połącz folder z iCloud" : "Zmień folder", systemImage: "folder") { pickFolder = true }
                } label: {
                    Label(scripts[index].title, systemImage: scripts[index].file == nil ? "doc.text" : "icloud").lineLimit(1)
                }
                Spacer()
            }
            .confirmationDialog("Usunąć „\(scripts[index].title)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Usuń", role: .destructive) {
                    let i = index
                    current = max(0, i - 1)
                    scripts.remove(at: i)
                }
            } message: {
                if scripts[index].file != nil { Text("Plik zostaje w iCloud i wróci przy odświeżeniu, jeśli nie usuniesz go z folderu.") }
            }
            .fileImporter(isPresented: $pickFolder, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { setFolder(url) }
            }

            TextEditor(text: text)
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
            prompter.setText(scripts[index].plain, fontSize: fontSize)
            syncFolder()
        }
        .onChange(of: phase) { if phase == .active { syncFolder() } } // powrót do aplikacji = świeże pliki z komputera
        .onChange(of: scripts) {
            UserDefaults.standard.set(try? JSONEncoder().encode(scripts), forKey: "scripts")
            prompter.setText(scripts[index].plain, fontSize: fontSize)
        }
        .onChange(of: current) {
            prompter.rewind()
            prompter.setText(scripts[index].plain, fontSize: fontSize)
        }
        .onChange(of: fontSize) { prompter.setText(scripts[index].plain, fontSize: fontSize) }
        .onChange(of: speed) { prompter.speed = speed }
        .onChange(of: windowHeight) { prompter.setWindowHeight(windowHeight) }
        .onChange(of: followVoice) { prompter.followVoice = followVoice }
    }
}
