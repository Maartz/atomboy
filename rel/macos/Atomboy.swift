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

final class Moteur: ObservableObject {
    let couche = CALayer()
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
        try? p.run()
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
    // clavier nous revient dès qu'elle existe, sans clic préalable.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.contentAspectRatio = NSSize(width: LARGEUR, height: HAUTEUR)
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.isARepeat { return }
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
            Écran(moteur: délégué.moteur)
                .frame(minWidth: CGFloat(LARGEUR), minHeight: CGFloat(HAUTEUR))
                .aspectRatio(CGFloat(LARGEUR) / CGFloat(HAUTEUR), contentMode: .fit)
        }
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
                Button("Menu en jeu") { délégué.moteur.tape("M") }
                    .keyboardShortcut("m")
            }
        }
    }
}
