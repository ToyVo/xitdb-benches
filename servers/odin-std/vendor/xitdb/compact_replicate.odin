package xitdb

import "base:intrinsics"
import "base:runtime"
import "core:encoding/endian"

// ============================================================================
// Offset_Map (Memory_Offset_Map & File_Offset_Map)
// ============================================================================

Memory_Offset_Entry :: struct {
	key_plus_one: i64,
	val:          i64,
}

Memory_Offset_Map :: struct {
	entries:   []Memory_Offset_Entry,
	count:     int,
	allocator: runtime.Allocator,
}

File_Offset_Map :: struct {
	m: Write_Hash_Map,
}

Offset_Map :: union {
	Memory_Offset_Map,
	File_Offset_Map,
}

memory_offset_map_init :: proc(allocator := context.allocator) -> Memory_Offset_Map {
	return Memory_Offset_Map{allocator = allocator}
}

memory_offset_map_destroy :: proc(m: ^Memory_Offset_Map) {
	if m.entries != nil {
		delete(m.entries, m.allocator)
		m.entries = nil
	}
	m.count = 0
}

@(private)
_memory_offset_map_grow :: proc(m: ^Memory_Offset_Map) -> Error {
	old_entries := m.entries
	new_cap := 128 if len(old_entries) == 0 else len(old_entries) * 2
	alloc := m.allocator if m.allocator.procedure != nil else context.allocator
	new_entries, alloc_err := make([]Memory_Offset_Entry, new_cap, alloc)
	if alloc_err != nil {
		return Xitdb_Error.Write_Failed
	}
	mask := new_cap - 1
	#no_bounds_check for e in old_entries {
		if e.key_plus_one != 0 {
			h := u64(e.key_plus_one - 1) * 0x9e3779b97f4a7c15
			idx := int((h >> 32) ~ h) & mask
			for new_entries[idx].key_plus_one != 0 {
				idx = (idx + 1) & mask
			}
			new_entries[idx] = e
		}
	}
	if old_entries != nil {
		delete(old_entries, alloc)
	}
	m.entries = new_entries
	return nil
}

file_offset_map_init :: proc(cursor: Write_Cursor) -> (res: File_Offset_Map, err: Error) {
	if cursor.db.header.hash_size < 8 {
		return {}, .Invalid_Hash_Size
	}
	m := write_hash_map_init(cursor) or_return
	return File_Offset_Map{m = m}, nil
}

@(private)
_file_offset_map_key :: proc(m: ^File_Offset_Map, offset: i64, buf: []u8) -> []u8 {
	hash_size := int(m.m.cursor.db.header.hash_size)
	key := buf[:hash_size] if hash_size <= len(buf) else make([]u8, hash_size, context.temp_allocator)
	for i in 0 ..< hash_size - 8 {
		key[i] = 0
	}
	endian.unchecked_put_u64be(key[hash_size - 8:], u64(offset))
	return key
}

offset_map_reset :: proc(om: ^Offset_Map) -> Error {
	switch &m in om {
	case Memory_Offset_Map:
		if len(m.entries) > 0 && m.count > 0 {
			intrinsics.mem_zero(raw_data(m.entries), len(m.entries) * size_of(Memory_Offset_Entry))
		}
		m.count = 0
		return nil
	case File_Offset_Map:
		cursor := m.m.write_cursor
		cursor_write(&cursor, nil) or_return
		m.m = write_hash_map_init(cursor) or_return
		return nil
	}
	return nil
}

offset_map_get :: #force_inline proc(om: ^Offset_Map, source_offset: i64) -> (target_offset: i64, found: bool, err: Error) {
	switch &m in om {
	case Memory_Offset_Map:
		if m.count == 0 {
			return 0, false, nil
		}
		kp1 := source_offset + 1
		mask := len(m.entries) - 1
		h := u64(source_offset) * 0x9e3779b97f4a7c15
		idx := int((h >> 32) ~ h) & mask
		#no_bounds_check for {
			e := m.entries[idx]
			if e.key_plus_one == kp1 {
				return e.val, true, nil
			}
			if e.key_plus_one == 0 {
				return 0, false, nil
			}
			idx = (idx + 1) & mask
		}
	case File_Offset_Map:
		key_buf: [64]u8 = ---
		key := _file_offset_map_key(&m, source_offset, key_buf[:])
		mc := hash_map_get_cursor_by_hash(m.m.read_hash_map, key) or_return
		c, ok := mc.?
		if !ok {
			return 0, false, nil
		}
		u := cursor_read_uint(c) or_return
		return i64(u), true, nil
	}
	return 0, false, nil
}

offset_map_put :: #force_inline proc(om: ^Offset_Map, source_offset, target_offset: i64) -> Error {
	switch &m in om {
	case Memory_Offset_Map:
		if (m.count + 1) * 10 > len(m.entries) * 7 {
			_memory_offset_map_grow(&m) or_return
		}
		kp1 := source_offset + 1
		mask := len(m.entries) - 1
		h := u64(source_offset) * 0x9e3779b97f4a7c15
		idx := int((h >> 32) ~ h) & mask
		#no_bounds_check for {
			e := &m.entries[idx]
			if e.key_plus_one == 0 {
				e.key_plus_one = kp1
				e.val = target_offset
				m.count += 1
				return nil
			}
			if e.key_plus_one == kp1 {
				e.val = target_offset
				return nil
			}
			idx = (idx + 1) & mask
		}
	case File_Offset_Map:
		key_buf: [64]u8 = ---
		key := _file_offset_map_key(&m, source_offset, key_buf[:])
		return hash_map_put_by_hash(&m.m, key, Uint{u64(target_offset)})
	}
	return nil
}

offset_map_destroy :: proc(om: ^Offset_Map) {
	#partial switch &m in om {
	case Memory_Offset_Map:
		memory_offset_map_destroy(&m)
	}
}

// ============================================================================
// Compaction
// ============================================================================

@(private)
_Compactor :: struct {
	source_core: ^Core,
	target_core: ^Core,
	hash_size:   u16,
	offset_map:  ^Offset_Map,
}

@(private)
_compactor_reserve_block :: #force_inline proc(c: ^_Compactor, size: int) -> (res: i64, err: Error) {
	#partial switch &dst in c.target_core {
	case Core_Memory:
		offset := i64(len(dst.buf))
		new_len := int(offset) + size
		if max_sz, ok := dst.max_size.?; ok && i64(new_len) > max_sz {
			return 0, Xitdb_Error.Write_Failed
		}
		if new_len > cap(dst.buf) {
			_memory_reserve(&dst, max(new_len, cap(dst.buf) * 2 + 4096)) or_return
		}
		_memory_resize(&dst, new_len) or_return
		dst.pos = i64(new_len)
		return offset, nil
	}
	offset := core_length(c.target_core) or_return
	core_seek_to(c.target_core, offset) or_return
	if size <= 512 {
		zeros: [512]u8
		core_write_all(c.target_core, zeros[:size]) or_return
		return offset, nil
	}
	zeros := make([]u8, size, context.temp_allocator)
	core_write_all(c.target_core, zeros) or_return
	return offset, nil
}

@(private)
_compactor_remap_slot :: proc(c: ^_Compactor, slot: Slot) -> (res: Slot, err: Error) {
	tag_validate(slot.tag) or_return
	new_offset: i64
	#partial switch slot.tag {
	case .None, .Uint, .Int, .Float, .Short_Bytes:
		return slot, nil

	case .Bytes:
		new_offset = _compactor_remap_bytes(c, slot) or_return

	case .Index:
		mapped, found := offset_map_get(c.offset_map, slot.value) or_return
		if found {
			new_offset = mapped
		} else {
			new_offset = _compactor_reserve_block(c, INDEX_BLOCK_SIZE) or_return
			offset_map_put(c.offset_map, slot.value, new_offset) or_return
			_compactor_populate_index(c, slot.value, new_offset) or_return
		}

	case .Array_List:
		mapped, found := offset_map_get(c.offset_map, slot.value) or_return
		if found {
			new_offset = mapped
		} else {
			new_offset = _compactor_reserve_block(c, ARRAY_LIST_HEADER_LENGTH) or_return
			offset_map_put(c.offset_map, slot.value, new_offset) or_return
			_compactor_populate_array_list(c, slot.value, new_offset) or_return
		}

	case .Linked_Array_List:
		mapped, found := offset_map_get(c.offset_map, slot.value) or_return
		if found {
			new_offset = mapped
		} else {
			new_offset = _compactor_reserve_block(c, BTREE_HEADER_LENGTH) or_return
			offset_map_put(c.offset_map, slot.value, new_offset) or_return
			_compactor_populate_btree(c, slot.value, new_offset) or_return
		}

	case .Hash_Map, .Hash_Set:
		mapped, found := offset_map_get(c.offset_map, slot.value) or_return
		if found {
			new_offset = mapped
		} else {
			new_offset = _compactor_reserve_block(c, INDEX_BLOCK_SIZE) or_return
			offset_map_put(c.offset_map, slot.value, new_offset) or_return
			_compactor_populate_hash_map(c, slot.value, new_offset, false) or_return
		}

	case .Counted_Hash_Map, .Counted_Hash_Set:
		mapped, found := offset_map_get(c.offset_map, slot.value) or_return
		if found {
			new_offset = mapped
		} else {
			new_offset = _compactor_reserve_block(c, INDEX_BLOCK_SIZE + 8) or_return
			offset_map_put(c.offset_map, slot.value, new_offset) or_return
			_compactor_populate_hash_map(c, slot.value, new_offset, true) or_return
		}

	case .KV_Pair:
		mapped, found := offset_map_get(c.offset_map, slot.value) or_return
		if found {
			new_offset = mapped
		} else {
			new_offset = _compactor_reserve_block(c, kv_pair_length(int(c.hash_size))) or_return
			offset_map_put(c.offset_map, slot.value, new_offset) or_return
			_compactor_populate_kv_pair(c, slot.value, new_offset, .KV_Pair) or_return
		}

	case .Sorted_KV_Pair:
		mapped, found := offset_map_get(c.offset_map, slot.value) or_return
		if found {
			new_offset = mapped
		} else {
			new_offset = _compactor_reserve_block(c, SORTED_KV_PAIR_LENGTH) or_return
			offset_map_put(c.offset_map, slot.value, new_offset) or_return
			_compactor_populate_kv_pair(c, slot.value, new_offset, .Sorted_KV_Pair) or_return
		}

	case .Sorted_Map, .Sorted_Set:
		mapped, found := offset_map_get(c.offset_map, slot.value) or_return
		if found {
			new_offset = mapped
		} else {
			new_offset = _compactor_reserve_block(c, BTREE_HEADER_LENGTH) or_return
			offset_map_put(c.offset_map, slot.value, new_offset) or_return
			_compactor_populate_sorted_map(c, slot.value, new_offset) or_return
		}

	case:
		return {}, .Unexpected_Tag
	}
	return Slot{value = new_offset, tag = slot.tag, full = slot.full}, nil
}

@(private)
_compactor_remap_bytes :: proc(c: ^_Compactor, slot: Slot) -> (res: i64, err: Error) {
	mapped, found := offset_map_get(c.offset_map, slot.value) or_return
	if found {
		return mapped, nil
	}
	length := core_read_long_at(c.source_core, slot.value) or_return
	format_tag_size: i64 = 2 if slot.full else 0
	total_payload := length + format_tag_size

	new_offset := core_length(c.target_core) or_return
	core_seek_to(c.target_core, new_offset) or_return
	core_write_long(c.target_core, length) or_return

	if total_payload > 0 {
		payload_offset := slot.value + 8
		#partial switch &src in c.source_core {
		case Core_Memory:
			if payload_offset >= 0 && payload_offset + total_payload <= i64(len(src.buf)) {
				slice := src.buf[int(payload_offset):int(payload_offset + total_payload)]
				core_write_all(c.target_core, slice) or_return
				offset_map_put(c.offset_map, slot.value, new_offset) or_return
				return new_offset, nil
			}
		}
		buf: [4096]u8 = ---
		remaining := total_payload
		cur_offset := payload_offset
		for remaining > 0 {
			chunk := min(remaining, i64(len(buf)))
			core_read_exact_at(c.source_core, cur_offset, buf[:chunk]) or_return
			core_write_all(c.target_core, buf[:chunk]) or_return
			cur_offset += chunk
			remaining -= chunk
		}
	}
	offset_map_put(c.offset_map, slot.value, new_offset) or_return
	return new_offset, nil
}

@(private)
_compactor_populate_index :: proc(c: ^_Compactor, source_offset, target_offset: i64) -> Error {
	block_bytes: [INDEX_BLOCK_SIZE]u8 = ---
	core_read_exact_at(c.source_core, source_offset, block_bytes[:]) or_return

	for i in 0 ..< SLOT_COUNT {
		tag := Tag(block_bytes[i * SLOT_LENGTH] & 0x7F)
		tag_validate(tag) or_return
		#partial switch tag {
		case .None, .Uint, .Int, .Float, .Short_Bytes:
			continue
		}
		sb: [SLOT_LENGTH]u8 = ---
		copy(sb[:], block_bytes[i * SLOT_LENGTH : (i + 1) * SLOT_LENGTH])
		child_slot := slot_from_bytes_raw(sb)
		remapped := _compactor_remap_slot(c, child_slot) or_return
		out_sb := slot_to_bytes(remapped)
		copy(block_bytes[i * SLOT_LENGTH : (i + 1) * SLOT_LENGTH], out_sb[:])
	}

	core_seek_to(c.target_core, target_offset) or_return
	return core_write_all(c.target_core, block_bytes[:])
}

@(private)
_compactor_remap_array_list_index :: proc(c: ^_Compactor, source_offset, size: i64, shift: u8) -> (res: i64, err: Error) {
	child_size := i64(1) << (u64(shift) * BIT_COUNT)
	if child_size <= max(i64) / SLOT_COUNT && size == child_size * SLOT_COUNT {
		slot := _compactor_remap_slot(c, Slot{value = source_offset, tag = .Index}) or_return
		return slot.value, nil
	}

	target_offset := _compactor_reserve_block(c, INDEX_BLOCK_SIZE) or_return
	block_bytes: [INDEX_BLOCK_SIZE]u8 = ---
	core_read_exact_at(c.source_core, source_offset, block_bytes[:]) or_return
	remapped_block: [INDEX_BLOCK_SIZE]u8
	remaining := size
	for i := 0; i < SLOT_COUNT && remaining > 0; i += 1 {
		sb: [SLOT_LENGTH]u8 = ---
		copy(sb[:], block_bytes[i * SLOT_LENGTH : (i + 1) * SLOT_LENGTH])
		child_slot := slot_from_bytes_raw(sb)
		count := min(remaining, child_size)
		remapped_slot := child_slot
		if shift == 0 {
			remapped_slot = _compactor_remap_slot(c, child_slot) or_return
		} else {
			if child_slot.tag != .Index {
				return 0, .Unexpected_Tag
			}
			remapped_slot.value = _compactor_remap_array_list_index(c, child_slot.value, count, shift - 1) or_return
		}
		b := slot_to_bytes(remapped_slot)
		copy(remapped_block[i * SLOT_LENGTH : (i + 1) * SLOT_LENGTH], b[:])
		remaining -= count
	}
	core_seek_to(c.target_core, target_offset) or_return
	core_write_all(c.target_core, remapped_block[:]) or_return
	return target_offset, nil
}

@(private)
_compactor_populate_array_list :: proc(c: ^_Compactor, source_offset, target_offset: i64) -> Error {
	hb: [ARRAY_LIST_HEADER_LENGTH]u8 = ---
	core_read_exact_at(c.source_core, source_offset, hb[:]) or_return
	header := array_list_header_from_bytes(hb) or_return

	shift := radix_shift(header.size - 1)
	remapped_index := _compactor_remap_array_list_index(c, header.ptr, header.size, shift) or_return
	core_seek_to(c.target_core, target_offset) or_return
	nhb := array_list_header_to_bytes(Array_List_Header{ptr = remapped_index, size = header.size})
	return core_write_all(c.target_core, nhb[:])
}

@(private)
_compactor_populate_btree :: proc(c: ^_Compactor, source_offset, target_offset: i64) -> Error {
	hb: [BTREE_HEADER_LENGTH]u8 = ---
	core_read_exact_at(c.source_core, source_offset, hb[:]) or_return
	header := btree_header_from_bytes(hb) or_return
	remapped_root := _compactor_remap_btree_node(c, header.root_ptr) or_return
	core_seek_to(c.target_core, target_offset) or_return
	nhb := btree_header_to_bytes(BTree_Header{root_ptr = remapped_root, size = header.size})
	return core_write_all(c.target_core, nhb[:])
}

@(private)
_compactor_remap_btree_node :: proc(c: ^_Compactor, node_offset: i64) -> (res: i64, err: Error) {
	mapped, found := offset_map_get(c.offset_map, node_offset) or_return
	if found {
		return mapped, nil
	}
	node_header: [BTREE_NODE_HEADER_SIZE]u8 = ---
	core_read_exact_at(c.source_core, node_offset, node_header[:]) or_return
	kind_int := node_header[0]
	if kind_int > u8(BTree_Node_Kind.Branch) {
		return 0, .Invalid_BTree_Node_Kind
	}
	kind := BTree_Node_Kind(kind_int)
	num := node_header[1]
	if num > BTREE_SLOT_COUNT {
		return 0, .Invalid_BTree_Node
	}

	switch kind {
	case .Leaf:
		target_offset := _compactor_reserve_block(c, BTREE_LEAF_BLOCK_SIZE) or_return
		offset_map_put(c.offset_map, node_offset, target_offset) or_return
		_compactor_populate_btree_leaf(c, node_offset, target_offset, kind_int, num) or_return
		return target_offset, nil
	case .Branch:
		target_offset := _compactor_reserve_block(c, BTREE_BRANCH_BLOCK_SIZE) or_return
		offset_map_put(c.offset_map, node_offset, target_offset) or_return
		_compactor_populate_btree_branch(c, node_offset, target_offset, kind_int, num) or_return
		return target_offset, nil
	}
	return 0, .Unreachable
}

@(private)
_compactor_populate_btree_leaf :: proc(c: ^_Compactor, source_offset, target_offset: i64, kind, num: u8) -> Error {
	buf: [BTREE_LEAF_BLOCK_SIZE]u8 = ---
	buf[0] = kind
	buf[1] = num
	body := buf[BTREE_NODE_HEADER_SIZE:]
	active_len := int(num) * SLOT_LENGTH
	core_read_exact_at(c.source_core, source_offset + BTREE_NODE_HEADER_SIZE, body[:active_len]) or_return
	if active_len < len(body) {
		intrinsics.mem_zero(raw_data(body[active_len:]), len(body) - active_len)
	}

	for i in 0 ..< int(num) {
		tag := Tag(body[i * SLOT_LENGTH] & 0x7F)
		tag_validate(tag) or_return
		#partial switch tag {
		case .None, .Uint, .Int, .Float, .Short_Bytes:
			continue
		}
		sb: [SLOT_LENGTH]u8 = ---
		copy(sb[:], body[i * SLOT_LENGTH : (i + 1) * SLOT_LENGTH])
		remapped := _compactor_remap_slot(c, slot_from_bytes_raw(sb)) or_return
		out_sb := slot_to_bytes(remapped)
		copy(body[i * SLOT_LENGTH : (i + 1) * SLOT_LENGTH], out_sb[:])
	}

	core_seek_to(c.target_core, target_offset) or_return
	return core_write_all(c.target_core, buf[:])
}

@(private)
_compactor_populate_btree_branch :: proc(c: ^_Compactor, source_offset, target_offset: i64, kind, num: u8) -> Error {
	buf: [BTREE_BRANCH_BLOCK_SIZE]u8 = ---
	buf[0] = kind
	buf[1] = num
	body := buf[BTREE_NODE_HEADER_SIZE:]
	active_len := SLOT_LENGTH * BTREE_SLOT_COUNT + int(num) * 8
	core_read_exact_at(c.source_core, source_offset + BTREE_NODE_HEADER_SIZE, body[:active_len]) or_return
	if active_len < len(body) {
		intrinsics.mem_zero(raw_data(body[active_len:]), len(body) - active_len)
	}

	for i in 0 ..< int(num) {
		sb: [SLOT_LENGTH]u8 = ---
		copy(sb[:], body[i * SLOT_LENGTH : (i + 1) * SLOT_LENGTH])
		child := slot_from_bytes_raw(sb)
		tag_validate(child.tag) or_return
		if child.tag == .Index {
			remapped_ptr := _compactor_remap_btree_node(c, child.value) or_return
			out_sb := slot_to_bytes(Slot{value = remapped_ptr, tag = .Index, full = child.full})
			copy(body[i * SLOT_LENGTH : (i + 1) * SLOT_LENGTH], out_sb[:])
		}
	}

	core_seek_to(c.target_core, target_offset) or_return
	return core_write_all(c.target_core, buf[:])
}

@(private)
_compactor_populate_sorted_map :: proc(c: ^_Compactor, source_offset, target_offset: i64) -> Error {
	hb: [BTREE_HEADER_LENGTH]u8 = ---
	core_read_exact_at(c.source_core, source_offset, hb[:]) or_return
	header := btree_header_from_bytes(hb) or_return
	remapped_root := _compactor_remap_sorted_map_node(c, header.root_ptr) or_return
	core_seek_to(c.target_core, target_offset) or_return
	nhb := btree_header_to_bytes(BTree_Header{root_ptr = remapped_root, size = header.size})
	return core_write_all(c.target_core, nhb[:])
}

@(private)
_compactor_remap_sorted_map_node :: proc(c: ^_Compactor, node_offset: i64) -> (res: i64, err: Error) {
	mapped, found := offset_map_get(c.offset_map, node_offset) or_return
	if found {
		return mapped, nil
	}
	node_header: [BTREE_NODE_HEADER_SIZE]u8 = ---
	core_read_exact_at(c.source_core, node_offset, node_header[:]) or_return
	kind_int := node_header[0]
	if kind_int > u8(BTree_Node_Kind.Branch) {
		return 0, .Invalid_BTree_Node_Kind
	}
	kind := BTree_Node_Kind(kind_int)
	num := node_header[1]
	if num > BTREE_SLOT_COUNT {
		return 0, .Invalid_BTree_Node
	}

	switch kind {
	case .Leaf:
		target_offset := _compactor_reserve_block(c, SORTED_LEAF_BLOCK_SIZE) or_return
		offset_map_put(c.offset_map, node_offset, target_offset) or_return
		_compactor_populate_sorted_map_leaf(c, node_offset, target_offset, kind_int, num) or_return
		return target_offset, nil
	case .Branch:
		target_offset := _compactor_reserve_block(c, SORTED_BRANCH_BLOCK_SIZE) or_return
		offset_map_put(c.offset_map, node_offset, target_offset) or_return
		_compactor_populate_sorted_map_branch(c, node_offset, target_offset, kind_int, num) or_return
		return target_offset, nil
	}
	return 0, .Unreachable
}

@(private)
_compactor_populate_sorted_map_leaf :: proc(c: ^_Compactor, source_offset, target_offset: i64, kind, num: u8) -> Error {
	buf: [SORTED_LEAF_BLOCK_SIZE]u8 = ---
	buf[0] = kind
	buf[1] = num
	body := buf[BTREE_NODE_HEADER_SIZE:]
	active_len := int(num) * SLOT_LENGTH
	core_read_exact_at(c.source_core, source_offset + BTREE_NODE_HEADER_SIZE, body[:active_len]) or_return
	if active_len < len(body) {
		intrinsics.mem_zero(raw_data(body[active_len:]), len(body) - active_len)
	}

	for i in 0 ..< int(num) {
		tag := Tag(body[i * SLOT_LENGTH] & 0x7F)
		tag_validate(tag) or_return
		#partial switch tag {
		case .None, .Uint, .Int, .Float, .Short_Bytes:
			continue
		}
		sb: [SLOT_LENGTH]u8 = ---
		copy(sb[:], body[i * SLOT_LENGTH : (i + 1) * SLOT_LENGTH])
		remapped := _compactor_remap_slot(c, slot_from_bytes_raw(sb)) or_return
		out_sb := slot_to_bytes(remapped)
		copy(body[i * SLOT_LENGTH : (i + 1) * SLOT_LENGTH], out_sb[:])
	}

	core_seek_to(c.target_core, target_offset) or_return
	return core_write_all(c.target_core, buf[:])
}

@(private)
_compactor_populate_sorted_map_branch :: proc(c: ^_Compactor, source_offset, target_offset: i64, kind, num: u8) -> Error {
	buf: [SORTED_BRANCH_BLOCK_SIZE]u8 = ---
	buf[0] = kind
	buf[1] = num
	body := buf[BTREE_NODE_HEADER_SIZE:]
	active_len := SLOT_LENGTH * 2 * BTREE_SLOT_COUNT + int(num) * 8
	core_read_exact_at(c.source_core, source_offset + BTREE_NODE_HEADER_SIZE, body[:active_len]) or_return
	if active_len < len(body) {
		intrinsics.mem_zero(raw_data(body[active_len:]), len(body) - active_len)
	}

	for i in 0 ..< int(num) {
		sb: [SLOT_LENGTH]u8 = ---
		copy(sb[:], body[i * SLOT_LENGTH : (i + 1) * SLOT_LENGTH])
		child := slot_from_bytes_raw(sb)
		tag_validate(child.tag) or_return
		if child.tag == .Index {
			remapped_ptr := _compactor_remap_sorted_map_node(c, child.value) or_return
			out_sb := slot_to_bytes(Slot{value = remapped_ptr, tag = .Index, full = child.full})
			copy(body[i * SLOT_LENGTH : (i + 1) * SLOT_LENGTH], out_sb[:])
		}
	}
	separator_offset := SLOT_LENGTH * BTREE_SLOT_COUNT
	for i in 1 ..< int(num) {
		tag := Tag(body[separator_offset + i * SLOT_LENGTH] & 0x7F)
		tag_validate(tag) or_return
		#partial switch tag {
		case .None, .Uint, .Int, .Float, .Short_Bytes:
			continue
		}
		sb: [SLOT_LENGTH]u8 = ---
		copy(sb[:], body[separator_offset + i * SLOT_LENGTH : separator_offset + (i + 1) * SLOT_LENGTH])
		remapped := _compactor_remap_slot(c, slot_from_bytes_raw(sb)) or_return
		out_sb := slot_to_bytes(remapped)
		copy(body[separator_offset + i * SLOT_LENGTH : separator_offset + (i + 1) * SLOT_LENGTH], out_sb[:])
	}

	core_seek_to(c.target_core, target_offset) or_return
	return core_write_all(c.target_core, buf[:])
}

@(private)
_compactor_populate_hash_map :: proc(c: ^_Compactor, source_offset, target_offset: i64, counted: bool) -> Error {
	count_value: i64 = 0
	block_offset := source_offset
	if counted {
		count_value = core_read_long_at(c.source_core, source_offset) or_return
		block_offset += 8
	}
	block_bytes: [INDEX_BLOCK_SIZE]u8 = ---
	core_read_exact_at(c.source_core, block_offset, block_bytes[:]) or_return

	for i in 0 ..< SLOT_COUNT {
		tag := Tag(block_bytes[i * SLOT_LENGTH] & 0x7F)
		tag_validate(tag) or_return
		#partial switch tag {
		case .None, .Uint, .Int, .Float, .Short_Bytes:
			continue
		}
		sb: [SLOT_LENGTH]u8 = ---
		copy(sb[:], block_bytes[i * SLOT_LENGTH : (i + 1) * SLOT_LENGTH])
		child_slot := slot_from_bytes_raw(sb)
		remapped := _compactor_remap_slot(c, child_slot) or_return
		out_sb := slot_to_bytes(remapped)
		copy(block_bytes[i * SLOT_LENGTH : (i + 1) * SLOT_LENGTH], out_sb[:])
	}

	core_seek_to(c.target_core, target_offset) or_return
	if counted {
		core_write_long(c.target_core, count_value) or_return
	}
	return core_write_all(c.target_core, block_bytes[:])
}

@(private)
_compactor_populate_kv_pair :: proc(c: ^_Compactor, source_offset, target_offset: i64, tag: Tag) -> Error {
	hsize := int(c.hash_size) if tag == .KV_Pair else 0
	total := hsize + SORTED_KV_PAIR_LENGTH
	stack_buf: [128]u8 = ---
	b := stack_buf[:total] if total <= len(stack_buf) else make([]u8, total, context.temp_allocator)
	core_read_exact_at(c.source_core, source_offset, b) or_return

	key_slot := slot_from_slice_raw(b[hsize : hsize + SLOT_LENGTH])
	tag_validate(key_slot.tag) or_return
	val_slot := slot_from_slice_raw(b[hsize + SLOT_LENGTH : total])
	tag_validate(val_slot.tag) or_return

	key_slot = _compactor_remap_slot(c, key_slot) or_return
	val_slot = _compactor_remap_slot(c, val_slot) or_return

	kb := slot_to_bytes(key_slot)
	vb := slot_to_bytes(val_slot)
	copy(b[hsize : hsize + SLOT_LENGTH], kb[:])
	copy(b[hsize + SLOT_LENGTH : total], vb[:])

	core_seek_to(c.target_core, target_offset) or_return
	return core_write_all(c.target_core, b)
}

@(private)
_Remap_Ctx :: struct {
	compactor: ^_Compactor,
	slot:      Slot,
}

@(private)
_remap_slot_cb :: proc(cursor: ^Write_Cursor, user_data: rawptr) -> Error {
	ctx := (^_Remap_Ctx)(user_data)
	remapped := _compactor_remap_slot(ctx.compactor, ctx.slot) or_return
	return cursor_write(cursor, remapped)
}

// Compact `db` into `target_core` using `offset_map` (or an internal `Memory_Offset_Map` if `offset_map == nil`).
// Returns the compacted `Database`.
database_compact :: proc(db: ^Database, target_core: ^Core, offset_map: ^Offset_Map = nil) -> (target: Database, err: Error) {
	local_map: Offset_Map
	om := offset_map
	if om == nil {
		local_map = memory_offset_map_init()
		om = &local_map
	}
	defer if offset_map == nil {
		offset_map_destroy(&local_map)
	}

	offset_map_reset(om) or_return

	h := db.hasher
	h.id = db.header.hash_id
	h.hash_size = db.header.hash_size
	h.file_id = 0
	target = database_init(target_core, h) or_return

	target_root := database_read_root_slot(&target) or_return
	if !slot_empty(target_root) {
		return {}, .Target_Not_Empty
	}

	source_root := database_read_root_slot(db) or_return
	if slot_empty(source_root) {
		return target, nil
	}

	#partial switch &dst in target_core {
	case Core_Memory:
		want_cap := 4096
		if source_root.tag != .Array_List {
			if src_len, lerr := core_length(db.core); lerr == nil && src_len > 4096 {
				want_cap = min(int(src_len), 65536)
			}
		}
		if max_sz, ok := dst.max_size.?; ok && i64(want_cap) > max_sz {
			want_cap = int(max(max_sz, 0))
		}
		if cap(dst.buf) < want_cap {
			_ = _memory_reserve(&dst, want_cap)
		}
	}

	compactor := _Compactor{
		source_core = db.core,
		target_core = target.core,
		hash_size   = db.header.hash_size,
		offset_map  = om,
	}

	#partial switch source_root.tag {
	case .Array_List:
		rc := database_root_cursor(db)
		last_moment_maybe := cursor_read_path_slot(rc.read_cursor, []Path_Part{Array_List_Get{index = -1}}) or_return
		if last_moment, ok := last_moment_maybe.?; ok && !slot_empty(last_moment) {
			ctx := _Remap_Ctx{compactor = &compactor, slot = last_moment}
			trc := database_root_cursor(&target)
			_, err = cursor_write_path(&trc, []Path_Part{
				Array_List_Init{},
				Array_List_Append{},
				Context{function = _remap_slot_cb, user_data = &ctx},
			})
			if err != nil {
				return {}, err
			}
		}
	case:
		ctx := _Remap_Ctx{compactor = &compactor, slot = source_root}
		err = database_run_context(&target, _remap_slot_cb, &ctx)
		if err != nil {
			return {}, err
		}
	}

	return target, nil
}

// ============================================================================
// Replication
// ============================================================================

// Return this database's current `Replica_State` (committed size + trailer checksum).
database_replica_state :: proc(db: ^Database) -> (res: Replica_State, err: Error) {
	committed_size := database_committed_size(db) or_return
	trailer := database_read_root_trailer(db, committed_size) or_return
	return Replica_State{committed_size = committed_size, checksum = trailer.checksum}, nil
}

// Where to start sending committed bytes to a replica in `state`.
// Returns `state.committed_size` if its bytes are a prefix of this database,
// or `0` if the replica must be replaced from the beginning.
database_replication_start :: proc(db: ^Database, state: Replica_State) -> (res: i64, err: Error) {
	committed_size := database_committed_size(db) or_return
	if state.committed_size > committed_size {
		return 0, nil
	}
	trailer: Root_Trailer
	trailer, err = database_read_root_trailer(db, state.committed_size)
	if err != nil {
		if err == .Invalid_Database || err == .Unexpected_Tag {
			return 0, nil
		}
		return 0, err
	}
	if trailer.checksum == state.checksum {
		return state.committed_size, nil
	}
	return 0, nil
}

@(private)
_stream_bytes :: proc(db: ^Database, target_core: ^Core, start, length: i64) -> Error {
	if length <= 0 {
		return nil
	}
	#partial switch &src in db.core {
	case Core_Memory:
		if start >= 0 && start + length <= i64(len(src.buf)) {
			return core_write_all(target_core, src.buf[int(start):int(start + length)])
		}
	}
	buf: [4096]u8 = ---
	rem := length
	cur_offset := start
	for rem > 0 {
		chunk := min(rem, i64(len(buf)))
		core_read_exact_at(db.core, cur_offset, buf[:chunk]) or_return
		core_write_all(target_core, buf[:chunk]) or_return
		cur_offset += chunk
		rem -= chunk
	}
	return nil
}

// Write committed bytes from `start` up to `end` into `target_core` at its current position.
// When `start == 0`, a root header matching `end` is synthesized so the output is a complete database.
database_read_committed :: proc(db: ^Database, start, end: i64, target_core: ^Core) -> Error {
	committed_size := database_committed_size(db) or_return
	if start < 0 || start > end || end > committed_size {
		return .Invalid_Range
	}
	if start > 0 && start < ROOT_HEADER_END {
		return .Invalid_Range
	}
	if start == 0 {
		trailer := database_read_root_trailer(db, end) or_return
		_stream_bytes(db, target_core, 0, ROOT_HEADER_START) or_return
		root_header := root_header_to_bytes(Root_Header{file_size = end, root = trailer.root})
		core_write_all(target_core, root_header[:]) or_return
		return _stream_bytes(db, target_core, ROOT_HEADER_END, end - ROOT_HEADER_END)
	}
	return _stream_bytes(db, target_core, start, end - start)
}

// Read committed bytes from `start` up to `end` into a caller-supplied buffer (when large enough)
// or allocate from `allocator`.
database_read_committed_buf :: proc(db: ^Database, start, end: i64, buf: []u8) -> (res: []u8, err: Error) {
	committed_size := database_committed_size(db) or_return
	if start < 0 || start > end || end > committed_size {
		return nil, .Invalid_Range
	}
	if start > 0 && start < ROOT_HEADER_END {
		return nil, .Invalid_Range
	}
	needed := int(end - start)
	out := buf[:needed] if needed <= len(buf) else make([]u8, needed, context.temp_allocator)
	if start == 0 {
		trailer := database_read_root_trailer(db, end) or_return
		core_read_exact_at(db.core, 0, out[:ROOT_HEADER_START]) or_return
		root_header := root_header_to_bytes(Root_Header{file_size = end, root = trailer.root})
		copy(out[ROOT_HEADER_START:ROOT_HEADER_END], root_header[:])
		core_read_exact_at(db.core, ROOT_HEADER_END, out[ROOT_HEADER_END:]) or_return
		return out, nil
	}
	core_read_exact_at(db.core, start, out) or_return
	return out, nil
}

// Allocate and return the committed bytes from `start` up to `end` as a `[]u8` slice.
database_read_committed_bytes :: proc(db: ^Database, start, end: i64, allocator := context.allocator) -> (res: []u8, err: Error) {
	committed_size := database_committed_size(db) or_return
	if start < 0 || start > end || end > committed_size {
		return nil, .Invalid_Range
	}
	if start > 0 && start < ROOT_HEADER_END {
		return nil, .Invalid_Range
	}
	out := make([]u8, int(end - start), allocator)
	if start == 0 {
		trailer := database_read_root_trailer(db, end) or_return
		core_read_exact_at(db.core, 0, out[:ROOT_HEADER_START]) or_return
		root_header := root_header_to_bytes(Root_Header{file_size = end, root = trailer.root})
		copy(out[ROOT_HEADER_START:ROOT_HEADER_END], root_header[:])
		core_read_exact_at(db.core, ROOT_HEADER_END, out[ROOT_HEADER_END:]) or_return
		return out, nil
	}
	core_read_exact_at(db.core, start, out) or_return
	return out, nil
}

// Apply `length` bytes from `source_core` (starting at `source_core`'s current position)
// at `start` in `db` and commit them.
database_apply_replicated :: proc(db: ^Database, start: i64, source_core: ^Core, length: i64) -> Error {
	if start == 0 {
		core_set_length(db.core, 0) or_return
	} else {
		root_header := database_read_root_header(db) or_return
		committed_size, file_size := _database_committed_size_with_header(db, root_header) or_return
		if start != committed_size {
			return .Invalid_Range
		}
		if file_size > committed_size {
			core_set_length(db.core, committed_size) or_return
		}
	}

	core_seek_to(db.core, start) or_return
	if length > 0 {
		#partial switch &src in source_core {
		case Core_Memory:
			if src.pos >= 0 && src.pos + length <= i64(len(src.buf)) {
				slice := src.buf[int(src.pos):int(src.pos + length)]
				src.pos += length
				core_write_all(db.core, slice) or_return
			} else {
				return Xitdb_Error.Unexpected_EOF
			}
		case:
			buf: [4096]u8 = ---
			for remaining := length; remaining > 0; {
				chunk := min(remaining, i64(len(buf)))
				core_read_exact(source_core, buf[:chunk]) or_return
				core_write_all(db.core, buf[:chunk]) or_return
				remaining -= chunk
			}
		}
	}

	if start == 0 {
		core_sync(db.core) or_return
		header := database_read_and_validate_header(db) or_return
		db.header = header
		_ = database_committed_size(db) or_return
	} else if length > 0 {
		trailer := database_read_root_trailer(db, start + length) or_return
		database_write_root_header(db, trailer.root) or_return
		core_sync(db.core) or_return
	}
	return nil
}

// Convenience wrapper to apply a `[]u8` slice of replicated bytes at `start`.
database_apply_replicated_bytes :: proc(db: ^Database, start: i64, data: []u8) -> Error {
	if start == 0 {
		core_set_length(db.core, 0) or_return
	} else {
		root_header := database_read_root_header(db) or_return
		committed_size, file_size := _database_committed_size_with_header(db, root_header) or_return
		if start != committed_size {
			return .Invalid_Range
		}
		if file_size > committed_size {
			core_set_length(db.core, committed_size) or_return
		}
	}

	core_seek_to(db.core, start) or_return
	core_write_all(db.core, data) or_return

	if start == 0 {
		core_sync(db.core) or_return
		header := database_read_and_validate_header(db) or_return
		db.header = header
		_ = database_committed_size(db) or_return
	} else if len(data) > 0 {
		trailer := database_read_root_trailer(db, start + i64(len(data))) or_return
		database_write_root_header(db, trailer.root) or_return
		core_sync(db.core) or_return
	}
	return nil
}
