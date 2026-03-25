# odin-slug build script (PowerShell)
# Builds examples and optionally checks the library.
#
# External dependency backends:
#   Karl2D:  $env:KARL2D_PATH = "C:\path\to"   (parent dir of karl2d\)
#            auto-detects ..\karl2d\ as sibling directory
#   Sokol:   $env:SOKOL_PATH = "C:\path\to\sokol-odin\sokol"
#            auto-detects ..\sokol-odin\sokol\ as sibling directory

param(
    [string]$Command = "check"
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Do-Check {
    Write-Host "=== Checking core library ==="
    odin check slug/ -no-entry-point
    Write-Host "Core: OK"

    Write-Host "=== Checking OpenGL backend ==="
    odin check slug/backends/opengl/ -no-entry-point
    Write-Host "OpenGL backend: OK"

    Write-Host "=== Checking Raylib backend ==="
    odin check slug/backends/raylib/ -no-entry-point
    Write-Host "Raylib backend: OK"

    Write-Host "=== Checking Vulkan backend ==="
    odin check slug/backends/vulkan/ -no-entry-point
    Write-Host "Vulkan backend: OK"

    Write-Host "=== Checking SDL3 GPU backend ==="
    odin check slug/backends/sdl3gpu/ -no-entry-point
    Write-Host "SDL3 GPU backend: OK"

    Write-Host "=== Checking D3D11 backend ==="
    odin check slug/backends/d3d11/ -no-entry-point
    Write-Host "D3D11 backend: OK"

    Write-Host "=== Checking Karl2D backend ==="
    odin check slug/backends/karl2d/ -no-entry-point
    Write-Host "Karl2D backend: OK"

    $sokolPath = Resolve-SokolPath
    if ($sokolPath) {
        Write-Host "=== Checking Sokol backend ==="
        odin check slug/backends/sokol/ -no-entry-point "-collection:sokol=$sokolPath" -define:SOKOL_USE_GL=true
        Write-Host "Sokol backend: OK"
    } else {
        Write-Host "=== Skipping Sokol backend (SOKOL_PATH not set) ==="
    }

    Write-Host ""
    Write-Host "All packages compile cleanly."
}

function Do-CompileShaders {
    Write-Host "=== Compiling shaders ==="
    # Vulkan backend (push_constant uniforms)
    glslc slug/shaders/slug_450.vert -o slug/shaders/slug_vert.spv
    glslc slug/shaders/slug_450.frag -o slug/shaders/slug_frag.spv
    glslc slug/shaders/rect_450.vert -o slug/shaders/rect_vert.spv
    glslc slug/shaders/rect_450.frag -o slug/shaders/rect_frag.spv
    # SDL3 GPU backend (UBO uniforms)
    glslc slug/shaders/slug_sdl3.vert -o slug/shaders/slug_sdl3_vert.spv
    glslc slug/shaders/slug_sdl3.frag -o slug/shaders/slug_sdl3_frag.spv
    glslc slug/shaders/rect_sdl3.vert -o slug/shaders/rect_sdl3_vert.spv
    Write-Host "Shaders compiled."
}

function Do-BuildOpenGL {
    Write-Host "=== Building OpenGL demo ==="
    odin build examples/demo_opengl/ -out:demo_opengl.exe -collection:libs=.
    Write-Host "Built: demo_opengl.exe"
}

function Do-BuildRaylib {
    Write-Host "=== Building Raylib demo ==="
    odin build examples/demo_raylib/ -out:demo_raylib.exe -collection:libs=.
    Write-Host "Built: demo_raylib.exe"
    Write-Host "Note: if you see NULL GL function pointers at runtime, rebuild with -define:RAYLIB_SHARED=true"
}

function Do-BuildVulkan {
    Do-CompileShaders
    Write-Host "=== Building Vulkan demo ==="
    odin build examples/demo_vulkan/ -out:demo_vulkan.exe -collection:libs=.
    Write-Host "Built: demo_vulkan.exe"
}

function Do-BuildSDL3GPU {
    Do-CompileShaders
    Write-Host "=== Building SDL3 GPU demo ==="
    odin build examples/demo_sdl3gpu/ -out:demo_sdl3gpu.exe -collection:libs=.
    Write-Host "Built: demo_sdl3gpu.exe"
}

function Resolve-Karl2DPath {
    if ($env:KARL2D_PATH) { return $env:KARL2D_PATH }
    $sibling = Join-Path $ScriptDir "..\karl2d"
    if (Test-Path $sibling) { return (Resolve-Path (Join-Path $ScriptDir "..")).Path }
    return $null
}

function Resolve-SokolPath {
    if ($env:SOKOL_PATH) { return $env:SOKOL_PATH }
    $sibling = Join-Path $ScriptDir "..\sokol-odin\sokol"
    if (Test-Path $sibling) { return (Resolve-Path $sibling).Path }
    return $null
}

function Do-BuildD3D11 {
    Write-Host "=== Building D3D11 demo ==="
    odin build examples/demo_d3d11/ -out:demo_d3d11.exe -collection:libs=.
    Write-Host "Built: demo_d3d11.exe"
}

function Do-BuildKarl2D {
    Write-Host "=== Building Karl2D demo ==="
    $karl2dPath = Resolve-Karl2DPath
    if (-not $karl2dPath) {
        Write-Host "Error: KARL2D_PATH not set and ..\karl2d\ not found."
        Write-Host "  Clone it:  git clone https://github.com/nicoepp/karl2d ..\karl2d"
        Write-Host "  Or set:    `$env:KARL2D_PATH = 'C:\path\to'  (parent dir of karl2d\)"
        exit 1
    }
    odin build examples/demo_karl2d/ -out:demo_karl2d.exe -collection:libs=. "-collection:karl2d=$karl2dPath" -define:KARL2D_RENDER_BACKEND=gl
    Write-Host "Built: demo_karl2d.exe"
}

function Do-BuildSokol {
    Write-Host "=== Building Sokol GFX demo ==="
    $sokolPath = Resolve-SokolPath
    if (-not $sokolPath) {
        Write-Host "Error: SOKOL_PATH not set and ..\sokol-odin\sokol\ not found."
        Write-Host "  Clone it:  git clone https://github.com/floooh/sokol-odin ..\sokol-odin"
        Write-Host "             cd ..\sokol-odin\sokol; .\build_clibs_windows.cmd"
        Write-Host "  Or set:    `$env:SOKOL_PATH = 'C:\path\to\sokol-odin\sokol'"
        exit 1
    }
    odin build examples/demo_sokol/ -out:demo_sokol.exe -collection:libs=. "-collection:sokol=$sokolPath" -define:SOKOL_USE_GL=true
    Write-Host "Built: demo_sokol.exe"
}

function Do-Clean {
    Write-Host "=== Cleaning build artifacts ==="
    Remove-Item -Force -ErrorAction SilentlyContinue `
        demo_opengl.exe, demo_raylib.exe, demo_vulkan.exe, `
        demo_sdl3gpu.exe, demo_d3d11.exe, demo_karl2d.exe, demo_sokol.exe
    Get-ChildItem slug/shaders/*.spv -ErrorAction SilentlyContinue | Remove-Item -Force
    Write-Host "Clean."
}

switch ($Command) {
    "check"   { Do-Check }
    "opengl"  { Do-BuildOpenGL }
    "raylib"  { Do-BuildRaylib }
    "vulkan"  { Do-BuildVulkan }
    "sdl3gpu" { Do-BuildSDL3GPU }
    "d3d11"   { Do-BuildD3D11 }
    "karl2d"  { Do-BuildKarl2D }
    "sokol"   { Do-BuildSokol }
    "shaders" { Do-CompileShaders }
    "all"     { Do-BuildOpenGL; Do-BuildRaylib; Do-BuildVulkan; Do-BuildSDL3GPU }
    "clean"   { Do-Clean }
    "help"    {
        Write-Host "Usage: .\build.ps1 [command]"
        Write-Host ""
        Write-Host "Commands:"
        Write-Host "  check       Check that all packages compile (no binary output)"
        Write-Host "  opengl      Build the OpenGL/GLFW demo"
        Write-Host "  raylib      Build the Raylib integration demo"
        Write-Host "  vulkan      Compile shaders + build the Vulkan demo"
        Write-Host "  sdl3gpu     Compile shaders + build the SDL3 GPU demo"
        Write-Host "  d3d11       Build the D3D11 demo (Windows only)"
        Write-Host "  karl2d      Build the Karl2D demo (KARL2D_PATH or auto-detect ..\karl2d\)"
        Write-Host "  sokol       Build the Sokol GFX demo (SOKOL_PATH or auto-detect ..\sokol-odin\sokol\)"
        Write-Host "  shaders     Compile GLSL 4.50 + SDL3 shaders to SPIR-V (requires glslc)"
        Write-Host "  all         Build opengl + raylib + vulkan + sdl3gpu"
        Write-Host "  clean       Remove build artifacts"
    }
    default {
        Write-Host "Unknown command: $Command"
        Write-Host "Run: .\build.ps1 help"
    }
}
