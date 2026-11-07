import Cocoa
import SceneKit
import UniformTypeIdentifiers
import QLCADCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    private var scnView: SCNView!
    private var statusLabel: NSTextField!
    private var dropOverlay: NSTextField!
    private var displayModeControl: NSSegmentedControl!
    private var displayMode = QLCADDisplayMode.default
    private let lightFollower = QLCADLightFollower()
    private var pendingFilePath: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupWindow()

        // Check if an openFile was requested before finishLaunching
        if let path = pendingFilePath {
            loadSTEP(at: path)
        } else {
            // Check command line args
            let args = ProcessInfo.processInfo.arguments
            if args.count > 1 && !args[1].starts(with: "-") {
                loadSTEP(at: args[1])
            }
        }

        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    // Handles Finder double-click, "Open With", and drag-and-drop onto Dock icon
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        if window != nil {
            loadSTEP(at: filename)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
        } else {
            pendingFilePath = filename
        }
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if let first = filenames.first {
            _ = application(sender, openFile: first)
        }
    }

    private func setupWindow() {
        let contentRect = NSRect(x: 150, y: 150, width: 950, height: 700)
        window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "QLCAD — STEP CAD Viewer"
        window.center()
        window.delegate = self
        window.minSize = NSSize(width: 650, height: 450)
        window.isReleasedWhenClosed = false

        guard let contentView = window.contentView else { return }
        contentView.wantsLayer = true

        // SceneKit View
        scnView = SCNView(frame: contentView.bounds)
        scnView.autoresizingMask = [.width, .height]
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = false
        scnView.antialiasingMode = .multisampling4X
        scnView.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.16, alpha: 1.0)
        scnView.preferredFramesPerSecond = 60
        scnView.delegate = lightFollower
        contentView.addSubview(scnView)

        // Drop instruction overlay
        dropOverlay = NSTextField(labelWithString: "Drag & Drop any STEP (.step / .stp) file here\nor click Open below")
        dropOverlay.font = NSFont.systemFont(ofSize: 20, weight: .medium)
        dropOverlay.textColor = NSColor.white.withAlphaComponent(0.65)
        dropOverlay.alignment = .center
        dropOverlay.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(dropOverlay)

        // Status Label (top-left badge)
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.95)
        statusLabel.drawsBackground = true
        statusLabel.backgroundColor = NSColor.black.withAlphaComponent(0.6)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.isHidden = true
        contentView.addSubview(statusLabel)

        // Bottom Controls Bar
        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.spacing = 14
        bar.translatesAutoresizingMaskIntoConstraints = false

        let openBtn = NSButton(title: "Open STEP…", target: self, action: #selector(openFileClicked))
        openBtn.bezelStyle = .rounded

        displayModeControl = NSSegmentedControl(
            labels: QLCADDisplayMode.allCases.map(\.title),
            trackingMode: .selectOne,
            target: self,
            action: #selector(displayModeChanged)
        )
        displayModeControl.selectedSegment = displayMode.rawValue

        let resetCamBtn = NSButton(title: "Reset Camera", target: self, action: #selector(resetCameraClicked))
        resetCamBtn.bezelStyle = .rounded

        bar.addArrangedSubview(openBtn)
        bar.addArrangedSubview(resetCamBtn)
        bar.addArrangedSubview(displayModeControl)
        contentView.addSubview(bar)

        NSLayoutConstraint.activate([
            dropOverlay.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            dropOverlay.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            statusLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),

            bar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            bar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16)
        ])
    }

    @objc func openFileClicked() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "step") ?? .data,
            UTType(filenameExtension: "stp") ?? .data
        ]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            loadSTEP(at: url.path)
        }
    }

    @objc private func displayModeChanged() {
        guard let mode = QLCADDisplayMode(rawValue: displayModeControl.selectedSegment) else { return }
        displayMode = mode
        if let scene = scnView.scene {
            QLCADSceneBuilder.apply(mode, to: scene)
        }
    }

    @objc private func resetCameraClicked() {
        scnView.pointOfView = scnView.scene?.rootNode.childNode(withName: "Camera", recursively: true)
    }

    func loadSTEP(at path: String) {
        dropOverlay.stringValue = "Tessellating CAD geometry with OpenCASCADE…"
        dropOverlay.isHidden = false

        DispatchQueue.global(qos: .userInitiated).async {
            guard let result = QLCADSceneBuilder.loadSTEP(from: path) else {
                DispatchQueue.main.async {
                    self.dropOverlay.stringValue = "Failed to load STEP file.\nFile may be corrupt or unreadable."
                }
                return
            }

            DispatchQueue.main.async {
                self.dropOverlay.isHidden = true
                self.scnView.scene = result.scene
                QLCADSceneBuilder.apply(self.displayMode, to: result.scene)

                let filename = (path as NSString).lastPathComponent
                self.window.title = "QLCAD — \(filename)"
                self.statusLabel.stringValue = "  \(filename)  |  \(result.faceCount) faces • \(result.vertexCount) verts • \(result.triangleCount) tris  |  \(String(format: "%.1f", result.loadTimeMs)) ms  "
                self.statusLabel.isHidden = false
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

// Top-level application initialization
let app = NSApplication.shared
app.setActivationPolicy(.regular)

let delegate = AppDelegate()
app.delegate = delegate

// Construct standard macOS Menu Bar
let mainMenu = NSMenu()

// 1. Application Menu
let appMenuItem = NSMenuItem()
mainMenu.addItem(appMenuItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "About QLCAD", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
appMenu.addItem(NSMenuItem.separator())
appMenu.addItem(withTitle: "Hide QLCAD", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
hideOthers.keyEquivalentModifierMask = [.command, .option]
appMenu.addItem(hideOthers)
appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
appMenu.addItem(NSMenuItem.separator())
appMenu.addItem(withTitle: "Quit QLCAD", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appMenuItem.submenu = appMenu

// 2. File Menu
let fileMenuItem = NSMenuItem()
mainMenu.addItem(fileMenuItem)
let fileMenu = NSMenu(title: "File")
fileMenu.addItem(withTitle: "Open…", action: #selector(delegate.openFileClicked), keyEquivalent: "o")
fileMenu.addItem(NSMenuItem.separator())
fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
fileMenuItem.submenu = fileMenu

// 3. Window Menu
let windowMenuItem = NSMenuItem()
mainMenu.addItem(windowMenuItem)
let windowMenu = NSMenu(title: "Window")
windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
windowMenuItem.submenu = windowMenu

app.mainMenu = mainMenu

app.run()
