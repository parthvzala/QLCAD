import Cocoa
import QuickLookThumbnailing
import SceneKit
import QLCADCore

@objc(ThumbnailProvider)
public class ThumbnailProvider: QLThumbnailProvider {
    public override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let url = request.fileURL
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        // Thumbnails can't show the finer mesh, so spend less on it
        guard let result = QLCADSceneBuilder.loadSTEP(from: url.path, linearDeflection: 0.01, angularDeflection: 0.8) else {
            let error = NSError(
                domain: "com.qlcad.thumbnail",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to load STEP for thumbnail."]
            )
            handler(nil, error)
            return
        }

        let maxDimension = max(request.maximumSize.width, request.maximumSize.height)
        let renderSize = CGSize(width: maxDimension, height: maxDimension)

        let reply = QLThumbnailReply(contextSize: renderSize, currentContextDrawing: { () -> Bool in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }

            let renderer = SCNRenderer(device: nil, options: nil)
            renderer.scene = result.scene
            renderer.autoenablesDefaultLighting = false

            // Set background to transparent
            renderer.scene?.background.contents = NSColor.clear

            let snapshot = renderer.snapshot(atTime: 0, with: renderSize, antialiasingMode: .multisampling4X)
            if let cgImage = snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let rect = CGRect(origin: .zero, size: renderSize)
                context.draw(cgImage, in: rect)
                return true
            }

            return false
        })

        handler(reply, nil)
    }
}
