package xitdb

import "base:intrinsics"
import "core:encoding/endian"
import "core:io"

Read_Cursor :: struct {
	slot_ptr:  Slot_Pointer,
	db:        ^Database,
	frozen_at: i64,
}

Write_Cursor :: struct {
	using read_cursor: Read_Cursor,
	transaction:       ^Transaction,
}

Read_KV_Pair_Cursor :: struct {
	value_cursor: Read_Cursor,
	key_cursor:   Read_Cursor,
	hash:         []u8,
}

Write_KV_Pair_Cursor :: struct {
	value_cursor: Write_Cursor,
	key_cursor:   Write_Cursor,
	hash:         []u8,
}

new_write_cursor :: proc(slot_ptr: Slot_Pointer, db: ^Database) -> Write_Cursor {
	c := Write_Cursor{
		read_cursor = Read_Cursor{
			slot_ptr  = slot_ptr,
			db        = db,
			frozen_at = 0,
		},
	}
	if slot_ptr.position != nil && !is_root(slot_ptr) {
		c.transaction = db.transaction
	}
	return c
}

cursor_read_only :: proc(c: Write_Cursor) -> Read_Cursor {
	return c.read_cursor
}

cursor_resolved :: proc(c: Read_Cursor) -> (res: Slot_Pointer, err: Error) {
	if is_root(c.slot_ptr) {
		header := database_read_root_header(c.db) or_return
		if header.file_size < ROOT_TRAILER_LENGTH {
			return {}, .Invalid_Database
		}
		position := header.file_size - ROOT_TRAILER_LENGTH
		return Slot_Pointer{position = position, slot = header.root}, nil
	}
	return c.slot_ptr, nil
}

cursor_resolved_cursor :: proc(c: Read_Cursor) -> (res: Read_Cursor, err: Error) {
	slot_ptr := cursor_resolved(c) or_return
	return Read_Cursor{slot_ptr = slot_ptr, db = c.db, frozen_at = c.frozen_at}, nil
}

cursor_slot :: proc(c: Read_Cursor) -> (res: Slot, err: Error) {
	slot_ptr := cursor_resolved(c) or_return
	return slot_ptr.slot, nil
}

cursor_read_path :: proc(c: Read_Cursor, path: []Path_Part) -> (res: Maybe(Read_Cursor), err: Error) {
	start := cursor_resolved(c) or_return
	slot_ptr: Slot_Pointer
	slot_ptr, err = read_slot_pointer(c.db, .Read_Only, path, 0, start, 0)
	if err != nil {
		if err == .Key_Not_Found {
			return nil, nil
		}
		return nil, err
	}
	return Read_Cursor{slot_ptr = slot_ptr, db = c.db}, nil
}

cursor_read_path_slot :: proc(c: Read_Cursor, path: []Path_Part) -> (res: Maybe(Slot), err: Error) {
	start := cursor_resolved(c) or_return
	slot_ptr: Slot_Pointer
	slot_ptr, err = read_slot_pointer(c.db, .Read_Only, path, 0, start, 0)
	if err != nil {
		if err == .Key_Not_Found {
			return nil, nil
		}
		return nil, err
	}
	if !slot_empty(slot_ptr.slot) {
		return slot_ptr.slot, nil
	}
	return nil, nil
}

cursor_check_writable :: proc(c: ^Write_Cursor) -> Error {
	if c.transaction != nil && c.transaction != c.db.transaction {
		return .Expired_Transaction
	}
	if !is_root(c.slot_ptr) && c.transaction == nil && c.db.tx_start == nil {
		return .Expected_Tx_Start
	}
	return database_check_frozen_slot(c.db, c.slot_ptr)
}

cursor_reload_slot :: proc(c: ^Write_Cursor) -> Error {
	if (c.transaction != nil || c.db.tx_start != nil) && !is_root(c.slot_ptr) {
		if pos, ok := c.slot_ptr.position.?; ok {
			slot := core_read_slot_at(c.db.core, pos) or_return
			c.slot_ptr = slot_pointer_with_slot(c.slot_ptr, slot)
		}
	}
	return nil
}

cursor_write_path :: proc(c: ^Write_Cursor, path: []Path_Part) -> (res: Write_Cursor, err: Error) {
	cursor_check_writable(c) or_return
	if (c.db.transaction != nil || c.db.tx_start != nil) && is_root(c.slot_ptr) && len(path) > 0 {
		return {}, .Nested_Top_Level_Write
	}

	tx_stack: Transaction
	starts_transaction := c.db.transaction == nil && is_root(c.slot_ptr)
	if starts_transaction {
		c.db.transaction = &tx_stack
	}
	defer if starts_transaction {
		c.db.transaction = nil
	}

	err = nil
	switch c.slot_ptr.slot.tag {
	case .Array_List, .Linked_Array_List, .Hash_Map, .Hash_Set, .Counted_Hash_Map, .Counted_Hash_Set, .Sorted_Map, .Sorted_Set:
		is_init := false
		if len(path) > 0 {
			_, is_init = init_tag(path[0])
		}
		if is_init || (c.db.transaction != nil && (c.db.transaction.frozen_at != nil || c.frozen_at != 0)) {
			err = cursor_reload_slot(c)
		}
	case .None, .Index, .Bytes, .Short_Bytes, .Uint, .Int, .Float, .KV_Pair, .Sorted_KV_Pair:
		err = cursor_reload_slot(c)
	}
	slot_ptr: Slot_Pointer
	if err == nil {
		slot_ptr, err = read_slot_pointer(c.db, .Read_Write, path, 0, c.slot_ptr, c.frozen_at)
	}
	if err != nil {
		if c.db.tx_start == nil {
			_ = database_truncate(c.db)
		}
		return {}, err
	}
	if c.db.tx_start == nil {
		core_sync(c.db.core) or_return
	}
	ends_with_ctx := false
	if len(path) > 0 {
		_, ends_with_ctx = path[len(path) - 1].(Context)
	}
	res = new_write_cursor(slot_ptr, c.db)
	res.frozen_at = c.frozen_at
	if ends_with_ctx {
		cursor_reload_slot(c) or_return
		cursor_reload_slot(&res) or_return
	} else if c.slot_ptr.position != nil && c.slot_ptr.position == slot_ptr.position {
		c.slot_ptr = slot_ptr
	} else if c.db.transaction == nil || c.db.transaction.frozen_at != nil || c.frozen_at != 0 || c.slot_ptr.slot.tag == .None {
		cursor_reload_slot(c) or_return
	}
	return res, nil
}

cursor_freeze :: proc(c: ^Write_Cursor) -> Error {
	if c.db.tx_start == nil {
		return .Expected_Tx_Start
	}
	length := core_length(c.db.core) or_return
	c.frozen_at = length
	return nil
}

cursor_write :: proc(c: ^Write_Cursor, data: Writeable_Data) -> Error {
	next := cursor_write_path(c, []Path_Part{Write_Data{data = data}}) or_return
	c.slot_ptr = next.slot_ptr
	return nil
}

cursor_write_if_empty :: proc(c: ^Write_Cursor, data: Writeable_Data) -> Error {
	cursor_check_writable(c) or_return
	slot_ptr := cursor_resolved(c.read_cursor) or_return
	if slot_empty(slot_ptr.slot) {
		return cursor_write(c, data)
	}
	return nil
}

cursor_read_uint :: proc(c: Read_Cursor) -> (res: u64, err: Error) {
	slot_ptr := cursor_resolved(c) or_return
	if slot_ptr.slot.tag != .Uint {
		return 0, .Unexpected_Tag
	}
	if slot_ptr.slot.value < 0 {
		return 0, .Expected_Unsigned_Long
	}
	return u64(slot_ptr.slot.value), nil
}

cursor_read_int :: proc(c: Read_Cursor) -> (res: i64, err: Error) {
	slot_ptr := cursor_resolved(c) or_return
	if slot_ptr.slot.tag != .Int {
		return 0, .Unexpected_Tag
	}
	return slot_ptr.slot.value, nil
}

cursor_read_float :: proc(c: Read_Cursor) -> (res: f64, err: Error) {
	slot_ptr := cursor_resolved(c) or_return
	if slot_ptr.slot.tag != .Float {
		return 0, .Unexpected_Tag
	}
	return transmute(f64)slot_ptr.slot.value, nil
}

cursor_read_bytes :: proc(c: Read_Cursor, max_size: i64 = 0, allocator := context.allocator) -> (res: []u8, err: Error) {
	obj := cursor_read_bytes_object(c, max_size, allocator) or_return
	if obj.format_tag != nil {
		delete(obj.format_tag, allocator)
	}
	return obj.value, nil
}

cursor_read_string :: proc(c: Read_Cursor, max_size: i64 = 0, allocator := context.allocator) -> (res: string, err: Error) {
	b := cursor_read_bytes(c, max_size, allocator) or_return
	return string(b), nil
}

cursor_read_bytes_object :: proc(c: Read_Cursor, max_size: i64 = 0, allocator := context.allocator) -> (res: Bytes, err: Error) {
	slot_ptr := cursor_resolved(c) or_return
	#partial switch slot_ptr.slot.tag {
	case .None:
		return Bytes{value = make([]u8, 0, allocator)}, nil

	case .Bytes:
		value_size := core_read_long_at(c.db.core, slot_ptr.slot.value) or_return
		if max_size > 0 && value_size > max_size {
			return {}, .Stream_Too_Long
		}
		value := make([]u8, int(value_size), allocator)
		err := core_read_exact_at(c.db.core, slot_ptr.slot.value + 8, value)
		if err != nil {
			delete(value, allocator)
			return {}, err
		}
		format_tag: []u8
		if slot_ptr.slot.full {
			format_tag = make([]u8, 2, allocator)
			if ft_err := core_read_exact_at(c.db.core, slot_ptr.slot.value + 8 + value_size, format_tag); ft_err != nil {
				delete(value, allocator)
				delete(format_tag, allocator)
				return {}, ft_err
			}
		}
		return Bytes{value = value, format_tag = format_tag}, nil

	case .Short_Bytes:
		buf: [8]u8
		endian.unchecked_put_u64be(buf[:], u64(slot_ptr.slot.value))
		total_size: i64 = 6 if slot_ptr.slot.full else 8
		value_size: i64 = 0
		for b in buf {
			if b == 0 || value_size == total_size {
				break
			}
			value_size += 1
		}
		if max_size > 0 && value_size > max_size {
			return {}, .Stream_Too_Long
		}
		format_tag: []u8
		if slot_ptr.slot.full {
			format_tag = make([]u8, 2, allocator)
			copy(format_tag, buf[total_size : total_size + 2])
		}
		value := make([]u8, int(value_size), allocator)
		copy(value, buf[:value_size])
		return Bytes{value = value, format_tag = format_tag}, nil

	case:
		return {}, .Unexpected_Tag
	}
}

cursor_read_bytes_buf :: proc(c: Read_Cursor, buffer: []u8) -> (res: Bytes, err: Error) {
	slot_ptr := cursor_resolved(c) or_return
	#partial switch slot_ptr.slot.tag {
	case .None:
		if len(buffer) == 0 {
			return Bytes{value = buffer}, nil
		}
		return {}, .End_Of_Stream

	case .Bytes:
		value_size := core_read_long_at(c.db.core, slot_ptr.slot.value) or_return
		if value_size > i64(len(buffer)) {
			return {}, .Stream_Too_Long
		}
		if slot_ptr.slot.full {
			if value_size + 2 <= i64(len(buffer)) {
				combined := buffer[:value_size + 2]
				core_read_exact_at(c.db.core, slot_ptr.slot.value + 8, combined) or_return
				return Bytes{
					value      = combined[:value_size],
					format_tag = combined[value_size : value_size + 2],
				}, nil
			}
			value := buffer[:value_size]
			core_read_exact_at(c.db.core, slot_ptr.slot.value + 8, value) or_return
			ft := make([]u8, 2, context.temp_allocator)
			core_read_exact_at(c.db.core, slot_ptr.slot.value + 8 + value_size, ft) or_return
			return Bytes{value = value, format_tag = ft}, nil
		}
		value := buffer[:value_size]
		core_read_exact_at(c.db.core, slot_ptr.slot.value + 8, value) or_return
		return Bytes{value = value}, nil

	case .Short_Bytes:
		buf: [8]u8
		endian.unchecked_put_u64be(buf[:], u64(slot_ptr.slot.value))
		total_size: i64 = 6 if slot_ptr.slot.full else 8
		value_size: i64 = 0
		for b in buf {
			if b == 0 || value_size == total_size {
				break
			}
			value_size += 1
		}
		if value_size > i64(len(buffer)) {
			return {}, .Stream_Too_Long
		}
		copy(buffer[:value_size], buf[:value_size])
		format_tag: []u8
		if slot_ptr.slot.full {
			if value_size + 2 <= i64(len(buffer)) {
				buffer[value_size] = buf[total_size]
				buffer[value_size + 1] = buf[total_size + 1]
				format_tag = buffer[value_size : value_size + 2]
			} else {
				ft := make([]u8, 2, context.temp_allocator)
				copy(ft, buf[total_size : total_size + 2])
				format_tag = ft
			}
		}
		return Bytes{value = buffer[:value_size], format_tag = format_tag}, nil

	case:
		return {}, .Unexpected_Tag
	}
}

cursor_read_kv_pair :: proc(c: Read_Cursor, allocator := context.temp_allocator) -> (res: Read_KV_Pair_Cursor, err: Error) {
	slot_ptr := cursor_resolved(c) or_return
	if is_key_only_entry(slot_ptr.slot) {
		return Read_KV_Pair_Cursor{
			value_cursor = Read_Cursor{slot_ptr = Slot_Pointer{position = nil, slot = Slot{}}, db = c.db, frozen_at = c.frozen_at},
			key_cursor   = Read_Cursor{slot_ptr = Slot_Pointer{position = nil, slot = slot_ptr.slot}, db = c.db, frozen_at = c.frozen_at},
			hash         = nil,
		}, nil
	}
	kv_pair := decode_kv_pair_at(c.db.core, slot_ptr.slot.value, slot_ptr.slot.tag, int(c.db.header.hash_size), allocator) or_return
	key_slot_pos := database_kv_key_position(c.db, slot_ptr.slot)
	value_slot_pos := database_kv_value_position(c.db, slot_ptr.slot)
	return Read_KV_Pair_Cursor{
		value_cursor = Read_Cursor{slot_ptr = Slot_Pointer{position = value_slot_pos, slot = kv_pair.value_slot}, db = c.db, frozen_at = c.frozen_at},
		key_cursor   = Read_Cursor{slot_ptr = Slot_Pointer{position = key_slot_pos, slot = kv_pair.key_slot}, db = c.db, frozen_at = c.frozen_at},
		hash         = kv_pair.hash,
	}, nil
}

// Zero-allocation KV pair reader that decodes only the key and value slots on the stack without allocating the hash.
cursor_read_kv_pair_slots :: proc(c: Read_Cursor) -> (key_cursor: Read_Cursor, value_cursor: Read_Cursor, err: Error) {
	slot_ptr := cursor_resolved(c) or_return
	if is_key_only_entry(slot_ptr.slot) {
		return Read_Cursor{slot_ptr = Slot_Pointer{position = nil, slot = slot_ptr.slot}, db = c.db, frozen_at = c.frozen_at},
			Read_Cursor{slot_ptr = Slot_Pointer{position = nil, slot = Slot{}}, db = c.db, frozen_at = c.frozen_at},
			nil
	}
	if slot_ptr.slot.tag != .KV_Pair && slot_ptr.slot.tag != .Sorted_KV_Pair {
		return {}, {}, .Unexpected_Tag
	}
	key_pos := slot_ptr.slot.value + database_kv_key_offset(c.db, slot_ptr.slot.tag)
	val_pos := key_pos + SLOT_LENGTH
	b: [SLOT_LENGTH * 2]u8 = ---
	core_read_exact_at(c.db.core, key_pos, b[:]) or_return
	key_slot := slot_from_slice_raw(b[0:SLOT_LENGTH])
	tag_validate(key_slot.tag) or_return
	val_slot := slot_from_slice_raw(b[SLOT_LENGTH : SLOT_LENGTH * 2])
	tag_validate(val_slot.tag) or_return
	return Read_Cursor{slot_ptr = Slot_Pointer{position = key_pos, slot = key_slot}, db = c.db, frozen_at = c.frozen_at},
		Read_Cursor{slot_ptr = Slot_Pointer{position = val_pos, slot = val_slot}, db = c.db, frozen_at = c.frozen_at},
		nil
}

cursor_write_kv_pair :: proc(c: Write_Cursor, allocator := context.temp_allocator) -> (res: Write_KV_Pair_Cursor, err: Error) {
	rkv := cursor_read_kv_pair(c.read_cursor, allocator) or_return
	return Write_KV_Pair_Cursor{
		value_cursor = Write_Cursor{read_cursor = rkv.value_cursor, transaction = c.transaction},
		key_cursor   = Write_Cursor{read_cursor = rkv.key_cursor, transaction = c.transaction},
		hash         = rkv.hash,
	}, nil
}

cursor_count :: proc(c: Read_Cursor) -> (res: i64, err: Error) {
	slot_ptr := cursor_resolved(c) or_return
	#partial switch slot_ptr.slot.tag {
	case .None:
		return 0, nil
	case .Array_List:
		hb: [ARRAY_LIST_HEADER_LENGTH]u8
		core_read_exact_at(c.db.core, slot_ptr.slot.value, hb[:]) or_return
		header := array_list_header_from_bytes(hb) or_return
		return header.size, nil
	case .Linked_Array_List, .Sorted_Map, .Sorted_Set:
		hb: [BTREE_HEADER_LENGTH]u8
		core_read_exact_at(c.db.core, slot_ptr.slot.value, hb[:]) or_return
		header := btree_header_from_bytes(hb) or_return
		return header.size, nil
	case .Bytes:
		return core_read_long_at(c.db.core, slot_ptr.slot.value)
	case .Short_Bytes:
		buf: [8]u8
		endian.unchecked_put_u64be(buf[:], u64(slot_ptr.slot.value))
		total_size := 6 if slot_ptr.slot.full else 8
		size := 0
		for b in buf {
			if b == 0 || size == total_size {
				break
			}
			size += 1
		}
		return i64(size), nil
	case .Counted_Hash_Map, .Counted_Hash_Set:
		return core_read_long_at(c.db.core, slot_ptr.slot.value)
	case:
		return 0, .Unexpected_Tag
	}
}

// Cursor_Reader

Cursor_Reader :: struct {
	parent:            Read_Cursor,
	size:              i64,
	start_position:    i64,
	relative_position: i64,
}

cursor_reader :: proc(c: Read_Cursor) -> (res: Cursor_Reader, err: Error) {
	slot_ptr := cursor_resolved(c) or_return
	#partial switch slot_ptr.slot.tag {
	case .Bytes:
		size := core_read_long_at(c.db.core, slot_ptr.slot.value) or_return
		start_position := slot_ptr.slot.value + 8
		return Cursor_Reader{
			parent            = c,
			size              = size,
			start_position    = start_position,
			relative_position = 0,
		}, nil
	case .Short_Bytes:
		buf: [8]u8 = ---
		endian.unchecked_put_u64be(buf[:], u64(slot_ptr.slot.value))
		total_size := 6 if slot_ptr.slot.full else 8
		value_size := 0
		for b in buf {
			if b == 0 || value_size == total_size {
				break
			}
			value_size += 1
		}
		pos, ok := slot_ptr.position.?
		if !ok {
			return {}, .Expected_Slot_Position
		}
		start_position := pos + 1
		return Cursor_Reader{
			parent            = c,
			size              = i64(value_size),
			start_position    = start_position,
			relative_position = 0,
		}, nil
	case:
		return {}, .Unexpected_Tag
	}
}

cursor_reader_read :: #force_inline proc(r: ^Cursor_Reader, p: []u8) -> (res: int, err: Error) {
	if r.size < r.relative_position {
		return 0, .End_Of_Stream
	}
	read_size := min(i64(len(p)), r.size - r.relative_position)
	if read_size == 0 {
		return 0, nil
	}
	if src_slice, in_mem, slice_err := core_slice_at(r.parent.db.core, r.start_position + r.relative_position, int(read_size)); in_mem {
		if slice_err != nil {
			return 0, slice_err
		}
		intrinsics.mem_copy_non_overlapping(raw_data(p), raw_data(src_slice), int(read_size))
		r.relative_position += read_size
		return int(read_size), nil
	}
	core_read_exact_at(r.parent.db.core, r.start_position + r.relative_position, p[:read_size]) or_return
	r.relative_position += read_size
	return int(read_size), nil
}

cursor_reader_read_fully :: #force_inline proc(r: ^Cursor_Reader, buf: []u8) -> Error {
	n := i64(len(buf))
	if r.size < r.relative_position || r.size - r.relative_position < n {
		return .End_Of_Stream
	}
	if n == 0 {
		return nil
	}
	if src_slice, in_mem, slice_err := core_slice_at(r.parent.db.core, r.start_position + r.relative_position, int(n)); in_mem {
		if slice_err != nil {
			return slice_err
		}
		intrinsics.mem_copy_non_overlapping(raw_data(buf), raw_data(src_slice), int(n))
		r.relative_position += n
		return nil
	}
	core_read_exact_at(r.parent.db.core, r.start_position + r.relative_position, buf) or_return
	r.relative_position += n
	return nil
}

cursor_reader_seek_to :: #force_inline proc(r: ^Cursor_Reader, position: i64) -> Error {
	if position < 0 || position > r.size {
		return Xitdb_Error.Invalid_Offset
	}
	r.relative_position = position
	return nil
}

cursor_reader_read_all :: proc(r: ^Cursor_Reader, allocator := context.allocator) -> (res: []u8, err: Error) {
	remaining := r.size - r.relative_position
	buf := make([]u8, int(remaining), allocator)
	err = cursor_reader_read_fully(r, buf)
	if err != nil {
		delete(buf, allocator)
		return nil, err
	}
	return buf, nil
}

// Cursor_Writer

Cursor_Writer :: struct {
	parent:            ^Write_Cursor,
	size:              i64,
	slot:              Slot,
	start_position:    i64,
	relative_position: i64,
	format_tag:        []u8,
}

cursor_writer :: proc(c: ^Write_Cursor) -> (res: Cursor_Writer, err: Error) {
	cursor_check_writable(c) or_return
	if is_root(c.slot_ptr) {
		return {}, .Cursor_Not_Writeable
	}
	if c.db.tx_start == nil {
		return {}, .Expected_Tx_Start
	}
	ptr_pos := core_length(c.db.core) or_return
	core_seek_to(c.db.core, ptr_pos) or_return
	core_write_long(c.db.core, 0) or_return
	start_position := core_length(c.db.core) or_return
	return Cursor_Writer{
		parent            = c,
		size              = 0,
		slot              = Slot{value = ptr_pos, tag = .Bytes},
		start_position    = start_position,
		relative_position = 0,
	}, nil
}

cursor_writer_check_writable :: proc(w: ^Cursor_Writer) -> Error {
	cursor_check_writable(w.parent) or_return
	if w.parent.db.tx_start == nil {
		return .Expected_Tx_Start
	}
	active := w.parent.db.transaction
	if active != nil {
		if fa, ok := active.frozen_at.?; ok && w.slot.value < fa {
			return .Frozen_Bytes
		}
	}
	return nil
}

cursor_writer_write :: proc(w: ^Cursor_Writer, p: []u8) -> (res: int, err: Error) {
	cursor_writer_check_writable(w) or_return
	if w.size < w.relative_position {
		return 0, .End_Of_Stream
	}
	new_position := w.relative_position + i64(len(p))
	if new_position > w.size {
		end := core_length(w.parent.db.core) or_return
		if end != w.start_position + w.size {
			return 0, .Unexpected_Writer_Position
		}
	}
	core_seek_to(w.parent.db.core, w.start_position + w.relative_position) or_return
	core_write_all(w.parent.db.core, p) or_return
	w.relative_position = new_position
	if w.relative_position > w.size {
		w.size = w.relative_position
	}
	return len(p), nil
}

cursor_writer_seek_to :: proc(w: ^Cursor_Writer, position: i64) -> Error {
	if position < 0 || position > w.size {
		return Xitdb_Error.Invalid_Offset
	}
	w.relative_position = position
	return nil
}

cursor_writer_finish :: proc(w: ^Cursor_Writer) -> Error {
	cursor_writer_check_writable(w) or_return
	if w.format_tag != nil {
		if len(w.format_tag) != 2 {
			return .Invalid_Format_Tag_Size
		}
		w.slot = slot_with_full(w.slot, true)
		format_tag_pos := core_length(w.parent.db.core) or_return
		core_seek_to(w.parent.db.core, format_tag_pos) or_return
		if w.start_position + w.size != format_tag_pos {
			return .Unexpected_Writer_Position
		}
		core_write_all(w.parent.db.core, w.format_tag) or_return
	}
	core_seek_to(w.parent.db.core, w.slot.value) or_return
	core_write_long(w.parent.db.core, w.size) or_return

	position, pos_ok := w.parent.slot_ptr.position.?
	if !pos_ok {
		return .Cursor_Not_Writeable
	}
	core_seek_to(w.parent.db.core, position) or_return
	core_write_slot(w.parent.db.core, w.slot) or_return

	w.parent.slot_ptr = slot_pointer_with_slot(w.parent.slot_ptr, w.slot)
	if w.parent.db.tx_start == nil {
		return core_sync(w.parent.db.core)
	}
	return nil
}

// Cursor_Iterator - stack-based tree traversal

Iter_Level :: struct {
	position: i64,
	block:    [SLOT_COUNT]Slot,
	index:    u8,
	count:    u8,
}

Cursor_Iterator :: struct {
	cursor:    Read_Cursor,
	size:      i64,
	index:     i64,
	stack:     [ITERATOR_STACK_SIZE]Iter_Level,
	stack_len: int,
}

@(private)
_fill_slot_block_from :: proc(cursor: Read_Cursor, position: i64, start_idx: int, end_idx: int, level: ^Iter_Level) -> Error {
	level.position = position
	level.index = u8(start_idx)
	level.count = u8(end_idx)
	rem_slots := end_idx - start_idx
	if rem_slots <= 0 {
		return nil
	}
	read_pos := position + i64(start_idx) * SLOT_LENGTH
	byte_len := rem_slots * SLOT_LENGTH
	if mem_slice, in_mem, slice_err := core_slice_at(cursor.db.core, read_pos, byte_len); in_mem {
		if slice_err != nil {
			return slice_err
		}
		for j in 0 ..< rem_slots {
			level.block[start_idx + j] = slot_from_slice(mem_slice[j * SLOT_LENGTH : (j + 1) * SLOT_LENGTH]) or_return
		}
		return nil
	}
	index_block_bytes: [INDEX_BLOCK_SIZE]u8 = ---
	core_read_exact_at(cursor.db.core, read_pos, index_block_bytes[:byte_len]) or_return
	for j in 0 ..< rem_slots {
		level.block[start_idx + j] = slot_from_slice(index_block_bytes[j * SLOT_LENGTH : (j + 1) * SLOT_LENGTH]) or_return
	}
	return nil
}

@(private)
_fill_slot_block_rev :: proc(cursor: Read_Cursor, position: i64, count: int, level: ^Iter_Level) -> Error {
	level.position = position
	if count <= 0 {
		level.index = 0
		level.count = 0
		return nil
	}
	level.index = u8(count - 1)
	level.count = u8(count)
	byte_len := count * SLOT_LENGTH
	if mem_slice, in_mem, slice_err := core_slice_at(cursor.db.core, position, byte_len); in_mem {
		if slice_err != nil {
			return slice_err
		}
		for j in 0 ..< count {
			level.block[j] = slot_from_slice(mem_slice[j * SLOT_LENGTH : (j + 1) * SLOT_LENGTH]) or_return
		}
		return nil
	}
	index_block_bytes: [INDEX_BLOCK_SIZE]u8 = ---
	core_read_exact_at(cursor.db.core, position, index_block_bytes[:byte_len]) or_return
	for j in 0 ..< count {
		level.block[j] = slot_from_slice(index_block_bytes[j * SLOT_LENGTH : (j + 1) * SLOT_LENGTH]) or_return
	}
	return nil
}

@(private)
_init_iter_level :: proc(cursor: Read_Cursor, position: i64, level: ^Iter_Level) -> Error {
	return _fill_slot_block_from(cursor, position, 0, SLOT_COUNT, level)
}

@(private)
_init_iter_level_rev :: proc(cursor: Read_Cursor, position: i64, level: ^Iter_Level) -> Error {
	return _fill_slot_block_rev(cursor, position, SLOT_COUNT, level)
}

@(private)
_init_btree_iter_level :: proc(cursor: Read_Cursor, node_ptr: i64, level: ^Iter_Level) -> Error {
	position := node_ptr + BTREE_NODE_HEADER_SIZE
	if hdr_slice, in_mem, slice_err := core_slice_at(cursor.db.core, node_ptr, BTREE_NODE_HEADER_SIZE); in_mem {
		if slice_err != nil {
			return slice_err
		}
		if hdr_slice[0] > u8(BTree_Node_Kind.Branch) {
			return .Invalid_BTree_Node_Kind
		}
		num := int(hdr_slice[1])
		if num > BTREE_SLOT_COUNT {
			return .Invalid_BTree_Node
		}
		return _fill_slot_block_from(cursor, position, 0, num, level)
	}
	buf: [BTREE_LEAF_BLOCK_SIZE]u8 = ---
	n, r_err := core_read_at(cursor.db.core, node_ptr, buf[:])
	if r_err != nil && r_err != io.Error.EOF {
		return r_err
	}
	if n < BTREE_NODE_HEADER_SIZE {
		return io.Error.Unexpected_EOF
	}
	if buf[0] > u8(BTree_Node_Kind.Branch) {
		return .Invalid_BTree_Node_Kind
	}
	num := int(buf[1])
	if num > BTREE_SLOT_COUNT {
		return .Invalid_BTree_Node
	}
	needed := BTREE_NODE_HEADER_SIZE + num * SLOT_LENGTH
	if n < needed {
		core_read_exact_at(cursor.db.core, node_ptr + i64(n), buf[n:needed]) or_return
	}
	level.position = position
	level.index = 0
	level.count = u8(num)
	slots_slice := buf[BTREE_NODE_HEADER_SIZE:needed]
	for j in 0 ..< num {
		level.block[j] = slot_from_slice(slots_slice[j * SLOT_LENGTH : (j + 1) * SLOT_LENGTH]) or_return
	}
	return nil
}

@(private)
_init_btree_iter_level_rev :: proc(cursor: Read_Cursor, node_ptr: i64, level: ^Iter_Level) -> Error {
	position := node_ptr + BTREE_NODE_HEADER_SIZE
	if hdr_slice, in_mem, slice_err := core_slice_at(cursor.db.core, node_ptr, BTREE_NODE_HEADER_SIZE); in_mem {
		if slice_err != nil {
			return slice_err
		}
		if hdr_slice[0] > u8(BTree_Node_Kind.Branch) {
			return .Invalid_BTree_Node_Kind
		}
		num := int(hdr_slice[1])
		if num > BTREE_SLOT_COUNT {
			return .Invalid_BTree_Node
		}
		return _fill_slot_block_rev(cursor, position, num, level)
	}
	buf: [BTREE_LEAF_BLOCK_SIZE]u8 = ---
	n, r_err := core_read_at(cursor.db.core, node_ptr, buf[:])
	if r_err != nil && r_err != io.Error.EOF {
		return r_err
	}
	if n < BTREE_NODE_HEADER_SIZE {
		return io.Error.Unexpected_EOF
	}
	if buf[0] > u8(BTree_Node_Kind.Branch) {
		return .Invalid_BTree_Node_Kind
	}
	num := int(buf[1])
	if num > BTREE_SLOT_COUNT {
		return .Invalid_BTree_Node
	}
	needed := BTREE_NODE_HEADER_SIZE + num * SLOT_LENGTH
	if n < needed {
		core_read_exact_at(cursor.db.core, node_ptr + i64(n), buf[n:needed]) or_return
	}
	level.position = position
	if num <= 0 {
		level.index = 0
		level.count = 0
		return nil
	}
	level.index = u8(num - 1)
	level.count = u8(num)
	slots_slice := buf[BTREE_NODE_HEADER_SIZE:needed]
	for j in 0 ..< num {
		level.block[j] = slot_from_slice(slots_slice[j * SLOT_LENGTH : (j + 1) * SLOT_LENGTH]) or_return
	}
	return nil
}

cursor_iterator :: proc(unresolved_cursor: Read_Cursor) -> (res: Cursor_Iterator, err: Error) {
	cursor := cursor_resolved_cursor(unresolved_cursor) or_return
	res.cursor = cursor

	#partial switch cursor.slot_ptr.slot.tag {
	case .None:
		res.size = 0
		res.index = 0
	case .Array_List:
		position := cursor.slot_ptr.slot.value
		hb: [ARRAY_LIST_HEADER_LENGTH]u8 = ---
		core_read_exact_at(cursor.db.core, position, hb[:]) or_return
		header := array_list_header_from_bytes(hb) or_return
		res.size = header.size
		res.index = 0
		if header.size > 0 {
			_init_iter_level(cursor, header.ptr, &res.stack[0]) or_return
			res.stack_len = 1
		}
	case .Linked_Array_List, .Sorted_Map, .Sorted_Set:
		position := cursor.slot_ptr.slot.value
		hb: [BTREE_HEADER_LENGTH]u8 = ---
		core_read_exact_at(cursor.db.core, position, hb[:]) or_return
		header := btree_header_from_bytes(hb) or_return
		res.size = header.size
		res.index = 0
		if header.size > 0 {
			_init_btree_iter_level(cursor, header.root_ptr, &res.stack[0]) or_return
			res.stack_len = 1
		}
	case .Hash_Map, .Hash_Set:
		res.size = 0
		res.index = 0
		_init_iter_level(cursor, cursor.slot_ptr.slot.value, &res.stack[0]) or_return
		res.stack_len = 1
	case .Counted_Hash_Map, .Counted_Hash_Set:
		res.size = 0
		res.index = 0
		_init_iter_level(cursor, cursor.slot_ptr.slot.value + 8, &res.stack[0]) or_return
		res.stack_len = 1
	case:
		return {}, .Unexpected_Tag
	}
	return res, nil
}

cursor_iterator_reverse :: proc(unresolved_cursor: Read_Cursor) -> (res: Cursor_Iterator, err: Error) {
	cursor := cursor_resolved_cursor(unresolved_cursor) or_return
	res.cursor = cursor

	#partial switch cursor.slot_ptr.slot.tag {
	case .None:
		res.size = 0
		res.index = 0
	case .Array_List:
		return cursor_iterator_array_list_reverse_from_index(cursor, -1)
	case .Linked_Array_List, .Sorted_Map, .Sorted_Set:
		position := cursor.slot_ptr.slot.value
		hb: [BTREE_HEADER_LENGTH]u8 = ---
		core_read_exact_at(cursor.db.core, position, hb[:]) or_return
		header := btree_header_from_bytes(hb) or_return
		res.size = header.size
		res.index = header.size
		if header.size > 0 {
			_init_btree_iter_level_rev(cursor, header.root_ptr, &res.stack[0]) or_return
			res.stack_len = 1
		}
	case .Hash_Map, .Hash_Set:
		res.size = 0
		res.index = 0
		_init_iter_level_rev(cursor, cursor.slot_ptr.slot.value, &res.stack[0]) or_return
		res.stack_len = 1
	case .Counted_Hash_Map, .Counted_Hash_Set:
		res.size = 0
		res.index = 0
		_init_iter_level_rev(cursor, cursor.slot_ptr.slot.value + 8, &res.stack[0]) or_return
		res.stack_len = 1
	case:
		return {}, .Unexpected_Tag
	}
	return res, nil
}

@(private)
_resolve_start_index :: proc(index: i64, size: i64) -> (res: i64, err: bool) {
	resolved := index
	if index < 0 {
		resolved = index + size
	}
	if resolved < 0 || resolved >= size {
		return 0, false
	}
	return resolved, true
}

@(private)
_sorted_header :: proc(cursor: Read_Cursor) -> (res: BTree_Header, err: Error) {
	#partial switch cursor.slot_ptr.slot.tag {
	case .Sorted_Map, .Sorted_Set:
	case:
		return {}, .Unexpected_Tag
	}
	hb: [BTREE_HEADER_LENGTH]u8 = ---
	core_read_exact_at(cursor.db.core, cursor.slot_ptr.slot.value, hb[:]) or_return
	return btree_header_from_bytes(hb)
}

cursor_iterator_sorted_from_index :: proc(unresolved_cursor: Read_Cursor, start_index: i64) -> (res: Cursor_Iterator, err: Error) {
	cursor := cursor_resolved_cursor(unresolved_cursor) or_return
	res.cursor = cursor
	#partial switch cursor.slot_ptr.slot.tag {
	case .None:
		return res, nil
	case .Sorted_Map, .Sorted_Set:
	case:
		return {}, .Unexpected_Tag
	}
	header := _sorted_header(cursor) or_return
	total := header.size
	idx, ok := _resolve_start_index(start_index, total)
	if !ok {
		return res, nil
	}
	node_ptr := header.root_ptr
	rem := idx
	for {
		header_bytes: [BTREE_NODE_HEADER_SIZE]u8 = ---
		core_read_exact_at(cursor.db.core, node_ptr, header_bytes[:]) or_return
		kind_int := header_bytes[0]
		if kind_int > u8(BTree_Node_Kind.Branch) {
			return {}, .Invalid_BTree_Node_Kind
		}
		num := int(header_bytes[1])
		if num > BTREE_SLOT_COUNT {
			return {}, .Invalid_BTree_Node
		}
		position := node_ptr + BTREE_NODE_HEADER_SIZE
		level := &res.stack[res.stack_len]
		if BTree_Node_Kind(kind_int) == .Leaf {
			r := int(rem)
			if r < 0 || r >= num {
				return {}, .Invalid_BTree_Node
			}
			_fill_slot_block_from(cursor, position, r, num, level) or_return
			res.stack_len += 1
			break
		}
		counts_pos := position + SLOT_LENGTH * 2 * BTREE_SLOT_COUNT
		counts_buf: [8 * BTREE_SLOT_COUNT]u8 = ---
		core_read_exact_at(cursor.db.core, counts_pos, counts_buf[:num * 8]) or_return
		i := 0
		for i + 1 < num {
			cnt := i64(endian.unchecked_get_u64be(counts_buf[i * 8 : i * 8 + 8]))
			if rem < cnt {
				break
			}
			rem -= cnt
			i += 1
		}
		_fill_slot_block_from(cursor, position, i, num, level) or_return
		res.stack_len += 1
		node_ptr = level.block[i].value
	}
	res.size = total
	res.index = idx
	return res, nil
}

cursor_iterator_sorted_from_key :: proc(unresolved_cursor: Read_Cursor, start_key: []u8) -> (res: Cursor_Iterator, err: Error) {
	cursor := cursor_resolved_cursor(unresolved_cursor) or_return
	res.cursor = cursor
	#partial switch cursor.slot_ptr.slot.tag {
	case .None:
		return res, nil
	case .Sorted_Map, .Sorted_Set:
	case:
		return {}, .Unexpected_Tag
	}
	header := _sorted_header(cursor) or_return
	total := header.size
	node_ptr := header.root_ptr
	before: i64 = 0
	for {
		header_bytes: [BTREE_NODE_HEADER_SIZE]u8 = ---
		core_read_exact_at(cursor.db.core, node_ptr, header_bytes[:]) or_return
		kind_int := header_bytes[0]
		if kind_int > u8(BTree_Node_Kind.Branch) {
			return {}, .Invalid_BTree_Node_Kind
		}
		num := int(header_bytes[1])
		if num > BTREE_SLOT_COUNT {
			return {}, .Invalid_BTree_Node
		}
		position := node_ptr + BTREE_NODE_HEADER_SIZE
		level := &res.stack[res.stack_len]
		if BTree_Node_Kind(kind_int) == .Leaf {
			if num > 0 {
				index_block_bytes: [INDEX_BLOCK_SIZE]u8 = ---
				core_read_exact_at(cursor.db.core, position, index_block_bytes[:num * SLOT_LENGTH]) or_return
				for j in 0 ..< num {
					level.block[j] = slot_from_slice(index_block_bytes[j * SLOT_LENGTH : (j + 1) * SLOT_LENGTH]) or_return
				}
			}
			lo := 0
			hi := num
			for lo < hi {
				mid := int(uint(lo + hi) >> 1)
				entry_slot := level.block[mid]
				key_slot := sorted_entry_key_slot(cursor.db, entry_slot) or_return
				cmp := compare_key(cursor.db, key_slot, start_key) or_return
				if cmp == 0 {
					lo = mid
					break
				} else if cmp < 0 {
					lo = mid + 1
				} else {
					hi = mid
				}
			}
			before += i64(lo)
			level.position = position
			level.index = u8(lo)
			level.count = u8(num)
			res.stack_len += 1
			break
		}
		branch_buf: [(SLOT_LENGTH * 2 + 8) * BTREE_SLOT_COUNT]u8 = ---
		core_read_exact_at(cursor.db.core, position, branch_buf[:SLOT_LENGTH * 2 * BTREE_SLOT_COUNT + num * 8]) or_return
		lo := 1
		hi := num
		sep_off := SLOT_LENGTH * BTREE_SLOT_COUNT
		for lo < hi {
			mid := int(uint(lo + hi) >> 1)
			sep_slot := slot_from_slice(branch_buf[sep_off + mid * SLOT_LENGTH : sep_off + (mid + 1) * SLOT_LENGTH]) or_return
			c := compare_key(cursor.db, sep_slot, start_key) or_return
			if c <= 0 {
				lo = mid + 1
			} else {
				hi = mid
			}
		}
		i := lo - 1
		counts_off := SLOT_LENGTH * 2 * BTREE_SLOT_COUNT
		for k in 0 ..< i {
			before += i64(endian.unchecked_get_u64be(branch_buf[counts_off + k * 8 : counts_off + (k + 1) * 8]))
		}
		for j in i ..< num {
			level.block[j] = slot_from_slice(branch_buf[j * SLOT_LENGTH : (j + 1) * SLOT_LENGTH]) or_return
		}
		level.position = position
		level.index = u8(i)
		level.count = u8(num)
		res.stack_len += 1
		node_ptr = level.block[i].value
	}
	res.size = total
	res.index = before
	return res, nil
}

cursor_iterator_array_list_from_index :: proc(unresolved_cursor: Read_Cursor, start_index: i64) -> (res: Cursor_Iterator, err: Error) {
	cursor := cursor_resolved_cursor(unresolved_cursor) or_return
	res.cursor = cursor
	#partial switch cursor.slot_ptr.slot.tag {
	case .None:
		return res, nil
	case .Array_List:
	case:
		return {}, .Unexpected_Tag
	}
	hb: [ARRAY_LIST_HEADER_LENGTH]u8 = ---
	core_read_exact_at(cursor.db.core, cursor.slot_ptr.slot.value, hb[:]) or_return
	header := array_list_header_from_bytes(hb) or_return
	idx, ok := _resolve_start_index(start_index, header.size)
	if !ok {
		return res, nil
	}
	shift := radix_shift(header.size - 1)
	pos := header.ptr
	sh := shift
	for {
		i := int((idx >> (u64(sh) * BIT_COUNT)) & i64(MASK))
		level := &res.stack[res.stack_len]
		_fill_slot_block_from(cursor, pos, i, SLOT_COUNT, level) or_return
		res.stack_len += 1
		if sh == 0 {
			break
		}
		pos = level.block[i].value
		sh -= 1
	}
	res.size = header.size
	res.index = idx
	return res, nil
}

cursor_iterator_linked_array_list_from_index :: proc(unresolved_cursor: Read_Cursor, start_index: i64) -> (res: Cursor_Iterator, err: Error) {
	cursor := cursor_resolved_cursor(unresolved_cursor) or_return
	res.cursor = cursor
	#partial switch cursor.slot_ptr.slot.tag {
	case .None:
		return res, nil
	case .Linked_Array_List:
	case:
		return {}, .Unexpected_Tag
	}
	hb: [BTREE_HEADER_LENGTH]u8 = ---
	core_read_exact_at(cursor.db.core, cursor.slot_ptr.slot.value, hb[:]) or_return
	header := btree_header_from_bytes(hb) or_return
	idx, ok := _resolve_start_index(start_index, header.size)
	if !ok {
		return res, nil
	}
	node_ptr := header.root_ptr
	rem := idx
	for {
		header_bytes: [BTREE_NODE_HEADER_SIZE]u8 = ---
		core_read_exact_at(cursor.db.core, node_ptr, header_bytes[:]) or_return
		kind_int := header_bytes[0]
		if kind_int > u8(BTree_Node_Kind.Branch) {
			return {}, .Invalid_BTree_Node_Kind
		}
		num := int(header_bytes[1])
		if num > BTREE_SLOT_COUNT {
			return {}, .Invalid_BTree_Node
		}
		position := node_ptr + BTREE_NODE_HEADER_SIZE
		level := &res.stack[res.stack_len]
		if BTree_Node_Kind(kind_int) == .Leaf {
			r := int(rem)
			if r < 0 || r >= num {
				return {}, .Invalid_BTree_Node
			}
			_fill_slot_block_from(cursor, position, r, num, level) or_return
			res.stack_len += 1
			break
		}
		counts_pos := position + SLOT_LENGTH * BTREE_SLOT_COUNT
		counts_buf: [8 * BTREE_SLOT_COUNT]u8 = ---
		core_read_exact_at(cursor.db.core, counts_pos, counts_buf[:num * 8]) or_return
		i := 0
		for i + 1 < num {
			cnt := i64(endian.unchecked_get_u64be(counts_buf[i * 8 : i * 8 + 8]))
			if rem < cnt {
				break
			}
			rem -= cnt
			i += 1
		}
		_fill_slot_block_from(cursor, position, i, num, level) or_return
		res.stack_len += 1
		node_ptr = level.block[i].value
	}
	res.size = header.size
	res.index = idx
	return res, nil
}

cursor_iterator_sorted_reverse_from_index :: proc(unresolved_cursor: Read_Cursor, start_index: i64) -> (res: Cursor_Iterator, err: Error) {
	cursor := cursor_resolved_cursor(unresolved_cursor) or_return
	res.cursor = cursor
	#partial switch cursor.slot_ptr.slot.tag {
	case .None:
		return res, nil
	case .Sorted_Map, .Sorted_Set:
	case:
		return {}, .Unexpected_Tag
	}
	header := _sorted_header(cursor) or_return
	total := header.size
	idx, ok := _resolve_start_index(start_index, total)
	if !ok {
		return res, nil
	}
	node_ptr := header.root_ptr
	rem := idx
	for {
		header_bytes: [BTREE_NODE_HEADER_SIZE]u8 = ---
		core_read_exact_at(cursor.db.core, node_ptr, header_bytes[:]) or_return
		kind_int := header_bytes[0]
		if kind_int > u8(BTree_Node_Kind.Branch) {
			return {}, .Invalid_BTree_Node_Kind
		}
		num := int(header_bytes[1])
		if num > BTREE_SLOT_COUNT {
			return {}, .Invalid_BTree_Node
		}
		position := node_ptr + BTREE_NODE_HEADER_SIZE
		level := &res.stack[res.stack_len]
		if BTree_Node_Kind(kind_int) == .Leaf {
			r := int(rem)
			if r < 0 || r >= num {
				return {}, .Invalid_BTree_Node
			}
			_fill_slot_block_rev(cursor, position, r + 1, level) or_return
			res.stack_len += 1
			break
		}
		counts_pos := position + SLOT_LENGTH * 2 * BTREE_SLOT_COUNT
		counts_buf: [8 * BTREE_SLOT_COUNT]u8 = ---
		core_read_exact_at(cursor.db.core, counts_pos, counts_buf[:num * 8]) or_return
		i := 0
		for i + 1 < num {
			cnt := i64(endian.unchecked_get_u64be(counts_buf[i * 8 : i * 8 + 8]))
			if rem < cnt {
				break
			}
			rem -= cnt
			i += 1
		}
		_fill_slot_block_rev(cursor, position, i + 1, level) or_return
		res.stack_len += 1
		node_ptr = level.block[i].value
	}
	res.size = total
	res.index = idx + 1
	return res, nil
}

cursor_iterator_sorted_reverse_from_key :: proc(unresolved_cursor: Read_Cursor, upper_key: []u8, inclusive: bool = true) -> (res: Cursor_Iterator, err: Error) {
	cursor := cursor_resolved_cursor(unresolved_cursor) or_return
	res.cursor = cursor
	#partial switch cursor.slot_ptr.slot.tag {
	case .None:
		return res, nil
	case .Sorted_Map, .Sorted_Set:
	case:
		return {}, .Unexpected_Tag
	}
	header := _sorted_header(cursor) or_return
	total := header.size
	if total == 0 {
		return res, nil
	}
	node_ptr := header.root_ptr
	before: i64 = 0
	for {
		header_bytes: [BTREE_NODE_HEADER_SIZE]u8 = ---
		core_read_exact_at(cursor.db.core, node_ptr, header_bytes[:]) or_return
		kind_int := header_bytes[0]
		if kind_int > u8(BTree_Node_Kind.Branch) {
			return {}, .Invalid_BTree_Node_Kind
		}
		num := int(header_bytes[1])
		if num > BTREE_SLOT_COUNT {
			return {}, .Invalid_BTree_Node
		}
		position := node_ptr + BTREE_NODE_HEADER_SIZE
		level := &res.stack[res.stack_len]
		if BTree_Node_Kind(kind_int) == .Leaf {
			if num > 0 {
				index_block_bytes: [INDEX_BLOCK_SIZE]u8 = ---
				core_read_exact_at(cursor.db.core, position, index_block_bytes[:num * SLOT_LENGTH]) or_return
				for j in 0 ..< num {
					level.block[j] = slot_from_slice(index_block_bytes[j * SLOT_LENGTH : (j + 1) * SLOT_LENGTH]) or_return
				}
			}
			lo := 0
			hi := num
			found := false
			for lo < hi {
				mid := int(uint(lo + hi) >> 1)
				entry_slot := level.block[mid]
				key_slot := sorted_entry_key_slot(cursor.db, entry_slot) or_return
				cmp := compare_key(cursor.db, key_slot, upper_key) or_return
				if cmp == 0 {
					lo = mid
					found = true
					break
				} else if cmp < 0 {
					lo = mid + 1
				} else {
					hi = mid
				}
			}
			leaf_count := (lo + 1) if (found && inclusive) else lo
			before += i64(leaf_count)
			if before == 0 {
				res.stack_len = 0
				return res, nil
			}
			if leaf_count > 0 {
				level.position = position
				level.index = u8(leaf_count - 1)
				level.count = u8(leaf_count)
				res.stack_len += 1
			} else if res.stack_len > 0 {
				res.stack[res.stack_len - 1].index -= 1
			}
			break
		}
		branch_buf: [(SLOT_LENGTH * 2 + 8) * BTREE_SLOT_COUNT]u8 = ---
		core_read_exact_at(cursor.db.core, position, branch_buf[:SLOT_LENGTH * 2 * BTREE_SLOT_COUNT + num * 8]) or_return
		lo := 1
		hi := num
		sep_off := SLOT_LENGTH * BTREE_SLOT_COUNT
		for lo < hi {
			mid := int(uint(lo + hi) >> 1)
			sep_slot := slot_from_slice(branch_buf[sep_off + mid * SLOT_LENGTH : sep_off + (mid + 1) * SLOT_LENGTH]) or_return
			c := compare_key(cursor.db, sep_slot, upper_key) or_return
			if (c <= 0 if inclusive else c < 0) {
				lo = mid + 1
			} else {
				hi = mid
			}
		}
		i := lo - 1
		counts_off := SLOT_LENGTH * 2 * BTREE_SLOT_COUNT
		for k in 0 ..< i {
			before += i64(endian.unchecked_get_u64be(branch_buf[counts_off + k * 8 : counts_off + (k + 1) * 8]))
		}
		for j in 0 ..= i {
			level.block[j] = slot_from_slice(branch_buf[j * SLOT_LENGTH : (j + 1) * SLOT_LENGTH]) or_return
		}
		level.position = position
		level.index = u8(i)
		level.count = u8(i + 1)
		res.stack_len += 1
		node_ptr = level.block[i].value
	}
	res.size = total
	res.index = before
	return res, nil
}

cursor_iterator_array_list_reverse_from_index :: proc(unresolved_cursor: Read_Cursor, start_index: i64) -> (res: Cursor_Iterator, err: Error) {
	cursor := cursor_resolved_cursor(unresolved_cursor) or_return
	res.cursor = cursor
	#partial switch cursor.slot_ptr.slot.tag {
	case .None:
		return res, nil
	case .Array_List:
	case:
		return {}, .Unexpected_Tag
	}
	hb: [ARRAY_LIST_HEADER_LENGTH]u8 = ---
	core_read_exact_at(cursor.db.core, cursor.slot_ptr.slot.value, hb[:]) or_return
	header := array_list_header_from_bytes(hb) or_return
	idx, ok := _resolve_start_index(start_index, header.size)
	if !ok {
		return res, nil
	}
	shift := radix_shift(header.size - 1)
	pos := header.ptr
	sh := shift
	for {
		i := int((idx >> (u64(sh) * BIT_COUNT)) & i64(MASK))
		level := &res.stack[res.stack_len]
		_fill_slot_block_rev(cursor, pos, i + 1, level) or_return
		res.stack_len += 1
		if sh == 0 {
			break
		}
		pos = level.block[i].value
		sh -= 1
	}
	res.size = header.size
	res.index = idx + 1
	return res, nil
}

cursor_iterator_linked_array_list_reverse_from_index :: proc(unresolved_cursor: Read_Cursor, start_index: i64) -> (res: Cursor_Iterator, err: Error) {
	cursor := cursor_resolved_cursor(unresolved_cursor) or_return
	res.cursor = cursor
	#partial switch cursor.slot_ptr.slot.tag {
	case .None:
		return res, nil
	case .Linked_Array_List:
	case:
		return {}, .Unexpected_Tag
	}
	hb: [BTREE_HEADER_LENGTH]u8 = ---
	core_read_exact_at(cursor.db.core, cursor.slot_ptr.slot.value, hb[:]) or_return
	header := btree_header_from_bytes(hb) or_return
	idx, ok := _resolve_start_index(start_index, header.size)
	if !ok {
		return res, nil
	}
	node_ptr := header.root_ptr
	rem := idx
	for {
		header_bytes: [BTREE_NODE_HEADER_SIZE]u8 = ---
		core_read_exact_at(cursor.db.core, node_ptr, header_bytes[:]) or_return
		kind_int := header_bytes[0]
		if kind_int > u8(BTree_Node_Kind.Branch) {
			return {}, .Invalid_BTree_Node_Kind
		}
		num := int(header_bytes[1])
		if num > BTREE_SLOT_COUNT {
			return {}, .Invalid_BTree_Node
		}
		position := node_ptr + BTREE_NODE_HEADER_SIZE
		level := &res.stack[res.stack_len]
		if BTree_Node_Kind(kind_int) == .Leaf {
			r := int(rem)
			if r < 0 || r >= num {
				return {}, .Invalid_BTree_Node
			}
			_fill_slot_block_rev(cursor, position, r + 1, level) or_return
			res.stack_len += 1
			break
		}
		counts_pos := position + SLOT_LENGTH * BTREE_SLOT_COUNT
		counts_buf: [8 * BTREE_SLOT_COUNT]u8 = ---
		core_read_exact_at(cursor.db.core, counts_pos, counts_buf[:num * 8]) or_return
		i := 0
		for i + 1 < num {
			cnt := i64(endian.unchecked_get_u64be(counts_buf[i * 8 : i * 8 + 8]))
			if rem < cnt {
				break
			}
			rem -= cnt
			i += 1
		}
		_fill_slot_block_rev(cursor, position, i + 1, level) or_return
		res.stack_len += 1
		node_ptr = level.block[i].value
	}
	res.size = header.size
	res.index = idx + 1
	return res, nil
}

@(private)
_iterator_next_internal :: proc(it: ^Cursor_Iterator, node_offset: i64) -> (res: Maybe(Read_Cursor), err: Error) {
	for it.stack_len > 0 {
		level := &it.stack[it.stack_len - 1]
		if level.index >= level.count {
			it.stack_len -= 1
			if it.stack_len > 0 {
				it.stack[it.stack_len - 1].index += 1
			}
			continue
		}
		next_slot := level.block[level.index]
		if next_slot.tag == .Index {
			if node_offset == BTREE_NODE_HEADER_SIZE {
				_init_btree_iter_level(it.cursor, next_slot.value, &it.stack[it.stack_len]) or_return
			} else {
				_init_iter_level(it.cursor, next_slot.value, &it.stack[it.stack_len]) or_return
			}
			it.stack_len += 1
			continue
		}
		slot_idx := level.index
		level.index += 1
		if !slot_empty(next_slot) {
			position := level.position + i64(slot_idx) * SLOT_LENGTH
			return Read_Cursor{
				slot_ptr  = Slot_Pointer{position = position, slot = next_slot},
				db        = it.cursor.db,
				frozen_at = it.cursor.frozen_at,
			}, nil
		}
	}
	return nil, nil
}

@(private)
_iterator_prev_internal :: proc(it: ^Cursor_Iterator, node_offset: i64) -> (res: Maybe(Read_Cursor), err: Error) {
	for it.stack_len > 0 {
		level := &it.stack[it.stack_len - 1]
		if level.index >= level.count {
			it.stack_len -= 1
			if it.stack_len > 0 {
				it.stack[it.stack_len - 1].index -= 1
			}
			continue
		}
		next_slot := level.block[level.index]
		if next_slot.tag == .Index {
			if node_offset == BTREE_NODE_HEADER_SIZE {
				_init_btree_iter_level_rev(it.cursor, next_slot.value, &it.stack[it.stack_len]) or_return
			} else {
				_init_iter_level_rev(it.cursor, next_slot.value, &it.stack[it.stack_len]) or_return
			}
			it.stack_len += 1
			continue
		}
		slot_idx := level.index
		level.index -= 1
		if !slot_empty(next_slot) {
			position := level.position + i64(slot_idx) * SLOT_LENGTH
			return Read_Cursor{
				slot_ptr  = Slot_Pointer{position = position, slot = next_slot},
				db        = it.cursor.db,
				frozen_at = it.cursor.frozen_at,
			}, nil
		}
	}
	return nil, nil
}

cursor_iterator_next :: proc(it: ^Cursor_Iterator) -> (res: Maybe(Read_Cursor), err: Error) {
	#partial switch it.cursor.slot_ptr.slot.tag {
	case .None:
		return nil, nil
	case .Array_List:
		if it.index == it.size {
			return nil, nil
		}
		it.index += 1
		return _iterator_next_internal(it, 0)
	case .Linked_Array_List, .Sorted_Map, .Sorted_Set:
		if it.index == it.size {
			return nil, nil
		}
		it.index += 1
		return _iterator_next_internal(it, BTREE_NODE_HEADER_SIZE)
	case .Hash_Map, .Hash_Set, .Counted_Hash_Map, .Counted_Hash_Set:
		return _iterator_next_internal(it, 0)
	case:
		return nil, .Unexpected_Tag
	}
}

cursor_iterator_prev :: proc(it: ^Cursor_Iterator) -> (res: Maybe(Read_Cursor), err: Error) {
	#partial switch it.cursor.slot_ptr.slot.tag {
	case .None:
		return nil, nil
	case .Array_List:
		if it.index == 0 {
			return nil, nil
		}
		it.index -= 1
		return _iterator_prev_internal(it, 0)
	case .Linked_Array_List, .Sorted_Map, .Sorted_Set:
		if it.index == 0 {
			return nil, nil
		}
		it.index -= 1
		return _iterator_prev_internal(it, BTREE_NODE_HEADER_SIZE)
	case .Hash_Map, .Hash_Set, .Counted_Hash_Map, .Counted_Hash_Set:
		return _iterator_prev_internal(it, 0)
	case:
		return nil, .Unexpected_Tag
	}
}
