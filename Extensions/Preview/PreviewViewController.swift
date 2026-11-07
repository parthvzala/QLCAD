import Cocoa
import Quartz
import SceneKit
import QLCADCore

@objc(PreviewViewController)
public class PreviewViewController: NSViewController, QLPreviewingController {
    private var scnView: SCNView!
    private var badgeLabel: NSTextField!
    private var modeControl: NSSegmentedControl!
    private let lightFollower = QLCADLightFollower()

    public override func loadView() {
        let defaultSize = NSSize(width: 800, height: 600)
        self.preferredContentSize = defaultSize

        let container = NSView(frame: NSRect(origin: .zero, size: defaultSize))
        container.autoresizingMask = [.width, .height]

        scnView = SCNView(frame: container.bounds)
        scnView.autoresizingMask = [.width, .height]
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = false
        scnView.antialiasingMode = .multisampling4X
        scnView.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.15, alpha: 1.0)
        scnView.delegate = lightFollower
        container.addSubview(scnView)

        modeControl = NSSegmentedControl(
            labels: QLCADDisplayMode.allCases.map(\.title),
            trackingMode: .selectOne,
            target: self,
            action: #selector(displayModeChanged(_:))
        )
        modeControl.selectedSegment = QLCADDisplayMode.default.rawValue
        modeControl.controlSize = .small
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(modeControl)

        // Subtle stats badge in the lower-right corner
        badgeLabel = NSTextField(labelWithString: "")
        badgeLabel.textColor = NSColor.white.withAlphaComponent(0.7)
        badgeLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        badgeLabel.drawsBackground = true
        badgeLabel.backgroundColor = NSColor.black.withAlphaComponent(0.4)
        badgeLabel.alignment = .right
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(badgeLabel)

        NSLayoutConstraint.activate([
            modeControl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            modeControl.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            badgeLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            badgeLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])

        self.view = container
    }

    @objc private func displayModeChanged(_ sender: NSSegmentedControl) {
        guard let scene = scnView.scene, let mode = QLCADDisplayMode(rawValue: sender.selectedSegment) else { return }
        QLCADSceneBuilder.apply(mode, to: scene)
    }

    public func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        let isAccessing = url.startAccessingSecurityScopedResource()
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                if isAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            guard let result = QLCADSceneBuilder.loadSTEP(from: url.path) else {
                let error = NSError(
                    domain: "com.qlcad.preview",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to parse and tessellate STEP file."]
                )
                DispatchQueue.main.async { handler(error) }
                return
            }

            DispatchQueue.main.async {
                _ = self.view // Ensure view is loaded before accessing subviews
                if self.scnView != nil {
                    self.scnView.scene = result.scene
                    if let mode = QLCADDisplayMode(rawValue: self.modeControl.selectedSegment) {
                        QLCADSceneBuilder.apply(mode, to: result.scene)
                    }
                }
                if self.badgeLabel != nil {
                    self.badgeLabel.stringValue = "  \(result.faceCount) faces • \(result.triangleCount) tris • \(String(format: "%.1f", result.loadTimeMs)) ms  "
                }
                handler(nil)
            }
        }
    }
}
