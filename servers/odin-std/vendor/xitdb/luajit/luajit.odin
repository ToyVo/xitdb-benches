package luajit

import "core:c"

when ODIN_OS == .Linux {
	foreign import luajit_lib "system:luajit-5.1"
} else when ODIN_OS == .Darwin {
	foreign import luajit_lib "system:luajit-5.1"
} else when ODIN_OS == .Windows {
	foreign import luajit_lib "system:lua51.lib"
}

// ============================================================================
// LuaJIT 2.1 C API Bindings (`package luajit`)
// ============================================================================

VERSION        :: "Lua 5.1"
LUAJIT_VERSION :: "LuaJIT 2.1"
SIGNATURE      :: "\x1bLJ"

MULTRET        :: c.int(-1)

REGISTRYINDEX  :: c.int(-10000)
ENVIRONINDEX   :: c.int(-10001)
GLOBALSINDEX   :: c.int(-10002)

NOREF          :: c.int(-2)
REFNIL         :: c.int(-1)

GCSTOP         :: c.int(0)
GCRESTART      :: c.int(1)
GCCOLLECT      :: c.int(2)
GCCOUNT        :: c.int(3)
GCCOUNTB       :: c.int(4)
GCSTEP         :: c.int(5)
GCSETPAUSE     :: c.int(6)
GCSETSTEPMUL   :: c.int(7)
GCISRUNNING    :: c.int(9)

LUAJIT_MODE_ENGINE     :: c.int(0)
LUAJIT_MODE_DEBUG      :: c.int(1)
LUAJIT_MODE_FUNC       :: c.int(2)
LUAJIT_MODE_ALLFUNC    :: c.int(3)
LUAJIT_MODE_ALLSUBFUNC :: c.int(4)
LUAJIT_MODE_TRACE      :: c.int(5)
LUAJIT_MODE_WRAPCFUNC  :: c.int(0x10)

LUAJIT_MODE_OFF        :: c.int(0x0000)
LUAJIT_MODE_ON         :: c.int(0x0100)
LUAJIT_MODE_FLUSH      :: c.int(0x0200)

State :: struct {}

Number  :: c.double
Integer :: c.ptrdiff_t

CFunction :: #type proc "c" (L: ^State) -> c.int
Reader    :: #type proc "c" (L: ^State, ud: rawptr, sz: ^c.size_t) -> cstring
Writer    :: #type proc "c" (L: ^State, p: rawptr, sz: c.size_t, ud: rawptr) -> c.int
Alloc     :: #type proc "c" (ud: rawptr, ptr: rawptr, osize: c.size_t, nsize: c.size_t) -> rawptr

L_Reg :: struct {
	name: cstring,
	func: CFunction,
}

Status :: enum c.int {
	OK        = 0,
	YIELD     = 1,
	ERRRUN    = 2,
	ERRSYNTAX = 3,
	ERRMEM    = 4,
	ERRERR    = 5,
	ERRFILE   = 6,
}

Type :: enum c.int {
	NONE          = -1,
	NIL           = 0,
	BOOLEAN       = 1,
	LIGHTUSERDATA = 2,
	NUMBER        = 3,
	STRING        = 4,
	TABLE         = 5,
	FUNCTION      = 6,
	USERDATA      = 7,
	THREAD        = 8,
}

@(default_calling_convention = "c")
foreign luajit_lib {
	// State manipulation
	@(link_name = "lua_newstate")
	newstate :: proc(f: Alloc, ud: rawptr) -> ^State ---
	@(link_name = "lua_close")
	close :: proc(L: ^State) ---
	@(link_name = "lua_newthread")
	newthread :: proc(L: ^State) -> ^State ---
	@(link_name = "lua_atpanic")
	atpanic :: proc(L: ^State, panicf: CFunction) -> CFunction ---

	// Basic stack manipulation
	@(link_name = "lua_gettop")
	gettop :: proc(L: ^State) -> c.int ---
	@(link_name = "lua_settop")
	settop :: proc(L: ^State, idx: c.int) ---
	@(link_name = "lua_pushvalue")
	pushvalue :: proc(L: ^State, idx: c.int) ---
	@(link_name = "lua_remove")
	remove :: proc(L: ^State, idx: c.int) ---
	@(link_name = "lua_insert")
	insert :: proc(L: ^State, idx: c.int) ---
	@(link_name = "lua_replace")
	replace :: proc(L: ^State, idx: c.int) ---
	@(link_name = "lua_checkstack")
	checkstack :: proc(L: ^State, sz: c.int) -> c.int ---
	@(link_name = "lua_xmove")
	xmove :: proc(from, to: ^State, n: c.int) ---
	@(link_name = "lua_copy")
	copy :: proc(L: ^State, fromidx, toidx: c.int) ---

	// Access functions (stack -> C)
	@(link_name = "lua_isnumber")
	isnumber :: proc(L: ^State, idx: c.int) -> b32 ---
	@(link_name = "lua_isstring")
	isstring :: proc(L: ^State, idx: c.int) -> b32 ---
	@(link_name = "lua_iscfunction")
	iscfunction :: proc(L: ^State, idx: c.int) -> b32 ---
	@(link_name = "lua_isuserdata")
	isuserdata :: proc(L: ^State, idx: c.int) -> b32 ---
	@(link_name = "lua_type")
	type :: proc(L: ^State, idx: c.int) -> Type ---
	@(link_name = "lua_typename")
	typename :: proc(L: ^State, tp: Type) -> cstring ---

	@(link_name = "lua_equal")
	equal :: proc(L: ^State, idx1, idx2: c.int) -> b32 ---
	@(link_name = "lua_rawequal")
	rawequal :: proc(L: ^State, idx1, idx2: c.int) -> b32 ---
	@(link_name = "lua_lessthan")
	lessthan :: proc(L: ^State, idx1, idx2: c.int) -> b32 ---

	@(link_name = "lua_tonumber")
	tonumber :: proc(L: ^State, idx: c.int) -> Number ---
	@(link_name = "lua_tonumberx")
	tonumberx :: proc(L: ^State, idx: c.int, isnum: ^b32) -> Number ---
	@(link_name = "lua_tointeger")
	tointeger :: proc(L: ^State, idx: c.int) -> Integer ---
	@(link_name = "lua_tointegerx")
	tointegerx :: proc(L: ^State, idx: c.int, isnum: ^b32) -> Integer ---
	@(link_name = "lua_toboolean")
	toboolean :: proc(L: ^State, idx: c.int) -> b32 ---
	@(link_name = "lua_tolstring")
	tolstring :: proc(L: ^State, idx: c.int, len: ^c.size_t) -> cstring ---
	@(link_name = "lua_objlen")
	objlen :: proc(L: ^State, idx: c.int) -> c.size_t ---
	@(link_name = "lua_tocfunction")
	tocfunction :: proc(L: ^State, idx: c.int) -> CFunction ---
	@(link_name = "lua_touserdata")
	touserdata :: proc(L: ^State, idx: c.int) -> rawptr ---
	@(link_name = "lua_tothread")
	tothread :: proc(L: ^State, idx: c.int) -> ^State ---
	@(link_name = "lua_topointer")
	topointer :: proc(L: ^State, idx: c.int) -> rawptr ---

	// Push functions (C -> stack)
	@(link_name = "lua_pushnil")
	pushnil :: proc(L: ^State) ---
	@(link_name = "lua_pushnumber")
	pushnumber :: proc(L: ^State, n: Number) ---
	@(link_name = "lua_pushinteger")
	pushinteger :: proc(L: ^State, n: Integer) ---
	@(link_name = "lua_pushlstring")
	pushlstring :: proc(L: ^State, s: cstring, l: c.size_t) ---
	@(link_name = "lua_pushstring")
	pushstring :: proc(L: ^State, s: cstring) ---
	@(link_name = "lua_pushcclosure")
	pushcclosure :: proc(L: ^State, fn: CFunction, n: c.int) ---
	@(link_name = "lua_pushboolean")
	pushboolean :: proc(L: ^State, b: b32) ---
	@(link_name = "lua_pushlightuserdata")
	pushlightuserdata :: proc(L: ^State, p: rawptr) ---
	@(link_name = "lua_pushthread")
	pushthread :: proc(L: ^State) -> c.int ---

	// Get functions (Lua -> stack)
	@(link_name = "lua_gettable")
	gettable :: proc(L: ^State, idx: c.int) ---
	@(link_name = "lua_getfield")
	getfield :: proc(L: ^State, idx: c.int, k: cstring) ---
	@(link_name = "lua_rawget")
	rawget :: proc(L: ^State, idx: c.int) ---
	@(link_name = "lua_rawgeti")
	rawgeti :: proc(L: ^State, idx: c.int, n: Integer) ---
	@(link_name = "lua_createtable")
	createtable :: proc(L: ^State, narr, nrec: c.int) ---
	@(link_name = "lua_newuserdata")
	newuserdata :: proc(L: ^State, sz: c.size_t) -> rawptr ---
	@(link_name = "lua_getmetatable")
	getmetatable :: proc(L: ^State, objindex: c.int) -> c.int ---
	@(link_name = "lua_getfenv")
	getfenv :: proc(L: ^State, idx: c.int) ---

	// Set functions (stack -> Lua)
	@(link_name = "lua_settable")
	settable :: proc(L: ^State, idx: c.int) ---
	@(link_name = "lua_setfield")
	setfield :: proc(L: ^State, idx: c.int, k: cstring) ---
	@(link_name = "lua_rawset")
	rawset :: proc(L: ^State, idx: c.int) ---
	@(link_name = "lua_rawseti")
	rawseti :: proc(L: ^State, idx: c.int, n: Integer) ---
	@(link_name = "lua_setmetatable")
	setmetatable :: proc(L: ^State, objindex: c.int) -> c.int ---
	@(link_name = "lua_setfenv")
	setfenv :: proc(L: ^State, idx: c.int) -> c.int ---

	// Load and call functions
	@(link_name = "lua_call")
	call :: proc(L: ^State, nargs, nresults: c.int) ---
	@(link_name = "lua_pcall")
	pcall :: proc(L: ^State, nargs, nresults, errfunc: c.int) -> c.int ---
	@(link_name = "lua_cpcall")
	cpcall :: proc(L: ^State, func: CFunction, ud: rawptr) -> c.int ---
	@(link_name = "lua_load")
	load :: proc(L: ^State, reader: Reader, dt: rawptr, chunkname: cstring) -> Status ---
	@(link_name = "lua_loadx")
	loadx :: proc(L: ^State, reader: Reader, dt: rawptr, chunkname: cstring, mode: cstring) -> Status ---
	@(link_name = "lua_dump")
	dump :: proc(L: ^State, writer: Writer, data: rawptr) -> Status ---

	// Garbage collection & miscellaneous
	@(link_name = "lua_gc")
	gc :: proc(L: ^State, what, data: c.int) -> c.int ---
	@(link_name = "lua_error")
	error :: proc(L: ^State) -> c.int ---
	@(link_name = "lua_next")
	next :: proc(L: ^State, idx: c.int) -> c.int ---
	@(link_name = "lua_concat")
	concat :: proc(L: ^State, n: c.int) ---

	// Auxiliary library (luaL_*)
	@(link_name = "luaL_newstate")
	L_newstate :: proc() -> ^State ---
	@(link_name = "luaL_openlibs")
	L_openlibs :: proc(L: ^State) ---
	@(link_name = "luaL_register")
	L_register :: proc(L: ^State, libname: cstring, l: ^L_Reg) ---
	@(link_name = "luaL_getmetafield")
	L_getmetafield :: proc(L: ^State, obj: c.int, e: cstring) -> c.int ---
	@(link_name = "luaL_callmeta")
	L_callmeta :: proc(L: ^State, obj: c.int, e: cstring) -> c.int ---
	@(link_name = "luaL_typerror")
	L_typerror :: proc(L: ^State, narg: c.int, tname: cstring) -> c.int ---
	@(link_name = "luaL_argerror")
	L_argerror :: proc(L: ^State, numarg: c.int, extramsg: cstring) -> c.int ---
	@(link_name = "luaL_checklstring")
	L_checklstring :: proc(L: ^State, numArg: c.int, l: ^c.size_t) -> cstring ---
	@(link_name = "luaL_optlstring")
	L_optlstring :: proc(L: ^State, numArg: c.int, def: cstring, l: ^c.size_t) -> cstring ---
	@(link_name = "luaL_checknumber")
	L_checknumber :: proc(L: ^State, numArg: c.int) -> Number ---
	@(link_name = "luaL_optnumber")
	L_optnumber :: proc(L: ^State, nArg: c.int, def: Number) -> Number ---
	@(link_name = "luaL_checkinteger")
	L_checkinteger :: proc(L: ^State, numArg: c.int) -> Integer ---
	@(link_name = "luaL_optinteger")
	L_optinteger :: proc(L: ^State, nArg: c.int, def: Integer) -> Integer ---
	@(link_name = "luaL_checkstack")
	L_checkstack :: proc(L: ^State, sz: c.int, msg: cstring) ---
	@(link_name = "luaL_checktype")
	L_checktype :: proc(L: ^State, narg: c.int, t: Type) ---
	@(link_name = "luaL_checkany")
	L_checkany :: proc(L: ^State, narg: c.int) ---
	@(link_name = "luaL_newmetatable")
	L_newmetatable :: proc(L: ^State, tname: cstring) -> c.int ---
	@(link_name = "luaL_checkudata")
	L_checkudata :: proc(L: ^State, ud: c.int, tname: cstring) -> rawptr ---
	@(link_name = "luaL_testudata")
	L_testudata :: proc(L: ^State, ud: c.int, tname: cstring) -> rawptr ---
	@(link_name = "luaL_setmetatable")
	L_setmetatable :: proc(L: ^State, tname: cstring) ---
	@(link_name = "luaL_where")
	L_where :: proc(L: ^State, lvl: c.int) ---
	@(link_name = "luaL_error")
	L_error :: proc(L: ^State, fmt: cstring, #c_vararg args: ..any) -> c.int ---
	@(link_name = "luaL_ref")
	L_ref :: proc(L: ^State, t: c.int) -> c.int ---
	@(link_name = "luaL_unref")
	L_unref :: proc(L: ^State, t: c.int, ref: c.int) ---
	@(link_name = "luaL_loadfile")
	L_loadfile :: proc(L: ^State, filename: cstring) -> Status ---
	@(link_name = "luaL_loadfilex")
	L_loadfilex :: proc(L: ^State, filename: cstring, mode: cstring) -> Status ---
	@(link_name = "luaL_loadbuffer")
	L_loadbuffer_51 :: proc(L: ^State, buff: [^]u8, sz: c.size_t, name: cstring) -> Status ---
	@(link_name = "luaL_loadbufferx")
	L_loadbufferx :: proc(L: ^State, buff: [^]u8, sz: c.size_t, name: cstring, mode: cstring) -> Status ---
	@(link_name = "luaL_loadstring")
	L_loadstring :: proc(L: ^State, s: cstring) -> Status ---
	@(link_name = "luaL_setfuncs")
	L_setfuncs :: proc(L: ^State, l: ^L_Reg, nup: c.int) ---
	@(link_name = "luaL_traceback")
	L_traceback :: proc(L: ^State, L1: ^State, msg: cstring, level: c.int) ---

	// LuaJIT control API
	@(link_name = "luaJIT_setmode")
	JIT_setmode :: proc(L: ^State, idx: c.int, mode: c.int) -> c.int ---
}

// ============================================================================
// Inline C Macro Equivalents for LuaJIT 2.1
// ============================================================================

pop :: #force_inline proc "c" (L: ^State, n: c.int) {
	settop(L, -(n) - 1)
}

absindex :: #force_inline proc "c" (L: ^State, idx: c.int) -> c.int {
	if idx > 0 || idx <= REGISTRYINDEX {
		return idx
	}
	return gettop(L) + idx + 1
}

newtable :: #force_inline proc "c" (L: ^State) {
	createtable(L, 0, 0)
}

newuserdatauv :: #force_inline proc "c" (L: ^State, sz: c.size_t, nuvalue: c.int = 0) -> rawptr {
	return newuserdata(L, sz)
}

pushcfunction :: #force_inline proc "c" (L: ^State, fn: CFunction) {
	pushcclosure(L, fn, 0)
}

tostring :: #force_inline proc "c" (L: ^State, idx: c.int) -> cstring {
	return tolstring(L, idx, nil)
}

setglobal :: #force_inline proc "c" (L: ^State, name: cstring) {
	setfield(L, GLOBALSINDEX, name)
}

getglobal :: #force_inline proc "c" (L: ^State, name: cstring) {
	getfield(L, GLOBALSINDEX, name)
}

rawlen :: #force_inline proc "c" (L: ^State, idx: c.int) -> c.size_t {
	return objlen(L, idx)
}

isinteger :: #force_inline proc "c" (L: ^State, idx: c.int) -> b32 {
	if type(L, idx) != .NUMBER {
		return false
	}
	f := tonumber(L, idx)
	return Number(Integer(f)) == f
}

L_checkstring :: #force_inline proc "c" (L: ^State, n: c.int) -> cstring {
	return L_checklstring(L, n, nil)
}

L_optstring :: #force_inline proc "c" (L: ^State, n: c.int, d: cstring) -> cstring {
	return L_optlstring(L, n, d, nil)
}

L_loadbuffer :: #force_inline proc "c" (L: ^State, buff: [^]u8, sz: c.size_t, name: cstring, mode: cstring = nil) -> Status {
	if mode != nil {
		return L_loadbufferx(L, buff, sz, name, mode)
	}
	return L_loadbuffer_51(L, buff, sz, name)
}
