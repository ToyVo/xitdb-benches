package xitdb

import "core:encoding/endian"
import "core:math/rand"

// Transaction tracks the active transaction's root slot, scratch slot, and freeze watermark.
Transaction :: struct {
	root_position:    Maybe(i64),
	scratch_position: Maybe(i64),
	frozen_at:        Maybe(i64),
}

transaction_is_root_position :: proc(t: ^Transaction, pos: Maybe(i64)) -> bool {
	if t == nil || pos == nil || t.root_position == nil {
		return false
	}
	return pos.? == t.root_position.?
}

transaction_is_scratch_position :: proc(t: ^Transaction, pos: Maybe(i64)) -> bool {
	if t == nil || pos == nil || t.scratch_position == nil {
		return false
	}
	return pos.? == t.scratch_position.?
}

// Context_Function is the transaction callback signature.
Context_Function :: proc(cursor: ^Write_Cursor, user_data: rawptr = nil) -> Error

// Database is the primary handle to a xitdb store.
Database :: struct {
	core:        ^Core,
	hasher:      Hasher,
	header:      Header,
	tx_start:    Maybe(i64),
	transaction: ^Transaction,
}

// Path_Part Variants for read_slot_pointer traversal.
Array_List_Init :: struct {}

Array_List_Get :: struct {
	index: i64,
}

Array_List_Append :: struct {}

Array_List_Slice :: struct {
	size: i64,
}

Linked_Array_List_Init :: struct {}

Linked_Array_List_Get :: struct {
	index: i64,
}

Linked_Array_List_Append :: struct {}

Linked_Array_List_Slice :: struct {
	offset: i64,
	size:   i64,
}

Linked_Array_List_Concat :: struct {
	list: Slot,
}

Linked_Array_List_Insert :: struct {
	index: i64,
}

Linked_Array_List_Remove :: struct {
	index: i64,
}

Hash_Map_Init :: struct {
	counted: bool,
	set:     bool,
}

Hash_Map_Get_Value :: struct {
	hash: []u8,
}

Hash_Map_Get_Key :: struct {
	hash: []u8,
}

Hash_Map_Get_KV_Pair :: struct {
	hash: []u8,
}

Hash_Map_Get_Target :: union {
	Hash_Map_Get_Value,
	Hash_Map_Get_Key,
	Hash_Map_Get_KV_Pair,
}

Hash_Map_Get :: struct {
	target: Hash_Map_Get_Target,
}

Hash_Map_Remove :: struct {
	hash: []u8,
}

Sorted_Map_Init :: struct {
	set: bool,
}

Sorted_Map_Get_Value :: struct {
	key: []u8,
}

Sorted_Map_Get_Key :: struct {
	key: []u8,
}

Sorted_Map_Get_KV_Pair :: struct {
	key: []u8,
}

Sorted_Map_Get_Target :: union {
	Sorted_Map_Get_Value,
	Sorted_Map_Get_Key,
	Sorted_Map_Get_KV_Pair,
}

Sorted_Map_Get :: struct {
	target: Sorted_Map_Get_Target,
}

Sorted_Map_Get_Index :: struct {
	index: i64,
}

Sorted_Map_Remove :: struct {
	key: []u8,
}

Write_Data :: struct {
	data:     Writeable_Data,
	if_empty: bool,
}

Write_KV_Data :: struct {
	key:   Writeable_Data,
	value: Writeable_Data,
}

Context :: struct {
	function:  Context_Function,
	user_data: rawptr,
}

Path_Part :: union {
	Array_List_Init,
	Array_List_Get,
	Array_List_Append,
	Array_List_Slice,
	Linked_Array_List_Init,
	Linked_Array_List_Get,
	Linked_Array_List_Append,
	Linked_Array_List_Slice,
	Linked_Array_List_Concat,
	Linked_Array_List_Insert,
	Linked_Array_List_Remove,
	Hash_Map_Init,
	Hash_Map_Get,
	Hash_Map_Remove,
	Sorted_Map_Init,
	Sorted_Map_Get,
	Sorted_Map_Get_Index,
	Sorted_Map_Remove,
	Write_Data,
	Write_KV_Data,
	Context,
}

// Initialize or open a xitdb database on `core`.
database_init :: proc(core: ^Core, hasher := Hasher{}) -> (db: Database, err: Error) {
	h := hasher
	if h.hash_proc == nil && h.hash_size == 0 {
		h = sha1_hasher()
	}

	// If buffered file, clear any stale buffer bytes before opening.
	#partial switch &bf in core {
	case Core_Buffered_File:
		clear(&bf.memory.buf)
		bf.memory_pos = 0
		bf.pos = 0
		bf.file_len = nil
	}

	db.core = core
	db.hasher = h
	db.tx_start = nil
	db.transaction = nil

	core_seek_to(core, 0) or_return
	length := core_length(core) or_return

	if length == 0 {
		file_id := h.file_id
		if file_id == 0 {
			file_id = _random_u64()
		}
		digest_len := h.hash_size
		if digest_len == 0 {
			digest_len = 20
		}
		db.header = Header{
			file_id      = file_id,
			hash_id      = h.id,
			hash_size    = digest_len,
			version      = VERSION,
			padding      = 0,
			magic_number = MAGIC_NUMBER,
		}
		header_write(db.header, core) or_return
		rh_bytes := root_header_to_bytes(Root_Header{file_size = 0, root = Slot{}})
		core_write_all(core, rh_bytes[:]) or_return
		database_commit_root(&db, Slot{}, 0) or_return
		core_sync(core) or_return
	} else {
		db.header = database_read_and_validate_header(&db) or_return
		_ = database_committed_size(&db) or_return
	}

	db.tx_start = nil
	return db, nil
}

@(private)
_random_u64 :: proc() -> u64 {
	v := rand.uint64()
	if v == 0 {
		v = 1
	}
	return v
}

// Compute a key digest using the database's configured hasher.
database_digest :: proc(db: ^Database, data: []u8, allocator := context.temp_allocator) -> []u8 {
	out := make([]u8, int(db.header.hash_size), allocator)
	if db.hasher.hash_proc != nil {
		db.hasher.hash_proc(data, out, db.hasher.user_data)
	}
	return out
}

database_digest_string :: proc(db: ^Database, s: string, allocator := context.temp_allocator) -> []u8 {
	return database_digest(db, transmute([]u8)s, allocator)
}

database_digest_buf :: proc(db: ^Database, data: []u8, buf: []u8) -> []u8 {
	hsize := int(db.header.hash_size)
	out := buf[:hsize] if hsize <= len(buf) else make([]u8, hsize, context.temp_allocator)
	if db.hasher.hash_proc != nil {
		db.hasher.hash_proc(data, out, db.hasher.user_data)
	}
	return out
}

database_digest_string_buf :: proc(db: ^Database, s: string, buf: []u8) -> []u8 {
	return database_digest_buf(db, transmute([]u8)s, buf)
}

database_read_and_validate_header :: proc(db: ^Database) -> (res: Header, err: Error) {
	header := header_read_at(db.core, 0) or_return
	header_validate(header) or_return
	if db.hasher.hash_size != 0 && header.hash_size != db.hasher.hash_size {
		return {}, .Invalid_Hash_Size
	}
	return header, nil
}

// Return a writeable root cursor pointing at ROOT_HEADER_START.
database_root_cursor :: proc(db: ^Database) -> Write_Cursor {
	root, err := database_read_root_slot(db)
	if err != nil {
		root = Slot{}
	}
	return Write_Cursor{
		read_cursor = Read_Cursor{
			slot_ptr = Slot_Pointer{
				position = i64(ROOT_HEADER_START),
				slot     = root,
			},
			db        = db,
			frozen_at = 0,
		},
	}
}

// Run `fn` with a write cursor to the root in a single transaction,
// discarding everything it wrote if `fn` returns an error.
database_run_context :: proc(db: ^Database, fn: Context_Function, user_data: rawptr = nil) -> Error {
	rc := database_root_cursor(db)
	_, err := cursor_write_path(&rc, []Path_Part{Context{function = fn, user_data = user_data}})
	return err
}

// Freeze everything written in the current transaction so far.
database_freeze :: proc(db: ^Database) -> Error {
	if db.transaction == nil || db.tx_start == nil {
		return .Expected_Tx_Start
	}
	length := core_length(db.core) or_return
	db.tx_start = length
	db.transaction.frozen_at = length
	return nil
}

@(private)
_database_committed_size_with_header :: proc(db: ^Database, header: Root_Header) -> (committed_size: i64, file_size: i64, err: Error) {
	minimum_size := i64(ROOT_HEADER_END + ROOT_TRAILER_LENGTH)
	if header.file_size < minimum_size {
		return 0, 0, .Invalid_Database
	}
	file_size = core_length(db.core) or_return
	if file_size < header.file_size {
		return 0, 0, .Truncated_Database
	}
	trailer := database_read_root_trailer(db, header.file_size) or_return
	if trailer.root != header.root {
		return 0, 0, .Invalid_Database
	}
	return header.file_size, file_size, nil
}

// Return the number of bytes that belong to committed transactions.
database_committed_size :: proc(db: ^Database) -> (res: i64, err: Error) {
	header := database_read_root_header(db) or_return
	committed_size, _ := _database_committed_size_with_header(db, header) or_return
	return committed_size, nil
}

@(private)
_database_truncate_with_header :: proc(db: ^Database, header: Root_Header) -> (final_size: i64, err: Error) {
	committed_size, file_size := _database_committed_size_with_header(db, header) or_return
	active := db.transaction
	if active != nil {
		if fa, ok := active.frozen_at.?; ok && fa > committed_size {
			if file_size > fa {
				core_set_length(db.core, fa) or_return
			}
			commit_id := _random_u64()
			database_commit_root(db, header.root, commit_id) or_return
			core_sync(db.core) or_return
			return core_length(db.core)
		}
	}
	if file_size > committed_size {
		core_set_length(db.core, committed_size) or_return
	}
	return committed_size, nil
}

database_truncate :: proc(db: ^Database) -> Error {
	header := database_read_root_header(db) or_return
	_, err := _database_truncate_with_header(db, header)
	return err
}

database_read_root_header :: proc(db: ^Database) -> (res: Root_Header, err: Error) {
	b: [ROOT_HEADER_LENGTH]u8
	core_read_exact_at(db.core, ROOT_HEADER_START, b[:]) or_return
	header := root_header_from_bytes(b)
	tag_validate(header.root.tag) or_return
	return header, nil
}

database_read_root_slot :: proc(db: ^Database) -> (res: Slot, err: Error) {
	header := database_read_root_header(db) or_return
	return header.root, nil
}

database_read_root_trailer :: proc(db: ^Database, end: i64) -> (res: Root_Trailer, err: Error) {
	if end < ROOT_TRAILER_LENGTH {
		return {}, .Invalid_Database
	}
	trailer_pos := end - ROOT_TRAILER_LENGTH
	b: [ROOT_TRAILER_LENGTH]u8
	core_read_exact_at(db.core, trailer_pos, b[:]) or_return
	trailer := root_trailer_from_bytes(b)
	if trailer.checksum != compute_root_trailer_checksum(db.header.file_id, trailer_pos, trailer.root, trailer.commit_id) {
		return {}, .Invalid_Database
	}
	tag_validate(trailer.root.tag) or_return
	return trailer, nil
}

database_commit_root :: proc(db: ^Database, root: Slot, commit_id: u64) -> Error {
	trailer_pos := core_length(db.core) or_return
	core_seek_to(db.core, trailer_pos) or_return
	trailer := root_trailer_to_bytes(new_root_trailer(db.header.file_id, trailer_pos, root, commit_id))
	core_write_all(db.core, trailer[:]) or_return
	core_sync(db.core) or_return
	return database_write_root_header(db, root)
}

database_write_root_header :: proc(db: ^Database, root: Slot) -> Error {
	file_size := core_length(db.core) or_return
	core_seek_to(db.core, ROOT_HEADER_START) or_return
	header := root_header_to_bytes(Root_Header{file_size = file_size, root = root})
	core_write_all(db.core, header[:]) or_return
	return core_flush(db.core)
}

is_root :: proc(slot_ptr: Slot_Pointer) -> bool {
	if pos, ok := slot_ptr.position.?; ok {
		return pos == ROOT_HEADER_START
	}
	return false
}

init_tag :: proc(part: Path_Part) -> (res: Tag, err: bool) {
	#partial switch p in part {
	case Array_List_Init:
		return .Array_List, true
	case Linked_Array_List_Init:
		return .Linked_Array_List, true
	case Hash_Map_Init:
		if p.counted {
			return (.Counted_Hash_Set if p.set else .Counted_Hash_Map), true
		}
		return (.Hash_Set if p.set else .Hash_Map), true
	case Sorted_Map_Init:
		return (.Sorted_Set if p.set else .Sorted_Map), true
	}
	return .None, false
}

init_part_for :: proc(tag: Tag) -> (res: Path_Part, err: bool) {
	#partial switch tag {
	case .Array_List:
		return Array_List_Init{}, true
	case .Linked_Array_List:
		return Linked_Array_List_Init{}, true
	case .Hash_Map:
		return Hash_Map_Init{counted = false, set = false}, true
	case .Hash_Set:
		return Hash_Map_Init{counted = false, set = true}, true
	case .Counted_Hash_Map:
		return Hash_Map_Init{counted = true, set = false}, true
	case .Counted_Hash_Set:
		return Hash_Map_Init{counted = true, set = true}, true
	case .Sorted_Map:
		return Sorted_Map_Init{set = false}, true
	case .Sorted_Set:
		return Sorted_Map_Init{set = true}, true
	}
	return nil, false
}

database_is_old :: proc(db: ^Database, ptr, frozen_at: i64) -> (res: bool, err: Error) {
	tx_s, ok := db.tx_start.?
	if !ok {
		return false, .Expected_Tx_Start
	}
	return ptr < max(tx_s, frozen_at), nil
}

database_copy_index_block_if_old :: proc(db: ^Database, ptr, frozen_at: i64) -> (res: i64, err: Error) {
	old := database_is_old(db, ptr, frozen_at) or_return
	if !old {
		return ptr, nil
	}
	index_block: [INDEX_BLOCK_SIZE]u8
	core_read_exact_at(db.core, ptr, index_block[:]) or_return
	next_ptr := core_length(db.core) or_return
	core_seek_to(db.core, next_ptr) or_return
	core_write_all(db.core, index_block[:]) or_return
	return next_ptr, nil
}

database_check_hash :: proc(db: ^Database, h: []u8) -> (res: []u8, err: Error) {
	if len(h) != int(db.header.hash_size) {
		return nil, .Invalid_Hash_Size
	}
	return h, nil
}

database_check_hash_target :: proc(db: ^Database, target: Hash_Map_Get_Target) -> (res: []u8, err: Error) {
	switch t in target {
	case Hash_Map_Get_Value:
		return database_check_hash(db, t.hash)
	case Hash_Map_Get_Key:
		return database_check_hash(db, t.hash)
	case Hash_Map_Get_KV_Pair:
		return database_check_hash(db, t.hash)
	}
	return nil, .Invalid_Hash_Size
}

database_check_frozen_slot :: proc(db: ^Database, slot_ptr: Slot_Pointer) -> Error {
	active := db.transaction
	if active != nil {
		if fa, ok := active.frozen_at.?; ok {
			if pos, pok := slot_ptr.position.?; pok {
				if pos < fa && !transaction_is_root_position(active, slot_ptr.position) {
					return .Frozen_Slot
				}
			}
		}
	}
	return nil
}

database_copy_collection_if_frozen :: proc(db: ^Database, slot_ptr: Slot_Pointer, init_part: Path_Part, frozen_at: i64) -> (res: Slot_Pointer, err: Error) {
	if db.transaction != nil {
		fa := frozen_at
		if tfa, ok := db.transaction.frozen_at.?; ok && tfa > fa {
			fa = tfa
		}
		if fa > 0 && slot_ptr.slot.value < fa {
			return read_slot_pointer(db, .Read_Write, []Path_Part{init_part}, 0, slot_ptr, frozen_at)
		}
	}
	return slot_ptr, nil
}

database_kv_key_offset :: proc(db: ^Database, tag: Tag) -> i64 {
	if tag == .KV_Pair {
		return i64(db.header.hash_size)
	}
	return 0
}

database_kv_key_position :: proc(db: ^Database, entry: Slot) -> Maybe(i64) {
	if is_key_only_entry(entry) {
		return nil
	}
	return entry.value + database_kv_key_offset(db, entry.tag)
}

database_kv_value_position :: proc(db: ^Database, entry: Slot) -> Maybe(i64) {
	if key_pos, ok := database_kv_key_position(db, entry).?; ok {
		return key_pos + SLOT_LENGTH
	}
	return nil
}

// Central path-traversal method.
read_slot_pointer :: proc(
	db: ^Database,
	write_mode: Write_Mode,
	path: []Path_Part,
	path_i: int,
	slot_ptr: Slot_Pointer,
	frozen_at: i64,
) -> (res: Slot_Pointer, err: Error) {
	if path_i == len(path) {
		if write_mode == .Read_Only && slot_empty(slot_ptr.slot) {
			return {}, .Key_Not_Found
		}
		return slot_ptr, nil
	}
	if write_mode == .Read_Write {
		database_check_frozen_slot(db, slot_ptr) or_return
	}
	part := path[path_i]

	// Every write that starts at the root is a transaction.
	if is_root(slot_ptr) {
		root_header := database_read_root_header(db) or_return
		root := root_header.root

		if write_mode == .Read_Only {
			return read_slot_pointer(db, write_mode, path, path_i, Slot_Pointer{position = nil, slot = root}, frozen_at)
		}

		// Initializing an already-initialized root is free.
		if len(path) - path_i == 1 && root.tag != .None {
			if tag, ok := init_tag(part); ok && tag == root.tag {
				_ = _database_truncate_with_header(db, root_header) or_return
				return Slot_Pointer{position = i64(ROOT_HEADER_START), slot = root}, nil
			}
		}

		scratch_pos := _database_truncate_with_header(db, root_header) or_return
		db.tx_start = scratch_pos
		defer db.tx_start = nil

		if db.transaction != nil {
			db.transaction.root_position = scratch_pos
			db.transaction.scratch_position = scratch_pos
		}

		core_seek_to(db.core, scratch_pos) or_return
		core_write_slot(db.core, root) or_return
		root_ptr := Slot_Pointer{position = scratch_pos, slot = root}

		if init_p, ok := init_part_for(root.tag); ok {
			root_ptr = read_slot_pointer(db, write_mode, []Path_Part{init_p}, 0, root_ptr, frozen_at) or_return
		}

		result := read_slot_pointer(db, write_mode, path, path_i, root_ptr, frozen_at) or_return

		next_root := core_read_slot_raw_at(db.core, scratch_pos) or_return
		commit_id := _random_u64()
		database_commit_root(db, next_root, commit_id) or_return

		if rpos, ok := result.position.?; ok && rpos == scratch_pos {
			result = Slot_Pointer{position = i64(ROOT_HEADER_START), slot = next_root}
		}
		return result, nil
	}

	return _exec_path_part(db, part, write_mode, path, path_i, slot_ptr, frozen_at)
}

@(private)
_exec_path_part :: proc(
	db: ^Database,
	part: Path_Part,
	write_mode: Write_Mode,
	path: []Path_Part,
	path_i: int,
	slot_ptr: Slot_Pointer,
	frozen_at: i64,
) -> (res: Slot_Pointer, err: Error) {
	slot_ptr := slot_ptr

	switch p in part {
	case Array_List_Init:
		if write_mode == .Read_Only {
			return {}, .Write_Not_Allowed
		}
		position, pos_ok := slot_ptr.position.?
		if !pos_ok {
			return {}, .Cursor_Not_Writeable
		}
		#partial switch slot_ptr.slot.tag {
		case .None:
			array_list_start := core_length(db.core) or_return
			core_seek_to(db.core, array_list_start) or_return
			array_list_ptr := array_list_start + ARRAY_LIST_HEADER_LENGTH
			al_header := array_list_header_to_bytes(Array_List_Header{ptr = array_list_ptr, size = 0})
			core_write_all(db.core, al_header[:]) or_return
			empty_block: [INDEX_BLOCK_SIZE]u8
			core_write_all(db.core, empty_block[:]) or_return
			next_slot_ptr := Slot_Pointer{
				position = position,
				slot     = Slot{value = array_list_start, tag = .Array_List},
			}
			core_seek_to(db.core, position) or_return
			core_write_slot(db.core, next_slot_ptr.slot) or_return
			return read_slot_pointer(db, write_mode, path, path_i + 1, next_slot_ptr, frozen_at)

		case .Array_List:
			array_list_start := slot_ptr.slot.value
			old := database_is_old(db, array_list_start, frozen_at) or_return
			if old {
				hb: [ARRAY_LIST_HEADER_LENGTH]u8
				core_read_exact_at(db.core, array_list_start, hb[:]) or_return
				header := array_list_header_from_bytes(hb) or_return
				idx_block: [INDEX_BLOCK_SIZE]u8
				core_read_exact_at(db.core, header.ptr, idx_block[:]) or_return
				new_start := core_length(db.core) or_return
				core_seek_to(db.core, new_start) or_return
				next_ptr := new_start + ARRAY_LIST_HEADER_LENGTH
				header = array_list_header_with_ptr(header, next_ptr)
				nhb := array_list_header_to_bytes(header)
				core_write_all(db.core, nhb[:]) or_return
				core_write_all(db.core, idx_block[:]) or_return
				array_list_start = new_start
			}
			next_slot_ptr := Slot_Pointer{
				position = position,
				slot     = Slot{value = array_list_start, tag = .Array_List},
			}
			core_seek_to(db.core, position) or_return
			core_write_slot(db.core, next_slot_ptr.slot) or_return
			return read_slot_pointer(db, write_mode, path, path_i + 1, next_slot_ptr, frozen_at)

		case:
			return {}, .Unexpected_Tag
		}

	case Array_List_Get:
		#partial switch slot_ptr.slot.tag {
		case .None:
			return {}, .Key_Not_Found
		case .Array_List:
		case:
			return {}, .Unexpected_Tag
		}
		if write_mode == .Read_Write {
			slot_ptr = database_copy_collection_if_frozen(db, slot_ptr, Array_List_Init{}, frozen_at) or_return
		}
		next_array_list_start := slot_ptr.slot.value
		index := p.index
		hb: [ARRAY_LIST_HEADER_LENGTH]u8
		core_read_exact_at(db.core, next_array_list_start, hb[:]) or_return
		header := array_list_header_from_bytes(hb) or_return
		if index >= header.size || index < -header.size {
			return {}, .Key_Not_Found
		}
		key := (header.size + index) if index < 0 else index
		shift := radix_shift(header.size - 1)
		final_slot_ptr := read_array_list_slot(db, header.ptr, key, shift, write_mode, frozen_at) or_return
		return read_slot_pointer(db, write_mode, path, path_i + 1, final_slot_ptr, frozen_at)

	case Array_List_Append:
		if write_mode == .Read_Only {
			return {}, .Write_Not_Allowed
		}
		if slot_ptr.slot.tag != .Array_List {
			return {}, .Unexpected_Tag
		}
		slot_ptr = database_copy_collection_if_frozen(db, slot_ptr, Array_List_Init{}, frozen_at) or_return
		next_array_list_start := slot_ptr.slot.value
		hb: [ARRAY_LIST_HEADER_LENGTH]u8
		core_read_exact_at(db.core, next_array_list_start, hb[:]) or_return
		orig_header := array_list_header_from_bytes(hb) or_return
		append_res := read_array_list_slot_append(db, orig_header, write_mode, frozen_at) or_return
		core_seek_to(db.core, next_array_list_start) or_return
		nhb := array_list_header_to_bytes(append_res.header)
		core_write_all(db.core, nhb[:]) or_return
		if db.transaction != nil && transaction_is_scratch_position(db.transaction, slot_ptr.position) {
			db.transaction.root_position = append_res.slot_ptr.position
		}
		return read_slot_pointer(db, write_mode, path, path_i + 1, append_res.slot_ptr, frozen_at)

	case Array_List_Slice:
		if write_mode == .Read_Only {
			return {}, .Write_Not_Allowed
		}
		if slot_ptr.slot.tag != .Array_List {
			return {}, .Unexpected_Tag
		}
		slot_ptr = database_copy_collection_if_frozen(db, slot_ptr, Array_List_Init{}, frozen_at) or_return
		next_array_list_start := slot_ptr.slot.value
		hb: [ARRAY_LIST_HEADER_LENGTH]u8
		core_read_exact_at(db.core, next_array_list_start, hb[:]) or_return
		orig_header := array_list_header_from_bytes(hb) or_return
		slice_header := read_array_list_slice(db, orig_header, p.size, frozen_at) or_return
		core_seek_to(db.core, next_array_list_start) or_return
		nhb := array_list_header_to_bytes(slice_header)
		core_write_all(db.core, nhb[:]) or_return
		return read_slot_pointer(db, write_mode, path, path_i + 1, slot_ptr, frozen_at)

	case Linked_Array_List_Init:
		if write_mode == .Read_Only {
			return {}, .Write_Not_Allowed
		}
		position, pos_ok := slot_ptr.position.?
		if !pos_ok {
			return {}, .Cursor_Not_Writeable
		}
		#partial switch slot_ptr.slot.tag {
		case .None:
			root_ptr := write_btree_node(db, BTree_Node{kind = .Leaf, num = 0}) or_return
			header_ptr := core_length(db.core) or_return
			core_seek_to(db.core, header_ptr) or_return
			hb := btree_header_to_bytes(BTree_Header{root_ptr = root_ptr, size = 0})
			core_write_all(db.core, hb[:]) or_return
			next_slot_ptr := Slot_Pointer{
				position = position,
				slot     = Slot{value = header_ptr, tag = .Linked_Array_List},
			}
			core_seek_to(db.core, position) or_return
			core_write_slot(db.core, next_slot_ptr.slot) or_return
			return read_slot_pointer(db, write_mode, path, path_i + 1, next_slot_ptr, frozen_at)

		case .Linked_Array_List:
			header_ptr := slot_ptr.slot.value
			old := database_is_old(db, header_ptr, frozen_at) or_return
			if old {
				hb: [BTREE_HEADER_LENGTH]u8
				core_read_exact_at(db.core, header_ptr, hb[:]) or_return
				new_ptr := core_length(db.core) or_return
				core_seek_to(db.core, new_ptr) or_return
				core_write_all(db.core, hb[:]) or_return
				header_ptr = new_ptr
			}
			next_slot_ptr := Slot_Pointer{
				position = position,
				slot     = Slot{value = header_ptr, tag = .Linked_Array_List},
			}
			core_seek_to(db.core, position) or_return
			core_write_slot(db.core, next_slot_ptr.slot) or_return
			return read_slot_pointer(db, write_mode, path, path_i + 1, next_slot_ptr, frozen_at)

		case:
			return {}, .Unexpected_Tag
		}

	case Linked_Array_List_Get:
		#partial switch slot_ptr.slot.tag {
		case .None:
			return {}, .Key_Not_Found
		case .Linked_Array_List:
		case:
			return {}, .Unexpected_Tag
		}
		index := p.index
		if write_mode == .Read_Write {
			slot_ptr = database_copy_collection_if_frozen(db, slot_ptr, Linked_Array_List_Init{}, frozen_at) or_return
		}
		header_ptr := slot_ptr.slot.value
		hb: [BTREE_HEADER_LENGTH]u8
		core_read_exact_at(db.core, header_ptr, hb[:]) or_return
		header := btree_header_from_bytes(hb) or_return
		if index >= header.size || index < -header.size {
			return {}, .Key_Not_Found
		}
		rank := (header.size + index) if index < 0 else index
		if write_mode == .Read_Only {
			final_slot_ptr := read_btree_slot(db, header.root_ptr, rank) or_return
			return read_slot_pointer(db, write_mode, path, path_i + 1, final_slot_ptr, frozen_at)
		}
		write_slot := btree_get_for_write(db, header.root_ptr, rank, frozen_at) or_return
		if write_slot.node_ptr != header.root_ptr {
			core_seek_to(db.core, header_ptr) or_return
			nhb := btree_header_to_bytes(BTree_Header{root_ptr = write_slot.node_ptr, size = header.size})
			core_write_all(db.core, nhb[:]) or_return
		}
		return read_slot_pointer(db, write_mode, path, path_i + 1, Slot_Pointer{position = write_slot.value_position, slot = write_slot.slot}, frozen_at)

	case Linked_Array_List_Append:
		if write_mode == .Read_Only {
			return {}, .Write_Not_Allowed
		}
		if slot_ptr.slot.tag != .Linked_Array_List {
			return {}, .Unexpected_Tag
		}
		slot_ptr = database_copy_collection_if_frozen(db, slot_ptr, Linked_Array_List_Init{}, frozen_at) or_return
		header_ptr := slot_ptr.slot.value
		hb: [BTREE_HEADER_LENGTH]u8
		core_read_exact_at(db.core, header_ptr, hb[:]) or_return
		header := btree_header_from_bytes(hb) or_return
		res := btree_insert(db, header.root_ptr, header.size, frozen_at) or_return
		new_root_ptr := btree_grow_root(db, res) or_return
		core_seek_to(db.core, header_ptr) or_return
		nhb := btree_header_to_bytes(BTree_Header{root_ptr = new_root_ptr, size = header.size + 1})
		core_write_all(db.core, nhb[:]) or_return
		return read_slot_pointer(db, write_mode, path, path_i + 1, Slot_Pointer{position = res.value_position, slot = Slot{}}, frozen_at)

	case Linked_Array_List_Slice:
		if write_mode == .Read_Only {
			return {}, .Write_Not_Allowed
		}
		if slot_ptr.slot.tag != .Linked_Array_List {
			return {}, .Unexpected_Tag
		}
		slot_ptr = database_copy_collection_if_frozen(db, slot_ptr, Linked_Array_List_Init{}, frozen_at) or_return
		header_ptr := slot_ptr.slot.value
		hb: [BTREE_HEADER_LENGTH]u8
		core_read_exact_at(db.core, header_ptr, hb[:]) or_return
		header := btree_header_from_bytes(hb) or_return
		if p.offset < 0 || p.size < 0 || p.offset > header.size || p.size > header.size - p.offset {
			return {}, .Key_Not_Found
		}
		new_root_ptr: i64
		if p.size == 0 {
			new_root_ptr = btree_new_root(db) or_return
		} else {
			after_offset := btree_split_right(db, header.root_ptr, p.offset) or_return
			if p.size == header.size - p.offset {
				new_root_ptr = after_offset
			} else {
				new_root_ptr = btree_split_left(db, after_offset, p.size) or_return
			}
		}
		core_seek_to(db.core, header_ptr) or_return
		nhb := btree_header_to_bytes(BTree_Header{root_ptr = new_root_ptr, size = p.size})
		core_write_all(db.core, nhb[:]) or_return
		return read_slot_pointer(db, write_mode, path, path_i + 1, slot_ptr, frozen_at)

	case Linked_Array_List_Concat:
		if write_mode == .Read_Only {
			return {}, .Write_Not_Allowed
		}
		if slot_ptr.slot.tag != .Linked_Array_List || p.list.tag != .Linked_Array_List {
			return {}, .Unexpected_Tag
		}
		slot_ptr = database_copy_collection_if_frozen(db, slot_ptr, Linked_Array_List_Init{}, frozen_at) or_return
		header_ptr := slot_ptr.slot.value
		hba: [BTREE_HEADER_LENGTH]u8
		core_read_exact_at(db.core, header_ptr, hba[:]) or_return
		header_a := btree_header_from_bytes(hba) or_return

		hbb: [BTREE_HEADER_LENGTH]u8
		core_read_exact_at(db.core, p.list.value, hbb[:]) or_return
		header_b := btree_header_from_bytes(hbb) or_return

		tx_s := core_length(db.core) or_return
		db.tx_start = tx_s
		new_root_ptr := btree_join(db, header_a.root_ptr, header_b.root_ptr) or_return
		core_seek_to(db.core, header_ptr) or_return
		nhb := btree_header_to_bytes(BTree_Header{root_ptr = new_root_ptr, size = header_a.size + header_b.size})
		core_write_all(db.core, nhb[:]) or_return
		return read_slot_pointer(db, write_mode, path, path_i + 1, slot_ptr, frozen_at)

	case Linked_Array_List_Insert:
		if write_mode == .Read_Only {
			return {}, .Write_Not_Allowed
		}
		if slot_ptr.slot.tag != .Linked_Array_List {
			return {}, .Unexpected_Tag
		}
		slot_ptr = database_copy_collection_if_frozen(db, slot_ptr, Linked_Array_List_Init{}, frozen_at) or_return
		header_ptr := slot_ptr.slot.value
		hb: [BTREE_HEADER_LENGTH]u8
		core_read_exact_at(db.core, header_ptr, hb[:]) or_return
		header := btree_header_from_bytes(hb) or_return
		index := p.index
		if index >= header.size || index < -header.size {
			return {}, .Key_Not_Found
		}
		rank := (header.size + index) if index < 0 else index
		res := btree_insert(db, header.root_ptr, rank, frozen_at) or_return
		new_root_ptr := btree_grow_root(db, res) or_return
		core_seek_to(db.core, header_ptr) or_return
		nhb := btree_header_to_bytes(BTree_Header{root_ptr = new_root_ptr, size = header.size + 1})
		core_write_all(db.core, nhb[:]) or_return
		return read_slot_pointer(db, write_mode, path, path_i + 1, Slot_Pointer{position = res.value_position, slot = Slot{}}, frozen_at)

	case Linked_Array_List_Remove:
		if write_mode == .Read_Only {
			return {}, .Write_Not_Allowed
		}
		if slot_ptr.slot.tag != .Linked_Array_List {
			return {}, .Unexpected_Tag
		}
		slot_ptr = database_copy_collection_if_frozen(db, slot_ptr, Linked_Array_List_Init{}, frozen_at) or_return
		header_ptr := slot_ptr.slot.value
		hb: [BTREE_HEADER_LENGTH]u8
		core_read_exact_at(db.core, header_ptr, hb[:]) or_return
		header := btree_header_from_bytes(hb) or_return
		index := p.index
		if index >= header.size || index < -header.size {
			return {}, .Key_Not_Found
		}
		rank := (header.size + index) if index < 0 else index
		new_root_ptr: i64
		if header.size == 1 {
			new_root_ptr = btree_new_root(db) or_return
		} else {
			root_res := btree_remove(db, header.root_ptr, rank, frozen_at, true) or_return
			if root_res.kind == .Branch && root_res.num == 1 {
				root := root_res.node
				if root_res.persisted {
					root = read_btree_node(db, root_res.node_ptr) or_return
				}
				for root.kind == .Branch && root.num == 1 {
					new_root_ptr = root.children[0].value
					root = read_btree_node(db, new_root_ptr) or_return
				}
			} else if root_res.persisted {
				new_root_ptr = root_res.node_ptr
			} else {
				new_root_ptr = btree_write_node(db, root_res.node, header.root_ptr, frozen_at) or_return
			}
		}
		core_seek_to(db.core, header_ptr) or_return
		nhb := btree_header_to_bytes(BTree_Header{root_ptr = new_root_ptr, size = header.size - 1})
		core_write_all(db.core, nhb[:]) or_return
		return read_slot_pointer(db, write_mode, path, path_i + 1, slot_ptr, frozen_at)

	case Hash_Map_Init:
		if write_mode == .Read_Only {
			return {}, .Write_Not_Allowed
		}
		tag: Tag
		if p.counted {
			tag = .Counted_Hash_Set if p.set else .Counted_Hash_Map
		} else {
			tag = .Hash_Set if p.set else .Hash_Map
		}
		position, pos_ok := slot_ptr.position.?
		if !pos_ok {
			return {}, .Cursor_Not_Writeable
		}
		#partial switch slot_ptr.slot.tag {
		case .None:
			map_start := core_length(db.core) or_return
			core_seek_to(db.core, map_start) or_return
			if p.counted {
				core_write_long(db.core, 0) or_return
			}
			empty_block: [INDEX_BLOCK_SIZE]u8
			core_write_all(db.core, empty_block[:]) or_return
			next_slot_ptr := Slot_Pointer{
				position = position,
				slot     = Slot{value = map_start, tag = tag},
			}
			core_seek_to(db.core, position) or_return
			core_write_slot(db.core, next_slot_ptr.slot) or_return
			return read_slot_pointer(db, write_mode, path, path_i + 1, next_slot_ptr, frozen_at)

		case .Hash_Map, .Hash_Set, .Counted_Hash_Map, .Counted_Hash_Set:
			if p.counted {
				#partial switch slot_ptr.slot.tag {
				case .Counted_Hash_Map, .Counted_Hash_Set:
				case:
					return {}, .Unexpected_Tag
				}
			} else {
				#partial switch slot_ptr.slot.tag {
				case .Hash_Map, .Hash_Set:
				case:
					return {}, .Unexpected_Tag
				}
			}
			map_start := slot_ptr.slot.value
			old := database_is_old(db, map_start, frozen_at) or_return
			if old {
				map_count: i64 = 0
				block_pos := map_start
				if p.counted {
					map_count = core_read_long_at(db.core, map_start) or_return
					block_pos += 8
				}
				idx_block: [INDEX_BLOCK_SIZE]u8
				core_read_exact_at(db.core, block_pos, idx_block[:]) or_return
				new_start := core_length(db.core) or_return
				core_seek_to(db.core, new_start) or_return
				if p.counted {
					core_write_long(db.core, map_count) or_return
				}
				core_write_all(db.core, idx_block[:]) or_return
				map_start = new_start
			}
			next_slot_ptr := Slot_Pointer{
				position = position,
				slot     = Slot{value = map_start, tag = tag},
			}
			core_seek_to(db.core, position) or_return
			core_write_slot(db.core, next_slot_ptr.slot) or_return
			return read_slot_pointer(db, write_mode, path, path_i + 1, next_slot_ptr, frozen_at)

		case:
			return {}, .Unexpected_Tag
		}

	case Hash_Map_Get:
		counted := false
		#partial switch slot_ptr.slot.tag {
		case .None:
			return {}, .Key_Not_Found
		case .Hash_Map, .Hash_Set:
		case .Counted_Hash_Map, .Counted_Hash_Set:
			counted = true
		case:
			return {}, .Unexpected_Tag
		}
		if write_mode == .Read_Write {
			is_set := slot_ptr.slot.tag == .Hash_Set || slot_ptr.slot.tag == .Counted_Hash_Set
			slot_ptr = database_copy_collection_if_frozen(db, slot_ptr, Hash_Map_Init{counted = counted, set = is_set}, frozen_at) or_return
		}
		index_pos := (slot_ptr.slot.value + 8) if counted else slot_ptr.slot.value
		key_hash := database_check_hash_target(db, p.target) or_return
		res := read_map_slot(db, index_pos, key_hash, 0, write_mode, p.target, frozen_at) or_return
		if write_mode == .Read_Write && counted && res.is_empty {
			map_count := core_read_long_at(db.core, slot_ptr.slot.value) or_return
			core_seek_to(db.core, slot_ptr.slot.value) or_return
			core_write_long(db.core, map_count + 1) or_return
		}
		next_sp := res.slot_ptr
		if write_mode == .Read_Write && res.is_empty && next_sp.slot.tag == .KV_Pair {
			next_sp.slot.full = true
		}
		return read_slot_pointer(db, write_mode, path, path_i + 1, next_sp, frozen_at)

	case Hash_Map_Remove:
		if write_mode == .Read_Only {
			return {}, .Write_Not_Allowed
		}
		counted := false
		#partial switch slot_ptr.slot.tag {
		case .None:
			return {}, .Key_Not_Found
		case .Hash_Map, .Hash_Set:
		case .Counted_Hash_Map, .Counted_Hash_Set:
			counted = true
		case:
			return {}, .Unexpected_Tag
		}
		is_set := slot_ptr.slot.tag == .Hash_Set || slot_ptr.slot.tag == .Counted_Hash_Set
		slot_ptr = database_copy_collection_if_frozen(db, slot_ptr, Hash_Map_Init{counted = counted, set = is_set}, frozen_at) or_return
		index_pos := (slot_ptr.slot.value + 8) if counted else slot_ptr.slot.value
		key_hash := database_check_hash(db, p.hash) or_return
		key_found := true
		_, rem_err := remove_map_slot(db, index_pos, key_hash, 0, frozen_at)
		if rem_err != nil {
			if rem_err == .Key_Not_Found {
				key_found = false
			} else {
				return {}, rem_err
			}
		}
		if write_mode == .Read_Write && counted && key_found {
			map_count := core_read_long_at(db.core, slot_ptr.slot.value) or_return
			core_seek_to(db.core, slot_ptr.slot.value) or_return
			core_write_long(db.core, map_count - 1) or_return
		}
		if !key_found {
			return {}, .Key_Not_Found
		}
		return slot_ptr, nil

	case Sorted_Map_Init:
		if write_mode == .Read_Only {
			return {}, .Write_Not_Allowed
		}
		position, pos_ok := slot_ptr.position.?
		if !pos_ok {
			return {}, .Cursor_Not_Writeable
		}
		tag: Tag = .Sorted_Set if p.set else .Sorted_Map
		#partial switch slot_ptr.slot.tag {
		case .None:
			root_ptr := write_sorted_node(db, Sorted_Node{kind = .Leaf, num = 0}) or_return
			header_ptr := core_length(db.core) or_return
			core_seek_to(db.core, header_ptr) or_return
			hb := btree_header_to_bytes(BTree_Header{root_ptr = root_ptr, size = 0})
			core_write_all(db.core, hb[:]) or_return
			next_slot_ptr := Slot_Pointer{
				position = position,
				slot     = Slot{value = header_ptr, tag = tag},
			}
			core_seek_to(db.core, position) or_return
			core_write_slot(db.core, next_slot_ptr.slot) or_return
			return read_slot_pointer(db, write_mode, path, path_i + 1, next_slot_ptr, frozen_at)

		case .Sorted_Map, .Sorted_Set:
			header_ptr := slot_ptr.slot.value
			old := database_is_old(db, header_ptr, frozen_at) or_return
			if old {
				hb: [BTREE_HEADER_LENGTH]u8
				core_read_exact_at(db.core, header_ptr, hb[:]) or_return
				new_ptr := core_length(db.core) or_return
				core_seek_to(db.core, new_ptr) or_return
				core_write_all(db.core, hb[:]) or_return
				header_ptr = new_ptr
			}
			next_slot_ptr := Slot_Pointer{
				position = position,
				slot     = Slot{value = header_ptr, tag = tag},
			}
			core_seek_to(db.core, position) or_return
			core_write_slot(db.core, next_slot_ptr.slot) or_return
			return read_slot_pointer(db, write_mode, path, path_i + 1, next_slot_ptr, frozen_at)

		case:
			return {}, .Unexpected_Tag
		}

	case Sorted_Map_Get:
		#partial switch slot_ptr.slot.tag {
		case .None:
			return {}, .Key_Not_Found
		case .Sorted_Map, .Sorted_Set:
		case:
			return {}, .Unexpected_Tag
		}
		key: []u8
		switch t in p.target {
		case Sorted_Map_Get_Value:
			key = t.key
		case Sorted_Map_Get_Key:
			key = t.key
		case Sorted_Map_Get_KV_Pair:
			key = t.key
		}
		if write_mode == .Read_Write {
			slot_ptr = database_copy_collection_if_frozen(db, slot_ptr, Sorted_Map_Init{set = slot_ptr.slot.tag == .Sorted_Set}, frozen_at) or_return
		}
		header_ptr := slot_ptr.slot.value
		hb: [BTREE_HEADER_LENGTH]u8
		core_read_exact_at(db.core, header_ptr, hb[:]) or_return
		header := btree_header_from_bytes(hb) or_return

		if write_mode == .Read_Only {
			found_maybe := sorted_get(db, header.root_ptr, key) or_return
			found, has_found := found_maybe.?
			if !has_found {
				return {}, .Key_Not_Found
			}
			target_slot: Slot_Pointer
			if _, is_key := p.target.(Sorted_Map_Get_Key); is_key {
				target_slot = Slot_Pointer{position = nil, slot = found.key_slot}
			} else {
				target_slot = sorted_target_slot(db, found.slot, p.target) or_return
			}
			return read_slot_pointer(db, write_mode, path, path_i + 1, target_slot, frozen_at)
		}

		_, is_key_target := p.target.(Sorted_Map_Get_Key)
		key_only := slot_ptr.slot.tag == .Sorted_Set && is_key_target
		res := sorted_put(db, header.root_ptr, key, key_only, frozen_at) or_return
		new_root_ptr := sorted_grow_root(db, res) or_return
		if new_root_ptr != header.root_ptr || res.added {
			core_seek_to(db.core, header_ptr) or_return
			new_size := header.size + (1 if res.added else 0)
			nhb := btree_header_to_bytes(BTree_Header{root_ptr = new_root_ptr, size = new_size})
			core_write_all(db.core, nhb[:]) or_return
		}
		target_slot: Slot_Pointer
		if _, is_val := p.target.(Sorted_Map_Get_Value); is_val && res.added {
			target_slot = Slot_Pointer{position = res.entry.value + SLOT_LENGTH, slot = Slot{}}
		} else {
			target_slot = sorted_target_slot(db, res.entry, p.target) or_return
		}
		return read_slot_pointer(db, write_mode, path, path_i + 1, target_slot, frozen_at)

	case Sorted_Map_Get_Index:
		if write_mode == .Read_Write {
			return {}, .Write_Not_Allowed
		}
		#partial switch slot_ptr.slot.tag {
		case .None:
			return {}, .Key_Not_Found
		case .Sorted_Map, .Sorted_Set:
		case:
			return {}, .Unexpected_Tag
		}
		header_ptr := slot_ptr.slot.value
		hb: [BTREE_HEADER_LENGTH]u8
		core_read_exact_at(db.core, header_ptr, hb[:]) or_return
		header := btree_header_from_bytes(hb) or_return
		index := p.index
		if index >= header.size || index < -header.size {
			return {}, .Key_Not_Found
		}
		rank := (header.size + index) if index < 0 else index
		found := sorted_get_by_index(db, header.root_ptr, rank) or_return
		target_slot := Slot_Pointer{position = found.position, slot = found.slot}
		return read_slot_pointer(db, write_mode, path, path_i + 1, target_slot, frozen_at)

	case Sorted_Map_Remove:
		if write_mode == .Read_Only {
			return {}, .Write_Not_Allowed
		}
		#partial switch slot_ptr.slot.tag {
		case .None:
			return {}, .Key_Not_Found
		case .Sorted_Map, .Sorted_Set:
		case:
			return {}, .Unexpected_Tag
		}
		slot_ptr = database_copy_collection_if_frozen(db, slot_ptr, Sorted_Map_Init{set = slot_ptr.slot.tag == .Sorted_Set}, frozen_at) or_return
		header_ptr := slot_ptr.slot.value
		hb: [BTREE_HEADER_LENGTH]u8
		core_read_exact_at(db.core, header_ptr, hb[:]) or_return
		header := btree_header_from_bytes(hb) or_return
		res := sorted_remove(db, header.root_ptr, p.key, frozen_at) or_return
		if !res.found {
			return {}, .Key_Not_Found
		}
		core_seek_to(db.core, header_ptr) or_return
		nhb := btree_header_to_bytes(BTree_Header{root_ptr = res.node_ptr, size = header.size - 1})
		core_write_all(db.core, nhb[:]) or_return
		return slot_ptr, nil

	case Write_Data:
		if write_mode == .Read_Only {
			return {}, .Write_Not_Allowed
		}
		position, pos_ok := slot_ptr.position.?
		if !pos_ok {
			return {}, .Cursor_Not_Writeable
		}
		if p.if_empty && !slot_empty(slot_ptr.slot) {
			return read_slot_pointer(db, write_mode, path, path_i + 1, slot_ptr, frozen_at)
		}

		slot := _encode_writeable_data(db, slot_ptr, p.data) or_return

		core_seek_to(db.core, position) or_return
		core_write_slot(db.core, slot) or_return
		next_slot_ptr := Slot_Pointer{position = slot_ptr.position, slot = slot}
		return read_slot_pointer(db, write_mode, path, path_i + 1, next_slot_ptr, frozen_at)

	case Write_KV_Data:
		if write_mode == .Read_Only {
			return {}, .Write_Not_Allowed
		}
		kv_pos := slot_ptr.slot.value
		key_slot_pos := kv_pos + database_kv_key_offset(db, slot_ptr.slot.tag)
		val_slot_pos := key_slot_pos + SLOT_LENGTH

		if slot_ptr.slot.full {
			if val_slot, val_inline, val_err := _try_encode_inline_data(p.value); val_err != nil {
				return {}, val_err
			} else if val_inline {
				if key_bytes, is_kbytes := _extract_bytes_data(p.key); is_kbytes && !bytes_is_short(key_bytes) {
					if key_bytes.format_tag != nil && len(key_bytes.format_tag) != 2 {
						return {}, .Invalid_Format_Tag_Size
					}
					if db.tx_start == nil {
						return {}, .Expected_Tx_Start
					}
					cur_len := core_length(db.core) or_return
					has_ft := key_bytes.format_tag != nil
					key_payload_len := 8 + len(key_bytes.value) + (2 if has_ft else 0)
					if cur_len == val_slot_pos + SLOT_LENGTH && key_payload_len <= 238 {
						key_slot := Slot{value = cur_len, tag = .Bytes, full = has_ft}
						combined_buf: [256]u8 = ---
						out_kb := slot_to_bytes(key_slot)
						out_vb := slot_to_bytes(val_slot)
						copy(combined_buf[0:SLOT_LENGTH], out_kb[:])
						copy(combined_buf[SLOT_LENGTH : SLOT_LENGTH * 2], out_vb[:])
						endian.unchecked_put_u64be(combined_buf[18:26], u64(len(key_bytes.value)))
						copy(combined_buf[26 : 26 + len(key_bytes.value)], key_bytes.value)
						if has_ft {
							copy(combined_buf[26 + len(key_bytes.value) : 18 + key_payload_len], key_bytes.format_tag)
						}
						core_seek_to(db.core, key_slot_pos) or_return
						core_write_all(db.core, combined_buf[:18 + key_payload_len]) or_return
						clean_sp := Slot_Pointer{position = slot_ptr.position, slot = slot_with_full(slot_ptr.slot, false)}
						return read_slot_pointer(db, write_mode, path, path_i + 1, clean_sp, frozen_at)
					}
				}
			}
			key_slot := _encode_writeable_data(db, Slot_Pointer{position = key_slot_pos, slot = Slot{}}, p.key) or_return
			val_slot := _encode_writeable_data(db, Slot_Pointer{position = val_slot_pos, slot = Slot{}}, p.value) or_return
			slots_buf: [SLOT_LENGTH * 2]u8 = ---
			out_kb := slot_to_bytes(key_slot)
			out_vb := slot_to_bytes(val_slot)
			copy(slots_buf[:SLOT_LENGTH], out_kb[:])
			copy(slots_buf[SLOT_LENGTH:], out_vb[:])
			core_seek_to(db.core, key_slot_pos) or_return
			core_write_all(db.core, slots_buf[:]) or_return
		} else {
			val_slot := _encode_writeable_data(db, Slot_Pointer{position = val_slot_pos, slot = Slot{}}, p.value) or_return
			core_seek_to(db.core, val_slot_pos) or_return
			core_write_slot(db.core, val_slot) or_return
		}
		clean_sp := Slot_Pointer{position = slot_ptr.position, slot = slot_with_full(slot_ptr.slot, false)}
		return read_slot_pointer(db, write_mode, path, path_i + 1, clean_sp, frozen_at)

	case Context:
		if write_mode == .Read_Only {
			return {}, .Write_Not_Allowed
		}
		if path_i != len(path) - 1 {
			return {}, .Path_Part_Must_Be_At_End
		}
		clean_sp := slot_ptr
		if clean_sp.slot.tag == .KV_Pair && clean_sp.slot.full {
			clean_sp.slot.full = false
		}
		next_cursor := new_write_cursor(clean_sp, db)
		next_cursor.frozen_at = frozen_at
		if p.function != nil {
			p.function(&next_cursor, p.user_data) or_return
		}
		return next_cursor.slot_ptr, nil
	}

	return {}, .Unreachable
}

@(private)
_extract_bytes_data :: #force_inline proc(write_data: Writeable_Data) -> (b: Bytes, ok: bool) {
	#partial switch data in write_data {
	case string:
		return Bytes{value = transmute([]u8)data}, true
	case []u8:
		return Bytes{value = data}, true
	case Bytes:
		return data, true
	}
	return {}, false
}

@(private)
_try_encode_inline_data :: #force_inline proc(write_data: Writeable_Data) -> (slot: Slot, is_inline: bool, err: Error) {
	switch data in write_data {
	case nil:
		return Slot{full = true}, true, nil
	case Slot:
		if data.tag == .None {
			return slot_with_full(data, true), true, nil
		}
		return data, true, nil
	case Uint:
		return Slot{value = i64(data.value), tag = .Uint}, true, nil
	case u64:
		return Slot{value = i64(data), tag = .Uint}, true, nil
	case Int:
		return Slot{value = data.value, tag = .Int}, true, nil
	case i64:
		return Slot{value = data, tag = .Int}, true, nil
	case Float:
		return Slot{value = transmute(i64)data.value, tag = .Float}, true, nil
	case f64:
		return Slot{value = transmute(i64)data, tag = .Float}, true, nil
	case string:
		b := Bytes{value = transmute([]u8)data}
		if bytes_is_short(b) {
			buf: [8]u8
			copy(buf[:], b.value)
			return Slot{value = i64(endian.unchecked_get_u64be(buf[:])), tag = .Short_Bytes}, true, nil
		}
		return {}, false, nil
	case []u8:
		b := Bytes{value = data}
		if bytes_is_short(b) {
			buf: [8]u8
			copy(buf[:], b.value)
			return Slot{value = i64(endian.unchecked_get_u64be(buf[:])), tag = .Short_Bytes}, true, nil
		}
		return {}, false, nil
	case Bytes:
		if data.format_tag != nil && len(data.format_tag) != 2 {
			return {}, false, .Invalid_Format_Tag_Size
		}
		if bytes_is_short(data) {
			buf: [8]u8
			copy(buf[:], data.value)
			if data.format_tag != nil {
				copy(buf[6:8], data.format_tag)
			}
			return Slot{value = i64(endian.unchecked_get_u64be(buf[:])), tag = .Short_Bytes, full = data.format_tag != nil}, true, nil
		}
		return {}, false, nil
	}
	return {}, false, nil
}

@(private)
_encode_writeable_data :: proc(db: ^Database, slot_ptr: Slot_Pointer, write_data: Writeable_Data) -> (slot: Slot, err: Error) {
	switch data in write_data {
	case nil:
		slot = Slot{}
	case Slot:
		slot = data
	case Uint:
		slot = Slot{value = i64(data.value), tag = .Uint}
	case u64:
		slot = Slot{value = i64(data), tag = .Uint}
	case Int:
		slot = Slot{value = data.value, tag = .Int}
	case i64:
		slot = Slot{value = data, tag = .Int}
	case Float:
		slot = Slot{value = transmute(i64)data.value, tag = .Float}
	case f64:
		slot = Slot{value = transmute(i64)data, tag = .Float}
	case string:
		slot = _encode_bytes_slot(db, slot_ptr, Bytes{value = transmute([]u8)data}) or_return
	case []u8:
		slot = _encode_bytes_slot(db, slot_ptr, Bytes{value = data}) or_return
	case Bytes:
		slot = _encode_bytes_slot(db, slot_ptr, data) or_return
	}

	if slot.tag == .None {
		slot = slot_with_full(slot, true)
	}
	return slot, nil
}

@(private)
_encode_bytes_slot :: proc(db: ^Database, slot_ptr: Slot_Pointer, data: Bytes) -> (res: Slot, err: Error) {
	if data.format_tag != nil && len(data.format_tag) != 2 {
		return {}, .Invalid_Format_Tag_Size
	}
	if bytes_is_short(data) {
		buf: [8]u8
		copy(buf[:], data.value)
		if data.format_tag != nil {
			copy(buf[6:8], data.format_tag)
		}
		uval := endian.unchecked_get_u64be(buf[:])
		return Slot{
			value = i64(uval),
			tag   = .Short_Bytes,
			full  = data.format_tag != nil,
		}, nil
	}
	if is_root(slot_ptr) {
		return {}, .Cursor_Not_Writeable
	}
	if db.tx_start == nil {
		return {}, .Expected_Tx_Start
	}
	ptr_pos := core_length(db.core) or_return
	core_seek_to(db.core, ptr_pos) or_return
	has_ft := data.format_tag != nil
	total_len := 8 + len(data.value) + (2 if has_ft else 0)
	if total_len <= 256 {
		buf: [256]u8 = ---
		endian.unchecked_put_u64be(buf[0:8], u64(len(data.value)))
		copy(buf[8 : 8 + len(data.value)], data.value)
		if has_ft {
			copy(buf[8 + len(data.value) : total_len], data.format_tag)
		}
		core_write_all(db.core, buf[:total_len]) or_return
	} else {
		core_write_long(db.core, i64(len(data.value))) or_return
		core_write_all(db.core, data.value) or_return
		if has_ft {
			core_write_all(db.core, data.format_tag) or_return
		}
	}
	return Slot{
		value = ptr_pos,
		tag   = .Bytes,
		full  = has_ft,
	}, nil
}
