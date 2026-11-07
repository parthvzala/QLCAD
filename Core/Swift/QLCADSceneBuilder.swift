import Foundation
import SceneKit
import AppKit
import QLCADCore

public enum QLCADDisplayMode: Int, CaseIterable {
    case shaded
    case shadedWithEdges
    case wireframe

    public static let `default`: QLCADDisplayMode = .shadedWithEdges

    public var title: String {
        switch self {
        case .shaded: return "Shaded"
        case .shadedWithEdges: return "Edges"
        case .wireframe: return "Wireframe"
        }
    }
}

/// Keeps the light rig locked to the active camera. SceneKit's camera control swaps in its own
/// point of view when the user orbits, so parenting the lights to the camera node isn't enough.
public final class QLCADLightFollower: NSObject, SCNSceneRendererDelegate {
    public func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard let pointOfView = renderer.pointOfView,
              let rig = renderer.scene?.rootNode.childNode(withName: QLCADSceneBuilder.lightRigName, recursively: false)
        else { return }
        rig.simdWorldTransform = pointOfView.presentation.simdWorldTransform
    }
}

public final class QLCADSceneBuilder {
    fileprivate static let lightRigName = "QLCAD_LightRig"
    private static let facesGroupName = "QLCAD_Faces"
    private static let edgesGroupName = "QLCAD_Edges"
    private static let edgesForDarkPartsName = "QLCAD_EdgesForDarkParts"
    /// Parts darker than this get light edges. Compared against Rec. 709 luma of the part colour.
    private static let darkPartLuma: Float = 0.3

    public struct LoadResult {
        public let scene: SCNScene
        public let nodeCount: Int
        public let faceCount: Int
        public let vertexCount: Int
        public let triangleCount: Int
        public let loadTimeMs: Double
        public let boundingCenter: SCNVector3
        public let boundingRadius: Float
    }

    public static func loadSTEP(from path: String, linearDeflection: Double = 0.002, angularDeflection: Double = 0.5) -> LoadResult? {
        var options = qlcad_default_options()
        options.linear_deflection = linearDeflection
        options.angular_deflection = angularDeflection
        options.is_relative = true
        options.enable_shape_healing = true

        guard let model = qlcad_load_step(path, &options) else {
            return nil
        }
        defer {
            qlcad_free_model(model)
        }

        let scene = SCNScene()
        let rootNode = SCNNode()
        rootNode.name = "CAD_Root"
        let facesGroup = SCNNode()
        facesGroup.name = facesGroupName
        rootNode.addChildNode(facesGroup)
        let edgesGroup = SCNNode()
        edgesGroup.name = edgesGroupName
        rootNode.addChildNode(edgesGroup)
        let edgesForLightParts = makeEdgeMaterial()
        let edgesForDarkParts = makeEdgeMaterial()
        edgesForDarkParts.name = edgesForDarkPartsName

        let center = SCNVector3(
            model.pointee.bbox_center.0,
            model.pointee.bbox_center.1,
            model.pointee.bbox_center.2
        )
        let radius = model.pointee.bounding_radius

        // Instances of a part share vertex data; only those differing in colour need their own material
        struct FaceKey: Hashable {
            let mesh: Int
            let r, g, b, a: Float
        }
        struct EdgeKey: Hashable {
            let mesh: Int
            let isDarkPart: Bool
        }
        var faceGeometries = [FaceKey: SCNGeometry]()
        var baseFaceGeometries = [Int: SCNGeometry]()
        var edgeGeometries = [EdgeKey: SCNGeometry]()

        for i in 0..<Int(model.pointee.instance_count) {
            let instance = model.pointee.instances[i]
            let meshIndex = Int(instance.mesh_index)
            let meshNode = model.pointee.nodes[meshIndex]
            let (r, g, b, a) = (instance.color.0, instance.color.1, instance.color.2, instance.color.3)
            let transform = makeTransform(instance.transform)

            let faceKey = FaceKey(mesh: meshIndex, r: r, g: g, b: b, a: a)
            let faceGeometry: SCNGeometry
            if let existing = faceGeometries[faceKey] {
                faceGeometry = existing
            } else {
                if let base = baseFaceGeometries[meshIndex] {
                    faceGeometry = base.copy() as! SCNGeometry
                } else {
                    faceGeometry = makeFaceGeometry(meshNode)
                    baseFaceGeometries[meshIndex] = faceGeometry
                }
                faceGeometry.materials = (0..<Int(meshNode.group_count)).map { index in
                    let group = meshNode.groups[index]
                    return group.has_color
                        ? makeFaceMaterial(r: group.color.0, g: group.color.1, b: group.color.2, a: group.color.3)
                        : makeFaceMaterial(r: r, g: g, b: b, a: a)
                }
                faceGeometries[faceKey] = faceGeometry
            }

            var nameBytes = meshNode.name
            let partName = withUnsafeBytes(of: &nameBytes) { rawPtr -> String in
                guard let base = rawPtr.baseAddress?.assumingMemoryBound(to: CChar.self) else { return "Part" }
                return String(cString: base)
            }

            let partNode = SCNNode(geometry: faceGeometry)
            partNode.name = partName
            partNode.transform = transform
            facesGroup.addChildNode(partNode)

            let isDarkPart = averageLuma(of: meshNode, instanceColor: (r, g, b)) < darkPartLuma
            let edgeKey = EdgeKey(mesh: meshIndex, isDarkPart: isDarkPart)
            var edgeGeometry = edgeGeometries[edgeKey]
            if edgeGeometry == nil {
                edgeGeometry = makeEdgeGeometry(meshNode, material: isDarkPart ? edgesForDarkParts : edgesForLightParts)
                edgeGeometries[edgeKey] = edgeGeometry
            }
            if let edgeGeometry {
                let edgeNode = SCNNode(geometry: edgeGeometry)
                edgeNode.name = partName
                edgeNode.transform = transform
                edgesGroup.addChildNode(edgeNode)
            }
        }

        // Center the geometry at origin for effortless rotation
        rootNode.position = SCNVector3(-center.x, -center.y, -center.z)
        let worldNode = SCNNode()
        worldNode.name = "World"
        // STEP has no up-axis field and CAD models are mostly Z-up. SceneKit's camera control orbits
        // around Y, so stand the model up instead of tilting the camera.
        worldNode.eulerAngles.x = -.pi / 2
        worldNode.addChildNode(rootNode)
        scene.rootNode.addChildNode(worldNode)
        scene.background.contents = makeBackgroundImage()

        // Setup default camera
        let cameraNode = SCNNode()
        cameraNode.name = "Camera"
        let camera = SCNCamera()
        // A longer lens than SceneKit's default 60 degrees, to limit perspective distortion up close
        camera.fieldOfView = 30
        // Fit the bounding sphere to the vertical field of view, with a small margin
        let dist = radius / Float(sin(camera.fieldOfView / 2 * .pi / 180)) * 1.05
        camera.zNear = Double(radius * 0.01)
        camera.zFar = Double(dist + radius * 20.0)
        cameraNode.camera = camera

        let viewDirection = simd_normalize(SIMD3<Float>(0.8, 0.6, 1.2))
        cameraNode.simdPosition = viewDirection * dist
        cameraNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(cameraNode)

        setupLighting(in: scene, camera: cameraNode)
        apply(.default, to: scene)

        return LoadResult(
            scene: scene,
            nodeCount: Int(model.pointee.instance_count),
            faceCount: Int(model.pointee.total_faces),
            vertexCount: Int(model.pointee.total_vertices),
            triangleCount: Int(model.pointee.total_triangles),
            loadTimeMs: model.pointee.load_time_ms,
            boundingCenter: center,
            boundingRadius: radius
        )
    }

    /// Switches between faces, faces with B-rep edges, and B-rep edges alone.
    public static func apply(_ mode: QLCADDisplayMode, to scene: SCNScene) {
        let root = scene.rootNode
        root.childNode(withName: facesGroupName, recursively: true)?.isHidden = (mode == .wireframe)
        guard let edges = root.childNode(withName: edgesGroupName, recursively: true) else { return }
        edges.isHidden = (mode == .shaded)
        // With faces, edges contrast with their part; without, they contrast with the background
        let onBackground = NSColor(white: 0.9, alpha: 1.0)
        let onDarkPart = NSColor(white: 0.62, alpha: 1.0)
        let onLightPart = NSColor(white: 0.04, alpha: 1.0)
        for node in edges.childNodes {
            guard let material = node.geometry?.firstMaterial else { continue }
            if mode == .wireframe {
                material.diffuse.contents = onBackground
            } else {
                material.diffuse.contents = material.name == edgesForDarkPartsName ? onDarkPart : onLightPart
            }
        }
    }

    private static func makeTransform(_ m: (Float, Float, Float, Float, Float, Float, Float, Float,
                                            Float, Float, Float, Float, Float, Float, Float, Float)) -> SCNMatrix4 {
        var result = SCNMatrix4()
        result.m11 = CGFloat(m.0); result.m12 = CGFloat(m.1); result.m13 = CGFloat(m.2); result.m14 = CGFloat(m.3)
        result.m21 = CGFloat(m.4); result.m22 = CGFloat(m.5); result.m23 = CGFloat(m.6); result.m24 = CGFloat(m.7)
        result.m31 = CGFloat(m.8); result.m32 = CGFloat(m.9); result.m33 = CGFloat(m.10); result.m34 = CGFloat(m.11)
        result.m41 = CGFloat(m.12); result.m42 = CGFloat(m.13); result.m43 = CGFloat(m.14); result.m44 = CGFloat(m.15)
        return result
    }

    private static func makeFaceGeometry(_ meshNode: QLCADMeshNode) -> SCNGeometry {
        let vertexCount = Int(meshNode.vertex_count)
        let vectorByteCount = vertexCount * 3 * MemoryLayout<Float>.size

        func makeSource(_ pointer: UnsafeMutablePointer<Float>, _ semantic: SCNGeometrySource.Semantic) -> SCNGeometrySource {
            SCNGeometrySource(
                data: Data(bytes: pointer, count: vectorByteCount),
                semantic: semantic,
                vectorCount: vertexCount,
                usesFloatComponents: true,
                componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<Float>.size * 3
            )
        }

        let elements = (0..<Int(meshNode.group_count)).map { index -> SCNGeometryElement in
            let group = meshNode.groups[index]
            return SCNGeometryElement(
                data: Data(bytes: meshNode.indices + Int(group.first_triangle) * 3,
                           count: Int(group.triangle_count) * 3 * MemoryLayout<UInt32>.size),
                primitiveType: .triangles,
                primitiveCount: Int(group.triangle_count),
                bytesPerIndex: MemoryLayout<UInt32>.size
            )
        }
        return SCNGeometry(sources: [makeSource(meshNode.positions, .vertex), makeSource(meshNode.normals, .normal)],
                           elements: elements)
    }

    /// Rec. 709 luma of a part as displayed, weighted by how many triangles show each colour.
    private static func averageLuma(of meshNode: QLCADMeshNode, instanceColor: (Float, Float, Float)) -> Float {
        func luma(_ r: Float, _ g: Float, _ b: Float) -> Float { 0.2126 * r + 0.7152 * g + 0.0722 * b }
        var total: Float = 0
        for index in 0..<Int(meshNode.group_count) {
            let group = meshNode.groups[index]
            let groupLuma = group.has_color
                ? luma(group.color.0, group.color.1, group.color.2)
                : luma(instanceColor.0, instanceColor.1, instanceColor.2)
            total += groupLuma * Float(group.triangle_count)
        }
        return total / Float(max(meshNode.triangle_count, 1))
    }

    private static func makeFaceMaterial(r: Float, g: Float, b: Float, a: Float) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.isDoubleSided = true
        material.diffuse.contents = NSColor(calibratedRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
        material.roughness.contents = NSNumber(value: 0.5)
        material.metalness.contents = NSNumber(value: 0.1)
        return material
    }

    private static func makeEdgeGeometry(_ meshNode: QLCADMeshNode, material: SCNMaterial) -> SCNGeometry? {
        guard meshNode.edge_vertex_count >= 2, let positions = meshNode.edge_positions else { return nil }
        let vertexCount = Int(meshNode.edge_vertex_count)
        let source = SCNGeometrySource(
            data: Data(bytes: positions, count: vertexCount * 3 * MemoryLayout<Float>.size),
            semantic: .vertex,
            vectorCount: vertexCount,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<Float>.size * 3
        )
        let element = SCNGeometryElement(indices: (0..<UInt32(vertexCount)).map { $0 }, primitiveType: .line)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        geometry.materials = [material]
        return geometry
    }

    private static func makeEdgeMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        // Edges lie exactly on the mesh, so nudge them along the eye ray to win the depth test.
        // Motion along that ray doesn't change where they land on screen.
        material.shaderModifiers = [.geometry: """
            float3 eye = (scn_node.inverseModelViewTransform * float4(0.0, 0.0, 0.0, 1.0)).xyz;
            _geometry.position.xyz = mix(_geometry.position.xyz, eye, 0.001);
            """]
        return material
    }

    /// Three-point rig in camera space, so whichever side the user orbits to is well lit,
    /// over a soft sky/ground environment that gives faces pointing away some shape.
    private static func setupLighting(in scene: SCNScene, camera: SCNNode) {
        let rig = SCNNode()
        rig.name = lightRigName
        rig.simdWorldTransform = camera.simdWorldTransform
        scene.rootNode.addChildNode(rig)

        func addLight(intensity: CGFloat, pitch: Float, yaw: Float) {
            let light = SCNLight()
            light.type = .directional
            light.intensity = intensity
            let node = SCNNode()
            node.light = light
            node.eulerAngles = SCNVector3(pitch * .pi / 180, yaw * .pi / 180, 0)
            rig.addChildNode(node)
        }
        addLight(intensity: 520, pitch: -35, yaw: -30) // key: above left of the camera
        addLight(intensity: 130, pitch: 10, yaw: 45)    // fill: right of the camera
        addLight(intensity: 170, pitch: 0, yaw: 0)      // head: keeps faces toward the viewer lit

        scene.lightingEnvironment.contents = makeEnvironmentImage()
        scene.lightingEnvironment.intensity = 0.55
    }

    /// Vertical gradient behind the model, so a part can only match the background along a narrow band.
    private static func makeBackgroundImage() -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: 4, height: 512, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let gradient = CGGradient(colorSpace: colorSpace,
                                        colorComponents: [0.13, 0.14, 0.17, 1, 0.40, 0.43, 0.48, 1] as [CGFloat],
                                        locations: [0, 1], count: 2)
        else { return nil }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 512), options: [])
        return context.makeImage()
    }

    /// Equirectangular vertical gradient from a bright zenith to a dim ground.
    private static func makeEnvironmentImage() -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(data: nil, width: 128, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let gradient = CGGradient(colorSpace: colorSpace,
                                        colorComponents: [0.25, 1, 0.55, 1, 0.8, 1] as [CGFloat],
                                        locations: [0, 0.5, 1], count: 3)
        else { return nil }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 64), options: [])
        return context.makeImage()
    }
}
