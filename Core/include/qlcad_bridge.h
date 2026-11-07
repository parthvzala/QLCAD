#ifndef QLCAD_BRIDGE_H
#define QLCAD_BRIDGE_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// A run of a mesh's triangles that share a face colour.
typedef struct QLCADFaceGroup {
    uint32_t first_triangle;
    uint32_t triangle_count;
    float color[4];         // RGBA: [0.0f .. 1.0f]. Only meaningful if has_color
    bool has_color;         // False: these faces take the instance's colour
} QLCADFaceGroup;

// One part definition's mesh, in the definition's own coordinates. Shared by its instances.
typedef struct QLCADMeshNode {
    char name[128];
    float* positions;       // 3 * vertex_count floats [x0, y0, z0, x1, y1, z1, ...]
    float* normals;         // 3 * vertex_count floats [nx0, ny0, nz0, ...]
    uint32_t* indices;      // 3 * triangle_count uint32_t [i0, i1, i2, ...]
    uint32_t vertex_count;
    uint32_t triangle_count;
    uint32_t face_count;
    uint32_t edge_count;
    QLCADFaceGroup* groups; // Partitions the triangles; indices are ordered by group
    uint32_t group_count;

    // Edge lines for "shaded with edges" display mode
    float* edge_positions;      // 3 * edge_vertex_count floats (pairs of vertices forming line segments)
    uint32_t edge_vertex_count; // number of vertices (always even; edge_vertex_count/2 = number of line segments)
} QLCADMeshNode;

// One placement of a mesh in the model.
typedef struct QLCADInstance {
    uint32_t mesh_index;    // Index into QLCADModel.nodes
    float transform[16];    // Column-major, with translation in elements 12..14
    float color[4];         // RGBA: [0.0f .. 1.0f]
    bool has_color;
} QLCADInstance;

typedef struct QLCADModel {
    QLCADMeshNode* nodes;
    uint32_t node_count;
    QLCADInstance* instances;
    uint32_t instance_count;
    float bbox_min[3];
    float bbox_max[3];
    float bbox_center[3];
    float bounding_radius;
    // Totals count every instance, so they describe the model as displayed
    uint32_t total_faces;
    uint32_t total_vertices;
    uint32_t total_triangles;
    uint32_t total_edges;
    double load_time_ms;
} QLCADModel;

typedef struct QLCADLoadOptions {
    double linear_deflection;   // Chordal deviation (default ~0.1 or 0.0 for auto relative)
    double angular_deflection;  // Angular deviation in radians (default ~0.5)
    bool is_relative;           // Relative deflection based on shape size
    bool enable_shape_healing;  // Run ShapeFix in the plain-reader fallback, used when XCAF yields nothing
    bool extract_edges;         // Extract boundary edges for "shaded with edges" mode
} QLCADLoadOptions;

/**
 * Returns default loading options optimized for fast interactive Quick Look preview.
 */
QLCADLoadOptions qlcad_default_options(void);

/**
 * Loads and tessellates a STEP file (.step / .stp) using Open CASCADE.
 * Returns NULL on failure.
 */
QLCADModel* qlcad_load_step(const char* filepath, const QLCADLoadOptions* options);

/**
 * Frees a QLCADModel and all associated vertex/index/normal buffers.
 */
void qlcad_free_model(QLCADModel* model);

#ifdef __cplusplus
}
#endif

#endif // QLCAD_BRIDGE_H
