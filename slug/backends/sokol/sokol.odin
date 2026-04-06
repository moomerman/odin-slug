package slug_sokol

// ===================================================
// Sokol GFX backend for odin-slug
//
// Renders GPU-evaluated Bezier text using the Slug algorithm
// through Sokol GFX's cross-platform rendering abstraction.
// Currently targets the GL backend with GLSL 430 shaders.
//
// Sokol GFX must be provided via a `-collection:sokol=` flag
// pointing to the sokol/ subdirectory of a sokol-odin clone:
//   -collection:sokol=/path/to/sokol-odin/sokol
//
// Usage:
//   1. Call sg.setup() first (creates the Sokol GFX context)
//   2. renderer := new(slug_sokol.Renderer)
//   3. slug_sokol.init(renderer)
//   4. slug_sokol.load_font(renderer, 0, "myfont.ttf")
//   5. Per frame (inside sg.begin_pass / sg.end_pass):
//        slug.begin(slug_sokol.ctx(renderer))
//        slug.draw_text(slug_sokol.ctx(renderer), ...)
//        slug.end(slug_sokol.ctx(renderer))
//        slug_sokol.flush(renderer, width, height)
//
// NOTE: flush() issues sg.apply_pipeline / apply_bindings / draw calls.
// The caller must have already called sg.begin_pass() before flushing,
// and sg.end_pass() + sg.commit() after. flush() does NOT manage passes.
//
// NOTE: Uses sg.append_buffer() for vertex uploads, which supports
// multiple flush calls per frame (e.g. for scissored passes).
// ===================================================

import "core:c"
import "core:math/linalg"

import sg "sokol:gfx"

import slug "../../"

// --- Per-font GPU resources ---

Font_SG :: struct {
	curve_view: sg.View,
	band_view:  sg.View,
	curve_smp:  sg.Sampler,
	band_smp:   sg.Sampler,
	curve_img:  sg.Image, // kept alive for cleanup
	band_img:   sg.Image,
	loaded:     bool,
}

// Uniform block for the Slug text vertex shader.
// Matches GLSL 430: uniform vec4 vs_params[5]
//   [0..3] = mat4 mvp (column-major)
//   [4].xy = viewport dimensions
// Total: 80 bytes = 5 x 16 (std140-aligned)
Vs_Params :: struct {
	mvp:      matrix[4, 4]f32,
	viewport: [2]f32,
	_pad:     [2]f32,
}

// Uniform block for the Slug text fragment shader.
// Matches GLSL 430: uniform vec4 fs_params[1]
//   [0].x = weight boost flag (>0.5 = enabled)
// Total: 16 bytes = 1 x 16 (std140-aligned)
Fs_Params :: struct {
	weight_boost: f32,
	_pad:         [3]f32,
}

// Uniform block for the rect vertex shader.
// Matches GLSL 430: uniform vec4 rect_vs_params[4]
// Total: 64 bytes = 4 x 16
Rect_Vs_Params :: struct {
	mvp: matrix[4, 4]f32,
}

// --- Renderer state ---
// Created by init(), freed by destroy().

Renderer :: struct {
	ctx:         slug.Context,

	// Slug text pipeline
	slug_shader: sg.Shader,
	slug_pip:    sg.Pipeline,
	slug_vbuf:   sg.Buffer,
	slug_ibuf:   sg.Buffer,

	// Rect pipeline
	rect_shader: sg.Shader,
	rect_pip:    sg.Pipeline,
	rect_vbuf:   sg.Buffer,
	rect_ibuf:   sg.Buffer,

	// Per-font textures
	font_sg:     [slug.MAX_FONT_SLOTS]Font_SG,

	// Shared atlas textures
	shared_sg:   Font_SG,
}

// ===================================================
// GLSL 430 shaders for Sokol GL backend
//
// Sokol's GL backend expects GLSL 430 with uniforms packed
// into vec4 arrays (matching the sokol-shdc convention).
// Textures use combined image-sampler names matching the
// texture_sampler_pairs[].glsl_name in the shader desc.
// ===================================================

SLUG_VS_SOURCE :: `#version 430

layout(location = 0) in vec4 inPos;
layout(location = 1) in vec4 inTex;
layout(location = 2) in vec4 inJac;
layout(location = 3) in vec4 inBnd;
layout(location = 4) in vec4 inCol;

uniform vec4 vs_params[5];

out vec4 vColor;
out vec2 vTexcoord;
flat out vec4 vBanding;
flat out ivec4 vGlyph;

void SlugUnpack(vec4 tex, vec4 bnd, out vec4 vbnd, out ivec4 vgly)
{
    uvec2 g = floatBitsToUint(tex.zw);
    vgly = ivec4(g.x & 0xFFFFu, g.x >> 16u, g.y & 0xFFFFu, g.y >> 16u);
    vbnd = bnd;
}

vec2 SlugDilate(vec4 pos, vec4 tex, vec4 jac, vec4 m0, vec4 m1, vec4 m3, vec2 dim, out vec2 vpos)
{
    vec2 n = normalize(pos.zw);
    float s = dot(m3.xy, pos.xy) + m3.w;
    float t = dot(m3.xy, n);

    float u = (s * dot(m0.xy, n) - t * (dot(m0.xy, pos.xy) + m0.w)) * dim.x;
    float v = (s * dot(m1.xy, n) - t * (dot(m1.xy, pos.xy) + m1.w)) * dim.y;

    float s2 = s * s;
    float st = s * t;
    float uv = u * u + v * v;
    vec2 d = pos.zw * (s2 * (st + sqrt(uv)) / (uv - st * st));

    vpos = pos.xy + d;
    return vec2(tex.x + dot(d, jac.xy), tex.y + dot(d, jac.zw));
}

void main()
{
    mat4 mvp = mat4(vs_params[0], vs_params[1], vs_params[2], vs_params[3]);
    vec2 viewport = vs_params[4].xy;

    vec2 p;

    vec4 m0 = vec4(mvp[0][0], mvp[1][0], mvp[2][0], mvp[3][0]);
    vec4 m1 = vec4(mvp[0][1], mvp[1][1], mvp[2][1], mvp[3][1]);
    vec4 m2 = vec4(mvp[0][2], mvp[1][2], mvp[2][2], mvp[3][2]);
    vec4 m3 = vec4(mvp[0][3], mvp[1][3], mvp[2][3], mvp[3][3]);

    vTexcoord = SlugDilate(inPos, inTex, inJac, m0, m1, m3, viewport, p);

    gl_Position.x = p.x * m0.x + p.y * m0.y + m0.w;
    gl_Position.y = p.x * m1.x + p.y * m1.y + m1.w;
    gl_Position.z = p.x * m2.x + p.y * m2.y + m2.w;
    gl_Position.w = p.x * m3.x + p.y * m3.y + m3.w;

    SlugUnpack(inTex, inBnd, vBanding, vGlyph);
    vColor = inCol;
}
`

SLUG_FS_SOURCE :: `#version 430

#define kLogBandTextureWidth 12

in vec4 vColor;
in vec2 vTexcoord;
flat in vec4 vBanding;
flat in ivec4 vGlyph;

out vec4 fragColor;

uniform sampler2D curveTexture;
uniform usampler2D bandTexture;
uniform vec4 fs_params[1];

uint CalcRootCode(float y1, float y2, float y3)
{
    uint i1 = floatBitsToUint(y1) >> 31u;
    uint i2 = floatBitsToUint(y2) >> 30u;
    uint i3 = floatBitsToUint(y3) >> 29u;

    uint shift = (i2 & 2u) | (i1 & ~2u);
    shift = (i3 & 4u) | (shift & ~4u);

    return ((0x2E74u >> shift) & 0x0101u);
}

vec2 SolveHorizPoly(vec4 p12, vec2 p3)
{
    vec2 a = p12.xy - p12.zw * 2.0 + p3;
    vec2 b = p12.xy - p12.zw;
    float ra = 1.0 / a.y;
    float rb = 0.5 / b.y;

    float d = sqrt(max(b.y * b.y - a.y * p12.y, 0.0));
    float t1 = (b.y - d) * ra;
    float t2 = (b.y + d) * ra;

    if (abs(a.y) < 1.0 / 65536.0) t1 = t2 = p12.y * rb;

    return vec2((a.x * t1 - b.x * 2.0) * t1 + p12.x,
                (a.x * t2 - b.x * 2.0) * t2 + p12.x);
}

vec2 SolveVertPoly(vec4 p12, vec2 p3)
{
    vec2 a = p12.xy - p12.zw * 2.0 + p3;
    vec2 b = p12.xy - p12.zw;
    float ra = 1.0 / a.x;
    float rb = 0.5 / b.x;

    float d = sqrt(max(b.x * b.x - a.x * p12.x, 0.0));
    float t1 = (b.x - d) * ra;
    float t2 = (b.x + d) * ra;

    if (abs(a.x) < 1.0 / 65536.0) t1 = t2 = p12.x * rb;

    return vec2((a.y * t1 - b.y * 2.0) * t1 + p12.y,
                (a.y * t2 - b.y * 2.0) * t2 + p12.y);
}

ivec2 CalcBandLoc(ivec2 glyphLoc, uint offset)
{
    ivec2 bandLoc = ivec2(glyphLoc.x + int(offset), glyphLoc.y);
    bandLoc.y += bandLoc.x >> kLogBandTextureWidth;
    bandLoc.x &= (1 << kLogBandTextureWidth) - 1;
    return bandLoc;
}

float CalcCoverage(float xcov, float ycov, float xwgt, float ywgt)
{
    float coverage = max(abs(xcov * xwgt + ycov * ywgt) / max(xwgt + ywgt, 1.0 / 65536.0),
                         min(abs(xcov), abs(ycov)));
    return clamp(coverage, 0.0, 1.0);
}

void main()
{
    vec2 renderCoord = vTexcoord;
    vec4 bandTransform = vBanding;
    ivec4 glyphData = vGlyph;

    vec2 emsPerPixel = fwidth(renderCoord);
    vec2 pixelsPerEm = 1.0 / emsPerPixel;

    ivec2 bandMax = glyphData.zw;
    bandMax.y &= 0x00FF;

    ivec2 bandIndex = clamp(ivec2(renderCoord * bandTransform.xy + bandTransform.zw),
                            ivec2(0, 0), bandMax);
    ivec2 glyphLoc = glyphData.xy;

    float xcov = 0.0;
    float xwgt = 0.0;

    uvec2 hbandData = texelFetch(bandTexture, ivec2(glyphLoc.x + bandIndex.y, glyphLoc.y), 0).xy;
    ivec2 hbandLoc = CalcBandLoc(glyphLoc, hbandData.y);

    for (int curveIndex = 0; curveIndex < int(hbandData.x); curveIndex++)
    {
        ivec2 curveLoc = ivec2(texelFetch(bandTexture, ivec2(hbandLoc.x + curveIndex, hbandLoc.y), 0).xy);
        vec4 p12 = texelFetch(curveTexture, curveLoc, 0) - vec4(renderCoord, renderCoord);
        vec2 p3 = texelFetch(curveTexture, ivec2(curveLoc.x + 1, curveLoc.y), 0).xy - renderCoord;

        if (max(max(p12.x, p12.z), p3.x) * pixelsPerEm.x < -0.5) break;

        uint code = CalcRootCode(p12.y, p12.w, p3.y);
        if (code != 0u)
        {
            vec2 r = SolveHorizPoly(p12, p3) * pixelsPerEm.x;

            if ((code & 1u) != 0u)
            {
                xcov += clamp(r.x + 0.5, 0.0, 1.0);
                xwgt = max(xwgt, clamp(1.0 - abs(r.x) * 2.0, 0.0, 1.0));
            }

            if (code > 1u)
            {
                xcov -= clamp(r.y + 0.5, 0.0, 1.0);
                xwgt = max(xwgt, clamp(1.0 - abs(r.y) * 2.0, 0.0, 1.0));
            }
        }
    }

    float ycov = 0.0;
    float ywgt = 0.0;

    uvec2 vbandData = texelFetch(bandTexture, ivec2(glyphLoc.x + bandMax.y + 1 + bandIndex.x, glyphLoc.y), 0).xy;
    ivec2 vbandLoc = CalcBandLoc(glyphLoc, vbandData.y);

    for (int curveIndex = 0; curveIndex < int(vbandData.x); curveIndex++)
    {
        ivec2 curveLoc = ivec2(texelFetch(bandTexture, ivec2(vbandLoc.x + curveIndex, vbandLoc.y), 0).xy);
        vec4 p12 = texelFetch(curveTexture, curveLoc, 0) - vec4(renderCoord, renderCoord);
        vec2 p3 = texelFetch(curveTexture, ivec2(curveLoc.x + 1, curveLoc.y), 0).xy - renderCoord;

        if (max(max(p12.y, p12.w), p3.y) * pixelsPerEm.y < -0.5) break;

        uint code = CalcRootCode(p12.x, p12.z, p3.x);
        if (code != 0u)
        {
            vec2 r = SolveVertPoly(p12, p3) * pixelsPerEm.y;

            if ((code & 1u) != 0u)
            {
                ycov -= clamp(r.x + 0.5, 0.0, 1.0);
                ywgt = max(ywgt, clamp(1.0 - abs(r.x) * 2.0, 0.0, 1.0));
            }

            if (code > 1u)
            {
                ycov += clamp(r.y + 0.5, 0.0, 1.0);
                ywgt = max(ywgt, clamp(1.0 - abs(r.y) * 2.0, 0.0, 1.0));
            }
        }
    }

    float coverage = CalcCoverage(xcov, ycov, xwgt, ywgt);
    if (fs_params[0].x > 0.5) coverage = sqrt(coverage);
    fragColor = vColor * coverage;
}
`

RECT_VS_SOURCE :: `#version 430
layout(location = 0) in vec2 inPos;
layout(location = 1) in vec4 inCol;
uniform vec4 rect_vs_params[4];
out vec4 vColor;
void main() {
    mat4 mvp = mat4(rect_vs_params[0], rect_vs_params[1], rect_vs_params[2], rect_vs_params[3]);
    gl_Position = mvp * vec4(inPos, 0.0, 1.0);
    vColor = inCol;
}
`

RECT_FS_SOURCE :: `#version 430
in vec4 vColor;
out vec4 fragColor;
void main() { fragColor = vColor; }
`

// ===================================================
// Initialization
// Call AFTER sg.setup() has initialized the Sokol GFX context.
// Returns nil if shader or pipeline creation fails.
// Caller must call destroy() to free.
// ===================================================

init :: proc() -> ^Renderer {
	r, alloc_err := new(Renderer)
	if alloc_err != .None do return nil
	// --- Slug text shader ---
	r.slug_shader = sg.make_shader({
		vertex_func = {
			source = SLUG_VS_SOURCE,
			entry = "main",
		},
		fragment_func = {
			source = SLUG_FS_SOURCE,
			entry = "main",
		},
		attrs = {
			0 = {base_type = .FLOAT, glsl_name = "inPos"},
			1 = {base_type = .FLOAT, glsl_name = "inTex"},
			2 = {base_type = .FLOAT, glsl_name = "inJac"},
			3 = {base_type = .FLOAT, glsl_name = "inBnd"},
			4 = {base_type = .FLOAT, glsl_name = "inCol"},
		},
		uniform_blocks = {
			0 = {
				stage = .VERTEX,
				size = size_of(Vs_Params),
				layout = .STD140,
				glsl_uniforms = {
					0 = {type = .FLOAT4, array_count = 5, glsl_name = "vs_params"},
				},
			},
			1 = {
				stage = .FRAGMENT,
				size = size_of(Fs_Params),
				layout = .STD140,
				glsl_uniforms = {
					0 = {type = .FLOAT4, array_count = 1, glsl_name = "fs_params"},
				},
			},
		},
		views = {
			0 = {texture = {stage = .FRAGMENT, image_type = ._2D, sample_type = .FLOAT}},
			1 = {texture = {stage = .FRAGMENT, image_type = ._2D, sample_type = .UINT}},
		},
		samplers = {
			0 = {stage = .FRAGMENT, sampler_type = .NONFILTERING},
			1 = {stage = .FRAGMENT, sampler_type = .NONFILTERING},
		},
		texture_sampler_pairs = {
			0 = {stage = .FRAGMENT, view_slot = 0, sampler_slot = 0, glsl_name = "curveTexture"},
			1 = {stage = .FRAGMENT, view_slot = 1, sampler_slot = 1, glsl_name = "bandTexture"},
		},
	})

	// --- Slug text pipeline ---
	r.slug_pip = sg.make_pipeline({
		shader = r.slug_shader,
		layout = {
			attrs = {
				0 = {format = .FLOAT4}, // pos: xy + dilation normal zw
				1 = {format = .FLOAT4}, // tex: em coords + packed glyph data
				2 = {format = .FLOAT4}, // jac: inverse Jacobian
				3 = {format = .FLOAT4}, // bnd: band transform
				4 = {format = .FLOAT4}, // col: RGBA color
			},
		},
		index_type = .UINT32,
		colors = {
			0 = {
				blend = {
					enabled = true,
					src_factor_rgb = .SRC_ALPHA,
					dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
					src_factor_alpha = .SRC_ALPHA,
					dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
				},
			},
		},
		depth = {
			write_enabled = false,
			compare = .ALWAYS,
		},
		cull_mode = .NONE,
	})

	// --- Slug vertex buffer (stream — re-uploaded each frame via append_buffer) ---
	r.slug_vbuf = sg.make_buffer({
		usage = {vertex_buffer = true, stream_update = true},
		size  = c.size_t(slug.MAX_GLYPH_VERTICES * size_of(slug.Vertex)),
	})

	// --- Slug index buffer (static — pre-generated 0,1,2,2,3,0 quad pattern) ---
	slug_indices: [slug.MAX_GLYPH_INDICES]u32
	for q in 0 ..< slug.MAX_GLYPH_QUADS {
		base := u32(q) * 4
		off := q * 6
		slug_indices[off + 0] = base + 0
		slug_indices[off + 1] = base + 1
		slug_indices[off + 2] = base + 2
		slug_indices[off + 3] = base + 2
		slug_indices[off + 4] = base + 3
		slug_indices[off + 5] = base + 0
	}
	r.slug_ibuf = sg.make_buffer({
		usage = {index_buffer = true},
		data  = {ptr = &slug_indices, size = size_of(slug_indices)},
	})

	// --- Rect shader ---
	r.rect_shader = sg.make_shader({
		vertex_func = {
			source = RECT_VS_SOURCE,
			entry = "main",
		},
		fragment_func = {
			source = RECT_FS_SOURCE,
			entry = "main",
		},
		attrs = {
			0 = {base_type = .FLOAT, glsl_name = "inPos"},
			1 = {base_type = .FLOAT, glsl_name = "inCol"},
		},
		uniform_blocks = {
			0 = {
				stage = .VERTEX,
				size = size_of(Rect_Vs_Params),
				layout = .STD140,
				glsl_uniforms = {
					0 = {type = .FLOAT4, array_count = 4, glsl_name = "rect_vs_params"},
				},
			},
		},
	})

	// --- Rect pipeline ---
	r.rect_pip = sg.make_pipeline({
		shader = r.rect_shader,
		layout = {
			attrs = {
				0 = {format = .FLOAT2}, // pos: xy screen position
				1 = {format = .FLOAT4}, // col: RGBA color
			},
		},
		index_type = .UINT32,
		colors = {
			0 = {
				blend = {
					enabled = true,
					src_factor_rgb = .SRC_ALPHA,
					dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
					src_factor_alpha = .SRC_ALPHA,
					dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
				},
			},
		},
		depth = {
			write_enabled = false,
			compare = .ALWAYS,
		},
		cull_mode = .NONE,
	})

	// --- Rect vertex buffer (stream) ---
	r.rect_vbuf = sg.make_buffer({
		usage = {vertex_buffer = true, stream_update = true},
		size  = c.size_t(slug.MAX_RECTS * slug.VERTICES_PER_QUAD * size_of(slug.Rect_Vertex)),
	})

	// --- Rect index buffer (static) ---
	rect_indices: [slug.MAX_RECTS * slug.INDICES_PER_QUAD]u32
	for q in 0 ..< slug.MAX_RECTS {
		base := u32(q) * 4
		off := q * 6
		rect_indices[off + 0] = base + 0
		rect_indices[off + 1] = base + 1
		rect_indices[off + 2] = base + 2
		rect_indices[off + 3] = base + 2
		rect_indices[off + 4] = base + 3
		rect_indices[off + 5] = base + 0
	}
	r.rect_ibuf = sg.make_buffer({
		usage = {index_buffer = true},
		data  = {ptr = &rect_indices, size = size_of(rect_indices)},
	})

	return r
}

// Return a pointer to the slug context for draw calls.
ctx :: proc(r: ^Renderer) -> ^slug.Context {
	return &r.ctx
}

// ===================================================
// Font loading
// ===================================================

// Load a TTF font into the given slot (0-3), process it, and
// upload its curve/band textures to the GPU. All-in-one convenience.
load_font :: proc(r: ^Renderer, slot: int, path: string) -> bool {
	if slot < 0 || slot >= slug.MAX_FONT_SLOTS do return false

	font, font_ok := slug.font_load(path)
	if !font_ok do return false

	slug.register_font(&r.ctx, slot, font)

	loaded := slug.font_load_ascii(&r.ctx.fonts[slot])
	if loaded == 0 do return false

	pack := slug.font_process(&r.ctx.fonts[slot])
	defer slug.pack_result_destroy(&pack)

	return upload_font_textures(r, slot, &pack)
}

// Upload pre-packed font textures to a slot.
// For advanced use when you want to control the packing step yourself.
upload_font_textures :: proc(r: ^Renderer, slot: int, pack: ^slug.Texture_Pack_Result) -> bool {
	if slot < 0 || slot >= slug.MAX_FONT_SLOTS do return false
	return upload_textures_to(&r.font_sg[slot], pack)
}

// Upload a shared font atlas (all fonts packed into one texture pair).
// Call with the result of slug.fonts_process_shared().
upload_shared_textures :: proc(r: ^Renderer, pack: ^slug.Texture_Pack_Result) -> bool {
	return upload_textures_to(&r.shared_sg, pack)
}

// Load multiple fonts and pack them into a shared atlas.
// paths is a slice of TTF file paths, loaded into slots 0, 1, 2, ...
// Returns false if any font fails to load.
load_fonts_shared :: proc(r: ^Renderer, paths: []string) -> bool {
	if len(paths) > slug.MAX_FONT_SLOTS do return false

	for path, slot in paths {
		font, font_ok := slug.font_load(path)
		if !font_ok do return false

		slug.register_font(&r.ctx, slot, font)
		loaded := slug.font_load_ascii(&r.ctx.fonts[slot])
		if loaded == 0 do return false
	}

	pack := slug.fonts_process_shared(&r.ctx)
	defer slug.pack_result_destroy(&pack)

	return upload_shared_textures(r, &pack)
}

// Unload a font from a slot, releasing GPU textures and CPU glyph data.
// The slot can be reused with load_font or upload_font_textures.
unload_font :: proc(r: ^Renderer, slot: int) {
	if slot < 0 || slot >= slug.MAX_FONT_SLOTS do return

	fg := &r.font_sg[slot]
	if fg.loaded {
		destroy_font_sg(fg)
	}
	slug.unload_font(&r.ctx, slot)
}

// ===================================================
// Flush — upload vertices and issue draw calls
// ===================================================

// Upload vertices and issue draw calls for the current slug batch.
// Must be called inside an active sg.begin_pass / sg.end_pass block.
// scissor restricts rendering to a screen-space rectangle; zero value = full screen.
// Uses sg.append_buffer(), so safe to call multiple times per frame.
flush :: proc(r: ^Renderer, width, height: i32, scissor: slug.Scissor_Rect = {}) {
	if r.ctx.quad_count == 0 && r.ctx.rect_count == 0 do return

	w := f32(width)
	h := f32(height)

	// Orthographic projection: origin top-left, Y-down
	proj := linalg.matrix_ortho3d_f32(0, w, h, 0, -1, 1)

	// Apply scissor (Sokol handles Y-flip internally when origin_top_left=true)
	if scissor.w > 0 && scissor.h > 0 {
		sg.apply_scissor_rectf(scissor.x, scissor.y, scissor.w, scissor.h, true)
	} else {
		sg.apply_scissor_rectf(0, 0, w, h, true)
	}

	// --- Rect pass (drawn before text so rects appear behind glyphs) ---
	if r.ctx.rect_count > 0 {
		rect_vert_count := int(r.ctx.rect_count) * slug.VERTICES_PER_QUAD
		rect_vb_offset := sg.append_buffer(r.rect_vbuf, {
			ptr  = &r.ctx.rect_vertices[0],
			size = c.size_t(rect_vert_count * size_of(slug.Rect_Vertex)),
		})

		sg.apply_pipeline(r.rect_pip)
		sg.apply_bindings({
			vertex_buffers = {0 = r.rect_vbuf},
			vertex_buffer_offsets = {0 = rect_vb_offset},
			index_buffer = r.rect_ibuf,
		})
		sg.apply_uniforms(0, {
			ptr  = &Rect_Vs_Params{mvp = proj},
			size = size_of(Rect_Vs_Params),
		})
		sg.draw(0, i32(r.ctx.rect_count * slug.INDICES_PER_QUAD), 1)
	}

	// --- Slug text pass ---
	vert_count := slug.vertex_count(&r.ctx)
	if vert_count > 0 {
		vb_offset := sg.append_buffer(r.slug_vbuf, {
			ptr  = &r.ctx.vertices[0],
			size = c.size_t(vert_count) * size_of(slug.Vertex),
		})

		sg.apply_pipeline(r.slug_pip)

		vs_params := Vs_Params{mvp = proj, viewport = {w, h}}
		fs_params := Fs_Params{weight_boost = r.ctx.weight_boost ? 1.0 : 0.0}

		if r.ctx.shared_atlas && r.shared_sg.loaded {
			// Shared atlas: one texture bind, one draw call for all quads
			sg.apply_bindings({
				vertex_buffers = {0 = r.slug_vbuf},
				vertex_buffer_offsets = {0 = vb_offset},
				index_buffer = r.slug_ibuf,
				views = {0 = r.shared_sg.curve_view, 1 = r.shared_sg.band_view},
				samplers = {0 = r.shared_sg.curve_smp, 1 = r.shared_sg.band_smp},
			})
			sg.apply_uniforms(0, {ptr = &vs_params, size = size_of(Vs_Params)})
			sg.apply_uniforms(1, {ptr = &fs_params, size = size_of(Fs_Params)})
			sg.draw(0, i32(r.ctx.quad_count * slug.INDICES_PER_QUAD), 1)
		} else {
			// Per-font batched draw calls
			for fi in 0 ..< slug.MAX_FONT_SLOTS {
				qcount := r.ctx.font_quad_count[fi]
				if qcount == 0 do continue

				fg := &r.font_sg[fi]
				if !fg.loaded do continue

				sg.apply_bindings({
					vertex_buffers = {0 = r.slug_vbuf},
					vertex_buffer_offsets = {0 = vb_offset},
					index_buffer = r.slug_ibuf,
					views = {0 = fg.curve_view, 1 = fg.band_view},
					samplers = {0 = fg.curve_smp, 1 = fg.band_smp},
				})
				sg.apply_uniforms(0, {ptr = &vs_params, size = size_of(Vs_Params)})
				sg.apply_uniforms(1, {ptr = &fs_params, size = size_of(Fs_Params)})

				first_index := i32(r.ctx.font_quad_start[fi] * slug.INDICES_PER_QUAD)
				index_count := i32(qcount * slug.INDICES_PER_QUAD)
				sg.draw(first_index, index_count, 1)
			}
		}
	}
}

// ===================================================
// Shutdown — release all Sokol GFX resources
// ===================================================

// Destroy all Sokol GFX resources, free the slug context, and free the renderer.
destroy :: proc(r: ^Renderer) {
	if r == nil do return
	// Delete shared atlas
	if r.shared_sg.loaded {
		destroy_font_sg(&r.shared_sg)
	}

	// Delete per-font textures
	for fi in 0 ..< slug.MAX_FONT_SLOTS {
		if r.font_sg[fi].loaded {
			destroy_font_sg(&r.font_sg[fi])
		}
	}

	// Delete buffers
	sg.destroy_buffer(r.slug_vbuf)
	sg.destroy_buffer(r.slug_ibuf)
	sg.destroy_buffer(r.rect_vbuf)
	sg.destroy_buffer(r.rect_ibuf)

	// Delete pipelines and shaders
	sg.destroy_pipeline(r.slug_pip)
	sg.destroy_pipeline(r.rect_pip)
	sg.destroy_shader(r.slug_shader)
	sg.destroy_shader(r.rect_shader)

	// Destroy slug context (frees fonts and glyph data)
	slug.destroy(&r.ctx)

	free(r)
}

// ===================================================
// Internal helpers
// ===================================================

// Upload curve (RGBA16F) and band (RG16UI) textures for one font slot.
@(private = "file")
upload_textures_to :: proc(fg: ^Font_SG, pack: ^slug.Texture_Pack_Result) -> bool {
	// Curve texture: RGBA16F (half-float control points)
	fg.curve_img = sg.make_image({
		width        = i32(pack.curve_width),
		height       = i32(pack.curve_height),
		pixel_format = .RGBA16F,
		data = {
			mip_levels = {
				0 = {
					ptr  = raw_data(pack.curve_data[:]),
					size = c.size_t(len(pack.curve_data)) * size_of([4]u16),
				},
			},
		},
	})
	fg.curve_view = sg.make_view({
		texture = {image = fg.curve_img},
	})

	// Curve sampler: NEAREST (Slug uses texelFetch, no interpolation)
	fg.curve_smp = sg.make_sampler({
		min_filter = .NEAREST,
		mag_filter = .NEAREST,
		wrap_u = .CLAMP_TO_EDGE,
		wrap_v = .CLAMP_TO_EDGE,
	})

	// Band texture: RG16UI (unsigned integer band indices)
	fg.band_img = sg.make_image({
		width        = i32(pack.band_width),
		height       = i32(pack.band_height),
		pixel_format = .RG16UI,
		data = {
			mip_levels = {
				0 = {
					ptr  = raw_data(pack.band_data[:]),
					size = c.size_t(len(pack.band_data)) * size_of([2]u16),
				},
			},
		},
	})
	fg.band_view = sg.make_view({
		texture = {image = fg.band_img},
	})

	// Band sampler: NEAREST (integer textures cannot use filtering)
	fg.band_smp = sg.make_sampler({
		min_filter = .NEAREST,
		mag_filter = .NEAREST,
		wrap_u = .CLAMP_TO_EDGE,
		wrap_v = .CLAMP_TO_EDGE,
	})

	fg.loaded = true
	return true
}

// Release all Sokol GFX resources for a font slot.
@(private = "file")
destroy_font_sg :: proc(fg: ^Font_SG) {
	sg.destroy_sampler(fg.band_smp)
	sg.destroy_sampler(fg.curve_smp)
	sg.destroy_view(fg.band_view)
	sg.destroy_view(fg.curve_view)
	sg.destroy_image(fg.band_img)
	sg.destroy_image(fg.curve_img)
	fg^ = {}
}
