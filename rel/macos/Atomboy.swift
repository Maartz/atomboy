// La coquille macOS d'atomboy : SwiftUI devant, le BEAM derrière.
//
// Le moteur est le binaire Burrito embarqué dans le bundle, lancé en
// `--serveur` : il pousse des frames RGB24 (<<'F', 69120 octets>>) et du
// PCM s16le stéréo 32 768 Hz (<<'A', longueur sur 2 octets, données>>)
// sur stdout ; la coquille lui renvoie les touches en enregistrements de
// deux octets (op '+'/'-', touche) sur stdin. Toute l'émulation — menu,
// états, mixer, câble link — vit côté BEAM ; ici on ne fait que dessiner
// (CALayer au plus proche voisin : du pixel net), jouer (AVAudioEngine —
// plus besoin de ffplay) et relayer le clavier.
//
// Compilé par swiftc directement (voir bin/build --app) : pas de projet
// Xcode, un seul fichier.

import SwiftUI
import AVFoundation

let LARGEUR = 160
let HAUTEUR = 144
let FRAME_OCTETS = LARGEUR * HAUTEUR * 3

// ── Le moteur ─────────────────────────────────────────────────────────────────

// Un code GameShark tel que la fenêtre de réglages le garde : le texte
// hexadécimal, et son interrupteur — persisté par jeu dans UserDefaults.
struct CodeGS: Codable, Identifiable, Equatable {
    var id: String { texte }
    var texte: String
    var actif: Bool
}

final class Moteur: ObservableObject {
    let couche = CALayer()
    @Published var panneau = false
    @Published var jeu: String?
    var processusEnCours: Process? { processus }
    private var processus: Process?
    private var entrée: FileHandle?
    private var tampon = Data()

    private let audio = AVAudioEngine()
    private let lecteur = AVAudioPlayerNode()
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 32768, channels: 2, interleaved: false)!
    private var audioLancé = false

    init() {
        couche.magnificationFilter = .nearest
        couche.contentsGravity = .resizeAspect
        couche.backgroundColor = NSColor.black.cgColor
    }

    // Un appui bref « depuis la barre de menus » : presse puis relâche.
    func tape(_ clé: Character) {
        let octet = UInt8(clé.asciiValue ?? 0)
        try? entrée?.write(contentsOf: Data([UInt8(ascii: "+"), octet]))
        try? entrée?.write(contentsOf: Data([UInt8(ascii: "-"), octet]))
    }

    // Le mixer natif : volume 0-100 (?V) et masque des quatre voix (?X).
    func volume(_ v: Int) {
        try? entrée?.write(contentsOf: Data([UInt8(ascii: "V"), UInt8(max(0, min(100, v)))]))
    }

    func voix(_ actives: [Bool]) {
        var masque: UInt8 = 0
        for (i, on) in actives.enumerated() where on { masque |= 1 << UInt8(i) }
        try? entrée?.write(contentsOf: Data([UInt8(ascii: "X"), masque]))
    }

    func lance(rom: URL) {
        arrête()

        // « atomboy-moteur », pas « atomboy » : APFS est insensible à la
        // casse, et « atomboy » écraserait la coquille « Atomboy » (vécu).
        let p = Process()
        p.executableURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/atomboy-moteur")
        p.arguments = [rom.path, "--serveur"]
        p.currentDirectoryURL = rom.deletingLastPathComponent()

        let versNous = Pipe()
        let versMoteur = Pipe()
        p.standardOutput = versNous
        p.standardInput = versMoteur
        p.standardError = FileHandle.standardError

        versNous.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            if data.isEmpty { return }
            DispatchQueue.main.async { self?.reçoit(data) }
        }

        p.terminationHandler = { _ in
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        }

        entrée = versMoteur.fileHandleForWriting
        processus = p
        jeu = rom.deletingPathExtension().lastPathComponent
        try? p.run()

        // Les réglages persistés rattrapent le moteur fraîchement né.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let défauts = UserDefaults.standard
            volume(défauts.object(forKey: "reglages.volume") as? Int ?? 100)
            let masque = défauts.object(forKey: "reglages.voixMasque") as? Int ?? 15
            voix((0..<4).map { masque & (1 << $0) != 0 })
            envoieCodesActifs()
        }
    }

    // ── Les codes GameShark, persistés par jeu ───────────────────────────────

    static func chargeCodes(_ jeu: String) -> [CodeGS] {
        guard let data = UserDefaults.standard.data(forKey: "codes." + jeu),
              let codes = try? JSONDecoder().decode([CodeGS].self, from: data)
        else { return [] }
        return codes
    }

    static func sauveCodes(_ codes: [CodeGS], jeu: String) {
        if let data = try? JSONEncoder().encode(codes) {
            UserDefaults.standard.set(data, forKey: "codes." + jeu)
        }
    }

    // L'ensemble actif, envoyé en remplacement complet (?C + longueur).
    func envoieCodesActifs() {
        guard let jeu else { return }
        let payload = Moteur.chargeCodes(jeu).filter(\.actif).map(\.texte).joined(separator: ",")
        let octets = Array(payload.utf8.prefix(255))
        var data = Data([UInt8(ascii: "C"), UInt8(octets.count)])
        data.append(contentsOf: octets)
        try? entrée?.write(contentsOf: data)
    }

    func arrête() {
        processus?.terminationHandler = nil
        try? entrée?.close()
        processus?.terminate()
        processus = nil
    }

    // ── Le flux entrant : frames et PCM, découpés au fil de l'eau ────────────

    private func reçoit(_ data: Data) {
        tampon.append(data)

        while true {
            guard let tag = tampon.first else { return }

            if tag == UInt8(ascii: "F") {
                guard tampon.count >= 1 + FRAME_OCTETS else { return }
                dessine(tampon.subdata(in: 1..<(1 + FRAME_OCTETS)))
                tampon.removeSubrange(0..<(1 + FRAME_OCTETS))
            } else if tag == UInt8(ascii: "A") {
                guard tampon.count >= 3 else { return }
                let n = Int(tampon[1]) << 8 | Int(tampon[2])
                guard tampon.count >= 3 + n else { return }
                joue(tampon.subdata(in: 3..<(3 + n)))
                tampon.removeSubrange(0..<(3 + n))
            } else {
                // Flux désynchronisé : jeter l'octet et se rattraper.
                tampon.removeFirst()
            }
        }
    }

    private func dessine(_ rgb: Data) {
        guard let provider = CGDataProvider(data: rgb as CFData),
              let image = CGImage(
                  width: LARGEUR, height: HAUTEUR, bitsPerComponent: 8, bitsPerPixel: 24,
                  bytesPerRow: LARGEUR * 3, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false,
                  intent: .defaultIntent)
        else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        couche.contents = image
        CATransaction.commit()
    }

    private func joue(_ pcm: Data) {
        if !audioLancé {
            audio.attach(lecteur)
            audio.connect(lecteur, to: audio.mainMixerNode, format: format)
            try? audio.start()
            lecteur.play()
            audioLancé = true
        }

        let trames = pcm.count / 4
        guard trames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(trames))
        else { return }
        buffer.frameLength = AVAudioFrameCount(trames)

        pcm.withUnsafeBytes { (brut: UnsafeRawBufferPointer) in
            let s16 = brut.bindMemory(to: Int16.self)
            let gauche = buffer.floatChannelData![0]
            let droite = buffer.floatChannelData![1]
            for i in 0..<trames {
                gauche[i] = Float(Int16(littleEndian: s16[2 * i])) / 32768.0
                droite[i] = Float(Int16(littleEndian: s16[2 * i + 1])) / 32768.0
            }
        }

        lecteur.scheduleBuffer(buffer, completionHandler: nil)
    }

    // ── Le clavier, relayé ───────────────────────────────────────────────────

    func touche(_ event: NSEvent, pressée: Bool) -> Bool {
        guard let clé = Moteur.clé(event) else { return false }
        let op: UInt8 = pressée ? UInt8(ascii: "+") : UInt8(ascii: "-")
        try? entrée?.write(contentsOf: Data([op, clé]))
        return true
    }

    private static func clé(_ event: NSEvent) -> UInt8? {
        switch event.keyCode {
        case 123: return UInt8(ascii: "L")
        case 124: return UInt8(ascii: "R")
        case 125: return UInt8(ascii: "D")
        case 126: return UInt8(ascii: "U")
        case 36: return UInt8(ascii: "S")  // Entrée = Start
        case 49: return UInt8(ascii: "E")  // Espace = Select
        case 53: return UInt8(ascii: "M")  // Échap = menu
        case 51: return UInt8(ascii: "W")  // Retour arrière = rembobinage
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

// ── La vue : une couche à l'échelle, le clavier en prise directe ─────────────

final class VueÉcran: NSView {
    var moteur: Moteur?

    override var acceptsFirstResponder: Bool { true }

    override func makeBackingLayer() -> CALayer {
        moteur?.couche ?? CALayer()
    }

    // La fenêtre garde le ratio de la dalle : pas de bandes noires — et le
    // clavier nous revient dès qu'elle existe, sans clic préalable. Sans
    // barre de titre, c'est la frame qu'on attrape pour déplacer la fenêtre.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.contentAspectRatio = NSSize(width: LARGEUR, height: HAUTEUR)
        window?.isMovableByWindowBackground = true
        window?.makeFirstResponder(self)

        // Les feux tricolores naissent effacés — ils n'apparaissent qu'au
        // survol, comme la HUD.
        for bouton in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(bouton)?.alphaValue = 0
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.isARepeat { return }

        // Échap (ou m) : le panneau NATIF, pas le menu pixel du moteur —
        // dans une app macOS, les réglages parlent SwiftUI.
        if event.keyCode == 53 || event.charactersIgnoringModifiers?.lowercased() == "m" {
            moteur?.panneau.toggle()
            return
        }

        if moteur?.touche(event, pressée: true) != true { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        if moteur?.touche(event, pressée: false) != true { super.keyUp(with: event) }
    }
}

struct Écran: NSViewRepresentable {
    let moteur: Moteur

    func makeNSView(context: Context) -> VueÉcran {
        let vue = VueÉcran()
        vue.moteur = moteur
        vue.wantsLayer = true
        DispatchQueue.main.async { vue.window?.makeFirstResponder(vue) }
        return vue
    }

    func updateNSView(_ vue: VueÉcran, context: Context) {}
}

// ── La HUD de verre : les commandes au survol, l'écran sinon ─────────────────

struct BoutonHUD: View {
    let symbole: String
    let aide: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbole)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(aide)
    }
}

struct HUD: View {
    @ObservedObject var moteur: Moteur

    var body: some View {
        HStack(spacing: 2) {
            BoutonHUD(symbole: "forward.fill", aide: "Turbo (Tab)") { moteur.tape("T") }
            BoutonHUD(symbole: "square.and.arrow.down", aide: "Sauver l'état (⌘S)") { moteur.tape("s") }
            BoutonHUD(symbole: "arrow.counterclockwise", aide: "Charger l'état (⌘R)") { moteur.tape("r") }
            BoutonHUD(symbole: "slider.horizontal.3", aide: "Réglages (Échap)") { moteur.panneau.toggle() }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .modifier(Verre())
    }
}

// ── Les Réglages (⌘,) : la convention macOS, persistée ───────────────────────

struct RéglagesAudio: View {
    let moteur: Moteur
    @AppStorage("reglages.volume") private var volume = 100
    @AppStorage("reglages.voixMasque") private var masque = 15

    init(moteur: Moteur) { self.moteur = moteur }

    private func voixLiée(_ i: Int) -> Binding<Bool> {
        Binding(
            get: { masque & (1 << i) != 0 },
            set: { on in
                masque = on ? masque | (1 << i) : masque & ~(1 << i)
                moteur.voix((0..<4).map { masque & (1 << $0) != 0 })
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
                        set: { volume = Int($0); moteur.volume(volume) }
                    ), in: 0...100, step: 10)
                Text("\(volume)").monospacedDigit().frame(width: 32, alignment: .trailing)
            }

            Section("Voix") {
                Toggle("Pulse 1", isOn: voixLiée(0))
                Toggle("Pulse 2", isOn: voixLiée(1))
                Toggle("Wave", isOn: voixLiée(2))
                Toggle("Bruit", isOn: voixLiée(3))
            }
        }
        .padding(20)
    }
}

struct RéglagesCodes: View {
    @ObservedObject var moteur: Moteur
    @State private var codes: [CodeGS] = []
    @State private var saisie = ""

    init(moteur: Moteur) { self.moteur = moteur }

    private var saisieValide: Bool {
        saisie.count == 8 && saisie.lowercased().hasPrefix("01")
            && saisie.allSatisfy(\.isHexDigit)
    }

    private func enregistre() {
        guard let jeu = moteur.jeu else { return }
        Moteur.sauveCodes(codes, jeu: jeu)
        moteur.envoieCodesActifs()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let jeu = moteur.jeu {
                Text(jeu).font(.headline)

                List {
                    ForEach($codes) { $code in
                        HStack {
                            Toggle("", isOn: $code.actif)
                                .labelsHidden()
                                .onChange(of: code.actif) { enregistre() }
                            Text(code.texte.uppercased()).monospaced()
                            Spacer()
                            Button {
                                codes.removeAll { $0.id == code.id }
                                enregistre()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(minHeight: 140)

                HStack {
                    TextField("01FF16D1", text: $saisie)
                        .textFieldStyle(.roundedBorder)
                        .monospaced()
                        .onSubmit { ajoute() }
                    Button("Ajouter") { ajoute() }
                        .disabled(!saisieValide)
                }

                Text("Format GameShark : 01 + valeur + adresse (petit-boutiste).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Lance un jeu pour lui attacher des codes.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .onAppear { charge() }
        .onChange(of: moteur.jeu) { charge() }
    }

    private func charge() {
        codes = moteur.jeu.map(Moteur.chargeCodes) ?? []
    }

    private func ajoute() {
        guard saisieValide, let _ = moteur.jeu else { return }
        let texte = saisie.uppercased()
        guard !codes.contains(where: { $0.texte == texte }) else { return }
        codes.append(CodeGS(texte: texte, actif: true))
        saisie = ""
        enregistre()
    }
}

// Liquid Glass quand le système le parle, verre dépoli sinon.
struct Verre: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
        }
    }
}

struct Scène: View {
    @ObservedObject var moteur: Moteur
    @State private var survol = false
    @Environment(\.openSettings) private var ouvreRéglages

    init(moteur: Moteur) { self.moteur = moteur }

    var body: some View {
        ZStack(alignment: .bottom) {
            Écran(moteur: moteur)
                .ignoresSafeArea()

            HUD(moteur: moteur)
                .padding(.bottom, 14)
                .opacity(survol ? 1 : 0)
                .animation(.easeOut(duration: 0.18), value: survol)
        }
        // Échap et le bouton réglages de la HUD mènent à LA fenêtre de
        // Réglages (⌘,) — la convention macOS, pas un panneau maison.
        .onChange(of: moteur.panneau) {
            if moteur.panneau {
                ouvreRéglages()
                moteur.panneau = false
            }
        }
        .onHover { dedans in
            survol = dedans
            feux(visibles: dedans)
        }
    }

    // Les feux tricolores suivent la règle de la HUD : visibles au survol,
    // effacés pendant le jeu — ils mordaient l'UI des combats.
    private func feux(visibles: Bool) {
        for fenêtre in NSApp.windows {
            for bouton in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                fenêtre.standardWindowButton(bouton)?.animator().alphaValue = visibles ? 1 : 0
            }
        }
    }
}

// ── L'application ────────────────────────────────────────────────────────────

final class Délégué: NSObject, NSApplicationDelegate {
    let moteur = Moteur()

    func application(_ application: NSApplication, open urls: [URL]) {
        if let rom = urls.first { moteur.lance(rom: rom) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Lancé sans document (double-clic sur l'app) : proposer une ROM.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            if moteur.estInactif { choisisROM() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        moteur.arrête()
    }

    func choisisROM() {
        let panneau = NSOpenPanel()
        panneau.title = "Choisir une ROM Game Boy"
        panneau.allowedFileTypes = ["gb", "gbc"]
        if panneau.runModal() == .OK, let url = panneau.url {
            moteur.lance(rom: url)
        }
    }
}

extension Moteur {
    // « Inactif » = aucun moteur lancé — pas « aucune frame reçue » : un
    // double-clic sur une ROM lance le moteur avant la première frame.
    var estInactif: Bool { processusEnCours == nil }
}

@main
struct AtomboyApp: App {
    @NSApplicationDelegateAdaptor(Délégué.self) var délégué

    var body: some Scene {
        WindowGroup("atomboy") {
            // Plein cadre : la frame va jusqu'aux coins arrondis de la
            // fenêtre, les feux tricolores flottent par-dessus — le ratio
            // est verrouillé par la fenêtre elle-même (contentAspectRatio).
            Scène(moteur: délégué.moteur)
                .frame(minWidth: CGFloat(LARGEUR * 2), minHeight: CGFloat(HAUTEUR * 2))
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: CGFloat(LARGEUR * 3), height: CGFloat(HAUTEUR * 3))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Ouvrir une ROM…") { délégué.choisisROM() }
                    .keyboardShortcut("o")
            }

            // L'idiome natif : les actions du jeu vivent aussi dans la
            // barre de menus — le menu en jeu (Échap) reste pour le style.
            CommandMenu("Partie") {
                Button("Sauver l'état") { délégué.moteur.tape("s") }
                    .keyboardShortcut("s")
                Button("Charger l'état") { délégué.moteur.tape("r") }
                    .keyboardShortcut("r")

                Menu("Case d'état") {
                    ForEach(1...9, id: \.self) { n in
                        Button("Case \(n)") { délégué.moteur.tape(Character("\(n)")) }
                            .keyboardShortcut(KeyEquivalent(Character("\(n)")))
                    }
                }

                Divider()

                Button("Turbo") { délégué.moteur.tape("T") }
                    .keyboardShortcut("t")
                Button("Menu rétro (dans le jeu)") { délégué.moteur.tape("M") }
            }
        }

        // ⌘, et « Réglages… » dans le menu de l'app — la convention, servie
        // par SwiftUI : audio (mixer) et codes GameShark, persistés.
        Settings {
            TabView {
                RéglagesAudio(moteur: délégué.moteur)
                    .tabItem { Label("Audio", systemImage: "speaker.wave.2") }
                RéglagesCodes(moteur: délégué.moteur)
                    .tabItem { Label("Codes GameShark", systemImage: "wand.and.stars") }
            }
            .frame(width: 440)
        }
    }
}
