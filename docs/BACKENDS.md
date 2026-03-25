# Backend Comparison Guide

odin-slug ships seven GPU backends. They all render identical output — the same
Slug fragment shader evaluating the same Bezier curves — but differ in API
complexity, platform reach, and frame lifecycle. This guide helps you pick one.

## Quick Comparison

| Backend | Graphics API | GLSL | External Deps | Complexity | Frame Model |
|---------|-------------|------|---------------|------------|-------------|
| **OpenGL** | OpenGL 3.3 | 3.30 | None (vendor lib) | Low | Stateless |
| **Raylib** | OpenGL 3.3 (via Raylib) | 3.30 | None (vendor lib) | Lowest | Stateless |
| **Karl2D** | OpenGL 3.3 (via Karl2D) | 3.30 | Karl2D package | Lowest | Stateless |
| **D3D11** | Direct3D 11 (Windows) | HLSL 5.0 | None (vendor lib) | Low | Stateless |
| **Sokol** | GL 4.3 / Metal / D3D11 / WebGPU | 430 | sokol-odin | Low | Stateless |
| **SDL3 GPU** | Vulkan / D3D12 / Metal | SPIR-V | None (vendor lib) | Medium | 3-step |
| **Vulkan** | Vulkan 1.x | SPIR-V | None (vendor lib) | High | 3-step |

**Complexity** rates how much GPU boilerplate the backend handles for you vs
exposing to the caller. "Lowest" means you barely touch GPU state at all.

## Frame Models

### Stateless (OpenGL, Raylib, Karl2D, D3D11, Sokol)

The caller manages `slug.begin()` / `slug.end()` directly, then calls `flush()`
which uploads vertices and issues draw calls in one shot. No GPU synchronization
to think about.

```odin
slug.begin(&renderer.ctx)           // or slug.begin(backend.ctx(renderer))
// ... draw calls ...
slug.end(&renderer.ctx)
backend.flush(&renderer, width, height)
```

For multi-flush (scissored passes), just repeat the cycle:

```odin
slug.begin(ctx)
// draw calls for region A
slug.end(ctx)
backend.flush(renderer, w, h, scissor_a)

slug.begin(ctx)
// draw calls for region B
slug.end(ctx)
backend.flush(renderer, w, h, scissor_b)
```

### 3-Step (Vulkan, SDL3 GPU)

These backends manage the command buffer / render pass lifecycle internally.
`begin_frame()` acquires GPU resources and calls `slug.begin()` for you.
`flush()` calls `slug.end()` and records draw commands. `present_frame()`
submits and presents.

```odin
if backend.begin_frame(renderer) {
    // ... draw calls on renderer.ctx ...
    backend.flush(renderer)                  // optional scissor param
    backend.present_frame(renderer)
}
```

For multi-flush, just call `flush()` multiple times — each call ends the current
slug batch and starts a new one automatically:

```odin
if backend.begin_frame(renderer) {
    // draw calls for region A
    backend.flush(renderer, scissor_a)
    // draw calls for region B
    backend.flush(renderer, scissor_b)
    backend.present_frame(renderer)
}
```

The caller does **not** call `slug.begin()` / `slug.end()` — the backend handles it.

## Context Access

All backends store a `slug.Context` inside their `Renderer` struct. How you
access it differs by backend complexity:

| Backend | Access Pattern |
|---------|---------------|
| OpenGL | `&renderer.ctx` (direct field) |
| Vulkan | `&renderer.ctx` (direct field) |
| SDL3 GPU | `&renderer.ctx` (direct field) |
| Raylib | `slug_raylib.ctx(&renderer)` (proc) |
| Karl2D | `slug_karl2d.ctx(&renderer)` (proc) |
| Sokol | `slug_sokol.ctx(&renderer)` (proc) |

The wrapper backends (Raylib, Karl2D, Sokol) use a `ctx()` proc because
their `Renderer` wraps another struct and the field path isn't a simple
`renderer.ctx`. Low-level backends expose the field directly — you're already
managing GPU state, so one more direct field access is consistent with that level.

## When to Use Each Backend

### OpenGL — "I just need text rendering"

Best for: custom OpenGL engines, learning projects, headless rendering.

You create the GL context yourself (GLFW, SDL, whatever). The backend compiles
its own shaders and manages its own VAO/VBO. Zero interference with your
existing GL state — flush sets everything explicitly and restores nothing
(stateless design).

Requires: OpenGL 3.3 Core Profile.

### Raylib — "I'm making a game with Raylib"

Best for: Raylib games that need resolution-independent text.

Wraps the OpenGL backend with two additions: loads `vendor:OpenGL` function
pointers from Raylib's GL context, and flushes Raylib's internal draw batch
before touching GL state. ~85 lines of code on top of the OpenGL backend.

Call `rl.InitWindow()` before `slug_raylib.init()`. Call `flush()` between
`slug.end()` and any post-slug Raylib drawing.

**Windows note:** Raylib's GLAD loader may return NULL for some GL functions
on Windows. If you hit this, build with `-define:RAYLIB_SHARED=true` and
link against the Raylib DLL instead of the static lib. See the README
troubleshooting section.

### Karl2D — "I'm making a game with Karl2D"

Best for: Karl2D games. Nearly identical to the Raylib backend in structure.

Karl2D creates its own GL context (GLX/EGL/WGL) and has its own internal
GL loader. Like Raylib, it doesn't populate `vendor:OpenGL`, so this backend
handles that. It also flushes Karl2D's draw batch before slug issues GL calls.

The caller passes `k2.draw_current_batch` as a callback during init — this
avoids a hard import dependency on the Karl2D package.

Requires: Karl2D source. The build script auto-detects `../karl2d/` as a
sibling directory. Override with `KARL2D_PATH` environment variable if your
Karl2D checkout is elsewhere.

### D3D11 — "I want native Windows rendering without OpenGL"

Best for: Windows-native applications that want Direct3D 11 rendering without
the overhead of Vulkan or the cross-platform abstraction of SDL3 GPU.

The D3D11 backend embeds HLSL Shader Model 5.0 source as string constants and
compiles them at init time via `d3d_compiler.Compile()`. No external shader
files or toolchain needed.

The caller owns the `IDevice`, `IDeviceContext`, and swapchain. The backend
receives device/context at `init()` and the render target view at each `flush()`
call. This makes it easy to integrate into existing D3D11 applications.

No external dependencies — uses Odin's `vendor:directx/d3d11` and
`vendor:directx/d3d_compiler` bindings.

```sh
# Windows only
./build.sh d3d11
# or: odin build examples/demo_d3d11/ -out:demo_d3d11 -collection:libs=.
```

### Sokol — "I want cross-platform without Vulkan complexity"

Best for: cross-platform apps targeting GL + Metal + D3D11 + WebGPU through
one API, without the complexity of raw Vulkan or SDL3 GPU.

Sokol GFX is a thin C abstraction over multiple graphics APIs. The backend
compiles GLSL 430 shaders inline (no external .spv files) and uses Sokol's
`append_buffer()` for multi-flush-safe vertex uploads.

The caller manages `sg.begin_pass()` / `sg.end_pass()` / `sg.commit()` —
slug's `flush()` issues pipeline/binding/draw calls inside the active pass.

Requires: sokol-odin clone with pre-compiled C libraries. The build script
auto-detects `../sokol-odin/sokol/` as a sibling directory. Override with
`SOKOL_PATH` if your clone is elsewhere (point to the `sokol/` subdirectory
inside the clone, not the repo root).

```sh
# Linux/macOS
git clone https://github.com/floooh/sokol-odin ../sokol-odin
cd ../sokol-odin/sokol && bash build_clibs_linux.sh
# If not a sibling directory, set the path explicitly:
export SOKOL_PATH=/path/to/sokol-odin/sokol
./build.sh sokol
```

```cmd
:: Windows (Developer Command Prompt)
git clone https://github.com/floooh/sokol-odin ..\sokol-odin
cd ..\sokol-odin\sokol
build_clibs_windows.cmd
cd ..\..\odin-slug
:: If not a sibling directory, set the path explicitly:
set SOKOL_PATH=C:\path\to\sokol-odin\sokol
build.bat sokol
```

### SDL3 GPU — "I want modern GPU access with SDL3"

Best for: cross-platform apps using SDL3's GPU API (Vulkan/D3D12/Metal
under the hood, backend selected automatically).

SDL3 GPU sits between raw Vulkan and high-level wrappers. You get explicit
control over command buffers, copy passes, and render passes, but SDL3
handles device selection, swapchain management, and shader translation.

Uses SPIR-V shaders that must be compiled before building (run `./build.sh shaders`).
For D3D12/Metal cross-compilation, use SDL_shadercross or provide additional
bytecode formats.

The caller owns the `sdl.GPUDevice` — init does not create or destroy it.

### Vulkan — "I need full Vulkan control"

Best for: custom Vulkan engines where you want to integrate slug into your
own render pass, or when you need maximum control over synchronization.

This is the most complex backend (~760 lines). It creates its own Vulkan
instance, device, swapchain, render pass, descriptor sets, and pipelines.
The caller provides an SDL3 window with the `.VULKAN` flag.

Push constants are used for uniforms (no UBO allocation). Each font gets
its own descriptor set with curve + band texture bindings. Vertex data is
uploaded via a persistent mapped buffer.

Ideal when you're already deep in Vulkan and want slug to fit into your
existing rendering architecture.

## Shared Atlas vs Per-Font Textures

All six backends support both modes:

**Per-font** (default): Each font gets its own curve + band texture pair.
Draw calls are batched per-font — one draw call per active font per flush.
Use `load_font()` for each font independently.

**Shared atlas**: All fonts are packed into a single texture pair. One draw
call renders all text regardless of font. Use `load_fonts_shared()` to load
all fonts at once, or manually call `fonts_process_shared()` + `upload_shared_textures()`.

Shared atlas is better when you have 2-4 fonts and want minimal draw calls.
Per-font is better when fonts are loaded/unloaded dynamically.

## Build Requirements

| Backend | Build Command | Prerequisites |
|---------|--------------|---------------|
| OpenGL | `./build.sh opengl` | OpenGL 3.3 driver |
| Raylib | `./build.sh raylib` | Raylib (Odin vendor lib) |
| D3D11 | `./build.sh d3d11` | Windows with D3D11 GPU (no external deps) |
| Karl2D | `./build.sh karl2d` | Karl2D source (auto-detects sibling dir, or set `KARL2D_PATH`) |
| Sokol | `./build.sh sokol` | sokol-odin + C libs compiled (auto-detects sibling dir, or set `SOKOL_PATH`) |
| SDL3 GPU | `./build.sh sdl3gpu` | `./build.sh shaders` first (needs `glslc`) |
| Vulkan | `./build.sh vulkan` | `./build.sh shaders` first (needs `glslc`), Vulkan driver |

## Platform Support

| Backend | Linux | Windows | macOS | Web |
|---------|-------|---------|-------|-----|
| OpenGL | Yes | Yes | Yes (3.3 deprecated) | No |
| Raylib | Yes | Yes | Yes | No |
| D3D11 | No | Yes | No | No |
| Karl2D | Yes | Yes | Untested | No |
| Sokol | Yes (GL) | Yes (GL/D3D11) | Yes (Metal) | Possible (WebGPU) |
| SDL3 GPU | Yes (Vulkan) | Yes (Vulkan/D3D12) | Yes (Metal) | No |
| Vulkan | Yes | Yes | MoltenVK | No |

macOS note: Apple deprecated OpenGL at 3.3 and will not update it further.
For macOS, prefer Sokol (Metal backend) or SDL3 GPU (Metal backend).
