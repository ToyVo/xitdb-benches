package xitdb

// ============================================================================
// ArrayList
// ============================================================================

Read_Array_List :: struct {
	cursor: Read_Cursor,
}

Write_Array_List :: struct {
	using read_array_list: Read_Array_List,
	write_cursor:          Write_Cursor,
}

read_array_list_init :: proc(cursor: Read_Cursor) -> (res: Read_Array_List, err: Error) {
	slot_ptr := cursor_resolved(cursor) or_return
	#partial switch slot_ptr.slot.tag {
	case .None, .Array_List:
		return Read_Array_List{cursor = cursor}, nil
	case:
		return {}, .Unexpected_Tag
	}
}

write_array_list_init :: proc(cursor: Write_Cursor) -> (res: Write_Array_List, err: Error) {
	c := cursor
	wc := cursor_write_path(&c, []Path_Part{Array_List_Init{}}) or_return
	ra := read_array_list_init(wc.read_cursor) or_return
	return Write_Array_List{read_array_list = ra, write_cursor = wc}, nil
}

array_list_slot :: proc(a: Read_Array_List) -> (res: Slot, err: Error) {
	return cursor_slot(a.cursor)
}

array_list_count :: proc(a: Read_Array_List) -> (res: i64, err: Error) {
	return cursor_count(a.cursor)
}

array_list_get_cursor :: proc(a: Read_Array_List, index: i64) -> (Maybe(Read_Cursor), Error) {
	return cursor_read_path(a.cursor, []Path_Part{Array_List_Get{index = index}})
}

array_list_get_slot :: proc(a: Read_Array_List, index: i64) -> (Maybe(Slot), Error) {
	return cursor_read_path_slot(a.cursor, []Path_Part{Array_List_Get{index = index}})
}

array_list_iterator :: proc(a: Read_Array_List) -> (res: Cursor_Iterator, err: Error) {
	return cursor_iterator(a.cursor)
}

array_list_iterator_from :: proc(a: Read_Array_List, index: i64) -> (res: Cursor_Iterator, err: Error) {
	return cursor_iterator_array_list_from_index(a.cursor, index)
}

array_list_iterator_reverse :: proc(a: Read_Array_List) -> (res: Cursor_Iterator, err: Error) {
	return cursor_iterator_reverse(a.cursor)
}

array_list_iterator_reverse_from :: proc(a: Read_Array_List, index: i64) -> (res: Cursor_Iterator, err: Error) {
	return cursor_iterator_array_list_reverse_from_index(a.cursor, index)
}

array_list_put :: proc(a: ^Write_Array_List, index: i64, data: Writeable_Data) -> Error {
	_, err := cursor_write_path(&a.write_cursor, []Path_Part{
		Array_List_Get{index = index},
		Write_Data{data = data},
	})
	return err
}

array_list_put_cursor :: proc(a: ^Write_Array_List, index: i64) -> (res: Write_Cursor, err: Error) {
	return cursor_write_path(&a.write_cursor, []Path_Part{Array_List_Get{index = index}})
}

array_list_append :: proc(a: ^Write_Array_List, data: Writeable_Data) -> Error {
	_, err := cursor_write_path(&a.write_cursor, []Path_Part{
		Array_List_Append{},
		Write_Data{data = data},
	})
	return err
}

array_list_append_cursor :: proc(a: ^Write_Array_List) -> (res: Write_Cursor, err: Error) {
	return cursor_write_path(&a.write_cursor, []Path_Part{Array_List_Append{}})
}

array_list_append_context :: proc(a: ^Write_Array_List, data: Writeable_Data, fn: Context_Function, user_data: rawptr = nil) -> Error {
	_, err := cursor_write_path(&a.write_cursor, []Path_Part{
		Array_List_Append{},
		Write_Data{data = data},
		Context{function = fn, user_data = user_data},
	})
	return err
}

array_list_slice :: proc(a: ^Write_Array_List, size: i64) -> Error {
	_, err := cursor_write_path(&a.write_cursor, []Path_Part{Array_List_Slice{size = size}})
	return err
}

// ============================================================================
// LinkedArrayList
// ============================================================================

Read_Linked_Array_List :: struct {
	cursor: Read_Cursor,
}

Write_Linked_Array_List :: struct {
	using read_linked_array_list: Read_Linked_Array_List,
	write_cursor:                 Write_Cursor,
}

read_linked_array_list_init :: proc(cursor: Read_Cursor) -> (res: Read_Linked_Array_List, err: Error) {
	slot_ptr := cursor_resolved(cursor) or_return
	#partial switch slot_ptr.slot.tag {
	case .None, .Linked_Array_List:
		return Read_Linked_Array_List{cursor = cursor}, nil
	case:
		return {}, .Unexpected_Tag
	}
}

write_linked_array_list_init :: proc(cursor: Write_Cursor) -> (res: Write_Linked_Array_List, err: Error) {
	c := cursor
	wc := cursor_write_path(&c, []Path_Part{Linked_Array_List_Init{}}) or_return
	ra := read_linked_array_list_init(wc.read_cursor) or_return
	return Write_Linked_Array_List{read_linked_array_list = ra, write_cursor = wc}, nil
}

linked_array_list_slot :: proc(a: Read_Linked_Array_List) -> (res: Slot, err: Error) {
	return cursor_slot(a.cursor)
}

linked_array_list_count :: proc(a: Read_Linked_Array_List) -> (res: i64, err: Error) {
	return cursor_count(a.cursor)
}

linked_array_list_get_cursor :: proc(a: Read_Linked_Array_List, index: i64) -> (Maybe(Read_Cursor), Error) {
	return cursor_read_path(a.cursor, []Path_Part{Linked_Array_List_Get{index = index}})
}

linked_array_list_get_slot :: proc(a: Read_Linked_Array_List, index: i64) -> (Maybe(Slot), Error) {
	return cursor_read_path_slot(a.cursor, []Path_Part{Linked_Array_List_Get{index = index}})
}

linked_array_list_iterator :: proc(a: Read_Linked_Array_List) -> (res: Cursor_Iterator, err: Error) {
	return cursor_iterator(a.cursor)
}

linked_array_list_iterator_from :: proc(a: Read_Linked_Array_List, index: i64) -> (res: Cursor_Iterator, err: Error) {
	return cursor_iterator_linked_array_list_from_index(a.cursor, index)
}

linked_array_list_iterator_reverse :: proc(a: Read_Linked_Array_List) -> (res: Cursor_Iterator, err: Error) {
	return cursor_iterator_reverse(a.cursor)
}

linked_array_list_iterator_reverse_from :: proc(a: Read_Linked_Array_List, index: i64) -> (res: Cursor_Iterator, err: Error) {
	return cursor_iterator_linked_array_list_reverse_from_index(a.cursor, index)
}

linked_array_list_put :: proc(a: ^Write_Linked_Array_List, index: i64, data: Writeable_Data) -> Error {
	_, err := cursor_write_path(&a.write_cursor, []Path_Part{
		Linked_Array_List_Get{index = index},
		Write_Data{data = data},
	})
	return err
}

linked_array_list_put_cursor :: proc(a: ^Write_Linked_Array_List, index: i64) -> (res: Write_Cursor, err: Error) {
	return cursor_write_path(&a.write_cursor, []Path_Part{Linked_Array_List_Get{index = index}})
}

linked_array_list_append :: proc(a: ^Write_Linked_Array_List, data: Writeable_Data) -> Error {
	_, err := cursor_write_path(&a.write_cursor, []Path_Part{
		Linked_Array_List_Append{},
		Write_Data{data = data},
	})
	return err
}

linked_array_list_append_cursor :: proc(a: ^Write_Linked_Array_List) -> (res: Write_Cursor, err: Error) {
	return cursor_write_path(&a.write_cursor, []Path_Part{Linked_Array_List_Append{}})
}

linked_array_list_append_context :: proc(a: ^Write_Linked_Array_List, data: Writeable_Data, fn: Context_Function, user_data: rawptr = nil) -> Error {
	_, err := cursor_write_path(&a.write_cursor, []Path_Part{
		Linked_Array_List_Append{},
		Write_Data{data = data},
		Context{function = fn, user_data = user_data},
	})
	return err
}

linked_array_list_slice :: proc(a: ^Write_Linked_Array_List, offset, size: i64) -> Error {
	_, err := cursor_write_path(&a.write_cursor, []Path_Part{Linked_Array_List_Slice{offset = offset, size = size}})
	return err
}

linked_array_list_concat :: proc(a: ^Write_Linked_Array_List, list: Slot) -> Error {
	_, err := cursor_write_path(&a.write_cursor, []Path_Part{Linked_Array_List_Concat{list = list}})
	return err
}

linked_array_list_insert :: proc(a: ^Write_Linked_Array_List, index: i64, data: Writeable_Data) -> Error {
	_, err := cursor_write_path(&a.write_cursor, []Path_Part{
		Linked_Array_List_Insert{index = index},
		Write_Data{data = data},
	})
	return err
}

linked_array_list_insert_cursor :: proc(a: ^Write_Linked_Array_List, index: i64) -> (res: Write_Cursor, err: Error) {
	return cursor_write_path(&a.write_cursor, []Path_Part{Linked_Array_List_Insert{index = index}})
}

linked_array_list_remove :: proc(a: ^Write_Linked_Array_List, index: i64) -> Error {
	_, err := cursor_write_path(&a.write_cursor, []Path_Part{Linked_Array_List_Remove{index = index}})
	return err
}

// ============================================================================
// HashMap & CountedHashMap
// ============================================================================

Read_Hash_Map :: struct {
	cursor: Read_Cursor,
}

Write_Hash_Map :: struct {
	using read_hash_map: Read_Hash_Map,
	write_cursor:        Write_Cursor,
}

Read_Counted_Hash_Map :: struct {
	using read_hash_map: Read_Hash_Map,
}

Write_Counted_Hash_Map :: struct {
	using write_hash_map: Write_Hash_Map,
}

read_hash_map_init :: proc(cursor: Read_Cursor) -> (res: Read_Hash_Map, err: Error) {
	slot_ptr := cursor_resolved(cursor) or_return
	#partial switch slot_ptr.slot.tag {
	case .None, .Hash_Map, .Hash_Set:
		return Read_Hash_Map{cursor = cursor}, nil
	case:
		return {}, .Unexpected_Tag
	}
}

write_hash_map_init :: proc(cursor: Write_Cursor) -> (res: Write_Hash_Map, err: Error) {
	c := cursor
	wc := cursor_write_path(&c, []Path_Part{Hash_Map_Init{counted = false, set = false}}) or_return
	rm := read_hash_map_init(wc.read_cursor) or_return
	return Write_Hash_Map{read_hash_map = rm, write_cursor = wc}, nil
}

read_counted_hash_map_init :: proc(cursor: Read_Cursor) -> (res: Read_Counted_Hash_Map, err: Error) {
	slot_ptr := cursor_resolved(cursor) or_return
	#partial switch slot_ptr.slot.tag {
	case .None, .Counted_Hash_Map, .Counted_Hash_Set:
		return Read_Counted_Hash_Map{read_hash_map = Read_Hash_Map{cursor = cursor}}, nil
	case:
		return {}, .Unexpected_Tag
	}
}

write_counted_hash_map_init :: proc(cursor: Write_Cursor) -> (res: Write_Counted_Hash_Map, err: Error) {
	slot_ptr := cursor_resolved(cursor.read_cursor) or_return
	#partial switch slot_ptr.slot.tag {
	case .None, .Counted_Hash_Map, .Counted_Hash_Set:
	case:
		return {}, .Unexpected_Tag
	}
	c := cursor
	wc := cursor_write_path(&c, []Path_Part{Hash_Map_Init{counted = true, set = false}}) or_return
	rm := Read_Hash_Map{cursor = wc.read_cursor}
	return Write_Counted_Hash_Map{
		write_hash_map = Write_Hash_Map{read_hash_map = rm, write_cursor = wc},
	}, nil
}

hash_map_slot :: proc(m: Read_Hash_Map) -> (res: Slot, err: Error) {
	return cursor_slot(m.cursor)
}

hash_map_iterator :: proc(m: Read_Hash_Map) -> (res: Cursor_Iterator, err: Error) {
	return cursor_iterator(m.cursor)
}

hash_map_iterator_reverse :: proc(m: Read_Hash_Map) -> (res: Cursor_Iterator, err: Error) {
	return cursor_iterator_reverse(m.cursor)
}

counted_hash_map_count :: proc(m: Read_Counted_Hash_Map) -> (res: i64, err: Error) {
	return cursor_count(m.cursor)
}

hash_map_get_cursor_by_hash :: proc(m: Read_Hash_Map, hash: []u8) -> (Maybe(Read_Cursor), Error) {
	return cursor_read_path(m.cursor, []Path_Part{Hash_Map_Get{target = Hash_Map_Get_Value{hash = hash}}})
}

hash_map_get_slot_by_hash :: proc(m: Read_Hash_Map, hash: []u8) -> (Maybe(Slot), Error) {
	return cursor_read_path_slot(m.cursor, []Path_Part{Hash_Map_Get{target = Hash_Map_Get_Value{hash = hash}}})
}

hash_map_get_key_cursor_by_hash :: proc(m: Read_Hash_Map, hash: []u8) -> (Maybe(Read_Cursor), Error) {
	return cursor_read_path(m.cursor, []Path_Part{Hash_Map_Get{target = Hash_Map_Get_Key{hash = hash}}})
}

hash_map_get_key_slot_by_hash :: proc(m: Read_Hash_Map, hash: []u8) -> (Maybe(Slot), Error) {
	return cursor_read_path_slot(m.cursor, []Path_Part{Hash_Map_Get{target = Hash_Map_Get_Key{hash = hash}}})
}

hash_map_get_kv_pair_by_hash :: proc(m: Read_Hash_Map, hash: []u8, allocator := context.temp_allocator) -> (res: Maybe(Read_KV_Pair_Cursor), err: Error) {
	mc := cursor_read_path(m.cursor, []Path_Part{Hash_Map_Get{target = Hash_Map_Get_KV_Pair{hash = hash}}}) or_return
	c, ok := mc.?
	if !ok {
		return nil, nil
	}
	kv := cursor_read_kv_pair(c, allocator) or_return
	return kv, nil
}

hash_map_get_cursor :: proc(m: Read_Hash_Map, key: string) -> (Maybe(Read_Cursor), Error) {
	buf: [64]u8 = ---
	hash := database_digest_string_buf(m.cursor.db, key, buf[:])
	return hash_map_get_cursor_by_hash(m, hash)
}

hash_map_get_slot :: proc(m: Read_Hash_Map, key: string) -> (Maybe(Slot), Error) {
	buf: [64]u8 = ---
	hash := database_digest_string_buf(m.cursor.db, key, buf[:])
	return hash_map_get_slot_by_hash(m, hash)
}

hash_map_get_key_cursor :: proc(m: Read_Hash_Map, key: string) -> (Maybe(Read_Cursor), Error) {
	buf: [64]u8 = ---
	hash := database_digest_string_buf(m.cursor.db, key, buf[:])
	return hash_map_get_key_cursor_by_hash(m, hash)
}

hash_map_get_key_slot :: proc(m: Read_Hash_Map, key: string) -> (Maybe(Slot), Error) {
	buf: [64]u8 = ---
	hash := database_digest_string_buf(m.cursor.db, key, buf[:])
	return hash_map_get_key_slot_by_hash(m, hash)
}

hash_map_get_kv_pair :: proc(m: Read_Hash_Map, key: string, allocator := context.temp_allocator) -> (Maybe(Read_KV_Pair_Cursor), Error) {
	buf: [64]u8 = ---
	hash := database_digest_string_buf(m.cursor.db, key, buf[:])
	return hash_map_get_kv_pair_by_hash(m, hash, allocator)
}

hash_map_get_cursor_by_bytes :: proc(m: Read_Hash_Map, key: []u8) -> (Maybe(Read_Cursor), Error) {
	buf: [64]u8 = ---
	hash := database_digest_buf(m.cursor.db, key, buf[:])
	return hash_map_get_cursor_by_hash(m, hash)
}

hash_map_get_slot_by_bytes :: proc(m: Read_Hash_Map, key: []u8) -> (Maybe(Slot), Error) {
	buf: [64]u8 = ---
	hash := database_digest_buf(m.cursor.db, key, buf[:])
	return hash_map_get_slot_by_hash(m, hash)
}

hash_map_get_key_cursor_by_bytes :: proc(m: Read_Hash_Map, key: []u8) -> (Maybe(Read_Cursor), Error) {
	buf: [64]u8 = ---
	hash := database_digest_buf(m.cursor.db, key, buf[:])
	return hash_map_get_key_cursor_by_hash(m, hash)
}

hash_map_get_key_slot_by_bytes :: proc(m: Read_Hash_Map, key: []u8) -> (Maybe(Slot), Error) {
	buf: [64]u8 = ---
	hash := database_digest_buf(m.cursor.db, key, buf[:])
	return hash_map_get_key_slot_by_hash(m, hash)
}

hash_map_get_kv_pair_by_bytes :: proc(m: Read_Hash_Map, key: []u8, allocator := context.temp_allocator) -> (Maybe(Read_KV_Pair_Cursor), Error) {
	buf: [64]u8 = ---
	hash := database_digest_buf(m.cursor.db, key, buf[:])
	return hash_map_get_kv_pair_by_hash(m, hash, allocator)
}

hash_map_put_by_hash :: proc(m: ^Write_Hash_Map, hash: []u8, data: Writeable_Data) -> Error {
	_, err := cursor_write_path(&m.write_cursor, []Path_Part{
		Hash_Map_Get{target = Hash_Map_Get_Value{hash = hash}},
		Write_Data{data = data},
	})
	return err
}

hash_map_put_cursor_by_hash :: proc(m: ^Write_Hash_Map, hash: []u8) -> (res: Write_Cursor, err: Error) {
	return cursor_write_path(&m.write_cursor, []Path_Part{
		Hash_Map_Get{target = Hash_Map_Get_Value{hash = hash}},
	})
}

hash_map_put_key_by_hash :: proc(m: ^Write_Hash_Map, hash: []u8, data: Writeable_Data) -> Error {
	_, err := cursor_write_path(&m.write_cursor, []Path_Part{
		Hash_Map_Get{target = Hash_Map_Get_Key{hash = hash}},
		Write_Data{data = data, if_empty = true},
	})
	return err
}

hash_map_put_key_cursor_by_hash :: proc(m: ^Write_Hash_Map, hash: []u8) -> (res: Write_Cursor, err: Error) {
	return cursor_write_path(&m.write_cursor, []Path_Part{
		Hash_Map_Get{target = Hash_Map_Get_Key{hash = hash}},
	})
}

hash_map_remove_by_hash :: proc(m: ^Write_Hash_Map, hash: []u8) -> (res: bool, err: Error) {
	_, err = cursor_write_path(&m.write_cursor, []Path_Part{Hash_Map_Remove{hash = hash}})
	if err != nil {
		if err == .Key_Not_Found {
			return false, nil
		}
		return false, err
	}
	return true, nil
}

hash_map_put_key_and_value :: proc(m: ^Write_Hash_Map, hash: []u8, key: Writeable_Data, data: Writeable_Data) -> Error {
	_, err := cursor_write_path(&m.write_cursor, []Path_Part{
		Hash_Map_Get{target = Hash_Map_Get_KV_Pair{hash = hash}},
		Write_KV_Data{key = key, value = data},
	})
	return err
}

hash_map_put :: proc(m: ^Write_Hash_Map, key: string, data: Writeable_Data) -> Error {
	buf: [64]u8 = ---
	hash := database_digest_string_buf(m.cursor.db, key, buf[:])
	return hash_map_put_key_and_value(m, hash, key, data)
}

hash_map_put_cursor :: proc(m: ^Write_Hash_Map, key: string) -> (res: Write_Cursor, err: Error) {
	buf: [64]u8 = ---
	hash := database_digest_string_buf(m.cursor.db, key, buf[:])
	hash_map_put_key_by_hash(m, hash, key) or_return
	return hash_map_put_cursor_by_hash(m, hash)
}

hash_map_put_key :: proc(m: ^Write_Hash_Map, key: string, data: Writeable_Data) -> Error {
	buf: [64]u8 = ---
	hash := database_digest_string_buf(m.cursor.db, key, buf[:])
	return hash_map_put_key_by_hash(m, hash, data)
}

hash_map_put_key_cursor :: proc(m: ^Write_Hash_Map, key: string) -> (res: Write_Cursor, err: Error) {
	buf: [64]u8 = ---
	hash := database_digest_string_buf(m.cursor.db, key, buf[:])
	return hash_map_put_key_cursor_by_hash(m, hash)
}

hash_map_remove :: proc(m: ^Write_Hash_Map, key: string) -> (res: bool, err: Error) {
	buf: [64]u8 = ---
	hash := database_digest_string_buf(m.cursor.db, key, buf[:])
	return hash_map_remove_by_hash(m, hash)
}

hash_map_put_bytes :: proc(m: ^Write_Hash_Map, key: Bytes, data: Writeable_Data) -> Error {
	buf: [64]u8 = ---
	hash := database_digest_buf(m.cursor.db, key.value, buf[:])
	return hash_map_put_key_and_value(m, hash, key, data)
}

hash_map_put_cursor_by_bytes :: proc(m: ^Write_Hash_Map, key: Bytes) -> (res: Write_Cursor, err: Error) {
	buf: [64]u8 = ---
	hash := database_digest_buf(m.cursor.db, key.value, buf[:])
	hash_map_put_key_by_hash(m, hash, key) or_return
	return hash_map_put_cursor_by_hash(m, hash)
}

hash_map_put_key_by_bytes :: proc(m: ^Write_Hash_Map, key: Bytes, data: Writeable_Data) -> Error {
	buf: [64]u8 = ---
	hash := database_digest_buf(m.cursor.db, key.value, buf[:])
	return hash_map_put_key_by_hash(m, hash, data)
}

hash_map_put_key_cursor_by_bytes :: proc(m: ^Write_Hash_Map, key: Bytes) -> (res: Write_Cursor, err: Error) {
	buf: [64]u8 = ---
	hash := database_digest_buf(m.cursor.db, key.value, buf[:])
	return hash_map_put_key_cursor_by_hash(m, hash)
}

hash_map_remove_by_bytes :: proc(m: ^Write_Hash_Map, key: Bytes) -> (res: bool, err: Error) {
	buf: [64]u8 = ---
	hash := database_digest_buf(m.cursor.db, key.value, buf[:])
	return hash_map_remove_by_hash(m, hash)
}

// ============================================================================
// HashSet & CountedHashSet
// ============================================================================

Read_Hash_Set :: struct {
	cursor: Read_Cursor,
}

Write_Hash_Set :: struct {
	using read_hash_set: Read_Hash_Set,
	write_cursor:        Write_Cursor,
}

Read_Counted_Hash_Set :: struct {
	using read_hash_set: Read_Hash_Set,
}

Write_Counted_Hash_Set :: struct {
	using write_hash_set: Write_Hash_Set,
}

read_hash_set_init :: proc(cursor: Read_Cursor) -> (res: Read_Hash_Set, err: Error) {
	slot_ptr := cursor_resolved(cursor) or_return
	#partial switch slot_ptr.slot.tag {
	case .None, .Hash_Map, .Hash_Set:
		return Read_Hash_Set{cursor = cursor}, nil
	case:
		return {}, .Unexpected_Tag
	}
}

write_hash_set_init :: proc(cursor: Write_Cursor) -> (res: Write_Hash_Set, err: Error) {
	c := cursor
	wc := cursor_write_path(&c, []Path_Part{Hash_Map_Init{counted = false, set = true}}) or_return
	rs := read_hash_set_init(wc.read_cursor) or_return
	return Write_Hash_Set{read_hash_set = rs, write_cursor = wc}, nil
}

read_counted_hash_set_init :: proc(cursor: Read_Cursor) -> (res: Read_Counted_Hash_Set, err: Error) {
	slot_ptr := cursor_resolved(cursor) or_return
	#partial switch slot_ptr.slot.tag {
	case .None, .Counted_Hash_Map, .Counted_Hash_Set:
		return Read_Counted_Hash_Set{read_hash_set = Read_Hash_Set{cursor = cursor}}, nil
	case:
		return {}, .Unexpected_Tag
	}
}

write_counted_hash_set_init :: proc(cursor: Write_Cursor) -> (res: Write_Counted_Hash_Set, err: Error) {
	slot_ptr := cursor_resolved(cursor.read_cursor) or_return
	#partial switch slot_ptr.slot.tag {
	case .None, .Counted_Hash_Map, .Counted_Hash_Set:
	case:
		return {}, .Unexpected_Tag
	}
	c := cursor
	wc := cursor_write_path(&c, []Path_Part{Hash_Map_Init{counted = true, set = true}}) or_return
	rs := Read_Hash_Set{cursor = wc.read_cursor}
	return Write_Counted_Hash_Set{
		write_hash_set = Write_Hash_Set{read_hash_set = rs, write_cursor = wc},
	}, nil
}

hash_set_slot :: proc(s: Read_Hash_Set) -> (res: Slot, err: Error) {
	return cursor_slot(s.cursor)
}

hash_set_iterator :: proc(s: Read_Hash_Set) -> (res: Cursor_Iterator, err: Error) {
	return cursor_iterator(s.cursor)
}

hash_set_iterator_reverse :: proc(s: Read_Hash_Set) -> (res: Cursor_Iterator, err: Error) {
	return cursor_iterator_reverse(s.cursor)
}

counted_hash_set_count :: proc(s: Read_Counted_Hash_Set) -> (res: i64, err: Error) {
	return cursor_count(s.cursor)
}

hash_set_get_cursor_by_hash :: proc(s: Read_Hash_Set, hash: []u8) -> (Maybe(Read_Cursor), Error) {
	return cursor_read_path(s.cursor, []Path_Part{Hash_Map_Get{target = Hash_Map_Get_Key{hash = hash}}})
}

hash_set_get_slot_by_hash :: proc(s: Read_Hash_Set, hash: []u8) -> (Maybe(Slot), Error) {
	return cursor_read_path_slot(s.cursor, []Path_Part{Hash_Map_Get{target = Hash_Map_Get_Key{hash = hash}}})
}

hash_set_get_cursor :: proc(s: Read_Hash_Set, key: string) -> (Maybe(Read_Cursor), Error) {
	buf: [64]u8 = ---
	hash := database_digest_string_buf(s.cursor.db, key, buf[:])
	return hash_set_get_cursor_by_hash(s, hash)
}

hash_set_get_slot :: proc(s: Read_Hash_Set, key: string) -> (Maybe(Slot), Error) {
	buf: [64]u8 = ---
	hash := database_digest_string_buf(s.cursor.db, key, buf[:])
	return hash_set_get_slot_by_hash(s, hash)
}

hash_set_get_cursor_by_bytes :: proc(s: Read_Hash_Set, key: Bytes) -> (Maybe(Read_Cursor), Error) {
	buf: [64]u8 = ---
	hash := database_digest_buf(s.cursor.db, key.value, buf[:])
	return hash_set_get_cursor_by_hash(s, hash)
}

hash_set_get_slot_by_bytes :: proc(s: Read_Hash_Set, key: Bytes) -> (Maybe(Slot), Error) {
	buf: [64]u8 = ---
	hash := database_digest_buf(s.cursor.db, key.value, buf[:])
	return hash_set_get_slot_by_hash(s, hash)
}

hash_set_put_by_hash :: proc(s: ^Write_Hash_Set, hash: []u8, data: Writeable_Data) -> Error {
	_, err := cursor_write_path(&s.write_cursor, []Path_Part{
		Hash_Map_Get{target = Hash_Map_Get_Key{hash = hash}},
		Write_Data{data = data, if_empty = true},
	})
	return err
}

hash_set_put_cursor_by_hash :: proc(s: ^Write_Hash_Set, hash: []u8) -> (res: Write_Cursor, err: Error) {
	return cursor_write_path(&s.write_cursor, []Path_Part{
		Hash_Map_Get{target = Hash_Map_Get_Key{hash = hash}},
	})
}

hash_set_remove_by_hash :: proc(s: ^Write_Hash_Set, hash: []u8) -> (res: bool, err: Error) {
	_, err = cursor_write_path(&s.write_cursor, []Path_Part{Hash_Map_Remove{hash = hash}})
	if err != nil {
		if err == .Key_Not_Found {
			return false, nil
		}
		return false, err
	}
	return true, nil
}

hash_set_put :: proc(s: ^Write_Hash_Set, key: string) -> Error {
	buf: [64]u8 = ---
	hash := database_digest_string_buf(s.cursor.db, key, buf[:])
	return hash_set_put_by_hash(s, hash, key)
}

hash_set_put_cursor :: proc(s: ^Write_Hash_Set, key: string) -> (res: Write_Cursor, err: Error) {
	buf: [64]u8 = ---
	hash := database_digest_string_buf(s.cursor.db, key, buf[:])
	return hash_set_put_cursor_by_hash(s, hash)
}

hash_set_remove :: proc(s: ^Write_Hash_Set, key: string) -> (res: bool, err: Error) {
	buf: [64]u8 = ---
	hash := database_digest_string_buf(s.cursor.db, key, buf[:])
	return hash_set_remove_by_hash(s, hash)
}

hash_set_put_bytes :: proc(s: ^Write_Hash_Set, key: Bytes) -> Error {
	buf: [64]u8 = ---
	hash := database_digest_buf(s.cursor.db, key.value, buf[:])
	return hash_set_put_by_hash(s, hash, key)
}

hash_set_put_cursor_by_bytes :: proc(s: ^Write_Hash_Set, key: Bytes) -> (res: Write_Cursor, err: Error) {
	buf: [64]u8 = ---
	hash := database_digest_buf(s.cursor.db, key.value, buf[:])
	return hash_set_put_cursor_by_hash(s, hash)
}

hash_set_remove_by_bytes :: proc(s: ^Write_Hash_Set, key: Bytes) -> (res: bool, err: Error) {
	buf: [64]u8 = ---
	hash := database_digest_buf(s.cursor.db, key.value, buf[:])
	return hash_set_remove_by_hash(s, hash)
}

// ============================================================================
// SortedMap & SortedSet
// ============================================================================

Read_Sorted_Map :: struct {
	cursor: Read_Cursor,
}

Write_Sorted_Map :: struct {
	using read_sorted_map: Read_Sorted_Map,
	write_cursor:          Write_Cursor,
}

Read_Sorted_Set :: struct {
	cursor: Read_Cursor,
}

Write_Sorted_Set :: struct {
	using read_sorted_set: Read_Sorted_Set,
	write_cursor:          Write_Cursor,
}

read_sorted_map_init :: proc(cursor: Read_Cursor) -> (res: Read_Sorted_Map, err: Error) {
	slot_ptr := cursor_resolved(cursor) or_return
	#partial switch slot_ptr.slot.tag {
	case .None, .Sorted_Map, .Sorted_Set:
		return Read_Sorted_Map{cursor = cursor}, nil
	case:
		return {}, .Unexpected_Tag
	}
}

write_sorted_map_init :: proc(cursor: Write_Cursor) -> (res: Write_Sorted_Map, err: Error) {
	c := cursor
	wc := cursor_write_path(&c, []Path_Part{Sorted_Map_Init{set = false}}) or_return
	rm := read_sorted_map_init(wc.read_cursor) or_return
	return Write_Sorted_Map{read_sorted_map = rm, write_cursor = wc}, nil
}

sorted_map_slot :: proc(m: Read_Sorted_Map) -> (res: Slot, err: Error) {
	return cursor_slot(m.cursor)
}

sorted_map_count :: proc(m: Read_Sorted_Map) -> (res: i64, err: Error) {
	return cursor_count(m.cursor)
}

sorted_map_iterator :: proc(m: Read_Sorted_Map) -> (res: Cursor_Iterator, err: Error) {
	return cursor_iterator(m.cursor)
}

sorted_map_iterator_from :: proc(m: Read_Sorted_Map, start_key: []u8) -> (res: Cursor_Iterator, err: Error) {
	return cursor_iterator_sorted_from_key(m.cursor, start_key)
}

sorted_map_iterator_from_string :: proc(m: Read_Sorted_Map, start_key: string) -> (res: Cursor_Iterator, err: Error) {
	return cursor_iterator_sorted_from_key(m.cursor, transmute([]u8)start_key)
}

sorted_map_iterator_from_index :: proc(m: Read_Sorted_Map, start_index: i64) -> (res: Cursor_Iterator, err: Error) {
	return cursor_iterator_sorted_from_index(m.cursor, start_index)
}

sorted_map_iterator_reverse :: proc(m: Read_Sorted_Map) -> (res: Cursor_Iterator, err: Error) {
	return cursor_iterator_reverse(m.cursor)
}

sorted_map_iterator_reverse_from :: proc(m: Read_Sorted_Map, upper_key: []u8, inclusive: bool = true) -> (res: Cursor_Iterator, err: Error) {
	return cursor_iterator_sorted_reverse_from_key(m.cursor, upper_key, inclusive)
}

sorted_map_iterator_reverse_from_string :: proc(m: Read_Sorted_Map, upper_key: string, inclusive: bool = true) -> (res: Cursor_Iterator, err: Error) {
	return cursor_iterator_sorted_reverse_from_key(m.cursor, transmute([]u8)upper_key, inclusive)
}

sorted_map_iterator_reverse_from_index :: proc(m: Read_Sorted_Map, start_index: i64) -> (res: Cursor_Iterator, err: Error) {
	return cursor_iterator_sorted_reverse_from_index(m.cursor, start_index)
}

sorted_map_get_cursor_by_bytes :: proc(m: Read_Sorted_Map, key: []u8) -> (Maybe(Read_Cursor), Error) {
	return cursor_read_path(m.cursor, []Path_Part{Sorted_Map_Get{target = Sorted_Map_Get_Value{key = key}}})
}

sorted_map_get_slot_by_bytes :: proc(m: Read_Sorted_Map, key: []u8) -> (Maybe(Slot), Error) {
	return cursor_read_path_slot(m.cursor, []Path_Part{Sorted_Map_Get{target = Sorted_Map_Get_Value{key = key}}})
}

sorted_map_get_kv_pair_by_bytes :: proc(m: Read_Sorted_Map, key: []u8, allocator := context.temp_allocator) -> (res: Maybe(Read_KV_Pair_Cursor), err: Error) {
	mc := cursor_read_path(m.cursor, []Path_Part{Sorted_Map_Get{target = Sorted_Map_Get_KV_Pair{key = key}}}) or_return
	c, ok := mc.?
	if !ok {
		return nil, nil
	}
	kv := cursor_read_kv_pair(c, allocator) or_return
	return kv, nil
}

sorted_map_get_index_kv_pair :: proc(m: Read_Sorted_Map, index: i64, allocator := context.temp_allocator) -> (res: Maybe(Read_KV_Pair_Cursor), err: Error) {
	mc := cursor_read_path(m.cursor, []Path_Part{Sorted_Map_Get_Index{index = index}}) or_return
	c, ok := mc.?
	if !ok {
		return nil, nil
	}
	kv := cursor_read_kv_pair(c, allocator) or_return
	return kv, nil
}

sorted_map_rank_by_bytes :: proc(m: Read_Sorted_Map, key: []u8) -> (res: i64, err: Error) {
	slot_ptr := cursor_resolved(m.cursor) or_return
	if slot_ptr.slot.tag == .None {
		return 0, nil
	}
	hb: [BTREE_HEADER_LENGTH]u8
	core_read_exact_at(m.cursor.db.core, slot_ptr.slot.value, hb[:]) or_return
	header := btree_header_from_bytes(hb) or_return
	return sorted_rank(m.cursor.db, header.root_ptr, key)
}

sorted_map_get_cursor :: proc(m: Read_Sorted_Map, key: string) -> (Maybe(Read_Cursor), Error) {
	return sorted_map_get_cursor_by_bytes(m, transmute([]u8)key)
}

sorted_map_get_slot :: proc(m: Read_Sorted_Map, key: string) -> (Maybe(Slot), Error) {
	return sorted_map_get_slot_by_bytes(m, transmute([]u8)key)
}

sorted_map_get_kv_pair :: proc(m: Read_Sorted_Map, key: string, allocator := context.temp_allocator) -> (Maybe(Read_KV_Pair_Cursor), Error) {
	return sorted_map_get_kv_pair_by_bytes(m, transmute([]u8)key, allocator)
}

sorted_map_rank :: proc(m: Read_Sorted_Map, key: string) -> (res: i64, err: Error) {
	return sorted_map_rank_by_bytes(m, transmute([]u8)key)
}

sorted_map_put_by_bytes :: proc(m: ^Write_Sorted_Map, key: []u8, data: Writeable_Data) -> Error {
	_, err := cursor_write_path(&m.write_cursor, []Path_Part{
		Sorted_Map_Get{target = Sorted_Map_Get_Value{key = key}},
		Write_Data{data = data},
	})
	return err
}

sorted_map_put_cursor_by_bytes :: proc(m: ^Write_Sorted_Map, key: []u8) -> (res: Write_Cursor, err: Error) {
	return cursor_write_path(&m.write_cursor, []Path_Part{Sorted_Map_Get{target = Sorted_Map_Get_Value{key = key}}})
}

sorted_map_remove_by_bytes :: proc(m: ^Write_Sorted_Map, key: []u8) -> (res: bool, err: Error) {
	_, err = cursor_write_path(&m.write_cursor, []Path_Part{Sorted_Map_Remove{key = key}})
	if err != nil {
		if err == .Key_Not_Found {
			return false, nil
		}
		return false, err
	}
	return true, nil
}

sorted_map_put :: proc(m: ^Write_Sorted_Map, key: string, data: Writeable_Data) -> Error {
	return sorted_map_put_by_bytes(m, transmute([]u8)key, data)
}

sorted_map_put_cursor :: proc(m: ^Write_Sorted_Map, key: string) -> (res: Write_Cursor, err: Error) {
	return sorted_map_put_cursor_by_bytes(m, transmute([]u8)key)
}

sorted_map_remove :: proc(m: ^Write_Sorted_Map, key: string) -> (res: bool, err: Error) {
	return sorted_map_remove_by_bytes(m, transmute([]u8)key)
}

// SortedSet

read_sorted_set_init :: proc(cursor: Read_Cursor) -> (res: Read_Sorted_Set, err: Error) {
	slot_ptr := cursor_resolved(cursor) or_return
	#partial switch slot_ptr.slot.tag {
	case .None, .Sorted_Map, .Sorted_Set:
		return Read_Sorted_Set{cursor = cursor}, nil
	case:
		return {}, .Unexpected_Tag
	}
}

write_sorted_set_init :: proc(cursor: Write_Cursor) -> (res: Write_Sorted_Set, err: Error) {
	c := cursor
	wc := cursor_write_path(&c, []Path_Part{Sorted_Map_Init{set = true}}) or_return
	rs := read_sorted_set_init(wc.read_cursor) or_return
	return Write_Sorted_Set{read_sorted_set = rs, write_cursor = wc}, nil
}

sorted_set_slot :: proc(s: Read_Sorted_Set) -> (res: Slot, err: Error) {
	return cursor_slot(s.cursor)
}

sorted_set_count :: proc(s: Read_Sorted_Set) -> (res: i64, err: Error) {
	return cursor_count(s.cursor)
}

sorted_set_iterator :: proc(s: Read_Sorted_Set) -> (res: Cursor_Iterator, err: Error) {
	return cursor_iterator(s.cursor)
}

sorted_set_iterator_from :: proc(s: Read_Sorted_Set, start_key: []u8) -> (res: Cursor_Iterator, err: Error) {
	return cursor_iterator_sorted_from_key(s.cursor, start_key)
}

sorted_set_iterator_from_string :: proc(s: Read_Sorted_Set, start_key: string) -> (res: Cursor_Iterator, err: Error) {
	return cursor_iterator_sorted_from_key(s.cursor, transmute([]u8)start_key)
}

sorted_set_iterator_from_index :: proc(s: Read_Sorted_Set, start_index: i64) -> (res: Cursor_Iterator, err: Error) {
	return cursor_iterator_sorted_from_index(s.cursor, start_index)
}

sorted_set_iterator_reverse :: proc(s: Read_Sorted_Set) -> (res: Cursor_Iterator, err: Error) {
	return cursor_iterator_reverse(s.cursor)
}

sorted_set_iterator_reverse_from :: proc(s: Read_Sorted_Set, upper_key: []u8, inclusive: bool = true) -> (res: Cursor_Iterator, err: Error) {
	return cursor_iterator_sorted_reverse_from_key(s.cursor, upper_key, inclusive)
}

sorted_set_iterator_reverse_from_string :: proc(s: Read_Sorted_Set, upper_key: string, inclusive: bool = true) -> (res: Cursor_Iterator, err: Error) {
	return cursor_iterator_sorted_reverse_from_key(s.cursor, transmute([]u8)upper_key, inclusive)
}

sorted_set_iterator_reverse_from_index :: proc(s: Read_Sorted_Set, start_index: i64) -> (res: Cursor_Iterator, err: Error) {
	return cursor_iterator_sorted_reverse_from_index(s.cursor, start_index)
}

sorted_set_get_index_kv_pair :: proc(s: Read_Sorted_Set, index: i64, allocator := context.temp_allocator) -> (res: Maybe(Read_KV_Pair_Cursor), err: Error) {
	mc := cursor_read_path(s.cursor, []Path_Part{Sorted_Map_Get_Index{index = index}}) or_return
	c, ok := mc.?
	if !ok {
		return nil, nil
	}
	kv := cursor_read_kv_pair(c, allocator) or_return
	return kv, nil
}

sorted_set_contains_by_bytes :: proc(s: Read_Sorted_Set, key: []u8) -> (res: bool, err: Error) {
	mc := cursor_read_path(s.cursor, []Path_Part{Sorted_Map_Get{target = Sorted_Map_Get_Key{key = key}}}) or_return
	_, ok := mc.?
	return ok, nil
}

sorted_set_contains :: proc(s: Read_Sorted_Set, key: string) -> (res: bool, err: Error) {
	return sorted_set_contains_by_bytes(s, transmute([]u8)key)
}

sorted_set_rank_by_bytes :: proc(s: Read_Sorted_Set, key: []u8) -> (res: i64, err: Error) {
	slot_ptr := cursor_resolved(s.cursor) or_return
	if slot_ptr.slot.tag == .None {
		return 0, nil
	}
	hb: [BTREE_HEADER_LENGTH]u8
	core_read_exact_at(s.cursor.db.core, slot_ptr.slot.value, hb[:]) or_return
	header := btree_header_from_bytes(hb) or_return
	return sorted_rank(s.cursor.db, header.root_ptr, key)
}

sorted_set_rank :: proc(s: Read_Sorted_Set, key: string) -> (res: i64, err: Error) {
	return sorted_set_rank_by_bytes(s, transmute([]u8)key)
}

sorted_set_put_by_bytes :: proc(s: ^Write_Sorted_Set, key: []u8) -> Error {
	_, err := cursor_write_path(&s.write_cursor, []Path_Part{Sorted_Map_Get{target = Sorted_Map_Get_Key{key = key}}})
	return err
}

sorted_set_put :: proc(s: ^Write_Sorted_Set, key: string) -> Error {
	return sorted_set_put_by_bytes(s, transmute([]u8)key)
}

sorted_set_remove_by_bytes :: proc(s: ^Write_Sorted_Set, key: []u8) -> (res: bool, err: Error) {
	_, err = cursor_write_path(&s.write_cursor, []Path_Part{Sorted_Map_Remove{key = key}})
	if err != nil {
		if err == .Key_Not_Found {
			return false, nil
		}
		return false, err
	}
	return true, nil
}

sorted_set_remove :: proc(s: ^Write_Sorted_Set, key: string) -> (res: bool, err: Error) {
	return sorted_set_remove_by_bytes(s, transmute([]u8)key)
}
