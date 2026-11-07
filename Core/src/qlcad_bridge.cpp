#include "qlcad_bridge.h"

#include <chrono>
#include <vector>
#include <string>
#include <cstring>
#include <cmath>
#include <algorithm>
#include <iostream>
#include <array>
#include <map>

// Open CASCADE Headers
#include <TDocStd_Document.hxx>
#include <XCAFApp_Application.hxx>
#include <STEPCAFControl_Reader.hxx>
#include <STEPControl_Reader.hxx>
#include <XCAFDoc_DocumentTool.hxx>
#include <XCAFDoc_ShapeTool.hxx>
#include <XCAFDoc_ColorTool.hxx>
#include <TDataStd_Name.hxx>
#include <TCollection_AsciiString.hxx>
#include <NCollection_Sequence.hxx>
#include <TDF_Label.hxx>
#include <TDF_Tool.hxx>
#include <Quantity_ColorRGBA.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRepBndLib.hxx>
#include <BRepLib_ToolTriangulatedShape.hxx>
#include <Bnd_Box.hxx>
#include <ShapeFix_Shape.hxx>
#include <TopExp_Explorer.hxx>
#include <TopTools_IndexedDataMapOfShapeListOfShape.hxx>
#include <TopExp.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Shape.hxx>
#include <TopoDS_Compound.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Edge.hxx>
#include <BRep_Builder.hxx>
#include <BRep_Tool.hxx>
#include <Poly_Triangulation.hxx>
#include <Poly_PolygonOnTriangulation.hxx>
#include <gp_Trsf.hxx>
#include <gp_Pnt.hxx>
#include <gp_Dir.hxx>
#include <gp_Vec.hxx>
#include <Geom_Curve.hxx>
#include <GCPnts_TangentialDeflection.hxx>
#include <GeomAdaptor_Curve.hxx>

struct TempMeshNode {
    std::string name;
    std::vector<float> positions;
    std::vector<float> normals;
    std::vector<uint32_t> indices;
    std::vector<float> edge_positions; // pairs of (x,y,z) for line segments
    uint32_t face_count = 0;
    uint32_t edge_count = 0;
    std::vector<QLCADFaceGroup> groups;
};

struct TempInstance {
    uint32_t mesh_index;
    gp_Trsf trsf;
    float color[4];
    bool has_color;
};

// Everything collected while walking the assembly tree
struct TempModel {
    std::vector<TempMeshNode> meshes;
    std::vector<TempInstance> instances;
    std::map<std::string, int> meshByLabel; // label entry -> mesh index, or -1 if it has no triangles
};

QLCADLoadOptions qlcad_default_options(void) {
    QLCADLoadOptions opt;
    opt.linear_deflection = 0.002; // 0.2% chordal deflection relative to size
    opt.angular_deflection = 0.5;  // ~28 degrees
    opt.is_relative = true;
    opt.enable_shape_healing = true;
    opt.extract_edges = true;      // Enable edge extraction by default
    return opt;
}

static void extractFaceTriangles(
    const TopoDS_Face& face,
    const gp_Trsf& parentTrsf,
    std::vector<float>& positions,
    std::vector<float>& normals,
    std::vector<uint32_t>& indices,
    uint32_t& faceCount
) {
    TopLoc_Location loc;
    Handle(Poly_Triangulation) tri = BRep_Tool::Triangulation(face, loc);
    if (tri.IsNull() || tri->NbNodes() == 0 || tri->NbTriangles() == 0) {
        return;
    }

    // BRepMesh does not generate normals, so derive them from the exact surface.
    // Nodes are per-face, which keeps curved faces smooth and B-rep edges crisp.
    BRepLib_ToolTriangulatedShape::ComputeNormals(face, tri);

    faceCount++;
    gp_Trsf combinedTrsf = parentTrsf * loc.Transformation();
    bool reversed = (face.Orientation() == TopAbs_REVERSED);

    uint32_t vertexOffset = static_cast<uint32_t>(positions.size() / 3);
    int nbNodes = tri->NbNodes();
    int nbTriangles = tri->NbTriangles();

    // Reserve space
    positions.reserve(positions.size() + nbNodes * 3);
    normals.reserve(normals.size() + nbNodes * 3);
    indices.reserve(indices.size() + nbTriangles * 3);

    for (int i = 1; i <= nbNodes; ++i) {
        gp_Pnt p = tri->Node(i).Transformed(combinedTrsf);
        positions.push_back(static_cast<float>(p.X()));
        positions.push_back(static_cast<float>(p.Y()));
        positions.push_back(static_cast<float>(p.Z()));

        gp_Dir n = tri->Normal(i);
        if (reversed) n.Reverse();
        gp_Vec nv(n.X(), n.Y(), n.Z());
        nv.Transform(combinedTrsf);
        double mag = nv.Magnitude();
        if (mag > 1e-6) nv.Divide(mag);
        normals.push_back(static_cast<float>(nv.X()));
        normals.push_back(static_cast<float>(nv.Y()));
        normals.push_back(static_cast<float>(nv.Z()));
    }

    for (int i = 1; i <= nbTriangles; ++i) {
        int n1, n2, n3;
        tri->Triangle(i).Get(n1, n2, n3);
        if (reversed) {
            std::swap(n2, n3);
        }
        indices.push_back(vertexOffset + static_cast<uint32_t>(n1 - 1));
        indices.push_back(vertexOffset + static_cast<uint32_t>(n2 - 1));
        indices.push_back(vertexOffset + static_cast<uint32_t>(n3 - 1));
    }
}

/**
 * Extracts boundary edges from an OCCT shape, discretizing each edge curve
 * into line segments. Uses the polygon-on-triangulation if available (fast,
 * consistent with face tessellation), else falls back to the 3D curve.
 */
static void extractEdgeLines(
    const TopoDS_Shape& shape,
    const gp_Trsf& parentTrsf,
    std::vector<float>& edgePositions,
    uint32_t& edgeCount
) {
    // Each unique edge once, along with the faces that reference it
    TopTools_IndexedDataMapOfShapeListOfShape edgeFaces;
    TopExp::MapShapesAndAncestors(shape, TopAbs_EDGE, TopAbs_FACE, edgeFaces);

    for (int i = 1; i <= edgeFaces.Extent(); ++i) {
        const TopoDS_Edge& edge = TopoDS::Edge(edgeFaces.FindKey(i));

        // Skip degenerated edges (e.g., apex of a cone)
        if (BRep_Tool::Degenerated(edge)) {
            continue;
        }

        edgeCount++;
        std::vector<gp_Pnt> pts;

        // Strategy 1: Use the polygon-on-triangulation (aligned with face mesh)
        // Try each face that references this edge
        bool gotFromTri = false;
        for (const TopoDS_Shape& faceShape : edgeFaces.FindFromIndex(i)) {
            const TopoDS_Face& face = TopoDS::Face(faceShape);
            TopLoc_Location faceLoc;
            Handle(Poly_Triangulation) tri = BRep_Tool::Triangulation(face, faceLoc);
            if (tri.IsNull()) continue;

            TopLoc_Location edgeLoc;
            Handle(Poly_PolygonOnTriangulation) poly = BRep_Tool::PolygonOnTriangulation(edge, tri, edgeLoc);
            if (poly.IsNull()) continue;

            gp_Trsf trsf = parentTrsf * faceLoc.Transformation();
            pts.clear();
            pts.reserve(poly->NbNodes());
            for (int j = 1; j <= poly->NbNodes(); ++j) {
                gp_Pnt p = tri->Node(poly->Node(j)).Transformed(trsf);
                pts.push_back(p);
            }
            gotFromTri = true;
            break; // Use the first face that has a poly-on-tri for this edge
        }

        // Strategy 2: Fall back to 3D curve discretization
        if (!gotFromTri) {
            double first, last;
            Handle(Geom_Curve) curve = BRep_Tool::Curve(edge, first, last);
            if (curve.IsNull()) continue;

            GeomAdaptor_Curve adaptor(curve, first, last);
            GCPnts_TangentialDeflection discretizer(adaptor, 0.01, 0.2);
            int nbPts = discretizer.NbPoints();
            pts.reserve(nbPts);
            for (int j = 1; j <= nbPts; ++j) {
                gp_Pnt p = discretizer.Value(j).Transformed(parentTrsf);
                pts.push_back(p);
            }
        }

        // Convert polyline points to line segments: [p0,p1], [p1,p2], ...
        for (size_t j = 0; j + 1 < pts.size(); ++j) {
            edgePositions.push_back(static_cast<float>(pts[j].X()));
            edgePositions.push_back(static_cast<float>(pts[j].Y()));
            edgePositions.push_back(static_cast<float>(pts[j].Z()));
            edgePositions.push_back(static_cast<float>(pts[j + 1].X()));
            edgePositions.push_back(static_cast<float>(pts[j + 1].Y()));
            edgePositions.push_back(static_cast<float>(pts[j + 1].Z()));
        }
    }
}

static bool getColorForLabel(
    const Handle(XCAFDoc_ColorTool)& colorTool,
    const TDF_Label& label,
    float outColor[4]
) {
    Quantity_ColorRGBA color;
    if (colorTool->GetColor(label, XCAFDoc_ColorGen, color) ||
        colorTool->GetColor(label, XCAFDoc_ColorSurf, color) ||
        colorTool->GetColor(label, XCAFDoc_ColorCurv, color)) {
        outColor[0] = static_cast<float>(color.GetRGB().Red());
        outColor[1] = static_cast<float>(color.GetRGB().Green());
        outColor[2] = static_cast<float>(color.GetRGB().Blue());
        outColor[3] = static_cast<float>(color.Alpha());
        return true;
    }
    return false;
}

// Colours set on a definition's sub-shapes, per face. A sub-shape can be a whole solid in a
// multi-body part, so faces are applied last to win over anything broader.
using FaceColorMap = std::map<const TopoDS_TShape*, std::array<float, 4>>;

static FaceColorMap collectFaceColors(
    const Handle(XCAFDoc_ShapeTool)& shapeTool,
    const Handle(XCAFDoc_ColorTool)& colorTool,
    const TDF_Label& label
) {
    FaceColorMap colors;
    NCollection_Sequence<TDF_Label> subShapes;
    if (!shapeTool->GetSubShapes(label, subShapes)) {
        return colors;
    }
    for (bool facesPass : { false, true }) {
        for (int i = 1; i <= subShapes.Length(); ++i) {
            std::array<float, 4> color;
            if (!getColorForLabel(colorTool, subShapes.Value(i), color.data())) continue;
            TopoDS_Shape subShape = shapeTool->GetShape(subShapes.Value(i));
            if (subShape.IsNull() || (subShape.ShapeType() == TopAbs_FACE) != facesPass) continue;
            for (TopExp_Explorer exp(subShape, TopAbs_FACE); exp.More(); exp.Next()) {
                colors[exp.Current().TShape().get()] = color;
            }
        }
    }
    return colors;
}

// Meshes a definition in its own coordinates, with triangles grouped by face colour.
// Placement is left to its instances.
static void extractShapeMesh(
    const TopoDS_Shape& shape,
    const FaceColorMap& faceColors,
    bool extractEdges,
    TempMeshNode& node
) {
    gp_Trsf identity;
    std::vector<uint32_t> uncolored;
    std::map<std::array<float, 4>, std::vector<uint32_t>> colored;
    for (TopExp_Explorer exp(shape, TopAbs_FACE); exp.More(); exp.Next()) {
        const TopoDS_Face& face = TopoDS::Face(exp.Current());
        auto found = faceColors.find(face.TShape().get());
        std::vector<uint32_t>& target = (found != faceColors.end()) ? colored[found->second] : uncolored;
        extractFaceTriangles(face, identity, node.positions, node.normals, target, node.face_count);
    }

    auto appendGroup = [&node](const std::vector<uint32_t>& indices, const float* color) {
        if (indices.empty()) return;
        QLCADFaceGroup group;
        std::memset(&group, 0, sizeof(group));
        group.first_triangle = static_cast<uint32_t>(node.indices.size() / 3);
        group.triangle_count = static_cast<uint32_t>(indices.size() / 3);
        group.has_color = (color != nullptr);
        if (color != nullptr) std::memcpy(group.color, color, 4 * sizeof(float));
        node.groups.push_back(group);
        node.indices.insert(node.indices.end(), indices.begin(), indices.end());
    };
    appendGroup(uncolored, nullptr);
    for (const auto& entry : colored) {
        appendGroup(entry.second, entry.first.data());
    }

    if (extractEdges) {
        extractEdgeLines(shape, identity, node.edge_positions, node.edge_count);
    }
}

/**
 * Walks the assembly tree. Components are placed references to a definition, so a
 * component contributes its location and the walk continues at the referred label.
 * Shapes are only read from definitions: GetShape() on a component already includes
 * the component's location, which would apply the placement twice. Each definition is
 * meshed once, however many times it's placed.
 *
 * overrideColor is a colour set on an enclosing component, which beats the definition's
 * own colour. fallbackColor comes from enclosing assemblies, which only fills in for
 * definitions that have none.
 */
static void processLabelTree(
    const Handle(XCAFDoc_ShapeTool)& shapeTool,
    const Handle(XCAFDoc_ColorTool)& colorTool,
    const TDF_Label& label,
    const gp_Trsf& parentTrsf,
    const float* overrideColor,
    const float* fallbackColor,
    bool extractEdges,
    TempModel& model
) {
    if (shapeTool->IsReference(label)) {
        TDF_Label referred;
        if (!shapeTool->GetReferredShape(label, referred)) {
            return;
        }
        float instanceColor[4];
        const float* nextOverride = overrideColor;
        if (nextOverride == nullptr && getColorForLabel(colorTool, label, instanceColor)) {
            nextOverride = instanceColor;
        }
        gp_Trsf placed = parentTrsf * shapeTool->GetLocation(label).Transformation();
        processLabelTree(shapeTool, colorTool, referred, placed, nextOverride, fallbackColor,
                         extractEdges, model);
        return;
    }

    // Determine color for this definition
    float nodeColor[4] = { 0.82f, 0.84f, 0.86f, 1.0f };
    bool hasColor = true;
    if (overrideColor != nullptr) {
        std::memcpy(nodeColor, overrideColor, 4 * sizeof(float));
    } else if (!getColorForLabel(colorTool, label, nodeColor)) {
        if (fallbackColor != nullptr) {
            std::memcpy(nodeColor, fallbackColor, 4 * sizeof(float));
        } else {
            hasColor = false;
        }
    }

    if (shapeTool->IsAssembly(label)) {
        NCollection_Sequence<TDF_Label> components;
        shapeTool->GetComponents(label, components);
        for (int i = 1; i <= components.Length(); ++i) {
            processLabelTree(shapeTool, colorTool, components.Value(i), parentTrsf, overrideColor,
                             hasColor ? nodeColor : nullptr, extractEdges, model);
        }
    } else if (shapeTool->IsSimpleShape(label)) {
        TCollection_AsciiString entry;
        TDF_Tool::Entry(label, entry);
        auto found = model.meshByLabel.find(entry.ToCString());
        int meshIndex;
        if (found != model.meshByLabel.end()) {
            meshIndex = found->second;
        } else {
            meshIndex = -1;
            TopoDS_Shape shape = shapeTool->GetShape(label);
            if (!shape.IsNull()) {
                TempMeshNode mesh;
                mesh.name = "Part";
                Handle(TDataStd_Name) nameAttr;
                if (label.FindAttribute(TDataStd_Name::GetID(), nameAttr)) {
                    TCollection_AsciiString ascii(nameAttr->Get(), '?');
                    if (!ascii.IsEmpty()) {
                        mesh.name = ascii.ToCString();
                    }
                }
                extractShapeMesh(shape, collectFaceColors(shapeTool, colorTool, label), extractEdges, mesh);
                if (!mesh.indices.empty()) {
                    meshIndex = static_cast<int>(model.meshes.size());
                    model.meshes.push_back(std::move(mesh));
                }
            }
            model.meshByLabel[entry.ToCString()] = meshIndex;
        }

        if (meshIndex >= 0) {
            TempInstance instance;
            instance.mesh_index = static_cast<uint32_t>(meshIndex);
            instance.trsf = parentTrsf;
            std::memcpy(instance.color, nodeColor, 4 * sizeof(float));
            instance.has_color = hasColor;
            model.instances.push_back(instance);
        }
    }
}

extern "C" QLCADModel* qlcad_load_step(const char* filepath, const QLCADLoadOptions* userOptions) {
    if (!filepath) return nullptr;

    auto startTime = std::chrono::high_resolution_clock::now();
    QLCADLoadOptions options = userOptions ? *userOptions : qlcad_default_options();

    // 1. Try reading with XCAF (retains colors, names, and assemblies)
    Handle(XCAFApp_Application) app = XCAFApp_Application::GetApplication();
    Handle(TDocStd_Document) doc;
    app->NewDocument("MDTV-XCAF", doc);

    STEPCAFControl_Reader cafReader;
    cafReader.SetColorMode(true);
    cafReader.SetNameMode(true);
    cafReader.SetLayerMode(true);
    cafReader.SetMatMode(true);

    IFSelect_ReturnStatus status = cafReader.ReadFile(filepath);
    bool useFallback = false;

    if (status != IFSelect_RetDone || !cafReader.Transfer(doc)) {
        useFallback = true;
    }

    Handle(XCAFDoc_ShapeTool) shapeTool;
    Handle(XCAFDoc_ColorTool) colorTool;
    NCollection_Sequence<TDF_Label> freeShapes;

    if (!useFallback) {
        shapeTool = XCAFDoc_DocumentTool::ShapeTool(doc->Main());
        colorTool = XCAFDoc_DocumentTool::ColorTool(doc->Main());
        shapeTool->GetFreeShapes(freeShapes);
        if (freeShapes.IsEmpty()) {
            useFallback = true;
        }
    }

    TempModel temp;
    Bnd_Box overallBndBox;

    if (!useFallback) {
        // Collect full compound for meshing and bounds
        TopoDS_Compound compound;
        BRep_Builder b;
        b.MakeCompound(compound);

        for (int i = 1; i <= freeShapes.Length(); ++i) {
            TopoDS_Shape s = shapeTool->GetShape(freeShapes.Value(i));
            if (!s.IsNull()) {
                b.Add(compound, s);
            }
        }

        // Tessellate entire model with adaptive deflection. No ShapeFix here: the tree walk below
        // reads the document's shapes, so faces a fixer replaced would have no mesh and vanish.
        BRepBndLib::Add(compound, overallBndBox);
        BRepMesh_IncrementalMesh mesher(
            compound,
            options.linear_deflection,
            options.is_relative,
            options.angular_deflection,
            true // in parallel
        );
        mesher.Perform();

        // Traverse hierarchy
        gp_Trsf identity;
        for (int i = 1; i <= freeShapes.Length(); ++i) {
            processLabelTree(shapeTool, colorTool, freeShapes.Value(i), identity, nullptr, nullptr,
                             options.extract_edges, temp);
        }
    }

    // Fallback: standard STEPControl_Reader if XCAF didn't yield nodes
    if (temp.instances.empty()) {
        STEPControl_Reader reader;
        IFSelect_ReturnStatus fbStatus = reader.ReadFile(filepath);
        if (fbStatus != IFSelect_RetDone) {
            return nullptr;
        }
        reader.TransferRoots();
        TopoDS_Shape shape = reader.OneShape();
        if (shape.IsNull()) return nullptr;

        if (options.enable_shape_healing) {
            ShapeFix_Shape fixer(shape);
            fixer.Perform();
            shape = fixer.Shape();
        }

        BRepBndLib::Add(shape, overallBndBox);
        BRepMesh_IncrementalMesh mesher(
            shape,
            options.linear_deflection,
            options.is_relative,
            options.angular_deflection,
            true
        );
        mesher.Perform();

        TempMeshNode mesh;
        mesh.name = "Model";
        extractShapeMesh(shape, FaceColorMap(), options.extract_edges, mesh);
        if (!mesh.indices.empty()) {
            TempInstance instance;
            instance.mesh_index = 0;
            instance.color[0] = 0.82f;
            instance.color[1] = 0.84f;
            instance.color[2] = 0.86f;
            instance.color[3] = 1.0f;
            instance.has_color = false;
            temp.meshes.push_back(std::move(mesh));
            temp.instances.push_back(instance);
        }
    }

    if (temp.instances.empty()) {
        return nullptr;
    }

    // Allocate output model
    QLCADModel* model = new QLCADModel();
    std::memset(model, 0, sizeof(QLCADModel));
    model->node_count = static_cast<uint32_t>(temp.meshes.size());
    model->nodes = new QLCADMeshNode[model->node_count];

    for (uint32_t i = 0; i < model->node_count; ++i) {
        auto& src = temp.meshes[i];
        auto& dst = model->nodes[i];

        std::strncpy(dst.name, src.name.c_str(), sizeof(dst.name) - 1);
        dst.name[sizeof(dst.name) - 1] = '\0';

        dst.vertex_count = static_cast<uint32_t>(src.positions.size() / 3);
        dst.triangle_count = static_cast<uint32_t>(src.indices.size() / 3);
        dst.face_count = src.face_count;
        dst.edge_count = src.edge_count;

        dst.positions = new float[src.positions.size()];
        std::memcpy(dst.positions, src.positions.data(), src.positions.size() * sizeof(float));

        dst.normals = new float[src.normals.size()];
        std::memcpy(dst.normals, src.normals.data(), src.normals.size() * sizeof(float));

        dst.indices = new uint32_t[src.indices.size()];
        std::memcpy(dst.indices, src.indices.data(), src.indices.size() * sizeof(uint32_t));

        dst.group_count = static_cast<uint32_t>(src.groups.size());
        dst.groups = new QLCADFaceGroup[dst.group_count];
        std::memcpy(dst.groups, src.groups.data(), src.groups.size() * sizeof(QLCADFaceGroup));

        // Edge data
        dst.edge_vertex_count = static_cast<uint32_t>(src.edge_positions.size() / 3);
        if (dst.edge_vertex_count > 0) {
            dst.edge_positions = new float[src.edge_positions.size()];
            std::memcpy(dst.edge_positions, src.edge_positions.data(), src.edge_positions.size() * sizeof(float));
        } else {
            dst.edge_positions = nullptr;
        }
    }

    model->instance_count = static_cast<uint32_t>(temp.instances.size());
    model->instances = new QLCADInstance[model->instance_count];

    uint32_t totalFaces = 0;
    uint32_t totalEdges = 0;
    uint32_t totalVertices = 0;
    uint32_t totalTriangles = 0;

    for (uint32_t i = 0; i < model->instance_count; ++i) {
        const auto& src = temp.instances[i];
        auto& dst = model->instances[i];

        dst.mesh_index = src.mesh_index;
        dst.has_color = src.has_color;
        std::memcpy(dst.color, src.color, 4 * sizeof(float));

        for (int column = 0; column < 4; ++column) {
            for (int row = 0; row < 4; ++row) {
                double value = (row == 3) ? (column == 3 ? 1.0 : 0.0) : src.trsf.Value(row + 1, column + 1);
                dst.transform[column * 4 + row] = static_cast<float>(value);
            }
        }

        const auto& mesh = model->nodes[src.mesh_index];
        totalFaces += mesh.face_count;
        totalEdges += mesh.edge_count;
        totalVertices += mesh.vertex_count;
        totalTriangles += mesh.triangle_count;
    }

    // Bounding box calculations
    double xmin, ymin, zmin, xmax, ymax, zmax;
    if (!overallBndBox.IsVoid()) {
        overallBndBox.Get(xmin, ymin, zmin, xmax, ymax, zmax);
    } else {
        xmin = ymin = zmin = -1.0;
        xmax = ymax = zmax = 1.0;
    }

    model->bbox_min[0] = static_cast<float>(xmin);
    model->bbox_min[1] = static_cast<float>(ymin);
    model->bbox_min[2] = static_cast<float>(zmin);

    model->bbox_max[0] = static_cast<float>(xmax);
    model->bbox_max[1] = static_cast<float>(ymax);
    model->bbox_max[2] = static_cast<float>(zmax);

    model->bbox_center[0] = static_cast<float>((xmin + xmax) * 0.5);
    model->bbox_center[1] = static_cast<float>((ymin + ymax) * 0.5);
    model->bbox_center[2] = static_cast<float>((zmin + zmax) * 0.5);

    double dx = xmax - xmin;
    double dy = ymax - ymin;
    double dz = zmax - zmin;
    model->bounding_radius = static_cast<float>(std::sqrt(dx * dx + dy * dy + dz * dz) * 0.5);

    model->total_faces = totalFaces;
    model->total_vertices = totalVertices;
    model->total_triangles = totalTriangles;
    model->total_edges = totalEdges;

    auto endTime = std::chrono::high_resolution_clock::now();
    model->load_time_ms = std::chrono::duration<double, std::milli>(endTime - startTime).count();

    return model;
}

extern "C" void qlcad_free_model(QLCADModel* model) {
    if (!model) return;

    if (model->nodes) {
        for (uint32_t i = 0; i < model->node_count; ++i) {
            delete[] model->nodes[i].positions;
            delete[] model->nodes[i].normals;
            delete[] model->nodes[i].indices;
            delete[] model->nodes[i].edge_positions;
            delete[] model->nodes[i].groups;
        }
        delete[] model->nodes;
    }
    delete[] model->instances;

    delete model;
}
