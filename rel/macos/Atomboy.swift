// atomboy's macOS shell: SwiftUI up front, the BEAM behind.
//
// The engine is the Burrito binary embedded in the bundle, launched with
// `--serveur`: it pushes RGB24 frames (<<'F', 69120 bytes>>) and stereo
// s16le PCM at 32,768 Hz (<<'A', 2-byte length, data>>) on stdout; the
// shell writes keys back as two-byte records (op '+'/'-', key) on stdin.
// All of the emulation — menu, save states, mixer, link cable — lives on
// the BEAM side; here we only draw (a CALayer with nearest-neighbour
// filtering: crisp pixels), play sound (AVAudioEngine — no more ffplay)
// and relay the keyboard.
//
// Compiled by swiftc directly (see bin/build --app): no Xcode project,
// a single file.

import SwiftUI
import AVFoundation
import GameController

let WIDTH = 160
let HEIGHT = 144
let FRAME_BYTES = WIDTH * HEIGHT * 3

// ── The engine ────────────────────────────────────────────────────────────────

// A GameShark code as the settings window keeps it: the hex text, and its
// switch — persisted per game in UserDefaults.
struct GSCode: Codable, Identifiable, Equatable {
    var id: String { text }
    var text: String
    var enabled: Bool
}

final class Engine: ObservableObject {
    let layer = CALayer()
    @Published var settingsRequested = false
    @Published var game: String?
    @Published var recentROMs: [URL] = Engine.loadRecents()
    var runningProcess: Process? { process }
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()

    private let audio = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 32768, channels: 2, interleaved: false)!
    private var audioStarted = false

    init() {
        layer.magnificationFilter = .nearest
        layer.contentsGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        attachGamepads()
    }

    // A button held or released — the gamepad and the keyboard speak the
    // same protocol, press and release kept separate.
    func button(_ key: Character, pressed: Bool) {
        let op: UInt8 = pressed ? UInt8(ascii: "+") : UInt8(ascii: "-")
        try? input?.write(contentsOf: Data([op, UInt8(key.asciiValue ?? 0)]))
    }

    // ── The gamepad: GameController, edges only ──────────────────────────────

    // The held state, per gamepad: only emit CHANGES — GameController's
    // handlers fire on every twitch of a stick, and the pipe has no need for
    // ten thousand identical presses.
    private var heldButtons: [ObjectIdentifier: Set<Character>] = [:]

    private func attachGamepads() {
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] note in
            if let gamepad = note.object as? GCController { self?.configure(gamepad) }
        }

        NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let gamepad = note.object as? GCController else { return }
            // Release everything it was holding — no phantom buttons.
            for key in heldButtons[ObjectIdentifier(gamepad)] ?? [] {
                button(key, pressed: false)
            }
            heldButtons[ObjectIdentifier(gamepad)] = nil
        }

        GCController.controllers().forEach(configure)
    }

    private func configure(_ gamepad: GCController) {
        guard let pad = gamepad.extendedGamepad else { return }
        let id = ObjectIdentifier(gamepad)
        heldButtons[id] = []

        pad.valueChangedHandler = { [weak self] pad, _ in
            DispatchQueue.main.async { self?.readPad(pad, id: id) }
        }
    }

    // The wanted state is recomputed whole on every event (dpad OR stick per
    // direction, threshold ±0.5), then diffed against the held one: only the
    // edges go down the pipe.
    private func readPad(_ pad: GCExtendedGamepad, id: ObjectIdentifier) {
        var wanted: Set<Character> = []

        if pad.dpad.up.isPressed || pad.leftThumbstick.yAxis.value > 0.5 { wanted.insert("U") }
        if pad.dpad.down.isPressed || pad.leftThumbstick.yAxis.value < -0.5 { wanted.insert("D") }
        if pad.dpad.left.isPressed || pad.leftThumbstick.xAxis.value < -0.5 { wanted.insert("L") }
        if pad.dpad.right.isPressed || pad.leftThumbstick.xAxis.value > 0.5 { wanted.insert("R") }
        if pad.buttonA.isPressed { wanted.insert("A") }
        if pad.buttonB.isPressed { wanted.insert("B") }
        if pad.buttonMenu.isPressed { wanted.insert("S") }
        if pad.buttonOptions?.isPressed == true { wanted.insert("E") }
        if pad.leftShoulder.isPressed { wanted.insert("W") }

        let held = heldButtons[id] ?? []
        for key in wanted.subtracting(held) { button(key, pressed: true) }
        for key in held.subtracting(wanted) { button(key, pressed: false) }
        heldButtons[id] = wanted

        // Turbo is a toggle on the engine side: rising edge only.
        let turbo = pad.rightShoulder.isPressed || pad.rightTrigger.isPressed
        if turbo && !turboHeld { press("T") }
        turboHeld = turbo

        // X saves, Y reloads — the console reflex, on the rising edge.
        if pad.buttonX.isPressed && !saveHeld { press("s") }
        saveHeld = pad.buttonX.isPressed
        if pad.buttonY.isPressed && !loadHeld { press("r") }
        loadHeld = pad.buttonY.isPressed
    }

    private var turboHeld = false
    private var saveHeld = false
    private var loadHeld = false

    // A short tap "from the menu bar": press, then release.
    func press(_ key: Character) {
        let byte = UInt8(key.asciiValue ?? 0)
        try? input?.write(contentsOf: Data([UInt8(ascii: "+"), byte]))
        try? input?.write(contentsOf: Data([UInt8(ascii: "-"), byte]))
    }

    // The native mixer: volume 0-100 ('V') and the four-voice mask ('X').
    func volume(_ v: Int) {
        try? input?.write(contentsOf: Data([UInt8(ascii: "V"), UInt8(max(0, min(100, v)))]))
    }

    func voices(_ enabled: [Bool]) {
        var mask: UInt8 = 0
        for (i, on) in enabled.enumerated() where on { mask |= 1 << UInt8(i) }
        try? input?.write(contentsOf: Data([UInt8(ascii: "X"), mask]))
    }

    func launch(rom: URL) {
        stop()

        // "atomboy-moteur", not "atomboy": APFS is case-insensitive, and
        // "atomboy" would clobber the "Atomboy" shell (learned the hard way).
        // The name is also baked into bin/build and into shipped bundles —
        // renaming it takes a coordinated change on both sides.
        let p = Process()
        p.executableURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/atomboy-moteur")
        // `--serveur` is the engine's own CLI flag: it stays as it is.
        p.arguments = [rom.path, "--serveur"]
        p.currentDirectoryURL = rom.deletingLastPathComponent()

        let fromEngine = Pipe()
        let toEngine = Pipe()
        p.standardOutput = fromEngine
        p.standardInput = toEngine
        p.standardError = FileHandle.standardError

        fromEngine.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            if data.isEmpty { return }
            DispatchQueue.main.async { self?.receive(data) }
        }

        p.terminationHandler = { _ in
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        }

        input = toEngine.fileHandleForWriting
        process = p
        game = rom.deletingPathExtension().lastPathComponent
        noteRecent(rom)
        try? p.run()

        // The persisted settings catch up with the freshly born engine.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let defaults = UserDefaults.standard
            volume(defaults.object(forKey: "reglages.volume") as? Int ?? 100)
            let mask = defaults.object(forKey: "reglages.voixMasque") as? Int ?? 15
            voices((0..<4).map { mask & (1 << $0) != 0 })
            sendActiveCodes()
        }
    }

    // ── The recent ROMs, persisted ───────────────────────────────────────────

    // NOTE: "recentes" — like every "reglages.*" and "codes.*" key in this
    // file — is a legacy French key name kept as-is: these strings address
    // data already written to users' UserDefaults, so renaming them would
    // silently drop everybody's settings, recent list and cheat codes.

    static func loadRecents() -> [URL] {
        (UserDefaults.standard.stringArray(forKey: "recentes") ?? [])
            .map(URL.init(fileURLWithPath:))
    }

    private func noteRecent(_ rom: URL) {
        recentROMs.removeAll { $0.path == rom.path }
        recentROMs.insert(rom, at: 0)
        recentROMs = Array(recentROMs.prefix(8))
        UserDefaults.standard.set(recentROMs.map(\.path), forKey: "recentes")
    }

    func clearRecents() {
        recentROMs = []
        UserDefaults.standard.removeObject(forKey: "recentes")
    }

    // ── The GameShark codes, persisted per game ──────────────────────────────

    static func loadCodes(_ game: String) -> [GSCode] {
        guard let data = UserDefaults.standard.data(forKey: "codes." + game),
              let codes = try? JSONDecoder().decode([GSCode].self, from: data)
        else { return [] }
        return codes
    }

    static func saveCodes(_ codes: [GSCode], game: String) {
        if let data = try? JSONEncoder().encode(codes) {
            UserDefaults.standard.set(data, forKey: "codes." + game)
        }
    }

    // The active set, sent as a full replacement ('C' + length).
    func sendActiveCodes() {
        guard let game else { return }
        let payload = Engine.loadCodes(game).filter(\.enabled).map(\.text).joined(separator: ",")
        let bytes = Array(payload.utf8.prefix(255))
        var data = Data([UInt8(ascii: "C"), UInt8(bytes.count)])
        data.append(contentsOf: bytes)
        try? input?.write(contentsOf: data)
    }

    func stop() {
        process?.terminationHandler = nil
        try? input?.close()
        process?.terminate()
        process = nil
    }

    // ── The incoming stream: frames and PCM, sliced as they arrive ───────────

    private func receive(_ data: Data) {
        buffer.append(data)

        while true {
            guard let tag = buffer.first else { return }

            if tag == UInt8(ascii: "F") {
                guard buffer.count >= 1 + FRAME_BYTES else { return }
                draw(buffer.subdata(in: 1..<(1 + FRAME_BYTES)))
                buffer.removeSubrange(0..<(1 + FRAME_BYTES))
            } else if tag == UInt8(ascii: "A") {
                guard buffer.count >= 3 else { return }
                let n = Int(buffer[1]) << 8 | Int(buffer[2])
                guard buffer.count >= 3 + n else { return }
                play(buffer.subdata(in: 3..<(3 + n)))
                buffer.removeSubrange(0..<(3 + n))
            } else {
                // Stream out of sync: drop the byte and catch up.
                buffer.removeFirst()
            }
        }
    }

    private func draw(_ rgb: Data) {
        guard let provider = CGDataProvider(data: rgb as CFData),
              let image = CGImage(
                  width: WIDTH, height: HEIGHT, bitsPerComponent: 8, bitsPerPixel: 24,
                  bytesPerRow: WIDTH * 3, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false,
                  intent: .defaultIntent)
        else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = image
        CATransaction.commit()
    }

    private func play(_ pcm: Data) {
        if !audioStarted {
            audio.attach(player)
            audio.connect(player, to: audio.mainMixerNode, format: format)
            try? audio.start()
            player.play()
            audioStarted = true
        }

        let frames = pcm.count / 4
        guard frames > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return }
        pcmBuffer.frameLength = AVAudioFrameCount(frames)

        pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let s16 = raw.bindMemory(to: Int16.self)
            let left = pcmBuffer.floatChannelData![0]
            let right = pcmBuffer.floatChannelData![1]
            for i in 0..<frames {
                left[i] = Float(Int16(littleEndian: s16[2 * i])) / 32768.0
                right[i] = Float(Int16(littleEndian: s16[2 * i + 1])) / 32768.0
            }
        }

        player.scheduleBuffer(pcmBuffer, completionHandler: nil)
    }

    // ── The keyboard, relayed ────────────────────────────────────────────────

    func handleKey(_ event: NSEvent, pressed: Bool) -> Bool {
        guard let key = Engine.key(event) else { return false }
        let op: UInt8 = pressed ? UInt8(ascii: "+") : UInt8(ascii: "-")
        try? input?.write(contentsOf: Data([op, key]))
        return true
    }

    private static func key(_ event: NSEvent) -> UInt8? {
        switch event.keyCode {
        case 123: return UInt8(ascii: "L")
        case 124: return UInt8(ascii: "R")
        case 125: return UInt8(ascii: "D")
        case 126: return UInt8(ascii: "U")
        case 36: return UInt8(ascii: "S")  // Return = Start
        case 49: return UInt8(ascii: "E")  // Space = Select
        case 53: return UInt8(ascii: "M")  // Esc = menu
        case 51: return UInt8(ascii: "W")  // Delete = rewind
        case 48: return UInt8(ascii: "T")  // Tab = turbo
        default: break
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "x": return UInt8(ascii: "A")
        case "c": return UInt8(ascii: "B")
        case "m": return UInt8(ascii: "M")
        case "p": return UInt8(ascii: "P")
        default: return nil
        }
    }
}

// ── The view: one scaled layer, the keyboard tapped directly ─────────────────

final class ScreenView: NSView {
    var engine: Engine?

    override var acceptsFirstResponder: Bool { true }

    override func makeBackingLayer() -> CALayer {
        engine?.layer ?? CALayer()
    }

    // The window keeps the panel's aspect ratio: no black bars — and the
    // keyboard comes back to us as soon as the window exists, with no click
    // first. Without a title bar, the frame itself is what you grab to move
    // the window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.contentAspectRatio = NSSize(width: WIDTH, height: HEIGHT)
        window?.isMovableByWindowBackground = true
        window?.makeFirstResponder(self)

        // The traffic lights are born invisible — they only show up on
        // hover, like the HUD.
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(button)?.alphaValue = 0
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.isARepeat { return }

        // Esc (or m): the NATIVE panel, not the engine's pixel menu — in a
        // macOS app, settings speak SwiftUI.
        if event.keyCode == 53 || event.charactersIgnoringModifiers?.lowercased() == "m" {
            engine?.settingsRequested.toggle()
            return
        }

        if engine?.handleKey(event, pressed: true) != true { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        if engine?.handleKey(event, pressed: false) != true { super.keyUp(with: event) }
    }
}

struct Screen: NSViewRepresentable {
    let engine: Engine

    func makeNSView(context: Context) -> ScreenView {
        let view = ScreenView()
        view.engine = engine
        view.wantsLayer = true
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: ScreenView, context: Context) {}
}

// ── The glass HUD: the controls on hover, the screen otherwise ───────────────

struct HUDButton: View {
    let symbol: String
    let tooltip: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }
}

struct HUD: View {
    @ObservedObject var engine: Engine

    var body: some View {
        HStack(spacing: 2) {
            HUDButton(symbol: "forward.fill", tooltip: "Turbo (Tab)") { engine.press("T") }
            HUDButton(symbol: "square.and.arrow.down", tooltip: "Save State (⌘S)") { engine.press("s") }
            HUDButton(symbol: "arrow.counterclockwise", tooltip: "Load State (⌘R)") { engine.press("r") }
            HUDButton(symbol: "slider.horizontal.3", tooltip: "Settings (Esc)") { engine.settingsRequested.toggle() }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .modifier(Glass())
    }
}

// ── Settings (⌘,): the macOS convention, persisted ───────────────────────────

struct GeneralSettings: View {
    // Legacy French UserDefaults key — kept for data compatibility.
    @AppStorage("reglages.reprise") private var resume = true

    var body: some View {
        Form {
            Toggle("Resume the last game on launch", isOn: $resume)
            Text("Otherwise, the app asks you to pick a ROM.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

struct AudioSettings: View {
    let engine: Engine
    // Legacy French UserDefaults keys — kept for data compatibility.
    @AppStorage("reglages.volume") private var volume = 100
    @AppStorage("reglages.voixMasque") private var mask = 15

    init(engine: Engine) { self.engine = engine }

    private func voiceBinding(_ i: Int) -> Binding<Bool> {
        Binding(
            get: { mask & (1 << i) != 0 },
            set: { on in
                mask = on ? mask | (1 << i) : mask & ~(1 << i)
                engine.voices((0..<4).map { mask & (1 << $0) != 0 })
            }
        )
    }

    var body: some View {
        Form {
            HStack {
                Image(systemName: "speaker.wave.2.fill")
                Slider(
                    value: Binding(
                        get: { Double(volume) },
                        set: { volume = Int($0); engine.volume(volume) }
                    ), in: 0...100, step: 10)
                Text("\(volume)").monospacedDigit().frame(width: 32, alignment: .trailing)
            }

            Section("Voices") {
                Toggle("Pulse 1", isOn: voiceBinding(0))
                Toggle("Pulse 2", isOn: voiceBinding(1))
                Toggle("Wave", isOn: voiceBinding(2))
                Toggle("Noise", isOn: voiceBinding(3))
            }
        }
        .padding(20)
    }
}

struct CodesSettings: View {
    @ObservedObject var engine: Engine
    @State private var codes: [GSCode] = []
    @State private var entry = ""

    init(engine: Engine) { self.engine = engine }

    private var entryIsValid: Bool {
        entry.count == 8 && entry.lowercased().hasPrefix("01")
            && entry.allSatisfy(\.isHexDigit)
    }

    private func commit() {
        guard let game = engine.game else { return }
        Engine.saveCodes(codes, game: game)
        engine.sendActiveCodes()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let game = engine.game {
                Text(game).font(.headline)

                List {
                    ForEach($codes) { $code in
                        HStack {
                            Toggle("", isOn: $code.enabled)
                                .labelsHidden()
                                .onChange(of: code.enabled) { commit() }
                            Text(code.text.uppercased()).monospaced()
                            Spacer()
                            Button {
                                codes.removeAll { $0.id == code.id }
                                commit()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(minHeight: 140)

                HStack {
                    TextField("01FF16D1", text: $entry)
                        .textFieldStyle(.roundedBorder)
                        .monospaced()
                        .onSubmit { add() }
                    Button("Add") { add() }
                        .disabled(!entryIsValid)
                }

                Text("GameShark format: 01 + value + address (little-endian).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Start a game to attach codes to it.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .onAppear { load() }
        .onChange(of: engine.game) { load() }
    }

    private func load() {
        codes = engine.game.map(Engine.loadCodes) ?? []
    }

    private func add() {
        guard entryIsValid, let _ = engine.game else { return }
        let text = entry.uppercased()
        guard !codes.contains(where: { $0.text == text }) else { return }
        codes.append(GSCode(text: text, enabled: true))
        entry = ""
        commit()
    }
}

// Liquid Glass when the system speaks it, frosted glass otherwise.
struct Glass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
        }
    }
}

// Named MainScene, not Scene: a type called Scene in this module would
// shadow SwiftUI's Scene protocol that AtomboyApp.body returns.
struct MainScene: View {
    @ObservedObject var engine: Engine
    @State private var hovering = false
    @Environment(\.openSettings) private var openSettings

    init(engine: Engine) { self.engine = engine }

    var body: some View {
        ZStack(alignment: .bottom) {
            Screen(engine: engine)
                .ignoresSafeArea()

            HUD(engine: engine)
                .padding(.bottom, 14)
                .opacity(hovering ? 1 : 0)
                .animation(.easeOut(duration: 0.18), value: hovering)
        }
        // Esc and the HUD's settings button both lead to THE Settings window
        // (⌘,) — the macOS convention, not a home-made panel.
        .onChange(of: engine.settingsRequested) {
            if engine.settingsRequested {
                openSettings()
                engine.settingsRequested = false
            }
        }
        .onHover { inside in
            hovering = inside
            trafficLights(visible: inside)
        }
    }

    // The traffic lights follow the HUD's rule: visible on hover, wiped
    // during play — they used to bite into the battle UI.
    private func trafficLights(visible: Bool) {
        for window in NSApp.windows {
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(button)?.animator().alphaValue = visible ? 1 : 0
            }
        }
    }
}

// ── The application ──────────────────────────────────────────────────────────

final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = Engine()

    func application(_ application: NSApplication, open urls: [URL]) {
        if let rom = urls.first { engine.launch(rom: rom) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched without a document: resume the last game (can be turned
        // off in Settings) — otherwise, offer to pick a ROM.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            guard engine.isIdle else { return }

            // Legacy French UserDefaults key — kept for data compatibility.
            let resume = UserDefaults.standard.object(forKey: "reglages.reprise") == nil
                || UserDefaults.standard.bool(forKey: "reglages.reprise")

            if resume, let latest = engine.recentROMs.first(where: {
                FileManager.default.fileExists(atPath: $0.path)
            }) {
                engine.launch(rom: latest)
            } else {
                chooseROM()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
    }

    func chooseROM() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Game Boy ROM"
        panel.allowedFileTypes = ["gb", "gbc"]
        if panel.runModal() == .OK, let url = panel.url {
            engine.launch(rom: url)
        }
    }
}

extension Engine {
    // "Idle" = no engine running — not "no frame received yet": a
    // double-click on a ROM starts the engine before the first frame.
    var isIdle: Bool { runningProcess == nil }
}

// The File menu: open, and the recent ROMs — observed, so the menu updates
// itself when the list moves.
struct FileCommands: Commands {
    let delegate: AppDelegate
    @ObservedObject var engine: Engine

    init(delegate: AppDelegate) {
        self.delegate = delegate
        self.engine = delegate.engine
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open ROM…") { delegate.chooseROM() }
                .keyboardShortcut("o")

            Menu("Recent ROMs") {
                ForEach(engine.recentROMs, id: \.path) { rom in
                    Button(rom.deletingPathExtension().lastPathComponent) {
                        engine.launch(rom: rom)
                    }
                }

                if engine.recentROMs.isEmpty {
                    Button("(empty)") {}.disabled(true)
                } else {
                    Divider()
                    Button("Clear List") { engine.clearRecents() }
                }
            }
        }
    }
}

@main
struct AtomboyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup("atomboy") {
            // Full frame: the picture runs all the way to the window's
            // rounded corners, the traffic lights float on top — the aspect
            // ratio is locked by the window itself (contentAspectRatio).
            MainScene(engine: delegate.engine)
                .frame(minWidth: CGFloat(WIDTH * 2), minHeight: CGFloat(HEIGHT * 2))
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: CGFloat(WIDTH * 3), height: CGFloat(HEIGHT * 3))
        .commands {
            FileCommands(delegate: delegate)

            // The native idiom: the game's actions live in the menu bar too
            // — the in-game menu (Esc) stays around for the style.
            CommandMenu("Game") {
                Button("Save State") { delegate.engine.press("s") }
                    .keyboardShortcut("s")
                Button("Load State") { delegate.engine.press("r") }
                    .keyboardShortcut("r")

                Menu("State Slot") {
                    ForEach(1...9, id: \.self) { n in
                        Button("Slot \(n)") { delegate.engine.press(Character("\(n)")) }
                            .keyboardShortcut(KeyEquivalent(Character("\(n)")))
                    }
                }

                Divider()

                Button("Turbo") { delegate.engine.press("T") }
                    .keyboardShortcut("t")
                Button("Retro Menu (in game)") { delegate.engine.press("M") }
            }
        }

        // ⌘, and "Settings…" in the app menu — the convention, served by
        // SwiftUI: audio (mixer) and GameShark codes, both persisted.
        Settings {
            TabView {
                GeneralSettings()
                    .tabItem { Label("General", systemImage: "gearshape") }
                AudioSettings(engine: delegate.engine)
                    .tabItem { Label("Audio", systemImage: "speaker.wave.2") }
                CodesSettings(engine: delegate.engine)
                    .tabItem { Label("GameShark Codes", systemImage: "wand.and.stars") }
            }
            .frame(width: 440)
        }
    }
}
