#!/bin/bash
set -e

# odin-slug build script
# Builds examples and optionally checks the library.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

usage() {
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  check       Check that all packages compile (no binary output)"
    echo "  opengl      Build the OpenGL/GLFW demo"
    echo "  raylib      Build the Raylib integration demo"
    echo "  vulkan      Compile shaders + build the Vulkan demo"
    echo "  sdl3gpu     Compile shaders + build the SDL3 GPU demo"
    echo "  karl2d      Build the Karl2D integration demo (requires KARL2D_PATH)"
    echo "  d3d11       Build the D3D11 demo (Windows only)"
    echo "  sokol       Build the Sokol GFX demo (requires SOKOL_PATH)"
    echo "  shaders     Compile GLSL 4.50 shaders to SPIR-V (requires glslc)"
    echo "  all         Build all examples (except karl2d, sokol, d3d11)"
    echo "  clean       Remove build artifacts"
    echo ""
    echo "If no command is given, 'check' is run."
}

do_check() {
    echo "=== Checking core library ==="
    odin check slug/ -no-entry-point
    echo "Core: OK"

    echo "=== Checking OpenGL backend ==="
    odin check slug/backends/opengl/ -no-entry-point
    echo "OpenGL backend: OK"

    echo "=== Checking Raylib backend ==="
    odin check slug/backends/raylib/ -no-entry-point
    echo "Raylib backend: OK"

    echo "=== Checking Vulkan backend ==="
    odin check slug/backends/vulkan/ -no-entry-point
    echo "Vulkan backend: OK"

    echo "=== Checking SDL3 GPU backend ==="
    odin check slug/backends/sdl3gpu/ -no-entry-point
    echo "SDL3 GPU backend: OK"

    echo "=== Checking Karl2D backend ==="
    odin check slug/backends/karl2d/ -no-entry-point
    echo "Karl2D backend: OK"

    # D3D11 backend is Windows-only — skip on other platforms
    if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || "$OSTYPE" == "win32" ]]; then
        echo "=== Checking D3D11 backend ==="
        odin check slug/backends/d3d11/ -no-entry-point
        echo "D3D11 backend: OK"
    else
        echo "=== Skipping D3D11 backend (Windows only) ==="
    fi

    if [ -z "$SOKOL_PATH" ] && [ -d "$SCRIPT_DIR/../sokol-odin/sokol" ]; then
        SOKOL_PATH="$(cd "$SCRIPT_DIR/../sokol-odin/sokol" && pwd)"
    fi
    if [ -n "$SOKOL_PATH" ]; then
        echo "=== Checking Sokol backend ==="
        odin check slug/backends/sokol/ -no-entry-point -collection:sokol="$SOKOL_PATH" -define:SOKOL_USE_GL=true
        echo "Sokol backend: OK"
    else
        echo "=== Skipping Sokol backend (SOKOL_PATH not set) ==="
    fi

    echo ""
    echo "All packages compile cleanly."
}

do_compile_shaders() {
    echo "=== Compiling shaders ==="
    # Vulkan backend (push_constant)
    glslc slug/shaders/slug_450.vert -o slug/shaders/slug_vert.spv
    glslc slug/shaders/slug_450.frag -o slug/shaders/slug_frag.spv
    glslc slug/shaders/rect_450.vert -o slug/shaders/rect_vert.spv
    glslc slug/shaders/rect_450.frag -o slug/shaders/rect_frag.spv
    # SDL3 GPU backend (UBO uniforms)
    glslc slug/shaders/slug_sdl3.vert -o slug/shaders/slug_sdl3_vert.spv
    glslc slug/shaders/slug_sdl3.frag -o slug/shaders/slug_sdl3_frag.spv
    glslc slug/shaders/rect_sdl3.vert -o slug/shaders/rect_sdl3_vert.spv
    echo "Shaders compiled."
}

do_build_opengl() {
    echo "=== Building OpenGL demo ==="
    odin build examples/demo_opengl/ -out:demo_opengl -collection:libs=.
    echo "Built: ./demo_opengl"
}

do_build_raylib() {
    echo "=== Building Raylib demo ==="
    odin build examples/demo_raylib/ -out:demo_raylib -collection:libs=.
    echo "Built: ./demo_raylib"
}

do_build_vulkan() {
    do_compile_shaders
    echo "=== Building Vulkan demo ==="
    odin build examples/demo_vulkan/ -out:demo_vulkan -collection:libs=.
    echo "Built: ./demo_vulkan"
}

do_build_sdl3gpu() {
    do_compile_shaders
    echo "=== Building SDL3 GPU demo ==="
    odin build examples/demo_sdl3gpu/ -out:demo_sdl3gpu -collection:libs=.
    echo "Built: ./demo_sdl3gpu"
}

do_build_d3d11() {
    echo "=== Building D3D11 demo ==="
    odin build examples/demo_d3d11/ -out:demo_d3d11 -collection:libs=.
    echo "Built: ./demo_d3d11"
}

do_build_karl2d() {
    echo "=== Building Karl2D demo ==="
    if [ -z "$KARL2D_PATH" ]; then
        # Auto-detect: sibling directory ../karl2d
        if [ -d "$SCRIPT_DIR/../karl2d" ]; then
            KARL2D_PATH="$(cd "$SCRIPT_DIR/.." && pwd)"
        else
            echo "Error: KARL2D_PATH not set and ../karl2d not found."
            echo "  Clone it:  git clone https://github.com/nicoepp/karl2d.git ../karl2d"
            echo "  Or set:    export KARL2D_PATH=/path/to  (parent dir of karl2d/)"
            exit 1
        fi
    fi
    odin build examples/demo_karl2d/ -out:demo_karl2d -collection:libs=. -collection:karl2d="$KARL2D_PATH" -define:KARL2D_RENDER_BACKEND=gl
    echo "Built: ./demo_karl2d"
}

do_build_sokol() {
    echo "=== Building Sokol GFX demo ==="
    if [ -z "$SOKOL_PATH" ]; then
        # Auto-detect: sibling directory ../sokol-odin/sokol
        if [ -d "$SCRIPT_DIR/../sokol-odin/sokol" ]; then
            SOKOL_PATH="$(cd "$SCRIPT_DIR/../sokol-odin/sokol" && pwd)"
        else
            echo "Error: SOKOL_PATH not set and ../sokol-odin/sokol not found."
            echo "  Clone it:  git clone https://github.com/floooh/sokol-odin.git ../sokol-odin"
            echo "  Or set:    export SOKOL_PATH=/path/to/sokol-odin/sokol"
            exit 1
        fi
    fi
    odin build examples/demo_sokol/ -out:demo_sokol -collection:libs=. -collection:sokol="$SOKOL_PATH" -define:SOKOL_USE_GL=true
    echo "Built: ./demo_sokol"
}

do_clean() {
    echo "=== Cleaning build artifacts ==="
    rm -f demo_opengl demo_raylib demo_vulkan demo_sdl3gpu demo_d3d11 demo_karl2d demo_sokol
    rm -f slug/shaders/*.spv
    echo "Clean."
}

CMD="${1:-check}"

case "$CMD" in
    check)   do_check ;;
    opengl)  do_build_opengl ;;
    raylib)  do_build_raylib ;;
    vulkan)  do_build_vulkan ;;
    sdl3gpu) do_build_sdl3gpu ;;
    d3d11)   do_build_d3d11 ;;
    karl2d)  do_build_karl2d ;;
    sokol)   do_build_sokol ;;
    shaders) do_compile_shaders ;;
    all)     do_build_opengl; do_build_raylib; do_build_vulkan; do_build_sdl3gpu ;;
    clean)   do_clean ;;
    help|-h) usage ;;
    *)       echo "Unknown command: $CMD"; usage; exit 1 ;;
esac
