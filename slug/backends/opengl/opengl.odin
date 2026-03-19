package slug_opengl

// ===================================================
// OpenGL 3.3 backend for odin-slug
//
// Renders GPU-evaluated Bezier text using the Slug algorithm.
// Wraps a slug.Context and manages GL shader, buffers, and per-font textures.
//
// Usage:
//   1. Create a Renderer, call init()
//   2. Load fonts with load_font()
//   3. Per frame:
//        slug.begin(&r.ctx)
//        slug.draw_text(...)
//        slug.end(&r.ctx)
//        flush(&r, width, height)
// ===================================================

import "core:fmt"
import "core:math/linalg"
import gl "vendor:OpenGL"

import slug "../../"

// --- Per-font GPU resources ---

Font_GL :: struct {
	curve_texture: u32, // GL texture handle (GL_RGBA16F)
	band_texture:  u32, // GL texture handle (GL_RG16UI)
	loaded:        bool,
}

// --- Renderer state ---

Renderer :: struct {
	ctx:           slug.Context,

	// Shader program and uniform locations
	program:       u32,
	mvp_loc:       i32,
	viewport_loc:  i32,
	curve_tex_loc: i32,
	band_tex_loc:  i32,

	// GL objects
	vao:           u32,
	vbo:           u32,
	ibo:           u32,

	// Per-font textures
	font_gl:       [slug.MAX_FONT_SLOTS]Font_GL,
}

// ===================================================
// GLSL 3.30 shaders (ported from the 4.50 Vulkan shaders)
// ===================================================

VERTEX_SHADER_SOURCE :: `#version 330 core

layout(location = 0) in vec4 inPos;
layout(location = 1) in vec4 inTex;
layout(location = 2) in vec4 inJac;
layout(location = 3) in vec4 inBnd;
layout(location = 4) in vec4 inCol;

uniform mat4 mvp;
uniform vec2 viewport;

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


FRAGMENT_SHADER_SOURCE :: `#version 330 core

#define kLogBandTextureWidth 12

in vec4 vColor;
in vec2 vTexcoord;
flat in vec4 vBanding;
flat in ivec4 vGlyph;

out vec4 fragColor;

uniform sampler2D curveTexture;
uniform usampler2D bandTexture;

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
    fragColor = vColor * coverage;
}
`


// --- Vertex layout constants ---

VERTEX_SIZE :: size_of(slug.Vertex) // 80 bytes (5x vec4)
ATTRIB_COUNT :: 5

// ===================================================
// Initialization
// ===================================================

init :: proc(r: ^Renderer) -> bool {
	// Compile and link shader program
	program, program_ok := gl.load_shaders_source(VERTEX_SHADER_SOURCE, FRAGMENT_SHADER_SOURCE)
	if !program_ok {
		fmt.eprintln("slug_opengl: failed to compile shaders")
		return false
	}
	r.program = program

	// Cache uniform locations
	r.mvp_loc = gl.GetUniformLocation(program, "mvp")
	r.viewport_loc = gl.GetUniformLocation(program, "viewport")
	r.curve_tex_loc = gl.GetUniformLocation(program, "curveTexture")
	r.band_tex_loc = gl.GetUniformLocation(program, "bandTexture")

	// Create VAO
	gl.GenVertexArrays(1, &r.vao)
	gl.BindVertexArray(r.vao)

	// Create VBO (dynamic — re-uploaded each frame)
	gl.GenBuffers(1, &r.vbo)
	gl.BindBuffer(gl.ARRAY_BUFFER, r.vbo)
	gl.BufferData(gl.ARRAY_BUFFER, slug.MAX_GLYPH_VERTICES * VERTEX_SIZE, nil, gl.DYNAMIC_DRAW)

	// Set up vertex attributes: 5x vec4, stride = 80 bytes
	for i in u32(0) ..< ATTRIB_COUNT {
		gl.EnableVertexAttribArray(i)
		gl.VertexAttribPointer(
			i, // attribute index
			4, // components per attribute (vec4)
			gl.FLOAT, // type
			false, // normalized
			i32(VERTEX_SIZE), // stride
			uintptr(i * 16), // offset (each vec4 = 16 bytes)
		)
	}

	// Create IBO with pre-generated quad indices (0,1,2, 2,3,0 pattern)
	gl.GenBuffers(1, &r.ibo)
	gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, r.ibo)

	indices: [slug.MAX_GLYPH_INDICES]u32
	for q in 0 ..< slug.MAX_GLYPH_QUADS {
		base := u32(q) * 4
		off := q * 6
		indices[off + 0] = base + 0
		indices[off + 1] = base + 1
		indices[off + 2] = base + 2
		indices[off + 3] = base + 2
		indices[off + 4] = base + 3
		indices[off + 5] = base + 0
	}

	gl.BufferData(
		gl.ELEMENT_ARRAY_BUFFER,
		slug.MAX_GLYPH_INDICES * size_of(u32),
		&indices,
		gl.STATIC_DRAW,
	)

	gl.BindVertexArray(0)
	return true
}

// ===================================================
// Font loading
// ===================================================

load_font :: proc(r: ^Renderer, slot: int, path: string) -> bool {
	if slot < 0 || slot >= slug.MAX_FONT_SLOTS {
		fmt.eprintln("slug_opengl: invalid font slot", slot)
		return false
	}

	// Load font via slug core
	font, font_ok := slug.font_load(path)
	if !font_ok {
		fmt.eprintln("slug_opengl: failed to load font:", path)
		return false
	}

	r.ctx.fonts[slot] = font
	r.ctx.font_loaded[slot] = true
	if slot >= r.ctx.font_count {
		r.ctx.font_count = slot + 1
	}

	// Load ASCII glyphs and process into texture data
	loaded := slug.font_load_ascii(&r.ctx.fonts[slot])
	if loaded == 0 {
		fmt.eprintln("slug_opengl: no glyphs loaded from font:", path)
		return false
	}

	pack := slug.font_process(&r.ctx.fonts[slot])
	defer slug.pack_result_destroy(&pack)

	fg := &r.font_gl[slot]

	// --- Curve texture: GL_RGBA16F ---
	gl.GenTextures(1, &fg.curve_texture)
	gl.BindTexture(gl.TEXTURE_2D, fg.curve_texture)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, i32(gl.NEAREST))
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, i32(gl.NEAREST))
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, i32(gl.CLAMP_TO_EDGE))
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, i32(gl.CLAMP_TO_EDGE))
	gl.TexImage2D(
		gl.TEXTURE_2D,
		0, // level
		i32(gl.RGBA16F), // internal format
		i32(pack.curve_width), // width
		i32(pack.curve_height), // height
		0, // border
		gl.RGBA, // format
		gl.HALF_FLOAT, // type
		raw_data(pack.curve_data[:]),
	)

	// --- Band texture: GL_RG16UI ---
	gl.GenTextures(1, &fg.band_texture)
	gl.BindTexture(gl.TEXTURE_2D, fg.band_texture)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, i32(gl.NEAREST))
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, i32(gl.NEAREST))
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, i32(gl.CLAMP_TO_EDGE))
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, i32(gl.CLAMP_TO_EDGE))
	gl.TexImage2D(
		gl.TEXTURE_2D,
		0, // level
		i32(gl.RG16UI), // internal format
		i32(pack.band_width), // width
		i32(pack.band_height), // height
		0, // border
		gl.RG_INTEGER, // format (integer textures need _INTEGER format)
		gl.UNSIGNED_SHORT, // type
		raw_data(pack.band_data[:]),
	)

	fg.loaded = true
	fmt.printf("slug_opengl: font slot %d loaded (%d glyphs)\n", slot, loaded)
	return true
}

// ===================================================
// Flush — upload vertices and issue per-font draw calls
// ===================================================

flush :: proc(r: ^Renderer, width, height: i32) {
	quad_count := r.ctx.quad_count
	if quad_count == 0 do return

	vert_count := slug.vertex_count(&r.ctx)
	w := f32(width)
	h := f32(height)

	// Orthographic projection: origin top-left, Y-down
	// Maps (0,0) to top-left and (w,h) to bottom-right in screen coords.
	proj := linalg.matrix_ortho3d_f32(0, w, h, 0, -1, 1)

	// Set all GL state explicitly — don't assume the host left defaults.
	// Bind default framebuffer in case the host left an FBO bound.
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
	// Sync viewport to our projection matrix dimensions.
	gl.Viewport(0, 0, width, height)
	// Prevent backface culling from discarding our screen-aligned quads.
	gl.Disable(gl.CULL_FACE)
	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
	gl.Disable(gl.DEPTH_TEST)

	gl.UseProgram(r.program)

	// Set uniforms
	gl.UniformMatrix4fv(r.mvp_loc, 1, false, &proj[0][0])
	gl.Uniform2f(r.viewport_loc, w, h)

	// Upload vertex data
	gl.BindVertexArray(r.vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, r.vbo)
	gl.BufferSubData(gl.ARRAY_BUFFER, 0, int(vert_count) * VERTEX_SIZE, &r.ctx.vertices[0])

	// Per-font batched draw calls
	for fi in 0 ..< slug.MAX_FONT_SLOTS {
		qcount := r.ctx.font_quad_count[fi]
		if qcount == 0 do continue

		fg := &r.font_gl[fi]
		if !fg.loaded do continue

		// Bind curve texture to unit 0
		gl.ActiveTexture(gl.TEXTURE0)
		gl.BindTexture(gl.TEXTURE_2D, fg.curve_texture)
		gl.Uniform1i(r.curve_tex_loc, 0)

		// Bind band texture to unit 1
		gl.ActiveTexture(gl.TEXTURE0 + 1)
		gl.BindTexture(gl.TEXTURE_2D, fg.band_texture)
		gl.Uniform1i(r.band_tex_loc, 1)

		// Draw this font's quad range
		first_index := r.ctx.font_quad_start[fi] * slug.INDICES_PER_QUAD
		index_count := qcount * slug.INDICES_PER_QUAD

		gl.DrawElements(
			gl.TRIANGLES,
			i32(index_count),
			gl.UNSIGNED_INT,
			rawptr(uintptr(first_index * size_of(u32))),
		)
	}

	gl.BindVertexArray(0)
	gl.UseProgram(0)
}

// ===================================================
// Upload font textures manually (for advanced usage)
// ===================================================
//
// Use this when you need to load SVG icons into the font between
// font_load_ascii and font_process, or when you want more control
// over the loading pipeline. For simple cases, use load_font() instead.

upload_font_textures :: proc(r: ^Renderer, slot: int, pack: ^slug.Texture_Pack_Result) -> bool {
	if slot < 0 || slot >= slug.MAX_FONT_SLOTS do return false

	fg := &r.font_gl[slot]

	// Curve texture: GL_RGBA16F
	gl.GenTextures(1, &fg.curve_texture)
	gl.BindTexture(gl.TEXTURE_2D, fg.curve_texture)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, i32(gl.NEAREST))
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, i32(gl.NEAREST))
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, i32(gl.CLAMP_TO_EDGE))
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, i32(gl.CLAMP_TO_EDGE))
	gl.TexImage2D(
		gl.TEXTURE_2D,
		0,
		i32(gl.RGBA16F),
		i32(pack.curve_width),
		i32(pack.curve_height),
		0,
		gl.RGBA,
		gl.HALF_FLOAT,
		raw_data(pack.curve_data[:]),
	)

	// Band texture: GL_RG16UI
	gl.GenTextures(1, &fg.band_texture)
	gl.BindTexture(gl.TEXTURE_2D, fg.band_texture)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, i32(gl.NEAREST))
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, i32(gl.NEAREST))
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, i32(gl.CLAMP_TO_EDGE))
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, i32(gl.CLAMP_TO_EDGE))
	gl.TexImage2D(
		gl.TEXTURE_2D,
		0,
		i32(gl.RG16UI),
		i32(pack.band_width),
		i32(pack.band_height),
		0,
		gl.RG_INTEGER,
		gl.UNSIGNED_SHORT,
		raw_data(pack.band_data[:]),
	)

	fg.loaded = true
	return true
}

// ===================================================
// Shutdown — release all GL resources and slug context
// ===================================================

destroy :: proc(r: ^Renderer) {
	// Delete per-font textures
	for fi in 0 ..< slug.MAX_FONT_SLOTS {
		fg := &r.font_gl[fi]
		if fg.loaded {
			gl.DeleteTextures(1, &fg.curve_texture)
			gl.DeleteTextures(1, &fg.band_texture)
			fg^ = {}
		}
	}

	// Delete GL objects
	if r.ibo != 0 do gl.DeleteBuffers(1, &r.ibo)
	if r.vbo != 0 do gl.DeleteBuffers(1, &r.vbo)
	if r.vao != 0 do gl.DeleteVertexArrays(1, &r.vao)
	if r.program != 0 do gl.DeleteProgram(r.program)

	// Destroy slug context (frees fonts and glyph data)
	slug.destroy(&r.ctx)

	r^ = {}
}
