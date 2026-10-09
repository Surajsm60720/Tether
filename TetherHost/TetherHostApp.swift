import AppKit
import SwiftData
import SwiftUI

enum AppIconChoice: String, CaseIterable, Identifiable {
    case gold, blue, green, neutral

    var id: String { rawValue }
    var title: String {
        switch self {
        case .gold: "Gold"
        case .blue: "Blue"
        case .green: "Green"
        case .neutral: "Neutral"
        }
    }

    static var current: AppIconChoice {
        AppIconChoice(rawValue: UserDefaults.standard.string(forKey: "iconChoice") ?? "") ?? .gold
    }

    @MainActor
    func save() {
        UserDefaults.standard.set(rawValue, forKey: "iconChoice")
        DockIcon.apply()
    }
}

enum DockIcon {
    /// Asset name for the current Dock / menu-bar brand mark (matches Settings → App icon).
    @MainActor
    static var assetName: String {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let choice = AppIconChoice.current
        return "Dock\(choice.rawValue.capitalized)\(dark ? "Dark" : "Light")"
    }

    @MainActor
    static func apply() {
        guard let source = NSImage(named: assetName) else { return }
        // Match the live Dock tile. A fixed 128pt image sits smaller than the other icons.
        let tile = NSApp.dockTile.size
        let side = max(tile.width, tile.height)
        guard side > 1 else { return }
        // A custom Dock image is not masked by the system, so it has to be
        // cut to the same squircle as every other Dock icon.
        let icon = NSImage(size: NSSize(width: side, height: side))
        icon.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        // The Dock tile is larger than the painted icons inside it. Drawing
        // edge to edge makes Tether look bigger than the apps beside it.
        let iconSide = side * 0.84
        let origin = (side - iconSide) / 2
        let bounds = NSRect(x: origin, y: origin, width: iconSide, height: iconSide)
        squircle(in: bounds).addClip()
        source.draw(
            in: bounds,
            from: NSRect(origin: .zero, size: source.size),
            operation: .sourceOver,
            fraction: 1
        )
        icon.unlockFocus()
        NSApp.applicationIconImage = icon
    }

    /// macOS Dock icons are a superellipse, not a square or a plain rounded rect.
    private static func squircle(in rect: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        let exponent: CGFloat = 5
        let radiusX = rect.width / 2
        let radiusY = rect.height / 2
        let steps = 96
        for step in 0...steps {
            let angle = CGFloat(step) / CGFloat(steps) * 2 * .pi
            let cosine = cos(angle)
            let sine = sin(angle)
            let point = NSPoint(
                x: rect.midX + radiusX * pow(abs(cosine), 2 / exponent) * (cosine < 0 ? -1 : 1),
                y: rect.midY + radiusY * pow(abs(sine), 2 / exponent) * (sine < 0 ? -1 : 1)
            )
            if step == 0 {
                path.move(to: point)
            } else {
                path.line(to: point)
            }
        }
        path.close()
        return path
    }
}

final class DockIconController: NSObject, NSApplicationDelegate {
    private var appearanceObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DockIcon.apply()
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in
            Task { @MainActor in DockIcon.apply() }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        DockIcon.apply()
    }
}

@main
struct TetherHostApp: App {
    @NSApplicationDelegateAdaptor(DockIconController.self) private var dockIcon
    private let container: ModelContainer
    @State private var store: HostStore

    init() {
        let schema = Schema([ShareRecord.self, DeviceRecord.self])
        let container = (try? ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema)))
            ?? {
                let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                return try! ModelContainer(for: schema, configurations: memory)
            }()
        self.container = container
        _store = State(initialValue: HostStore(context: container.mainContext))
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            AppearanceChrome {
                HostWindow(store: store)
            }
        }
        .defaultSize(width: 920, height: 600)

        MenuBarExtra {
            MenuBarRoot(store: store)
        } label: {
            MenuBarIconLabel(accessibilityLabel: store.statusLabel)
        }
        .menuBarExtraStyle(.menu)

        Window("Pair new iPhone", id: "pair") {
            AppearanceChrome {
                PairingWindow(store: store)
            }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 420, height: 520)

        Window("Welcome to Tether", id: "welcome") {
            AppearanceChrome {
                WelcomeView(store: store)
            }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 420, height: 280)

        Window("Shelf", id: "shelf") {
            AppearanceChrome {
                ShelfView(store: store)
            }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 520, height: 140)
        .windowStyle(.hiddenTitleBar)

        Settings {
            AppearanceChrome {
                SettingsView(store: store)
            }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L10n.pair) {
                    store.beginPairing()
                }
                .keyboardShortcut("n")
            }
        }
    }
}
