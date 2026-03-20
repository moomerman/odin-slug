package slug_raylib

// ===================================================
// Raylib backend for odin-slug
//
// Thin wrapper around the OpenGL 3.3 backend that handles
// the two Raylib-specific gotchas automatically:
//
//   1. Loading Odin's vendor:OpenGL function pointers
//      from the GL context that Raylib already created.
//      (Raylib uses its own internal GLAD loader, which
//      does NOT populate vendor:OpenGL's function pointers.)
//
//   2. Flushing Raylib's internal draw batch before slug
//      touches GL state (shader, VAO, blend mode)
//
// Usage:
//   1. Call rl.InitWindow() first (creates the GL context)
//   2. renderer := new(slug_raylib.Renderer)
//   3. slug_raylib.init(renderer)
//   4. slug_raylib.load_font(renderer, 0, "myfont.ttf")
//   5. Per frame:
//        slug.begin(slug_raylib.ctx(renderer))
//        slug.draw_text(slug_raylib.ctx(renderer), ...)
//        slug.end(slug_raylib.ctx(renderer))
//        slug_raylib.flush(renderer, rl.GetScreenWidth(), rl.GetScreenHeight())
// ===================================================

import gl "vendor:OpenGL"
import rlgl "vendor:raylib/rlgl"

import slug "../../"
import slug_gl "../opengl"

// --- Renderer ---
// Wraps the OpenGL renderer. Heap-allocate with new() —
// slug.Context is ~1.5MB, too large for the stack.

Renderer :: struct {
	using gl_renderer: slug_gl.Renderer,
}

// --- Public API ---

// Initialize the slug renderer. Call AFTER rl.InitWindow().
// Loads Odin's vendor:OpenGL function pointers from the
// already-active GL context, then sets up the slug shader,
// VAO, VBO, and EBO.
// Returns false if GL function pointers couldn't be loaded
// (usually means rl.InitWindow() wasn't called first).
init :: proc(r: ^Renderer) -> bool {
	gl.load_up_to(3, 3, gl_set_proc_address)

	// Verify GL is actually available — if InitWindow() wasn't called,
	// all function pointers will be nil and slug_gl.init will segfault.
	if gl.CreateShader == nil {
		return false
	}

	return slug_gl.init(&r.gl_renderer)
}

// Return a pointer to the slug context for draw calls.
ctx :: proc(r: ^Renderer) -> ^slug.Context {
	return &r.gl_renderer.ctx
}

// Load a TTF font into the given slot (0-3) and upload
// its curve/band textures to the GPU. All-in-one convenience.
load_font :: proc(r: ^Renderer, slot: int, path: string) -> bool {
	return slug_gl.load_font(&r.gl_renderer, slot, path)
}

// Upload pre-packed font textures to a slot. For advanced
// use when you want to control the packing step yourself.
upload_font_textures :: proc(r: ^Renderer, slot: int, pack: ^slug.Texture_Pack_Result) -> bool {
	return slug_gl.upload_font_textures(&r.gl_renderer, slot, pack)
}

// Flush Raylib's internal draw batch, then upload slug
// vertices and issue draw calls for all font batches.
// Call this between slug.end() and any post-slug Raylib drawing.
flush :: proc(r: ^Renderer, width, height: i32) {
	rlgl.DrawRenderBatchActive()
	slug_gl.flush(&r.gl_renderer, width, height)
}

// Destroy all GL resources and free the slug context.
destroy :: proc(r: ^Renderer) {
	slug_gl.destroy(&r.gl_renderer)
}

// --- GL proc loader ---
// Callback for gl.load_up_to(). Uses platform-specific
// get_gl_proc() from gl_loader_*.odin files.

@(private = "file")
gl_set_proc_address :: proc(p: rawptr, name: cstring) {
	(^rawptr)(p)^ = get_gl_proc(name)
}
