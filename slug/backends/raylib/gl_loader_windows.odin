#+build windows
package slug_raylib

import win32 "core:sys/windows"

// On Windows, wglGetProcAddress handles GL 1.2+ extension functions
// but returns NULL for GL 1.0/1.1 core functions (glGetString, etc).
// We fall back to GetProcAddress on opengl32.dll for those.
//
// The opengl32.dll handle is cached — LoadLibraryW increments a
// reference count each call, and loading hundreds of times during
// gl.load_up_to() would leak handles.

@(private = "package")
gl32_lib: win32.HMODULE

@(private = "package")
gl_loader_init :: proc() {
	if gl32_lib != nil do return
	gl32_lib = win32.LoadLibraryW(win32.L("opengl32.dll"))
}

@(private = "package")
get_gl_proc :: proc(name: cstring) -> rawptr {
	// wglGetProcAddress needs a current GL context and handles
	// extension functions (GL 1.2+). Returns NULL/1/2/3 for
	// core 1.0/1.1 functions or if no context is current.
	func := win32.wglGetProcAddress(name)
	if uintptr(func) > 3 && func != rawptr(~uintptr(0)) {
		return func
	}

	// Fallback: core GL 1.0/1.1 functions are exported from opengl32.dll
	if gl32_lib == nil do gl_loader_init()
	if gl32_lib != nil {
		return rawptr(win32.GetProcAddress(gl32_lib, name))
	}

	return nil
}
