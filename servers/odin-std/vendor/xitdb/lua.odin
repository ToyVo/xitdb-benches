package xitdb

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import lua "luajit"

// ============================================================================
// LuaJIT 2.1 Client Bindings & Userdata Runtime (`xitdb/lua.odin`)
// ============================================================================
// Exposes xitdb Databases, Cursors, Collections, Streams, Compaction,
// Replication, and the 5-Layer DSL (Selectors, Datomic Tx & transact_script,
// Lua Table marshal/unmarshal & pull, diff_moments/history_of/B+Tree queries,
// and Datalog) + LuaJIT 2.1 bytecode compilation/execution to LuaJIT states.

LUA_MT_DB         :: "xitdb.Database"
LUA_MT_CURSOR     :: "xitdb.Cursor"
LUA_MT_ITERATOR   :: "xitdb.Iterator"
LUA_MT_READER     :: "xitdb.Reader"
LUA_MT_WRITER     :: "xitdb.Writer"
LUA_MT_COLLECTION :: "xitdb.Collection"
LUA_MT_TX         :: "xitdb.Tx"
LUA_MT_OFFSET_MAP :: "xitdb.Offset_Map"
LUA_MT_TYPED_VAL  :: "xitdb.Typed_Val"
LUA_MT_SLOT       :: "xitdb.Slot"
LUA_MT_EXT        :: "xitdb.State_Ext"

LUA_REG_CONTEXT_KEY :: "__xitdb_odin_context"

LUA_UD_MAGIC             :: u32(0x58495455) // "XITU"
LUA_COL_CURSOR_RING_SIZE :: 8
LUA_COL_NUVALUE          :: 0
LUA_CTX_CURSOR_POOL_SIZE :: 4
LUA_COL_POOL_SIZE        :: 32

Lua_UD_Kind :: enum u8 {
	None       = 0,
	Database   = 1,
	Cursor     = 2,
	Collection = 3,
	Iterator   = 4,
	Reader     = 5,
	Writer     = 6,
	Tx         = 7,
	Offset_Map = 8,
	Typed_Val  = 9,
	Slot       = 10,
}

Lua_UD_Header :: struct {
	magic:   u32,
	ud_kind: Lua_UD_Kind,
}

Lua_Collection_Kind :: enum u8 {
	Array_List,
	Linked_Array_List,
	Hash_Map,
	Counted_Hash_Map,
	Hash_Set,
	Counted_Hash_Set,
	Sorted_Map,
	Sorted_Set,
}

Lua_Typed_Kind :: enum u8 {
	Uint,
	Int,
	Float,
	Tagged_Bytes,
}

Lua_Db_Handle :: struct {
	core:      Core,
	db:        Database,
	ext_db:    ^Database,
	owns_core: bool,
	is_closed: bool,
	temp_path: string,
}

Lua_Db_UD :: struct {
	using hdr: Lua_UD_Header,
	h:         ^Lua_Db_Handle,
}

Lua_Cursor_UD :: struct {
	using hdr:  Lua_UD_Header,
	is_write:   bool,
	rc:         Read_Cursor,
	wc:         Write_Cursor,
	kv_key_ud:  ^Lua_Cursor_UD,
	kv_key_ref: c.int,
	kv_val_ud:  ^Lua_Cursor_UD,
	kv_val_ref: c.int,
}

Lua_Collection_UD :: struct {
	using hdr:    Lua_UD_Header,
	kind:         Lua_Collection_Kind,
	is_write:     bool,
	cur_ring_idx: u8,
	rc:           Read_Cursor,
	wc:           Write_Cursor,
	iter_ud:      ^Lua_Iterator_UD,
	iter_ref:     c.int,
	cur_ring:     [LUA_COL_CURSOR_RING_SIZE]^Lua_Cursor_UD,
	cur_refs:     [LUA_COL_CURSOR_RING_SIZE]c.int,
	slot_ud:      ^Lua_Slot_UD,
	slot_ref:     c.int,
}

Lua_Iterator_UD :: struct {
	using hdr: Lua_UD_Header,
	it:        Cursor_Iterator,
	cur_ud:    ^Lua_Cursor_UD,
	cur_ref:   c.int,
}

Lua_Reader_UD :: struct {
	using hdr: Lua_UD_Header,
	reader:    Cursor_Reader,
}

Lua_Writer_UD :: struct {
	using hdr:  Lua_UD_Header,
	writer:     Cursor_Writer,
	parent_cud: ^Lua_Cursor_UD,
	finished:   bool,
}

Lua_Tx_UD :: struct {
	using hdr:      Lua_UD_Header,
	tx:             Tx,
	committed:      bool,
	destroyed:      bool,
	owned_chunks:   [dynamic][]u8,
	cur_chunk:      []u8,
	cur_chunk_used: int,
}

Lua_Offset_Map_UD :: struct {
	using hdr: Lua_UD_Header,
	om:        Offset_Map,
	destroyed: bool,
}

Lua_Typed_Val_UD :: struct {
	using hdr: Lua_UD_Header,
	kind:      Lua_Typed_Kind,
	u_val:     u64,
	i_val:     i64,
	f_val:     f64,
	has_tag:   bool,
	tag:       [2]u8,
	str_ref:   c.int,
}

Lua_Slot_UD :: struct {
	using hdr: Lua_UD_Header,
	slot:      Slot,
}

@(private = "file")
_Lua_State_Ext :: struct {
	ctx:              runtime.Context,
	mt_refs:          [Lua_UD_Kind]c.int,
	ctx_cursors:      [LUA_CTX_CURSOR_POOL_SIZE]^Lua_Cursor_UD,
	ctx_cursor_refs:  [LUA_CTX_CURSOR_POOL_SIZE]c.int,
	ctx_cursor_depth: int,
	col_pool:         [LUA_COL_POOL_SIZE]^Lua_Collection_UD,
	col_refs:         [LUA_COL_POOL_SIZE]c.int,
	col_idx:          u32,
}

@(private = "file", thread_local)
_tls_L: ^lua.State
@(private = "file", thread_local)
_tls_ext: ^_Lua_State_Ext
@(private = "file")
_base_tick := time.tick_now()

// ----------------------------------------------------------------------------
// Public Odin API for LuaJIT 2.1 Integration
// ----------------------------------------------------------------------------

// Create a new LuaJIT 2.1 state with standard libraries (including `jit` & `ffi`)
// and `xitdb` registered (both in `package.loaded["xitdb"]` and as global `xitdb`).
// If `db != nil`, also binds it as global `db`.
lua_new_state :: proc(db: ^Database = nil) -> ^lua.State {
	L := lua.L_newstate()
	if L == nil {
		return nil
	}
	lua.L_openlibs(L)
	lua_open_xitdb(L)
	if db != nil {
		lua_push_database(L, db)
		lua.setglobal(L, "db")
	}
	return L
}

// Register the `xitdb` module and all userdata metatables in `L`.
// Leaves the `xitdb` module table in global `xitdb` and `package.loaded["xitdb"]`.
lua_open_xitdb :: proc(L: ^lua.State) {
	_tls_L = nil
	_tls_ext = nil
	_lua_store_context(L, context)
	lua_module_open(L)
	// Register in `package.loaded["xitdb"]`
	lua.getglobal(L, "package")
	if lua.type(L, -1) == .TABLE {
		lua.getfield(L, -1, "loaded")
		if lua.type(L, -1) == .TABLE {
			lua.pushvalue(L, -3)
			lua.setfield(L, -2, "xitdb")
		}
		lua.pop(L, 1)
	}
	lua.pop(L, 1)
	// Set global `xitdb`
	lua.setglobal(L, "xitdb")
}

// `lua.CFunction` module loader suitable for `lua.L_requiref(L, "xitdb", lua_module_open, 1)`.
lua_module_open :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	_register_metatables(L)

	funcs := [?]lua.L_Reg{
		{"open_memory",           _l_open_memory},
		{"open_file",             _l_open_file},
		{"open_buffered_file",    _l_open_buffered_file},
		{"temp_path",             _l_temp_path},
		{"remove_file",           _l_remove_file},
		{"now_ns",                _l_now_ns},
		{"uint",                  _l_uint},
		{"int",                   _l_int},
		{"float",                 _l_float},
		{"bytes",                 _l_bytes},
		{"tagged",                _l_bytes},
		{"slot",                  _l_slot},
		{"memory_offset_map",     _l_memory_offset_map},
		{"file_offset_map",       _l_file_offset_map},
		{"compile_bytecode",      _l_compile_bytecode},
		{"load_bytecode",         _l_load_bytecode},
		{"read_array_list",       _l_read_array_list},
		{"write_array_list",      _l_write_array_list},
		{"read_linked_array_list",_l_read_linked_array_list},
		{"write_linked_array_list",_l_write_linked_array_list},
		{"read_hash_map",         _l_read_hash_map},
		{"write_hash_map",        _l_write_hash_map},
		{"read_counted_hash_map", _l_read_counted_hash_map},
		{"write_counted_hash_map",_l_write_counted_hash_map},
		{"read_hash_set",         _l_read_hash_set},
		{"write_hash_set",        _l_write_hash_set},
		{"read_counted_hash_set", _l_read_counted_hash_set},
		{"write_counted_hash_set",_l_write_counted_hash_set},
		{"read_sorted_map",       _l_read_sorted_map},
		{"write_sorted_map",      _l_write_sorted_map},
		{"read_sorted_set",       _l_read_sorted_set},
		{"write_sorted_set",      _l_write_sorted_set},
		{nil, nil},
	}

	lua.createtable(L, 0, i32(len(funcs)))
	lua.L_setfuncs(L, &funcs[0], 0)

	// Expose Tag constants table `xitdb.Tag`
	lua.createtable(L, 0, 16)
	_set_int_field(L, "None",              i64(Tag.None))
	_set_int_field(L, "Index",             i64(Tag.Index))
	_set_int_field(L, "Array_List",        i64(Tag.Array_List))
	_set_int_field(L, "Linked_Array_List", i64(Tag.Linked_Array_List))
	_set_int_field(L, "Hash_Map",          i64(Tag.Hash_Map))
	_set_int_field(L, "KV_Pair",           i64(Tag.KV_Pair))
	_set_int_field(L, "Bytes",             i64(Tag.Bytes))
	_set_int_field(L, "Short_Bytes",       i64(Tag.Short_Bytes))
	_set_int_field(L, "Uint",              i64(Tag.Uint))
	_set_int_field(L, "Int",               i64(Tag.Int))
	_set_int_field(L, "Float",             i64(Tag.Float))
	_set_int_field(L, "Hash_Set",          i64(Tag.Hash_Set))
	_set_int_field(L, "Counted_Hash_Map",  i64(Tag.Counted_Hash_Map))
	_set_int_field(L, "Counted_Hash_Set",  i64(Tag.Counted_Hash_Set))
	_set_int_field(L, "Sorted_Map",        i64(Tag.Sorted_Map))
	_set_int_field(L, "Sorted_Set",        i64(Tag.Sorted_Set))
	lua.setfield(L, -2, "Tag")

	return 1
}

// Push a non-owning `xitdb.Database` userdata wrapping an existing Odin `^Database`.
lua_push_database :: proc(L: ^lua.State, db: ^Database) {
	ud := (^Lua_Db_UD)(lua.newuserdatauv(L, size_of(Lua_Db_UD), 0))
	h := new(Lua_Db_Handle, context.allocator)
	h.ext_db = db
	h.owns_core = false
	ud^ = Lua_Db_UD{
		hdr = Lua_UD_Header{magic = LUA_UD_MAGIC, ud_kind = .Database},
		h   = h,
	}
	_set_ud_mt(L, .Database, LUA_MT_DB)
}

lua_push_read_cursor :: #force_inline proc(L: ^lua.State, rc: Read_Cursor) {
	ud := (^Lua_Cursor_UD)(lua.newuserdatauv(L, size_of(Lua_Cursor_UD), 2))
	ud^ = Lua_Cursor_UD{
		hdr      = Lua_UD_Header{magic = LUA_UD_MAGIC, ud_kind = .Cursor},
		is_write = false,
		rc       = rc,
	}
	_set_ud_mt(L, .Cursor, LUA_MT_CURSOR)
}

lua_push_write_cursor :: #force_inline proc(L: ^lua.State, wc: Write_Cursor) {
	ud := (^Lua_Cursor_UD)(lua.newuserdatauv(L, size_of(Lua_Cursor_UD), 2))
	ud^ = Lua_Cursor_UD{
		hdr      = Lua_UD_Header{magic = LUA_UD_MAGIC, ud_kind = .Cursor},
		is_write = true,
		rc       = wc.read_cursor,
		wc       = wc,
	}
	_set_ud_mt(L, .Cursor, LUA_MT_CURSOR)
}

lua_push_slot :: #force_inline proc(L: ^lua.State, s: Slot) {
	ud := (^Lua_Slot_UD)(lua.newuserdatauv(L, size_of(Lua_Slot_UD), 0))
	ud^ = Lua_Slot_UD{
		hdr  = Lua_UD_Header{magic = LUA_UD_MAGIC, ud_kind = .Slot},
		slot = s,
	}
	_set_ud_mt(L, .Slot, LUA_MT_SLOT)
}

// Push any `Pull_Value` onto the Lua stack as native Lua tables/primitives.
lua_push_pull_value :: proc(L: ^lua.State, pv: Pull_Value) {
	switch v in pv {
	case nil:
		lua.pushnil(L)
	case u64:
		lua.pushinteger(L, lua.Integer(v))
	case i64:
		lua.pushinteger(L, lua.Integer(v))
	case f64:
		lua.pushnumber(L, lua.Number(v))
	case string:
		_push_str(L, v)
	case Bytes:
		lua.createtable(L, 0, 2)
		_push_bytes(L, v.value)
		lua.setfield(L, -2, "value")
		if len(v.format_tag) > 0 {
			_push_bytes(L, v.format_tag)
			lua.setfield(L, -2, "format_tag")
		}
	case Pull_List:
		lua.createtable(L, i32(len(v)), 0)
		for elem, idx in v {
			lua_push_pull_value(L, elem)
			lua.rawseti(L, -2, lua.Integer(idx + 1))
		}
	case Pull_Map:
		lua.createtable(L, 0, i32(len(v)))
		for entry in v {
			_push_str(L, entry.key)
			lua_push_pull_value(L, entry.val)
			lua.rawset(L, -3)
		}
	}
}

// Compile a LuaJIT 2.1 source chunk into binary bytecode (`\x1bLJ`).
lua_compile_bytecode :: proc(
	L: ^lua.State,
	src: string,
	chunk_name: string = "chunk",
	strip_debug := false,
	allocator := context.allocator,
) -> (bytecode: []u8, err_msg: string, ok: bool) {
	cname := strings.clone_to_cstring(chunk_name, context.temp_allocator)
	status := lua.L_loadbuffer(L, raw_data(src), c.size_t(len(src)), cname, "t")
	if status != .OK {
		msg := _lua_tostring_odin(L, -1)
		err_copy := strings.clone(msg, allocator)
		lua.pop(L, 1)
		return nil, err_copy, false
	}

	lua.getglobal(L, "string")
	lua.getfield(L, -1, "dump")
	lua.remove(L, -2)
	lua.pushvalue(L, -2)
	lua.pushboolean(L, b32(strip_debug))
	if lua.Status(lua.pcall(L, 2, 1, 0)) != .OK {
		msg := _lua_tostring_odin(L, -1)
		err_copy := strings.clone(msg, allocator)
		lua.pop(L, 2)
		return nil, err_copy, false
	}

	raw_bc := _lua_tobytes_odin(L, -1)
	bc_copy := make([]u8, len(raw_bc), allocator)
	copy(bc_copy, raw_bc)
	lua.pop(L, 2)
	return bc_copy, "", true
}

// Load compiled LuaJIT 2.1 bytecode onto the top of the Lua stack as a callable function.
lua_load_bytecode :: proc(L: ^lua.State, bytecode: []u8, chunk_name: string = "bytecode") -> (err_msg: string, ok: bool) {
	cname := strings.clone_to_cstring(chunk_name, context.temp_allocator)
	status := lua.L_loadbuffer(L, raw_data(bytecode), c.size_t(len(bytecode)), cname, "b")
	if status != .OK {
		msg := _lua_tostring_odin(L, -1)
		lua.pop(L, 1)
		return msg, false
	}
	return "", true
}

// Execute a Lua script string in `L`. Returns `(true, "")` on success or `(false, err_msg)`.
lua_exec_string :: proc(L: ^lua.State, code: string, chunk_name: string = "chunk") -> (ok: bool, err_msg: string) {
	_lua_store_context(L, context)
	cname := strings.clone_to_cstring(chunk_name, context.temp_allocator)
	if lua.L_loadbuffer(L, raw_data(code), c.size_t(len(code)), cname, nil) != .OK {
		msg := strings.clone(_lua_tostring_odin(L, -1), context.temp_allocator)
		lua.pop(L, 1)
		return false, msg
	}
	if lua.Status(lua.pcall(L, 0, lua.MULTRET, 0)) != .OK {
		msg := strings.clone(_lua_tostring_odin(L, -1), context.temp_allocator)
		lua.pop(L, 1)
		return false, msg
	}
	return true, ""
}

// ----------------------------------------------------------------------------
// Internal Context, Fast Metatable & Userdata Helpers
// ----------------------------------------------------------------------------

@(private = "file")
_push_str :: #force_inline proc(L: ^lua.State, s: string) {
	if len(s) == 0 {
		lua.pushlstring(L, "", 0)
	} else {
		lua.pushlstring(L, cstring(raw_data(s)), c.size_t(len(s)))
	}
}

@(private = "file")
_push_bytes :: #force_inline proc(L: ^lua.State, b: []u8) {
	if len(b) == 0 {
		lua.pushlstring(L, "", 0)
	} else {
		lua.pushlstring(L, cstring(raw_data(b)), c.size_t(len(b)))
	}
}

@(private = "file")
_l_ext_gc :: proc "c" (L: ^lua.State) -> c.int {
	ext := (^_Lua_State_Ext)(lua.touserdata(L, 1))
	if ext != nil && _tls_ext == ext {
		_tls_L = nil
		_tls_ext = nil
	}
	return 0
}

@(private = "file")
_lua_ext_slow :: proc "contextless" (L: ^lua.State) -> ^_Lua_State_Ext {
	if L == nil {
		return nil
	}
	lua.getfield(L, lua.REGISTRYINDEX, LUA_REG_CONTEXT_KEY)
	if lua.type(L, -1) == .USERDATA {
		ext := (^_Lua_State_Ext)(lua.touserdata(L, -1))
		lua.pop(L, 1)
		if ext != nil {
			_tls_L = L
			_tls_ext = ext
			return ext
		}
	}
	lua.pop(L, 1)
	ext := (^_Lua_State_Ext)(lua.newuserdata(L, size_of(_Lua_State_Ext)))
	ext^ = _Lua_State_Ext{
		ctx = runtime.default_context(),
	}
	if lua.L_newmetatable(L, LUA_MT_EXT) != 0 {
		lua.pushcfunction(L, _l_ext_gc)
		lua.setfield(L, -2, "__gc")
	}
	lua.setmetatable(L, -2)
	lua.setfield(L, lua.REGISTRYINDEX, LUA_REG_CONTEXT_KEY)
	_tls_L = L
	_tls_ext = ext
	return ext
}

@(private = "file")
_lua_ext :: #force_inline proc "contextless" (L: ^lua.State) -> ^_Lua_State_Ext {
	if L != nil && L == _tls_L && _tls_ext != nil {
		return _tls_ext
	}
	return _lua_ext_slow(L)
}

@(private = "file")
_lua_store_context :: proc(L: ^lua.State, ctx: runtime.Context) {
	if ext := _lua_ext(L); ext != nil {
		ext.ctx = ctx
	}
}

@(private = "file")
_lua_context :: #force_inline proc "contextless" (L: ^lua.State) -> runtime.Context {
	if L != nil {
		if L == _tls_L && _tls_ext != nil {
			return _tls_ext.ctx
		}
		if ext := _lua_ext_slow(L); ext != nil {
			return ext.ctx
		}
	}
	return runtime.default_context()
}

@(private = "file")
_set_ud_mt :: #force_inline proc(L: ^lua.State, kind: Lua_UD_Kind, fallback_name: cstring) {
	if ext := _lua_ext(L); ext != nil && ext.mt_refs[kind] > 0 {
		lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(ext.mt_refs[kind]))
		lua.setmetatable(L, -2)
		return
	}
	lua.L_setmetatable(L, fallback_name)
}

@(private = "file")
_test_ud :: #force_inline proc "contextless" (L: ^lua.State, idx: c.int, $T: typeid, kind: Lua_UD_Kind) -> ^T {
	p := (^Lua_UD_Header)(lua.touserdata(L, idx))
	if p != nil && p.magic == LUA_UD_MAGIC && p.ud_kind == kind {
		return (^T)(p)
	}
	return nil
}

@(private = "file")
_check_ud :: #force_inline proc(L: ^lua.State, idx: c.int, $T: typeid, kind: Lua_UD_Kind, err_msg: string) -> ^T {
	p := (^Lua_UD_Header)(lua.touserdata(L, idx))
	if p != nil && p.magic == LUA_UD_MAGIC && p.ud_kind == kind {
		return (^T)(p)
	}
	_raise_msg(L, err_msg)
	return nil
}

@(private = "file")
_raise_err :: proc(L: ^lua.State, err: Error, prefix: string = "xitdb") -> c.int {
	msg := fmt.tprintf("%s error: %v", prefix, err)
	cstr := strings.clone_to_cstring(msg, context.temp_allocator)
	return c.int(lua.L_error(L, "%s", cstr))
}

@(private = "file")
_raise_msg :: proc(L: ^lua.State, msg: string) -> c.int {
	cstr := strings.clone_to_cstring(msg, context.temp_allocator)
	return c.int(lua.L_error(L, "%s", cstr))
}

@(private = "file")
_lua_tostring_odin :: #force_inline proc(L: ^lua.State, idx: c.int) -> string {
	length: c.size_t
	ptr := lua.tolstring(L, idx, &length)
	if ptr == nil || length == 0 {
		return ""
	}
	return string(([^]u8)(ptr)[:length])
}

@(private = "file")
_lua_tobytes_odin :: #force_inline proc(L: ^lua.State, idx: c.int) -> []u8 {
	length: c.size_t
	ptr := lua.tolstring(L, idx, &length)
	if ptr == nil || length == 0 {
		return nil
	}
	return ([^]u8)(ptr)[:length]
}

@(private = "file")
_set_int_field :: proc(L: ^lua.State, key: cstring, val: i64) {
	lua.pushinteger(L, lua.Integer(val))
	lua.setfield(L, -2, key)
}

@(private = "file")
_set_str_field :: proc(L: ^lua.State, key: cstring, val: string) {
	_push_str(L, val)
	lua.setfield(L, -2, key)
}

@(private = "file")
_tag_name :: proc(tag: Tag) -> string {
	switch tag {
	case .None:              return "None"
	case .Index:             return "Index"
	case .Array_List:        return "Array_List"
	case .Linked_Array_List: return "Linked_Array_List"
	case .Hash_Map:          return "Hash_Map"
	case .KV_Pair:           return "KV_Pair"
	case .Bytes:             return "Bytes"
	case .Short_Bytes:       return "Short_Bytes"
	case .Uint:              return "Uint"
	case .Int:               return "Int"
	case .Float:             return "Float"
	case .Hash_Set:          return "Hash_Set"
	case .Counted_Hash_Map:  return "Counted_Hash_Map"
	case .Counted_Hash_Set:  return "Counted_Hash_Set"
	case .Sorted_Map:        return "Sorted_Map"
	case .Sorted_Set:        return "Sorted_Set"
	case .Sorted_KV_Pair:    return "Sorted_KV_Pair"
	}
	return "None"
}

@(private = "file")
_check_db_handle :: #force_inline proc(L: ^lua.State, idx: c.int) -> ^Lua_Db_Handle {
	ud := _check_ud(L, idx, Lua_Db_UD, .Database, "invalid xitdb.Database userdata")
	if ud == nil || ud.h == nil {
		_raise_msg(L, "invalid xitdb.Database userdata")
		return nil
	}
	return ud.h
}

@(private = "file")
_active_db :: #force_inline proc(L: ^lua.State, idx: c.int) -> (^Database, ^Lua_Db_Handle) {
	h := _check_db_handle(L, idx)
	if h == nil do return nil, nil
	if h.is_closed {
		_raise_msg(L, "xitdb.Database is closed")
		return nil, nil
	}
	if h.ext_db != nil {
		return h.ext_db, h
	}
	return &h.db, h
}

@(private = "file")
_check_cursor :: #force_inline proc(L: ^lua.State, idx: c.int) -> ^Lua_Cursor_UD {
	return _check_ud(L, idx, Lua_Cursor_UD, .Cursor, "expected xitdb.Cursor")
}

@(private = "file")
_extract_read_cursor :: #force_inline proc(L: ^lua.State, idx: c.int) -> (Read_Cursor, bool) {
	hdr := (^Lua_UD_Header)(lua.touserdata(L, idx))
	if hdr != nil && hdr.magic == LUA_UD_MAGIC {
		#partial switch hdr.ud_kind {
		case .Cursor:
			return (^Lua_Cursor_UD)(hdr).rc, true
		case .Collection:
			return (^Lua_Collection_UD)(hdr).rc, true
		}
	}
	return {}, false
}

@(private = "file")
_extract_write_cursor :: #force_inline proc(L: ^lua.State, idx: c.int) -> (Write_Cursor, bool) {
	hdr := (^Lua_UD_Header)(lua.touserdata(L, idx))
	if hdr != nil && hdr.magic == LUA_UD_MAGIC {
		#partial switch hdr.ud_kind {
		case .Cursor:
			cud := (^Lua_Cursor_UD)(hdr)
			if cud.is_write do return cud.wc, true
		case .Collection:
			col := (^Lua_Collection_UD)(hdr)
			if col.is_write do return col.wc, true
		}
	}
	return {}, false
}

// Convert a Lua value at `idx` into `Writeable_Data`.
// By default:
// - `xitdb.uint(n)` -> `u64(n)`
// - `xitdb.int(n)` -> `i64(n)`
// - `xitdb.float(n)` -> `f64(n)`
// - `xitdb.bytes(s, tag)` -> `Bytes{value = s, format_tag = tag}`
// - `xitdb.Slot` / `xitdb.Cursor` / `xitdb.Collection` -> `Slot`
// - Plain Lua integer: if `default_uint_for_non_neg` is true and `n >= 0`, maps to `u64(n)`, else `i64(n)`.
// - Plain Lua float -> `f64`
// - Plain Lua boolean -> `u64(1)` / `u64(0)`
// - Plain Lua string -> `string`
@(private = "file")
_lua_to_writeable_data :: proc(
	L: ^lua.State,
	idx: c.int,
	default_uint_for_non_neg := true,
	clone_strings := false,
	str_allocator := context.temp_allocator,
) -> (data: Writeable_Data, err: Error) {
	ltype := lua.type(L, idx)
	#partial switch ltype {
	case .NIL, .NONE:
		return nil, nil

	case .BOOLEAN:
		b := bool(lua.toboolean(L, idx))
		return u64(1 if b else 0), nil

	case .NUMBER:
		if bool(lua.isinteger(L, idx)) {
			iv := i64(lua.tointeger(L, idx))
			if default_uint_for_non_neg && iv >= 0 {
				return u64(iv), nil
			}
			return iv, nil
		}
		fv := f64(lua.tonumber(L, idx))
		return fv, nil

	case .STRING:
		s := _lua_tostring_odin(L, idx)
		if clone_strings {
			s = strings.clone(s, str_allocator)
		}
		return s, nil

	case .USERDATA:
		hdr := (^Lua_UD_Header)(lua.touserdata(L, idx))
		if hdr != nil && hdr.magic == LUA_UD_MAGIC {
			#partial switch hdr.ud_kind {
			case .Typed_Val:
				tv := (^Lua_Typed_Val_UD)(hdr)
				switch tv.kind {
				case .Uint:
					return tv.u_val, nil
				case .Int:
					return tv.i_val, nil
				case .Float:
					return tv.f_val, nil
				case .Tagged_Bytes:
					lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(tv.str_ref))
					s := _lua_tostring_odin(L, -1)
					if clone_strings {
						s = strings.clone(s, str_allocator)
					}
					lua.pop(L, 1)
					if tv.has_tag {
						tag_slice := make([]u8, 2, str_allocator)
						tag_slice[0] = tv.tag[0]
						tag_slice[1] = tv.tag[1]
						return new_tagged_string(s, tag_slice), nil
					}
					return new_bytes(transmute([]u8)s), nil
				}
			case .Slot:
				return (^Lua_Slot_UD)(hdr).slot, nil
			case .Cursor:
				s := cursor_slot((^Lua_Cursor_UD)(hdr).rc) or_return
				return s, nil
			case .Collection:
				s := cursor_slot((^Lua_Collection_UD)(hdr).rc) or_return
				return s, nil
			}
		}
	}
	return nil, .Unexpected_Tag
}

// ----------------------------------------------------------------------------
// Lua Table Marshal & Unmarshal (Layer 3 for Lua)
// ----------------------------------------------------------------------------

// Marshal a Lua value or table at `idx` into `cursor`.
// Supports optional collection sigils on table keys (`"$sorted"`, `"#counted"`, `"[[linked]]"`, `"%hset"`, `"^sset"`, `"#%cset"`, or `"bio,tag=md"`).
lua_marshal_value :: proc(L: ^lua.State, idx: c.int, cursor: ^Write_Cursor) -> Error {
	abs_idx := lua.absindex(L, idx)
	ltype := lua.type(L, abs_idx)

	if ltype != .TABLE {
		wdata := _lua_to_writeable_data(L, abs_idx, true) or_return
		return cursor_write(cursor, wdata)
	}

	// Check if table has a `__xitdb_type` hint or if it's a sequential 1..N Lua array
	lua.getfield(L, abs_idx, "__xitdb_type")
	type_hint := ""
	if lua.type(L, -1) == .STRING {
		type_hint = _lua_tostring_odin(L, -1)
	}
	lua.pop(L, 1)

	if type_hint == "linked_list" {
		ll_col := write_linked_array_list_init(cursor^) or_return
		linked_array_list_slice(&ll_col, 0, 0) or_return
		n := i64(lua.rawlen(L, abs_idx))
		for i: i64 = 1; i <= n; i += 1 {
			lua.rawgeti(L, abs_idx, lua.Integer(i))
			if lua.type(L, -1) != .TABLE {
				wdata, w_err := _lua_to_writeable_data(L, -1, true)
				if w_err != nil {
					lua.pop(L, 1)
					return w_err
				}
				err := linked_array_list_append(&ll_col, wdata)
				lua.pop(L, 1)
				if err != nil do return err
			} else {
				ecur := linked_array_list_append_cursor(&ll_col) or_return
				err := lua_marshal_value(L, -1, &ecur)
				lua.pop(L, 1)
				if err != nil do return err
			}
		}
		return nil
	} else if type_hint == "sorted_set" {
		ss_col := write_sorted_set_init(cursor^) or_return
		n := i64(lua.rawlen(L, abs_idx))
		for i: i64 = 1; i <= n; i += 1 {
			lua.rawgeti(L, abs_idx, lua.Integer(i))
			s := _lua_tostring_odin(L, -1)
			err := sorted_set_put(&ss_col, s)
			lua.pop(L, 1)
			if err != nil do return err
		}
		return nil
	} else if type_hint == "hash_set" {
		hs_col := write_hash_set_init(cursor^) or_return
		n := i64(lua.rawlen(L, abs_idx))
		for i: i64 = 1; i <= n; i += 1 {
			lua.rawgeti(L, abs_idx, lua.Integer(i))
			s := _lua_tostring_odin(L, -1)
			err := hash_set_put(&hs_col, s)
			lua.pop(L, 1)
			if err != nil do return err
		}
		return nil
	}

	// Inspect keys to see if it's a pure sequential array `[1..N]` (only when `raw_len > 0`)
	raw_len := i64(lua.rawlen(L, abs_idx))
	is_seq_array := false
	if raw_len > 0 && type_hint == "" {
		is_seq_array = true
		total_keys := i64(0)
		lua.pushnil(L)
		for lua.next(L, abs_idx) != 0 {
			lua.pop(L, 1) // pop value, keep key
			total_keys += 1
			if bool(lua.isinteger(L, -1)) {
				k_int := i64(lua.tointeger(L, -1))
				if k_int < 1 || k_int > raw_len {
					is_seq_array = false
					lua.pop(L, 1)
					break
				}
			} else {
				is_seq_array = false
				lua.pop(L, 1)
				break
			}
		}
		if total_keys != raw_len {
			is_seq_array = false
		}
	}

	if is_seq_array {
		al_col := write_array_list_init(cursor^) or_return
		array_list_slice(&al_col, 0) or_return
		for i: i64 = 1; i <= raw_len; i += 1 {
			lua.rawgeti(L, abs_idx, lua.Integer(i))
			if lua.type(L, -1) != .TABLE {
				wdata, w_err := _lua_to_writeable_data(L, -1, true)
				if w_err != nil {
					lua.pop(L, 1)
					return w_err
				}
				err := array_list_append(&al_col, wdata)
				lua.pop(L, 1)
				if err != nil do return err
			} else {
				ecur := array_list_append_cursor(&al_col) or_return
				err := lua_marshal_value(L, -1, &ecur)
				lua.pop(L, 1)
				if err != nil do return err
			}
		}
		return nil
	}

	// Otherwise marshal as a map (`Hash_Map`, `Counted_Hash_Map`, or `Sorted_Map`)
	if type_hint == "sorted_map" {
		sm_col := write_sorted_map_init(cursor^) or_return
		lua.pushnil(L)
		for lua.next(L, abs_idx) != 0 {
			if lua.type(L, -2) == .STRING {
				k_str := _lua_tostring_odin(L, -2)
				if k_str != "__xitdb_type" {
					if lua.type(L, -1) != .TABLE {
						wdata, w_err := _lua_to_writeable_data(L, -1, true)
						if w_err != nil {
							lua.pop(L, 2)
							return w_err
						}
						err := sorted_map_put(&sm_col, k_str, wdata)
						if err != nil {
							lua.pop(L, 2)
							return err
						}
					} else {
						vcur := sorted_map_put_cursor(&sm_col, k_str) or_return
						err := lua_marshal_value(L, -1, &vcur)
						if err != nil {
							lua.pop(L, 2)
							return err
						}
					}
				}
			}
			lua.pop(L, 1)
		}
		return nil
	}

	hm_col: Write_Hash_Map
	if type_hint == "counted_map" {
		cm := write_counted_hash_map_init(cursor^) or_return
		hm_col = cm.write_hash_map
	} else {
		hm_col = write_hash_map_init(cursor^) or_return
	}

	lua.pushnil(L)
	for lua.next(L, abs_idx) != 0 {
		if lua.type(L, -2) == .STRING {
			raw_key := _lua_tostring_odin(L, -2)
			if raw_key != "__xitdb_type" {
				err := _lua_marshal_map_entry(L, &hm_col, raw_key, -1)
				if err != nil {
					lua.pop(L, 2)
					return err
				}
			}
		}
		lua.pop(L, 1)
	}
	return nil
}

@(private = "file")
_lua_marshal_map_entry :: proc(L: ^lua.State, hm_col: ^Write_Hash_Map, raw_key: string, val_idx: c.int) -> Error {
	abs_val := lua.absindex(L, val_idx)
	spec := _parse_raw_tag_val(raw_key, raw_key)
	if spec.skip {
		return nil
	}
	val_type := lua.type(L, abs_val)
	if len(spec.format_tag) == 2 && val_type == .STRING {
		s := _lua_tostring_odin(L, abs_val)
		return hash_map_put(hm_col, spec.name, new_tagged_string(s, transmute([]u8)spec.format_tag))
	}

	if val_type != .TABLE {
		wdata := _lua_to_writeable_data(L, abs_val, true) or_return
		return hash_map_put(hm_col, spec.name, wdata)
	}

	switch spec.col_prefix {
	case '[':
		fcur := hash_map_put_cursor(hm_col, spec.name) or_return
		ll_col := write_linked_array_list_init(fcur) or_return
		linked_array_list_slice(&ll_col, 0, 0) or_return
		n := i64(lua.rawlen(L, abs_val))
		for i: i64 = 1; i <= n; i += 1 {
			lua.rawgeti(L, abs_val, lua.Integer(i))
			if lua.type(L, -1) != .TABLE {
				wdata, w_err := _lua_to_writeable_data(L, -1, true)
				if w_err != nil {
					lua.pop(L, 1)
					return w_err
				}
				err := linked_array_list_append(&ll_col, wdata)
				lua.pop(L, 1)
				if err != nil do return err
			} else {
				ecur := linked_array_list_append_cursor(&ll_col) or_return
				err := lua_marshal_value(L, -1, &ecur)
				lua.pop(L, 1)
				if err != nil do return err
			}
		}
		return nil
	case '%':
		fcur := hash_map_put_cursor(hm_col, spec.name) or_return
		hs_col := write_hash_set_init(fcur) or_return
		n := i64(lua.rawlen(L, abs_val))
		for i: i64 = 1; i <= n; i += 1 {
			lua.rawgeti(L, abs_val, lua.Integer(i))
			s := _lua_tostring_odin(L, -1)
			err := hash_set_put(&hs_col, s)
			lua.pop(L, 1)
			if err != nil do return err
		}
		return nil
	case '^':
		fcur := hash_map_put_cursor(hm_col, spec.name) or_return
		ss_col := write_sorted_set_init(fcur) or_return
		n := i64(lua.rawlen(L, abs_val))
		for i: i64 = 1; i <= n; i += 1 {
			lua.rawgeti(L, abs_val, lua.Integer(i))
			s := _lua_tostring_odin(L, -1)
			err := sorted_set_put(&ss_col, s)
			lua.pop(L, 1)
			if err != nil do return err
		}
		return nil
	case '$':
		fcur := hash_map_put_cursor(hm_col, spec.name) or_return
		sm_col := write_sorted_map_init(fcur) or_return
		lua.pushnil(L)
		for lua.next(L, abs_val) != 0 {
			if lua.type(L, -2) == .STRING {
				k := _lua_tostring_odin(L, -2)
				if lua.type(L, -1) != .TABLE {
					wdata, w_err := _lua_to_writeable_data(L, -1, true)
					if w_err != nil {
						lua.pop(L, 2)
						return w_err
					}
					err := sorted_map_put(&sm_col, k, wdata)
					if err != nil {
						lua.pop(L, 2)
						return err
					}
				} else {
					vcur := sorted_map_put_cursor(&sm_col, k) or_return
					err := lua_marshal_value(L, -1, &vcur)
					if err != nil {
						lua.pop(L, 2)
						return err
					}
				}
			}
			lua.pop(L, 1)
		}
		return nil
	case '#':
		fcur := hash_map_put_cursor(hm_col, spec.name) or_return
		cm_col := write_counted_hash_map_init(fcur) or_return
		lua.pushnil(L)
		for lua.next(L, abs_val) != 0 {
			if lua.type(L, -2) == .STRING {
				k := _lua_tostring_odin(L, -2)
				if lua.type(L, -1) != .TABLE {
					wdata, w_err := _lua_to_writeable_data(L, -1, true)
					if w_err != nil {
						lua.pop(L, 2)
						return w_err
					}
					err := hash_map_put(&cm_col.write_hash_map, k, wdata)
					if err != nil {
						lua.pop(L, 2)
						return err
					}
				} else {
					vcur := hash_map_put_cursor(&cm_col.write_hash_map, k) or_return
					err := lua_marshal_value(L, -1, &vcur)
					if err != nil {
						lua.pop(L, 2)
						return err
					}
				}
			}
			lua.pop(L, 1)
		}
		return nil
	}

	fcur := hash_map_put_cursor(hm_col, spec.name) or_return
	return lua_marshal_value(L, abs_val, &fcur)
}

@(private = "file")
_Lua_Visited_Stack :: struct {
	ptrs:  [64]i64,
	count: int,
}

// Unmarshal a `Read_Cursor` directly onto the Lua stack as a Lua table or primitive.
// Unlike `pull("*")`, tagged `Bytes` fields unmarshal directly to Lua strings so
// round-tripping a DTO table via `marshal` -> `unmarshal` is 1:1.
lua_unmarshal_cursor :: proc(L: ^lua.State, cursor: Read_Cursor) -> Error {
	visited: _Lua_Visited_Stack
	return _lua_unmarshal_with_visited(L, cursor, &visited)
}

@(private = "file")
_lua_unmarshal_with_visited :: proc(L: ^lua.State, cursor: Read_Cursor, visited: ^_Lua_Visited_Stack) -> Error {
	slot := cursor_slot(cursor) or_return
	is_col := _is_collection_tag(slot.tag)
	if is_col {
		for i in 0 ..< visited.count {
			if visited.ptrs[i] == slot.value {
				lua.pushnil(L)
				return nil
			}
		}
		if visited.count < len(visited.ptrs) {
			visited.ptrs[visited.count] = slot.value
			visited.count += 1
		}
	}
	defer if is_col && visited.count > 0 {
		visited.count -= 1
	}

	#partial switch slot.tag {
	case .None:
		lua.pushnil(L)
		return nil
	case .Uint:
		u := cursor_read_uint(cursor) or_return
		lua.pushinteger(L, lua.Integer(u))
		return nil
	case .Int:
		i := cursor_read_int(cursor) or_return
		lua.pushinteger(L, lua.Integer(i))
		return nil
	case .Float:
		f := cursor_read_float(cursor) or_return
		lua.pushnumber(L, lua.Number(f))
		return nil
	case .Short_Bytes, .Bytes:
		var_buf: [128]u8
		if b, err := cursor_read_bytes_buf(cursor, var_buf[:]); err == nil {
			_push_bytes(L, b.value)
			return nil
		}
		s := cursor_read_string(cursor, 0, context.temp_allocator) or_return
		_push_str(L, s)
		return nil
	case .Array_List, .Linked_Array_List:
		it := cursor_iterator(cursor) or_return
		lua.createtable(L, 4, 0)
		idx: lua.Integer = 1
		for {
			c_maybe := cursor_iterator_next(&it) or_return
			c, ok := c_maybe.?
			if !ok do break
			_lua_unmarshal_with_visited(L, c, visited) or_return
			lua.rawseti(L, -2, idx)
			idx += 1
		}
		return nil
	case .Hash_Set, .Counted_Hash_Set, .Sorted_Set:
		it := cursor_iterator(cursor) or_return
		lua.createtable(L, 4, 0)
		idx: lua.Integer = 1
		for {
			c_maybe := cursor_iterator_next(&it) or_return
			c, ok := c_maybe.?
			if !ok do break
			kc, _, kv_err := cursor_read_kv_pair_slots(c)
			if kv_err != nil do return kv_err
			_lua_unmarshal_with_visited(L, kc, visited) or_return
			lua.rawseti(L, -2, idx)
			idx += 1
		}
		return nil
	case .Hash_Map, .Counted_Hash_Map, .Sorted_Map:
		it := cursor_iterator(cursor) or_return
		lua.createtable(L, 0, 8)
		key_buf: [128]u8
		for {
			c_maybe := cursor_iterator_next(&it) or_return
			c, ok := c_maybe.?
			if !ok do break
			kc, vc, kv_err := cursor_read_kv_pair_slots(c)
			if kv_err != nil do return kv_err
			if kb, b_err := cursor_read_bytes_buf(kc, key_buf[:]); b_err == nil {
				if string(kb.value) == "__tx" {
					continue
				}
				_push_bytes(L, kb.value)
			} else {
				k_str := cursor_read_string(kc, 0, context.temp_allocator) or_return
				if k_str == "__tx" {
					continue
				}
				_push_str(L, k_str)
			}
			_lua_unmarshal_with_visited(L, vc, visited) or_return
			lua.rawset(L, -3)
		}
		return nil
	}
	return .Unexpected_Tag
}

// ----------------------------------------------------------------------------
// Module Constructors (`open_memory`, `open_file`, `uint`, `int`, etc.)
// ----------------------------------------------------------------------------

@(private = "file")
_parse_hasher_arg :: proc(L: ^lua.State, idx: c.int) -> Hasher {
	if lua.type(L, idx) == .STRING {
		algo := _lua_tostring_odin(L, idx)
		if algo == "sha256" || algo == "sha2" {
			return sha256_hasher(string_to_id("sha2"))
		}
	} else if lua.type(L, idx) == .TABLE {
		lua.getfield(L, idx, "hash")
		algo := _lua_tostring_odin(L, -1)
		lua.pop(L, 1)
		if algo == "sha256" || algo == "sha2" {
			return sha256_hasher(string_to_id("sha2"))
		}
	}
	return sha1_hasher(string_to_id("sha1"))
}

@(private = "file")
_l_open_memory :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	hasher := _parse_hasher_arg(L, 1)

	h := new(Lua_Db_Handle, context.allocator)
	if lua.type(L, 1) == .TABLE {
		lua.getfield(L, 1, "bytes")
		if lua.type(L, -1) == .STRING {
			raw := _lua_tobytes_odin(L, -1)
			h.core = core_memory_from_bytes(raw, context.allocator)
		} else {
			h.core = core_memory_init(context.allocator)
		}
		lua.pop(L, 1)
	} else {
		h.core = core_memory_init(context.allocator)
	}
	h.owns_core = true

	db, err := database_init(&h.core, hasher)
	if err != nil {
		_ = core_destroy(&h.core)
		free(h, context.allocator)
		return _raise_err(L, err, "open_memory")
	}
	h.db = db

	ud := (^Lua_Db_UD)(lua.newuserdatauv(L, size_of(Lua_Db_UD), 0))
	ud^ = Lua_Db_UD{
		hdr = Lua_UD_Header{magic = LUA_UD_MAGIC, ud_kind = .Database},
		h   = h,
	}
	_set_ud_mt(L, .Database, LUA_MT_DB)
	return 1
}

@(private = "file")
_l_open_file :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	path := _lua_tostring_odin(L, 1)
	if len(path) == 0 {
		return _raise_msg(L, "open_file requires a non-empty path")
	}
	hasher := _parse_hasher_arg(L, 2)
	trunc := false
	fsync := false
	if lua.type(L, 2) == .TABLE {
		lua.getfield(L, 2, "truncate")
		trunc = bool(lua.toboolean(L, -1))
		lua.pop(L, 1)
		lua.getfield(L, 2, "fsync")
		fsync = bool(lua.toboolean(L, -1))
		lua.pop(L, 1)
	} else if lua.type(L, 3) == .BOOLEAN {
		trunc = bool(lua.toboolean(L, 3))
	}

	flags := os.File_Flags{.Read, .Write, .Create}
	if trunc {
		flags += {.Trunc}
	}
	core, open_err := core_file_open(path, flags, fsync)
	if open_err != nil {
		return _raise_msg(L, fmt.tprintf("open_file failed for %s: %v", path, open_err))
	}

	h := new(Lua_Db_Handle, context.allocator)
	h.core = core
	h.owns_core = true
	db, err := database_init(&h.core, hasher)
	if err != nil {
		_ = core_destroy(&h.core, true)
		free(h, context.allocator)
		return _raise_err(L, err, "open_file")
	}
	h.db = db

	ud := (^Lua_Db_UD)(lua.newuserdatauv(L, size_of(Lua_Db_UD), 0))
	ud^ = Lua_Db_UD{
		hdr = Lua_UD_Header{magic = LUA_UD_MAGIC, ud_kind = .Database},
		h   = h,
	}
	_set_ud_mt(L, .Database, LUA_MT_DB)
	return 1
}

@(private = "file")
_l_open_buffered_file :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	path := _lua_tostring_odin(L, 1)
	if len(path) == 0 {
		return _raise_msg(L, "open_buffered_file requires a non-empty path")
	}
	buf_size: i64 = 65536
	if bool(lua.isinteger(L, 2)) {
		buf_size = i64(lua.tointeger(L, 2))
	}
	hasher := _parse_hasher_arg(L, 3)
	trunc := false
	fsync := false
	if lua.type(L, 3) == .TABLE {
		lua.getfield(L, 3, "truncate")
		trunc = bool(lua.toboolean(L, -1))
		lua.pop(L, 1)
		lua.getfield(L, 3, "fsync")
		fsync = bool(lua.toboolean(L, -1))
		lua.pop(L, 1)
	} else if lua.type(L, 4) == .BOOLEAN {
		trunc = bool(lua.toboolean(L, 4))
	}

	flags := os.File_Flags{.Read, .Write, .Create}
	if trunc {
		flags += {.Trunc}
	}
	core, open_err := core_buffered_file_open(path, buf_size, flags, fsync, context.allocator)
	if open_err != nil {
		return _raise_msg(L, fmt.tprintf("open_buffered_file failed for %s: %v", path, open_err))
	}

	h := new(Lua_Db_Handle, context.allocator)
	h.core = core
	h.owns_core = true
	db, err := database_init(&h.core, hasher)
	if err != nil {
		_ = core_destroy(&h.core, true)
		free(h, context.allocator)
		return _raise_err(L, err, "open_buffered_file")
	}
	h.db = db

	ud := (^Lua_Db_UD)(lua.newuserdatauv(L, size_of(Lua_Db_UD), 0))
	ud^ = Lua_Db_UD{
		hdr = Lua_UD_Header{magic = LUA_UD_MAGIC, ud_kind = .Database},
		h   = h,
	}
	_set_ud_mt(L, .Database, LUA_MT_DB)
	return 1
}

@(private = "file")
_l_temp_path :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	suffix := _lua_tostring_odin(L, 1)
	if len(suffix) == 0 {
		suffix = "temp.xit"
	}
	dir, err := os.temp_directory(context.temp_allocator)
	if err != nil || len(dir) == 0 {
		dir = "."
	}
	p := fmt.tprintf("%s/xitdb_lua_%p_%s", dir, L, suffix)
	_push_str(L, p)
	return 1
}

@(private = "file")
_l_remove_file :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	p := _lua_tostring_odin(L, 1)
	if len(p) > 0 {
		_ = os.remove(p)
	}
	return 0
}

@(private = "file")
_l_now_ns :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	// Monotonic nanosecond clock for high-resolution Lua benchmarking
	lua.pushinteger(L, lua.Integer(_monotonic_ns()))
	return 1
}

@(private = "file")
_l_uint :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	v := u64(lua.L_checkinteger(L, 1))
	ud := (^Lua_Typed_Val_UD)(lua.newuserdatauv(L, size_of(Lua_Typed_Val_UD), 0))
	ud^ = Lua_Typed_Val_UD{
		hdr     = Lua_UD_Header{magic = LUA_UD_MAGIC, ud_kind = .Typed_Val},
		kind    = .Uint,
		u_val   = v,
		str_ref = lua.REFNIL,
	}
	_set_ud_mt(L, .Typed_Val, LUA_MT_TYPED_VAL)
	return 1
}

@(private = "file")
_l_int :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	v := i64(lua.L_checkinteger(L, 1))
	ud := (^Lua_Typed_Val_UD)(lua.newuserdatauv(L, size_of(Lua_Typed_Val_UD), 0))
	ud^ = Lua_Typed_Val_UD{
		hdr     = Lua_UD_Header{magic = LUA_UD_MAGIC, ud_kind = .Typed_Val},
		kind    = .Int,
		i_val   = v,
		str_ref = lua.REFNIL,
	}
	_set_ud_mt(L, .Typed_Val, LUA_MT_TYPED_VAL)
	return 1
}

@(private = "file")
_l_float :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	v := f64(lua.L_checknumber(L, 1))
	ud := (^Lua_Typed_Val_UD)(lua.newuserdatauv(L, size_of(Lua_Typed_Val_UD), 0))
	ud^ = Lua_Typed_Val_UD{
		hdr     = Lua_UD_Header{magic = LUA_UD_MAGIC, ud_kind = .Typed_Val},
		kind    = .Float,
		f_val   = v,
		str_ref = lua.REFNIL,
	}
	_set_ud_mt(L, .Typed_Val, LUA_MT_TYPED_VAL)
	return 1
}

@(private = "file")
_l_bytes :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	if lua.type(L, 1) != .STRING {
		return _raise_msg(L, "xitdb.bytes/tagged expects string at argument 1")
	}
	has_tag := false
	tag_bytes: [2]u8
	if lua.type(L, 2) == .STRING {
		tstr := _lua_tostring_odin(L, 2)
		if len(tstr) != 2 {
			return _raise_err(L, .Invalid_Format_Tag_Size, "xitdb.bytes")
		}
		has_tag = true
		tag_bytes[0] = tstr[0]
		tag_bytes[1] = tstr[1]
	}
	lua.pushvalue(L, 1)
	ref := lua.L_ref(L, lua.REGISTRYINDEX)

	ud := (^Lua_Typed_Val_UD)(lua.newuserdatauv(L, size_of(Lua_Typed_Val_UD), 0))
	ud^ = Lua_Typed_Val_UD{
		hdr     = Lua_UD_Header{magic = LUA_UD_MAGIC, ud_kind = .Typed_Val},
		kind    = .Tagged_Bytes,
		has_tag = has_tag,
		tag     = tag_bytes,
		str_ref = ref,
	}
	_set_ud_mt(L, .Typed_Val, LUA_MT_TYPED_VAL)
	return 1
}

@(private = "file")
_l_typed_val_gc :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	ud := _test_ud(L, 1, Lua_Typed_Val_UD, .Typed_Val)
	if ud != nil && ud.str_ref != lua.REFNIL && ud.str_ref != lua.NOREF {
		lua.L_unref(L, lua.REGISTRYINDEX, ud.str_ref)
		ud.str_ref = lua.REFNIL
	}
	return 0
}

@(private = "file")
_l_slot :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	if lua.gettop(L) == 0 {
		lua_push_slot(L, Slot{})
		return 1
	}
	tag := Tag(lua.L_checkinteger(L, 1))
	val := i64(lua.L_optinteger(L, 2, 0))
	full := bool(lua.toboolean(L, 3))
	lua_push_slot(L, Slot{tag = tag, value = val, full = full})
	return 1
}

@(private = "file")
_l_memory_offset_map :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	ud := (^Lua_Offset_Map_UD)(lua.newuserdatauv(L, size_of(Lua_Offset_Map_UD), 0))
	ud^ = Lua_Offset_Map_UD{
		hdr = Lua_UD_Header{magic = LUA_UD_MAGIC, ud_kind = .Offset_Map},
		om  = memory_offset_map_init(context.allocator),
	}
	_set_ud_mt(L, .Offset_Map, LUA_MT_OFFSET_MAP)
	return 1
}

@(private = "file")
_l_file_offset_map :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	wc, ok := _extract_write_cursor(L, 1)
	if !ok {
		if lua.type(L, 1) == .USERDATA {
			if db, _ := _active_db(L, 1); db != nil {
				wc = database_root_cursor(db)
				ok = true
			}
		}
	}
	if !ok {
		return _raise_msg(L, "xitdb.file_offset_map requires a Write_Cursor or Database")
	}
	fom, err := file_offset_map_init(wc)
	if err != nil {
		return _raise_err(L, err, "file_offset_map")
	}
	ud := (^Lua_Offset_Map_UD)(lua.newuserdatauv(L, size_of(Lua_Offset_Map_UD), 0))
	ud^ = Lua_Offset_Map_UD{
		hdr = Lua_UD_Header{magic = LUA_UD_MAGIC, ud_kind = .Offset_Map},
		om  = fom,
	}
	_set_ud_mt(L, .Offset_Map, LUA_MT_OFFSET_MAP)
	return 1
}

@(private = "file")
_l_offset_map_close :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	ud := _test_ud(L, 1, Lua_Offset_Map_UD, .Offset_Map)
	if ud != nil && !ud.destroyed {
		offset_map_destroy(&ud.om)
		ud.destroyed = true
	}
	return 0
}

@(private = "file")
_l_compile_bytecode :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	strip := bool(lua.toboolean(L, 2))
	if lua.type(L, 1) == .FUNCTION {
		lua.pushvalue(L, 1)
	} else {
		src := _lua_tostring_odin(L, 1)
		cname := strings.clone_to_cstring("chunk", context.temp_allocator)
		if lua.L_loadbuffer(L, raw_data(src), c.size_t(len(src)), cname, "t") != .OK {
			return c.int(lua.error(L))
		}
	}

	lua.getglobal(L, "string")
	lua.getfield(L, -1, "dump")
	lua.remove(L, -2)
	lua.pushvalue(L, -2)
	lua.pushboolean(L, b32(strip))
	lua.call(L, 2, 1)
	return 1
}

@(private = "file")
_l_load_bytecode :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	bc := _lua_tobytes_odin(L, 1)
	chunk_name := _lua_tostring_odin(L, 2)
	if len(chunk_name) == 0 {
		chunk_name = "bytecode"
	}
	cname := strings.clone_to_cstring(chunk_name, context.temp_allocator)
	if lua.L_loadbuffer(L, raw_data(bc), c.size_t(len(bc)), cname, "b") != .OK {
		return c.int(lua.error(L))
	}
	return 1
}

// ----------------------------------------------------------------------------
// Collection Constructors (`read_array_list`, `write_hash_map`, etc.)
// ----------------------------------------------------------------------------

@(private = "file")
_push_collection :: #force_inline proc(L: ^lua.State, kind: Lua_Collection_Kind, is_write: bool, rc: Read_Cursor, wc: Write_Cursor = {}) {
	ud := (^Lua_Collection_UD)(lua.newuserdata(L, size_of(Lua_Collection_UD)))
	ud^ = Lua_Collection_UD{
		hdr      = Lua_UD_Header{magic = LUA_UD_MAGIC, ud_kind = .Collection},
		kind     = kind,
		is_write = is_write,
		rc       = rc,
		wc       = wc,
	}
	_set_ud_mt(L, .Collection, LUA_MT_COLLECTION)
}

@(private = "file")
_open_read_collection :: proc(L: ^lua.State, kind: Lua_Collection_Kind) -> c.int {
	rc, ok := _extract_read_cursor(L, 1)
	if !ok {
		return _raise_msg(L, "expected Cursor or Collection at argument 1")
	}
	switch kind {
	case .Array_List:
		col, err := read_array_list_init(rc)
		if err != nil do return _raise_err(L, err, "read_array_list")
		_push_collection(L, kind, false, col.cursor)
	case .Linked_Array_List:
		col, err := read_linked_array_list_init(rc)
		if err != nil do return _raise_err(L, err, "read_linked_array_list")
		_push_collection(L, kind, false, col.cursor)
	case .Hash_Map:
		col, err := read_hash_map_init(rc)
		if err != nil do return _raise_err(L, err, "read_hash_map")
		_push_collection(L, kind, false, col.cursor)
	case .Counted_Hash_Map:
		col, err := read_counted_hash_map_init(rc)
		if err != nil do return _raise_err(L, err, "read_counted_hash_map")
		_push_collection(L, kind, false, col.cursor)
	case .Hash_Set:
		col, err := read_hash_set_init(rc)
		if err != nil do return _raise_err(L, err, "read_hash_set")
		_push_collection(L, kind, false, col.cursor)
	case .Counted_Hash_Set:
		col, err := read_counted_hash_set_init(rc)
		if err != nil do return _raise_err(L, err, "read_counted_hash_set")
		_push_collection(L, kind, false, col.cursor)
	case .Sorted_Map:
		col, err := read_sorted_map_init(rc)
		if err != nil do return _raise_err(L, err, "read_sorted_map")
		_push_collection(L, kind, false, col.cursor)
	case .Sorted_Set:
		col, err := read_sorted_set_init(rc)
		if err != nil do return _raise_err(L, err, "read_sorted_set")
		_push_collection(L, kind, false, col.cursor)
	}
	return 1
}

@(private = "file")
_open_write_collection :: proc(L: ^lua.State, kind: Lua_Collection_Kind) -> c.int {
	wc, ok := _extract_write_cursor(L, 1)
	if !ok {
		return _raise_msg(L, "expected Write_Cursor at argument 1")
	}
	switch kind {
	case .Array_List:
		col, err := write_array_list_init(wc)
		if err != nil do return _raise_err(L, err, "write_array_list")
		_push_collection(L, kind, true, col.cursor, col.write_cursor)
	case .Linked_Array_List:
		col, err := write_linked_array_list_init(wc)
		if err != nil do return _raise_err(L, err, "write_linked_array_list")
		_push_collection(L, kind, true, col.cursor, col.write_cursor)
	case .Hash_Map:
		col, err := write_hash_map_init(wc)
		if err != nil do return _raise_err(L, err, "write_hash_map")
		_push_collection(L, kind, true, col.cursor, col.write_cursor)
	case .Counted_Hash_Map:
		col, err := write_counted_hash_map_init(wc)
		if err != nil do return _raise_err(L, err, "write_counted_hash_map")
		_push_collection(L, kind, true, col.cursor, col.write_cursor)
	case .Hash_Set:
		col, err := write_hash_set_init(wc)
		if err != nil do return _raise_err(L, err, "write_hash_set")
		_push_collection(L, kind, true, col.cursor, col.write_cursor)
	case .Counted_Hash_Set:
		col, err := write_counted_hash_set_init(wc)
		if err != nil do return _raise_err(L, err, "write_counted_hash_set")
		_push_collection(L, kind, true, col.cursor, col.write_cursor)
	case .Sorted_Map:
		col, err := write_sorted_map_init(wc)
		if err != nil do return _raise_err(L, err, "write_sorted_map")
		_push_collection(L, kind, true, col.cursor, col.write_cursor)
	case .Sorted_Set:
		col, err := write_sorted_set_init(wc)
		if err != nil do return _raise_err(L, err, "write_sorted_set")
		_push_collection(L, kind, true, col.cursor, col.write_cursor)
	}
	return 1
}

@(private = "file")
_l_read_array_list         :: proc "c" (L: ^lua.State) -> c.int { context = _lua_context(L); return _open_read_collection(L, .Array_List) }
@(private = "file")
_l_write_array_list        :: proc "c" (L: ^lua.State) -> c.int { context = _lua_context(L); return _open_write_collection(L, .Array_List) }
@(private = "file")
_l_read_linked_array_list  :: proc "c" (L: ^lua.State) -> c.int { context = _lua_context(L); return _open_read_collection(L, .Linked_Array_List) }
@(private = "file")
_l_write_linked_array_list :: proc "c" (L: ^lua.State) -> c.int { context = _lua_context(L); return _open_write_collection(L, .Linked_Array_List) }
@(private = "file")
_l_read_hash_map           :: proc "c" (L: ^lua.State) -> c.int { context = _lua_context(L); return _open_read_collection(L, .Hash_Map) }
@(private = "file")
_l_write_hash_map          :: proc "c" (L: ^lua.State) -> c.int { context = _lua_context(L); return _open_write_collection(L, .Hash_Map) }
@(private = "file")
_l_read_counted_hash_map   :: proc "c" (L: ^lua.State) -> c.int { context = _lua_context(L); return _open_read_collection(L, .Counted_Hash_Map) }
@(private = "file")
_l_write_counted_hash_map  :: proc "c" (L: ^lua.State) -> c.int { context = _lua_context(L); return _open_write_collection(L, .Counted_Hash_Map) }
@(private = "file")
_l_read_hash_set           :: proc "c" (L: ^lua.State) -> c.int { context = _lua_context(L); return _open_read_collection(L, .Hash_Set) }
@(private = "file")
_l_write_hash_set          :: proc "c" (L: ^lua.State) -> c.int { context = _lua_context(L); return _open_write_collection(L, .Hash_Set) }
@(private = "file")
_l_read_counted_hash_set   :: proc "c" (L: ^lua.State) -> c.int { context = _lua_context(L); return _open_read_collection(L, .Counted_Hash_Set) }
@(private = "file")
_l_write_counted_hash_set  :: proc "c" (L: ^lua.State) -> c.int { context = _lua_context(L); return _open_write_collection(L, .Counted_Hash_Set) }
@(private = "file")
_l_read_sorted_map         :: proc "c" (L: ^lua.State) -> c.int { context = _lua_context(L); return _open_read_collection(L, .Sorted_Map) }
@(private = "file")
_l_write_sorted_map        :: proc "c" (L: ^lua.State) -> c.int { context = _lua_context(L); return _open_write_collection(L, .Sorted_Map) }
@(private = "file")
_l_read_sorted_set         :: proc "c" (L: ^lua.State) -> c.int { context = _lua_context(L); return _open_read_collection(L, .Sorted_Set) }
@(private = "file")
_l_write_sorted_set        :: proc "c" (L: ^lua.State) -> c.int { context = _lua_context(L); return _open_write_collection(L, .Sorted_Set) }

// ----------------------------------------------------------------------------
// Database Userdata Methods (`LUA_MT_DB`)
// ----------------------------------------------------------------------------

@(private = "file")
_l_db_close :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	ud := _test_ud(L, 1, Lua_Db_UD, .Database)
	if ud == nil || ud.h == nil {
		return 0
	}
	h := ud.h
	if !h.is_closed {
		if h.owns_core {
			_ = core_destroy(&h.core, true)
		}
		if len(h.temp_path) > 0 {
			_ = os.remove(h.temp_path)
			delete(h.temp_path, context.allocator)
			h.temp_path = ""
		}
		h.is_closed = true
	}
	return 0
}

@(private = "file")
_l_db_gc :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	ud := _test_ud(L, 1, Lua_Db_UD, .Database)
	if ud == nil || ud.h == nil {
		return 0
	}
	h := ud.h
	_l_db_close(L)
	free(h, context.allocator)
	ud.h = nil
	return 0
}

@(private = "file")
_l_db_reopen :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	db, h := _active_db(L, 1)
	if db == nil do return 0
	reopened, err := database_init(db.core, db.hasher)
	if err != nil {
		return _raise_err(L, err, "db:reopen")
	}
	if h.ext_db != nil {
		h.ext_db^ = reopened
	} else {
		h.db = reopened
	}
	lua.pushvalue(L, 1)
	return 1
}

@(private = "file")
_l_db_committed_size :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	db, _ := _active_db(L, 1)
	if db == nil do return 0
	sz, err := database_committed_size(db)
	if err != nil {
		return _raise_err(L, err, "db:committed_size")
	}
	lua.pushinteger(L, lua.Integer(sz))
	return 1
}

@(private = "file")
_l_db_freeze :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	db, _ := _active_db(L, 1)
	if db == nil do return 0
	err := database_freeze(db)
	if err != nil {
		return _raise_err(L, err, "db:freeze")
	}
	return 0
}

@(private = "file")
_l_db_root_cursor :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	db, _ := _active_db(L, 1)
	if db == nil do return 0
	wc := database_root_cursor(db)
	lua_push_write_cursor(L, wc)
	return 1
}

@(private = "file")
_l_db_digest :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	db, _ := _active_db(L, 1)
	if db == nil do return 0
	b := _lua_tobytes_odin(L, 2)
	var_buf: [64]u8
	digest := database_digest_buf(db, b, var_buf[:])
	_push_bytes(L, digest)
	return 1
}

@(private = "file")
_Lua_Cb_Ctx :: struct {
	L:       ^lua.State,
	fn_idx:  c.int,
	err_msg: string,
}

@(private = "file")
_lua_run_context_trampoline :: proc(cursor: ^Write_Cursor, user_data: rawptr) -> Error {
	cctx := (^_Lua_Cb_Ctx)(user_data)
	L := cctx.L
	lua.pushvalue(L, cctx.fn_idx)

	ext := _lua_ext(L)
	depth := ext.ctx_cursor_depth if ext != nil else LUA_CTX_CURSOR_POOL_SIZE
	if ext != nil && depth < LUA_CTX_CURSOR_POOL_SIZE {
		ext.ctx_cursor_depth = depth + 1
		if ext.ctx_cursors[depth] == nil {
			cud := (^Lua_Cursor_UD)(lua.newuserdatauv(L, size_of(Lua_Cursor_UD), 2))
			cud^ = Lua_Cursor_UD{
				hdr      = Lua_UD_Header{magic = LUA_UD_MAGIC, ud_kind = .Cursor},
				is_write = true,
				rc       = cursor.read_cursor,
				wc       = cursor^,
			}
			_set_ud_mt(L, .Cursor, LUA_MT_CURSOR)
			lua.pushvalue(L, -1)
			ext.ctx_cursor_refs[depth] = lua.L_ref(L, lua.REGISTRYINDEX)
			ext.ctx_cursors[depth] = cud
		} else {
			cud := ext.ctx_cursors[depth]
			cud.is_write = true
			cud.rc = cursor.read_cursor
			cud.wc = cursor^
			lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(ext.ctx_cursor_refs[depth]))
		}
	} else {
		lua_push_write_cursor(L, cursor^)
	}
	defer if ext != nil && depth < LUA_CTX_CURSOR_POOL_SIZE {
		ext.ctx_cursor_depth = depth
	}

	if lua.Status(lua.pcall(L, 1, 1, 0)) != .OK {
		msg := _lua_tostring_odin(L, -1)
		cctx.err_msg = strings.clone(msg, context.temp_allocator)
		lua.pop(L, 1)
		return .Key_Not_Found
	}
	// If callback explicitly returns `false`, abort the transaction cleanly (`Key_Not_Found`)
	if lua.type(L, -1) == .BOOLEAN && !bool(lua.toboolean(L, -1)) {
		lua.pop(L, 1)
		return .Key_Not_Found
	}
	lua.pop(L, 1)
	return nil
}

@(private = "file")
_l_db_run_context :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	db, _ := _active_db(L, 1)
	if db == nil do return 0
	if lua.type(L, 2) != .FUNCTION {
		return _raise_msg(L, "db:run_context expects a function at argument 2")
	}
	cctx := _Lua_Cb_Ctx{L = L, fn_idx = 2}
	err := database_run_context(db, _lua_run_context_trampoline, &cctx)
	if err != nil {
		if len(cctx.err_msg) > 0 {
			return _raise_msg(L, cctx.err_msg)
		}
		return _raise_err(L, err, "db:run_context")
	}
	return 0
}

// Replication & Compaction methods on `Database`

@(private = "file")
_l_db_replica_state :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	db, _ := _active_db(L, 1)
	if db == nil do return 0
	st, err := database_replica_state(db)
	if err != nil {
		return _raise_err(L, err, "db:replica_state")
	}
	lua.createtable(L, 0, 4)
	_set_int_field(L, "committed_size", st.committed_size)
	_set_int_field(L, "checksum", i64(st.checksum))
	_set_int_field(L, "checksum_lo", i64(u32(st.checksum)))
	_set_int_field(L, "checksum_hi", i64(u32(st.checksum >> 32)))
	return 1
}

@(private = "file")
_l_db_replication_start :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	db, _ := _active_db(L, 1)
	if db == nil do return 0

	st: Replica_State
	if lua.type(L, 2) == .USERDATA {
		rep_db, _ := _active_db(L, 2)
		if rep_db == nil do return 0
		r_err: Error
		st, r_err = database_replica_state(rep_db)
		if r_err != nil {
			return _raise_err(L, r_err, "db:replication_start")
		}
	} else if lua.type(L, 2) == .TABLE {
		lua.getfield(L, 2, "committed_size")
		st.committed_size = i64(lua.tointeger(L, -1))
		lua.pop(L, 1)
		lua.getfield(L, 2, "checksum_lo")
		if lua.type(L, -1) == .NUMBER {
			lo := u64(u32(lua.tointeger(L, -1)))
			lua.pop(L, 1)
			lua.getfield(L, 2, "checksum_hi")
			hi := u64(u32(lua.tointeger(L, -1)))
			lua.pop(L, 1)
			st.checksum = (hi << 32) | lo
		} else {
			lua.pop(L, 1)
			lua.getfield(L, 2, "checksum")
			st.checksum = u64(lua.tointeger(L, -1))
			lua.pop(L, 1)
		}
	} else {
		return _raise_msg(L, "db:replication_start expects replica state table or replica Database")
	}

	start_off, err := database_replication_start(db, st)
	if err != nil {
		return _raise_err(L, err, "db:replication_start")
	}
	lua.pushinteger(L, lua.Integer(start_off))
	return 1
}

@(private = "file")
_l_db_read_committed_bytes :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	db, _ := _active_db(L, 1)
	if db == nil do return 0
	start_off := i64(lua.L_checkinteger(L, 2))
	end_off := i64(lua.L_checkinteger(L, 3))
	payload, err := database_read_committed_bytes(db, start_off, end_off, context.temp_allocator)
	if err != nil {
		return _raise_err(L, err, "db:read_committed_bytes")
	}
	_push_bytes(L, payload)
	return 1
}

@(private = "file")
_l_db_apply_replicated_bytes :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	db, _ := _active_db(L, 1)
	if db == nil do return 0
	start_off := i64(lua.L_checkinteger(L, 2))
	payload := _lua_tobytes_odin(L, 3)
	err := database_apply_replicated_bytes(db, start_off, payload)
	if err != nil {
		return _raise_err(L, err, "db:apply_replicated_bytes")
	}
	return 0
}

@(private = "file")
_l_db_compact :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	src_db, _ := _active_db(L, 1)
	if src_db == nil do return 0

	// If argument 2 is an existing Database userdata, compact into its core; otherwise create a new memory DB
	var_target_h: ^Lua_Db_Handle
	pushed_new := false
	if lua.gettop(L) >= 2 && lua.type(L, 2) == .USERDATA {
		if db_ud := _test_ud(L, 2, Lua_Db_UD, .Database); db_ud != nil && db_ud.h != nil && !db_ud.h.is_closed {
			var_target_h = db_ud.h
		}
	}
	if var_target_h == nil {
		var_target_h = new(Lua_Db_Handle, context.allocator)
		var_target_h.core = core_memory_init(context.allocator)
		var_target_h.owns_core = true
		ud := (^Lua_Db_UD)(lua.newuserdatauv(L, size_of(Lua_Db_UD), 0))
		ud^ = Lua_Db_UD{
			hdr = Lua_UD_Header{magic = LUA_UD_MAGIC, ud_kind = .Database},
			h   = var_target_h,
		}
		_set_ud_mt(L, .Database, LUA_MT_DB)
		pushed_new = true
	}

	target_core := var_target_h.ext_db.core if var_target_h.ext_db != nil else &var_target_h.core

	// Optional Offset_Map at argument 2 or 3
	om_ud: ^Lua_Offset_Map_UD
	if lua.gettop(L) >= 2 && lua.type(L, 2) == .USERDATA {
		om_ud = _test_ud(L, 2, Lua_Offset_Map_UD, .Offset_Map)
	}
	if om_ud == nil && lua.gettop(L) >= 3 && lua.type(L, 3) == .USERDATA {
		om_ud = _test_ud(L, 3, Lua_Offset_Map_UD, .Offset_Map)
	}

	comp_db: Database
	err: Error
	if om_ud != nil {
		comp_db, err = database_compact(src_db, target_core, &om_ud.om)
	} else {
		temp_om: Offset_Map = memory_offset_map_init(context.temp_allocator)
		defer offset_map_destroy(&temp_om)
		comp_db, err = database_compact(src_db, target_core, &temp_om)
	}
	if err != nil {
		return _raise_err(L, err, "db:compact")
	}
	if var_target_h.ext_db != nil {
		var_target_h.ext_db^ = comp_db
	} else {
		var_target_h.db = comp_db
	}
	if !pushed_new {
		lua.pushvalue(L, 2)
	}
	return 1
}

// ----------------------------------------------------------------------------
// Layer 1–5 DSL Methods on `Database`
// ----------------------------------------------------------------------------

@(private = "file")
_l_db_select_cursor :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	db, _ := _active_db(L, 1)
	if db == nil do return 0
	sel := _lua_tostring_odin(L, 2)
	cur_maybe, err := select_cursor(db, sel)
	if err != nil {
		return _raise_err(L, err, "db:select_cursor")
	}
	cur, ok := cur_maybe.?
	if !ok {
		lua.pushnil(L)
		return 1
	}
	lua_push_read_cursor(L, cur)
	return 1
}

@(private = "file")
_l_db_get_string :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	db, _ := _active_db(L, 1)
	if db == nil do return 0
	sel := _lua_tostring_odin(L, 2)
	s, err := get_string(db, sel, context.temp_allocator)
	if err != nil {
		return _raise_err(L, err, "db:get_string")
	}
	_push_str(L, s)
	return 1
}

@(private = "file")
_l_db_get_uint :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	db, _ := _active_db(L, 1)
	if db == nil do return 0
	sel := _lua_tostring_odin(L, 2)
	v, err := get_uint(db, sel)
	if err != nil {
		return _raise_err(L, err, "db:get_uint")
	}
	lua.pushinteger(L, lua.Integer(v))
	return 1
}

@(private = "file")
_l_db_get_int :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	db, _ := _active_db(L, 1)
	if db == nil do return 0
	sel := _lua_tostring_odin(L, 2)
	v, err := get_int(db, sel)
	if err != nil {
		return _raise_err(L, err, "db:get_int")
	}
	lua.pushinteger(L, lua.Integer(v))
	return 1
}

@(private = "file")
_l_db_get_float :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	db, _ := _active_db(L, 1)
	if db == nil do return 0
	sel := _lua_tostring_odin(L, 2)
	v, err := get_float(db, sel)
	if err != nil {
		return _raise_err(L, err, "db:get_float")
	}
	lua.pushnumber(L, lua.Number(v))
	return 1
}

@(private = "file")
_l_db_get :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	db, _ := _active_db(L, 1)
	if db == nil do return 0
	sel := _lua_tostring_odin(L, 2)
	cur_maybe, err := select_cursor(db, sel)
	if err != nil {
		return _raise_err(L, err, "db:get")
	}
	cur, ok := cur_maybe.?
	if !ok {
		lua.pushnil(L)
		return 1
	}
	slot, s_err := cursor_slot(cur)
	if s_err != nil {
		return _raise_err(L, s_err, "db:get")
	}
	#partial switch slot.tag {
	case .None:
		lua.pushnil(L)
		return 1
	case .Uint:
		v, _ := cursor_read_uint(cur)
		lua.pushinteger(L, lua.Integer(v))
		return 1
	case .Int:
		v, _ := cursor_read_int(cur)
		lua.pushinteger(L, lua.Integer(v))
		return 1
	case .Float:
		v, _ := cursor_read_float(cur)
		lua.pushnumber(L, lua.Number(v))
		return 1
	case .Short_Bytes, .Bytes:
		var_buf: [128]u8
		if obj, b_err := cursor_read_bytes_buf(cur, var_buf[:]); b_err == nil {
			_push_bytes(L, obj.value)
			if len(obj.format_tag) > 0 {
				_push_bytes(L, obj.format_tag)
				return 2
			}
			return 1
		}
		obj, o_err := cursor_read_bytes_object(cur, 0, context.temp_allocator)
		if o_err != nil do return _raise_err(L, o_err, "db:get")
		_push_bytes(L, obj.value)
		if len(obj.format_tag) > 0 {
			_push_bytes(L, obj.format_tag)
			return 2
		}
		return 1
	}
	lua_push_read_cursor(L, cur)
	return 1
}

// Push a `Tx_Report` as a Lua table
@(private = "file")
_push_tx_report :: proc(L: ^lua.State, rep: Tx_Report) {
	lua.createtable(L, 0, 6)
	_set_int_field(L, "moment_index", rep.moment_index)
	_set_int_field(L, "commit_size", rep.commit_size)

	lua_push_read_cursor(L, rep.after.cursor)
	lua.setfield(L, -2, "after")

	if bm, ok := rep.before.?; ok {
		lua_push_read_cursor(L, bm.cursor)
		lua.setfield(L, -2, "before")
	}
	if tm, ok := rep.tx_meta.?; ok {
		lua_push_read_cursor(L, tm.cursor)
		lua.setfield(L, -2, "tx_meta")
	}

	lua.createtable(L, i32(len(rep.changes)), 0)
	for chg, idx in rep.changes {
		lua.createtable(L, 0, 4)
		_set_str_field(L, "op", _op_kind_to_string(chg.op))
		_set_str_field(L, "path_str", chg.path_str)
		_set_str_field(L, "path", chg.path_str)
		_set_int_field(L, "old_tag", i64(chg.old_slot.tag))
		_set_int_field(L, "new_tag", i64(chg.new_slot.tag))
		lua.rawseti(L, -2, lua.Integer(idx + 1))
	}
	lua.setfield(L, -2, "changes")
}

@(private = "file")
_l_db_tx_init :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	db, _ := _active_db(L, 1)
	if db == nil do return 0

	base_moment: Maybe(i64) = -1
	track_changes := false

	if lua.gettop(L) >= 2 {
		if lua.type(L, 2) == .NIL {
			base_moment = nil
		} else if lua.type(L, 2) == .STRING && (_lua_tostring_odin(L, 2) == "none" || _lua_tostring_odin(L, 2) == "genesis") {
			base_moment = nil
		} else if bool(lua.isinteger(L, 2)) {
			base_moment = i64(lua.tointeger(L, 2))
		} else if lua.type(L, 2) == .TABLE {
			lua.getfield(L, 2, "base_moment")
			if lua.type(L, -1) == .NIL {
				// check if explicitly false
			} else if lua.type(L, -1) == .BOOLEAN && !bool(lua.toboolean(L, -1)) {
				base_moment = nil
			} else if bool(lua.isinteger(L, -1)) {
				base_moment = i64(lua.tointeger(L, -1))
			}
			lua.pop(L, 1)
			lua.getfield(L, 2, "track_changes")
			if lua.type(L, -1) == .BOOLEAN {
				track_changes = bool(lua.toboolean(L, -1))
			}
			lua.pop(L, 1)
		}
	}
	if lua.gettop(L) >= 3 && lua.type(L, 3) == .BOOLEAN {
		track_changes = bool(lua.toboolean(L, 3))
	}

	ud := (^Lua_Tx_UD)(lua.newuserdatauv(L, size_of(Lua_Tx_UD), 0))
	ud^ = Lua_Tx_UD{
		hdr          = Lua_UD_Header{magic = LUA_UD_MAGIC, ud_kind = .Tx},
		tx           = tx_init(db, base_moment, track_changes, context.allocator),
		owned_chunks = make([dynamic][]u8, 0, 4, context.allocator),
	}
	_set_ud_mt(L, .Tx, LUA_MT_TX)
	return 1
}

@(private = "file")
_l_db_transact_script :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	db, _ := _active_db(L, 1)
	if db == nil do return 0
	script := _lua_tostring_odin(L, 2)
	rep, err := transact_script(db, script, context.temp_allocator)
	if err != nil {
		return _raise_err(L, err, "db:transact_script")
	}
	_push_tx_report(L, rep)
	return 1
}

@(private = "file")
_l_db_pull :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	db, _ := _active_db(L, 1)
	if db == nil do return 0

	rc: Read_Cursor
	pattern := "*"
	if c, ok := _extract_read_cursor(L, 2); ok {
		rc = c
		if lua.type(L, 3) == .STRING {
			pattern = _lua_tostring_odin(L, 3)
		}
	} else {
		sel := _lua_tostring_odin(L, 2)
		if lua.type(L, 3) == .STRING {
			pattern = _lua_tostring_odin(L, 3)
		}
		cur_maybe, s_err := select_cursor(db, sel)
		if s_err != nil do return _raise_err(L, s_err, "db:pull")
		c, has_c := cur_maybe.?
		if !has_c {
			lua.pushnil(L)
			return 1
		}
		rc = c
	}

	pv, err := pull(rc, pattern, context.temp_allocator)
	if err != nil {
		return _raise_err(L, err, "db:pull")
	}
	lua_push_pull_value(L, pv)
	return 1
}

@(private = "file")
_l_db_unmarshal :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	db, _ := _active_db(L, 1)
	if db == nil do return 0

	rc: Read_Cursor
	if c, ok := _extract_read_cursor(L, 2); ok {
		rc = c
	} else {
		sel := _lua_tostring_odin(L, 2)
		cur_maybe, s_err := select_cursor(db, sel)
		if s_err != nil do return _raise_err(L, s_err, "db:unmarshal")
		c, has_c := cur_maybe.?
		if !has_c {
			lua.pushnil(L)
			return 1
		}
		rc = c
	}

	err := lua_unmarshal_cursor(L, rc)
	if err != nil {
		return _raise_err(L, err, "db:unmarshal")
	}
	return 1
}

@(private = "file")
_l_db_marshal :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	wc, ok := _extract_write_cursor(L, 2)
	if !ok {
		return _raise_msg(L, "db:marshal expects a Write_Cursor at argument 2")
	}
	err := lua_marshal_value(L, 3, &wc)
	if err != nil {
		return _raise_err(L, err, "db:marshal")
	}
	return 0
}

@(private = "file")
_l_db_diff_moments :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	db, _ := _active_db(L, 1)
	if db == nil do return 0
	ma := i64(lua.L_checkinteger(L, 2))
	mb := i64(lua.L_checkinteger(L, 3))
	inc_meta := bool(lua.toboolean(L, 4))

	changes, err := diff_moments(db, ma, mb, inc_meta, context.temp_allocator)
	if err != nil {
		return _raise_err(L, err, "db:diff_moments")
	}

	lua.createtable(L, i32(len(changes)), 0)
	for chg, idx in changes {
		lua.createtable(L, 0, 4)
		_set_str_field(L, "op", _op_kind_to_string(chg.op))
		_set_str_field(L, "path_str", chg.path_str)
		_set_str_field(L, "path", chg.path_str)
		_set_int_field(L, "old_tag", i64(chg.old_slot.tag))
		_set_int_field(L, "new_tag", i64(chg.new_slot.tag))
		lua.rawseti(L, -2, lua.Integer(idx + 1))
	}
	return 1
}

@(private = "file")
_l_db_history_of :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	db, _ := _active_db(L, 1)
	if db == nil do return 0
	sel := _lua_tostring_odin(L, 2)
	entries, err := history_of(db, sel, context.temp_allocator)
	if err != nil {
		return _raise_err(L, err, "db:history_of")
	}

	lua.createtable(L, i32(len(entries)), 0)
	for e, idx in entries {
		lua.createtable(L, 0, 5)
		_set_int_field(L, "moment_index", e.moment_index)
		_set_str_field(L, "tx_doc", e.tx_doc)
		_set_int_field(L, "tx_instant", e.tx_instant)
		if c, has_c := e.cursor.?; has_c {
			lua_push_read_cursor(L, c)
			lua.setfield(L, -2, "cursor")
		}
		lua.rawseti(L, -2, lua.Integer(idx + 1))
	}
	return 1
}

@(private = "file")
_resolve_moment_hash_map :: proc(L: ^lua.State, db: ^Database, idx: c.int) -> (res: Read_Hash_Map, err: Error) {
	if rc, ok := _extract_read_cursor(L, idx); ok {
		return read_hash_map_init(rc)
	}
	m_idx := i64(-1)
	if bool(lua.isinteger(L, idx)) {
		m_idx = i64(lua.tointeger(L, idx))
	}
	rc := database_root_cursor(db).read_cursor
	history := read_array_list_init(rc) or_return
	mc_maybe := array_list_get_cursor(history, m_idx) or_return
	mc, has_mc := mc_maybe.?
	if !has_mc {
		return {}, .Key_Not_Found
	}
	return read_hash_map_init(mc)
}

@(private = "file")
_push_index_hits :: proc(L: ^lua.State, hits: []Index_Hit) {
	lua.createtable(L, i32(len(hits)), 0)
	for h, idx in hits {
		lua.createtable(L, 0, 2)
		_set_str_field(L, "key", h.key)
		lua_push_read_cursor(L, h.value_cursor)
		lua.setfield(L, -2, "value_cursor")
		lua.rawseti(L, -2, lua.Integer(idx + 1))
	}
}

@(private = "file")
_l_db_query_prefix :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	db, _ := _active_db(L, 1)
	if db == nil do return 0
	moment, m_err := _resolve_moment_hash_map(L, db, 2)
	if m_err != nil do return _raise_err(L, m_err, "db:query_prefix")
	index_key := _lua_tostring_odin(L, 3)
	prefix := _lua_tostring_odin(L, 4)

	hits, err := query_prefix(moment, index_key, prefix, context.temp_allocator)
	if err != nil do return _raise_err(L, err, "db:query_prefix")
	_push_index_hits(L, hits)
	return 1
}

@(private = "file")
_l_db_query_page :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	db, _ := _active_db(L, 1)
	if db == nil do return 0
	moment, m_err := _resolve_moment_hash_map(L, db, 2)
	if m_err != nil do return _raise_err(L, m_err, "db:query_page")
	index_key := _lua_tostring_odin(L, 3)
	offset := i64(lua.L_checkinteger(L, 4))
	limit := i64(lua.L_checkinteger(L, 5))

	hits, err := query_page(moment, index_key, offset, limit, context.temp_allocator)
	if err != nil do return _raise_err(L, err, "db:query_page")
	_push_index_hits(L, hits)
	return 1
}

@(private = "file")
_l_db_query_count_range :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	db, _ := _active_db(L, 1)
	if db == nil do return 0
	moment, m_err := _resolve_moment_hash_map(L, db, 2)
	if m_err != nil do return _raise_err(L, m_err, "db:query_count_range")
	index_key := _lua_tostring_odin(L, 3)
	lo := _lua_tostring_odin(L, 4)
	hi := _lua_tostring_odin(L, 5)

	cnt, err := query_count_range(moment, index_key, lo, hi)
	if err != nil do return _raise_err(L, err, "db:query_count_range")
	lua.pushinteger(L, lua.Integer(cnt))
	return 1
}

@(private = "file")
_l_db_query_datalog :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	db, _ := _active_db(L, 1)
	if db == nil do return 0
	q_str := _lua_tostring_odin(L, 2)
	def_moment := i64(lua.L_optinteger(L, 3, -1))

	res, err := query_datalog(db, q_str, def_moment, context.temp_allocator)
	if err != nil {
		return _raise_err(L, err, "db:query_datalog")
	}

	lua.createtable(L, 0, 2)
	lua.createtable(L, i32(len(res.vars)), 0)
	for v, i in res.vars {
		_push_str(L, v)
		lua.rawseti(L, -2, lua.Integer(i + 1))
	}
	lua.setfield(L, -2, "vars")

	lua.createtable(L, i32(len(res.rows)), 0)
	for row, r_idx in res.rows {
		lua.createtable(L, i32(len(row)), i32(len(row)))
		for cell, c_idx in row {
			// Populate both positional `row[1..k]` and named `row["?var"]` keys!
			lua_push_pull_value(L, cell)
			lua.rawseti(L, -2, lua.Integer(c_idx + 1))
			if c_idx < len(res.vars) {
				vname := res.vars[c_idx]
				_push_str(L, vname)
				lua_push_pull_value(L, cell)
				lua.rawset(L, -3)
			}
		}
		lua.rawseti(L, -2, lua.Integer(r_idx + 1))
	}
	lua.setfield(L, -2, "rows")
	return 1
}

// ----------------------------------------------------------------------------
// `Tx` Userdata Methods (`LUA_MT_TX`)
// ----------------------------------------------------------------------------

@(private = "file")
_check_tx :: #force_inline proc(L: ^lua.State, idx: c.int) -> ^Lua_Tx_UD {
	ud := _check_ud(L, idx, Lua_Tx_UD, .Tx, "invalid or destroyed xitdb.Tx")
	if ud == nil || ud.destroyed {
		_raise_msg(L, "invalid or destroyed xitdb.Tx")
	}
	return ud
}

@(private = "file")
_tx_cleanup :: proc(ud: ^Lua_Tx_UD) {
	if ud == nil || ud.destroyed {
		return
	}
	tx_destroy(&ud.tx)
	for chunk in ud.owned_chunks {
		delete(chunk, ud.tx.allocator)
	}
	delete(ud.owned_chunks)
	ud.cur_chunk = nil
	ud.cur_chunk_used = 0
	ud.destroyed = true
}

@(private = "file")
_l_tx_gc :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	ud := _test_ud(L, 1, Lua_Tx_UD, .Tx)
	_tx_cleanup(ud)
	return 0
}

@(private = "file")
_tx_own_str :: #force_inline proc(ud: ^Lua_Tx_UD, s: string) -> string {
	if len(s) == 0 {
		return ""
	}
	need := len(s)
	if len(ud.cur_chunk) - ud.cur_chunk_used < need {
		chunk_cap := max(4096, need)
		new_chunk := make([]u8, chunk_cap, ud.tx.allocator)
		append(&ud.owned_chunks, new_chunk)
		ud.cur_chunk = new_chunk
		ud.cur_chunk_used = 0
	}
	dst := ud.cur_chunk[ud.cur_chunk_used : ud.cur_chunk_used + need]
	copy(dst, s)
	ud.cur_chunk_used += need
	return string(dst)
}

@(private = "file")
_tx_own_writeable :: proc(L: ^lua.State, ud: ^Lua_Tx_UD, idx: c.int) -> (res: Writeable_Data, err: Error) {
	wdata := _lua_to_writeable_data(L, idx, true, false) or_return
	#partial switch v in wdata {
	case string:
		return _tx_own_str(ud, v), nil
	case Bytes:
		v_copy := _tx_own_str(ud, string(v.value))
		if len(v.format_tag) == 2 {
			t_copy := _tx_own_str(ud, string(v.format_tag))
			return new_tagged_string(v_copy, transmute([]u8)t_copy), nil
		}
		return new_bytes(transmute([]u8)v_copy), nil
	}
	return wdata, nil
}

@(private = "file")
_l_tx_doc :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	ud := _check_tx(L, 1)
	tx_doc(&ud.tx, _tx_own_str(ud, _lua_tostring_odin(L, 2)))
	lua.pushvalue(L, 1)
	return 1
}

@(private = "file")
_l_tx_instant :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	ud := _check_tx(L, 1)
	tx_instant(&ud.tx, i64(lua.L_checkinteger(L, 2)))
	lua.pushvalue(L, 1)
	return 1
}

@(private = "file")
_l_tx_meta :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	ud := _check_tx(L, 1)
	k := _tx_own_str(ud, _lua_tostring_odin(L, 2))
	v, err := _tx_own_writeable(L, ud, 3)
	if err != nil do return _raise_err(L, err, "tx:meta")
	tx_meta(&ud.tx, k, v)
	lua.pushvalue(L, 1)
	return 1
}

@(private = "file")
_l_tx_index_on :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	ud := _check_tx(L, 1)
	src := _tx_own_str(ud, _lua_tostring_odin(L, 2))
	fld := _tx_own_str(ud, _lua_tostring_odin(L, 3))
	idx := _tx_own_str(ud, _lua_tostring_odin(L, 4))
	tx_index_on(&ud.tx, src, fld, idx)
	lua.pushvalue(L, 1)
	return 1
}

@(private = "file")
_l_tx_put :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	ud := _check_tx(L, 1)
	path := _tx_own_str(ud, _lua_tostring_odin(L, 2))
	v, err := _tx_own_writeable(L, ud, 3)
	if err != nil do return _raise_err(L, err, "tx:put")
	p_err := tx_put(&ud.tx, path, v)
	if p_err != nil do return _raise_err(L, p_err, "tx:put")
	lua.pushvalue(L, 1)
	return 1
}

@(private = "file")
_l_tx_append :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	ud := _check_tx(L, 1)
	path := _tx_own_str(ud, _lua_tostring_odin(L, 2))
	v, err := _tx_own_writeable(L, ud, 3)
	if err != nil do return _raise_err(L, err, "tx:append")
	a_err := tx_append(&ud.tx, path, v)
	if a_err != nil do return _raise_err(L, a_err, "tx:append")
	lua.pushvalue(L, 1)
	return 1
}

@(private = "file")
_l_tx_insert :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	ud := _check_tx(L, 1)
	path := _tx_own_str(ud, _lua_tostring_odin(L, 2))
	index := i64(lua.L_checkinteger(L, 3))
	v, err := _tx_own_writeable(L, ud, 4)
	if err != nil do return _raise_err(L, err, "tx:insert")
	i_err := tx_insert(&ud.tx, path, index, v)
	if i_err != nil do return _raise_err(L, i_err, "tx:insert")
	lua.pushvalue(L, 1)
	return 1
}

@(private = "file")
_l_tx_rm :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	ud := _check_tx(L, 1)
	path := _tx_own_str(ud, _lua_tostring_odin(L, 2))
	err := tx_rm(&ud.tx, path)
	if err != nil do return _raise_err(L, err, "tx:rm")
	lua.pushvalue(L, 1)
	return 1
}

@(private = "file")
_l_tx_slice :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	ud := _check_tx(L, 1)
	path := _tx_own_str(ud, _lua_tostring_odin(L, 2))
	sz := i64(lua.L_checkinteger(L, 3))
	off := i64(lua.L_optinteger(L, 4, 0))
	err := tx_slice(&ud.tx, path, sz, off)
	if err != nil do return _raise_err(L, err, "tx:slice")
	lua.pushvalue(L, 1)
	return 1
}

@(private = "file")
_l_tx_fork :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	ud := _check_tx(L, 1)
	src := _tx_own_str(ud, _lua_tostring_odin(L, 2))
	dst := _tx_own_str(ud, _lua_tostring_odin(L, 3))
	err := tx_fork(&ud.tx, src, dst)
	if err != nil do return _raise_err(L, err, "tx:fork")
	lua.pushvalue(L, 1)
	return 1
}

@(private = "file")
_l_tx_savepoint :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	ud := _check_tx(L, 1)
	tx_savepoint(&ud.tx)
	lua.pushvalue(L, 1)
	return 1
}

@(private = "file")
_Tx_Lua_Callback :: struct {
	L:       ^lua.State,
	fn_ref:  c.int,
	err_msg: string,
}

@(private = "file")
_tx_lua_cb_trampoline :: proc(cursor: ^Write_Cursor, user_data: rawptr) -> Error {
	cb := (^_Tx_Lua_Callback)(user_data)
	L := cb.L
	lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(cb.fn_ref))
	lua_push_write_cursor(L, cursor^)
	if lua.Status(lua.pcall(L, 1, 0, 0)) != .OK {
		cb.err_msg = strings.clone(_lua_tostring_odin(L, -1), context.temp_allocator)
		lua.pop(L, 1)
		return .Key_Not_Found
	}
	return nil
}

@(private = "file")
_l_tx_with_cursor :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	ud := _check_tx(L, 1)
	if lua.type(L, 2) != .FUNCTION {
		return _raise_msg(L, "tx:with_cursor expects a function")
	}
	lua.pushvalue(L, 2)
	ref := lua.L_ref(L, lua.REGISTRYINDEX)
	cb_holder := new(_Tx_Lua_Callback, context.temp_allocator)
	cb_holder^ = _Tx_Lua_Callback{L = L, fn_ref = ref}
	tx_with_cursor(&ud.tx, _tx_lua_cb_trampoline, cb_holder)
	lua.pushvalue(L, 1)
	return 1
}

@(private = "file")
_l_tx_commit :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	ud := _check_tx(L, 1)
	if ud.committed {
		return _raise_msg(L, "tx:commit called on already-committed Tx")
	}
	// Release any Lua function references registered via `with_cursor` after commit
	defer {
		for op in ud.tx.ops {
			if op.kind == .Callback && op.user_data != nil {
				cb := (^_Tx_Lua_Callback)(op.user_data)
				lua.L_unref(L, lua.REGISTRYINDEX, cb.fn_ref)
			}
		}
		_tx_cleanup(ud)
	}

	rep, err := tx_commit(&ud.tx)
	defer tx_report_destroy(&rep, ud.tx.allocator)
	if err != nil {
		for op in ud.tx.ops {
			if op.kind == .Callback && op.user_data != nil {
				cb := (^_Tx_Lua_Callback)(op.user_data)
				if len(cb.err_msg) > 0 {
					return _raise_msg(L, cb.err_msg)
				}
			}
		}
		return _raise_err(L, err, "tx:commit")
	}
	ud.committed = true
	_push_tx_report(L, rep)
	return 1
}

// ----------------------------------------------------------------------------
// `Cursor` Userdata Methods (`LUA_MT_CURSOR`)
// ----------------------------------------------------------------------------

@(private = "file")
_l_cursor_slot :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	cud := _check_cursor(L, 1)
	s, err := cursor_slot(cud.rc)
	if err != nil do return _raise_err(L, err, "cursor:slot")
	lua_push_slot(L, s)
	return 1
}

@(private = "file")
_l_cursor_tag :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	cud := _check_cursor(L, 1)
	s, err := cursor_slot(cud.rc)
	if err != nil do return _raise_err(L, err, "cursor:tag")
	name := _tag_name(s.tag)
	_push_str(L, name)
	lua.pushinteger(L, lua.Integer(s.tag))
	return 2
}

@(private = "file")
_l_cursor_count :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	cud := _check_cursor(L, 1)
	cnt, err := cursor_count(cud.rc)
	if err != nil do return _raise_err(L, err, "cursor:count")
	lua.pushinteger(L, lua.Integer(cnt))
	return 1
}

@(private = "file")
_l_cursor_read_uint :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	cud := _check_cursor(L, 1)
	v, err := cursor_read_uint(cud.rc)
	if err != nil do return _raise_err(L, err, "cursor:read_uint")
	lua.pushinteger(L, lua.Integer(v))
	return 1
}

@(private = "file")
_l_cursor_read_int :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	cud := _check_cursor(L, 1)
	v, err := cursor_read_int(cud.rc)
	if err != nil do return _raise_err(L, err, "cursor:read_int")
	lua.pushinteger(L, lua.Integer(v))
	return 1
}

@(private = "file")
_l_cursor_read_float :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	cud := _check_cursor(L, 1)
	v, err := cursor_read_float(cud.rc)
	if err != nil do return _raise_err(L, err, "cursor:read_float")
	lua.pushnumber(L, lua.Number(v))
	return 1
}

@(private = "file")
_l_cursor_read_string :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	cud := _check_cursor(L, 1)
	var_buf: [128]u8
	if obj, b_err := cursor_read_bytes_buf(cud.rc, var_buf[:]); b_err == nil {
		_push_bytes(L, obj.value)
		return 1
	}
	s, err := cursor_read_string(cud.rc, 0, context.temp_allocator)
	if err != nil do return _raise_err(L, err, "cursor:read_string")
	_push_str(L, s)
	return 1
}

@(private = "file")
_l_cursor_read_bytes :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	cud := _check_cursor(L, 1)
	var_buf: [128]u8
	if obj, b_err := cursor_read_bytes_buf(cud.rc, var_buf[:]); b_err == nil {
		_push_bytes(L, obj.value)
		if len(obj.format_tag) > 0 {
			_push_bytes(L, obj.format_tag)
			return 2
		}
		return 1
	}
	obj, err := cursor_read_bytes_object(cud.rc, 0, context.temp_allocator)
	if err != nil do return _raise_err(L, err, "cursor:read_bytes")
	_push_bytes(L, obj.value)
	if len(obj.format_tag) > 0 {
		_push_bytes(L, obj.format_tag)
		return 2
	}
	return 1
}

@(private = "file")
_push_cursor_kv_pair :: proc(L: ^lua.State, cud_idx: c.int, cud: ^Lua_Cursor_UD, kc: Read_Cursor, vc: Read_Cursor) {
	k_ud := cud.kv_key_ud
	if k_ud != nil {
		k_ud.rc       = kc
		k_ud.is_write = false
		lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(cud.kv_key_ref))
	} else {
		k_ud = (^Lua_Cursor_UD)(lua.newuserdata(L, size_of(Lua_Cursor_UD)))
		k_ud^ = Lua_Cursor_UD{
			hdr      = {magic = LUA_UD_MAGIC, ud_kind = .Cursor},
			rc       = kc,
			is_write = false,
		}
		_set_ud_mt(L, .Cursor, LUA_MT_CURSOR)
		lua.pushvalue(L, -1)
		cud.kv_key_ref = lua.L_ref(L, lua.REGISTRYINDEX)
		cud.kv_key_ud = k_ud
	}

	v_ud := cud.kv_val_ud
	if v_ud != nil {
		v_ud.rc       = vc
		v_ud.is_write = false
		lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(cud.kv_val_ref))
	} else {
		v_ud = (^Lua_Cursor_UD)(lua.newuserdata(L, size_of(Lua_Cursor_UD)))
		v_ud^ = Lua_Cursor_UD{
			hdr      = {magic = LUA_UD_MAGIC, ud_kind = .Cursor},
			rc       = vc,
			is_write = false,
		}
		_set_ud_mt(L, .Cursor, LUA_MT_CURSOR)
		lua.pushvalue(L, -1)
		cud.kv_val_ref = lua.L_ref(L, lua.REGISTRYINDEX)
		cud.kv_val_ud = v_ud
	}
}

@(private = "file")
_l_cursor_read_kv_pair :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	cud := _check_cursor(L, 1)
	if lua.gettop(L) >= 2 && bool(lua.toboolean(L, 2)) {
		kv, err := cursor_read_kv_pair(cud.rc, context.temp_allocator)
		if err != nil do return _raise_err(L, err, "cursor:read_kv_pair")
		_push_cursor_kv_pair(L, 1, cud, kv.key_cursor, kv.value_cursor)
		_push_bytes(L, kv.hash)
		return 3
	}
	kc, vc, err := cursor_read_kv_pair_slots(cud.rc)
	if err != nil do return _raise_err(L, err, "cursor:read_kv_pair")
	_push_cursor_kv_pair(L, 1, cud, kc, vc)
	return 2
}

@(private = "file")
_l_cursor_write :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	cud := _check_cursor(L, 1)
	if !cud.is_write {
		return _raise_err(L, .Write_Not_Allowed, "cursor:write")
	}
	wdata, err := _lua_to_writeable_data(L, 2, true)
	if err != nil do return _raise_err(L, err, "cursor:write")
	w_err := cursor_write(&cud.wc, wdata)
	if w_err != nil do return _raise_err(L, w_err, "cursor:write")
	cud.rc = cud.wc.read_cursor
	return 0
}

@(private = "file")
_l_cursor_write_if_empty :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	cud := _check_cursor(L, 1)
	if !cud.is_write {
		return _raise_err(L, .Write_Not_Allowed, "cursor:write_if_empty")
	}
	wdata, err := _lua_to_writeable_data(L, 2, true)
	if err != nil do return _raise_err(L, err, "cursor:write_if_empty")
	w_err := cursor_write_if_empty(&cud.wc, wdata)
	if w_err != nil do return _raise_err(L, w_err, "cursor:write_if_empty")
	cud.rc = cud.wc.read_cursor
	return 0
}

@(private = "file")
_l_cursor_freeze :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	cud := _check_cursor(L, 1)
	if !cud.is_write {
		return _raise_err(L, .Write_Not_Allowed, "cursor:freeze")
	}
	err := cursor_freeze(&cud.wc)
	if err != nil do return _raise_err(L, err, "cursor:freeze")
	cud.rc = cud.wc.read_cursor
	return 0
}

@(private = "file")
_l_cursor_read_only :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	cud := _check_cursor(L, 1)
	lua_push_read_cursor(L, cud.rc)
	return 1
}

@(private = "file")
_l_cursor_iterator :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	cud := _check_cursor(L, 1)
	it, err := cursor_iterator(cud.rc)
	if err != nil do return _raise_err(L, err, "cursor:iterator")
	ud := (^Lua_Iterator_UD)(lua.newuserdatauv(L, size_of(Lua_Iterator_UD), 1))
	ud^ = Lua_Iterator_UD{
		hdr = {magic = LUA_UD_MAGIC, ud_kind = .Iterator},
		it  = it,
	}
	_set_ud_mt(L, .Iterator, LUA_MT_ITERATOR)
	return 1
}

@(private = "file")
_l_cursor_reader :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	cud := _check_cursor(L, 1)
	r, err := cursor_reader(cud.rc)
	if err != nil do return _raise_err(L, err, "cursor:reader")
	ud := (^Lua_Reader_UD)(lua.newuserdatauv(L, size_of(Lua_Reader_UD), 0))
	ud^ = Lua_Reader_UD{
		hdr    = {magic = LUA_UD_MAGIC, ud_kind = .Reader},
		reader = r,
	}
	_set_ud_mt(L, .Reader, LUA_MT_READER)
	return 1
}

@(private = "file")
_l_cursor_writer :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	cud := _check_cursor(L, 1)
	if !cud.is_write {
		return _raise_err(L, .Write_Not_Allowed, "cursor:writer")
	}
	w, err := cursor_writer(&cud.wc)
	if err != nil do return _raise_err(L, err, "cursor:writer")
	ud := (^Lua_Writer_UD)(lua.newuserdatauv(L, size_of(Lua_Writer_UD), 0))
	ud^ = Lua_Writer_UD{
		hdr        = {magic = LUA_UD_MAGIC, ud_kind = .Writer},
		writer     = w,
		parent_cud = cud,
		finished   = false,
	}
	_set_ud_mt(L, .Writer, LUA_MT_WRITER)
	return 1
}

@(private = "file")
_l_cursor_pull :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	cud := _check_cursor(L, 1)
	pattern := "*"
	if lua.type(L, 2) == .STRING {
		pattern = _lua_tostring_odin(L, 2)
	}
	pv, err := pull(cud.rc, pattern, context.temp_allocator)
	if err != nil do return _raise_err(L, err, "cursor:pull")
	lua_push_pull_value(L, pv)
	return 1
}

@(private = "file")
_l_cursor_unmarshal :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	cud := _check_cursor(L, 1)
	err := lua_unmarshal_cursor(L, cud.rc)
	if err != nil do return _raise_err(L, err, "cursor:unmarshal")
	return 1
}

@(private = "file")
_l_cursor_marshal :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	cud := _check_cursor(L, 1)
	if !cud.is_write {
		return _raise_err(L, .Write_Not_Allowed, "cursor:marshal")
	}
	err := lua_marshal_value(L, 2, &cud.wc)
	if err != nil do return _raise_err(L, err, "cursor:marshal")
	cud.rc = cud.wc.read_cursor
	return 0
}

// Parse a Lua table of path-part descriptors into `[]Path_Part` for `cursor:read_path` / `cursor:write_path`
@(private = "file")
_lua_parse_path_parts :: proc(L: ^lua.State, idx: c.int) -> (res: []Path_Part, err: Error) {
	if lua.type(L, idx) == .STRING {
		// Allow selector string syntax too!
		sel := _lua_tostring_odin(L, idx)
		steps := parse_steps(sel, context.temp_allocator) or_return
		parts := make([dynamic]Path_Part, 0, len(steps), context.temp_allocator)
		for s in steps {
			switch s.kind {
			case .Hash_Map_Key:
				append(&parts, Hash_Map_Init{counted = false, set = false})
			case .Counted_Hash_Map_Key:
				append(&parts, Hash_Map_Init{counted = true, set = false})
			case .Sorted_Map_Key:
				append(&parts, Sorted_Map_Init{set = false})
				append(&parts, Sorted_Map_Get{target = Sorted_Map_Get_Value{key = transmute([]u8)s.key}})
			case .Array_List_Idx:
				append(&parts, Array_List_Init{})
				append(&parts, Array_List_Get{index = s.index})
			case .Linked_List_Idx:
				append(&parts, Linked_Array_List_Init{})
				append(&parts, Linked_Array_List_Get{index = s.index})
			case .Hash_Set_Member, .Counted_Set_Member, .Sorted_Set_Member:
			}
		}
		return parts[:], nil
	}

	if lua.type(L, idx) != .TABLE {
		return nil, .Invalid_Range
	}
	n := int(lua.rawlen(L, idx))
	parts := make([]Path_Part, n, context.temp_allocator)
	for i in 1 ..= n {
		lua.rawgeti(L, idx, lua.Integer(i))
		lua.getfield(L, -1, "op")
		op := _lua_tostring_odin(L, -1)
		lua.pop(L, 1)

		switch op {
		case "hash_map_init":
			lua.getfield(L, -1, "counted")
			cnt := bool(lua.toboolean(L, -1))
			lua.pop(L, 1)
			lua.getfield(L, -1, "set")
			st := bool(lua.toboolean(L, -1))
			lua.pop(L, 1)
			parts[i - 1] = Hash_Map_Init{counted = cnt, set = st}

		case "hash_map_get", "hash_map_get_value":
			lua.getfield(L, -1, "hash")
			h := _lua_tobytes_odin(L, -1)
			lua.pop(L, 1)
			parts[i - 1] = Hash_Map_Get{target = Hash_Map_Get_Value{hash = h}}

		case "hash_map_get_key":
			lua.getfield(L, -1, "hash")
			h := _lua_tobytes_odin(L, -1)
			lua.pop(L, 1)
			parts[i - 1] = Hash_Map_Get{target = Hash_Map_Get_Key{hash = h}}

		case "array_list_init":
			parts[i - 1] = Array_List_Init{}

		case "array_list_get":
			lua.getfield(L, -1, "index")
			index := i64(lua.tointeger(L, -1))
			lua.pop(L, 1)
			parts[i - 1] = Array_List_Get{index = index}

		case "array_list_append":
			parts[i - 1] = Array_List_Append{}

		case "linked_array_list_init":
			parts[i - 1] = Linked_Array_List_Init{}

		case "linked_array_list_get":
			lua.getfield(L, -1, "index")
			index := i64(lua.tointeger(L, -1))
			lua.pop(L, 1)
			parts[i - 1] = Linked_Array_List_Get{index = index}

		case "linked_array_list_append":
			parts[i - 1] = Linked_Array_List_Append{}

		case "sorted_map_init":
			lua.getfield(L, -1, "set")
			st := bool(lua.toboolean(L, -1))
			lua.pop(L, 1)
			parts[i - 1] = Sorted_Map_Init{set = st}

		case "sorted_map_get", "sorted_map_get_value":
			lua.getfield(L, -1, "key")
			k := _lua_tobytes_odin(L, -1)
			lua.pop(L, 1)
			parts[i - 1] = Sorted_Map_Get{target = Sorted_Map_Get_Value{key = k}}

		case "sorted_map_get_key":
			lua.getfield(L, -1, "key")
			k := _lua_tobytes_odin(L, -1)
			lua.pop(L, 1)
			parts[i - 1] = Sorted_Map_Get{target = Sorted_Map_Get_Key{key = k}}

		case "write":
			lua.getfield(L, -1, "data")
			wdata := _lua_to_writeable_data(L, -1, true) or_return
			lua.pop(L, 1)
			parts[i - 1] = Write_Data{data = wdata}

		case:
			lua.pop(L, 1)
			return nil, .Invalid_Range
		}
		lua.pop(L, 1)
	}
	return parts, nil
}

@(private = "file")
_l_cursor_read_path :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	cud := _check_cursor(L, 1)
	if lua.type(L, 2) == .STRING {
		steps, s_err := parse_steps(_lua_tostring_odin(L, 2), context.temp_allocator)
		if s_err != nil do return _raise_err(L, s_err, "cursor:read_path")
		c_maybe, r_err := read_steps_cursor(cud.rc, steps)
		if r_err != nil do return _raise_err(L, r_err, "cursor:read_path")
		if c, ok := c_maybe.?; ok {
			lua_push_read_cursor(L, c)
		} else {
			lua.pushnil(L)
		}
		return 1
	}
	parts, p_err := _lua_parse_path_parts(L, 2)
	if p_err != nil do return _raise_err(L, p_err, "cursor:read_path")
	c_maybe, err := cursor_read_path(cud.rc, parts)
	if err != nil do return _raise_err(L, err, "cursor:read_path")
	if c, ok := c_maybe.?; ok {
		lua_push_read_cursor(L, c)
	} else {
		lua.pushnil(L)
	}
	return 1
}

@(private = "file")
_l_cursor_write_path :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	cud := _check_cursor(L, 1)
	if !cud.is_write {
		return _raise_err(L, .Write_Not_Allowed, "cursor:write_path")
	}
	if lua.type(L, 2) == .STRING {
		steps, s_err := parse_steps(_lua_tostring_odin(L, 2), context.temp_allocator)
		if s_err != nil do return _raise_err(L, s_err, "cursor:write_path")
		wc, w_err := write_steps_cursor(cud.wc, steps)
		if w_err != nil do return _raise_err(L, w_err, "cursor:write_path")
		cud.rc = cud.wc.read_cursor
		lua_push_write_cursor(L, wc)
		return 1
	}
	parts, p_err := _lua_parse_path_parts(L, 2)
	if p_err != nil do return _raise_err(L, p_err, "cursor:write_path")
	wc, err := cursor_write_path(&cud.wc, parts)
	if err != nil do return _raise_err(L, err, "cursor:write_path")
	cud.rc = cud.wc.read_cursor
	lua_push_write_cursor(L, wc)
	return 1
}

// ----------------------------------------------------------------------------
// `Collection` Userdata Methods (`LUA_MT_COLLECTION`)
// ----------------------------------------------------------------------------

@(private = "file")
_check_collection :: #force_inline proc(L: ^lua.State, idx: c.int) -> ^Lua_Collection_UD {
	return _check_ud(L, idx, Lua_Collection_UD, .Collection, "expected xitdb.Collection")
}

// Ring-buffer helper for collection methods returning cursors
@(private = "file")
_col_push_read_cursor :: proc(L: ^lua.State, col_idx: c.int, col: ^Lua_Collection_UD, rc: Read_Cursor) {
	slot_idx := col.cur_ring_idx & 7
	col.cur_ring_idx = (slot_idx + 1) & 7
	cud := col.cur_ring[slot_idx]
	if cud != nil {
		cud.rc       = rc
		cud.is_write = false
		lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(col.cur_refs[slot_idx]))
	} else {
		cud = (^Lua_Cursor_UD)(lua.newuserdata(L, size_of(Lua_Cursor_UD)))
		cud^ = Lua_Cursor_UD{
			hdr      = {magic = LUA_UD_MAGIC, ud_kind = .Cursor},
			rc       = rc,
			is_write = false,
		}
		_set_ud_mt(L, .Cursor, LUA_MT_CURSOR)
		lua.pushvalue(L, -1)
		col.cur_refs[slot_idx] = lua.L_ref(L, lua.REGISTRYINDEX)
		col.cur_ring[slot_idx] = cud
	}
}

@(private = "file")
_col_push_write_cursor :: proc(L: ^lua.State, col_idx: c.int, col: ^Lua_Collection_UD, wc: Write_Cursor) {
	slot_idx := col.cur_ring_idx & 7
	col.cur_ring_idx = (slot_idx + 1) & 7
	cud := col.cur_ring[slot_idx]
	if cud != nil {
		cud.rc       = wc.read_cursor
		cud.wc       = wc
		cud.is_write = true
		lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(col.cur_refs[slot_idx]))
	} else {
		cud = (^Lua_Cursor_UD)(lua.newuserdata(L, size_of(Lua_Cursor_UD)))
		cud^ = Lua_Cursor_UD{
			hdr      = {magic = LUA_UD_MAGIC, ud_kind = .Cursor},
			rc       = wc.read_cursor,
			wc       = wc,
			is_write = true,
		}
		_set_ud_mt(L, .Cursor, LUA_MT_CURSOR)
		lua.pushvalue(L, -1)
		col.cur_refs[slot_idx] = lua.L_ref(L, lua.REGISTRYINDEX)
		col.cur_ring[slot_idx] = cud
	}
}

@(private = "file")
_col_push_slot :: proc(L: ^lua.State, col_idx: c.int, col: ^Lua_Collection_UD, s: Slot) {
	sud := col.slot_ud
	if sud != nil {
		sud.slot = s
		lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(col.slot_ref))
	} else {
		sud = (^Lua_Slot_UD)(lua.newuserdata(L, size_of(Lua_Slot_UD)))
		sud^ = Lua_Slot_UD{
			hdr  = {magic = LUA_UD_MAGIC, ud_kind = .Slot},
			slot = s,
		}
		_set_ud_mt(L, .Slot, LUA_MT_SLOT)
		lua.pushvalue(L, -1)
		col.slot_ref = lua.L_ref(L, lua.REGISTRYINDEX)
		col.slot_ud = sud
	}
}

@(private = "file")
_l_col_cursor :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	col := _check_collection(L, 1)
	if col.is_write {
		_col_push_write_cursor(L, 1, col, col.wc)
	} else {
		_col_push_read_cursor(L, 1, col, col.rc)
	}
	return 1
}

@(private = "file")
_l_col_slot :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	col := _check_collection(L, 1)
	s, err := cursor_slot(col.rc)
	if err != nil do return _raise_err(L, err, "collection:slot")
	_col_push_slot(L, 1, col, s)
	return 1
}

@(private = "file")
_l_col_freeze :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	col := _check_collection(L, 1)
	if !col.is_write {
		return _raise_err(L, .Write_Not_Allowed, "collection:freeze")
	}
	err := cursor_freeze(&col.wc)
	if err != nil do return _raise_err(L, err, "collection:freeze")
	col.rc = col.wc.read_cursor
	return 0
}

@(private = "file")
_l_col_count :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	col := _check_collection(L, 1)
	cnt, err := cursor_count(col.rc)
	if err != nil do return _raise_err(L, err, "collection:count")
	lua.pushinteger(L, lua.Integer(cnt))
	return 1
}

@(private = "file")
_l_col_get_cursor :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	col := _check_collection(L, 1)
	c_maybe: Maybe(Read_Cursor)
	err: Error

	switch col.kind {
	case .Array_List:
		idx := i64(lua.tointeger(L, 2))
		c_maybe, err = array_list_get_cursor(Read_Array_List{cursor = col.rc}, idx)
	case .Linked_Array_List:
		idx := i64(lua.tointeger(L, 2))
		c_maybe, err = linked_array_list_get_cursor(Read_Linked_Array_List{cursor = col.rc}, idx)
	case .Hash_Map, .Counted_Hash_Map:
		k := _lua_tobytes_odin(L, 2)
		c_maybe, err = hash_map_get_cursor_by_bytes(Read_Hash_Map{cursor = col.rc}, k)
	case .Hash_Set, .Counted_Hash_Set:
		k := _lua_tobytes_odin(L, 2)
		c_maybe, err = hash_set_get_cursor_by_bytes(Read_Hash_Set{cursor = col.rc}, new_bytes(k))
	case .Sorted_Map:
		k := _lua_tobytes_odin(L, 2)
		c_maybe, err = sorted_map_get_cursor_by_bytes(Read_Sorted_Map{cursor = col.rc}, k)
	case .Sorted_Set:
		k := _lua_tobytes_odin(L, 2)
		c_maybe, err = cursor_read_path(col.rc, []Path_Part{
			Sorted_Map_Get{target = Sorted_Map_Get_Key{key = k}},
		})
	}
	if err != nil do return _raise_err(L, err, "collection:get_cursor")
	if c, ok := c_maybe.?; ok {
		_col_push_read_cursor(L, 1, col, c)
	} else {
		lua.pushnil(L)
	}
	return 1
}

@(private = "file")
_l_col_get_slot :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	col := _check_collection(L, 1)
	s_maybe: Maybe(Slot)
	err: Error

	switch col.kind {
	case .Array_List:
		idx := i64(lua.tointeger(L, 2))
		s_maybe, err = array_list_get_slot(Read_Array_List{cursor = col.rc}, idx)
	case .Linked_Array_List:
		idx := i64(lua.tointeger(L, 2))
		s_maybe, err = linked_array_list_get_slot(Read_Linked_Array_List{cursor = col.rc}, idx)
	case .Hash_Map, .Counted_Hash_Map:
		k := _lua_tobytes_odin(L, 2)
		s_maybe, err = hash_map_get_slot_by_bytes(Read_Hash_Map{cursor = col.rc}, k)
	case .Hash_Set, .Counted_Hash_Set:
		k := _lua_tobytes_odin(L, 2)
		s_maybe, err = hash_set_get_slot_by_bytes(Read_Hash_Set{cursor = col.rc}, new_bytes(k))
	case .Sorted_Map, .Sorted_Set:
		k := _lua_tobytes_odin(L, 2)
		s_maybe, err = sorted_map_get_slot_by_bytes(Read_Sorted_Map{cursor = col.rc}, k)
	}
	if err != nil do return _raise_err(L, err, "collection:get_slot")
	if s, ok := s_maybe.?; ok {
		_col_push_slot(L, 1, col, s)
	} else {
		lua.pushnil(L)
	}
	return 1
}

@(private = "file")
_l_col_get_key_cursor :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	col := _check_collection(L, 1)
	k := _lua_tobytes_odin(L, 2)
	c_maybe: Maybe(Read_Cursor)
	err: Error

	#partial switch col.kind {
	case .Hash_Map, .Counted_Hash_Map, .Hash_Set, .Counted_Hash_Set:
		c_maybe, err = hash_map_get_key_cursor_by_bytes(Read_Hash_Map{cursor = col.rc}, k)
	case .Sorted_Map, .Sorted_Set:
		c_maybe, err = cursor_read_path(col.rc, []Path_Part{Sorted_Map_Get{target = Sorted_Map_Get_Key{key = k}}})
	case:
		return _raise_err(L, .Unexpected_Tag, "collection:get_key_cursor")
	}
	if err != nil do return _raise_err(L, err, "collection:get_key_cursor")
	if c, ok := c_maybe.?; ok {
		_col_push_read_cursor(L, 1, col, c)
	} else {
		lua.pushnil(L)
	}
	return 1
}

@(private = "file")
_l_col_get_kv_pair :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	col := _check_collection(L, 1)
	k := _lua_tobytes_odin(L, 2)
	c_maybe: Maybe(Read_Cursor)
	err: Error

	#partial switch col.kind {
	case .Hash_Map, .Counted_Hash_Map, .Hash_Set, .Counted_Hash_Set:
		var_buf: [64]u8
		h := database_digest_buf(col.rc.db, k, var_buf[:])
		c_maybe, err = cursor_read_path(col.rc, []Path_Part{Hash_Map_Get{target = Hash_Map_Get_KV_Pair{hash = h}}})
	case .Sorted_Map, .Sorted_Set:
		c_maybe, err = cursor_read_path(col.rc, []Path_Part{Sorted_Map_Get{target = Sorted_Map_Get_KV_Pair{key = k}}})
	case:
		return _raise_err(L, .Unexpected_Tag, "collection:get_kv_pair")
	}
	if err != nil do return _raise_err(L, err, "collection:get_kv_pair")
	if c, ok := c_maybe.?; ok {
		_col_push_read_cursor(L, 1, col, c)
	} else {
		lua.pushnil(L)
	}
	return 1
}

@(private = "file")
_l_col_get_cursor_by_hash :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	col := _check_collection(L, 1)
	h := _lua_tobytes_odin(L, 2)
	c_maybe, err := hash_map_get_cursor_by_hash(Read_Hash_Map{cursor = col.rc}, h)
	if err != nil do return _raise_err(L, err, "collection:get_cursor_by_hash")
	if c, ok := c_maybe.?; ok {
		_col_push_read_cursor(L, 1, col, c)
	} else {
		lua.pushnil(L)
	}
	return 1
}

@(private = "file")
_l_col_get_index_kv_pair :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	col := _check_collection(L, 1)
	idx := i64(lua.tointeger(L, 2))
	kv_maybe, err := sorted_map_get_index_kv_pair(Read_Sorted_Map{cursor = col.rc}, idx)
	if err != nil do return _raise_err(L, err, "collection:get_index_kv_pair")
	if kv, ok := kv_maybe.?; ok {
		_col_push_read_cursor(L, 1, col, kv.key_cursor)
		_col_push_read_cursor(L, 1, col, kv.value_cursor)
		return 2
	}
	lua.pushnil(L)
	return 1
}

@(private = "file")
_l_col_rank :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	col := _check_collection(L, 1)
	k := _lua_tobytes_odin(L, 2)
	rk, err := sorted_map_rank_by_bytes(Read_Sorted_Map{cursor = col.rc}, k)
	if err != nil do return _raise_err(L, err, "collection:rank")
	lua.pushinteger(L, lua.Integer(rk))
	return 1
}

@(private = "file")
_l_col_contains :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	col := _check_collection(L, 1)
	k := _lua_tobytes_odin(L, 2)
	#partial switch col.kind {
	case .Sorted_Set:
		ok, err := sorted_set_contains_by_bytes(Read_Sorted_Set{cursor = col.rc}, k)
		if err != nil do return _raise_err(L, err, "collection:contains")
		lua.pushboolean(L, b32(ok))
		return 1
	case .Sorted_Map:
		c_maybe, err := sorted_map_get_cursor_by_bytes(Read_Sorted_Map{cursor = col.rc}, k)
		if err != nil do return _raise_err(L, err, "collection:contains")
		lua.pushboolean(L, b32(c_maybe != nil))
		return 1
	case .Hash_Set, .Counted_Hash_Set:
		c_maybe, err := hash_set_get_cursor_by_bytes(Read_Hash_Set{cursor = col.rc}, new_bytes(k))
		if err != nil do return _raise_err(L, err, "collection:contains")
		lua.pushboolean(L, b32(c_maybe != nil))
		return 1
	case .Hash_Map, .Counted_Hash_Map:
		c_maybe, err := hash_map_get_cursor_by_bytes(Read_Hash_Map{cursor = col.rc}, k)
		if err != nil do return _raise_err(L, err, "collection:contains")
		lua.pushboolean(L, b32(c_maybe != nil))
		return 1
	}
	return _raise_err(L, .Unexpected_Tag, "collection:contains")
}

@(private = "file")
_l_col_put :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	col := _check_collection(L, 1)
	if !col.is_write {
		return _raise_err(L, .Write_Not_Allowed, "collection:put")
	}
	err: Error
	switch col.kind {
	case .Array_List:
		idx := i64(lua.tointeger(L, 2))
		wdata, w_err := _lua_to_writeable_data(L, 3, true)
		if w_err != nil do return _raise_err(L, w_err, "array_list:put")
		al_w := Write_Array_List{Read_Array_List{col.rc}, col.wc}
		err = array_list_put(&al_w, idx, wdata)
		col.wc = al_w.write_cursor
		col.rc = al_w.cursor
	case .Linked_Array_List:
		idx := i64(lua.tointeger(L, 2))
		wdata, w_err := _lua_to_writeable_data(L, 3, true)
		if w_err != nil do return _raise_err(L, w_err, "linked_array_list:put")
		ll_w := Write_Linked_Array_List{Read_Linked_Array_List{col.rc}, col.wc}
		err = linked_array_list_put(&ll_w, idx, wdata)
		col.wc = ll_w.write_cursor
		col.rc = ll_w.cursor
	case .Hash_Map, .Counted_Hash_Map:
		k := _lua_tobytes_odin(L, 2)
		wdata, w_err := _lua_to_writeable_data(L, 3, true)
		if w_err != nil do return _raise_err(L, w_err, "hash_map:put")
		hm_w := Write_Hash_Map{Read_Hash_Map{col.rc}, col.wc}
		err = hash_map_put_bytes(&hm_w, new_bytes(k), wdata)
		col.wc = hm_w.write_cursor
		col.rc = hm_w.cursor
	case .Hash_Set, .Counted_Hash_Set:
		k := _lua_tobytes_odin(L, 2)
		hs_w := Write_Hash_Set{Read_Hash_Set{col.rc}, col.wc}
		err = hash_set_put_bytes(&hs_w, new_bytes(k))
		col.wc = hs_w.write_cursor
		col.rc = hs_w.cursor
	case .Sorted_Map:
		k := _lua_tobytes_odin(L, 2)
		wdata, w_err := _lua_to_writeable_data(L, 3, true)
		if w_err != nil do return _raise_err(L, w_err, "sorted_map:put")
		sm_w := Write_Sorted_Map{Read_Sorted_Map{col.rc}, col.wc}
		err = sorted_map_put_by_bytes(&sm_w, k, wdata)
		col.wc = sm_w.write_cursor
		col.rc = sm_w.cursor
	case .Sorted_Set:
		k := _lua_tobytes_odin(L, 2)
		ss_w := Write_Sorted_Set{Read_Sorted_Set{col.rc}, col.wc}
		err = sorted_set_put_by_bytes(&ss_w, k)
		col.wc = ss_w.write_cursor
		col.rc = ss_w.cursor
	}
	if err != nil do return _raise_err(L, err, "collection:put")
	return 0
}

@(private = "file")
_l_col_put_cursor :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	col := _check_collection(L, 1)
	if !col.is_write {
		return _raise_err(L, .Write_Not_Allowed, "collection:put_cursor")
	}
	wc: Write_Cursor
	err: Error
	switch col.kind {
	case .Array_List:
		idx := i64(lua.tointeger(L, 2))
		al_w := Write_Array_List{Read_Array_List{col.rc}, col.wc}
		wc, err = array_list_put_cursor(&al_w, idx)
		col.wc = al_w.write_cursor
		col.rc = al_w.cursor
	case .Linked_Array_List:
		idx := i64(lua.tointeger(L, 2))
		ll_w := Write_Linked_Array_List{Read_Linked_Array_List{col.rc}, col.wc}
		wc, err = linked_array_list_put_cursor(&ll_w, idx)
		col.wc = ll_w.write_cursor
		col.rc = ll_w.cursor
	case .Hash_Map, .Counted_Hash_Map:
		k := _lua_tobytes_odin(L, 2)
		hm_w := Write_Hash_Map{Read_Hash_Map{col.rc}, col.wc}
		wc, err = hash_map_put_cursor_by_bytes(&hm_w, new_bytes(k))
		col.wc = hm_w.write_cursor
		col.rc = hm_w.cursor
	case .Hash_Set, .Counted_Hash_Set:
		k := _lua_tobytes_odin(L, 2)
		hs_w := Write_Hash_Set{Read_Hash_Set{col.rc}, col.wc}
		wc, err = hash_set_put_cursor_by_bytes(&hs_w, new_bytes(k))
		col.wc = hs_w.write_cursor
		col.rc = hs_w.cursor
	case .Sorted_Map, .Sorted_Set:
		k := _lua_tobytes_odin(L, 2)
		sm_w := Write_Sorted_Map{Read_Sorted_Map{col.rc}, col.wc}
		wc, err = sorted_map_put_cursor_by_bytes(&sm_w, k)
		col.wc = sm_w.write_cursor
		col.rc = sm_w.cursor
	}
	if err != nil do return _raise_err(L, err, "collection:put_cursor")
	_col_push_write_cursor(L, 1, col, wc)
	return 1
}

@(private = "file")
_l_col_put_key :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	col := _check_collection(L, 1)
	if !col.is_write {
		return _raise_err(L, .Write_Not_Allowed, "collection:put_key")
	}
	k := _lua_tobytes_odin(L, 2)
	wdata, w_err := _lua_to_writeable_data(L, 3, true)
	if w_err != nil do return _raise_err(L, w_err, "collection:put_key")
	hm_w := Write_Hash_Map{Read_Hash_Map{col.rc}, col.wc}
	err := hash_map_put_key_by_bytes(&hm_w, new_bytes(k), wdata)
	col.wc = hm_w.write_cursor
	col.rc = hm_w.cursor
	if err != nil do return _raise_err(L, err, "collection:put_key")
	return 0
}

@(private = "file")
_l_col_put_key_and_value :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	col := _check_collection(L, 1)
	if !col.is_write {
		return _raise_err(L, .Write_Not_Allowed, "collection:put_key_and_value")
	}
	h := _lua_tobytes_odin(L, 2)
	k_data, k_err := _lua_to_writeable_data(L, 3, true)
	if k_err != nil do return _raise_err(L, k_err, "collection:put_key_and_value")
	v_data, v_err := _lua_to_writeable_data(L, 4, true)
	if v_err != nil do return _raise_err(L, v_err, "collection:put_key_and_value")

	hm_w := Write_Hash_Map{Read_Hash_Map{col.rc}, col.wc}
	err := hash_map_put_key_and_value(&hm_w, h, k_data, v_data)
	col.wc = hm_w.write_cursor
	col.rc = hm_w.cursor
	if err != nil do return _raise_err(L, err, "collection:put_key_and_value")
	return 0
}

@(private = "file")
_l_col_append :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	col := _check_collection(L, 1)
	if !col.is_write {
		return _raise_err(L, .Write_Not_Allowed, "collection:append")
	}
	wdata, w_err := _lua_to_writeable_data(L, 2, true)
	if w_err != nil do return _raise_err(L, w_err, "collection:append")
	err: Error
	#partial switch col.kind {
	case .Array_List:
		al_w := Write_Array_List{Read_Array_List{col.rc}, col.wc}
		err = array_list_append(&al_w, wdata)
		col.wc = al_w.write_cursor
		col.rc = al_w.cursor
	case .Linked_Array_List:
		ll_w := Write_Linked_Array_List{Read_Linked_Array_List{col.rc}, col.wc}
		err = linked_array_list_append(&ll_w, wdata)
		col.wc = ll_w.write_cursor
		col.rc = ll_w.cursor
	case:
		return _raise_err(L, .Unexpected_Tag, "collection:append")
	}
	if err != nil do return _raise_err(L, err, "collection:append")
	return 0
}

@(private = "file")
_l_col_append_cursor :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	col := _check_collection(L, 1)
	if !col.is_write {
		return _raise_err(L, .Write_Not_Allowed, "collection:append_cursor")
	}
	wc: Write_Cursor
	err: Error
	#partial switch col.kind {
	case .Array_List:
		al_w := Write_Array_List{Read_Array_List{col.rc}, col.wc}
		wc, err = array_list_append_cursor(&al_w)
		col.wc = al_w.write_cursor
		col.rc = al_w.cursor
	case .Linked_Array_List:
		ll_w := Write_Linked_Array_List{Read_Linked_Array_List{col.rc}, col.wc}
		wc, err = linked_array_list_append_cursor(&ll_w)
		col.wc = ll_w.write_cursor
		col.rc = ll_w.cursor
	case:
		return _raise_err(L, .Unexpected_Tag, "collection:append_cursor")
	}
	if err != nil do return _raise_err(L, err, "collection:append_cursor")
	_col_push_write_cursor(L, 1, col, wc)
	return 1
}

@(private = "file")
_l_col_append_context :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	col := _check_collection(L, 1)
	if !col.is_write {
		return _raise_err(L, .Write_Not_Allowed, "collection:append_context")
	}

	// Accept either `col:append_context(fn)` (empty Slot{}) or `col:append_context(slot_or_cursor, fn)`
	base_slot := Slot{}
	fn_idx: c.int = 2
	if lua.type(L, 2) == .FUNCTION {
		fn_idx = 2
	} else {
		fn_idx = 3
		if lua.type(L, 2) != .NIL {
			if sud := _test_ud(L, 2, Lua_Slot_UD, .Slot); sud != nil {
				base_slot = sud.slot
			} else if rc, ok := _extract_read_cursor(L, 2); ok {
				s, s_err := cursor_slot(rc)
				if s_err != nil do return _raise_err(L, s_err, "collection:append_context")
				base_slot = s
			}
		}
	}
	if lua.type(L, fn_idx) != .FUNCTION {
		return _raise_msg(L, "collection:append_context expects a callback function")
	}

	cctx := _Lua_Cb_Ctx{L = L, fn_idx = fn_idx}
	err: Error
	#partial switch col.kind {
	case .Array_List:
		al_w := Write_Array_List{Read_Array_List{col.rc}, col.wc}
		err = array_list_append_context(&al_w, base_slot, _lua_run_context_trampoline, &cctx)
		col.wc = al_w.write_cursor
		col.rc = al_w.cursor
	case .Linked_Array_List:
		ll_w := Write_Linked_Array_List{Read_Linked_Array_List{col.rc}, col.wc}
		err = linked_array_list_append_context(&ll_w, base_slot, _lua_run_context_trampoline, &cctx)
		col.wc = ll_w.write_cursor
		col.rc = ll_w.cursor
	case:
		return _raise_err(L, .Unexpected_Tag, "collection:append_context")
	}
	if err != nil {
		if len(cctx.err_msg) > 0 {
			return _raise_msg(L, cctx.err_msg)
		}
		return _raise_err(L, err, "collection:append_context")
	}
	return 0
}

@(private = "file")
_l_col_insert :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	col := _check_collection(L, 1)
	if !col.is_write || col.kind != .Linked_Array_List {
		return _raise_err(L, .Write_Not_Allowed, "collection:insert")
	}
	idx := i64(lua.tointeger(L, 2))
	wdata, w_err := _lua_to_writeable_data(L, 3, true)
	if w_err != nil do return _raise_err(L, w_err, "collection:insert")
	ll_w := Write_Linked_Array_List{Read_Linked_Array_List{col.rc}, col.wc}
	err := linked_array_list_insert(&ll_w, idx, wdata)
	col.wc = ll_w.write_cursor
	col.rc = ll_w.cursor
	if err != nil do return _raise_err(L, err, "collection:insert")
	return 0
}

@(private = "file")
_l_col_insert_cursor :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	col := _check_collection(L, 1)
	if !col.is_write || col.kind != .Linked_Array_List {
		return _raise_err(L, .Write_Not_Allowed, "collection:insert_cursor")
	}
	idx := i64(lua.tointeger(L, 2))
	ll_w := Write_Linked_Array_List{Read_Linked_Array_List{col.rc}, col.wc}
	wc, err := linked_array_list_insert_cursor(&ll_w, idx)
	col.wc = ll_w.write_cursor
	col.rc = ll_w.cursor
	if err != nil do return _raise_err(L, err, "collection:insert_cursor")
	_col_push_write_cursor(L, 1, col, wc)
	return 1
}

@(private = "file")
_l_col_remove :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	col := _check_collection(L, 1)
	if !col.is_write {
		return _raise_err(L, .Write_Not_Allowed, "collection:remove")
	}
	removed := true
	err: Error
	switch col.kind {
	case .Linked_Array_List:
		idx := i64(lua.tointeger(L, 2))
		ll_w := Write_Linked_Array_List{Read_Linked_Array_List{col.rc}, col.wc}
		err = linked_array_list_remove(&ll_w, idx)
		col.wc = ll_w.write_cursor
		col.rc = ll_w.cursor
	case .Hash_Map, .Counted_Hash_Map:
		k := _lua_tobytes_odin(L, 2)
		hm_w := Write_Hash_Map{Read_Hash_Map{col.rc}, col.wc}
		removed, err = hash_map_remove_by_bytes(&hm_w, new_bytes(k))
		col.wc = hm_w.write_cursor
		col.rc = hm_w.cursor
	case .Hash_Set, .Counted_Hash_Set:
		k := _lua_tobytes_odin(L, 2)
		hs_w := Write_Hash_Set{Read_Hash_Set{col.rc}, col.wc}
		removed, err = hash_set_remove_by_bytes(&hs_w, new_bytes(k))
		col.wc = hs_w.write_cursor
		col.rc = hs_w.cursor
	case .Sorted_Map:
		k := _lua_tobytes_odin(L, 2)
		sm_w := Write_Sorted_Map{Read_Sorted_Map{col.rc}, col.wc}
		removed, err = sorted_map_remove_by_bytes(&sm_w, k)
		col.wc = sm_w.write_cursor
		col.rc = sm_w.cursor
	case .Sorted_Set:
		k := _lua_tobytes_odin(L, 2)
		ss_w := Write_Sorted_Set{Read_Sorted_Set{col.rc}, col.wc}
		removed, err = sorted_set_remove_by_bytes(&ss_w, k)
		col.wc = ss_w.write_cursor
		col.rc = ss_w.cursor
	case .Array_List:
		return _raise_err(L, .Write_Not_Allowed, "array_list:remove")
	}
	if err != nil do return _raise_err(L, err, "collection:remove")
	lua.pushboolean(L, b32(removed))
	return 1
}

@(private = "file")
_l_col_remove_by_hash :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	col := _check_collection(L, 1)
	if !col.is_write {
		return _raise_err(L, .Write_Not_Allowed, "collection:remove_by_hash")
	}
	h := _lua_tobytes_odin(L, 2)
	hm_w := Write_Hash_Map{Read_Hash_Map{col.rc}, col.wc}
	removed, err := hash_map_remove_by_hash(&hm_w, h)
	col.wc = hm_w.write_cursor
	col.rc = hm_w.cursor
	if err != nil do return _raise_err(L, err, "collection:remove_by_hash")
	lua.pushboolean(L, b32(removed))
	return 1
}

@(private = "file")
_l_col_slice :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	col := _check_collection(L, 1)
	if !col.is_write {
		return _raise_err(L, .Write_Not_Allowed, "collection:slice")
	}
	err: Error
	#partial switch col.kind {
	case .Array_List:
		sz := i64(lua.tointeger(L, 2))
		al_w := Write_Array_List{Read_Array_List{col.rc}, col.wc}
		err = array_list_slice(&al_w, sz)
		col.wc = al_w.write_cursor
		col.rc = al_w.cursor
	case .Linked_Array_List:
		// Accept either `ll:slice(offset, size)` or `ll:slice(size)`
		offset: i64 = 0
		size: i64 = 0
		if lua.gettop(L) >= 3 {
			offset = i64(lua.tointeger(L, 2))
			size = i64(lua.tointeger(L, 3))
		} else {
			size = i64(lua.tointeger(L, 2))
		}
		ll_w := Write_Linked_Array_List{Read_Linked_Array_List{col.rc}, col.wc}
		err = linked_array_list_slice(&ll_w, offset, size)
		col.wc = ll_w.write_cursor
		col.rc = ll_w.cursor
	case:
		return _raise_err(L, .Unexpected_Tag, "collection:slice")
	}
	if err != nil do return _raise_err(L, err, "collection:slice")
	return 0
}

@(private = "file")
_l_col_concat :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	col := _check_collection(L, 1)
	if !col.is_write || col.kind != .Linked_Array_List {
		return _raise_err(L, .Write_Not_Allowed, "collection:concat")
	}
	s: Slot
	if sud := _test_ud(L, 2, Lua_Slot_UD, .Slot); sud != nil {
		s = sud.slot
	} else if rc, ok := _extract_read_cursor(L, 2); ok {
		s_err: Error
		s, s_err = cursor_slot(rc)
		if s_err != nil do return _raise_err(L, s_err, "collection:concat")
	} else {
		return _raise_msg(L, "collection:concat expects Slot or Collection/Cursor")
	}
	ll_w := Write_Linked_Array_List{Read_Linked_Array_List{col.rc}, col.wc}
	err := linked_array_list_concat(&ll_w, s)
	col.wc = ll_w.write_cursor
	col.rc = ll_w.cursor
	if err != nil do return _raise_err(L, err, "collection:concat")
	return 0
}

@(private = "file")
_col_push_iterator :: proc(L: ^lua.State, col_idx: c.int, col: ^Lua_Collection_UD, it: Cursor_Iterator) {
	ud := col.iter_ud
	if ud != nil {
		ud.it = it
		lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(col.iter_ref))
	} else {
		ud = (^Lua_Iterator_UD)(lua.newuserdata(L, size_of(Lua_Iterator_UD)))
		ud^ = Lua_Iterator_UD{
			hdr = {magic = LUA_UD_MAGIC, ud_kind = .Iterator},
			it  = it,
		}
		_set_ud_mt(L, .Iterator, LUA_MT_ITERATOR)
		lua.pushvalue(L, -1)
		col.iter_ref = lua.L_ref(L, lua.REGISTRYINDEX)
		col.iter_ud = ud
	}
}

@(private = "file")
_l_col_iterator :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	col := _check_collection(L, 1)
	it, err := cursor_iterator(col.rc)
	if err != nil do return _raise_err(L, err, "collection:iterator")
	_col_push_iterator(L, 1, col, it)
	return 1
}

@(private = "file")
_l_col_iterator_from :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	col := _check_collection(L, 1)
	it: Cursor_Iterator
	err: Error

	#partial switch col.kind {
	case .Array_List:
		idx := i64(lua.tointeger(L, 2))
		it, err = array_list_iterator_from(Read_Array_List{cursor = col.rc}, idx)
	case .Linked_Array_List:
		idx := i64(lua.tointeger(L, 2))
		it, err = linked_array_list_iterator_from(Read_Linked_Array_List{cursor = col.rc}, idx)
	case .Sorted_Map:
		k := _lua_tobytes_odin(L, 2)
		it, err = sorted_map_iterator_from(Read_Sorted_Map{cursor = col.rc}, k)
	case .Sorted_Set:
		k := _lua_tobytes_odin(L, 2)
		it, err = sorted_set_iterator_from(Read_Sorted_Set{cursor = col.rc}, k)
	case:
		return _raise_err(L, .Unexpected_Tag, "collection:iterator_from")
	}
	if err != nil do return _raise_err(L, err, "collection:iterator_from")
	_col_push_iterator(L, 1, col, it)
	return 1
}

@(private = "file")
_l_col_iterator_from_index :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	col := _check_collection(L, 1)
	idx := i64(lua.tointeger(L, 2))
	it: Cursor_Iterator
	err: Error

	#partial switch col.kind {
	case .Sorted_Map:
		it, err = sorted_map_iterator_from_index(Read_Sorted_Map{cursor = col.rc}, idx)
	case .Sorted_Set:
		it, err = sorted_set_iterator_from_index(Read_Sorted_Set{cursor = col.rc}, idx)
	case .Array_List:
		it, err = array_list_iterator_from(Read_Array_List{cursor = col.rc}, idx)
	case .Linked_Array_List:
		it, err = linked_array_list_iterator_from(Read_Linked_Array_List{cursor = col.rc}, idx)
	case:
		return _raise_err(L, .Unexpected_Tag, "collection:iterator_from_index")
	}
	if err != nil do return _raise_err(L, err, "collection:iterator_from_index")
	_col_push_iterator(L, 1, col, it)
	return 1
}

// ----------------------------------------------------------------------------
// `Iterator`, `Reader`, `Writer`, and `Slot` Userdata Methods
// ----------------------------------------------------------------------------

@(private = "file")
_l_iterator_next :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	ud := _check_ud(L, 1, Lua_Iterator_UD, .Iterator, "expected xitdb.Iterator")
	c_maybe, err := cursor_iterator_next(&ud.it)
	if err != nil do return _raise_err(L, err, "iterator:next")
	if c, ok := c_maybe.?; ok {
		cud := ud.cur_ud
		if cud != nil {
			cud.rc       = c
			cud.is_write = false
			lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(ud.cur_ref))
		} else {
			cud = (^Lua_Cursor_UD)(lua.newuserdata(L, size_of(Lua_Cursor_UD)))
			cud^ = Lua_Cursor_UD{
				hdr      = {magic = LUA_UD_MAGIC, ud_kind = .Cursor},
				rc       = c,
				is_write = false,
			}
			_set_ud_mt(L, .Cursor, LUA_MT_CURSOR)
			lua.pushvalue(L, -1)
			ud.cur_ref = lua.L_ref(L, lua.REGISTRYINDEX)
			ud.cur_ud = cud
		}
		return 1
	}
	lua.pushnil(L)
	return 1
}

@(private = "file")
_l_reader_read :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	ud := _check_ud(L, 1, Lua_Reader_UD, .Reader, "expected xitdb.Reader")
	sz := int(lua.L_optinteger(L, 2, 4096))
	if sz <= 0 {
		_push_str(L, "")
		return 1
	}
	stack_buf: [4096]u8
	buf: []u8
	if sz <= len(stack_buf) {
		buf = stack_buf[:sz]
	} else {
		buf = make([]u8, sz, context.temp_allocator)
	}
	nr, err := cursor_reader_read(&ud.reader, buf)
	if err != nil do return _raise_err(L, err, "reader:read")
	if nr == 0 {
		lua.pushnil(L)
		return 1
	}
	_push_bytes(L, buf[:nr])
	return 1
}

@(private = "file")
_l_reader_read_all :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	ud := _check_ud(L, 1, Lua_Reader_UD, .Reader, "expected xitdb.Reader")
	rem := int(max(0, ud.reader.size - ud.reader.relative_position))
	buf := make([]u8, rem, context.temp_allocator)
	err := cursor_reader_read_fully(&ud.reader, buf)
	if err != nil do return _raise_err(L, err, "reader:read_all")
	_push_bytes(L, buf)
	return 1
}

@(private = "file")
_l_reader_seek_to :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	ud := _check_ud(L, 1, Lua_Reader_UD, .Reader, "expected xitdb.Reader")
	off := i64(lua.tointeger(L, 2))
	err := cursor_reader_seek_to(&ud.reader, off)
	if err != nil do return _raise_err(L, err, "reader:seek_to")
	return 0
}

@(private = "file")
_l_reader_size :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	ud := _check_ud(L, 1, Lua_Reader_UD, .Reader, "expected xitdb.Reader")
	lua.pushinteger(L, lua.Integer(ud.reader.size))
	return 1
}

@(private = "file")
_l_reader_pos :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	ud := _check_ud(L, 1, Lua_Reader_UD, .Reader, "expected xitdb.Reader")
	lua.pushinteger(L, lua.Integer(ud.reader.relative_position))
	return 1
}

@(private = "file")
_l_writer_write :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	ud := _check_ud(L, 1, Lua_Writer_UD, .Writer, "expected xitdb.Writer")
	data := _lua_tobytes_odin(L, 2)
	nw, err := cursor_writer_write(&ud.writer, data)
	if err != nil do return _raise_err(L, err, "writer:write")
	lua.pushinteger(L, lua.Integer(nw))
	return 1
}

@(private = "file")
_l_writer_seek_to :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	ud := _check_ud(L, 1, Lua_Writer_UD, .Writer, "expected xitdb.Writer")
	off := i64(lua.tointeger(L, 2))
	err := cursor_writer_seek_to(&ud.writer, off)
	if err != nil do return _raise_err(L, err, "writer:seek_to")
	return 0
}

@(private = "file")
_l_writer_set_format_tag :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	ud := _check_ud(L, 1, Lua_Writer_UD, .Writer, "expected xitdb.Writer")
	tag := _lua_tobytes_odin(L, 2)
	if len(tag) != 2 {
		return _raise_err(L, .Invalid_Format_Tag_Size, "writer:set_format_tag")
	}
	tag_copy := make([]u8, 2, context.temp_allocator)
	tag_copy[0] = tag[0]
	tag_copy[1] = tag[1]
	ud.writer.format_tag = tag_copy
	return 0
}

@(private = "file")
_l_writer_finish :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	ud := _check_ud(L, 1, Lua_Writer_UD, .Writer, "expected xitdb.Writer")
	if !ud.finished {
		err := cursor_writer_finish(&ud.writer)
		if err != nil do return _raise_err(L, err, "writer:finish")
		ud.finished = true
		if ud.parent_cud != nil && ud.writer.parent != nil {
			ud.parent_cud.wc = ud.writer.parent^
			ud.parent_cud.rc = ud.writer.parent.read_cursor
		}
	}
	return 0
}

@(private = "file")
_l_writer_size :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	ud := _check_ud(L, 1, Lua_Writer_UD, .Writer, "expected xitdb.Writer")
	lua.pushinteger(L, lua.Integer(ud.writer.size))
	return 1
}

@(private = "file")
_l_writer_pos :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	ud := _check_ud(L, 1, Lua_Writer_UD, .Writer, "expected xitdb.Writer")
	lua.pushinteger(L, lua.Integer(ud.writer.relative_position))
	return 1
}

@(private = "file")
_l_slot_tag :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	ud := _check_ud(L, 1, Lua_Slot_UD, .Slot, "expected xitdb.Slot")
	name := _tag_name(ud.slot.tag)
	_push_str(L, name)
	lua.pushinteger(L, lua.Integer(ud.slot.tag))
	return 2
}

@(private = "file")
_l_slot_value :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	ud := _check_ud(L, 1, Lua_Slot_UD, .Slot, "expected xitdb.Slot")
	lua.pushinteger(L, lua.Integer(ud.slot.value))
	return 1
}

@(private = "file")
_l_slot_full :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	ud := _check_ud(L, 1, Lua_Slot_UD, .Slot, "expected xitdb.Slot")
	lua.pushboolean(L, b32(ud.slot.full))
	return 1
}

@(private = "file")
_l_slot_eq :: proc "c" (L: ^lua.State) -> c.int {
	context = _lua_context(L)
	a := _test_ud(L, 1, Lua_Slot_UD, .Slot)
	b := _test_ud(L, 2, Lua_Slot_UD, .Slot)
	if a == nil || b == nil {
		lua.pushboolean(L, false)
		return 1
	}
	lua.pushboolean(L, b32(a.slot == b.slot))
	return 1
}

// ----------------------------------------------------------------------------
// Metatable Registration & Monotonic Clock Helper
// ----------------------------------------------------------------------------

@(private = "file")
_l_cursor_gc :: proc "c" (L: ^lua.State) -> c.int {
	cud := _test_ud(L, 1, Lua_Cursor_UD, .Cursor)
	if cud != nil {
		if cud.kv_key_ref > 0 {
			lua.L_unref(L, lua.REGISTRYINDEX, cud.kv_key_ref)
			cud.kv_key_ref = 0
			cud.kv_key_ud = nil
		}
		if cud.kv_val_ref > 0 {
			lua.L_unref(L, lua.REGISTRYINDEX, cud.kv_val_ref)
			cud.kv_val_ref = 0
			cud.kv_val_ud = nil
		}
	}
	return 0
}

@(private = "file")
_l_col_gc :: proc "c" (L: ^lua.State) -> c.int {
	col := _test_ud(L, 1, Lua_Collection_UD, .Collection)
	if col != nil {
		if col.iter_ref > 0 {
			lua.L_unref(L, lua.REGISTRYINDEX, col.iter_ref)
			col.iter_ref = 0
			col.iter_ud = nil
		}
		for i in 0 ..< LUA_COL_CURSOR_RING_SIZE {
			if col.cur_refs[i] > 0 {
				lua.L_unref(L, lua.REGISTRYINDEX, col.cur_refs[i])
				col.cur_refs[i] = 0
				col.cur_ring[i] = nil
			}
		}
		if col.slot_ref > 0 {
			lua.L_unref(L, lua.REGISTRYINDEX, col.slot_ref)
			col.slot_ref = 0
			col.slot_ud = nil
		}
	}
	return 0
}

@(private = "file")
_l_iterator_gc :: proc "c" (L: ^lua.State) -> c.int {
	ud := _test_ud(L, 1, Lua_Iterator_UD, .Iterator)
	if ud != nil && ud.cur_ref > 0 {
		lua.L_unref(L, lua.REGISTRYINDEX, ud.cur_ref)
		ud.cur_ref = 0
		ud.cur_ud = nil
	}
	return 0
}

@(private = "file")
_bind_mt_ref :: proc(L: ^lua.State, ext: ^_Lua_State_Ext, kind: Lua_UD_Kind) {
	if ext != nil {
		lua.pushvalue(L, -1)
		ext.mt_refs[kind] = lua.L_ref(L, lua.REGISTRYINDEX)
	}
}

@(private = "file")
_register_metatables :: proc(L: ^lua.State) {
	ext := _lua_ext(L)

	// 1. Database metatable
	if lua.L_newmetatable(L, LUA_MT_DB) != 0 {
		db_methods := [?]lua.L_Reg{
			{"close",                  _l_db_close},
			{"reopen",                 _l_db_reopen},
			{"committed_size",         _l_db_committed_size},
			{"freeze",                 _l_db_freeze},
			{"root_cursor",            _l_db_root_cursor},
			{"digest",                 _l_db_digest},
			{"run_context",            _l_db_run_context},
			{"replica_state",          _l_db_replica_state},
			{"replication_start",      _l_db_replication_start},
			{"read_committed_bytes",   _l_db_read_committed_bytes},
			{"apply_replicated_bytes", _l_db_apply_replicated_bytes},
			{"compact",                _l_db_compact},
			{"select_cursor",          _l_db_select_cursor},
			{"get_string",             _l_db_get_string},
			{"get_uint",               _l_db_get_uint},
			{"get_int",                _l_db_get_int},
			{"get_float",              _l_db_get_float},
			{"get",                    _l_db_get},
			{"tx_init",                _l_db_tx_init},
			{"transact_script",        _l_db_transact_script},
			{"pull",                   _l_db_pull},
			{"unmarshal",              _l_db_unmarshal},
			{"marshal",                _l_db_marshal},
			{"diff_moments",           _l_db_diff_moments},
			{"history_of",             _l_db_history_of},
			{"query_prefix",           _l_db_query_prefix},
			{"query_page",             _l_db_query_page},
			{"query_count_range",      _l_db_query_count_range},
			{"query_datalog",          _l_db_query_datalog},
			{nil, nil},
		}
		lua.createtable(L, 0, i32(len(db_methods)))
		lua.L_setfuncs(L, &db_methods[0], 0)
		lua.setfield(L, -2, "__index")
		lua.pushcfunction(L, _l_db_gc)
		lua.setfield(L, -2, "__gc")
		lua.pushcfunction(L, _l_db_close)
		lua.setfield(L, -2, "__close")
	}
	_bind_mt_ref(L, ext, .Database)
	lua.pop(L, 1)

	// 2. Cursor metatable
	if lua.L_newmetatable(L, LUA_MT_CURSOR) != 0 {
		cur_methods := [?]lua.L_Reg{
			{"slot",              _l_cursor_slot},
			{"tag",               _l_cursor_tag},
			{"count",             _l_cursor_count},
			{"read_uint",         _l_cursor_read_uint},
			{"read_int",          _l_cursor_read_int},
			{"read_float",        _l_cursor_read_float},
			{"read_string",       _l_cursor_read_string},
			{"read_bytes",        _l_cursor_read_bytes},
			{"read_bytes_object", _l_cursor_read_bytes},
			{"read_kv_pair",      _l_cursor_read_kv_pair},
			{"write",             _l_cursor_write},
			{"write_if_empty",    _l_cursor_write_if_empty},
			{"freeze",            _l_cursor_freeze},
			{"read_only",         _l_cursor_read_only},
			{"iterator",          _l_cursor_iterator},
			{"reader",            _l_cursor_reader},
			{"writer",            _l_cursor_writer},
			{"pull",              _l_cursor_pull},
			{"unmarshal",         _l_cursor_unmarshal},
			{"marshal",           _l_cursor_marshal},
			{"read_path",         _l_cursor_read_path},
			{"write_path",        _l_cursor_write_path},
			{nil, nil},
		}
		lua.createtable(L, 0, i32(len(cur_methods)))
		lua.L_setfuncs(L, &cur_methods[0], 0)
		lua.setfield(L, -2, "__index")
		lua.pushcfunction(L, _l_cursor_gc)
		lua.setfield(L, -2, "__gc")
	}
	_bind_mt_ref(L, ext, .Cursor)
	lua.pop(L, 1)

	// 3. Collection metatable
	if lua.L_newmetatable(L, LUA_MT_COLLECTION) != 0 {
		col_methods := [?]lua.L_Reg{
			{"cursor",              _l_col_cursor},
			{"slot",                _l_col_slot},
			{"freeze",              _l_col_freeze},
			{"count",               _l_col_count},
			{"get_cursor",          _l_col_get_cursor},
			{"get_slot",            _l_col_get_slot},
			{"get_key_cursor",      _l_col_get_key_cursor},
			{"get_kv_pair",         _l_col_get_kv_pair},
			{"get_cursor_by_hash",  _l_col_get_cursor_by_hash},
			{"get_index_kv_pair",   _l_col_get_index_kv_pair},
			{"rank",                _l_col_rank},
			{"contains",            _l_col_contains},
			{"put",                 _l_col_put},
			{"put_cursor",          _l_col_put_cursor},
			{"put_key",             _l_col_put_key},
			{"put_key_and_value",   _l_col_put_key_and_value},
			{"append",              _l_col_append},
			{"append_cursor",       _l_col_append_cursor},
			{"append_context",      _l_col_append_context},
			{"insert",              _l_col_insert},
			{"insert_cursor",       _l_col_insert_cursor},
			{"remove",              _l_col_remove},
			{"remove_by_hash",      _l_col_remove_by_hash},
			{"slice",               _l_col_slice},
			{"concat",              _l_col_concat},
			{"iterator",            _l_col_iterator},
			{"iterator_from",       _l_col_iterator_from},
			{"iterator_from_index", _l_col_iterator_from_index},
			{nil, nil},
		}
		lua.createtable(L, 0, i32(len(col_methods)))
		lua.L_setfuncs(L, &col_methods[0], 0)
		lua.setfield(L, -2, "__index")
		lua.pushcfunction(L, _l_col_gc)
		lua.setfield(L, -2, "__gc")
	}
	_bind_mt_ref(L, ext, .Collection)
	lua.pop(L, 1)

	// 4. Iterator metatable (supports both `it:next()` and `for cur in col:iterator() do`)
	if lua.L_newmetatable(L, LUA_MT_ITERATOR) != 0 {
		it_methods := [?]lua.L_Reg{
			{"next", _l_iterator_next},
			{nil, nil},
		}
		lua.createtable(L, 0, i32(len(it_methods)))
		lua.L_setfuncs(L, &it_methods[0], 0)
		lua.setfield(L, -2, "__index")
		lua.pushcfunction(L, _l_iterator_next)
		lua.setfield(L, -2, "__call")
		lua.pushcfunction(L, _l_iterator_gc)
		lua.setfield(L, -2, "__gc")
	}
	_bind_mt_ref(L, ext, .Iterator)
	lua.pop(L, 1)

	// 5. Reader metatable
	if lua.L_newmetatable(L, LUA_MT_READER) != 0 {
		r_methods := [?]lua.L_Reg{
			{"read",     _l_reader_read},
			{"read_all", _l_reader_read_all},
			{"seek_to",  _l_reader_seek_to},
			{"size",     _l_reader_size},
			{"pos",      _l_reader_pos},
			{nil, nil},
		}
		lua.createtable(L, 0, i32(len(r_methods)))
		lua.L_setfuncs(L, &r_methods[0], 0)
		lua.setfield(L, -2, "__index")
	}
	_bind_mt_ref(L, ext, .Reader)
	lua.pop(L, 1)

	// 6. Writer metatable
	if lua.L_newmetatable(L, LUA_MT_WRITER) != 0 {
		w_methods := [?]lua.L_Reg{
			{"write",          _l_writer_write},
			{"seek_to",        _l_writer_seek_to},
			{"set_format_tag", _l_writer_set_format_tag},
			{"finish",         _l_writer_finish},
			{"size",           _l_writer_size},
			{"pos",            _l_writer_pos},
			{nil, nil},
		}
		lua.createtable(L, 0, i32(len(w_methods)))
		lua.L_setfuncs(L, &w_methods[0], 0)
		lua.setfield(L, -2, "__index")
	}
	_bind_mt_ref(L, ext, .Writer)
	lua.pop(L, 1)

	// 7. Tx metatable
	if lua.L_newmetatable(L, LUA_MT_TX) != 0 {
		tx_methods := [?]lua.L_Reg{
			{"doc",         _l_tx_doc},
			{"instant",     _l_tx_instant},
			{"meta",        _l_tx_meta},
			{"index_on",    _l_tx_index_on},
			{"put",         _l_tx_put},
			{"append",      _l_tx_append},
			{"insert",      _l_tx_insert},
			{"rm",          _l_tx_rm},
			{"slice",       _l_tx_slice},
			{"fork",        _l_tx_fork},
			{"savepoint",   _l_tx_savepoint},
			{"with_cursor", _l_tx_with_cursor},
			{"commit",      _l_tx_commit},
			{nil, nil},
		}
		lua.createtable(L, 0, i32(len(tx_methods)))
		lua.L_setfuncs(L, &tx_methods[0], 0)
		lua.setfield(L, -2, "__index")
		lua.pushcfunction(L, _l_tx_gc)
		lua.setfield(L, -2, "__gc")
	}
	_bind_mt_ref(L, ext, .Tx)
	lua.pop(L, 1)

	// 8. Offset_Map metatable
	if lua.L_newmetatable(L, LUA_MT_OFFSET_MAP) != 0 {
		om_methods := [?]lua.L_Reg{
			{"close", _l_offset_map_close},
			{nil, nil},
		}
		lua.createtable(L, 0, i32(len(om_methods)))
		lua.L_setfuncs(L, &om_methods[0], 0)
		lua.setfield(L, -2, "__index")
		lua.pushcfunction(L, _l_offset_map_close)
		lua.setfield(L, -2, "__gc")
		lua.pushcfunction(L, _l_offset_map_close)
		lua.setfield(L, -2, "__close")
	}
	_bind_mt_ref(L, ext, .Offset_Map)
	lua.pop(L, 1)

	// 9. Typed_Val metatable
	if lua.L_newmetatable(L, LUA_MT_TYPED_VAL) != 0 {
		lua.pushcfunction(L, _l_typed_val_gc)
		lua.setfield(L, -2, "__gc")
	}
	_bind_mt_ref(L, ext, .Typed_Val)
	lua.pop(L, 1)

	// 10. Slot metatable
	if lua.L_newmetatable(L, LUA_MT_SLOT) != 0 {
		slot_methods := [?]lua.L_Reg{
			{"tag",   _l_slot_tag},
			{"value", _l_slot_value},
			{"full",  _l_slot_full},
			{nil, nil},
		}
		lua.createtable(L, 0, i32(len(slot_methods)))
		lua.L_setfuncs(L, &slot_methods[0], 0)
		lua.setfield(L, -2, "__index")
		lua.pushcfunction(L, _l_slot_eq)
		lua.setfield(L, -2, "__eq")
	}
	_bind_mt_ref(L, ext, .Slot)
	lua.pop(L, 1)
}

@(private = "file")
_monotonic_ns :: proc() -> i64 {
	return i64(time.tick_since(_base_tick))
}
