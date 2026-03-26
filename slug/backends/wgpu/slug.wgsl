// ===================================================
// Slug WGSL shader — ported from the GLSL 3.30 OpenGL backend.
//
// Evaluates quadratic Bezier curves per-pixel for resolution-independent
// text rendering using horizontal and vertical band acceleration.
// ===================================================

const kLogBandTextureWidth: u32 = 12u;

// --- Uniforms ---

struct Uniforms {
    mvp:      mat4x4<f32>,
    viewport: vec2<f32>,
    _pad0:    f32,
    _pad1:    f32,
}

@group(0) @binding(0) var<uniform> uniforms: Uniforms;
@group(0) @binding(1) var curveTexture: texture_2d<f32>;
@group(0) @binding(2) var bandTexture: texture_2d<u32>;

// --- Vertex I/O ---

struct VertexInput {
    @location(0) pos: vec4<f32>,
    @location(1) tex: vec4<f32>,
    @location(2) jac: vec4<f32>,
    @location(3) bnd: vec4<f32>,
    @location(4) col: vec4<f32>,
}

struct VertexOutput {
    @builtin(position)              clip_pos: vec4<f32>,
    @location(0)                    vColor:   vec4<f32>,
    @location(1)                    vTexcoord: vec2<f32>,
    @location(2) @interpolate(flat) vBanding: vec4<f32>,
    @location(3) @interpolate(flat) vGlyph:  vec4<i32>,
}

// --- Vertex shader helpers ---

fn SlugUnpack(tex: vec4<f32>, bnd: vec4<f32>, vbnd: ptr<function, vec4<f32>>, vgly: ptr<function, vec4<i32>>) {
    let g = vec2<u32>(bitcast<u32>(tex.z), bitcast<u32>(tex.w));
    (*vgly) = vec4<i32>(
        i32(g.x & 0xFFFFu),
        i32(g.x >> 16u),
        i32(g.y & 0xFFFFu),
        i32(g.y >> 16u)
    );
    (*vbnd) = bnd;
}

fn SlugDilate(
    pos: vec4<f32>, tex: vec4<f32>, jac: vec4<f32>,
    m0: vec4<f32>, m1: vec4<f32>, m3: vec4<f32>,
    dim: vec2<f32>, vpos: ptr<function, vec2<f32>>
) -> vec2<f32> {
    let n = normalize(pos.zw);
    let s = dot(m3.xy, pos.xy) + m3.w;
    let t_val = dot(m3.xy, n);

    let u_val = (s * dot(m0.xy, n) - t_val * (dot(m0.xy, pos.xy) + m0.w)) * dim.x;
    let v_val = (s * dot(m1.xy, n) - t_val * (dot(m1.xy, pos.xy) + m1.w)) * dim.y;

    let s2 = s * s;
    let st = s * t_val;
    let uv = u_val * u_val + v_val * v_val;
    let d = pos.zw * (s2 * (st + sqrt(uv)) / (uv - st * st));

    (*vpos) = pos.xy + d;
    return vec2<f32>(tex.x + dot(d, jac.xy), tex.y + dot(d, jac.zw));
}

// --- Vertex shader ---

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    var out: VertexOutput;
    var p: vec2<f32>;

    let m0 = vec4<f32>(uniforms.mvp[0][0], uniforms.mvp[1][0], uniforms.mvp[2][0], uniforms.mvp[3][0]);
    let m1 = vec4<f32>(uniforms.mvp[0][1], uniforms.mvp[1][1], uniforms.mvp[2][1], uniforms.mvp[3][1]);
    let m2 = vec4<f32>(uniforms.mvp[0][2], uniforms.mvp[1][2], uniforms.mvp[2][2], uniforms.mvp[3][2]);
    let m3 = vec4<f32>(uniforms.mvp[0][3], uniforms.mvp[1][3], uniforms.mvp[2][3], uniforms.mvp[3][3]);

    out.vTexcoord = SlugDilate(in.pos, in.tex, in.jac, m0, m1, m3, uniforms.viewport, &p);

    out.clip_pos.x = p.x * m0.x + p.y * m0.y + m0.w;
    out.clip_pos.y = p.x * m1.x + p.y * m1.y + m1.w;
    out.clip_pos.z = p.x * m2.x + p.y * m2.y + m2.w;
    out.clip_pos.w = p.x * m3.x + p.y * m3.y + m3.w;

    var vbnd: vec4<f32>;
    var vgly: vec4<i32>;
    SlugUnpack(in.tex, in.bnd, &vbnd, &vgly);
    out.vBanding = vbnd;
    out.vGlyph = vgly;
    out.vColor = in.col;

    return out;
}

// --- Fragment shader helpers ---

fn CalcRootCode(y1: f32, y2: f32, y3: f32) -> u32 {
    let i1 = bitcast<u32>(y1) >> 31u;
    let i2 = bitcast<u32>(y2) >> 30u;
    let i3 = bitcast<u32>(y3) >> 29u;

    var shift = (i2 & 2u) | (i1 & ~2u);
    shift = (i3 & 4u) | (shift & ~4u);

    return ((0x2E74u >> shift) & 0x0101u);
}

fn SolveHorizPoly(p12: vec4<f32>, p3: vec2<f32>) -> vec2<f32> {
    let a = p12.xy - p12.zw * 2.0 + p3;
    let b = p12.xy - p12.zw;
    let ra = 1.0 / a.y;
    let rb = 0.5 / b.y;

    let d = sqrt(max(b.y * b.y - a.y * p12.y, 0.0));
    var t1 = (b.y - d) * ra;
    var t2 = (b.y + d) * ra;

    if (abs(a.y) < 1.0 / 65536.0) {
        t1 = p12.y * rb;
        t2 = t1;
    }

    return vec2<f32>(
        (a.x * t1 - b.x * 2.0) * t1 + p12.x,
        (a.x * t2 - b.x * 2.0) * t2 + p12.x
    );
}

fn SolveVertPoly(p12: vec4<f32>, p3: vec2<f32>) -> vec2<f32> {
    let a = p12.xy - p12.zw * 2.0 + p3;
    let b = p12.xy - p12.zw;
    let ra = 1.0 / a.x;
    let rb = 0.5 / b.x;

    let d = sqrt(max(b.x * b.x - a.x * p12.x, 0.0));
    var t1 = (b.x - d) * ra;
    var t2 = (b.x + d) * ra;

    if (abs(a.x) < 1.0 / 65536.0) {
        t1 = p12.x * rb;
        t2 = t1;
    }

    return vec2<f32>(
        (a.y * t1 - b.y * 2.0) * t1 + p12.y,
        (a.y * t2 - b.y * 2.0) * t2 + p12.y
    );
}

fn CalcBandLoc(glyphLoc: vec2<i32>, offset: u32) -> vec2<i32> {
    var bandLoc = vec2<i32>(glyphLoc.x + i32(offset), glyphLoc.y);
    bandLoc.y = bandLoc.y + (bandLoc.x >> kLogBandTextureWidth);
    bandLoc.x = bandLoc.x & ((1 << kLogBandTextureWidth) - 1);
    return bandLoc;
}

fn CalcCoverage(xcov: f32, ycov: f32, xwgt: f32, ywgt: f32) -> f32 {
    let coverage = max(
        abs(xcov * xwgt + ycov * ywgt) / max(xwgt + ywgt, 1.0 / 65536.0),
        min(abs(xcov), abs(ycov))
    );
    return clamp(coverage, 0.0, 1.0);
}

// --- Fragment shader ---

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let renderCoord = in.vTexcoord;
    let bandTransform = in.vBanding;
    let glyphData = in.vGlyph;

    let emsPerPixel = fwidth(renderCoord);
    let pixelsPerEm = 1.0 / emsPerPixel;

    var bandMax = glyphData.zw;
    bandMax.y = bandMax.y & 0x00FF;

    let bandIndex = clamp(
        vec2<i32>(vec2<f32>(renderCoord * bandTransform.xy + bandTransform.zw)),
        vec2<i32>(0, 0),
        bandMax
    );
    let glyphLoc = glyphData.xy;

    // --- Horizontal band (x-coverage) ---
    var xcov: f32 = 0.0;
    var xwgt: f32 = 0.0;

    let hbandData = textureLoad(bandTexture, vec2<i32>(glyphLoc.x + bandIndex.y, glyphLoc.y), 0).xy;
    let hbandLoc = CalcBandLoc(glyphLoc, hbandData.y);

    for (var curveIndex: i32 = 0; curveIndex < i32(hbandData.x); curveIndex = curveIndex + 1) {
        let curveLoc = vec2<i32>(textureLoad(bandTexture, vec2<i32>(hbandLoc.x + curveIndex, hbandLoc.y), 0).xy);
        let p12 = textureLoad(curveTexture, curveLoc, 0) - vec4<f32>(renderCoord, renderCoord);
        let p3 = textureLoad(curveTexture, vec2<i32>(curveLoc.x + 1, curveLoc.y), 0).xy - renderCoord;

        if (max(max(p12.x, p12.z), p3.x) * pixelsPerEm.x < -0.5) {
            break;
        }

        let code = CalcRootCode(p12.y, p12.w, p3.y);
        if (code != 0u) {
            let r = SolveHorizPoly(p12, p3) * pixelsPerEm.x;

            if ((code & 1u) != 0u) {
                xcov = xcov + clamp(r.x + 0.5, 0.0, 1.0);
                xwgt = max(xwgt, clamp(1.0 - abs(r.x) * 2.0, 0.0, 1.0));
            }

            if (code > 1u) {
                xcov = xcov - clamp(r.y + 0.5, 0.0, 1.0);
                xwgt = max(xwgt, clamp(1.0 - abs(r.y) * 2.0, 0.0, 1.0));
            }
        }
    }

    // --- Vertical band (y-coverage) ---
    var ycov: f32 = 0.0;
    var ywgt: f32 = 0.0;

    let vbandData = textureLoad(bandTexture, vec2<i32>(glyphLoc.x + bandMax.y + 1 + bandIndex.x, glyphLoc.y), 0).xy;
    let vbandLoc = CalcBandLoc(glyphLoc, vbandData.y);

    for (var curveIndex: i32 = 0; curveIndex < i32(vbandData.x); curveIndex = curveIndex + 1) {
        let curveLoc = vec2<i32>(textureLoad(bandTexture, vec2<i32>(vbandLoc.x + curveIndex, vbandLoc.y), 0).xy);
        let p12 = textureLoad(curveTexture, curveLoc, 0) - vec4<f32>(renderCoord, renderCoord);
        let p3 = textureLoad(curveTexture, vec2<i32>(curveLoc.x + 1, curveLoc.y), 0).xy - renderCoord;

        if (max(max(p12.y, p12.w), p3.y) * pixelsPerEm.y < -0.5) {
            break;
        }

        let code = CalcRootCode(p12.x, p12.z, p3.x);
        if (code != 0u) {
            let r = SolveVertPoly(p12, p3) * pixelsPerEm.y;

            if ((code & 1u) != 0u) {
                ycov = ycov - clamp(r.x + 0.5, 0.0, 1.0);
                ywgt = max(ywgt, clamp(1.0 - abs(r.x) * 2.0, 0.0, 1.0));
            }

            if (code > 1u) {
                ycov = ycov + clamp(r.y + 0.5, 0.0, 1.0);
                ywgt = max(ywgt, clamp(1.0 - abs(r.y) * 2.0, 0.0, 1.0));
            }
        }
    }

    let coverage = CalcCoverage(xcov, ycov, xwgt, ywgt);
    return in.vColor * coverage;
}
