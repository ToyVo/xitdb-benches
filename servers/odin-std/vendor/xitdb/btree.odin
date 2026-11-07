package xitdb

import "core:bytes"
import "core:encoding/endian"

// LinkedArrayList methods (backed by a count-augmented B-Tree)

read_btree_node :: proc(db: ^Database, ptr: i64) -> (res: BTree_Node, err: Error) {
	header_bytes: [BTREE_NODE_HEADER_SIZE]u8 = ---
	core_read_exact_at(db.core, ptr, header_bytes[:]) or_return
	kind_int := header_bytes[0]
	if kind_int > u8(BTree_Node_Kind.Branch) {
		return {}, .Invalid_BTree_Node_Kind
	}
	kind := BTree_Node_Kind(kind_int)
	num := int(header_bytes[1])
	if num > BTREE_SLOT_COUNT {
		return {}, .Invalid_BTree_Node
	}
	node := BTree_Node{kind = kind, num = num}
	switch kind {
	case .Leaf:
		body: [SLOT_LENGTH * BTREE_SLOT_COUNT]u8 = ---
		core_read_exact_at(db.core, ptr + BTREE_NODE_HEADER_SIZE, body[:]) or_return
		for i in 0 ..< num {
			node.values[i] = slot_from_slice(body[i * SLOT_LENGTH : i * SLOT_LENGTH + SLOT_LENGTH]) or_return
		}
	case .Branch:
		body: [(SLOT_LENGTH + 8) * BTREE_SLOT_COUNT]u8 = ---
		core_read_exact_at(db.core, ptr + BTREE_NODE_HEADER_SIZE, body[:]) or_return
		for i in 0 ..< num {
			node.children[i] = slot_from_slice(body[i * SLOT_LENGTH : i * SLOT_LENGTH + SLOT_LENGTH]) or_return
		}
		counts_offset := SLOT_LENGTH * BTREE_SLOT_COUNT
		for i in 0 ..< num {
			node.counts[i] = i64(endian.unchecked_get_u64be(body[counts_offset + i * 8 : counts_offset + i * 8 + 8]))
		}
	}
	return node, nil
}

write_btree_node_at :: proc(db: ^Database, node: BTree_Node, ptr: i64) -> Error {
	core_seek_to(db.core, ptr) or_return
	switch node.kind {
	case .Leaf:
		buf: [BTREE_LEAF_BLOCK_SIZE]u8
		buf[0] = u8(node.kind)
		buf[1] = u8(node.num)
		off := BTREE_NODE_HEADER_SIZE
		for i in 0 ..< node.num {
			sb := slot_to_bytes(node.values[i])
			copy(buf[off:], sb[:])
			off += SLOT_LENGTH
		}
		return core_write_all(db.core, buf[:])
	case .Branch:
		buf: [BTREE_BRANCH_BLOCK_SIZE]u8
		buf[0] = u8(node.kind)
		buf[1] = u8(node.num)
		off := BTREE_NODE_HEADER_SIZE
		for i in 0 ..< node.num {
			sb := slot_to_bytes(node.children[i])
			copy(buf[off:], sb[:])
			off += SLOT_LENGTH
		}
		counts_off := BTREE_NODE_HEADER_SIZE + SLOT_LENGTH * BTREE_SLOT_COUNT
		for i in 0 ..< node.num {
			endian.unchecked_put_u64be(buf[counts_off : counts_off + 8], u64(node.counts[i]))
			counts_off += 8
		}
		return core_write_all(db.core, buf[:])
	}
	return .Unreachable
}

write_btree_node :: proc(db: ^Database, node: BTree_Node) -> (res: i64, err: Error) {
	ptr := core_length(db.core) or_return
	write_btree_node_at(db, node, ptr) or_return
	return ptr, nil
}

btree_reusable :: proc(db: ^Database, ptr, frozen_at: i64) -> bool {
	old, err := database_is_old(db, ptr, frozen_at)
	if err != nil {
		return false
	}
	return !old
}

btree_write_node :: proc(db: ^Database, node: BTree_Node, old_ptr, frozen_at: i64) -> (res: i64, err: Error) {
	if btree_reusable(db, old_ptr, frozen_at) {
		write_btree_node_at(db, node, old_ptr) or_return
		return old_ptr, nil
	}
	return write_btree_node(db, node)
}

btree_new_root :: proc(db: ^Database) -> (res: i64, err: Error) {
	return write_btree_node(db, BTree_Node{kind = .Leaf, num = 0})
}

read_btree_slot :: proc(db: ^Database, root_ptr, rank: i64) -> (res: Slot_Pointer, err: Error) {
	node_ptr := root_ptr
	rem := rank
	for {
		if hdr_slice, in_mem, slice_err := core_slice_at(db.core, node_ptr, BTREE_NODE_HEADER_SIZE); in_mem {
			if slice_err != nil {
				return {}, slice_err
			}
			kind_int := hdr_slice[0]
			if kind_int > u8(BTree_Node_Kind.Branch) {
				return {}, .Invalid_BTree_Node_Kind
			}
			num := int(hdr_slice[1])
			if num > BTREE_SLOT_COUNT {
				return {}, .Invalid_BTree_Node
			}
			if BTree_Node_Kind(kind_int) == .Leaf {
				if rem >= i64(num) {
					return {}, .Invalid_BTree_Node
				}
				position := node_ptr + BTREE_NODE_HEADER_SIZE + rem * SLOT_LENGTH
				slot_slice, _, s_err := core_slice_at(db.core, position, SLOT_LENGTH)
				if s_err != nil {
					return {}, s_err
				}
				slot := slot_from_slice(slot_slice) or_return
				return Slot_Pointer{position = position, slot = slot}, nil
			}
			body_len := SLOT_LENGTH * BTREE_SLOT_COUNT + num * 8
			body_slice, _, b_err := core_slice_at(db.core, node_ptr + BTREE_NODE_HEADER_SIZE, body_len)
			if b_err != nil {
				return {}, b_err
			}
			counts_off := SLOT_LENGTH * BTREE_SLOT_COUNT
			i := 0
			for i + 1 < num {
				cnt := i64(endian.unchecked_get_u64be(body_slice[counts_off + i * 8 : counts_off + (i + 1) * 8]))
				if rem < cnt {
					break
				}
				rem -= cnt
				i += 1
			}
			child_slot := slot_from_slice(body_slice[i * SLOT_LENGTH : (i + 1) * SLOT_LENGTH]) or_return
			node_ptr = child_slot.value
			continue
		}

		header_bytes: [BTREE_NODE_HEADER_SIZE]u8 = ---
		core_read_exact_at(db.core, node_ptr, header_bytes[:]) or_return
		kind_int := header_bytes[0]
		if kind_int > u8(BTree_Node_Kind.Branch) {
			return {}, .Invalid_BTree_Node_Kind
		}
		num := int(header_bytes[1])
		if num > BTREE_SLOT_COUNT {
			return {}, .Invalid_BTree_Node
		}
		if BTree_Node_Kind(kind_int) == .Leaf {
			if rem >= i64(num) {
				return {}, .Invalid_BTree_Node
			}
			position := node_ptr + BTREE_NODE_HEADER_SIZE + rem * SLOT_LENGTH
			slot := core_read_slot_at(db.core, position) or_return
			return Slot_Pointer{position = position, slot = slot}, nil
		}
		counts_pos := node_ptr + BTREE_NODE_HEADER_SIZE + SLOT_LENGTH * BTREE_SLOT_COUNT
		counts_buf: [8 * BTREE_SLOT_COUNT]u8 = ---
		core_read_exact_at(db.core, counts_pos, counts_buf[:num * 8]) or_return
		i := 0
		for i + 1 < num {
			cnt := i64(endian.unchecked_get_u64be(counts_buf[i * 8 : i * 8 + 8]))
			if rem < cnt {
				break
			}
			rem -= cnt
			i += 1
		}
		child_pos := node_ptr + BTREE_NODE_HEADER_SIZE + i64(i) * SLOT_LENGTH
		child_slot := core_read_slot_at(db.core, child_pos) or_return
		node_ptr = child_slot.value
	}
}

btree_insert :: proc(db: ^Database, node_ptr, rank, frozen_at: i64) -> (res: BTree_Insert_Result, err: Error) {
	if btree_reusable(db, node_ptr, frozen_at) {
		header_bytes: [BTREE_NODE_HEADER_SIZE]u8
		core_read_exact_at(db.core, node_ptr, header_bytes[:]) or_return
		kind_int := header_bytes[0]
		if kind_int > u8(BTree_Node_Kind.Branch) {
			return {}, .Invalid_BTree_Node_Kind
		}
		num := int(header_bytes[1])
		if num > BTREE_SLOT_COUNT {
			return {}, .Invalid_BTree_Node
		}
		if BTree_Node_Kind(kind_int) == .Leaf {
			r := int(rank)
			if r < 0 || r > num {
				return {}, .Invalid_BTree_Node
			}
			if num < BTREE_SLOT_COUNT {
				total := num + 1
				val_pos := node_ptr + BTREE_NODE_HEADER_SIZE + i64(r) * SLOT_LENGTH
				empty_slot_bytes := slot_to_bytes(Slot{value = 0, tag = .None, full = true})
				if r < num {
					tail_len := (num - r) * SLOT_LENGTH
					shift_buf: [SLOT_LENGTH * BTREE_SLOT_COUNT]u8
					copy(shift_buf[:SLOT_LENGTH], empty_slot_bytes[:])
					core_read_exact_at(db.core, val_pos, shift_buf[SLOT_LENGTH : SLOT_LENGTH + tail_len]) or_return
					core_seek_to(db.core, val_pos) or_return
					core_write_all(db.core, shift_buf[:SLOT_LENGTH + tail_len]) or_return
				} else {
					core_seek_to(db.core, val_pos) or_return
					core_write_all(db.core, empty_slot_bytes[:]) or_return
				}
				new_hdr := [BTREE_NODE_HEADER_SIZE]u8{header_bytes[0], u8(total)}
				core_seek_to(db.core, node_ptr) or_return
				core_write_all(db.core, new_hdr[:]) or_return
				return BTree_Insert_Result{
					node_ptr       = node_ptr,
					count          = i64(total),
					value_position = val_pos,
				}, nil
			}
		} else {
			counts_pos := node_ptr + BTREE_NODE_HEADER_SIZE + SLOT_LENGTH * BTREE_SLOT_COUNT
			counts_buf: [8 * BTREE_SLOT_COUNT]u8
			core_read_exact_at(db.core, counts_pos, counts_buf[:num * 8]) or_return
			i := 0
			rem := rank
			total_count: i64 = 0
			old_cnt_i: i64 = 0
			for k in 0 ..< num {
				cnt := i64(endian.unchecked_get_u64be(counts_buf[k * 8 : k * 8 + 8]))
				total_count += cnt
				if k == i {
					old_cnt_i = cnt
					if i + 1 < num && rem > cnt {
						rem -= cnt
						i += 1
					}
				}
			}
			child_slot_pos := node_ptr + BTREE_NODE_HEADER_SIZE + i64(i) * SLOT_LENGTH
			child_slot := core_read_slot_at(db.core, child_slot_pos) or_return
			child_ptr := child_slot.value
			child := btree_insert(db, child_ptr, rem, frozen_at) or_return
			if child.split == nil {
				if child.node_ptr != child_ptr {
					core_seek_to(db.core, child_slot_pos) or_return
					core_write_slot(db.core, Slot{value = child.node_ptr, tag = .Index}) or_return
				}
				core_seek_to(db.core, counts_pos + i64(i) * 8) or_return
				core_write_i64(db.core, child.count) or_return
				return BTree_Insert_Result{
					node_ptr       = node_ptr,
					count          = total_count - old_cnt_i + child.count,
					value_position = child.value_position,
				}, nil
			}
			// Child split: read full branch node and finish split handling
			node := read_btree_node(db, node_ptr) or_return
			children: [BTREE_SLOT_COUNT + 1]Slot
			counts: [BTREE_SLOT_COUNT + 1]i64
			copy(children[:node.num], node.children[:node.num])
			copy(counts[:node.num], node.counts[:node.num])
			children[i] = Slot{value = child.node_ptr, tag = .Index}
			counts[i] = child.count
			split := child.split.?
			for j := node.num; j > i + 1; j -= 1 {
				children[j] = children[j - 1]
				counts[j] = counts[j - 1]
			}
			children[i + 1] = Slot{value = split.node_ptr, tag = .Index}
			counts[i + 1] = split.count
			total := node.num + 1

			if total <= BTREE_SLOT_COUNT {
				branch := BTree_Node{kind = .Branch, num = total}
				copy(branch.children[:total], children[:total])
				copy(branch.counts[:total], counts[:total])
				ptr := btree_write_node(db, branch, node_ptr, frozen_at) or_return
				return BTree_Insert_Result{
					node_ptr       = ptr,
					count          = btree_node_subtree_count(branch),
					value_position = child.value_position,
				}, nil
			}

			left_n := BTREE_SPLIT_COUNT
			right_n := total - left_n
			left := BTree_Node{kind = .Branch, num = left_n}
			copy(left.children[:left_n], children[:left_n])
			copy(left.counts[:left_n], counts[:left_n])
			right := BTree_Node{kind = .Branch, num = right_n}
			copy(right.children[:right_n], children[left_n:total])
			copy(right.counts[:right_n], counts[left_n:total])
			left_ptr := btree_write_node(db, left, node_ptr, frozen_at) or_return
			right_ptr := write_btree_node(db, right) or_return
			return BTree_Insert_Result{
				node_ptr       = left_ptr,
				count          = btree_node_subtree_count(left),
				value_position = child.value_position,
				split          = BTree_Node_Ref{node_ptr = right_ptr, count = btree_node_subtree_count(right)},
			}, nil
		}
	}

	node := read_btree_node(db, node_ptr) or_return
	switch node.kind {
	case .Leaf:
		r := int(rank)
		if r < 0 || r > node.num {
			return {}, .Invalid_BTree_Node
		}
		vals: [BTREE_SLOT_COUNT + 1]Slot
		copy(vals[:r], node.values[:r])
		vals[r] = Slot{value = 0, tag = .None, full = true}
		copy(vals[r + 1 : node.num + 1], node.values[r:node.num])
		total := node.num + 1

		if total <= BTREE_SLOT_COUNT {
			leaf := BTree_Node{kind = .Leaf, num = total}
			copy(leaf.values[:total], vals[:total])
			ptr := btree_write_node(db, leaf, node_ptr, frozen_at) or_return
			return BTree_Insert_Result{
				node_ptr       = ptr,
				count          = i64(total),
				value_position = ptr + BTREE_NODE_HEADER_SIZE + i64(r) * SLOT_LENGTH,
			}, nil
		}

		// Overflow: split into two leaves (reuse this node for the left half)
		left_n := BTREE_SPLIT_COUNT
		right_n := total - left_n
		left := BTree_Node{kind = .Leaf, num = left_n}
		copy(left.values[:left_n], vals[:left_n])
		right := BTree_Node{kind = .Leaf, num = right_n}
		copy(right.values[:right_n], vals[left_n:total])
		left_ptr := btree_write_node(db, left, node_ptr, frozen_at) or_return
		right_ptr := write_btree_node(db, right) or_return
		value_position: i64
		if r < left_n {
			value_position = left_ptr + BTREE_NODE_HEADER_SIZE + i64(r) * SLOT_LENGTH
		} else {
			value_position = right_ptr + BTREE_NODE_HEADER_SIZE + i64(r - left_n) * SLOT_LENGTH
		}
		return BTree_Insert_Result{
			node_ptr       = left_ptr,
			count          = i64(left_n),
			value_position = value_position,
			split          = BTree_Node_Ref{node_ptr = right_ptr, count = i64(right_n)},
		}, nil

	case .Branch:
		i := 0
		rem := rank
		for i + 1 < node.num && rem > node.counts[i] {
			rem -= node.counts[i]
			i += 1
		}
		child_ptr := node.children[i].value
		child := btree_insert(db, child_ptr, rem, frozen_at) or_return
		if child.split == nil && btree_reusable(db, node_ptr, frozen_at) {
			if child.node_ptr != child_ptr {
				child_slot_pos := node_ptr + BTREE_NODE_HEADER_SIZE + i64(i) * SLOT_LENGTH
				core_seek_to(db.core, child_slot_pos) or_return
				core_write_slot(db.core, Slot{value = child.node_ptr, tag = .Index}) or_return
				node.children[i] = Slot{value = child.node_ptr, tag = .Index}
			}
			count_pos := node_ptr + BTREE_NODE_HEADER_SIZE + SLOT_LENGTH * BTREE_SLOT_COUNT + i64(i) * 8
			core_seek_to(db.core, count_pos) or_return
			core_write_i64(db.core, child.count) or_return
			node.counts[i] = child.count
			return BTree_Insert_Result{
				node_ptr       = node_ptr,
				count          = btree_node_subtree_count(node),
				value_position = child.value_position,
			}, nil
		}

		children: [BTREE_SLOT_COUNT + 1]Slot
		counts: [BTREE_SLOT_COUNT + 1]i64
		copy(children[:node.num], node.children[:node.num])
		copy(counts[:node.num], node.counts[:node.num])
		children[i] = Slot{value = child.node_ptr, tag = .Index}
		counts[i] = child.count
		total := node.num
		if split, ok := child.split.?; ok {
			for j := node.num; j > i + 1; j -= 1 {
				children[j] = children[j - 1]
				counts[j] = counts[j - 1]
			}
			children[i + 1] = Slot{value = split.node_ptr, tag = .Index}
			counts[i + 1] = split.count
			total = node.num + 1
		}

		if total <= BTREE_SLOT_COUNT {
			branch := BTree_Node{kind = .Branch, num = total}
			copy(branch.children[:total], children[:total])
			copy(branch.counts[:total], counts[:total])
			ptr := btree_write_node(db, branch, node_ptr, frozen_at) or_return
			return BTree_Insert_Result{
				node_ptr       = ptr,
				count          = btree_node_subtree_count(branch),
				value_position = child.value_position,
			}, nil
		}

		left_n := BTREE_SPLIT_COUNT
		right_n := total - left_n
		left := BTree_Node{kind = .Branch, num = left_n}
		copy(left.children[:left_n], children[:left_n])
		copy(left.counts[:left_n], counts[:left_n])
		right := BTree_Node{kind = .Branch, num = right_n}
		copy(right.children[:right_n], children[left_n:total])
		copy(right.counts[:right_n], counts[left_n:total])
		left_ptr := btree_write_node(db, left, node_ptr, frozen_at) or_return
		right_ptr := write_btree_node(db, right) or_return
		return BTree_Insert_Result{
			node_ptr       = left_ptr,
			count          = btree_node_subtree_count(left),
			value_position = child.value_position,
			split          = BTree_Node_Ref{node_ptr = right_ptr, count = btree_node_subtree_count(right)},
		}, nil
	}
	return {}, .Unreachable
}

btree_grow_root :: proc(db: ^Database, result: BTree_Insert_Result) -> (res: i64, err: Error) {
	return btree_make_root(db, BTree_Join_Result{node_ptr = result.node_ptr, count = result.count, split = result.split})
}

btree_get_for_write :: proc(db: ^Database, node_ptr, rank, frozen_at: i64) -> (res: BTree_Write_Slot, err: Error) {
	header_bytes: [BTREE_NODE_HEADER_SIZE]u8
	core_read_exact_at(db.core, node_ptr, header_bytes[:]) or_return
	kind_int := header_bytes[0]
	if kind_int > u8(BTree_Node_Kind.Branch) {
		return {}, .Invalid_BTree_Node_Kind
	}
	num := int(header_bytes[1])
	if num > BTREE_SLOT_COUNT {
		return {}, .Invalid_BTree_Node
	}
	reusable := btree_reusable(db, node_ptr, frozen_at)
	if BTree_Node_Kind(kind_int) == .Leaf {
		if rank < 0 || rank >= i64(num) {
			return {}, .Invalid_BTree_Node
		}
		if reusable {
			val_pos := node_ptr + BTREE_NODE_HEADER_SIZE + rank * SLOT_LENGTH
			slot := core_read_slot_at(db.core, val_pos) or_return
			return BTree_Write_Slot{
				node_ptr       = node_ptr,
				value_position = val_pos,
				slot           = slot,
			}, nil
		}
		node := read_btree_node(db, node_ptr) or_return
		new_ptr := write_btree_node(db, node) or_return
		return BTree_Write_Slot{
			node_ptr       = new_ptr,
			value_position = new_ptr + BTREE_NODE_HEADER_SIZE + rank * SLOT_LENGTH,
			slot           = node.values[rank],
		}, nil
	}

	if reusable {
		counts_pos := node_ptr + BTREE_NODE_HEADER_SIZE + SLOT_LENGTH * BTREE_SLOT_COUNT
		counts_buf: [8 * BTREE_SLOT_COUNT]u8
		core_read_exact_at(db.core, counts_pos, counts_buf[:num * 8]) or_return
		i := 0
		rem := rank
		for i + 1 < num {
			cnt := i64(endian.unchecked_get_u64be(counts_buf[i * 8 : i * 8 + 8]))
			if rem < cnt {
				break
			}
			rem -= cnt
			i += 1
		}
		child_slot_pos := node_ptr + BTREE_NODE_HEADER_SIZE + i64(i) * SLOT_LENGTH
		child_slot := core_read_slot_at(db.core, child_slot_pos) or_return
		child_ptr := child_slot.value
		child := btree_get_for_write(db, child_ptr, rem, frozen_at) or_return
		if child.node_ptr != child_ptr {
			core_seek_to(db.core, child_slot_pos) or_return
			core_write_slot(db.core, Slot{value = child.node_ptr, tag = .Index}) or_return
		}
		return BTree_Write_Slot{node_ptr = node_ptr, value_position = child.value_position, slot = child.slot}, nil
	}

	node := read_btree_node(db, node_ptr) or_return
	i := 0
	rem := rank
	for i + 1 < node.num && rem >= node.counts[i] {
		rem -= node.counts[i]
		i += 1
	}
	child_ptr := node.children[i].value
	child := btree_get_for_write(db, child_ptr, rem, frozen_at) or_return
	node.children[i] = Slot{value = child.node_ptr, tag = .Index}
	new_ptr := write_btree_node(db, node) or_return
	return BTree_Write_Slot{node_ptr = new_ptr, value_position = child.value_position, slot = child.slot}, nil
}

BTree_Remove_Result :: struct {
	node_ptr:  i64,
	kind:      BTree_Node_Kind,
	num:       int,
	persisted: bool,
	node:      BTree_Node,
}

btree_remove :: proc(db: ^Database, node_ptr, rank, frozen_at: i64, is_root: bool = false) -> (res: BTree_Remove_Result, err: Error) {
	reusable := btree_reusable(db, node_ptr, frozen_at)
	if reusable {
		header_bytes: [BTREE_NODE_HEADER_SIZE]u8
		core_read_exact_at(db.core, node_ptr, header_bytes[:]) or_return
		kind_int := header_bytes[0]
		if kind_int > u8(BTree_Node_Kind.Branch) {
			return {}, .Invalid_BTree_Node_Kind
		}
		num := int(header_bytes[1])
		if num > BTREE_SLOT_COUNT {
			return {}, .Invalid_BTree_Node
		}
		position := node_ptr + BTREE_NODE_HEADER_SIZE
		if BTree_Node_Kind(kind_int) == .Leaf {
			r := int(rank)
			if r < 0 || r >= num {
				return {}, .Invalid_BTree_Node
			}
			total := num - 1
			if is_root || total >= BTREE_SPLIT_COUNT {
				entry_pos := position + i64(r) * SLOT_LENGTH
				tail_len := (total - r) * SLOT_LENGTH
				shift_buf: [SLOT_LENGTH * BTREE_SLOT_COUNT]u8
				if tail_len > 0 {
					core_read_exact_at(db.core, entry_pos + SLOT_LENGTH, shift_buf[:tail_len]) or_return
				}
				core_seek_to(db.core, entry_pos) or_return
				core_write_all(db.core, shift_buf[:tail_len + SLOT_LENGTH]) or_return
				new_hdr := [BTREE_NODE_HEADER_SIZE]u8{header_bytes[0], u8(total)}
				core_seek_to(db.core, node_ptr) or_return
				core_write_all(db.core, new_hdr[:]) or_return
				return BTree_Remove_Result{
					node_ptr  = node_ptr,
					kind      = .Leaf,
					num       = total,
					persisted = true,
				}, nil
			}
			node := read_btree_node(db, node_ptr) or_return
			copy(node.values[r : node.num - 1], node.values[r + 1 : node.num])
			node.num -= 1
			node.values[node.num] = Slot{}
			return BTree_Remove_Result{
				node_ptr  = node_ptr,
				kind      = .Leaf,
				num       = node.num,
				persisted = false,
				node      = node,
			}, nil
		} else {
			counts_pos := position + SLOT_LENGTH * BTREE_SLOT_COUNT
			counts_buf: [8 * BTREE_SLOT_COUNT]u8
			core_read_exact_at(db.core, counts_pos, counts_buf[:num * 8]) or_return
			i := 0
			rem := rank
			chosen_cnt: i64 = 0
			for i < num {
				cnt := i64(endian.unchecked_get_u64be(counts_buf[i * 8 : i * 8 + 8]))
				if i + 1 == num || rem < cnt {
					chosen_cnt = cnt
					break
				}
				rem -= cnt
				i += 1
			}
			child_slot_pos := position + i64(i) * SLOT_LENGTH
			child_slot := core_read_slot_at(db.core, child_slot_pos) or_return
			child_ptr := child_slot.value
			child := btree_remove(db, child_ptr, rem, frozen_at, false) or_return
			if child.num >= BTREE_SPLIT_COUNT || num == 1 {
				ptr := child.node_ptr
				if !child.persisted {
					ptr = btree_write_node(db, child.node, child_ptr, frozen_at) or_return
				}
				if ptr != child_ptr {
					core_seek_to(db.core, child_slot_pos) or_return
					core_write_slot(db.core, Slot{value = ptr, tag = .Index}) or_return
				}
				core_seek_to(db.core, counts_pos + i64(i) * 8) or_return
				core_write_i64(db.core, chosen_cnt - 1) or_return
				return BTree_Remove_Result{
					node_ptr  = node_ptr,
					kind      = .Branch,
					num       = num,
					persisted = true,
				}, nil
			}
			node := read_btree_node(db, node_ptr) or_return
			child_node := child.node
			if child.persisted {
				child_node = read_btree_node(db, child.node_ptr) or_return
			}
			if child_node.num == 0 {
				btree_drop_child(&node, i)
				return BTree_Remove_Result{
					node_ptr  = node_ptr,
					kind      = .Branch,
					num       = node.num,
					persisted = false,
					node      = node,
				}, nil
			}
			first := i
			neighbor_i := i + 1
			if i + 1 >= node.num {
				first = i - 1
				neighbor_i = first
			}
			neighbor := read_btree_node(db, node.children[neighbor_i].value) or_return
			if child_node.num + neighbor.num <= BTREE_SLOT_COUNT {
				if first == i {
					child_node = btree_concat_nodes(child_node, neighbor)
				} else {
					child_node = btree_concat_nodes(neighbor, child_node)
				}
				btree_drop_child(&node, first + 1)
				i = first
			}
			ptr := btree_write_node(db, child_node, child_ptr, frozen_at) or_return
			node.children[i] = Slot{value = ptr, tag = .Index}
			node.counts[i] = btree_node_subtree_count(child_node)
			if is_root || node.num >= BTREE_SPLIT_COUNT {
				write_btree_node_at(db, node, node_ptr) or_return
				return BTree_Remove_Result{
					node_ptr  = node_ptr,
					kind      = .Branch,
					num       = node.num,
					persisted = true,
				}, nil
			}
			return BTree_Remove_Result{
				node_ptr  = node_ptr,
				kind      = .Branch,
				num       = node.num,
				persisted = false,
				node      = node,
			}, nil
		}
	}

	node := read_btree_node(db, node_ptr) or_return
	switch node.kind {
	case .Leaf:
		r := int(rank)
		if r < 0 || r >= node.num {
			return {}, .Invalid_BTree_Node
		}
		copy(node.values[r : node.num - 1], node.values[r + 1 : node.num])
		node.num -= 1
		node.values[node.num] = Slot{}

	case .Branch:
		i := 0
		rem := rank
		for i + 1 < node.num && rem >= node.counts[i] {
			rem -= node.counts[i]
			i += 1
		}
		child_ptr := node.children[i].value
		child := btree_remove(db, child_ptr, rem, frozen_at, false) or_return
		if child.num == 0 {
			btree_drop_child(&node, i)
			return BTree_Remove_Result{
				node_ptr  = node_ptr,
				kind      = .Branch,
				num       = node.num,
				persisted = false,
				node      = node,
			}, nil
		}
		child_node := child.node
		if child.num < BTREE_SPLIT_COUNT && node.num > 1 {
			if child.persisted {
				child_node = read_btree_node(db, child.node_ptr) or_return
			}
			first := i
			neighbor_i := i + 1
			if i + 1 >= node.num {
				first = i - 1
				neighbor_i = first
			}
			neighbor := read_btree_node(db, node.children[neighbor_i].value) or_return
			if child_node.num + neighbor.num <= BTREE_SLOT_COUNT {
				if first == i {
					child_node = btree_concat_nodes(child_node, neighbor)
				} else {
					child_node = btree_concat_nodes(neighbor, child_node)
				}
				btree_drop_child(&node, first + 1)
				i = first
			}
			ptr := btree_write_node(db, child_node, child_ptr, frozen_at) or_return
			node.children[i] = Slot{value = ptr, tag = .Index}
			node.counts[i] = btree_node_subtree_count(child_node)
		} else {
			ptr := child.node_ptr
			if !child.persisted {
				ptr = btree_write_node(db, child_node, child_ptr, frozen_at) or_return
			}
			node.children[i] = Slot{value = ptr, tag = .Index}
			node.counts[i] -= 1
		}
	}
	return BTree_Remove_Result{
		node_ptr  = node_ptr,
		kind      = node.kind,
		num       = node.num,
		persisted = false,
		node      = node,
	}, nil
}

btree_drop_child :: proc(branch: ^BTree_Node, i: int) {
	copy(branch.children[i : branch.num - 1], branch.children[i + 1 : branch.num])
	copy(branch.counts[i : branch.num - 1], branch.counts[i + 1 : branch.num])
	branch.num -= 1
	branch.children[branch.num] = Slot{}
	branch.counts[branch.num] = 0
}

btree_concat_nodes :: proc(a, b: BTree_Node) -> BTree_Node {
	a, b := a, b
	node := a
	switch a.kind {
	case .Leaf:
		copy(node.values[a.num : a.num + b.num], b.values[:b.num])
	case .Branch:
		copy(node.children[a.num : a.num + b.num], b.children[:b.num])
		copy(node.counts[a.num : a.num + b.num], b.counts[:b.num])
	}
	node.num = a.num + b.num
	return node
}

btree_height :: proc(db: ^Database, root_ptr: i64) -> (res: int, err: Error) {
	ptr := root_ptr
	height := 0
	for {
		buf: [BTREE_NODE_HEADER_SIZE + SLOT_LENGTH]u8
		core_read_exact_at(db.core, ptr, buf[:]) or_return
		kind_int := buf[0]
		if kind_int > u8(BTree_Node_Kind.Branch) {
			return 0, .Invalid_BTree_Node_Kind
		}
		if BTree_Node_Kind(kind_int) == .Leaf {
			return height, nil
		}
		height += 1
		child_slot := slot_from_slice(buf[BTREE_NODE_HEADER_SIZE:]) or_return
		ptr = child_slot.value
	}
}

btree_make_root :: proc(db: ^Database, result: BTree_Join_Result) -> (res: i64, err: Error) {
	if split, ok := result.split.?; ok {
		root := BTree_Node{kind = .Branch, num = 2}
		root.children[0] = Slot{value = result.node_ptr, tag = .Index}
		root.children[1] = Slot{value = split.node_ptr, tag = .Index}
		root.counts[0] = result.count
		root.counts[1] = split.count
		return write_btree_node(db, root)
	}
	return result.node_ptr, nil
}

btree_assemble_leaf :: proc(db: ^Database, vals: []Slot, total: int) -> (res: BTree_Join_Result, err: Error) {
	if total <= BTREE_SLOT_COUNT {
		leaf := BTree_Node{kind = .Leaf, num = total}
		copy(leaf.values[:total], vals[:total])
		ptr := write_btree_node(db, leaf) or_return
		return BTree_Join_Result{node_ptr = ptr, count = i64(total)}, nil
	}
	left_n := total / 2
	left := BTree_Node{kind = .Leaf, num = left_n}
	copy(left.values[:left_n], vals[:left_n])
	right := BTree_Node{kind = .Leaf, num = total - left_n}
	copy(right.values[: total - left_n], vals[left_n:total])
	left_ptr := write_btree_node(db, left) or_return
	right_ptr := write_btree_node(db, right) or_return
	return BTree_Join_Result{
		node_ptr = left_ptr,
		count    = i64(left_n),
		split    = BTree_Node_Ref{node_ptr = right_ptr, count = i64(total - left_n)},
	}, nil
}

btree_assemble_branch :: proc(db: ^Database, children: []Slot, counts: []i64, total: int) -> (res: BTree_Join_Result, err: Error) {
	if total <= BTREE_SLOT_COUNT {
		branch := BTree_Node{kind = .Branch, num = total}
		copy(branch.children[:total], children[:total])
		copy(branch.counts[:total], counts[:total])
		ptr := write_btree_node(db, branch) or_return
		return BTree_Join_Result{node_ptr = ptr, count = btree_node_subtree_count(branch)}, nil
	}
	left_n := total / 2
	left := BTree_Node{kind = .Branch, num = left_n}
	copy(left.children[:left_n], children[:left_n])
	copy(left.counts[:left_n], counts[:left_n])
	right := BTree_Node{kind = .Branch, num = total - left_n}
	copy(right.children[: total - left_n], children[left_n:total])
	copy(right.counts[: total - left_n], counts[left_n:total])
	left_ptr := write_btree_node(db, left) or_return
	right_ptr := write_btree_node(db, right) or_return
	return BTree_Join_Result{
		node_ptr = left_ptr,
		count    = btree_node_subtree_count(left),
		split    = BTree_Node_Ref{node_ptr = right_ptr, count = btree_node_subtree_count(right)},
	}, nil
}

btree_merge_nodes :: proc(db: ^Database, a, b: BTree_Node) -> (res: BTree_Join_Result, err: Error) {
	a, b := a, b
	if a.kind == .Leaf {
		vals: [2 * BTREE_SLOT_COUNT]Slot
		copy(vals[:a.num], a.values[:a.num])
		copy(vals[a.num : a.num + b.num], b.values[:b.num])
		return btree_assemble_leaf(db, vals[: a.num + b.num], a.num + b.num)
	}
	children: [2 * BTREE_SLOT_COUNT]Slot
	counts: [2 * BTREE_SLOT_COUNT]i64
	copy(children[:a.num], a.children[:a.num])
	copy(children[a.num : a.num + b.num], b.children[:b.num])
	copy(counts[:a.num], a.counts[:a.num])
	copy(counts[a.num : a.num + b.num], b.counts[:b.num])
	return btree_assemble_branch(db, children[: a.num + b.num], counts[: a.num + b.num], a.num + b.num)
}

btree_join_right :: proc(db: ^Database, a_ptr: i64, ha: int, b_ptr: i64, hb: int) -> (res: BTree_Join_Result, err: Error) {
	a := read_btree_node(db, a_ptr) or_return
	last := a.num - 1
	sub: BTree_Join_Result
	if ha - 1 == hb {
		last_child := read_btree_node(db, a.children[last].value) or_return
		b_node := read_btree_node(db, b_ptr) or_return
		sub = btree_merge_nodes(db, last_child, b_node) or_return
	} else {
		sub = btree_join_right(db, a.children[last].value, ha - 1, b_ptr, hb) or_return
	}

	children: [BTREE_SLOT_COUNT + 1]Slot
	counts: [BTREE_SLOT_COUNT + 1]i64
	copy(children[:a.num], a.children[:a.num])
	copy(counts[:a.num], a.counts[:a.num])
	children[last] = Slot{value = sub.node_ptr, tag = .Index}
	counts[last] = sub.count
	total := a.num
	if split, ok := sub.split.?; ok {
		children[total] = Slot{value = split.node_ptr, tag = .Index}
		counts[total] = split.count
		total += 1
	}
	return btree_assemble_branch(db, children[:total], counts[:total], total)
}

btree_join_left :: proc(db: ^Database, a_ptr: i64, ha: int, b_ptr: i64, hb: int) -> (res: BTree_Join_Result, err: Error) {
	b := read_btree_node(db, b_ptr) or_return
	sub: BTree_Join_Result
	if hb - 1 == ha {
		a_node := read_btree_node(db, a_ptr) or_return
		first_child := read_btree_node(db, b.children[0].value) or_return
		sub = btree_merge_nodes(db, a_node, first_child) or_return
	} else {
		sub = btree_join_left(db, a_ptr, ha, b.children[0].value, hb - 1) or_return
	}

	children: [BTREE_SLOT_COUNT + 1]Slot
	counts: [BTREE_SLOT_COUNT + 1]i64
	total := 0
	children[total] = Slot{value = sub.node_ptr, tag = .Index}
	counts[total] = sub.count
	total += 1
	if split, ok := sub.split.?; ok {
		children[total] = Slot{value = split.node_ptr, tag = .Index}
		counts[total] = split.count
		total += 1
	}
	for k in 1 ..< b.num {
		children[total] = b.children[k]
		counts[total] = b.counts[k]
		total += 1
	}
	return btree_assemble_branch(db, children[:total], counts[:total], total)
}

btree_join :: proc(db: ^Database, root_a, root_b: i64) -> (res: i64, err: Error) {
	ha := btree_height(db, root_a) or_return
	hb := btree_height(db, root_b) or_return
	result: BTree_Join_Result
	if ha == hb {
		a := read_btree_node(db, root_a) or_return
		b := read_btree_node(db, root_b) or_return
		result = btree_merge_nodes(db, a, b) or_return
	} else if ha > hb {
		result = btree_join_right(db, root_a, ha, root_b, hb) or_return
	} else {
		result = btree_join_left(db, root_a, ha, root_b, hb) or_return
	}
	return btree_make_root(db, result)
}

btree_subtree :: proc(db: ^Database, children: []Slot, counts: []i64, start, length: int) -> (res: i64, err: Error) {
	if length == 0 {
		return btree_new_root(db)
	}
	if length == 1 {
		return children[start].value, nil
	}
	sub_children: [BTREE_SLOT_COUNT]Slot
	sub_counts: [BTREE_SLOT_COUNT]i64
	copy(sub_children[:length], children[start : start + length])
	copy(sub_counts[:length], counts[start : start + length])
	branch_res := btree_assemble_branch(db, sub_children[:length], sub_counts[:length], length) or_return
	return branch_res.node_ptr, nil
}

btree_split_right :: proc(db: ^Database, root_ptr, rank: i64) -> (res: i64, err: Error) {
	if rank == 0 {
		return root_ptr, nil
	}
	node := read_btree_node(db, root_ptr) or_return
	if node.kind == .Leaf {
		r := int(rank)
		if r < 0 || r > node.num {
			return 0, .Invalid_BTree_Node
		}
		right := BTree_Node{kind = .Leaf, num = node.num - r}
		copy(right.values[: node.num - r], node.values[r:node.num])
		return write_btree_node(db, right)
	}
	i := 0
	rem := rank
	for i + 1 < node.num && rem > node.counts[i] {
		rem -= node.counts[i]
		i += 1
	}
	if rem == node.counts[i] {
		return btree_subtree(db, node.children[:], node.counts[:], i + 1, node.num - (i + 1))
	}
	child_right := btree_split_right(db, node.children[i].value, rem) or_return
	joined_right := child_right
	if i + 1 < node.num {
		right_sub := btree_subtree(db, node.children[:], node.counts[:], i + 1, node.num - (i + 1)) or_return
		joined_right = btree_join(db, child_right, right_sub) or_return
	}
	return joined_right, nil
}

btree_split_left :: proc(db: ^Database, root_ptr, rank: i64) -> (res: i64, err: Error) {
	if rank == 0 {
		return btree_new_root(db)
	}
	node := read_btree_node(db, root_ptr) or_return
	if node.kind == .Leaf {
		r := int(rank)
		if r < 0 || r > node.num {
			return 0, .Invalid_BTree_Node
		}
		if r == node.num {
			return root_ptr, nil
		}
		left := BTree_Node{kind = .Leaf, num = r}
		copy(left.values[:r], node.values[:r])
		return write_btree_node(db, left)
	}
	i := 0
	rem := rank
	for i + 1 < node.num && rem > node.counts[i] {
		rem -= node.counts[i]
		i += 1
	}
	if rem == node.counts[i] {
		if i + 1 == node.num {
			return root_ptr, nil
		}
		return btree_subtree(db, node.children[:], node.counts[:], 0, i + 1)
	}
	child_left := btree_split_left(db, node.children[i].value, rem) or_return
	joined_left := child_left
	if i > 0 {
		left_sub := btree_subtree(db, node.children[:], node.counts[:], 0, i) or_return
		joined_left = btree_join(db, left_sub, child_left) or_return
	}
	return joined_left, nil
}

btree_split :: proc(db: ^Database, root_ptr, rank: i64) -> (res: BTree_Split_Result, err: Error) {
	node := read_btree_node(db, root_ptr) or_return
	if node.kind == .Leaf {
		r := int(rank)
		if r < 0 || r > node.num {
			return {}, .Invalid_BTree_Node
		}
		left := BTree_Node{kind = .Leaf, num = r}
		copy(left.values[:r], node.values[:r])
		right := BTree_Node{kind = .Leaf, num = node.num - r}
		copy(right.values[: node.num - r], node.values[r:node.num])
		left_ptr := write_btree_node(db, left) or_return
		right_ptr := write_btree_node(db, right) or_return
		return BTree_Split_Result{left = left_ptr, right = right_ptr}, nil
	}
	i := 0
	rem := rank
	for i + 1 < node.num && rem > node.counts[i] {
		rem -= node.counts[i]
		i += 1
	}
	child := btree_split(db, node.children[i].value, rem) or_return
	joined_left := child.left
	if i > 0 {
		left_sub := btree_subtree(db, node.children[:], node.counts[:], 0, i) or_return
		joined_left = btree_join(db, left_sub, child.left) or_return
	}
	joined_right := child.right
	if i + 1 < node.num {
		right_sub := btree_subtree(db, node.children[:], node.counts[:], i + 1, node.num - (i + 1)) or_return
		joined_right = btree_join(db, child.right, right_sub) or_return
	}
	return BTree_Split_Result{left = joined_left, right = joined_right}, nil
}

// SortedMap / SortedSet methods (backed by a count-augmented B+Tree)

read_sorted_node :: proc(db: ^Database, ptr: i64) -> (res: Sorted_Node, err: Error) {
	header_bytes: [BTREE_NODE_HEADER_SIZE]u8 = ---
	core_read_exact_at(db.core, ptr, header_bytes[:]) or_return
	kind_int := header_bytes[0]
	if kind_int > u8(BTree_Node_Kind.Branch) {
		return {}, .Invalid_BTree_Node_Kind
	}
	kind := BTree_Node_Kind(kind_int)
	num := int(header_bytes[1])
	if num > BTREE_SLOT_COUNT {
		return {}, .Invalid_BTree_Node
	}
	node := Sorted_Node{kind = kind, num = num}
	switch kind {
	case .Leaf:
		body: [SLOT_LENGTH * BTREE_SLOT_COUNT]u8 = ---
		core_read_exact_at(db.core, ptr + BTREE_NODE_HEADER_SIZE, body[:]) or_return
		for i in 0 ..< num {
			node.entries[i] = slot_from_slice(body[i * SLOT_LENGTH : i * SLOT_LENGTH + SLOT_LENGTH]) or_return
		}
	case .Branch:
		body: [(SLOT_LENGTH * 2 + 8) * BTREE_SLOT_COUNT]u8 = ---
		core_read_exact_at(db.core, ptr + BTREE_NODE_HEADER_SIZE, body[:]) or_return
		for i in 0 ..< num {
			node.children[i] = slot_from_slice(body[i * SLOT_LENGTH : i * SLOT_LENGTH + SLOT_LENGTH]) or_return
		}
		sep_offset := SLOT_LENGTH * BTREE_SLOT_COUNT
		for i in 0 ..< num {
			node.separators[i] = slot_from_slice(body[sep_offset + i * SLOT_LENGTH : sep_offset + i * SLOT_LENGTH + SLOT_LENGTH]) or_return
		}
		counts_offset := SLOT_LENGTH * 2 * BTREE_SLOT_COUNT
		for i in 0 ..< num {
			node.counts[i] = i64(endian.unchecked_get_u64be(body[counts_offset + i * 8 : counts_offset + i * 8 + 8]))
		}
	}
	return node, nil
}

write_sorted_node_at :: proc(db: ^Database, node: Sorted_Node, ptr: i64) -> Error {
	core_seek_to(db.core, ptr) or_return
	switch node.kind {
	case .Leaf:
		buf: [SORTED_LEAF_BLOCK_SIZE]u8
		buf[0] = u8(node.kind)
		buf[1] = u8(node.num)
		off := BTREE_NODE_HEADER_SIZE
		for i in 0 ..< node.num {
			sb := slot_to_bytes(node.entries[i])
			copy(buf[off:], sb[:])
			off += SLOT_LENGTH
		}
		return core_write_all(db.core, buf[:])
	case .Branch:
		buf: [SORTED_BRANCH_BLOCK_SIZE]u8
		buf[0] = u8(node.kind)
		buf[1] = u8(node.num)
		off := BTREE_NODE_HEADER_SIZE
		for i in 0 ..< node.num {
			sb := slot_to_bytes(node.children[i])
			copy(buf[off:], sb[:])
			off += SLOT_LENGTH
		}
		sep_off := BTREE_NODE_HEADER_SIZE + SLOT_LENGTH * BTREE_SLOT_COUNT
		for i in 0 ..< node.num {
			sb := slot_to_bytes(node.separators[i])
			copy(buf[sep_off:], sb[:])
			sep_off += SLOT_LENGTH
		}
		counts_off := BTREE_NODE_HEADER_SIZE + SLOT_LENGTH * 2 * BTREE_SLOT_COUNT
		for i in 0 ..< node.num {
			endian.unchecked_put_u64be(buf[counts_off : counts_off + 8], u64(node.counts[i]))
			counts_off += 8
		}
		return core_write_all(db.core, buf[:])
	}
	return .Unreachable
}

write_sorted_node :: proc(db: ^Database, node: Sorted_Node) -> (res: i64, err: Error) {
	ptr := core_length(db.core) or_return
	write_sorted_node_at(db, node, ptr) or_return
	return ptr, nil
}

sorted_write_node :: proc(db: ^Database, node: Sorted_Node, old_ptr, frozen_at: i64) -> (res: i64, err: Error) {
	if btree_reusable(db, old_ptr, frozen_at) {
		write_sorted_node_at(db, node, old_ptr) or_return
		return old_ptr, nil
	}
	return write_sorted_node(db, node)
}

read_kv_pair :: proc(db: ^Database, entry: Slot) -> (res: Key_Value_Pair, err: Error) {
	if is_key_only_entry(entry) {
		return Key_Value_Pair{value_slot = Slot{}, key_slot = entry, hash = nil}, nil
	}
	return decode_kv_pair_at(db.core, entry.value, entry.tag, 0, context.temp_allocator)
}

sorted_entry_key_slot :: #force_inline proc(db: ^Database, entry: Slot) -> (res: Slot, err: Error) {
	if is_key_only_entry(entry) {
		return entry, nil
	}
	return core_read_slot_at(db.core, entry.value)
}

write_kv_pair :: proc(db: ^Database, tag: Tag, kv_pair: Key_Value_Pair) -> (res: Slot, err: Error) {
	pos := core_length(db.core) or_return
	core_seek_to(db.core, pos) or_return
	encode_kv_pair(db.core, tag, kv_pair) or_return
	return Slot{value = pos, tag = tag}, nil
}

compare_key :: proc(db: ^Database, key_slot: Slot, target: []u8) -> (res: int, err: Error) {
	#partial switch key_slot.tag {
	case .Short_Bytes:
		buf: [8]u8 = ---
		endian.unchecked_put_u64be(buf[:], u64(key_slot.value))
		total := 6 if key_slot.full else 8
		length := total
		for i in 0 ..< total {
			if buf[i] == 0 {
				length = i
				break
			}
		}
		return bytes.compare(buf[:length], target), nil
	case .Bytes:
		#partial switch &v in db.core {
		case Core_Memory:
			pos := int(key_slot.value)
			if pos < 0 || pos + 8 > len(v.buf) {
				return 0, Xitdb_Error.Unexpected_EOF
			}
			length := int(endian.unchecked_get_u64be(v.buf[pos : pos + 8]))
			if length < 0 || pos + 8 + length > len(v.buf) {
				return 0, Xitdb_Error.Unexpected_EOF
			}
			return bytes.compare(v.buf[pos + 8 : pos + 8 + length], target), nil
		case Core_Buffered_File:
			buf_len := i64(len(v.memory.buf))
			if buf_len > 0 && key_slot.value >= v.memory_pos && key_slot.value + 8 <= v.memory_pos + buf_len {
				mem_off := int(key_slot.value - v.memory_pos)
				length := int(endian.unchecked_get_u64be(v.memory.buf[mem_off : mem_off + 8]))
				if length >= 0 && mem_off + 8 + length <= int(buf_len) {
					return bytes.compare(v.memory.buf[mem_off + 8 : mem_off + 8 + length], target), nil
				}
			}
		}
		length := core_read_i64_at(db.core, key_slot.value) or_return
		read_len := min(int(length), len(target))
		if read_len <= 256 {
			stack_buf: [256]u8 = ---
			key_bytes := stack_buf[:read_len]
			core_read_exact_at(db.core, key_slot.value + 8, key_bytes) or_return
			c := bytes.compare(key_bytes, target[:read_len])
			if c != 0 {
				return c, nil
			}
			return -1 if int(length) < len(target) else (1 if int(length) > len(target) else 0), nil
		}
		key_bytes := make([]u8, read_len, context.temp_allocator)
		core_read_exact_at(db.core, key_slot.value + 8, key_bytes) or_return
		c := bytes.compare(key_bytes, target[:read_len])
		if c != 0 {
			return c, nil
		}
		return -1 if int(length) < len(target) else (1 if int(length) > len(target) else 0), nil
	case:
		return 0, .Unexpected_Tag
	}
}

// Binary search a Sorted_Node (.Leaf) for `key`.
// Returns `(index, true, nil)` on exact match, or `(lower_bound_index, false, nil)` if not found.
sorted_leaf_search :: proc(db: ^Database, node: ^Sorted_Node, key: []u8) -> (idx: int, found: bool, err: Error) {
	lo := 0
	hi := node.num
	for lo < hi {
		mid := int(uint(lo + hi) >> 1)
		key_slot := sorted_entry_key_slot(db, node.entries[mid]) or_return
		cmp := compare_key(db, key_slot, key) or_return
		if cmp == 0 {
			return mid, true, nil
		} else if cmp < 0 {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo, false, nil
}

// Binary search a Sorted_Node (.Branch) for the child index `0 ..< node.num` containing `key`.
sorted_branch_search :: proc(db: ^Database, node: ^Sorted_Node, key: []u8) -> (idx: int, err: Error) {
	lo := 1
	hi := node.num
	for lo < hi {
		mid := int(uint(lo + hi) >> 1)
		c := compare_key(db, node.separators[mid], key) or_return
		if c <= 0 {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo - 1, nil
}

sorted_get :: proc(db: ^Database, root_ptr: i64, key: []u8) -> (res: Maybe(Sorted_Slot), err: Error) {
	node_ptr := root_ptr
	for {
		if hdr_slice, in_mem, slice_err := core_slice_at(db.core, node_ptr, BTREE_NODE_HEADER_SIZE); in_mem {
			if slice_err != nil {
				return nil, slice_err
			}
			kind_int := hdr_slice[0]
			if kind_int > u8(BTree_Node_Kind.Branch) {
				return nil, .Invalid_BTree_Node_Kind
			}
			num := int(hdr_slice[1])
			if num > BTREE_SLOT_COUNT {
				return nil, .Invalid_BTree_Node
			}
			if BTree_Node_Kind(kind_int) == .Leaf {
				entries_slice, _, e_err := core_slice_at(db.core, node_ptr + BTREE_NODE_HEADER_SIZE, num * SLOT_LENGTH)
				if e_err != nil {
					return nil, e_err
				}
				lo := 0
				hi := num
				for lo < hi {
					mid := int(uint(lo + hi) >> 1)
					entry_slot := slot_from_slice(entries_slice[mid * SLOT_LENGTH : (mid + 1) * SLOT_LENGTH]) or_return
					key_slot := sorted_entry_key_slot(db, entry_slot) or_return
					cmp := compare_key(db, key_slot, key) or_return
					if cmp == 0 {
						entry_pos := node_ptr + BTREE_NODE_HEADER_SIZE + i64(mid) * SLOT_LENGTH
						return Sorted_Slot{slot = entry_slot, key_slot = key_slot, position = entry_pos}, nil
					} else if cmp < 0 {
						lo = mid + 1
					} else {
						hi = mid
					}
				}
				return nil, nil
			}
			branch_slice, _, b_err := core_slice_at(db.core, node_ptr + BTREE_NODE_HEADER_SIZE, (BTREE_SLOT_COUNT + num) * SLOT_LENGTH)
			if b_err != nil {
				return nil, b_err
			}
			lo := 1
			hi := num
			sep_off := SLOT_LENGTH * BTREE_SLOT_COUNT
			for lo < hi {
				mid := int(uint(lo + hi) >> 1)
				sep_slot := slot_from_slice(branch_slice[sep_off + mid * SLOT_LENGTH : sep_off + (mid + 1) * SLOT_LENGTH]) or_return
				c := compare_key(db, sep_slot, key) or_return
				if c <= 0 {
					lo = mid + 1
				} else {
					hi = mid
				}
			}
			child_idx := lo - 1
			child_slot := slot_from_slice(branch_slice[child_idx * SLOT_LENGTH : (child_idx + 1) * SLOT_LENGTH]) or_return
			node_ptr = child_slot.value
			continue
		}

		header_bytes: [BTREE_NODE_HEADER_SIZE]u8 = ---
		core_read_exact_at(db.core, node_ptr, header_bytes[:]) or_return
		kind_int := header_bytes[0]
		if kind_int > u8(BTree_Node_Kind.Branch) {
			return nil, .Invalid_BTree_Node_Kind
		}
		num := int(header_bytes[1])
		if num > BTREE_SLOT_COUNT {
			return nil, .Invalid_BTree_Node
		}
		if BTree_Node_Kind(kind_int) == .Leaf {
			entries_buf: [SLOT_LENGTH * BTREE_SLOT_COUNT]u8 = ---
			if num > 0 {
				core_read_exact_at(db.core, node_ptr + BTREE_NODE_HEADER_SIZE, entries_buf[:num * SLOT_LENGTH]) or_return
			}
			lo := 0
			hi := num
			for lo < hi {
				mid := int(uint(lo + hi) >> 1)
				entry_slot := slot_from_slice(entries_buf[mid * SLOT_LENGTH : (mid + 1) * SLOT_LENGTH]) or_return
				key_slot := sorted_entry_key_slot(db, entry_slot) or_return
				cmp := compare_key(db, key_slot, key) or_return
				if cmp == 0 {
					entry_pos := node_ptr + BTREE_NODE_HEADER_SIZE + i64(mid) * SLOT_LENGTH
					return Sorted_Slot{slot = entry_slot, key_slot = key_slot, position = entry_pos}, nil
				} else if cmp < 0 {
					lo = mid + 1
				} else {
					hi = mid
				}
			}
			return nil, nil
		}
		branch_buf: [SLOT_LENGTH * 2 * BTREE_SLOT_COUNT]u8 = ---
		core_read_exact_at(db.core, node_ptr + BTREE_NODE_HEADER_SIZE, branch_buf[:(BTREE_SLOT_COUNT + num) * SLOT_LENGTH]) or_return
		lo := 1
		hi := num
		sep_off := SLOT_LENGTH * BTREE_SLOT_COUNT
		for lo < hi {
			mid := int(uint(lo + hi) >> 1)
			sep_slot := slot_from_slice(branch_buf[sep_off + mid * SLOT_LENGTH : sep_off + (mid + 1) * SLOT_LENGTH]) or_return
			c := compare_key(db, sep_slot, key) or_return
			if c <= 0 {
				lo = mid + 1
			} else {
				hi = mid
			}
		}
		child_idx := lo - 1
		child_slot := slot_from_slice(branch_buf[child_idx * SLOT_LENGTH : (child_idx + 1) * SLOT_LENGTH]) or_return
		node_ptr = child_slot.value
	}
}

sorted_get_by_index :: proc(db: ^Database, root_ptr, rank: i64) -> (res: Sorted_Slot, err: Error) {
	node_ptr := root_ptr
	rem := rank
	for {
		if hdr_slice, in_mem, slice_err := core_slice_at(db.core, node_ptr, BTREE_NODE_HEADER_SIZE); in_mem {
			if slice_err != nil {
				return {}, slice_err
			}
			kind_int := hdr_slice[0]
			if kind_int > u8(BTree_Node_Kind.Branch) {
				return {}, .Invalid_BTree_Node_Kind
			}
			num := int(hdr_slice[1])
			if num > BTREE_SLOT_COUNT {
				return {}, .Invalid_BTree_Node
			}
			if BTree_Node_Kind(kind_int) == .Leaf {
				if rem >= i64(num) {
					return {}, .Invalid_BTree_Node
				}
				pos := node_ptr + BTREE_NODE_HEADER_SIZE + rem * SLOT_LENGTH
				s_slice, _, s_err := core_slice_at(db.core, pos, SLOT_LENGTH)
				if s_err != nil {
					return {}, s_err
				}
				slot := slot_from_slice(s_slice) or_return
				return Sorted_Slot{slot = slot, position = pos}, nil
			}
			body_len := SLOT_LENGTH * 2 * BTREE_SLOT_COUNT + num * 8
			body_slice, _, b_err := core_slice_at(db.core, node_ptr + BTREE_NODE_HEADER_SIZE, body_len)
			if b_err != nil {
				return {}, b_err
			}
			counts_off := SLOT_LENGTH * 2 * BTREE_SLOT_COUNT
			i := 0
			for i + 1 < num {
				cnt := i64(endian.unchecked_get_u64be(body_slice[counts_off + i * 8 : counts_off + (i + 1) * 8]))
				if rem < cnt {
					break
				}
				rem -= cnt
				i += 1
			}
			child_slot := slot_from_slice(body_slice[i * SLOT_LENGTH : (i + 1) * SLOT_LENGTH]) or_return
			node_ptr = child_slot.value
			continue
		}

		header_bytes: [BTREE_NODE_HEADER_SIZE]u8 = ---
		core_read_exact_at(db.core, node_ptr, header_bytes[:]) or_return
		kind_int := header_bytes[0]
		if kind_int > u8(BTree_Node_Kind.Branch) {
			return {}, .Invalid_BTree_Node_Kind
		}
		num := int(header_bytes[1])
		if num > BTREE_SLOT_COUNT {
			return {}, .Invalid_BTree_Node
		}
		if BTree_Node_Kind(kind_int) == .Leaf {
			if rem >= i64(num) {
				return {}, .Invalid_BTree_Node
			}
			pos := node_ptr + BTREE_NODE_HEADER_SIZE + rem * SLOT_LENGTH
			slot := core_read_slot_at(db.core, pos) or_return
			return Sorted_Slot{slot = slot, position = pos}, nil
		}
		counts_pos := node_ptr + BTREE_NODE_HEADER_SIZE + SLOT_LENGTH * 2 * BTREE_SLOT_COUNT
		counts_buf: [8 * BTREE_SLOT_COUNT]u8 = ---
		core_read_exact_at(db.core, counts_pos, counts_buf[:num * 8]) or_return
		i := 0
		for i + 1 < num {
			cnt := i64(endian.unchecked_get_u64be(counts_buf[i * 8 : i * 8 + 8]))
			if rem < cnt {
				break
			}
			rem -= cnt
			i += 1
		}
		child_pos := node_ptr + BTREE_NODE_HEADER_SIZE + i64(i) * SLOT_LENGTH
		child_slot := core_read_slot_at(db.core, child_pos) or_return
		node_ptr = child_slot.value
	}
}

sorted_rank :: proc(db: ^Database, root_ptr: i64, key: []u8) -> (res: i64, err: Error) {
	node_ptr := root_ptr
	rank: i64 = 0
	for {
		if hdr_slice, in_mem, slice_err := core_slice_at(db.core, node_ptr, BTREE_NODE_HEADER_SIZE); in_mem {
			if slice_err != nil {
				return 0, slice_err
			}
			kind_int := hdr_slice[0]
			if kind_int > u8(BTree_Node_Kind.Branch) {
				return 0, .Invalid_BTree_Node_Kind
			}
			num := int(hdr_slice[1])
			if num > BTREE_SLOT_COUNT {
				return 0, .Invalid_BTree_Node
			}
			if BTree_Node_Kind(kind_int) == .Leaf {
				entries_slice, _, e_err := core_slice_at(db.core, node_ptr + BTREE_NODE_HEADER_SIZE, num * SLOT_LENGTH)
				if e_err != nil {
					return 0, e_err
				}
				lo := 0
				hi := num
				for lo < hi {
					mid := int(uint(lo + hi) >> 1)
					entry_slot := slot_from_slice(entries_slice[mid * SLOT_LENGTH : (mid + 1) * SLOT_LENGTH]) or_return
					key_slot := sorted_entry_key_slot(db, entry_slot) or_return
					cmp := compare_key(db, key_slot, key) or_return
					if cmp == 0 {
						return rank + i64(mid), nil
					} else if cmp < 0 {
						lo = mid + 1
					} else {
						hi = mid
					}
				}
				return rank + i64(lo), nil
			}
			branch_slice, _, b_err := core_slice_at(db.core, node_ptr + BTREE_NODE_HEADER_SIZE, SLOT_LENGTH * 2 * BTREE_SLOT_COUNT + num * 8)
			if b_err != nil {
				return 0, b_err
			}
			lo := 1
			hi := num
			sep_off := SLOT_LENGTH * BTREE_SLOT_COUNT
			for lo < hi {
				mid := int(uint(lo + hi) >> 1)
				sep_slot := slot_from_slice(branch_slice[sep_off + mid * SLOT_LENGTH : sep_off + (mid + 1) * SLOT_LENGTH]) or_return
				c := compare_key(db, sep_slot, key) or_return
				if c <= 0 {
					lo = mid + 1
				} else {
					hi = mid
				}
			}
			i := lo - 1
			counts_off := SLOT_LENGTH * 2 * BTREE_SLOT_COUNT
			for k in 0 ..< i {
				rank += i64(endian.unchecked_get_u64be(branch_slice[counts_off + k * 8 : counts_off + (k + 1) * 8]))
			}
			child_slot := slot_from_slice(branch_slice[i * SLOT_LENGTH : (i + 1) * SLOT_LENGTH]) or_return
			node_ptr = child_slot.value
			continue
		}

		header_bytes: [BTREE_NODE_HEADER_SIZE]u8 = ---
		core_read_exact_at(db.core, node_ptr, header_bytes[:]) or_return
		kind_int := header_bytes[0]
		if kind_int > u8(BTree_Node_Kind.Branch) {
			return 0, .Invalid_BTree_Node_Kind
		}
		num := int(header_bytes[1])
		if num > BTREE_SLOT_COUNT {
			return 0, .Invalid_BTree_Node
		}
		if BTree_Node_Kind(kind_int) == .Leaf {
			entries_buf: [SLOT_LENGTH * BTREE_SLOT_COUNT]u8 = ---
			if num > 0 {
				core_read_exact_at(db.core, node_ptr + BTREE_NODE_HEADER_SIZE, entries_buf[:num * SLOT_LENGTH]) or_return
			}
			lo := 0
			hi := num
			for lo < hi {
				mid := int(uint(lo + hi) >> 1)
				entry_slot := slot_from_slice(entries_buf[mid * SLOT_LENGTH : (mid + 1) * SLOT_LENGTH]) or_return
				key_slot := sorted_entry_key_slot(db, entry_slot) or_return
				cmp := compare_key(db, key_slot, key) or_return
				if cmp == 0 {
					return rank + i64(mid), nil
				} else if cmp < 0 {
					lo = mid + 1
				} else {
					hi = mid
				}
			}
			return rank + i64(lo), nil
		}
		branch_buf: [(SLOT_LENGTH * 2 + 8) * BTREE_SLOT_COUNT]u8 = ---
		core_read_exact_at(db.core, node_ptr + BTREE_NODE_HEADER_SIZE, branch_buf[:SLOT_LENGTH * 2 * BTREE_SLOT_COUNT + num * 8]) or_return
		lo := 1
		hi := num
		sep_off := SLOT_LENGTH * BTREE_SLOT_COUNT
		for lo < hi {
			mid := int(uint(lo + hi) >> 1)
			sep_slot := slot_from_slice(branch_buf[sep_off + mid * SLOT_LENGTH : sep_off + (mid + 1) * SLOT_LENGTH]) or_return
			c := compare_key(db, sep_slot, key) or_return
			if c <= 0 {
				lo = mid + 1
			} else {
				hi = mid
			}
		}
		i := lo - 1
		counts_off := SLOT_LENGTH * 2 * BTREE_SLOT_COUNT
		for k in 0 ..< i {
			rank += i64(endian.unchecked_get_u64be(branch_buf[counts_off + k * 8 : counts_off + (k + 1) * 8]))
		}
		child_slot := slot_from_slice(branch_buf[i * SLOT_LENGTH : (i + 1) * SLOT_LENGTH]) or_return
		node_ptr = child_slot.value
	}
}

write_key :: proc(db: ^Database, key: []u8) -> (res: Slot, err: Error) {
	if len(key) <= 8 {
		has_zero := false
		for b in key {
			if b == 0 {
				has_zero = true
				break
			}
		}
		if !has_zero {
			value: [8]u8
			copy(value[:], key)
			return Slot{value = i64(endian.unchecked_get_u64be(value[:])), tag = .Short_Bytes}, nil
		}
	}
	pos := core_length(db.core) or_return
	core_seek_to(db.core, pos) or_return
	if len(key) <= 248 {
		buf: [256]u8 = ---
		endian.unchecked_put_u64be(buf[0:8], u64(len(key)))
		copy(buf[8:8 + len(key)], key)
		core_write_all(db.core, buf[:8 + len(key)]) or_return
		return Slot{value = pos, tag = .Bytes}, nil
	}
	core_write_i64(db.core, i64(len(key))) or_return
	core_write_all(db.core, key) or_return
	return Slot{value = pos, tag = .Bytes}, nil
}

write_sorted_pair :: proc(db: ^Database, key_slot: Slot) -> (res: Slot, err: Error) {
	return write_kv_pair(db, .Sorted_KV_Pair, Key_Value_Pair{
		value_slot = Slot{},
		key_slot   = key_slot,
		hash       = nil,
	})
}

write_sorted_key_and_entry :: proc(db: ^Database, key: []u8, key_only: bool) -> (key_slot: Slot, entry: Slot, err: Error) {
	if len(key) <= 8 {
		has_zero := false
		for b in key {
			if b == 0 {
				has_zero = true
				break
			}
		}
		if !has_zero {
			value: [8]u8
			copy(value[:], key)
			key_slot = Slot{value = i64(endian.unchecked_get_u64be(value[:])), tag = .Short_Bytes}
			if key_only {
				return key_slot, key_slot, nil
			}
			entry = write_sorted_pair(db, key_slot) or_return
			return key_slot, entry, nil
		}
	}
	pos := core_length(db.core) or_return
	core_seek_to(db.core, pos) or_return
	key_slot = Slot{value = pos, tag = .Bytes}
	if key_only {
		if len(key) <= 248 {
			buf: [256]u8 = ---
			endian.unchecked_put_u64be(buf[0:8], u64(len(key)))
			copy(buf[8:8 + len(key)], key)
			core_write_all(db.core, buf[:8 + len(key)]) or_return
			return key_slot, key_slot, nil
		}
		core_write_i64(db.core, i64(len(key))) or_return
		core_write_all(db.core, key) or_return
		return key_slot, key_slot, nil
	}
	pair_pos := pos + 8 + i64(len(key))
	entry = Slot{value = pair_pos, tag = .Sorted_KV_Pair}
	if len(key) <= 230 {
		buf: [256]u8 = ---
		endian.unchecked_put_u64be(buf[0:8], u64(len(key)))
		copy(buf[8 : 8 + len(key)], key)
		ks_bytes := slot_to_bytes(key_slot)
		vs_bytes := slot_to_bytes(Slot{})
		pair_off := 8 + len(key)
		copy(buf[pair_off : pair_off + SLOT_LENGTH], ks_bytes[:])
		copy(buf[pair_off + SLOT_LENGTH : pair_off + SORTED_KV_PAIR_LENGTH], vs_bytes[:])
		core_write_all(db.core, buf[:pair_off + SORTED_KV_PAIR_LENGTH]) or_return
		return key_slot, entry, nil
	}
	core_write_i64(db.core, i64(len(key))) or_return
	core_write_all(db.core, key) or_return
	entry = write_sorted_pair(db, key_slot) or_return
	return key_slot, entry, nil
}

sorted_put :: proc(db: ^Database, node_ptr: i64, key: []u8, key_only: bool, frozen_at: i64) -> (res: Sorted_Insert_Result, err: Error) {
	reusable := btree_reusable(db, node_ptr, frozen_at)
	if reusable {
		header_bytes: [BTREE_NODE_HEADER_SIZE]u8
		core_read_exact_at(db.core, node_ptr, header_bytes[:]) or_return
		kind_int := header_bytes[0]
		if kind_int > u8(BTree_Node_Kind.Branch) {
			return {}, .Invalid_BTree_Node_Kind
		}
		num := int(header_bytes[1])
		if num > BTREE_SLOT_COUNT {
			return {}, .Invalid_BTree_Node
		}
		position := node_ptr + BTREE_NODE_HEADER_SIZE
		if BTree_Node_Kind(kind_int) == .Leaf {
			entries_buf: [SLOT_LENGTH * BTREE_SLOT_COUNT]u8 = ---
			if num > 0 {
				core_read_exact_at(db.core, position, entries_buf[:num * SLOT_LENGTH]) or_return
			}
			lo := 0
			hi := num
			matched_slot: Slot
			found := false
			for lo < hi {
				mid := int(uint(lo + hi) >> 1)
				entry_slot := slot_from_slice(entries_buf[mid * SLOT_LENGTH : (mid + 1) * SLOT_LENGTH]) or_return
				key_slot := sorted_entry_key_slot(db, entry_slot) or_return
				cmp := compare_key(db, key_slot, key) or_return
				if cmp == 0 {
					lo = mid
					matched_slot = entry_slot
					found = true
					break
				} else if cmp < 0 {
					lo = mid + 1
				} else {
					hi = mid
				}
			}
			if found {
				if key_only {
					return Sorted_Insert_Result{
						node_ptr = node_ptr,
						count    = i64(num),
						entry    = matched_slot,
						added    = false,
					}, nil
				}
				entry := matched_slot
				rewritten := false
				if is_key_only_entry(entry) {
					entry = write_sorted_pair(db, entry) or_return
					rewritten = true
				} else if !btree_reusable(db, entry.value, frozen_at) {
					kv := read_kv_pair(db, entry) or_return
					entry = write_kv_pair(db, entry.tag, kv) or_return
					rewritten = true
				}
				if rewritten {
					entry_pos := position + i64(lo) * SLOT_LENGTH
					core_seek_to(db.core, entry_pos) or_return
					core_write_slot(db.core, entry) or_return
				}
				return Sorted_Insert_Result{
					node_ptr = node_ptr,
					count    = i64(num),
					entry    = entry,
					added    = false,
				}, nil
			}
			idx := lo
			key_slot, entry := write_sorted_key_and_entry(db, key, key_only) or_return
			if num < BTREE_SLOT_COUNT {
				total := num + 1
				entry_pos := position + i64(idx) * SLOT_LENGTH
				eb := slot_to_bytes(entry)
				if idx < num {
					tail_len := (num - idx) * SLOT_LENGTH
					shift_buf: [SLOT_LENGTH * BTREE_SLOT_COUNT]u8 = ---
					copy(shift_buf[:SLOT_LENGTH], eb[:])
					copy(shift_buf[SLOT_LENGTH : SLOT_LENGTH + tail_len], entries_buf[idx * SLOT_LENGTH : num * SLOT_LENGTH])
					core_seek_to(db.core, entry_pos) or_return
					core_write_all(db.core, shift_buf[:SLOT_LENGTH + tail_len]) or_return
				} else {
					core_seek_to(db.core, entry_pos) or_return
					core_write_all(db.core, eb[:]) or_return
				}
				new_hdr := [BTREE_NODE_HEADER_SIZE]u8{header_bytes[0], u8(total)}
				core_seek_to(db.core, node_ptr) or_return
				core_write_all(db.core, new_hdr[:]) or_return
				return Sorted_Insert_Result{
					node_ptr = node_ptr,
					count    = i64(total),
					entry    = entry,
					added    = true,
				}, nil
			}
			entries: [BTREE_SLOT_COUNT + 1]Slot = ---
			for j in 0 ..< idx {
				entries[j] = slot_from_slice(entries_buf[j * SLOT_LENGTH : (j + 1) * SLOT_LENGTH]) or_return
			}
			entries[idx] = entry
			for j in idx ..< num {
				entries[j + 1] = slot_from_slice(entries_buf[j * SLOT_LENGTH : (j + 1) * SLOT_LENGTH]) or_return
			}
			total := num + 1
			left_n := BTREE_SPLIT_COUNT
			right_n := total - left_n
			left := Sorted_Node{kind = .Leaf, num = left_n}
			copy(left.entries[:left_n], entries[:left_n])
			right := Sorted_Node{kind = .Leaf, num = right_n}
			copy(right.entries[:right_n], entries[left_n:total])
			separator: Slot
			if left_n == idx {
				separator = key_slot
			} else {
				separator = sorted_entry_key_slot(db, entries[left_n]) or_return
			}
			left_ptr := sorted_write_node(db, left, node_ptr, frozen_at) or_return
			right_ptr := write_sorted_node(db, right) or_return
			return Sorted_Insert_Result{
				node_ptr = left_ptr,
				count    = i64(left_n),
				entry    = entry,
				added    = true,
				split    = Sorted_Split{node_ptr = right_ptr, count = i64(right_n), separator = separator},
			}, nil
		} else {
			branch_buf: [(SLOT_LENGTH * 2 + 8) * BTREE_SLOT_COUNT]u8 = ---
			core_read_exact_at(db.core, position, branch_buf[:SLOT_LENGTH * 2 * BTREE_SLOT_COUNT + num * 8]) or_return
			lo := 1
			hi := num
			sep_off := SLOT_LENGTH * BTREE_SLOT_COUNT
			for lo < hi {
				mid := int(uint(lo + hi) >> 1)
				sep_slot := slot_from_slice(branch_buf[sep_off + mid * SLOT_LENGTH : sep_off + (mid + 1) * SLOT_LENGTH]) or_return
				c := compare_key(db, sep_slot, key) or_return
				if c <= 0 {
					lo = mid + 1
				} else {
					hi = mid
				}
			}
			i := lo - 1
			child_slot_pos := position + i64(i) * SLOT_LENGTH
			child_slot := slot_from_slice(branch_buf[i * SLOT_LENGTH : (i + 1) * SLOT_LENGTH]) or_return
			child_ptr := child_slot.value
			child := sorted_put(db, child_ptr, key, key_only, frozen_at) or_return
			if child.split == nil {
				if child.node_ptr != child_ptr {
					core_seek_to(db.core, child_slot_pos) or_return
					core_write_slot(db.core, Slot{value = child.node_ptr, tag = .Index}) or_return
				}
				new_cnt: i64 = 0
				if child.added {
					counts_off := SLOT_LENGTH * 2 * BTREE_SLOT_COUNT + i * 8
					old_cnt := i64(endian.unchecked_get_u64be(branch_buf[counts_off : counts_off + 8]))
					new_cnt = old_cnt + 1
					count_pos := position + i64(counts_off)
					core_seek_to(db.core, count_pos) or_return
					core_write_i64(db.core, new_cnt) or_return
				}
				return Sorted_Insert_Result{
					node_ptr = node_ptr,
					count    = new_cnt,
					entry    = child.entry,
					added    = child.added,
				}, nil
			}
			// Child split: decode full branch node from branch_buf and finish split handling
			children: [BTREE_SLOT_COUNT + 1]Slot = ---
			separators: [BTREE_SLOT_COUNT + 1]Slot = ---
			counts: [BTREE_SLOT_COUNT + 1]i64 = ---
			counts_base := SLOT_LENGTH * 2 * BTREE_SLOT_COUNT
			for k in 0 ..< num {
				children[k] = slot_from_slice(branch_buf[k * SLOT_LENGTH : (k + 1) * SLOT_LENGTH]) or_return
				separators[k] = slot_from_slice(branch_buf[sep_off + k * SLOT_LENGTH : sep_off + (k + 1) * SLOT_LENGTH]) or_return
				counts[k] = i64(endian.unchecked_get_u64be(branch_buf[counts_base + k * 8 : counts_base + (k + 1) * 8]))
			}
			children[i] = Slot{value = child.node_ptr, tag = .Index}
			counts[i] = child.count
			split := child.split.?
			for j := num; j > i + 1; j -= 1 {
				children[j] = children[j - 1]
				separators[j] = separators[j - 1]
				counts[j] = counts[j - 1]
			}
			children[i + 1] = Slot{value = split.node_ptr, tag = .Index}
			separators[i + 1] = split.separator
			counts[i + 1] = split.count
			total := num + 1

			if total <= BTREE_SLOT_COUNT {
				branch := Sorted_Node{kind = .Branch, num = total}
				copy(branch.children[:total], children[:total])
				copy(branch.separators[:total], separators[:total])
				copy(branch.counts[:total], counts[:total])
				ptr := sorted_write_node(db, branch, node_ptr, frozen_at) or_return
				return Sorted_Insert_Result{
					node_ptr = ptr,
					count    = sorted_node_subtree_count(branch),
					entry    = child.entry,
					added    = child.added,
				}, nil
			}

			left_n := BTREE_SPLIT_COUNT
			right_n := total - left_n
			left := Sorted_Node{kind = .Branch, num = left_n}
			copy(left.children[:left_n], children[:left_n])
			copy(left.separators[:left_n], separators[:left_n])
			copy(left.counts[:left_n], counts[:left_n])
			right := Sorted_Node{kind = .Branch, num = right_n}
			copy(right.children[:right_n], children[left_n:total])
			copy(right.separators[:right_n], separators[left_n:total])
			copy(right.counts[:right_n], counts[left_n:total])
			separator := separators[left_n]
			left_ptr := sorted_write_node(db, left, node_ptr, frozen_at) or_return
			right_ptr := write_sorted_node(db, right) or_return
			return Sorted_Insert_Result{
				node_ptr = left_ptr,
				count    = sorted_node_subtree_count(left),
				entry    = child.entry,
				added    = child.added,
				split    = Sorted_Split{node_ptr = right_ptr, count = sorted_node_subtree_count(right), separator = separator},
			}, nil
		}
	}

	node := read_sorted_node(db, node_ptr) or_return
	switch node.kind {
	case .Leaf:
		idx, found := sorted_leaf_search(db, &node, key) or_return

		if found {
			if key_only {
				return Sorted_Insert_Result{
					node_ptr = node_ptr,
					count    = i64(node.num),
					entry    = node.entries[idx],
					added    = false,
				}, nil
			}
			entry := node.entries[idx]
			if is_key_only_entry(entry) {
				entry = write_sorted_pair(db, entry) or_return
			} else if !btree_reusable(db, entry.value, frozen_at) {
				kv := read_kv_pair(db, entry) or_return
				entry = write_kv_pair(db, entry.tag, kv) or_return
			}
			leaf := node
			leaf.entries[idx] = entry
			ptr := sorted_write_node(db, leaf, node_ptr, frozen_at) or_return
			return Sorted_Insert_Result{
				node_ptr = ptr,
				count    = i64(node.num),
				entry    = entry,
				added    = false,
			}, nil
		}

		key_slot, entry := write_sorted_key_and_entry(db, key, key_only) or_return
		entries: [BTREE_SLOT_COUNT + 1]Slot
		copy(entries[:idx], node.entries[:idx])
		entries[idx] = entry
		copy(entries[idx + 1 : node.num + 1], node.entries[idx:node.num])
		total := node.num + 1

		if total <= BTREE_SLOT_COUNT {
			leaf := Sorted_Node{kind = .Leaf, num = total}
			copy(leaf.entries[:total], entries[:total])
			ptr := sorted_write_node(db, leaf, node_ptr, frozen_at) or_return
			return Sorted_Insert_Result{
				node_ptr = ptr,
				count    = i64(total),
				entry    = entry,
				added    = true,
			}, nil
		}

		left_n := BTREE_SPLIT_COUNT
		right_n := total - left_n
		left := Sorted_Node{kind = .Leaf, num = left_n}
		copy(left.entries[:left_n], entries[:left_n])
		right := Sorted_Node{kind = .Leaf, num = right_n}
		copy(right.entries[:right_n], entries[left_n:total])
		separator: Slot
		if left_n == idx {
			separator = key_slot
		} else {
			separator = sorted_entry_key_slot(db, entries[left_n]) or_return
		}
		left_ptr := sorted_write_node(db, left, node_ptr, frozen_at) or_return
		right_ptr := write_sorted_node(db, right) or_return
		return Sorted_Insert_Result{
			node_ptr = left_ptr,
			count    = i64(left_n),
			entry    = entry,
			added    = true,
			split    = Sorted_Split{node_ptr = right_ptr, count = i64(right_n), separator = separator},
		}, nil

	case .Branch:
		i := sorted_branch_search(db, &node, key) or_return
		child_ptr := node.children[i].value
		child := sorted_put(db, child_ptr, key, key_only, frozen_at) or_return
		if !child.added && child.node_ptr == child_ptr {
			return Sorted_Insert_Result{
				node_ptr = node_ptr,
				count    = sorted_node_subtree_count(node),
				entry    = child.entry,
				added    = false,
			}, nil
		}

		children: [BTREE_SLOT_COUNT + 1]Slot
		separators: [BTREE_SLOT_COUNT + 1]Slot
		counts: [BTREE_SLOT_COUNT + 1]i64
		copy(children[:node.num], node.children[:node.num])
		copy(separators[:node.num], node.separators[:node.num])
		copy(counts[:node.num], node.counts[:node.num])
		children[i] = Slot{value = child.node_ptr, tag = .Index}
		counts[i] = child.count if child.split != nil else (node.counts[i] + (1 if child.added else 0))
		total := node.num
		if split, ok := child.split.?; ok {
			for j := node.num; j > i + 1; j -= 1 {
				children[j] = children[j - 1]
				separators[j] = separators[j - 1]
				counts[j] = counts[j - 1]
			}
			children[i + 1] = Slot{value = split.node_ptr, tag = .Index}
			separators[i + 1] = split.separator
			counts[i + 1] = split.count
			total = node.num + 1
		}

		if total <= BTREE_SLOT_COUNT {
			branch := Sorted_Node{kind = .Branch, num = total}
			copy(branch.children[:total], children[:total])
			copy(branch.separators[:total], separators[:total])
			copy(branch.counts[:total], counts[:total])
			ptr := sorted_write_node(db, branch, node_ptr, frozen_at) or_return
			return Sorted_Insert_Result{
				node_ptr = ptr,
				count    = sorted_node_subtree_count(branch),
				entry    = child.entry,
				added    = child.added,
			}, nil
		}

		left_n := BTREE_SPLIT_COUNT
		right_n := total - left_n
		left := Sorted_Node{kind = .Branch, num = left_n}
		copy(left.children[:left_n], children[:left_n])
		copy(left.separators[:left_n], separators[:left_n])
		copy(left.counts[:left_n], counts[:left_n])
		right := Sorted_Node{kind = .Branch, num = right_n}
		copy(right.children[:right_n], children[left_n:total])
		copy(right.separators[:right_n], separators[left_n:total])
		copy(right.counts[:right_n], counts[left_n:total])
		separator := separators[left_n]
		left_ptr := sorted_write_node(db, left, node_ptr, frozen_at) or_return
		right_ptr := write_sorted_node(db, right) or_return
		return Sorted_Insert_Result{
			node_ptr = left_ptr,
			count    = sorted_node_subtree_count(left),
			entry    = child.entry,
			added    = child.added,
			split    = Sorted_Split{node_ptr = right_ptr, count = sorted_node_subtree_count(right), separator = separator},
		}, nil
	}
	return {}, .Unreachable
}

sorted_remove :: proc(db: ^Database, node_ptr: i64, key: []u8, frozen_at: i64) -> (res: Sorted_Remove_Result, err: Error) {
	if btree_reusable(db, node_ptr, frozen_at) {
		header_bytes: [BTREE_NODE_HEADER_SIZE]u8
		core_read_exact_at(db.core, node_ptr, header_bytes[:]) or_return
		kind_int := header_bytes[0]
		if kind_int > u8(BTree_Node_Kind.Branch) {
			return {}, .Invalid_BTree_Node_Kind
		}
		num := int(header_bytes[1])
		if num > BTREE_SLOT_COUNT {
			return {}, .Invalid_BTree_Node
		}
		position := node_ptr + BTREE_NODE_HEADER_SIZE
		if BTree_Node_Kind(kind_int) == .Leaf {
			entries_buf: [SLOT_LENGTH * BTREE_SLOT_COUNT]u8
			if num > 0 {
				core_read_exact_at(db.core, position, entries_buf[:num * SLOT_LENGTH]) or_return
			}
			lo := 0
			hi := num
			found := false
			for lo < hi {
				mid := int(uint(lo + hi) >> 1)
				entry_slot := slot_from_slice(entries_buf[mid * SLOT_LENGTH : (mid + 1) * SLOT_LENGTH]) or_return
				key_slot := sorted_entry_key_slot(db, entry_slot) or_return
				cmp := compare_key(db, key_slot, key) or_return
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
			if !found {
				return Sorted_Remove_Result{node_ptr = node_ptr, found = false}, nil
			}
			idx := lo
			total := num - 1
			entry_pos := position + i64(idx) * SLOT_LENGTH
			tail_len := (total - idx) * SLOT_LENGTH
			shift_buf: [SLOT_LENGTH * BTREE_SLOT_COUNT]u8
			if tail_len > 0 {
				copy(shift_buf[:tail_len], entries_buf[(idx + 1) * SLOT_LENGTH : num * SLOT_LENGTH])
			}
			core_seek_to(db.core, entry_pos) or_return
			core_write_all(db.core, shift_buf[:tail_len + SLOT_LENGTH]) or_return
			new_hdr := [BTREE_NODE_HEADER_SIZE]u8{header_bytes[0], u8(total)}
			core_seek_to(db.core, node_ptr) or_return
			core_write_all(db.core, new_hdr[:]) or_return
			return Sorted_Remove_Result{node_ptr = node_ptr, found = true}, nil
		} else {
			branch_buf: [SLOT_LENGTH * 2 * BTREE_SLOT_COUNT]u8
			core_read_exact_at(db.core, position, branch_buf[:(BTREE_SLOT_COUNT + num) * SLOT_LENGTH]) or_return
			lo := 1
			hi := num
			sep_off := SLOT_LENGTH * BTREE_SLOT_COUNT
			for lo < hi {
				mid := int(uint(lo + hi) >> 1)
				sep_slot := slot_from_slice(branch_buf[sep_off + mid * SLOT_LENGTH : sep_off + (mid + 1) * SLOT_LENGTH]) or_return
				c := compare_key(db, sep_slot, key) or_return
				if c <= 0 {
					lo = mid + 1
				} else {
					hi = mid
				}
			}
			i := lo - 1
			child_slot_pos := position + i64(i) * SLOT_LENGTH
			child_slot := slot_from_slice(branch_buf[i * SLOT_LENGTH : (i + 1) * SLOT_LENGTH]) or_return
			child_ptr := child_slot.value
			child := sorted_remove(db, child_ptr, key, frozen_at) or_return
			if !child.found {
				return Sorted_Remove_Result{node_ptr = node_ptr, found = false}, nil
			}
			count_pos := position + SLOT_LENGTH * 2 * BTREE_SLOT_COUNT + i64(i) * 8
			old_cnt := core_read_i64_at(db.core, count_pos) or_return
			if !(old_cnt == 1 && num > 1) {
				if child.node_ptr != child_ptr {
					core_seek_to(db.core, child_slot_pos) or_return
					core_write_slot(db.core, Slot{value = child.node_ptr, tag = .Index}) or_return
				}
				core_seek_to(db.core, count_pos) or_return
				core_write_i64(db.core, old_cnt - 1) or_return
				return Sorted_Remove_Result{node_ptr = node_ptr, found = true}, nil
			}
			branch := read_sorted_node(db, node_ptr) or_return
			copy(branch.children[i : branch.num - 1], branch.children[i + 1 : branch.num])
			copy(branch.separators[i : branch.num - 1], branch.separators[i + 1 : branch.num])
			copy(branch.counts[i : branch.num - 1], branch.counts[i + 1 : branch.num])
			branch.num -= 1
			branch.children[branch.num] = Slot{}
			branch.separators[branch.num] = Slot{}
			branch.counts[branch.num] = 0
			branch.separators[0] = Slot{}
			ptr := sorted_write_node(db, branch, node_ptr, frozen_at) or_return
			return Sorted_Remove_Result{node_ptr = ptr, found = true}, nil
		}
	}

	node := read_sorted_node(db, node_ptr) or_return
	switch node.kind {
	case .Leaf:
		idx, found := sorted_leaf_search(db, &node, key) or_return
		if !found {
			return Sorted_Remove_Result{node_ptr = node_ptr, found = false}, nil
		}
		leaf := Sorted_Node{kind = .Leaf, num = node.num - 1}
		copy(leaf.entries[:idx], node.entries[:idx])
		copy(leaf.entries[idx : node.num - 1], node.entries[idx + 1 : node.num])
		ptr := sorted_write_node(db, leaf, node_ptr, frozen_at) or_return
		return Sorted_Remove_Result{node_ptr = ptr, found = true}, nil

	case .Branch:
		i := sorted_branch_search(db, &node, key) or_return
		child_ptr := node.children[i].value
		child := sorted_remove(db, child_ptr, key, frozen_at) or_return
		if !child.found {
			return Sorted_Remove_Result{node_ptr = node_ptr, found = false}, nil
		}
		branch := node
		if branch.counts[i] == 1 && branch.num > 1 {
			copy(branch.children[i : branch.num - 1], branch.children[i + 1 : branch.num])
			copy(branch.separators[i : branch.num - 1], branch.separators[i + 1 : branch.num])
			copy(branch.counts[i : branch.num - 1], branch.counts[i + 1 : branch.num])
			branch.num -= 1
			branch.children[branch.num] = Slot{}
			branch.separators[branch.num] = Slot{}
			branch.counts[branch.num] = 0
			branch.separators[0] = Slot{}
		} else {
			branch.children[i] = Slot{value = child.node_ptr, tag = .Index}
			branch.counts[i] -= 1
		}
		ptr := sorted_write_node(db, branch, node_ptr, frozen_at) or_return
		return Sorted_Remove_Result{node_ptr = ptr, found = true}, nil
	}
	return {}, .Unreachable
}

sorted_grow_root :: proc(db: ^Database, result: Sorted_Insert_Result) -> (res: i64, err: Error) {
	if split, ok := result.split.?; ok {
		root := Sorted_Node{kind = .Branch, num = 2}
		root.children[0] = Slot{value = result.node_ptr, tag = .Index}
		root.children[1] = Slot{value = split.node_ptr, tag = .Index}
		root.separators[1] = split.separator
		root.counts[0] = result.count
		root.counts[1] = split.count
		return write_sorted_node(db, root)
	}
	return result.node_ptr, nil
}

sorted_target_slot :: proc(db: ^Database, entry: Slot, target: Sorted_Map_Get_Target) -> (res: Slot_Pointer, err: Error) {
	switch _ in target {
	case Sorted_Map_Get_KV_Pair:
		return Slot_Pointer{position = nil, slot = entry}, nil
	case Sorted_Map_Get_Key:
		key_slot := sorted_entry_key_slot(db, entry) or_return
		return Slot_Pointer{position = nil, slot = key_slot}, nil
	case Sorted_Map_Get_Value:
		if is_key_only_entry(entry) {
			return Slot_Pointer{position = nil, slot = Slot{}}, nil
		}
		pos := entry.value + database_kv_key_offset(db, entry.tag) + SLOT_LENGTH
		val_slot := core_read_slot_at(db.core, pos) or_return
		return Slot_Pointer{position = pos, slot = val_slot}, nil
	}
	return {}, .Unexpected_Tag
}
