package xitdb

import "core:bytes"

Hash_Map_Get_Result :: struct {
	slot_ptr: Slot_Pointer,
	is_empty: bool,
}

Array_List_Append_Result :: struct {
	header:   Array_List_Header,
	slot_ptr: Slot_Pointer,
}

read_map_slot :: proc(
	db: ^Database,
	index_pos: i64,
	key_hash: []u8,
	key_offset: u8,
	write_mode: Write_Mode,
	target: Hash_Map_Get_Target,
	frozen_at: i64,
) -> (res: Hash_Map_Get_Result, err: Error) {
	index_pos := index_pos
	key_offset := key_offset
	max_offset := (int(db.header.hash_size) * 8) / BIT_COUNT

	for {
		if int(key_offset) >= max_offset {
			return {}, .Key_Offset_Exceeded
		}

		i := hamt_nibble(key_hash, key_offset)
		slot_pos := index_pos + i64(SLOT_LENGTH * i)
		slot := core_read_slot_raw_at(db.core, slot_pos) or_return
		ptr := slot.value

		#partial switch slot.tag {
		case .None:
			switch write_mode {
			case .Read_Only:
				return {}, .Key_Not_Found
			case .Read_Write:
				hash_pos := core_length(db.core) or_return
				core_seek_to(db.core, hash_pos) or_return
				key_slot_pos := hash_pos + i64(db.header.hash_size)
				value_slot_pos := key_slot_pos + i64(SLOT_LENGTH)
				kv_pair := Key_Value_Pair{value_slot = Slot{}, key_slot = Slot{}, hash = key_hash}
				kv_pair_write(kv_pair, db.core) or_return

				next_slot := Slot{value = hash_pos, tag = .KV_Pair}
				core_seek_to(db.core, slot_pos) or_return
				core_write_slot(db.core, next_slot) or_return

				next_slot_ptr: Slot_Pointer
				switch _ in target {
				case Hash_Map_Get_KV_Pair:
					next_slot_ptr = Slot_Pointer{position = slot_pos, slot = next_slot}
				case Hash_Map_Get_Key:
					next_slot_ptr = Slot_Pointer{position = key_slot_pos, slot = kv_pair.key_slot}
				case Hash_Map_Get_Value:
					next_slot_ptr = Slot_Pointer{position = value_slot_pos, slot = kv_pair.value_slot}
				}
				return Hash_Map_Get_Result{slot_ptr = next_slot_ptr, is_empty = true}, nil
			}

		case .Index:
			next_ptr := ptr
			if write_mode == .Read_Write {
				next_ptr = database_copy_index_block_if_old(db, ptr, frozen_at) or_return
				if next_ptr != ptr {
					core_seek_to(db.core, slot_pos) or_return
					core_write_slot(db.core, Slot{value = next_ptr, tag = .Index}) or_return
				}
			}
			index_pos = next_ptr
			key_offset += 1
			continue

		case .KV_Pair:
			hash_size := int(db.header.hash_size)
			kv_len := hash_size + SLOT_LENGTH * 2
			stack_hash: [64]u8 = ---
			kv_pair: Key_Value_Pair
			hash_matches: bool

			if kv_slice, in_mem, slice_err := core_slice_at(db.core, ptr, kv_len); in_mem {
				if slice_err != nil {
					return {}, slice_err
				}
				key_slot := slot_from_slice_raw(kv_slice[hash_size : hash_size + SLOT_LENGTH])
				tag_validate(key_slot.tag) or_return
				val_slot := slot_from_slice_raw(kv_slice[hash_size + SLOT_LENGTH : kv_len])
				tag_validate(val_slot.tag) or_return
				hash_matches = bytes.equal(kv_slice[:hash_size], key_hash)
				if hash_matches && write_mode == .Read_Only {
					key_slot_pos := ptr + i64(hash_size)
					value_slot_pos := key_slot_pos + i64(SLOT_LENGTH)
					next_slot_ptr: Slot_Pointer
					switch _ in target {
					case Hash_Map_Get_KV_Pair:
						next_slot_ptr = Slot_Pointer{position = slot_pos, slot = slot}
					case Hash_Map_Get_Key:
						next_slot_ptr = Slot_Pointer{position = key_slot_pos, slot = key_slot}
					case Hash_Map_Get_Value:
						next_slot_ptr = Slot_Pointer{position = value_slot_pos, slot = val_slot}
					}
					return Hash_Map_Get_Result{slot_ptr = next_slot_ptr, is_empty = false}, nil
				}
				if !hash_matches && write_mode == .Read_Only {
					return {}, .Key_Not_Found
				}
				hash_buf := stack_hash[:hash_size] if hash_size <= len(stack_hash) else make([]u8, hash_size, context.temp_allocator)
				copy(hash_buf, kv_slice[:hash_size])
				kv_pair = Key_Value_Pair{value_slot = val_slot, key_slot = key_slot, hash = hash_buf}
			} else {
				hash_buf := stack_hash[:hash_size] if hash_size <= len(stack_hash) else make([]u8, hash_size, context.temp_allocator)
				kv_pair = kv_pair_read_buf_at(db.core, ptr, hash_buf) or_return
				hash_matches = bytes.equal(kv_pair.hash, key_hash)
			}

			if hash_matches {
				if write_mode == .Read_Write {
					old := database_is_old(db, ptr, frozen_at) or_return
					if old {
						hash_pos := core_length(db.core) or_return
						core_seek_to(db.core, hash_pos) or_return
						key_slot_pos := hash_pos + i64(hash_size)
						value_slot_pos := key_slot_pos + i64(SLOT_LENGTH)
						kv_pair_write(kv_pair, db.core) or_return

						next_slot := Slot{value = hash_pos, tag = .KV_Pair}
						core_seek_to(db.core, slot_pos) or_return
						core_write_slot(db.core, next_slot) or_return

						next_slot_ptr: Slot_Pointer
						switch _ in target {
						case Hash_Map_Get_KV_Pair:
							next_slot_ptr = Slot_Pointer{position = slot_pos, slot = next_slot}
						case Hash_Map_Get_Key:
							next_slot_ptr = Slot_Pointer{position = key_slot_pos, slot = kv_pair.key_slot}
						case Hash_Map_Get_Value:
							next_slot_ptr = Slot_Pointer{position = value_slot_pos, slot = kv_pair.value_slot}
						}
						return Hash_Map_Get_Result{slot_ptr = next_slot_ptr, is_empty = false}, nil
					}
				}

				key_slot_pos := ptr + i64(hash_size)
				value_slot_pos := key_slot_pos + i64(SLOT_LENGTH)
				next_slot_ptr: Slot_Pointer
				switch _ in target {
				case Hash_Map_Get_KV_Pair:
					next_slot_ptr = Slot_Pointer{position = slot_pos, slot = slot}
				case Hash_Map_Get_Key:
					next_slot_ptr = Slot_Pointer{position = key_slot_pos, slot = kv_pair.key_slot}
				case Hash_Map_Get_Value:
					next_slot_ptr = Slot_Pointer{position = value_slot_pos, slot = kv_pair.value_slot}
				}
				return Hash_Map_Get_Result{slot_ptr = next_slot_ptr, is_empty = false}, nil
			}

			// Hash collision - different keys
			switch write_mode {
			case .Read_Only:
				return {}, .Key_Not_Found
			case .Read_Write:
				diff_offset := int(key_offset) + 1
				for diff_offset < max_offset {
					if hamt_nibble(kv_pair.hash, u8(diff_offset)) != hamt_nibble(key_hash, u8(diff_offset)) {
						break
					}
					diff_offset += 1
				}
				if diff_offset >= max_offset {
					return {}, .Key_Offset_Exceeded
				}

				first_index_pos := core_length(db.core) or_return
				core_seek_to(db.core, first_index_pos) or_return
				cur_index_pos := first_index_pos

				for off in int(key_offset) + 1 ..< diff_offset {
					nib := hamt_nibble(key_hash, u8(off))
					child_index_pos := cur_index_pos + INDEX_BLOCK_SIZE
					mid_block: [INDEX_BLOCK_SIZE]u8
					sb := slot_to_bytes(Slot{value = child_index_pos, tag = .Index})
					copy(mid_block[SLOT_LENGTH * nib : SLOT_LENGTH * (nib + 1)], sb[:])
					core_write_all(db.core, mid_block[:]) or_return
					cur_index_pos = child_index_pos
				}

				next_i := hamt_nibble(kv_pair.hash, u8(diff_offset))
				new_i := hamt_nibble(key_hash, u8(diff_offset))
				hash_pos := cur_index_pos + INDEX_BLOCK_SIZE
				next_slot := Slot{value = hash_pos, tag = .KV_Pair}
				key_slot_pos := hash_pos + i64(hash_size)
				value_slot_pos := key_slot_pos + i64(SLOT_LENGTH)

				if hash_size <= 64 {
					combined: [INDEX_BLOCK_SIZE + 64 + SLOT_LENGTH * 2]u8
					sb_old := slot_to_bytes(slot)
					sb_new := slot_to_bytes(next_slot)
					copy(combined[SLOT_LENGTH * next_i : SLOT_LENGTH * (next_i + 1)], sb_old[:])
					copy(combined[SLOT_LENGTH * new_i : SLOT_LENGTH * (new_i + 1)], sb_new[:])
					copy(combined[INDEX_BLOCK_SIZE : INDEX_BLOCK_SIZE + hash_size], key_hash)
					core_write_all(db.core, combined[:INDEX_BLOCK_SIZE + kv_len]) or_return
				} else {
					new_block: [INDEX_BLOCK_SIZE]u8
					sb_old := slot_to_bytes(slot)
					sb_new := slot_to_bytes(next_slot)
					copy(new_block[SLOT_LENGTH * next_i : SLOT_LENGTH * (next_i + 1)], sb_old[:])
					copy(new_block[SLOT_LENGTH * new_i : SLOT_LENGTH * (new_i + 1)], sb_new[:])
					core_write_all(db.core, new_block[:]) or_return
					new_kv := Key_Value_Pair{value_slot = Slot{}, key_slot = Slot{}, hash = key_hash}
					kv_pair_write(new_kv, db.core) or_return
				}

				core_seek_to(db.core, slot_pos) or_return
				core_write_slot(db.core, Slot{value = first_index_pos, tag = .Index}) or_return

				next_slot_ptr: Slot_Pointer
				switch _ in target {
				case Hash_Map_Get_KV_Pair:
					next_slot_ptr = Slot_Pointer{position = cur_index_pos + i64(SLOT_LENGTH * new_i), slot = next_slot}
				case Hash_Map_Get_Key:
					next_slot_ptr = Slot_Pointer{position = key_slot_pos, slot = Slot{}}
				case Hash_Map_Get_Value:
					next_slot_ptr = Slot_Pointer{position = value_slot_pos, slot = Slot{}}
				}
				return Hash_Map_Get_Result{slot_ptr = next_slot_ptr, is_empty = true}, nil
			}

		case:
			return {}, .Unexpected_Tag
		}
	}
}

remove_map_slot :: proc(
	db: ^Database,
	index_pos: i64,
	key_hash: []u8,
	key_offset: u8,
	frozen_at: i64,
) -> (res: Slot, err: Error) {
	if int(key_offset) >= (int(db.header.hash_size) * 8) / BIT_COUNT {
		return {}, .Key_Offset_Exceeded
	}

	i := hamt_nibble(key_hash, key_offset)
	slot_pos := index_pos + i64(SLOT_LENGTH * i)
	slot := core_read_slot_raw_at(db.core, slot_pos) or_return

	next_slot: Slot
	#partial switch slot.tag {
	case .None:
		return {}, .Key_Not_Found
	case .Index:
		next_slot = remove_map_slot(db, slot.value, key_hash, key_offset + 1, frozen_at) or_return
	case .KV_Pair:
		hash_size := int(db.header.hash_size)
		kv_len := hash_size + SLOT_LENGTH * 2
		if kv_slice, in_mem, slice_err := core_slice_at(db.core, slot.value, kv_len); in_mem {
			if slice_err != nil {
				return {}, slice_err
			}
			_ = slot_from_slice(kv_slice[hash_size : hash_size + SLOT_LENGTH]) or_return
			_ = slot_from_slice(kv_slice[hash_size + SLOT_LENGTH : kv_len]) or_return
			if !bytes.equal(kv_slice[:hash_size], key_hash) {
				return {}, .Key_Not_Found
			}
		} else {
			stack_hash: [64]u8 = ---
			hash_buf := stack_hash[:hash_size] if hash_size <= len(stack_hash) else make([]u8, hash_size, context.temp_allocator)
			kv_pair := kv_pair_read_buf_at(db.core, slot.value, hash_buf) or_return
			if !bytes.equal(kv_pair.hash, key_hash) {
				return {}, .Key_Not_Found
			}
		}
		next_slot = Slot{}
	case:
		return {}, .Unexpected_Tag
	}

	// If root node, write the new slot directly and finish
	if key_offset == 0 {
		core_seek_to(db.core, slot_pos) or_return
		core_write_slot(db.core, next_slot) or_return
		return Slot{value = index_pos, tag = .Index}, nil
	}

	// If the child is still an Index branch, this branch node cannot collapse
	if next_slot.tag == .Index {
		next_index_pos := database_copy_index_block_if_old(db, index_pos, frozen_at) or_return
		core_seek_to(db.core, next_index_pos + i64(SLOT_LENGTH * i)) or_return
		core_write_slot(db.core, next_slot) or_return
		return Slot{value = next_index_pos, tag = .Index}, nil
	}

	// Otherwise, read the index block to check if it can collapse into a single KV_Pair or None
	index_block: [INDEX_BLOCK_SIZE]u8 = ---
	core_read_exact_at(db.core, index_pos, index_block[:]) or_return

	slot_to_return: Maybe(Slot) = Slot{}
	for j in 0 ..< SLOT_COUNT {
		block_slot: Slot
		if j == i {
			block_slot = next_slot
		} else {
			if index_block[j * SLOT_LENGTH] == 0 {
				continue
			}
			block_slot = slot_from_slice(index_block[j * SLOT_LENGTH : (j + 1) * SLOT_LENGTH]) or_return
		}
		if block_slot.tag == .None {
			continue
		}
		if sr, ok := slot_to_return.?; ok {
			if sr.tag != .None {
				slot_to_return = nil
				break
			}
		}
		slot_to_return = block_slot
	}

	if sr, ok := slot_to_return.?; ok {
		#partial switch sr.tag {
		case .None, .KV_Pair:
			return sr, nil
		}
	}

	next_index_pos := database_copy_index_block_if_old(db, index_pos, frozen_at) or_return
	core_seek_to(db.core, next_index_pos + i64(SLOT_LENGTH * i)) or_return
	core_write_slot(db.core, next_slot) or_return
	return Slot{value = next_index_pos, tag = .Index}, nil
}

// ArrayList methods

read_array_list_slot_append :: proc(
	db: ^Database,
	header: Array_List_Header,
	write_mode: Write_Mode,
	frozen_at: i64,
) -> (res: Array_List_Append_Result, err: Error) {
	index_pos := header.ptr
	key := header.size

	prev_shift := radix_shift(key - 1)
	next_shift := radix_shift(key)

	if prev_shift != next_shift {
		// Root overflow
		next_index_pos := core_length(db.core) or_return
		core_seek_to(db.core, next_index_pos) or_return
		new_block: [INDEX_BLOCK_SIZE]u8
		sb := slot_to_bytes(Slot{value = index_pos, tag = .Index})
		copy(new_block[:SLOT_LENGTH], sb[:])
		core_write_all(db.core, new_block[:]) or_return
		index_pos = next_index_pos
	}

	slot_ptr := read_array_list_slot(db, index_pos, key, next_shift, write_mode, frozen_at) or_return
	pos, pos_ok := slot_ptr.position.?
	if !pos_ok {
		return {}, .Cursor_Not_Writeable
	}
	// Clear values left by a rollback or slice
	if slot_ptr.slot != (Slot{}) {
		slot_ptr = slot_pointer_with_slot(slot_ptr, Slot{})
		core_seek_to(db.core, pos) or_return
		core_write_slot(db.core, slot_ptr.slot) or_return
	}
	return Array_List_Append_Result{
		header   = Array_List_Header{ptr = index_pos, size = header.size + 1},
		slot_ptr = slot_ptr,
	}, nil
}

read_array_list_slot :: proc(
	db: ^Database,
	index_pos: i64,
	key: i64,
	shift: u8,
	write_mode: Write_Mode,
	frozen_at: i64,
) -> (res: Slot_Pointer, err: Error) {
	if shift >= MAX_BRANCH_LENGTH {
		return {}, .Max_Shift_Exceeded
	}

	index_pos := index_pos
	shift := shift
	for {
		i := (key >> (u64(shift) * BIT_COUNT)) & i64(MASK)
		slot_pos := index_pos + i64(SLOT_LENGTH) * i
		slot := core_read_slot_at(db.core, slot_pos) or_return

		if shift == 0 {
			return Slot_Pointer{position = slot_pos, slot = slot}, nil
		}

		ptr := slot.value

		#partial switch slot.tag {
		case .None:
			switch write_mode {
			case .Read_Only:
				return {}, .Key_Not_Found
			case .Read_Write:
				first_index_pos := core_length(db.core) or_return
				core_seek_to(db.core, first_index_pos) or_return
				cur_index_pos := first_index_pos
				for s := shift - 1; s > 0; s -= 1 {
					child_i := (key >> (u64(s) * BIT_COUNT)) & i64(MASK)
					child_index_pos := cur_index_pos + INDEX_BLOCK_SIZE
					mid_block: [INDEX_BLOCK_SIZE]u8
					sb := slot_to_bytes(Slot{value = child_index_pos, tag = .Index})
					copy(mid_block[int(child_i) * SLOT_LENGTH : (int(child_i) + 1) * SLOT_LENGTH], sb[:])
					core_write_all(db.core, mid_block[:]) or_return
					cur_index_pos = child_index_pos
				}
				empty_block: [INDEX_BLOCK_SIZE]u8
				core_write_all(db.core, empty_block[:]) or_return
				core_seek_to(db.core, slot_pos) or_return
				core_write_slot(db.core, Slot{value = first_index_pos, tag = .Index}) or_return
				leaf_i := key & i64(MASK)
				return Slot_Pointer{position = cur_index_pos + i64(SLOT_LENGTH) * leaf_i, slot = Slot{}}, nil
			}
		case .Index:
			next_ptr := ptr
			if write_mode == .Read_Write {
				next_ptr = database_copy_index_block_if_old(db, ptr, frozen_at) or_return
				if next_ptr != ptr {
					core_seek_to(db.core, slot_pos) or_return
					core_write_slot(db.core, Slot{value = next_ptr, tag = .Index}) or_return
				}
			}
			index_pos = next_ptr
			shift -= 1
			continue
		case:
			return {}, .Unexpected_Tag
		}
	}
}

read_array_list_slice :: proc(
	db: ^Database,
	header: Array_List_Header,
	size: i64,
	frozen_at: i64,
) -> (res: Array_List_Header, err: Error) {
	if size > header.size || size < 0 {
		return {}, .Key_Not_Found
	}

	prev_shift := radix_shift(header.size - 1)
	next_shift := radix_shift(size - 1)

	if prev_shift == next_shift {
		return Array_List_Header{ptr = header.ptr, size = size}, nil
	}

	shift := prev_shift
	index_pos := header.ptr
	for shift > next_shift {
		slot := core_read_slot_at(db.core, index_pos) or_return
		shift -= 1
		index_pos = slot.value
	}
	index_pos = database_copy_index_block_if_old(db, index_pos, frozen_at) or_return
	return Array_List_Header{ptr = index_pos, size = size}, nil
}
