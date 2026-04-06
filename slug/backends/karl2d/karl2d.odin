package slug_karl2d

// ===================================================
// Karl2D backend for odin-slug
//
// Thin wrapper around the OpenGL 3.3 backend that handles
// the two Karl2D-specific integration points automatically:
//
//   1. Loading Odin's vendor:OpenGL function pointers
//      from the GL context that Karl2D already created.
//      (Karl2D uses its own internal GL loader, which
//      does NOT populate vendor:OpenGL's function pointers.)
//
//   2. Flushing Karl2D's internal draw batch before slug
//      touches GL state (shader, VAO, blend mode)
//
// Karl2D creates an OpenGL 3.3 Core context on all platforms
// (GLX on X11, EGL on Wayland, WGL on Windows), which is
// exactly what odin-slug's GLSL 3.30 shaders require.
//
// Karl2D does NOT cache GL state — it re-binds everything
// per draw call, so slug's GL state changes are safe and
// no state invalidation is needed after flush.
//
// NOTE: Karl2D is a third-party package (not an Odin vendor lib),
// so this backend cannot import it directly. Instead, the caller
// passes k2.draw_current_batch as a callback during init.
//
// Usage:
//   1. Call k2.init() first (creates the GL context + window)
//   2. renderer := new(slug_karl2d.Renderer)
//   3. slug_karl2d.init(renderer, k2.draw_current_batch)
//   4. slug_karl2d.load_font(renderer, 0, "myfont.ttf")
//   5. Per frame:
//        slug.begin(slug_karl2d.ctx(renderer))
//        slug.draw_text(slug_karl2d.ctx(renderer), ...)
//        slug.end(slug_karl2d.ctx(renderer))
//        slug_karl2d.flush(renderer, i32(k2.get_screen_width()), i32(k2.get_screen_height()))
// ===================================================

import gl "vendor:OpenGL"

import slug "../../"
import slug_gl "../opengl"

// --- Renderer ---
// Wraps the OpenGL renderer plus a Karl2D batch flush callback.
// Created by init(), freed by destroy().

Renderer :: struct {
	using gl_renderer: slug_gl.Renderer,
	flush_batch:       proc(),
}

// --- Public API ---

// Create and initialize the slug renderer. Call AFTER k2.init().
// flush_batch_proc should be k2.draw_current_batch — it flushes
// Karl2D's internal vertex batch before slug issues GL draw calls.
// Returns nil if GL function pointers couldn't be loaded
// (usually means k2.init() wasn't called first).
// Caller must call destroy() to free.
init :: proc(flush_batch_proc: proc()) -> ^Renderer {
	gl.load_up_to(3, 3, gl_set_proc_address)

	// Verify GL is actually available — if k2.init() wasn't called,
	// all function pointers will be nil and slug_gl.init will segfault.
	if gl.CreateShader == nil {
		return nil
	}

	r, alloc_err := new(Renderer)
	if alloc_err != .None do return nil
	r.flush_batch = flush_batch_proc
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

// Flush Karl2D's internal draw batch, then upload slug vertices and issue draw calls.
// scissor restricts rendering to a screen-space rectangle; zero value = full screen.
// Safe to call multiple times per frame with different scissors.
// Call this between slug.end() and k2.present().
flush :: proc(r: ^Renderer, width, height: i32, scissor: slug.Scissor_Rect = {}) {
	if r.flush_batch != nil {
		r.flush_batch()
	}
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

// --- GL proc loader ---
// Callback for gl.load_up_to(). Uses platform-specific
// get_gl_proc() from gl_loader_*.odin files.

@(private = "file")
gl_set_proc_address :: proc(p: rawptr, name: cstring) {
	(^rawptr)(p)^ = get_gl_proc(name)
}
