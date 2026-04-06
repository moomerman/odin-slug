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
//   2. renderer := slug_raylib.init() // returns nil on failure
//   3. defer slug_raylib.destroy(renderer)
//   4. slug_raylib.load_font(renderer, 0, "myfont.ttf")
//   5. Per frame:
//        slug.begin(slug_raylib.ctx(renderer))
//        slug.draw_text(slug_raylib.ctx(renderer), ...)
//        slug.end(slug_raylib.ctx(renderer))
//        slug_raylib.flush(renderer, rl.GetScreenWidth(), rl.GetScreenHeight())
//
// Hot reload (shared .so workflow):
//   In game_hot_reloaded: slug_raylib.hot_reload(renderer)
//   This re-populates vendor:OpenGL function pointers without
//   re-creating GPU resources (VAO, VBO, shaders, textures survive).
// ===================================================

import gl "vendor:OpenGL"
import rlgl "vendor:raylib/rlgl"

import slug "../../"
import slug_gl "../opengl"

// --- Renderer ---
// Wraps the OpenGL renderer. Created by init(), freed by destroy().

Renderer :: struct {
	using gl_renderer: slug_gl.Renderer,
}

// --- Public API ---

// Create and initialize the slug renderer. Call AFTER rl.InitWindow().
// Loads Odin's vendor:OpenGL function pointers from the
// already-active GL context, then sets up the slug shader,
// VAO, VBO, and EBO.
// Returns nil if GL function pointers couldn't be loaded
// (usually means rl.InitWindow() wasn't called first).
// Caller must call destroy() to free.
init :: proc() -> ^Renderer {
	gl.load_up_to(3, 3, gl_set_proc_address)

	// Verify GL is actually available — if InitWindow() wasn't called,
	// all function pointers will be nil and slug_gl.init will segfault.
	if gl.CreateShader == nil {
		return nil
	}

	r, alloc_err := new(Renderer)
	if alloc_err != .None do return nil
	if !slug_gl.init_renderer(&r.gl_renderer) {
		free(r)
		return nil
	}
	return r
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

// Upload a shared font atlas (all fonts packed into one texture pair).
// Call with the result of slug.fonts_process_shared().
upload_shared_textures :: proc(r: ^Renderer, pack: ^slug.Texture_Pack_Result) -> bool {
	return slug_gl.upload_shared_textures(&r.gl_renderer, pack)
}

// Load multiple fonts and pack them into a shared atlas.
// paths is a slice of TTF file paths, loaded into slots 0, 1, 2, ...
// Returns false if any font fails to load.
load_fonts_shared :: proc(r: ^Renderer, paths: []string) -> bool {
	return slug_gl.load_fonts_shared(&r.gl_renderer, paths)
}

// Flush Raylib's internal draw batch, then upload slug vertices and issue draw calls.
// scissor restricts rendering to a screen-space rectangle; zero value = full screen.
// Safe to call multiple times per frame with different scissors.
// Call this between slug.end() and any post-slug Raylib drawing.
flush :: proc(r: ^Renderer, width, height: i32, scissor: slug.Scissor_Rect = {}) {
	rlgl.DrawRenderBatchActive()
	slug_gl.flush(&r.gl_renderer, width, height, scissor)
}

// Unload a font from a slot, releasing GPU textures and CPU glyph data.
// The slot can be reused with load_font or upload_font_textures.
unload_font :: proc(r: ^Renderer, slot: int) {
	slug_gl.unload_font(&r.gl_renderer, slot)
}

// Destroy all GL resources, free the slug context, and free the renderer.
destroy :: proc(r: ^Renderer) {
	if r == nil do return
	slug_gl.destroy_renderer(&r.gl_renderer)
	free(r)
}

// Re-populate vendor:OpenGL function pointers after a hot reload.
// GPU resources (VAO, VBO, shaders, textures) survive the reload — only
// the Odin-side GL function pointer table resets to nil in the new .so.
// Call this in your game_hot_reloaded callback instead of init().
// Returns false if the GL context is no longer available.
hot_reload :: proc(r: ^Renderer) -> bool {
	gl.load_up_to(3, 3, gl_set_proc_address)
	if gl.CreateShader == nil {
		return false
	}
	return true
}

// --- GL proc loader ---
// Callback for gl.load_up_to(). Uses platform-specific
// get_gl_proc() from gl_loader_*.odin files.

@(private = "file")
gl_set_proc_address :: proc(p: rawptr, name: cstring) {
	(^rawptr)(p)^ = get_gl_proc(name)
}
