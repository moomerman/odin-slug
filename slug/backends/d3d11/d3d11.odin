#+build windows
package slug_d3d11

// ===================================================
// Direct3D 11 backend for odin-slug
//
// Renders GPU-evaluated Bezier text using the Slug algorithm.
// Wraps a slug.Context and manages D3D11 shaders, buffers, and per-font textures.
//
// The backend does NOT create or own the D3D11 device/swapchain.
// The caller provides the IDevice and IDeviceContext at init time,
// and passes the render target view to flush() each frame.
//
// Usage:
//   1. Create your own D3D11 device + swapchain
//   2. renderer := new(slug_d3d11.Renderer)
//   3. slug_d3d11.init(renderer, device, device_context)
//   4. slug_d3d11.load_font(renderer, 0, "myfont.ttf")
//   5. Per frame:
//        slug.begin(&renderer.ctx)
//        slug.draw_text(&renderer.ctx, ...)
//        slug.end(&renderer.ctx)
//        slug_d3d11.flush(renderer, width, height, rtv)
// ===================================================

import "core:math/linalg"
import "core:mem"

import d3d11 "vendor:directx/d3d11"
import d3dc "vendor:directx/d3d_compiler"
import dxgi "vendor:directx/dxgi"

import slug "../../"

// --- Per-font GPU resources ---

Font_D3D :: struct {
	curve_texture: ^d3d11.ITexture2D,
	curve_srv:     ^d3d11.IShaderResourceView,
	band_texture:  ^d3d11.ITexture2D,
	band_srv:      ^d3d11.IShaderResourceView,
	loaded:        bool,
}

// --- Renderer state ---

Renderer :: struct {
	ctx:                      slug.Context,

	// D3D11 handles (NOT owned — caller manages lifetime)
	device:                   ^d3d11.IDevice,
	dc:                       ^d3d11.IDeviceContext,

	// Slug text pipeline
	slug_vs:                  ^d3d11.IVertexShader,
	slug_ps:                  ^d3d11.IPixelShader,
	slug_layout:              ^d3d11.IInputLayout,
	slug_cb:                  ^d3d11.IBuffer,
	slug_vb:                  ^d3d11.IBuffer,
	slug_ib:                  ^d3d11.IBuffer,

	// Rect pipeline
	rect_vs:                  ^d3d11.IVertexShader,
	rect_ps:                  ^d3d11.IPixelShader,
	rect_layout:              ^d3d11.IInputLayout,
	rect_cb:                  ^d3d11.IBuffer,
	rect_vb:                  ^d3d11.IBuffer,
	rect_ib:                  ^d3d11.IBuffer,

	// Shared state
	blend_state:              ^d3d11.IBlendState,
	raster_state:             ^d3d11.IRasterizerState,
	raster_state_scissor:     ^d3d11.IRasterizerState,

	// Per-font textures
	font_d3d:                 [slug.MAX_FONT_SLOTS]Font_D3D,

	// Shared atlas textures
	shared_d3d:               Font_D3D,
}

// --- Constant buffer layouts (16-byte aligned) ---

Slug_Constants :: struct #packed {
	mvp:      matrix[4, 4]f32, // 64 bytes
	viewport: [2]f32,          // 8 bytes
	_pad:     [2]f32,          // 8 bytes padding → 80 total
}

Rect_Constants :: struct #packed {
	mvp: matrix[4, 4]f32, // 64 bytes
}

// --- Vertex layout constants ---

VERTEX_SIZE :: size_of(slug.Vertex)           // 80 bytes
RECT_VERTEX_SIZE :: size_of(slug.Rect_Vertex) // 24 bytes

// ===================================================
// HLSL Shader Model 5.0 shaders
// ===================================================

SLUG_VS_SOURCE :: `
cbuffer Constants : register(b0) {
    column_major float4x4 mvp;
    float2 viewport;
    float2 _pad;
};

struct VS_INPUT {
    float4 pos : POSITION0;
    float4 tex : TEXCOORD0;
    float4 jac : TEXCOORD1;
    float4 bnd : TEXCOORD2;
    float4 col : COLOR0;
};

struct VS_OUTPUT {
    float4 position : SV_Position;
    float4 color : COLOR0;
    float2 texcoord : TEXCOORD0;
    nointerpolation float4 banding : TEXCOORD1;
    nointerpolation int4 glyph : TEXCOORD2;
};

void SlugUnpack(float4 tex, float4 bnd, out float4 vbnd, out int4 vgly)
{
    uint2 g = asuint(tex.zw);
    vgly = int4(g.x & 0xFFFFu, g.x >> 16u, g.y & 0xFFFFu, g.y >> 16u);
    vbnd = bnd;
}

float2 SlugDilate(float4 pos, float4 tex, float4 jac,
                  float4 m0, float4 m1, float4 m3,
                  float2 dim, out float2 vpos)
{
    float2 n = normalize(pos.zw);
    float s = dot(m3.xy, pos.xy) + m3.w;
    float t = dot(m3.xy, n);

    float u = (s * dot(m0.xy, n) - t * (dot(m0.xy, pos.xy) + m0.w)) * dim.x;
    float v = (s * dot(m1.xy, n) - t * (dot(m1.xy, pos.xy) + m1.w)) * dim.y;

    float s2 = s * s;
    float st = s * t;
    float uv = u * u + v * v;
    float2 d = pos.zw * (s2 * (st + sqrt(uv)) / (uv - st * st));

    vpos = pos.xy + d;
    return float2(tex.x + dot(d, jac.xy), tex.y + dot(d, jac.zw));
}

VS_OUTPUT vs_main(VS_INPUT input)
{
    VS_OUTPUT output;
    float2 p;

    // Extract matrix rows. HLSL indexes as mvp[row][col], unlike GLSL's mvp[col][row].
    float4 m0 = mvp[0];
    float4 m1 = mvp[1];
    float4 m2 = mvp[2];
    float4 m3 = mvp[3];

    output.texcoord = SlugDilate(input.pos, input.tex, input.jac, m0, m1, m3, viewport, p);

    output.position.x = p.x * m0.x + p.y * m0.y + m0.w;
    output.position.y = p.x * m1.x + p.y * m1.y + m1.w;
    output.position.z = p.x * m2.x + p.y * m2.y + m2.w;
    output.position.w = p.x * m3.x + p.y * m3.y + m3.w;

    SlugUnpack(input.tex, input.bnd, output.banding, output.glyph);
    output.color = input.col;
    return output;
}
`

SLUG_PS_SOURCE :: `
#define kLogBandTextureWidth 12

Texture2D<float4> curveTexture : register(t0);
Texture2D<uint2>  bandTexture  : register(t1);

struct PS_INPUT {
    float4 position : SV_Position;
    float4 color : COLOR0;
    float2 texcoord : TEXCOORD0;
    nointerpolation float4 banding : TEXCOORD1;
    nointerpolation int4 glyph : TEXCOORD2;
};

uint CalcRootCode(float y1, float y2, float y3)
{
    uint i1 = asuint(y1) >> 31u;
    uint i2 = asuint(y2) >> 30u;
    uint i3 = asuint(y3) >> 29u;

    uint shift = (i2 & 2u) | (i1 & ~2u);
    shift = (i3 & 4u) | (shift & ~4u);

    return ((0x2E74u >> shift) & 0x0101u);
}

float2 SolveHorizPoly(float4 p12, float2 p3)
{
    float2 a = p12.xy - p12.zw * 2.0 + p3;
    float2 b = p12.xy - p12.zw;
    float ra = 1.0 / a.y;
    float rb = 0.5 / b.y;

    float d = sqrt(max(b.y * b.y - a.y * p12.y, 0.0));
    float t1 = (b.y - d) * ra;
    float t2 = (b.y + d) * ra;

    if (abs(a.y) < 1.0 / 65536.0) { t1 = t2 = p12.y * rb; }

    return float2((a.x * t1 - b.x * 2.0) * t1 + p12.x,
                  (a.x * t2 - b.x * 2.0) * t2 + p12.x);
}

float2 SolveVertPoly(float4 p12, float2 p3)
{
    float2 a = p12.xy - p12.zw * 2.0 + p3;
    float2 b = p12.xy - p12.zw;
    float ra = 1.0 / a.x;
    float rb = 0.5 / b.x;

    float d = sqrt(max(b.x * b.x - a.x * p12.x, 0.0));
    float t1 = (b.x - d) * ra;
    float t2 = (b.x + d) * ra;

    if (abs(a.x) < 1.0 / 65536.0) { t1 = t2 = p12.x * rb; }

    return float2((a.y * t1 - b.y * 2.0) * t1 + p12.y,
                  (a.y * t2 - b.y * 2.0) * t2 + p12.y);
}

int2 CalcBandLoc(int2 glyphLoc, uint offset)
{
    int2 bandLoc = int2(glyphLoc.x + (int)offset, glyphLoc.y);
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

float4 ps_main(PS_INPUT input) : SV_Target
{
    float2 renderCoord = input.texcoord;
    float4 bandTransform = input.banding;
    int4 glyphData = input.glyph;

    float2 emsPerPixel = fwidth(renderCoord);
    float2 pixelsPerEm = 1.0 / emsPerPixel;

    int2 bandMax = glyphData.zw;
    bandMax.y &= 0x00FF;

    int2 bandIndex = clamp((int2)(renderCoord * bandTransform.xy + bandTransform.zw),
                           int2(0, 0), bandMax);
    int2 glyphLoc = glyphData.xy;

    float xcov = 0.0;
    float xwgt = 0.0;

    uint2 hbandData = bandTexture.Load(int3(glyphLoc.x + bandIndex.y, glyphLoc.y, 0));
    int2 hbandLoc = CalcBandLoc(glyphLoc, hbandData.y);

    for (int curveIndex = 0; curveIndex < (int)hbandData.x; curveIndex++)
    {
        int2 curveLoc = (int2)bandTexture.Load(int3(hbandLoc.x + curveIndex, hbandLoc.y, 0));
        float4 p12 = curveTexture.Load(int3(curveLoc, 0)) - float4(renderCoord, renderCoord);
        float2 p3 = curveTexture.Load(int3(curveLoc.x + 1, curveLoc.y, 0)).xy - renderCoord;

        if (max(max(p12.x, p12.z), p3.x) * pixelsPerEm.x < -0.5) break;

        uint code = CalcRootCode(p12.y, p12.w, p3.y);
        if (code != 0u)
        {
            float2 r = SolveHorizPoly(p12, p3) * pixelsPerEm.x;

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

    uint2 vbandData = bandTexture.Load(int3(glyphLoc.x + bandMax.y + 1 + bandIndex.x, glyphLoc.y, 0));
    int2 vbandLoc = CalcBandLoc(glyphLoc, vbandData.y);

    for (int curveIndex = 0; curveIndex < (int)vbandData.x; curveIndex++)
    {
        int2 curveLoc = (int2)bandTexture.Load(int3(vbandLoc.x + curveIndex, vbandLoc.y, 0));
        float4 p12 = curveTexture.Load(int3(curveLoc, 0)) - float4(renderCoord, renderCoord);
        float2 p3 = curveTexture.Load(int3(curveLoc.x + 1, curveLoc.y, 0)).xy - renderCoord;

        if (max(max(p12.y, p12.w), p3.y) * pixelsPerEm.y < -0.5) break;

        uint code = CalcRootCode(p12.x, p12.z, p3.x);
        if (code != 0u)
        {
            float2 r = SolveVertPoly(p12, p3) * pixelsPerEm.y;

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
    return input.color * coverage;
}
`

RECT_VS_SOURCE :: `
cbuffer Constants : register(b0) {
    column_major float4x4 mvp;
};

struct VS_INPUT {
    float2 pos : POSITION0;
    float4 col : COLOR0;
};

struct VS_OUTPUT {
    float4 position : SV_Position;
    float4 color : COLOR0;
};

VS_OUTPUT vs_main(VS_INPUT input) {
    VS_OUTPUT output;
    output.position = mul(mvp, float4(input.pos, 0.0, 1.0));
    output.color = input.col;
    return output;
}
`

RECT_PS_SOURCE :: `
struct PS_INPUT {
    float4 position : SV_Position;
    float4 color : COLOR0;
};

float4 ps_main(PS_INPUT input) : SV_Target {
    return input.color;
}
`

// ===================================================
// Initialization
// ===================================================

// Initialize the D3D11 renderer. The device and device context are NOT owned
// by this renderer — the caller is responsible for their lifetime.
// Returns false if shader compilation or resource creation fails.
init :: proc(r: ^Renderer, device: ^d3d11.IDevice, dc: ^d3d11.IDeviceContext) -> bool {
	r.device = device
	r.dc = dc

	// --- Compile and create slug shaders ---
	slug_vs_blob: ^d3d11.IBlob
	slug_vs_err: ^d3d11.IBlob
	slug_vs_src := string(SLUG_VS_SOURCE)
	hr := d3dc.Compile(
		raw_data(slug_vs_src),
		len(slug_vs_src),
		nil, nil, nil,
		"vs_main", "vs_5_0",
		0, 0,
		&slug_vs_blob, &slug_vs_err,
	)
	if slug_vs_err != nil do slug_vs_err->Release()
	if hr < 0 do return false
	defer slug_vs_blob->Release()

	hr = device->CreateVertexShader(
		slug_vs_blob->GetBufferPointer(),
		slug_vs_blob->GetBufferSize(),
		nil,
		&r.slug_vs,
	)
	if hr < 0 do return false

	// Slug input layout: 5x float4
	slug_elems := [5]d3d11.INPUT_ELEMENT_DESC{
		{SemanticName = "POSITION", SemanticIndex = 0, Format = .R32G32B32A32_FLOAT, AlignedByteOffset = 0},
		{SemanticName = "TEXCOORD", SemanticIndex = 0, Format = .R32G32B32A32_FLOAT, AlignedByteOffset = 16},
		{SemanticName = "TEXCOORD", SemanticIndex = 1, Format = .R32G32B32A32_FLOAT, AlignedByteOffset = 32},
		{SemanticName = "TEXCOORD", SemanticIndex = 2, Format = .R32G32B32A32_FLOAT, AlignedByteOffset = 48},
		{SemanticName = "COLOR",    SemanticIndex = 0, Format = .R32G32B32A32_FLOAT, AlignedByteOffset = 64},
	}
	hr = device->CreateInputLayout(
		&slug_elems[0],
		5,
		slug_vs_blob->GetBufferPointer(),
		slug_vs_blob->GetBufferSize(),
		&r.slug_layout,
	)
	if hr < 0 do return false

	slug_ps_blob: ^d3d11.IBlob
	slug_ps_err: ^d3d11.IBlob
	slug_ps_src := string(SLUG_PS_SOURCE)
	hr = d3dc.Compile(
		raw_data(slug_ps_src),
		len(slug_ps_src),
		nil, nil, nil,
		"ps_main", "ps_5_0",
		0, 0,
		&slug_ps_blob, &slug_ps_err,
	)
	if slug_ps_err != nil do slug_ps_err->Release()
	if hr < 0 do return false
	defer slug_ps_blob->Release()

	hr = device->CreatePixelShader(
		slug_ps_blob->GetBufferPointer(),
		slug_ps_blob->GetBufferSize(),
		nil,
		&r.slug_ps,
	)
	if hr < 0 do return false

	// --- Slug buffers ---
	// Constant buffer
	slug_cb_desc := d3d11.BUFFER_DESC{
		ByteWidth = size_of(Slug_Constants),
		Usage     = .DYNAMIC,
		BindFlags = {.CONSTANT_BUFFER},
		CPUAccessFlags = {.WRITE},
	}
	hr = device->CreateBuffer(&slug_cb_desc, nil, &r.slug_cb)
	if hr < 0 do return false

	// Vertex buffer (dynamic)
	slug_vb_desc := d3d11.BUFFER_DESC{
		ByteWidth = u32(slug.MAX_GLYPH_VERTICES * VERTEX_SIZE),
		Usage     = .DYNAMIC,
		BindFlags = {.VERTEX_BUFFER},
		CPUAccessFlags = {.WRITE},
	}
	hr = device->CreateBuffer(&slug_vb_desc, nil, &r.slug_vb)
	if hr < 0 do return false

	// Index buffer (static quad pattern)
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
	slug_ib_desc := d3d11.BUFFER_DESC{
		ByteWidth = u32(slug.MAX_GLYPH_INDICES * size_of(u32)),
		Usage     = .DEFAULT,
		BindFlags = {.INDEX_BUFFER},
	}
	slug_ib_data := d3d11.SUBRESOURCE_DATA{
		pSysMem = &indices[0],
	}
	hr = device->CreateBuffer(&slug_ib_desc, &slug_ib_data, &r.slug_ib)
	if hr < 0 do return false

	// --- Rect shaders ---
	rect_vs_blob: ^d3d11.IBlob
	rect_vs_err: ^d3d11.IBlob
	rect_vs_src := string(RECT_VS_SOURCE)
	hr = d3dc.Compile(
		raw_data(rect_vs_src),
		len(rect_vs_src),
		nil, nil, nil,
		"vs_main", "vs_5_0",
		0, 0,
		&rect_vs_blob, &rect_vs_err,
	)
	if rect_vs_err != nil do rect_vs_err->Release()
	if hr < 0 do return false
	defer rect_vs_blob->Release()

	hr = device->CreateVertexShader(
		rect_vs_blob->GetBufferPointer(),
		rect_vs_blob->GetBufferSize(),
		nil,
		&r.rect_vs,
	)
	if hr < 0 do return false

	// Rect input layout: float2 pos + float4 col
	rect_elems := [2]d3d11.INPUT_ELEMENT_DESC{
		{SemanticName = "POSITION", SemanticIndex = 0, Format = .R32G32_FLOAT,       AlignedByteOffset = 0},
		{SemanticName = "COLOR",    SemanticIndex = 0, Format = .R32G32B32A32_FLOAT, AlignedByteOffset = 8},
	}
	hr = device->CreateInputLayout(
		&rect_elems[0],
		2,
		rect_vs_blob->GetBufferPointer(),
		rect_vs_blob->GetBufferSize(),
		&r.rect_layout,
	)
	if hr < 0 do return false

	rect_ps_blob: ^d3d11.IBlob
	rect_ps_err: ^d3d11.IBlob
	rect_ps_src := string(RECT_PS_SOURCE)
	hr = d3dc.Compile(
		raw_data(rect_ps_src),
		len(rect_ps_src),
		nil, nil, nil,
		"ps_main", "ps_5_0",
		0, 0,
		&rect_ps_blob, &rect_ps_err,
	)
	if rect_ps_err != nil do rect_ps_err->Release()
	if hr < 0 do return false
	defer rect_ps_blob->Release()

	hr = device->CreatePixelShader(
		rect_ps_blob->GetBufferPointer(),
		rect_ps_blob->GetBufferSize(),
		nil,
		&r.rect_ps,
	)
	if hr < 0 do return false

	// --- Rect buffers ---
	rect_cb_desc := d3d11.BUFFER_DESC{
		ByteWidth = size_of(Rect_Constants),
		Usage     = .DYNAMIC,
		BindFlags = {.CONSTANT_BUFFER},
		CPUAccessFlags = {.WRITE},
	}
	hr = device->CreateBuffer(&rect_cb_desc, nil, &r.rect_cb)
	if hr < 0 do return false

	rect_vb_desc := d3d11.BUFFER_DESC{
		ByteWidth = u32(slug.MAX_RECTS * slug.VERTICES_PER_QUAD * RECT_VERTEX_SIZE),
		Usage     = .DYNAMIC,
		BindFlags = {.VERTEX_BUFFER},
		CPUAccessFlags = {.WRITE},
	}
	hr = device->CreateBuffer(&rect_vb_desc, nil, &r.rect_vb)
	if hr < 0 do return false

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
	rect_ib_desc := d3d11.BUFFER_DESC{
		ByteWidth = u32(slug.MAX_RECTS * slug.INDICES_PER_QUAD * size_of(u32)),
		Usage     = .DEFAULT,
		BindFlags = {.INDEX_BUFFER},
	}
	rect_ib_data := d3d11.SUBRESOURCE_DATA{
		pSysMem = &rect_indices[0],
	}
	hr = device->CreateBuffer(&rect_ib_desc, &rect_ib_data, &r.rect_ib)
	if hr < 0 do return false

	// --- Blend state: SrcAlpha / OneMinusSrcAlpha ---
	blend_desc := d3d11.BLEND_DESC{}
	blend_desc.RenderTarget[0] = d3d11.RENDER_TARGET_BLEND_DESC{
		BlendEnable           = true,
		SrcBlend              = .SRC_ALPHA,
		DestBlend             = .INV_SRC_ALPHA,
		BlendOp               = .ADD,
		SrcBlendAlpha         = .ONE,
		DestBlendAlpha        = .INV_SRC_ALPHA,
		BlendOpAlpha          = .ADD,
		RenderTargetWriteMask = u8(d3d11.COLOR_WRITE_ENABLE_ALL),
	}
	hr = device->CreateBlendState(&blend_desc, &r.blend_state)
	if hr < 0 do return false

	// --- Rasterizer states ---
	raster_desc := d3d11.RASTERIZER_DESC{
		FillMode        = .SOLID,
		CullMode        = .NONE,
		DepthClipEnable = true,
	}
	hr = device->CreateRasterizerState(&raster_desc, &r.raster_state)
	if hr < 0 do return false

	raster_desc.ScissorEnable = true
	hr = device->CreateRasterizerState(&raster_desc, &r.raster_state_scissor)
	if hr < 0 do return false

	return true
}

// Return a pointer to the slug context for draw calls (slug.begin, slug.draw_text, etc).
ctx :: proc(r: ^Renderer) -> ^slug.Context {
	return &r.ctx
}

// ===================================================
// Font loading
// ===================================================

// Load a TTF font file, process it, and upload textures to the GPU.
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

// Upload pre-packed font textures to a GPU slot. The font must already be registered
// via slug.register_font(). Returns false if texture or SRV creation fails.
// Caller must call pack_result_destroy on the pack when done.
upload_font_textures :: proc(r: ^Renderer, slot: int, pack: ^slug.Texture_Pack_Result) -> bool {
	if slot < 0 || slot >= slug.MAX_FONT_SLOTS do return false

	fd := &r.font_d3d[slot]
	return upload_texture_pair(r.device, fd, pack)
}

// Upload a shared font atlas (all fonts packed into one texture pair).
// Use this when multiple fonts are packed together via fonts_process_shared().
// Returns false if texture or SRV creation fails.
upload_shared_textures :: proc(r: ^Renderer, pack: ^slug.Texture_Pack_Result) -> bool {
	return upload_texture_pair(r.device, &r.shared_d3d, pack)
}

// Load multiple fonts, pack them into a shared atlas, and upload textures.
// Each font is registered into a slot matching its index in paths[].
// Returns false if any font fails to load or texture upload fails.
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

// ===================================================
// Flush — upload vertices and issue draw calls
// ===================================================

// Upload slug vertices and issue draw calls for the current batch.
// rtv is the render target view for the current frame (caller-owned).
// scissor restricts rendering to a screen-space rectangle; zero value = full screen.
// Safe to call multiple times per frame (e.g. for different scissor regions).
flush :: proc(
	r: ^Renderer,
	width, height: i32,
	rtv: ^d3d11.IRenderTargetView,
	scissor: slug.Scissor_Rect = {},
) {
	quad_count := r.ctx.quad_count
	if quad_count == 0 && r.ctx.rect_count == 0 do return

	vert_count := slug.vertex_count(&r.ctx)
	w := f32(width)
	h := f32(height)
	dc := r.dc

	// Orthographic projection: origin top-left, Y-down (same as OpenGL)
	proj := linalg.matrix_ortho3d_f32(0, w, h, 0, -1, 1)

	// Set render target
	rtvs := [1]^d3d11.IRenderTargetView{rtv}
	dc->OMSetRenderTargets(1, &rtvs[0], nil)

	// Viewport
	viewport := d3d11.VIEWPORT{Width = w, Height = h, MaxDepth = 1.0}
	dc->RSSetViewports(1, &viewport)

	// Blend state
	dc->OMSetBlendState(r.blend_state, nil, 0xFFFFFFFF)

	// Rasterizer + scissor
	use_scissor := scissor.w > 0 && scissor.h > 0
	if use_scissor {
		dc->RSSetState(r.raster_state_scissor)
		rect := d3d11.RECT{
			left   = i32(scissor.x),
			top    = i32(scissor.y),
			right  = i32(scissor.x + scissor.w),
			bottom = i32(scissor.y + scissor.h),
		}
		dc->RSSetScissorRects(1, &rect)
	} else {
		dc->RSSetState(r.raster_state)
	}

	// --- Rect pass (before text, so rects appear behind glyphs) ---
	if r.ctx.rect_count > 0 {
		rect_vert_count := int(r.ctx.rect_count) * slug.VERTICES_PER_QUAD

		// Upload rect vertices
		mapped: d3d11.MAPPED_SUBRESOURCE
		hr := dc->Map(r.rect_vb, 0, .WRITE_DISCARD, {}, &mapped)
		if hr >= 0 {
			mem.copy(mapped.pData, &r.ctx.rect_vertices[0], rect_vert_count * RECT_VERTEX_SIZE)
			dc->Unmap(r.rect_vb, 0)
		}

		// Upload rect constants
		hr = dc->Map(r.rect_cb, 0, .WRITE_DISCARD, {}, &mapped)
		if hr >= 0 {
			consts := cast(^Rect_Constants)mapped.pData
			consts.mvp = proj
			dc->Unmap(r.rect_cb, 0)
		}

		// Draw rects
		stride := u32(RECT_VERTEX_SIZE)
		offset := u32(0)
		dc->IASetInputLayout(r.rect_layout)
		dc->IASetPrimitiveTopology(.TRIANGLELIST)
		dc->IASetVertexBuffers(0, 1, &r.rect_vb, &stride, &offset)
		dc->IASetIndexBuffer(r.rect_ib, .R32_UINT, 0)
		dc->VSSetShader(r.rect_vs, nil, 0)
		dc->PSSetShader(r.rect_ps, nil, 0)
		cbs := [1]^d3d11.IBuffer{r.rect_cb}
		dc->VSSetConstantBuffers(0, 1, &cbs[0])
		dc->DrawIndexed(u32(r.ctx.rect_count) * slug.INDICES_PER_QUAD, 0, 0)
	}

	// --- Slug text pass ---
	if quad_count > 0 {
		// Upload slug vertices
		mapped: d3d11.MAPPED_SUBRESOURCE
		hr := dc->Map(r.slug_vb, 0, .WRITE_DISCARD, {}, &mapped)
		if hr >= 0 {
			mem.copy(mapped.pData, &r.ctx.vertices[0], int(vert_count) * VERTEX_SIZE)
			dc->Unmap(r.slug_vb, 0)
		}

		// Upload slug constants
		hr = dc->Map(r.slug_cb, 0, .WRITE_DISCARD, {}, &mapped)
		if hr >= 0 {
			consts := cast(^Slug_Constants)mapped.pData
			consts.mvp = proj
			consts.viewport = {w, h}
			dc->Unmap(r.slug_cb, 0)
		}

		// Set pipeline state
		stride := u32(VERTEX_SIZE)
		offset := u32(0)
		dc->IASetInputLayout(r.slug_layout)
		dc->IASetPrimitiveTopology(.TRIANGLELIST)
		dc->IASetVertexBuffers(0, 1, &r.slug_vb, &stride, &offset)
		dc->IASetIndexBuffer(r.slug_ib, .R32_UINT, 0)
		dc->VSSetShader(r.slug_vs, nil, 0)
		dc->PSSetShader(r.slug_ps, nil, 0)
		cbs := [1]^d3d11.IBuffer{r.slug_cb}
		dc->VSSetConstantBuffers(0, 1, &cbs[0])

		if r.ctx.shared_atlas && r.shared_d3d.loaded {
			// Shared atlas: one texture bind, one draw call
			srvs := [2]^d3d11.IShaderResourceView{r.shared_d3d.curve_srv, r.shared_d3d.band_srv}
			dc->PSSetShaderResources(0, 2, &srvs[0])
			dc->DrawIndexed(quad_count * slug.INDICES_PER_QUAD, 0, 0)
		} else {
			// Per-font batched draw calls
			for fi in 0 ..< slug.MAX_FONT_SLOTS {
				qcount := r.ctx.font_quad_count[fi]
				if qcount == 0 do continue

				fd := &r.font_d3d[fi]
				if !fd.loaded do continue

				srvs := [2]^d3d11.IShaderResourceView{fd.curve_srv, fd.band_srv}
				dc->PSSetShaderResources(0, 2, &srvs[0])

				first_index := r.ctx.font_quad_start[fi] * slug.INDICES_PER_QUAD
				index_count := qcount * slug.INDICES_PER_QUAD
				dc->DrawIndexed(index_count, first_index, 0)
			}
		}
	}

	// Reset rasterizer
	if use_scissor {
		dc->RSSetState(r.raster_state)
	}
}

// ===================================================
// Font unloading and cleanup
// ===================================================

// Unload a font from a slot, releasing GPU textures and CPU glyph data.
unload_font :: proc(r: ^Renderer, slot: int) {
	if slot < 0 || slot >= slug.MAX_FONT_SLOTS do return

	fd := &r.font_d3d[slot]
	release_font_d3d(fd)
	slug.unload_font(&r.ctx, slot)
}

// Destroy all D3D11 resources and free the slug context.
// Does NOT release the device or device context (caller-owned).
destroy :: proc(r: ^Renderer) {
	// Per-font textures
	for fi in 0 ..< slug.MAX_FONT_SLOTS {
		release_font_d3d(&r.font_d3d[fi])
	}
	release_font_d3d(&r.shared_d3d)

	// Slug pipeline
	if r.slug_ib     != nil do r.slug_ib->Release()
	if r.slug_vb     != nil do r.slug_vb->Release()
	if r.slug_cb     != nil do r.slug_cb->Release()
	if r.slug_layout != nil do r.slug_layout->Release()
	if r.slug_ps     != nil do r.slug_ps->Release()
	if r.slug_vs     != nil do r.slug_vs->Release()

	// Rect pipeline
	if r.rect_ib     != nil do r.rect_ib->Release()
	if r.rect_vb     != nil do r.rect_vb->Release()
	if r.rect_cb     != nil do r.rect_cb->Release()
	if r.rect_layout != nil do r.rect_layout->Release()
	if r.rect_ps     != nil do r.rect_ps->Release()
	if r.rect_vs     != nil do r.rect_vs->Release()

	// State objects
	if r.blend_state          != nil do r.blend_state->Release()
	if r.raster_state         != nil do r.raster_state->Release()
	if r.raster_state_scissor != nil do r.raster_state_scissor->Release()

	// Destroy slug context
	slug.destroy(&r.ctx)
	r^ = {}
}

// ===================================================
// Internal helpers
// ===================================================

@(private = "file")
upload_texture_pair :: proc(
	device: ^d3d11.IDevice,
	fd: ^Font_D3D,
	pack: ^slug.Texture_Pack_Result,
) -> bool {
	// Curve texture: RGBA16F
	curve_desc := d3d11.TEXTURE2D_DESC{
		Width      = u32(pack.curve_width),
		Height     = u32(pack.curve_height),
		MipLevels  = 1,
		ArraySize  = 1,
		Format     = .R16G16B16A16_FLOAT,
		SampleDesc = {Count = 1},
		Usage      = .DEFAULT,
		BindFlags  = {.SHADER_RESOURCE},
	}
	curve_data := d3d11.SUBRESOURCE_DATA{
		pSysMem     = raw_data(pack.curve_data[:]),
		SysMemPitch = u32(pack.curve_width) * 8, // 4 channels * 2 bytes
	}
	hr := device->CreateTexture2D(&curve_desc, &curve_data, &fd.curve_texture)
	if hr < 0 do return false

	hr = device->CreateShaderResourceView(fd.curve_texture, nil, &fd.curve_srv)
	if hr < 0 {
		fd.curve_texture->Release()
		fd.curve_texture = nil
		return false
	}

	// Band texture: RG16UI
	band_desc := d3d11.TEXTURE2D_DESC{
		Width      = u32(pack.band_width),
		Height     = u32(pack.band_height),
		MipLevels  = 1,
		ArraySize  = 1,
		Format     = .R16G16_UINT,
		SampleDesc = {Count = 1},
		Usage      = .DEFAULT,
		BindFlags  = {.SHADER_RESOURCE},
	}
	band_data := d3d11.SUBRESOURCE_DATA{
		pSysMem     = raw_data(pack.band_data[:]),
		SysMemPitch = u32(pack.band_width) * 4, // 2 channels * 2 bytes
	}
	hr = device->CreateTexture2D(&band_desc, &band_data, &fd.band_texture)
	if hr < 0 {
		release_font_d3d(fd)
		return false
	}

	hr = device->CreateShaderResourceView(fd.band_texture, nil, &fd.band_srv)
	if hr < 0 {
		release_font_d3d(fd)
		return false
	}

	fd.loaded = true
	return true
}

@(private = "file")
release_font_d3d :: proc(fd: ^Font_D3D) {
	if fd.band_srv      != nil do fd.band_srv->Release()
	if fd.band_texture  != nil do fd.band_texture->Release()
	if fd.curve_srv     != nil do fd.curve_srv->Release()
	if fd.curve_texture != nil do fd.curve_texture->Release()
	fd^ = {}
}
