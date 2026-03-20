package slug

import "core:mem"

// ===================================================
// Static text caching — avoid per-frame vertex recomputation.
//
// For text that doesn't change every frame (UI labels, panel titles,
// stat displays), caching the vertex data avoids re-walking the string
// and re-emitting quads. Create a cache once, draw it every frame.
//
// Usage:
//   // At init or when text changes:
//   cache := slug.cache_text(ctx, "Health: 100", x, y, size, color)
//
//   // Every frame:
//   slug.draw_cached(ctx, &cache)
//
//   // When text changes:
//   slug.cache_destroy(&cache)
//   cache = slug.cache_text(ctx, "Health: 95", x, y, size, color)
//
//   // At cleanup:
//   slug.cache_destroy(&cache)
// ===================================================

// Cached vertex data for a static piece of text.
// Owns its vertex memory — must be freed with cache_destroy().
Text_Cache :: struct {
	vertices:   []Vertex,
	quad_count: u32,
	origin_x:   f32,
	origin_y:   f32,
}

// Cache the vertex data for a text string.
// Renders the text into a temporary buffer and copies the result.
// The returned cache is independent of the context's per-frame buffer.
cache_text :: proc(
	ctx: ^Context,
	text: string,
	x, y: f32,
	font_size: f32,
	color: Color,
	use_kerning: bool = true,
	allocator := context.allocator,
) -> Text_Cache {
	// Save current quad count so we can isolate our output
	saved_count := ctx.quad_count

	// Emit quads into the context's vertex buffer
	draw_text(ctx, text, x, y, font_size, color, use_kerning)

	// Calculate how many quads were emitted
	new_quads := ctx.quad_count - saved_count
	if new_quads == 0 {
		// Restore and return empty cache
		ctx.quad_count = saved_count
		return {}
	}

	vert_count := new_quads * VERTICES_PER_QUAD
	base := saved_count * VERTICES_PER_QUAD

	// Copy vertices into owned memory
	verts := make([]Vertex, vert_count, allocator)
	mem.copy(raw_data(verts), &ctx.vertices[base], int(vert_count) * size_of(Vertex))

	// Restore the context — the cached quads don't consume frame budget
	ctx.quad_count = saved_count

	return Text_Cache {
		vertices   = verts,
		quad_count = new_quads,
		origin_x   = x,
		origin_y   = y,
	}
}

// Draw cached text into the current frame's vertex buffer.
// Copies the cached vertices directly — no per-character processing.
draw_cached :: proc(ctx: ^Context, cache: ^Text_Cache) {
	if cache.quad_count == 0 || cache.vertices == nil do return
	if ctx.quad_count + cache.quad_count > MAX_GLYPH_QUADS do return

	base := ctx.quad_count * VERTICES_PER_QUAD
	vert_count := cache.quad_count * VERTICES_PER_QUAD

	mem.copy(&ctx.vertices[base], raw_data(cache.vertices), int(vert_count) * size_of(Vertex))
	ctx.quad_count += cache.quad_count
}

// Draw cached text at a different position than where it was originally cached.
// Offsets all vertex positions by the delta from the original origin.
draw_cached_at :: proc(ctx: ^Context, cache: ^Text_Cache, x, y: f32) {
	if cache.quad_count == 0 || cache.vertices == nil do return
	if ctx.quad_count + cache.quad_count > MAX_GLYPH_QUADS do return

	dx := x - cache.origin_x
	dy := y - cache.origin_y

	base := ctx.quad_count * VERTICES_PER_QUAD
	vert_count := cache.quad_count * VERTICES_PER_QUAD

	mem.copy(&ctx.vertices[base], raw_data(cache.vertices), int(vert_count) * size_of(Vertex))

	// Offset screen positions
	if dx != 0 || dy != 0 {
		for i in base ..< base + vert_count {
			ctx.vertices[i].pos.x += dx
			ctx.vertices[i].pos.y += dy
		}
	}

	ctx.quad_count += cache.quad_count
}

// Free cached vertex data.
cache_destroy :: proc(cache: ^Text_Cache) {
	delete(cache.vertices)
	cache^ = {}
}
