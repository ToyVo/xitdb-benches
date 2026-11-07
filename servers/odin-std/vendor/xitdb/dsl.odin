package xitdb

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:reflect"
import "core:strconv"
import "core:strings"

// ============================================================================
// Layer 1: Path IR (`Path_Step`) & String Selector Parser
// ============================================================================

Step_Kind :: enum u8 {
	Hash_Map_Key,         // .key or .["key"]
	Counted_Hash_Map_Key, // #key or #["key"]
	Sorted_Map_Key,       // $key or $["key"]
	Array_List_Idx,       // [i]
	Linked_List_Idx,      // [[i]]
	Hash_Set_Member,      // %member or %["member"]
	Counted_Set_Member,   // #%member or #%["member"]
	Sorted_Set_Member,    // ^member or ^["member"]
}

Path_Step :: struct {
	kind:  Step_Kind,
	key:   string,
	index: i64,
}

Parsed_Selector :: struct {
	has_moment:   bool,
	moment_index: i64,
	steps:        []Path_Step,
}

// Embedded Odin Path Step Combinators
hm :: proc(key: string) -> Path_Step {
	return Path_Step{kind = .Hash_Map_Key, key = key}
}

chm :: proc(key: string) -> Path_Step {
	return Path_Step{kind = .Counted_Hash_Map_Key, key = key}
}

sm :: proc(key: string) -> Path_Step {
	return Path_Step{kind = .Sorted_Map_Key, key = key}
}

al :: proc(index: i64) -> Path_Step {
	return Path_Step{kind = .Array_List_Idx, index = index}
}

ll :: proc(index: i64) -> Path_Step {
	return Path_Step{kind = .Linked_List_Idx, index = index}
}

hs :: proc(member: string) -> Path_Step {
	return Path_Step{kind = .Hash_Set_Member, key = member}
}

chs :: proc(member: string) -> Path_Step {
	return Path_Step{kind = .Counted_Set_Member, key = member}
}

ss :: proc(member: string) -> Path_Step {
	return Path_Step{kind = .Sorted_Set_Member, key = member}
}

// Format a `[]Path_Step` slice back into canonical selector syntax.
format_steps :: proc(steps: []Path_Step, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for step in steps {
		switch step.kind {
		case .Hash_Map_Key:
			strings.write_byte(&b, '.')
			_write_escaped_step_key(&b, step.key)
		case .Counted_Hash_Map_Key:
			strings.write_byte(&b, '#')
			_write_escaped_step_key(&b, step.key)
		case .Sorted_Map_Key:
			strings.write_byte(&b, '$')
			_write_escaped_step_key(&b, step.key)
		case .Array_List_Idx:
			fmt.sbprintf(&b, "[%d]", step.index)
		case .Linked_List_Idx:
			fmt.sbprintf(&b, "[[%d]]", step.index)
		case .Hash_Set_Member:
			strings.write_byte(&b, '%')
			_write_escaped_step_key(&b, step.key)
		case .Counted_Set_Member:
			strings.write_string(&b, "#%")
			_write_escaped_step_key(&b, step.key)
		case .Sorted_Set_Member:
			strings.write_byte(&b, '^')
			_write_escaped_step_key(&b, step.key)
		}
	}
	return strings.to_string(b)
}

@(private = "file")
_write_escaped_step_key :: proc(b: ^strings.Builder, key: string) {
	needs_quotes := len(key) == 0
	for i in 0 ..< len(key) {
		ch := key[i]
		if ch == '.' || ch == '[' || ch == ']' || ch == '$' || ch == '#' || ch == '%' || ch == '^' || ch == ' ' || ch == '"' {
			needs_quotes = true
			break
		}
	}
	if needs_quotes {
		strings.write_string(b, "[\"")
		strings.write_string(b, key)
		strings.write_string(b, "\"]")
	} else {
		strings.write_string(b, key)
	}
}

// Parse a selector string like "@-1.users[\"101\"].age", "$catalog[\"apple\"]", or ".todos[[0]]".
parse_selector :: proc(selector: string, allocator := context.temp_allocator) -> (res: Parsed_Selector, err: Error) {
	s := strings.trim_space(selector)
	if len(s) == 0 {
		return {}, nil
	}

	i := 0
	if s[i] == '@' {
		i += 1
		start := i
		if i < len(s) && s[i] == '-' {
			i += 1
		}
		for i < len(s) && s[i] >= '0' && s[i] <= '9' {
			i += 1
		}
		if i == start || (i == start + 1 && s[start] == '-') {
			return {}, .Invalid_Range
		}
		m_idx, ok := strconv.parse_i64(s[start:i])
		if !ok {
			return {}, .Invalid_Range
		}
		res.has_moment = true
		res.moment_index = m_idx
	}

	steps := parse_steps(s[i:], allocator) or_return
	res.steps = steps
	return res, nil
}

parse_steps :: proc(path_str: string, allocator := context.temp_allocator) -> (res: []Path_Step, err: Error) {
	s := strings.trim_space(path_str)
	steps := make([dynamic]Path_Step, 0, 8, allocator)
	i := 0

	for i < len(s) {
		ch := s[i]
		switch ch {
		case '.':
			i += 1
			key, next_i := _parse_step_ident_or_bracket(s, i) or_return
			append(&steps, Path_Step{kind = .Hash_Map_Key, key = key})
			i = next_i

		case '#':
			i += 1
			if i < len(s) && s[i] == '%' {
				i += 1
				key, next_i := _parse_step_ident_or_bracket(s, i) or_return
				append(&steps, Path_Step{kind = .Counted_Set_Member, key = key})
				i = next_i
			} else {
				key, next_i := _parse_step_ident_or_bracket(s, i) or_return
				append(&steps, Path_Step{kind = .Counted_Hash_Map_Key, key = key})
				i = next_i
			}

		case '$':
			i += 1
			key, next_i := _parse_step_ident_or_bracket(s, i) or_return
			append(&steps, Path_Step{kind = .Sorted_Map_Key, key = key})
			i = next_i

		case '%':
			i += 1
			key, next_i := _parse_step_ident_or_bracket(s, i) or_return
			append(&steps, Path_Step{kind = .Hash_Set_Member, key = key})
			i = next_i

		case '^':
			i += 1
			key, next_i := _parse_step_ident_or_bracket(s, i) or_return
			append(&steps, Path_Step{kind = .Sorted_Set_Member, key = key})
			i = next_i

		case '[':
			if i + 1 < len(s) && s[i + 1] == '[' {
				// Linked_Array_List index: [[i]]
				i += 2
				start := i
				for i < len(s) && s[i] != ']' {
					i += 1
				}
				if i + 1 >= len(s) || s[i] != ']' || s[i + 1] != ']' {
					return nil, .Invalid_Range
				}
				idx_str := strings.trim_space(s[start:i])
				idx, ok := strconv.parse_i64(idx_str)
				if !ok {
					return nil, .Invalid_Range
				}
				append(&steps, Path_Step{kind = .Linked_List_Idx, index = idx})
				i += 2
			} else if i + 1 < len(s) && (s[i + 1] == '"' || s[i + 1] == '\'') {
				// Bracketed map key: ["key"] — inherits collection kind if preceded by $key or #key
				key, next_i := _parse_bracketed_string(s, i) or_return
				step_kind := Step_Kind.Hash_Map_Key
				if len(steps) == 1 {
					if steps[0].kind == .Counted_Hash_Map_Key {
						steps[0].kind = .Hash_Map_Key
						step_kind = .Counted_Hash_Map_Key
					} else if steps[0].kind == .Sorted_Map_Key {
						steps[0].kind = .Hash_Map_Key
						step_kind = .Sorted_Map_Key
					}
				}
				append(&steps, Path_Step{kind = step_kind, key = key})
				i = next_i
			} else {
				// Array_List index: [i]
				i += 1
				start := i
				for i < len(s) && s[i] != ']' {
					i += 1
				}
				if i >= len(s) || s[i] != ']' {
					return nil, .Invalid_Range
				}
				idx_str := strings.trim_space(s[start:i])
				idx, ok := strconv.parse_i64(idx_str)
				if !ok {
					return nil, .Invalid_Range
				}
				append(&steps, Path_Step{kind = .Array_List_Idx, index = idx})
				i += 1
			}

		case:
			// Bare leading identifier defaults to Hash_Map_Key
			key, next_i := _parse_step_ident_or_bracket(s, i) or_return
			append(&steps, Path_Step{kind = .Hash_Map_Key, key = key})
			i = next_i
		}
	}

	return steps[:], nil
}

@(private = "file")
_parse_step_ident_or_bracket :: proc(s: string, start_i: int) -> (key: string, next_i: int, err: Error) {
	if start_i >= len(s) {
		return "", start_i, .Invalid_Range
	}
	if s[start_i] == '[' {
		return _parse_bracketed_string(s, start_i)
	}
	if s[start_i] == '"' || s[start_i] == '\'' {
		quote := s[start_i]
		i := start_i + 1
		key_start := i
		for i < len(s) && s[i] != quote {
			i += 1
		}
		if i >= len(s) || s[i] != quote {
			return "", start_i, .Invalid_Range
		}
		return s[key_start:i], i + 1, nil
	}
	i := start_i
	for i < len(s) {
		ch := s[i]
		if ch == '.' || ch == '[' || ch == '#' || ch == '$' || ch == '%' || ch == '^' {
			break
		}
		i += 1
	}
	if i == start_i {
		return "", start_i, .Invalid_Range
	}
	return s[start_i:i], i, nil
}

@(private = "file")
_parse_bracketed_string :: proc(s: string, start_i: int) -> (key: string, next_i: int, err: Error) {
	if start_i + 2 >= len(s) || s[start_i] != '[' {
		return "", start_i, .Invalid_Range
	}
	quote := s[start_i + 1]
	if quote != '"' && quote != '\'' {
		return "", start_i, .Invalid_Range
	}
	i := start_i + 2
	key_start := i
	for i < len(s) && s[i] != quote {
		i += 1
	}
	if i + 1 >= len(s) || s[i] != quote || s[i + 1] != ']' {
		return "", start_i, .Invalid_Range
	}
	return s[key_start:i], i + 2, nil
}

// Resolve a `Read_Cursor` by walking `steps` from `start`.
read_steps_cursor :: proc(start: Read_Cursor, steps: []Path_Step) -> (res: Maybe(Read_Cursor), err: Error) {
	cur := start
	for step in steps {
		switch step.kind {
		case .Hash_Map_Key:
			m := read_hash_map_init(cur) or_return
			next_maybe := hash_map_get_cursor(m, step.key) or_return
			next_cur, ok := next_maybe.?
			if !ok {
				return nil, nil
			}
			cur = next_cur

		case .Counted_Hash_Map_Key:
			cm := read_counted_hash_map_init(cur) or_return
			next_maybe := hash_map_get_cursor(cm.read_hash_map, step.key) or_return
			next_cur, ok := next_maybe.?
			if !ok {
				return nil, nil
			}
			cur = next_cur

		case .Sorted_Map_Key:
			if slot_ptr := cursor_resolved(cur) or_return; slot_ptr.slot.tag == .Hash_Map || slot_ptr.slot.tag == .Counted_Hash_Map {
				m := read_hash_map_init(cur) or_return
				next_maybe := hash_map_get_cursor(m, step.key) or_return
				next_cur, ok := next_maybe.?
				if !ok {
					return nil, nil
				}
				cur = next_cur
			} else {
				sm_col := read_sorted_map_init(cur) or_return
				next_maybe := sorted_map_get_cursor(sm_col, step.key) or_return
				next_cur, ok := next_maybe.?
				if !ok {
					return nil, nil
				}
				cur = next_cur
			}

		case .Array_List_Idx:
			al_col := read_array_list_init(cur) or_return
			next_maybe := array_list_get_cursor(al_col, step.index) or_return
			next_cur, ok := next_maybe.?
			if !ok {
				return nil, nil
			}
			cur = next_cur

		case .Linked_List_Idx:
			ll_col := read_linked_array_list_init(cur) or_return
			next_maybe := linked_array_list_get_cursor(ll_col, step.index) or_return
			next_cur, ok := next_maybe.?
			if !ok {
				return nil, nil
			}
			cur = next_cur

		case .Hash_Set_Member:
			hs_col := read_hash_set_init(cur) or_return
			next_maybe := hash_set_get_cursor(hs_col, step.key) or_return
			next_cur, ok := next_maybe.?
			if !ok {
				return nil, nil
			}
			cur = next_cur

		case .Counted_Set_Member:
			cs_col := read_counted_hash_set_init(cur) or_return
			next_maybe := hash_set_get_cursor(cs_col.read_hash_set, step.key) or_return
			next_cur, ok := next_maybe.?
			if !ok {
				return nil, nil
			}
			cur = next_cur

		case .Sorted_Set_Member:
			ss_col := read_sorted_set_init(cur) or_return
			next_maybe := cursor_read_path(ss_col.cursor, []Path_Part{
				Sorted_Map_Get{target = Sorted_Map_Get_Key{key = transmute([]u8)step.key}},
			}) or_return
			next_cur, ok := next_maybe.?
			if !ok {
				return nil, nil
			}
			cur = next_cur
		}
	}
	return cur, nil
}

// Resolve a selector string (with optional `@moment` prefix) against `db`.
select_cursor :: proc(db: ^Database, selector: string) -> (res: Maybe(Read_Cursor), err: Error) {
	parsed := parse_selector(selector, context.temp_allocator) or_return
	rc := database_root_cursor(db).read_cursor
	start := rc
	if parsed.has_moment {
		history := read_array_list_init(rc) or_return
		mc_maybe := array_list_get_cursor(history, parsed.moment_index) or_return
		mc, ok := mc_maybe.?
		if !ok {
			return nil, nil
		}
		start = mc
	}
	return read_steps_cursor(start, parsed.steps)
}

get_string :: proc(db: ^Database, selector: string, allocator := context.temp_allocator) -> (res: string, err: Error) {
	cur_maybe := select_cursor(db, selector) or_return
	cur, ok := cur_maybe.?
	if !ok {
		return "", .Key_Not_Found
	}
	return cursor_read_string(cur, 0, allocator)
}

get_uint :: proc(db: ^Database, selector: string) -> (res: u64, err: Error) {
	cur_maybe := select_cursor(db, selector) or_return
	cur, ok := cur_maybe.?
	if !ok {
		return 0, .Key_Not_Found
	}
	return cursor_read_uint(cur)
}

get_int :: proc(db: ^Database, selector: string) -> (res: i64, err: Error) {
	cur_maybe := select_cursor(db, selector) or_return
	cur, ok := cur_maybe.?
	if !ok {
		return 0, .Key_Not_Found
	}
	return cursor_read_int(cur)
}

get_float :: proc(db: ^Database, selector: string) -> (res: f64, err: Error) {
	cur_maybe := select_cursor(db, selector) or_return
	cur, ok := cur_maybe.?
	if !ok {
		return 0, .Key_Not_Found
	}
	return cursor_read_float(cur)
}

// Auto-vivify intermediate collections along `steps` and return the target `Write_Cursor`.
write_steps_cursor :: proc(start: Write_Cursor, steps: []Path_Step) -> (res: Write_Cursor, err: Error) {
	cur := start
	cursor_reload_slot(&cur) or_return
	for step in steps {
		switch step.kind {
		case .Hash_Map_Key:
			m := write_hash_map_init(cur) or_return
			cur = hash_map_put_cursor(&m, step.key) or_return

		case .Counted_Hash_Map_Key:
			cm := write_counted_hash_map_init(cur) or_return
			cur = hash_map_put_cursor(&cm.write_hash_map, step.key) or_return

		case .Sorted_Map_Key:
			sm_col := write_sorted_map_init(cur) or_return
			cur = sorted_map_put_cursor(&sm_col, step.key) or_return

		case .Array_List_Idx:
			al_col := write_array_list_init(cur) or_return
			cnt := array_list_count(al_col.read_array_list) or_return
			if step.index == cnt {
				cur = array_list_append_cursor(&al_col) or_return
			} else {
				cur = array_list_put_cursor(&al_col, step.index) or_return
			}

		case .Linked_List_Idx:
			ll_col := write_linked_array_list_init(cur) or_return
			cnt := linked_array_list_count(ll_col.read_linked_array_list) or_return
			if step.index == cnt {
				cur = linked_array_list_append_cursor(&ll_col) or_return
			} else {
				cur = linked_array_list_put_cursor(&ll_col, step.index) or_return
			}

		case .Hash_Set_Member:
			hs_col := write_hash_set_init(cur) or_return
			hash_set_put(&hs_col, step.key) or_return
			cur = hash_set_put_cursor(&hs_col, step.key) or_return

		case .Counted_Set_Member:
			cs_col := write_counted_hash_set_init(cur) or_return
			hash_set_put(&cs_col.write_hash_set, step.key) or_return
			cur = hash_set_put_cursor(&cs_col.write_hash_set, step.key) or_return

		case .Sorted_Set_Member:
			ss_col := write_sorted_set_init(cur) or_return
			sorted_set_put(&ss_col, step.key) or_return
			cur = ss_col.write_cursor
		}
	}
	return cur, nil
}

// Put a value at `steps` starting from `root`, auto-vivifying intermediate collections.
put_at_steps :: proc(root: Write_Cursor, steps: []Path_Step, val: Writeable_Data) -> Error {
	if len(steps) == 0 {
		c := root
		return cursor_write(&c, val)
	}
	parent_cur := write_steps_cursor(root, steps[:len(steps) - 1]) or_return
	last := steps[len(steps) - 1]
	switch last.kind {
	case .Hash_Map_Key:
		m := write_hash_map_init(parent_cur) or_return
		return hash_map_put(&m, last.key, val)
	case .Counted_Hash_Map_Key:
		cm := write_counted_hash_map_init(parent_cur) or_return
		return hash_map_put(&cm.write_hash_map, last.key, val)
	case .Sorted_Map_Key:
		sm_col := write_sorted_map_init(parent_cur) or_return
		return sorted_map_put(&sm_col, last.key, val)
	case .Array_List_Idx:
		al_col := write_array_list_init(parent_cur) or_return
		cnt := array_list_count(al_col.read_array_list) or_return
		if last.index == cnt {
			return array_list_append(&al_col, val)
		}
		return array_list_put(&al_col, last.index, val)
	case .Linked_List_Idx:
		ll_col := write_linked_array_list_init(parent_cur) or_return
		cnt := linked_array_list_count(ll_col.read_linked_array_list) or_return
		if last.index == cnt {
			return linked_array_list_append(&ll_col, val)
		}
		return linked_array_list_put(&ll_col, last.index, val)
	case .Hash_Set_Member:
		hs_col := write_hash_set_init(parent_cur) or_return
		return hash_set_put(&hs_col, last.key)
	case .Counted_Set_Member:
		cs_col := write_counted_hash_set_init(parent_cur) or_return
		return hash_set_put(&cs_col.write_hash_set, last.key)
	case .Sorted_Set_Member:
		ss_col := write_sorted_set_init(parent_cur) or_return
		return sorted_set_put(&ss_col, last.key)
	}
	return .Unreachable
}

// ============================================================================
// Layer 2: Datomic-Style Transaction Engine (`Tx`, `Tx_Report`, Script DSL)
// ============================================================================

Tx_Op_Kind :: enum u8 {
	Put,
	Append,
	Insert,
	Remove,
	Slice,
	Fork,
	Savepoint,
	Callback,
}

Tx_Op :: struct {
	kind:       Tx_Op_Kind,
	steps:      []Path_Step,
	from_steps: []Path_Step,
	val:        Writeable_Data,
	offset:     i64,
	size:       i64,
	callback:   Context_Function,
	user_data:  rawptr,
}

Tx_Meta_Entry :: struct {
	key: string,
	val: Writeable_Data,
}

Secondary_Index_Rule :: struct {
	source_map_key: string,
	field_key:      string,
	index_map_key:  string,
}

Tx_Change :: struct {
	op:       Tx_Op_Kind,
	path_str: string,
	old_slot: Slot,
	new_slot: Slot,
}

Tx :: struct {
	db:            ^Database,
	base_moment:   Maybe(i64),
	doc:           string,
	instant:       Maybe(i64),
	track_changes: bool,
	meta:          [dynamic]Tx_Meta_Entry,
	ops:           [dynamic]Tx_Op,
	index_rules:   [dynamic]Secondary_Index_Rule,
	allocator:     runtime.Allocator,
}

Tx_Report :: struct {
	moment_index: i64,
	commit_size:  i64,
	before:       Maybe(Read_Hash_Map),
	after:        Read_Hash_Map,
	tx_meta:      Maybe(Read_Hash_Map),
	changes:      []Tx_Change,
}

tx_init :: proc(db: ^Database, base_moment: Maybe(i64) = -1, track_changes := false, allocator := context.temp_allocator) -> Tx {
	return Tx{
		db            = db,
		base_moment   = base_moment,
		track_changes = track_changes,
		meta          = make([dynamic]Tx_Meta_Entry, 0, 4, allocator),
		ops           = make([dynamic]Tx_Op, 0, 8, allocator),
		index_rules   = make([dynamic]Secondary_Index_Rule, 0, 2, allocator),
		allocator     = allocator,
	}
}

// Free all internal slices and dynamic arrays owned by `tx`.
tx_destroy :: proc(tx: ^Tx) {
	for op in tx.ops {
		if op.steps != nil {
			delete(op.steps, tx.allocator)
		}
		if op.from_steps != nil {
			delete(op.from_steps, tx.allocator)
		}
	}
	delete(tx.meta)
	delete(tx.ops)
	delete(tx.index_rules)
}

// Free a `[]Tx_Change` slice (and its formatted path strings) when allocated with a persistent allocator.
diff_changes_destroy :: proc(changes: []Tx_Change, allocator := context.allocator) {
	for chg in changes {
		if len(chg.path_str) > 0 {
			delete(chg.path_str, allocator)
		}
	}
	if changes != nil {
		delete(changes, allocator)
	}
}

// Free heap-allocated `changes` inside a `Tx_Report` when `tx_init` used a non-temporary allocator.
tx_report_destroy :: proc(report: ^Tx_Report, allocator := context.allocator) {
	diff_changes_destroy(report.changes, allocator)
	report.changes = nil
}

tx_doc :: proc(tx: ^Tx, doc: string) {
	tx.doc = doc
}

tx_instant :: proc(tx: ^Tx, epoch_ms: i64) {
	tx.instant = epoch_ms
}

tx_meta :: proc(tx: ^Tx, key: string, val: Writeable_Data) {
	append(&tx.meta, Tx_Meta_Entry{key = key, val = val})
}

tx_index_on :: proc(tx: ^Tx, source_map_key: string, field_key: string, into_sorted_map: string) {
	append(&tx.index_rules, Secondary_Index_Rule{
		source_map_key = source_map_key,
		field_key      = field_key,
		index_map_key  = into_sorted_map,
	})
}

tx_put_steps :: proc(tx: ^Tx, steps: []Path_Step, val: Writeable_Data) {
	cloned := make([]Path_Step, len(steps), tx.allocator)
	copy(cloned, steps)
	append(&tx.ops, Tx_Op{kind = .Put, steps = cloned, val = val})
}

tx_put :: proc(tx: ^Tx, path_str: string, val: Writeable_Data) -> Error {
	steps := parse_steps(path_str, tx.allocator) or_return
	append(&tx.ops, Tx_Op{kind = .Put, steps = steps, val = val})
	return nil
}

tx_append_steps :: proc(tx: ^Tx, steps: []Path_Step, val: Writeable_Data) {
	cloned := make([]Path_Step, len(steps), tx.allocator)
	copy(cloned, steps)
	append(&tx.ops, Tx_Op{kind = .Append, steps = cloned, val = val})
}

tx_append :: proc(tx: ^Tx, path_str: string, val: Writeable_Data) -> Error {
	steps := parse_steps(path_str, tx.allocator) or_return
	append(&tx.ops, Tx_Op{kind = .Append, steps = steps, val = val})
	return nil
}

tx_insert :: proc(tx: ^Tx, path_str: string, index: i64, val: Writeable_Data) -> Error {
	steps := parse_steps(path_str, tx.allocator) or_return
	append(&tx.ops, Tx_Op{kind = .Insert, steps = steps, offset = index, val = val})
	return nil
}

tx_rm_steps :: proc(tx: ^Tx, steps: []Path_Step) {
	cloned := make([]Path_Step, len(steps), tx.allocator)
	copy(cloned, steps)
	append(&tx.ops, Tx_Op{kind = .Remove, steps = cloned})
}

tx_rm :: proc(tx: ^Tx, path_str: string) -> Error {
	steps := parse_steps(path_str, tx.allocator) or_return
	append(&tx.ops, Tx_Op{kind = .Remove, steps = steps})
	return nil
}

tx_slice :: proc(tx: ^Tx, path_str: string, size: i64, offset: i64 = 0) -> Error {
	steps := parse_steps(path_str, tx.allocator) or_return
	append(&tx.ops, Tx_Op{kind = .Slice, steps = steps, offset = offset, size = size})
	return nil
}

// Zero-copy collection clone within a transaction with automatic `cursor_freeze` isolation.
tx_fork :: proc(tx: ^Tx, from_path: string, to_path: string) -> Error {
	src := parse_steps(from_path, tx.allocator) or_return
	dst := parse_steps(to_path, tx.allocator) or_return
	append(&tx.ops, Tx_Op{kind = .Fork, from_steps = src, steps = dst})
	return nil
}

// Freeze all transaction state written so far (`database_freeze`).
tx_savepoint :: proc(tx: ^Tx) {
	append(&tx.ops, Tx_Op{kind = .Savepoint})
}

// Escape hatch to mix raw `Write_Cursor` callbacks inside a `Tx`.
tx_with_cursor :: proc(tx: ^Tx, fn: Context_Function, user_data: rawptr = nil) {
	append(&tx.ops, Tx_Op{kind = .Callback, callback = fn, user_data = user_data})
}

@(private = "file")
_Tx_Exec_Ctx :: struct {
	tx:              ^Tx,
	resolved_parent: i64,
	has_parent:      bool,
	base_slot:       Slot,
	recorded:        [dynamic]Tx_Change,
}

@(private = "file")
_execute_tx_cb :: proc(cursor: ^Write_Cursor, user_data: rawptr) -> Error {
	ectx := (^_Tx_Exec_Ctx)(user_data)
	tx := ectx.tx
	moment := write_hash_map_init(cursor^) or_return

	for op in tx.ops {
		switch op.kind {
		case .Put:
			_evict_stale_secondary_index_entries(tx, &moment, ectx.has_parent, op) or_return
			put_at_steps(moment.write_cursor, op.steps, op.val) or_return
			_apply_secondary_index_rules(tx, &moment, op) or_return

		case .Append:
			target_cur := write_steps_cursor(moment.write_cursor, op.steps) or_return
			slot_ptr := cursor_resolved(target_cur.read_cursor) or_return
			#partial switch slot_ptr.slot.tag {
			case .Linked_Array_List:
				ll_col := write_linked_array_list_init(target_cur) or_return
				linked_array_list_append(&ll_col, op.val) or_return
			case .None, .Array_List:
				al_col := write_array_list_init(target_cur) or_return
				array_list_append(&al_col, op.val) or_return
			case:
				return .Unexpected_Tag
			}

		case .Insert:
			target_cur := write_steps_cursor(moment.write_cursor, op.steps) or_return
			ll_col := write_linked_array_list_init(target_cur) or_return
			linked_array_list_insert(&ll_col, op.offset, op.val) or_return

		case .Remove:
			cursor_reload_slot(&moment.write_cursor) or_return
			moment.read_hash_map.cursor = moment.write_cursor.read_cursor
			_evict_stale_secondary_index_entries(tx, &moment, true, op) or_return
			_execute_remove_steps(&moment, op.steps) or_return

		case .Slice:
			target_cur := write_steps_cursor(moment.write_cursor, op.steps) or_return
			slot_ptr := cursor_resolved(target_cur.read_cursor) or_return
			#partial switch slot_ptr.slot.tag {
			case .Array_List:
				al_col := write_array_list_init(target_cur) or_return
				array_list_slice(&al_col, op.size) or_return
			case .Linked_Array_List:
				ll_col := write_linked_array_list_init(target_cur) or_return
				linked_array_list_slice(&ll_col, op.offset, op.size) or_return
			case:
				return .Unexpected_Tag
			}

		case .Fork:
			cursor_reload_slot(&moment.write_cursor) or_return
			moment.read_hash_map.cursor = moment.write_cursor.read_cursor
			src_cur_maybe := read_steps_cursor(moment.read_hash_map.cursor, op.from_steps) or_return
			src_cur, has_src := src_cur_maybe.?
			if !has_src {
				return .Key_Not_Found
			}
			src_slot := cursor_slot(src_cur) or_return
			put_at_steps(moment.write_cursor, op.steps, src_slot) or_return
			dst_cur := write_steps_cursor(moment.write_cursor, op.steps) or_return
			cursor_freeze(&dst_cur) or_return

		case .Savepoint:
			database_freeze(cursor.db) or_return
			cursor_reload_slot(&moment.write_cursor) or_return
			moment.read_hash_map.cursor = moment.write_cursor.read_cursor

		case .Callback:
			if op.callback != nil {
				mc := moment.write_cursor
				op.callback(&mc, op.user_data) or_return
				cursor_reload_slot(&moment.write_cursor) or_return
				moment.read_hash_map.cursor = moment.write_cursor.read_cursor
			}
		}
	}

	// Only compute the structural diff when change tracking (`tx.track_changes`) is requested
	if tx.track_changes {
		cursor_reload_slot(&moment.write_cursor) or_return
		moment.read_hash_map.cursor = moment.write_cursor.read_cursor
		base_cur := Read_Cursor{
			slot_ptr = Slot_Pointer{position = nil, slot = ectx.base_slot if ectx.has_parent else Slot{}},
			db       = cursor.db,
		}
		diffs := diff_cursors(base_cur, moment.read_hash_map.cursor, false, tx.allocator) or_return
		defer delete(diffs, tx.allocator)
		for d in diffs {
			append(&ectx.recorded, d)
		}
	}

	wants_tx_meta := len(tx.doc) > 0 || tx.instant != nil || len(tx.meta) > 0 || tx.track_changes
	if wants_tx_meta {
		tx_cur := hash_map_put_cursor(&moment, "__tx") or_return
		tx_map := write_hash_map_init(tx_cur) or_return
		if len(tx.doc) > 0 {
			hash_map_put(&tx_map, "doc", tx.doc) or_return
		}
		if inst, ok := tx.instant.?; ok {
			hash_map_put(&tx_map, "tx_instant", inst) or_return
		}
		if ectx.has_parent {
			hash_map_put(&tx_map, "parent", ectx.resolved_parent) or_return
		}
		for m_entry in tx.meta {
			hash_map_put(&tx_map, m_entry.key, m_entry.val) or_return
		}
		if tx.track_changes {
			changes_cur := hash_map_put_cursor(&tx_map, "changes") or_return
			changes_list := write_array_list_init(changes_cur) or_return
			for chg in ectx.recorded {
				item_cur := array_list_append_cursor(&changes_list) or_return
				item_map := write_hash_map_init(item_cur) or_return
				hash_map_put(&item_map, "op", _op_kind_to_string(chg.op)) or_return
				hash_map_put(&item_map, "path", chg.path_str) or_return
				hash_map_put(&item_map, "old_tag", u64(chg.old_slot.tag)) or_return
				hash_map_put(&item_map, "new_tag", u64(chg.new_slot.tag)) or_return
			}
		}
	}

	return nil
}

@(private)
_op_kind_to_string :: proc(k: Tx_Op_Kind) -> string {
	switch k {
	case .Put:
		return "put"
	case .Append:
		return "append"
	case .Insert:
		return "insert"
	case .Remove:
		return "rm"
	case .Slice:
		return "slice"
	case .Fork:
		return "fork"
	case .Savepoint:
		return "savepoint"
	case .Callback:
		return "callback"
	}
	return "put"
}

@(private = "file")
_execute_remove_steps :: proc(moment: ^Write_Hash_Map, steps: []Path_Step) -> Error {
	if len(steps) == 0 {
		return .Invalid_Range
	}
	parent_cur := moment.write_cursor
	if len(steps) > 1 {
		parent_cur = write_steps_cursor(moment.write_cursor, steps[:len(steps) - 1]) or_return
	}
	last := steps[len(steps) - 1]
	switch last.kind {
	case .Hash_Map_Key:
		m := write_hash_map_init(parent_cur) or_return
		removed := hash_map_remove(&m, last.key) or_return
		if !removed {
			return .Key_Not_Found
		}
	case .Counted_Hash_Map_Key:
		cm := write_counted_hash_map_init(parent_cur) or_return
		removed := hash_map_remove(&cm.write_hash_map, last.key) or_return
		if !removed {
			return .Key_Not_Found
		}
	case .Sorted_Map_Key:
		sm_col := write_sorted_map_init(parent_cur) or_return
		removed := sorted_map_remove(&sm_col, last.key) or_return
		if !removed {
			return .Key_Not_Found
		}
	case .Linked_List_Idx:
		ll_col := write_linked_array_list_init(parent_cur) or_return
		linked_array_list_remove(&ll_col, last.index) or_return
	case .Hash_Set_Member:
		hs_col := write_hash_set_init(parent_cur) or_return
		removed := hash_set_remove(&hs_col, last.key) or_return
		if !removed {
			return .Key_Not_Found
		}
	case .Counted_Set_Member:
		cs_col := write_counted_hash_set_init(parent_cur) or_return
		removed := hash_set_remove(&cs_col.write_hash_set, last.key) or_return
		if !removed {
			return .Key_Not_Found
		}
	case .Sorted_Set_Member:
		ss_col := write_sorted_set_init(parent_cur) or_return
		removed := sorted_set_remove(&ss_col, last.key) or_return
		if !removed {
			return .Key_Not_Found
		}
	case .Array_List_Idx:
		return .Write_Not_Allowed
	}
	return nil
}

// Before overwriting or removing an indexed field/record, remove its previous key from the secondary Sorted_Map.
@(private = "file")
_evict_stale_secondary_index_entries :: proc(tx: ^Tx, moment: ^Write_Hash_Map, has_parent: bool, op: Tx_Op) -> Error {
	if !has_parent || len(tx.index_rules) == 0 || len(op.steps) < 2 {
		return nil
	}
	for rule in tx.index_rules {
		if op.steps[0].key != rule.source_map_key {
			continue
		}
		// Match either a field-level Put/Remove (`.users["101"].username`) or a record-level Remove (`.users["101"]`)
		is_field_op := len(op.steps) == 3 && op.steps[2].key == rule.field_key
		is_record_rm := op.kind == .Remove && len(op.steps) == 2
		if !is_field_op && !is_record_rm {
			continue
		}

		record_id := op.steps[1].key
		lookup_steps := [3]Path_Step{
			hm(rule.source_map_key),
			hm(record_id),
			hm(rule.field_key),
		}
		old_cur_maybe := read_steps_cursor(moment.read_hash_map.cursor, lookup_steps[:]) or_return
		if old_cur, has_old := old_cur_maybe.?; has_old {
			old_slot := cursor_slot(old_cur) or_return
			if old_slot.tag == .Short_Bytes || old_slot.tag == .Bytes {
				old_key := cursor_read_string(old_cur, 0, context.temp_allocator) or_return
				if op.kind == .Put {
					if new_key, is_str := op.val.(string); is_str && new_key == old_key {
						continue
					}
				}
				idx_cur := hash_map_put_cursor(moment, rule.index_map_key) or_return
				idx_sm := write_sorted_map_init(idx_cur) or_return
				_, _ = sorted_map_remove(&idx_sm, old_key)
			}
		}
	}
	return nil
}

@(private = "file")
_apply_secondary_index_rules :: proc(tx: ^Tx, moment: ^Write_Hash_Map, op: Tx_Op) -> Error {
	if len(tx.index_rules) == 0 || len(op.steps) != 3 || op.kind != .Put {
		return nil
	}
	for rule in tx.index_rules {
		if op.steps[0].key == rule.source_map_key && op.steps[2].key == rule.field_key {
			record_id := op.steps[1].key
			if idx_key, is_str := op.val.(string); is_str {
				idx_cur := hash_map_put_cursor(moment, rule.index_map_key) or_return
				idx_sm := write_sorted_map_init(idx_cur) or_return
				sorted_map_put(&idx_sm, idx_key, record_id) or_return
			}
		}
	}
	return nil
}

// Commit `tx` as a new moment in the root `Array_List` and return a `Tx_Report`.
tx_commit :: proc(tx: ^Tx) -> (report: Tx_Report, err: Error) {
	rc := database_root_cursor(tx.db)
	history := write_array_list_init(rc) or_return
	hist_count := array_list_count(history.read_array_list) or_return

	ectx := _Tx_Exec_Ctx{
		tx       = tx,
		recorded = make([dynamic]Tx_Change, 0, len(tx.ops), tx.allocator),
	}
	defer if err != nil {
		diff_changes_destroy(ectx.recorded[:], tx.allocator)
	}

	if bm, has_bm := tx.base_moment.?; has_bm && hist_count > 0 {
		resolved_idx := bm if bm >= 0 else hist_count + bm
		if resolved_idx < 0 || resolved_idx >= hist_count {
			return {}, .Key_Not_Found
		}
		slot_maybe := array_list_get_slot(history.read_array_list, resolved_idx) or_return
		if s, ok := slot_maybe.?; ok {
			ectx.base_slot = s
			ectx.has_parent = true
			ectx.resolved_parent = resolved_idx
		}
	}

	array_list_append_context(&history, ectx.base_slot, _execute_tx_cb, &ectx) or_return

	new_moment_idx := hist_count
	after_cur_maybe := array_list_get_cursor(history.read_array_list, new_moment_idx) or_return
	after_map := read_hash_map_init(after_cur_maybe.?) or_return

	before_map: Maybe(Read_Hash_Map)
	if ectx.has_parent {
		before_cur_maybe := array_list_get_cursor(history.read_array_list, ectx.resolved_parent) or_return
		if bc, ok := before_cur_maybe.?; ok {
			bm := read_hash_map_init(bc) or_return
			before_map = bm
		}
	}

	tx_meta_map: Maybe(Read_Hash_Map)
	tx_cur_maybe := hash_map_get_cursor(after_map, "__tx") or_return
	if tc, ok := tx_cur_maybe.?; ok {
		tm := read_hash_map_init(tc) or_return
		tx_meta_map = tm
	}

	committed := database_committed_size(tx.db) or_return
	return Tx_Report{
		moment_index = new_moment_idx,
		commit_size  = committed,
		before       = before_map,
		after        = after_map,
		tx_meta      = tx_meta_map,
		changes      = ectx.recorded[:],
	}, nil
}

// Parse and execute a declarative multi-line transaction script.
transact_script :: proc(db: ^Database, script: string, allocator := context.temp_allocator) -> (report: Tx_Report, err: Error) {
	tx := tx_init(db, -1, false, allocator)
	lines := strings.split_lines(script, allocator)

	for raw_line in lines {
		line := strings.trim_space(raw_line)
		if len(line) == 0 || strings.has_prefix(line, "//") || strings.has_prefix(line, "--") || line == "}" {
			continue
		}
		if strings.has_prefix(line, "branch ") {
			rest := strings.trim_space(strings.trim_prefix(line, "branch "))
			rest = strings.trim_space(strings.trim_suffix(rest, "{"))
			if strings.has_prefix(rest, "@") {
				m_idx, ok := strconv.parse_i64(rest[1:])
				if !ok {
					return {}, .Invalid_Range
				}
				tx.base_moment = m_idx
			} else if rest == "none" || rest == "genesis" {
				tx.base_moment = nil
			}
			continue
		}
		if strings.has_prefix(line, "doc ") {
			val := _parse_script_literal(strings.trim_space(strings.trim_prefix(line, "doc "))) or_return
			if s, ok := val.(string); ok {
				tx_doc(&tx, s)
			}
			continue
		}
		if strings.has_prefix(line, "instant ") {
			val := _parse_script_literal(strings.trim_space(strings.trim_prefix(line, "instant "))) or_return
			if iv, ok := val.(i64); ok {
				tx_instant(&tx, iv)
			} else if uv, uok := val.(u64); uok {
				tx_instant(&tx, i64(uv))
			}
			continue
		}
		if strings.has_prefix(line, "meta ") {
			rest := strings.trim_space(strings.trim_prefix(line, "meta "))
			eq_idx := strings.index_byte(rest, '=')
			if eq_idx < 0 {
				return {}, .Invalid_Range
			}
			k_lit := _parse_script_literal(strings.trim_space(rest[:eq_idx])) or_return
			v_lit := _parse_script_literal(strings.trim_space(rest[eq_idx + 1:])) or_return
			k_str, ok := k_lit.(string)
			if !ok {
				return {}, .Invalid_Range
			}
			tx_meta(&tx, k_str, v_lit)
			continue
		}
		if strings.has_prefix(line, "put ") {
			rest := strings.trim_space(strings.trim_prefix(line, "put "))
			eq_idx := strings.index_byte(rest, '=')
			if eq_idx < 0 {
				return {}, .Invalid_Range
			}
			path_str := strings.trim_space(rest[:eq_idx])
			v_lit := _parse_script_literal(strings.trim_space(rest[eq_idx + 1:])) or_return
			tx_put(&tx, path_str, v_lit) or_return
			continue
		}
		if strings.has_prefix(line, "append ") {
			rest := strings.trim_space(strings.trim_prefix(line, "append "))
			eq_idx := strings.index_byte(rest, '=')
			if eq_idx < 0 {
				return {}, .Invalid_Range
			}
			path_str := strings.trim_space(rest[:eq_idx])
			v_lit := _parse_script_literal(strings.trim_space(rest[eq_idx + 1:])) or_return
			tx_append(&tx, path_str, v_lit) or_return
			continue
		}
		if strings.has_prefix(line, "insert ") {
			rest := strings.trim_space(strings.trim_prefix(line, "insert "))
			eq_idx := strings.index_byte(rest, '=')
			if eq_idx < 0 {
				return {}, .Invalid_Range
			}
			left := strings.trim_space(rest[:eq_idx])
			last_space := strings.last_index_byte(left, ' ')
			if last_space < 0 {
				return {}, .Invalid_Range
			}
			path_str := strings.trim_space(left[:last_space])
			idx, ok := strconv.parse_i64(strings.trim_space(left[last_space + 1:]))
			if !ok {
				return {}, .Invalid_Range
			}
			v_lit := _parse_script_literal(strings.trim_space(rest[eq_idx + 1:])) or_return
			tx_insert(&tx, path_str, idx, v_lit) or_return
			continue
		}
		if strings.has_prefix(line, "rm ") {
			path_str := strings.trim_space(strings.trim_prefix(line, "rm "))
			tx_rm(&tx, path_str) or_return
			continue
		}
		if strings.has_prefix(line, "slice ") {
			rest := strings.trim_space(strings.trim_prefix(line, "slice "))
			last_space := strings.last_index_byte(rest, ' ')
			if last_space < 0 {
				return {}, .Invalid_Range
			}
			path_str := strings.trim_space(rest[:last_space])
			sz, ok := strconv.parse_i64(strings.trim_space(rest[last_space + 1:]))
			if !ok {
				return {}, .Invalid_Range
			}
			tx_slice(&tx, path_str, sz) or_return
			continue
		}
		if strings.has_prefix(line, "fork ") {
			rest := strings.trim_space(strings.trim_prefix(line, "fork "))
			arrow_idx := strings.index(rest, "->")
			if arrow_idx < 0 {
				return {}, .Invalid_Range
			}
			src_path := strings.trim_space(rest[:arrow_idx])
			dst_path := strings.trim_space(rest[arrow_idx + 2:])
			tx_fork(&tx, src_path, dst_path) or_return
			continue
		}
		if line == "savepoint" {
			tx_savepoint(&tx)
			continue
		}
		return {}, .Invalid_Range
	}

	return tx_commit(&tx)
}

@(private = "file")
_parse_script_literal :: proc(lit: string) -> (res: Writeable_Data, err: Error) {
	s := strings.trim_space(lit)
	if len(s) == 0 {
		return nil, .Invalid_Range
	}
	if s[0] == '"' {
		end_q := strings.last_index_byte(s[1:], '"')
		if end_q < 0 {
			return nil, .Invalid_Range
		}
		end_idx := end_q + 1
		body := s[1:end_idx]
		tail := strings.trim_space(s[end_idx + 1:])
		if strings.has_prefix(tail, "^^") {
			tag_str := strings.trim_space(tail[2:])
			if len(tag_str) != 2 {
				return nil, .Invalid_Format_Tag_Size
			}
			return new_tagged_string(body, transmute([]u8)tag_str), nil
		}
		return body, nil
	}
	if strings.has_suffix(s, "u") || strings.has_suffix(s, "U") {
		uv, ok := strconv.parse_u64(s[:len(s) - 1])
		if !ok {
			return nil, .Invalid_Range
		}
		return uv, nil
	}
	if strings.has_suffix(s, "i") || strings.has_suffix(s, "I") {
		iv, ok := strconv.parse_i64(s[:len(s) - 1])
		if !ok {
			return nil, .Invalid_Range
		}
		return iv, nil
	}
	if strings.contains_rune(s, '.') {
		fv, ok := strconv.parse_f64(s)
		if !ok {
			return nil, .Invalid_Range
		}
		return fv, nil
	}
	if s[0] == '-' {
		iv, ok := strconv.parse_i64(s)
		if !ok {
			return nil, .Invalid_Range
		}
		return iv, nil
	}
	uv, ok := strconv.parse_u64(s)
	if !ok {
		return nil, .Invalid_Range
	}
	return uv, nil
}

// ============================================================================
// Layer 3A: Odin Struct Reflection (`marshal` / `unmarshal`)
// ============================================================================

@(private)
_Field_Tag_Spec :: struct {
	name:       string,
	skip:       bool,
	col_prefix: u8, // 0, '$', '#', '[', '%', '^'
	format_tag: string,
}

@(private)
_parse_raw_tag_val :: proc(field_name: string, val: string) -> _Field_Tag_Spec {
	spec := _Field_Tag_Spec{name = field_name}
	if len(val) == 0 {
		return spec
	}
	if val == "-" {
		spec.skip = true
		return spec
	}
	comma_idx := strings.index_byte(val, ',')
	raw_name := val if comma_idx < 0 else val[:comma_idx]
	if len(raw_name) > 0 {
		if len(raw_name) > 4 && raw_name[0] == '[' && raw_name[1] == '[' && raw_name[len(raw_name) - 2] == ']' && raw_name[len(raw_name) - 1] == ']' {
			spec.col_prefix = '['
			spec.name = raw_name[2 : len(raw_name) - 2]
		} else if raw_name[0] == '$' || raw_name[0] == '#' || raw_name[0] == '%' || raw_name[0] == '^' {
			spec.col_prefix = raw_name[0]
			spec.name = raw_name[1:]
		} else {
			spec.name = raw_name
		}
	}
	if comma_idx >= 0 {
		rem := val[comma_idx + 1:]
		for len(rem) > 0 {
			next_c := strings.index_byte(rem, ',')
			part := rem if next_c < 0 else rem[:next_c]
			opt := strings.trim_space(part)
			if strings.has_prefix(opt, "tag=") {
				spec.format_tag = opt[4:]
			} else if opt == "sorted_map" {
				spec.col_prefix = '$'
			} else if opt == "counted_map" {
				spec.col_prefix = '#'
			} else if opt == "linked_list" {
				spec.col_prefix = '['
			} else if opt == "hash_set" {
				spec.col_prefix = '%'
			} else if opt == "sorted_set" {
				spec.col_prefix = '^'
			}
			if next_c < 0 {
				break
			}
			rem = rem[next_c + 1:]
		}
	}
	return spec
}

@(private)
_parse_field_tag :: proc(field_name: string, tag: reflect.Struct_Tag) -> _Field_Tag_Spec {
	val, ok := reflect.struct_tag_lookup(tag, "xitdb")
	if !ok || len(val) == 0 {
		return _Field_Tag_Spec{name = field_name}
	}
	return _parse_raw_tag_val(field_name, string(val))
}

// Marshal any Odin struct, map, slice, or primitive into `cursor`.
marshal :: proc(cursor: ^Write_Cursor, v: any) -> Error {
	if v == nil {
		return cursor_write(cursor, nil)
	}
	val := reflect.deref(v)
	ti := runtime.type_info_base(type_info_of(val.id))

	#partial switch info in ti.variant {
	case runtime.Type_Info_Integer:
		if info.signed {
			iv, ok := reflect.as_i64(val)
			if !ok {
				return .Unexpected_Tag
			}
			return cursor_write(cursor, iv)
		}
		uv, ok := reflect.as_u64(val)
		if !ok {
			return .Unexpected_Tag
		}
		return cursor_write(cursor, uv)

	case runtime.Type_Info_Float:
		fv, ok := reflect.as_f64(val)
		if !ok {
			return .Unexpected_Tag
		}
		return cursor_write(cursor, fv)

	case runtime.Type_Info_Boolean:
		bv, ok := reflect.as_bool(val)
		if !ok {
			return .Unexpected_Tag
		}
		return cursor_write(cursor, u64(1 if bv else 0))

	case runtime.Type_Info_String:
		str, ok := reflect.as_string(val)
		if !ok {
			return .Unexpected_Tag
		}
		return cursor_write(cursor, str)

	case runtime.Type_Info_Slice:
		elem_base := runtime.type_info_base(info.elem)
		if elem_base.id == u8 {
			raw_slice := (^runtime.Raw_Slice)(val.data)
			byte_slice := ([^]u8)(raw_slice.data)[:raw_slice.len]
			return cursor_write(cursor, byte_slice)
		}
		al_col := write_array_list_init(cursor^) or_return
		length := reflect.length(val)
		array_list_slice(&al_col, 0) or_return
		for i in 0 ..< length {
			elem_val := reflect.index(val, i)
			if elem_val == nil {
				return .Unexpected_Tag
			}
			elem_cur := array_list_append_cursor(&al_col) or_return
			marshal(&elem_cur, elem_val) or_return
		}
		return nil

	case runtime.Type_Info_Map:
		hm_col := write_hash_map_init(cursor^) or_return
		it: int
		for k_any, v_any in reflect.iterate_map(val, &it) {
			k_str, ok := reflect.as_string(k_any)
			if !ok {
				return .Unexpected_Tag
			}
			v_cur := hash_map_put_cursor(&hm_col, k_str) or_return
			marshal(&v_cur, v_any) or_return
		}
		return nil

	case runtime.Type_Info_Struct:
		hm_col := write_hash_map_init(cursor^) or_return
		fields := reflect.struct_fields_zipped(val.id)
		for field in fields {
			spec := _parse_field_tag(field.name, field.tag)
			if spec.skip {
				continue
			}
			fval := reflect.struct_field_value(val, field)
			_marshal_struct_field(&hm_col, spec, fval) or_return
		}
		return nil
	}

	return .Unexpected_Tag
}

@(private = "file")
_marshal_struct_field :: proc(hm_col: ^Write_Hash_Map, spec: _Field_Tag_Spec, fval: any) -> Error {
	if len(spec.format_tag) == 2 {
		if str, ok := reflect.as_string(fval); ok {
			return hash_map_put(hm_col, spec.name, new_tagged_string(str, transmute([]u8)spec.format_tag))
		}
	}

	ti := runtime.type_info_base(type_info_of(fval.id))
	#partial switch _ in ti.variant {
	case runtime.Type_Info_Slice:
		length := reflect.length(fval)
		switch spec.col_prefix {
		case '[':
			fcur := hash_map_put_cursor(hm_col, spec.name) or_return
			ll_col := write_linked_array_list_init(fcur) or_return
			linked_array_list_slice(&ll_col, 0, 0) or_return
			for i in 0 ..< length {
				elem := reflect.index(fval, i)
				ecur := linked_array_list_append_cursor(&ll_col) or_return
				marshal(&ecur, elem) or_return
			}
			return nil
		case '%':
			fcur := hash_map_put_cursor(hm_col, spec.name) or_return
			hs_col := write_hash_set_init(fcur) or_return
			for i in 0 ..< length {
				elem := reflect.index(fval, i)
				if s, ok := reflect.as_string(elem); ok {
					hash_set_put(&hs_col, s) or_return
				}
			}
			return nil
		case '^':
			fcur := hash_map_put_cursor(hm_col, spec.name) or_return
			ss_col := write_sorted_set_init(fcur) or_return
			for i in 0 ..< length {
				elem := reflect.index(fval, i)
				if s, ok := reflect.as_string(elem); ok {
					sorted_set_put(&ss_col, s) or_return
				}
			}
			return nil
		}

	case runtime.Type_Info_Map:
		switch spec.col_prefix {
		case '$':
			fcur := hash_map_put_cursor(hm_col, spec.name) or_return
			sm_col := write_sorted_map_init(fcur) or_return
			it: int
			for k_any, v_any in reflect.iterate_map(fval, &it) {
				k_str, ok := reflect.as_string(k_any)
				if !ok {
					return .Unexpected_Tag
				}
				vcur := sorted_map_put_cursor(&sm_col, k_str) or_return
				marshal(&vcur, v_any) or_return
			}
			return nil
		case '#':
			fcur := hash_map_put_cursor(hm_col, spec.name) or_return
			cm_col := write_counted_hash_map_init(fcur) or_return
			it: int
			for k_any, v_any in reflect.iterate_map(fval, &it) {
				k_str, ok := reflect.as_string(k_any)
				if !ok {
					return .Unexpected_Tag
				}
				vcur := hash_map_put_cursor(&cm_col.write_hash_map, k_str) or_return
				marshal(&vcur, v_any) or_return
			}
			return nil
		}
	}

	fcur := hash_map_put_cursor(hm_col, spec.name) or_return
	return marshal(&fcur, fval)
}

// Unmarshal a `Read_Cursor` into a value of type `$T`.
unmarshal :: proc($T: typeid, cursor: Read_Cursor, allocator := context.allocator) -> (res: T, err: Error) {
	err = unmarshal_into(cursor, any{&res, typeid_of(T)}, allocator)
	return res, err
}

unmarshal_into :: proc(cursor: Read_Cursor, dst_ptr: any, allocator := context.allocator) -> Error {
	val := reflect.deref(dst_ptr)
	ti := runtime.type_info_base(type_info_of(val.id))

	#partial switch info in ti.variant {
	case runtime.Type_Info_Integer:
		slot := cursor_slot(cursor) or_return
		if info.signed {
			iv: i64
			if slot.tag == .Int {
				iv = cursor_read_int(cursor) or_return
			} else if slot.tag == .Uint {
				uv := cursor_read_uint(cursor) or_return
				iv = i64(uv)
			} else {
				return .Unexpected_Tag
			}
			_assign_signed_int(val, iv)
			return nil
		}
		uv: u64
		if slot.tag == .Uint {
			uv = cursor_read_uint(cursor) or_return
		} else if slot.tag == .Int {
			iv := cursor_read_int(cursor) or_return
			uv = u64(iv)
		} else {
			return .Unexpected_Tag
		}
		_assign_unsigned_int(val, uv)
		return nil

	case runtime.Type_Info_Float:
		fv := cursor_read_float(cursor) or_return
		if ti.size == 8 {
			(^f64)(val.data)^ = fv
		} else {
			(^f32)(val.data)^ = f32(fv)
		}
		return nil

	case runtime.Type_Info_Boolean:
		uv := cursor_read_uint(cursor) or_return
		(^bool)(val.data)^ = (uv != 0)
		return nil

	case runtime.Type_Info_String:
		s := cursor_read_string(cursor, 0, allocator) or_return
		(^string)(val.data)^ = s
		return nil

	case runtime.Type_Info_Slice:
		elem_base := runtime.type_info_base(info.elem)
		if elem_base.id == u8 {
			b := cursor_read_bytes(cursor, 0, allocator) or_return
			(^[]u8)(val.data)^ = b
			return nil
		}
		slot := cursor_slot(cursor) or_return
		it := cursor_iterator(cursor) or_return
		items := make([dynamic]Read_Cursor, 0, 8, context.temp_allocator)
		for {
			c_maybe := cursor_iterator_next(&it) or_return
			c, ok := c_maybe.?
			if !ok {
				break
			}
			if slot.tag == .Sorted_Set || slot.tag == .Hash_Set || slot.tag == .Counted_Hash_Set {
				kv := cursor_read_kv_pair(c, context.temp_allocator) or_return
				append(&items, kv.key_cursor)
			} else {
				append(&items, c)
			}
		}
		count := len(items)
		raw_bytes, alloc_err := mem.alloc_bytes(count * info.elem_size, info.elem.align, allocator)
		if alloc_err != nil {
			return .Write_Failed
		}
		for item_cur, idx in items {
			elem_ptr := rawptr(uintptr(raw_data(raw_bytes)) + uintptr(idx * info.elem_size))
			unmarshal_into(item_cur, any{elem_ptr, info.elem.id}, allocator) or_return
		}
		raw_slice := (^runtime.Raw_Slice)(val.data)
		raw_slice.data = raw_data(raw_bytes)
		raw_slice.len = count
		return nil

	case runtime.Type_Info_Struct:
		hm_col := read_hash_map_init(cursor) or_return
		fields := reflect.struct_fields_zipped(val.id)
		for field in fields {
			spec := _parse_field_tag(field.name, field.tag)
			if spec.skip {
				continue
			}
			fcur_maybe := hash_map_get_cursor(hm_col, spec.name) or_return
			if fcur, ok := fcur_maybe.?; ok {
				fval := reflect.struct_field_value(val, field)
				unmarshal_into(fcur, fval, allocator) or_return
			}
		}
		return nil
	}

	return .Unexpected_Tag
}

@(private = "file")
_assign_signed_int :: proc(dst: any, v: i64) {
	switch dst.id {
	case i64:
		(^i64)(dst.data)^ = v
	case int:
		(^int)(dst.data)^ = int(v)
	case i32:
		(^i32)(dst.data)^ = i32(v)
	case i16:
		(^i16)(dst.data)^ = i16(v)
	case i8:
		(^i8)(dst.data)^ = i8(v)
	}
}

@(private = "file")
_assign_unsigned_int :: proc(dst: any, v: u64) {
	switch dst.id {
	case u64:
		(^u64)(dst.data)^ = v
	case uint:
		(^uint)(dst.data)^ = uint(v)
	case u32:
		(^u32)(dst.data)^ = u32(v)
	case u16:
		(^u16)(dst.data)^ = u16(v)
	case u8:
		(^u8)(dst.data)^ = u8(v)
	}
}

// ============================================================================
// Layer 3B: Datomic-Style `pull` Projection Engine
// ============================================================================

Pull_Map_Entry :: struct {
	key: string,
	val: Pull_Value,
}

Pull_Map :: distinct []Pull_Map_Entry
Pull_List :: distinct []Pull_Value

Pull_Value :: union {
	u64,
	i64,
	f64,
	string,
	Bytes,
	Pull_List,
	Pull_Map,
}

@(private)
_is_collection_tag :: proc(tag: Tag) -> bool {
	#partial switch tag {
	case .Array_List, .Linked_Array_List, .Hash_Map, .Counted_Hash_Map,
	     .Hash_Set, .Counted_Hash_Set, .Sorted_Map, .Sorted_Set:
		return true
	}
	return false
}

// Pull a shaped projection (e.g. `"{username, age, fruits[0..2], people[0]{age}}"`) from `cursor`.
pull :: proc(cursor: Read_Cursor, pattern: string, allocator := context.temp_allocator) -> (res: Pull_Value, err: Error) {
	p := strings.trim_space(pattern)
	if len(p) == 0 || p == "*" {
		slot := cursor_slot(cursor) or_return
		if !_is_collection_tag(slot.tag) {
			return _pull_scalar_slot(cursor, slot, allocator)
		}
	}
	visited := make(map[i64]bool, 16, context.temp_allocator)
	return _pull_with_visited(cursor, pattern, &visited, allocator)
}

@(private = "file")
_pull_scalar_slot :: proc(cursor: Read_Cursor, slot: Slot, allocator: runtime.Allocator) -> (res: Pull_Value, err: Error) {
	#partial switch slot.tag {
	case .None:
		return nil, nil
	case .Uint:
		u := cursor_read_uint(cursor) or_return
		return u, nil
	case .Int:
		i := cursor_read_int(cursor) or_return
		return i, nil
	case .Float:
		f := cursor_read_float(cursor) or_return
		return f, nil
	case .Short_Bytes, .Bytes:
		if slot.full {
			obj := cursor_read_bytes_object(cursor, 0, allocator) or_return
			return obj, nil
		}
		s := cursor_read_string(cursor, 0, allocator) or_return
		return s, nil
	}
	return nil, .Unexpected_Tag
}

@(private = "file")
_pull_cursor_value :: proc(cursor: Read_Cursor, allocator: runtime.Allocator) -> (res: Pull_Value, err: Error) {
	slot := cursor_slot(cursor) or_return
	if !_is_collection_tag(slot.tag) {
		return _pull_scalar_slot(cursor, slot, allocator)
	}
	visited := make(map[i64]bool, 16, context.temp_allocator)
	return _pull_wildcard(cursor, &visited, allocator)
}

@(private = "file")
_pull_with_visited :: proc(cursor: Read_Cursor, pattern: string, visited: ^map[i64]bool, allocator: runtime.Allocator) -> (res: Pull_Value, err: Error) {
	p := strings.trim_space(pattern)
	if len(p) == 0 || p == "*" {
		return _pull_wildcard(cursor, visited, allocator)
	}
	if p[0] == '{' && p[len(p) - 1] == '}' {
		inner := strings.trim_space(p[1 : len(p) - 1])
		specs := _split_top_level_pull_specs(inner, allocator)
		entries := make([dynamic]Pull_Map_Entry, 0, len(specs), allocator)
		for spec in specs {
			entry, has_entry := _eval_pull_spec(cursor, spec, visited, allocator) or_return
			if has_entry {
				append(&entries, entry)
			}
		}
		return Pull_Map(entries[:]), nil
	}
	return _pull_wildcard(cursor, visited, allocator)
}

// Lookup a key inside a `Pull_Map`.
pull_get :: proc(pv: Pull_Value, key: string) -> (res: Pull_Value, ok: bool) {
	pm, is_map := pv.(Pull_Map)
	if !is_map {
		return nil, false
	}
	for entry in pm {
		if entry.key == key {
			return entry.val, true
		}
	}
	return nil, false
}

@(private = "file")
_eval_pull_spec :: proc(cursor: Read_Cursor, spec: string, visited: ^map[i64]bool, allocator: runtime.Allocator) -> (entry: Pull_Map_Entry, found: bool, err: Error) {
	s := strings.trim_space(spec)
	if len(s) == 0 {
		return {}, false, nil
	}

	brace_idx := strings.index_byte(s, '{')
	sub_pattern := "*"
	path_part := s
	if brace_idx > 0 {
		path_part = strings.trim_space(s[:brace_idx])
		sub_pattern = strings.trim_space(s[brace_idx:])
	}

	range_start: i64 = 0
	range_end: i64 = -1
	has_range := false
	if bracket_idx := strings.last_index_byte(path_part, '['); bracket_idx > 0 && strings.has_suffix(path_part, "]") {
		inside := path_part[bracket_idx + 1 : len(path_part) - 1]
		if dots_idx := strings.index(inside, ".."); dots_idx >= 0 {
			r_start, ok1 := strconv.parse_i64(strings.trim_space(inside[:dots_idx]))
			r_end, ok2 := strconv.parse_i64(strings.trim_space(inside[dots_idx + 2:]))
			if ok1 && ok2 {
				range_start = r_start
				range_end = r_end
				has_range = true
				path_part = strings.trim_space(path_part[:bracket_idx])
			}
		}
	}

	steps := parse_steps(path_part, allocator) or_return
	if len(steps) == 0 {
		return {}, false, nil
	}
	target_maybe := read_steps_cursor(cursor, steps) or_return
	target_cur, ok := target_maybe.?
	if !ok {
		return {}, false, nil
	}

	label := steps[len(steps) - 1].key if len(steps[len(steps) - 1].key) > 0 else path_part
	if has_range {
		list_vals := _pull_range(target_cur, range_start, range_end, sub_pattern, visited, allocator) or_return
		return Pull_Map_Entry{key = label, val = list_vals}, true, nil
	}

	pulled := _pull_with_visited(target_cur, sub_pattern, visited, allocator) or_return
	return Pull_Map_Entry{key = label, val = pulled}, true, nil
}

@(private = "file")
_pull_range :: proc(cursor: Read_Cursor, start_idx, end_idx: i64, sub_pattern: string, visited: ^map[i64]bool, allocator: runtime.Allocator) -> (res: Pull_Value, err: Error) {
	slot := cursor_slot(cursor) or_return
	it: Cursor_Iterator
	#partial switch slot.tag {
	case .Array_List:
		al_col := read_array_list_init(cursor) or_return
		it = array_list_iterator_from(al_col, start_idx) or_return
	case .Linked_Array_List:
		ll_col := read_linked_array_list_init(cursor) or_return
		it = linked_array_list_iterator_from(ll_col, start_idx) or_return
	case:
		return nil, .Unexpected_Tag
	}

	limit := end_idx - start_idx
	items := make([dynamic]Pull_Value, 0, max(0, int(limit)), allocator)
	for i: i64 = 0; i < limit; i += 1 {
		c_maybe := cursor_iterator_next(&it) or_return
		c, ok := c_maybe.?
		if !ok {
			break
		}
		v := _pull_with_visited(c, sub_pattern, visited, allocator) or_return
		append(&items, v)
	}
	return Pull_List(items[:]), nil
}

@(private = "file")
_pull_wildcard :: proc(cursor: Read_Cursor, visited: ^map[i64]bool, allocator: runtime.Allocator) -> (res: Pull_Value, err: Error) {
	slot := cursor_slot(cursor) or_return
	if _is_collection_tag(slot.tag) {
		if visited[slot.value] {
			return nil, nil
		}
		visited[slot.value] = true
	}
	defer if _is_collection_tag(slot.tag) {
		delete_key(visited, slot.value)
	}

	#partial switch slot.tag {
	case .None:
		return nil, nil
	case .Uint:
		u := cursor_read_uint(cursor) or_return
		return u, nil
	case .Int:
		i := cursor_read_int(cursor) or_return
		return i, nil
	case .Float:
		f := cursor_read_float(cursor) or_return
		return f, nil
	case .Short_Bytes, .Bytes:
		if slot.full {
			obj := cursor_read_bytes_object(cursor, 0, allocator) or_return
			return obj, nil
		}
		s := cursor_read_string(cursor, 0, allocator) or_return
		return s, nil
	case .Array_List, .Linked_Array_List:
		it := cursor_iterator(cursor) or_return
		items := make([dynamic]Pull_Value, 0, 8, allocator)
		for {
			c_maybe := cursor_iterator_next(&it) or_return
			c, ok := c_maybe.?
			if !ok {
				break
			}
			v := _pull_wildcard(c, visited, allocator) or_return
			append(&items, v)
		}
		return Pull_List(items[:]), nil
	case .Hash_Set, .Counted_Hash_Set, .Sorted_Set:
		it := cursor_iterator(cursor) or_return
		items := make([dynamic]Pull_Value, 0, 8, allocator)
		for {
			c_maybe := cursor_iterator_next(&it) or_return
			c, ok := c_maybe.?
			if !ok {
				break
			}
			kv := cursor_read_kv_pair(c, allocator) or_return
			v := _pull_wildcard(kv.key_cursor, visited, allocator) or_return
			append(&items, v)
		}
		return Pull_List(items[:]), nil
	case .Hash_Map, .Counted_Hash_Map, .Sorted_Map:
		it := cursor_iterator(cursor) or_return
		entries := make([dynamic]Pull_Map_Entry, 0, 8, allocator)
		for {
			c_maybe := cursor_iterator_next(&it) or_return
			c, ok := c_maybe.?
			if !ok {
				break
			}
			kv := cursor_read_kv_pair(c, allocator) or_return
			k_str := cursor_read_string(kv.key_cursor, 0, allocator) or_return
			if k_str == "__tx" {
				continue
			}
			v := _pull_wildcard(kv.value_cursor, visited, allocator) or_return
			append(&entries, Pull_Map_Entry{key = k_str, val = v})
		}
		return Pull_Map(entries[:]), nil
	}
	return nil, .Unexpected_Tag
}

@(private = "file")
_split_top_level_pull_specs :: proc(inner: string, allocator: runtime.Allocator) -> []string {
	specs := make([dynamic]string, 0, 8, allocator)
	depth := 0
	start := 0
	for i in 0 ..< len(inner) {
		ch := inner[i]
		if ch == '{' || ch == '[' {
			depth += 1
		} else if ch == '}' || ch == ']' {
			depth -= 1
		} else if (ch == ',' || ch == '\n') && depth == 0 {
			part := strings.trim_space(inner[start:i])
			if len(part) > 0 {
				append(&specs, part)
			}
			start = i + 1
		}
	}
	if start < len(inner) {
		part := strings.trim_space(inner[start:])
		if len(part) > 0 {
			append(&specs, part)
		}
	}
	return specs[:]
}

// ============================================================================
// Layer 4: Structural Diff (`diff_moments`), Temporal Lineage (`history_of`)
//          & Composable B+Tree Secondary Index Queries
// ============================================================================

History_Entry :: struct {
	moment_index: i64,
	old_slot:     Slot,
	new_slot:     Slot,
	cursor:       Maybe(Read_Cursor),
	tx_doc:       string,
	tx_instant:   i64,
}

// Compute the minimal structural diff between two moments in $O(\text{changed paths})$
// by skipping any shared subtree where `slot_a == slot_b` in $O(1)$ time.
diff_moments :: proc(db: ^Database, moment_a, moment_b: i64, include_tx_meta := false, allocator := context.temp_allocator) -> (res: []Tx_Change, err: Error) {
	rc := database_root_cursor(db).read_cursor
	history := read_array_list_init(rc) or_return
	ca_maybe := array_list_get_cursor(history, moment_a) or_return
	cb_maybe := array_list_get_cursor(history, moment_b) or_return
	ca, oka := ca_maybe.?
	cb, okb := cb_maybe.?
	if !oka || !okb {
		return nil, .Key_Not_Found
	}
	return diff_cursors(ca, cb, include_tx_meta, allocator)
}

diff_cursors :: proc(cur_a, cur_b: Read_Cursor, include_tx_meta := false, allocator := context.temp_allocator) -> (res: []Tx_Change, err: Error) {
	changes := make([dynamic]Tx_Change, 0, 8, allocator)
	visited := make(map[[2]i64]bool, 16, context.temp_allocator)
	_diff_recursive(cur_a, cur_b, "", include_tx_meta, &changes, &visited, allocator) or_return
	return changes[:], nil
}

@(private = "file")
_diff_recursive :: proc(
	cur_a, cur_b: Read_Cursor,
	prefix: string,
	include_tx_meta: bool,
	changes: ^[dynamic]Tx_Change,
	visited: ^map[[2]i64]bool,
	allocator: runtime.Allocator,
) -> Error {
	slot_a := cursor_slot(cur_a) or_return
	slot_b := cursor_slot(cur_b) or_return

	if slot_a == slot_b {
		return nil
	}

	if _is_collection_tag(slot_a.tag) || _is_collection_tag(slot_b.tag) {
		off_a := slot_a.value if _is_collection_tag(slot_a.tag) else -1
		off_b := slot_b.value if _is_collection_tag(slot_b.tag) else -1
		pair := [2]i64{off_a, off_b}
		if visited[pair] {
			return nil
		}
		visited[pair] = true
		if off_b != -1 {
			visited[[2]i64{-1, off_b}] = true
		}
	}

	empty_cur := Read_Cursor{
		slot_ptr = Slot_Pointer{position = nil, slot = Slot{}},
		db       = cur_b.db,
	}

	if slot_a.tag == .None && (slot_b.tag == .Hash_Map || slot_b.tag == .Counted_Hash_Map || slot_b.tag == .Sorted_Map) {
		sigil := "." if slot_b.tag == .Hash_Map else ("#" if slot_b.tag == .Counted_Hash_Map else "$")
		it_b := cursor_iterator(cur_b) or_return
		for {
			cb_maybe := cursor_iterator_next(&it_b) or_return
			cb, ok := cb_maybe.?
			if !ok {
				break
			}
			kv_b := cursor_read_kv_pair(cb, context.temp_allocator) or_return
			k_str := cursor_read_string(kv_b.key_cursor, 0, context.temp_allocator) or_return
			if !include_tx_meta && len(prefix) == 0 && k_str == "__tx" {
				continue
			}
			child_path := fmt.aprintf("%s%s%s", prefix, sigil, k_str, allocator = allocator)
			val_b_slot := cursor_slot(kv_b.value_cursor) or_return
			if _is_collection_tag(val_b_slot.tag) && !visited[[2]i64{-1, val_b_slot.value}] {
				if len(prefix) == 0 && (val_b_slot.tag == .Array_List || val_b_slot.tag == .Linked_Array_List) {
					delete(child_path, allocator)
					sub_prefix := fmt.aprintf("%s%s%s", prefix, sigil, k_str, allocator = context.temp_allocator)
					_diff_recursive(empty_cur, kv_b.value_cursor, sub_prefix, include_tx_meta, changes, visited, allocator) or_return
				} else {
					append(changes, Tx_Change{op = .Put, path_str = child_path, old_slot = Slot{}, new_slot = val_b_slot})
				}
			} else {
				append(changes, Tx_Change{op = .Put, path_str = child_path, old_slot = Slot{}, new_slot = val_b_slot})
			}
		}
		return nil
	}

	if slot_a.tag == .None && (slot_b.tag == .Array_List || slot_b.tag == .Linked_Array_List) {
		cnt_b := cursor_count(cur_b) or_return
		is_linked := slot_b.tag == .Linked_Array_List
		for i: i64 = 0; i < cnt_b; i += 1 {
			step := ll(i) if is_linked else al(i)
			eb_maybe := read_steps_cursor(cur_b, []Path_Step{step}) or_return
			eb_slot := cursor_slot(eb_maybe.?) or_return
			child_path := fmt.aprintf(is_linked ? "%s[[%d]]" : "%s[%d]", prefix, i, allocator = allocator)
			append(changes, Tx_Change{op = .Append, path_str = child_path, old_slot = Slot{}, new_slot = eb_slot})
		}
		return nil
	}

	if slot_a.tag == slot_b.tag {
		#partial switch slot_a.tag {
		case .Hash_Map, .Counted_Hash_Map:
			sigil := "." if slot_a.tag == .Hash_Map else "#"
			map_a := Read_Hash_Map{cursor = cur_a}
			map_b := Read_Hash_Map{cursor = cur_b}

			it_a := cursor_iterator(cur_a) or_return
			for {
				ca_maybe := cursor_iterator_next(&it_a) or_return
				ca, ok := ca_maybe.?
				if !ok {
					break
				}
				kv_a := cursor_read_kv_pair(ca, context.temp_allocator) or_return
				k_str := cursor_read_string(kv_a.key_cursor, 0, context.temp_allocator) or_return
				if !include_tx_meta && len(prefix) == 0 && k_str == "__tx" {
					continue
				}
				vb_maybe := hash_map_get_cursor(map_b, k_str) or_return
				if vb_cur, has_b := vb_maybe.?; has_b {
					sub_prefix := fmt.aprintf("%s%s%s", prefix, sigil, k_str, allocator = context.temp_allocator)
					_diff_recursive(kv_a.value_cursor, vb_cur, sub_prefix, include_tx_meta, changes, visited, allocator) or_return
				} else {
					child_path := fmt.aprintf("%s%s%s", prefix, sigil, k_str, allocator = allocator)
					val_a_slot := cursor_slot(kv_a.value_cursor) or_return
					append(changes, Tx_Change{op = .Remove, path_str = child_path, old_slot = val_a_slot, new_slot = Slot{}})
				}
			}

			it_b := cursor_iterator(cur_b) or_return
			for {
				cb_maybe := cursor_iterator_next(&it_b) or_return
				cb, ok := cb_maybe.?
				if !ok {
					break
				}
				kv_b := cursor_read_kv_pair(cb, context.temp_allocator) or_return
				k_str := cursor_read_string(kv_b.key_cursor, 0, context.temp_allocator) or_return
				if !include_tx_meta && len(prefix) == 0 && k_str == "__tx" {
					continue
				}
				va_maybe := hash_map_get_cursor(map_a, k_str) or_return
				if va_maybe == nil {
					val_b_slot := cursor_slot(kv_b.value_cursor) or_return
					child_path := fmt.aprintf("%s%s%s", prefix, sigil, k_str, allocator = allocator)
					append(changes, Tx_Change{op = .Put, path_str = child_path, old_slot = Slot{}, new_slot = val_b_slot})
				}
			}
			return nil

		case .Sorted_Map:
			sm_a := Read_Sorted_Map{cursor = cur_a}
			sm_b := Read_Sorted_Map{cursor = cur_b}
			it_a := cursor_iterator(cur_a) or_return
			for {
				ca_maybe := cursor_iterator_next(&it_a) or_return
				ca, ok := ca_maybe.?
				if !ok {
					break
				}
				kv_a := cursor_read_kv_pair(ca, context.temp_allocator) or_return
				k_str := cursor_read_string(kv_a.key_cursor, 0, context.temp_allocator) or_return
				vb_maybe := sorted_map_get_cursor(sm_b, k_str) or_return
				if vb_cur, has_b := vb_maybe.?; has_b {
					sub_prefix := fmt.aprintf("%s$%s", prefix, k_str, allocator = context.temp_allocator)
					_diff_recursive(kv_a.value_cursor, vb_cur, sub_prefix, include_tx_meta, changes, visited, allocator) or_return
				} else {
					child_path := fmt.aprintf("%s$%s", prefix, k_str, allocator = allocator)
					val_a_slot := cursor_slot(kv_a.value_cursor) or_return
					append(changes, Tx_Change{op = .Remove, path_str = child_path, old_slot = val_a_slot, new_slot = Slot{}})
				}
			}
			it_b := cursor_iterator(cur_b) or_return
			for {
				cb_maybe := cursor_iterator_next(&it_b) or_return
				cb, ok := cb_maybe.?
				if !ok {
					break
				}
				kv_b := cursor_read_kv_pair(cb, context.temp_allocator) or_return
				k_str := cursor_read_string(kv_b.key_cursor, 0, context.temp_allocator) or_return
				va_maybe := sorted_map_get_cursor(sm_a, k_str) or_return
				if va_maybe == nil {
					val_b_slot := cursor_slot(kv_b.value_cursor) or_return
					child_path := fmt.aprintf("%s$%s", prefix, k_str, allocator = allocator)
					append(changes, Tx_Change{op = .Put, path_str = child_path, old_slot = Slot{}, new_slot = val_b_slot})
				}
			}
			return nil

		case .Array_List, .Linked_Array_List:
			cnt_a := cursor_count(cur_a) or_return
			cnt_b := cursor_count(cur_b) or_return
			common := min(cnt_a, cnt_b)
			is_linked := slot_a.tag == .Linked_Array_List
			for i: i64 = 0; i < common; i += 1 {
				step := ll(i) if is_linked else al(i)
				ea_maybe := read_steps_cursor(cur_a, []Path_Step{step}) or_return
				eb_maybe := read_steps_cursor(cur_b, []Path_Step{step}) or_return
				sub_prefix := fmt.aprintf(is_linked ? "%s[[%d]]" : "%s[%d]", prefix, i, allocator = context.temp_allocator)
				_diff_recursive(ea_maybe.?, eb_maybe.?, sub_prefix, include_tx_meta, changes, visited, allocator) or_return
			}
			if cnt_b > cnt_a {
				for i := cnt_a; i < cnt_b; i += 1 {
					step := ll(i) if is_linked else al(i)
					eb_maybe := read_steps_cursor(cur_b, []Path_Step{step}) or_return
					eb_slot := cursor_slot(eb_maybe.?) or_return
					child_path := fmt.aprintf(is_linked ? "%s[[%d]]" : "%s[%d]", prefix, i, allocator = allocator)
					append(changes, Tx_Change{op = .Append, path_str = child_path, old_slot = Slot{}, new_slot = eb_slot})
				}
			} else if cnt_b < cnt_a {
				cloned_prefix := strings.clone(prefix, allocator)
				append(changes, Tx_Change{op = .Slice, path_str = cloned_prefix, old_slot = slot_a, new_slot = slot_b})
			}
			return nil
		}
	}

	op: Tx_Op_Kind = .Put
	if slot_b.tag == .None && !slot_b.full {
		op = .Remove
	}
	cloned_prefix := strings.clone(prefix, allocator)
	append(changes, Tx_Change{op = op, path_str = cloned_prefix, old_slot = slot_a, new_slot = slot_b})
	return nil
}

// Walk database history and return every moment where `path_selector` changed,
// skipping unchanged moments in $O(1)$ via `Slot` equality.
history_of :: proc(db: ^Database, path_selector: string, allocator := context.temp_allocator) -> (res: []History_Entry, err: Error) {
	steps := parse_steps(path_selector, allocator) or_return
	rc := database_root_cursor(db).read_cursor
	history := read_array_list_init(rc) or_return
	moment_count := array_list_count(history) or_return

	entries := make([dynamic]History_Entry, 0, 8, allocator)
	prev_slot := Slot{}

	for m_idx: i64 = 0; m_idx < moment_count; m_idx += 1 {
		mc_maybe := array_list_get_cursor(history, m_idx) or_return
		mc, ok := mc_maybe.?
		if !ok {
			continue
		}
		target_maybe := read_steps_cursor(mc, steps) or_return
		cur_slot := Slot{}
		if tc, has_tc := target_maybe.?; has_tc {
			cur_slot = cursor_slot(tc) or_return
		}
		if cur_slot != prev_slot {
			doc_str := ""
			inst_val: i64 = 0
			m_map := read_hash_map_init(mc) or_return
			tx_maybe := hash_map_get_cursor(m_map, "__tx") or_return
			if tx_cur, has_tx := tx_maybe.?; has_tx {
				tx_map := read_hash_map_init(tx_cur) or_return
				if d_cur, has_d := (hash_map_get_cursor(tx_map, "doc") or_return).?; has_d {
					doc_str = cursor_read_string(d_cur, 0, allocator) or_return
				}
				if i_cur, has_i := (hash_map_get_cursor(tx_map, "tx_instant") or_return).?; has_i {
					inst_val = cursor_read_int(i_cur) or_return
				}
			}
			append(&entries, History_Entry{
				moment_index = m_idx,
				old_slot     = prev_slot,
				new_slot     = cur_slot,
				cursor       = target_maybe,
				tx_doc       = doc_str,
				tx_instant   = inst_val,
			})
			prev_slot = cur_slot
		}
	}
	return entries[:], nil
}

// Secondary Index B+Tree Query Helpers
Index_Hit :: struct {
	key:          string,
	value_cursor: Read_Cursor,
}

// Prefix scan on a `Sorted_Map` secondary index using `sorted_map_iterator_from_string`.
query_prefix :: proc(moment: Read_Hash_Map, index_key: string, prefix: string, allocator := context.temp_allocator) -> (res: []Index_Hit, err: Error) {
	sm_cur_maybe := hash_map_get_cursor(moment, index_key) or_return
	sm_cur, ok := sm_cur_maybe.?
	if !ok {
		return nil, nil
	}
	sm_col := read_sorted_map_init(sm_cur) or_return
	it := sorted_map_iterator_from_string(sm_col, prefix) or_return

	hits := make([dynamic]Index_Hit, 0, 8, allocator)
	for {
		c_maybe := cursor_iterator_next(&it) or_return
		c, has_c := c_maybe.?
		if !has_c {
			break
		}
		kv := cursor_read_kv_pair(c, allocator) or_return
		k_str := cursor_read_string(kv.key_cursor, 0, allocator) or_return
		if !strings.has_prefix(k_str, prefix) {
			break
		}
		append(&hits, Index_Hit{key = k_str, value_cursor = kv.value_cursor})
	}
	return hits[:], nil
}

// Offset/limit pagination over a `Sorted_Map` secondary index using `sorted_map_iterator_from_index`.
query_page :: proc(moment: Read_Hash_Map, index_key: string, offset, limit: i64, allocator := context.temp_allocator) -> (res: []Index_Hit, err: Error) {
	if limit <= 0 {
		return nil, nil
	}
	sm_cur_maybe := hash_map_get_cursor(moment, index_key) or_return
	sm_cur, ok := sm_cur_maybe.?
	if !ok {
		return nil, nil
	}
	sm_col := read_sorted_map_init(sm_cur) or_return
	it := sorted_map_iterator_from_index(sm_col, offset) or_return

	hits := make([dynamic]Index_Hit, 0, int(limit), allocator)
	for i: i64 = 0; i < limit; i += 1 {
		c_maybe := cursor_iterator_next(&it) or_return
		c, has_c := c_maybe.?
		if !has_c {
			break
		}
		kv := cursor_read_kv_pair(c, allocator) or_return
		k_str := cursor_read_string(kv.key_cursor, 0, allocator) or_return
		append(&hits, Index_Hit{key = k_str, value_cursor = kv.value_cursor})
	}
	return hits[:], nil
}

// $O(\log N)$ cardinality count in `[lower_inclusive, upper_exclusive)` using B+Tree ranks without scanning leaves!
query_count_range :: proc(moment: Read_Hash_Map, index_key: string, lower_inclusive, upper_exclusive: string) -> (count: i64, err: Error) {
	sm_cur_maybe := hash_map_get_cursor(moment, index_key) or_return
	sm_cur, ok := sm_cur_maybe.?
	if !ok {
		return 0, nil
	}
	sm_col := read_sorted_map_init(sm_cur) or_return
	r_lo := sorted_map_rank(sm_col, lower_inclusive) or_return
	r_hi := sorted_map_rank(sm_col, upper_exclusive) or_return
	return max(0, r_hi - r_lo), nil
}

// ============================================================================
// Layer 5: Structural & Temporal Datalog Engine
//          (Unification, B+Tree Pushdown, Aggregations & Transitive `reach`)
// ============================================================================

MAX_DATALOG_VARS :: 16

Datalog_Env :: struct {
	bound: [MAX_DATALOG_VARS]bool,
	vals:  [MAX_DATALOG_VARS]Pull_Value,
}

Datalog_Agg_Kind :: enum u8 {
	None,
	Count,
	Sum,
	Min,
	Max,
}

Datalog_Find_Item :: struct {
	agg:     Datalog_Agg_Kind,
	var_idx: int,
	label:   string,
}

Datalog_Moment_Kind :: enum u8 {
	Default_Moment,
	Literal_Moment,
	Var_Moment,
}

Datalog_Step :: struct {
	kind:    Step_Kind,
	is_var:  bool,
	var_idx: int,
	lit_key: string,
	lit_idx: i64,
}

Datalog_RHS_Kind :: enum u8 {
	None,
	Literal,
	Var,
}

Datalog_Pred_Op :: enum u8 {
	Eq,
	Neq,
	Lt,
	Lte,
	Gt,
	Gte,
	Starts_With,
	Contains,
}

Datalog_Clause_Kind :: enum u8 {
	Pattern,
	Not_Pattern,
	Predicate,
	Reach,
}

Datalog_Clause :: struct {
	kind:            Datalog_Clause_Kind,
	moment_kind:     Datalog_Moment_Kind,
	moment_lit:      i64,
	moment_var:      int,
	steps:           []Datalog_Step,
	rhs_kind:        Datalog_RHS_Kind,
	rhs_var:         int,
	rhs_lit:         Pull_Value,
	// Predicate fields
	pred_op:         Datalog_Pred_Op,
	pred_lhs_var:    int,
	pred_rhs_var:    int, // -1 if literal
	pred_rhs_lit:    Pull_Value,
	// Transitive `reach(?from, ?to, [?depth,] <edge_clause>)` fields
	reach_from_var:  int,
	reach_to_var:    int,
	reach_depth_var: int, // -1 if no depth var
	reach_edge:      ^Datalog_Clause,
}

Datalog_Query :: struct {
	var_names:      [MAX_DATALOG_VARS]string,
	var_count:      int,
	find_vars:      [dynamic]int,
	find_items:     [dynamic]Datalog_Find_Item,
	has_aggregates: bool,
	clauses:        [dynamic]Datalog_Clause,
	allocator:      runtime.Allocator,
}

Datalog_Result :: struct {
	vars: []string,
	rows: [][]Pull_Value,
}

// Initialize a programmatic Datalog query.
datalog_query_init :: proc(allocator := context.temp_allocator) -> Datalog_Query {
	return Datalog_Query{
		find_vars  = make([dynamic]int, 0, 8, allocator),
		find_items = make([dynamic]Datalog_Find_Item, 0, 8, allocator),
		clauses    = make([dynamic]Datalog_Clause, 0, 8, allocator),
		allocator  = allocator,
	}
}

@(private = "file")
_intern_datalog_var :: proc(q: ^Datalog_Query, name: string) -> (idx: int, err: Error) {
	for i in 0 ..< q.var_count {
		if q.var_names[i] == name {
			return i, nil
		}
	}
	if q.var_count >= MAX_DATALOG_VARS {
		return -1, .Invalid_Range
	}
	idx = q.var_count
	q.var_names[idx] = name
	q.var_count += 1
	return idx, nil
}

// Parse a Datalog query string (`find ?k, count(?v), ... where ...`) into a `Datalog_Query`.
parse_datalog :: proc(query_str: string, allocator := context.temp_allocator) -> (q: Datalog_Query, err: Error) {
	q = datalog_query_init(allocator)
	s := strings.trim_space(query_str)
	where_idx := strings.index(s, "where")
	if !strings.has_prefix(s, "where") && (!strings.has_prefix(s, "find ") || where_idx < 0) {
		return {}, .Invalid_Range
	}

	find_part := strings.trim_space(s[len("find "):where_idx])
	find_tokens := strings.split(find_part, ",", allocator)
	for tok in find_tokens {
		item_str := strings.trim_space(tok)
		if len(item_str) == 0 {
			continue
		}
		item := _parse_datalog_find_item(&q, item_str) or_return
		if item.agg != .None {
			q.has_aggregates = true
		}
		append(&q.find_items, item)
		append(&q.find_vars, item.var_idx)
	}
	if len(q.find_items) == 0 {
		return {}, .Invalid_Range
	}

	where_body := strings.trim_space(s[where_idx + len("where"):])
	clauses_raw := _split_datalog_where_clauses(where_body, allocator)
	for raw_clause in clauses_raw {
		line := strings.trim_space(raw_clause)
		if len(line) == 0 || strings.has_prefix(line, "//") || strings.has_prefix(line, "--") {
			continue
		}
		clause := _parse_datalog_clause(&q, line, allocator) or_return
		append(&q.clauses, clause)
	}

	return q, nil
}

@(private = "file")
_split_datalog_where_clauses :: proc(where_body: string, allocator: runtime.Allocator) -> []string {
	out := make([dynamic]string, 0, 8, allocator)
	lines := strings.split_lines(where_body, allocator)
	for raw_line in lines {
		line := strings.trim_space(raw_line)
		if len(line) == 0 || strings.has_prefix(line, "//") || strings.has_prefix(line, "--") {
			continue
		}
		// Support semicolon-delimited or space-separated clauses on a single line (e.g. from CLI/REPL)
		start := 0
		in_quotes := false
		paren_depth := 0
		bracket_depth := 0
		i := 0
		for i < len(line) {
			ch := line[i]
			if ch == '"' {
				in_quotes = !in_quotes
				i += 1
				continue
			}
			if !in_quotes {
				if ch == '(' {
					paren_depth += 1
				} else if ch == ')' {
					paren_depth -= 1
				} else if ch == '[' {
					bracket_depth += 1
				} else if ch == ']' {
					bracket_depth -= 1
				} else if (ch == ';' || ch == ',') && paren_depth == 0 && bracket_depth == 0 {
					sub := strings.trim_space(line[start:i])
					if len(sub) > 0 {
						append(&out, sub)
					}
					start = i + 1
					i += 1
					continue
				} else if ch == ' ' && paren_depth == 0 && bracket_depth == 0 {
					// Check if what precedes `i` is already a complete clause and what follows starts a new clause
					prev := strings.trim_space(line[start:i])
					rest := strings.trim_space(line[i + 1:])
					if _looks_like_complete_clause(prev) && _looks_like_clause_start(rest) {
						append(&out, prev)
						start = i + 1
					}
				}
			}
			i += 1
		}
		tail := strings.trim_space(line[start:])
		if len(tail) > 0 {
			append(&out, tail)
		}
	}
	return out[:]
}

@(private = "file")
_looks_like_complete_clause :: proc(s: string) -> bool {
	if len(s) == 0 || s == "not" {
		return false
	}
	// If it ends with an operator, it is incomplete
	if strings.has_suffix(s, "=") || strings.has_suffix(s, "<") || strings.has_suffix(s, ">") || strings.has_suffix(s, "!") {
		return false
	}
	return true
}

@(private = "file")
_looks_like_clause_start :: proc(s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	// Starts with an operator -> continuation of previous clause
	if s[0] == '=' || s[0] == '<' || s[0] == '>' || s[0] == '!' {
		return false
	}
	if s[0] == '.' || s[0] == '$' || s[0] == '#' || s[0] == '@' || s[0] == '[' || s[0] == '^' || s[0] == '%' {
		return true
	}
	if strings.has_prefix(s, "not ") || strings.has_prefix(s, "starts_with(") || strings.has_prefix(s, "contains(") || strings.has_prefix(s, "reach(") {
		return true
	}
	if s[0] == '?' {
		// `?var` starts a new predicate clause if followed by a comparison operator (`==`, `!=`, `<=`, `>=`, `<`, `>`)
		end_v := 1
		for end_v < len(s) && s[end_v] != ' ' && s[end_v] != '=' && s[end_v] != '!' && s[end_v] != '<' && s[end_v] != '>' {
			end_v += 1
		}
		after_v := strings.trim_space(s[end_v:])
		if strings.has_prefix(after_v, "==") || strings.has_prefix(after_v, "!=") || strings.has_prefix(after_v, "<=") || strings.has_prefix(after_v, ">=") || strings.has_prefix(after_v, "<") || strings.has_prefix(after_v, ">") {
			return true
		}
	}
	return false
}

@(private = "file")
_parse_datalog_find_item :: proc(q: ^Datalog_Query, token: string) -> (item: Datalog_Find_Item, err: Error) {
	aggs := [?]struct {
		prefix: string,
		kind:   Datalog_Agg_Kind,
	}{
		{"count(", .Count},
		{"sum(",   .Sum},
		{"min(",   .Min},
		{"max(",   .Max},
	}

	for a in aggs {
		if strings.has_prefix(token, a.prefix) && strings.has_suffix(token, ")") {
			inner := strings.trim_space(token[len(a.prefix) : len(token) - 1])
			if !strings.has_prefix(inner, "?") || len(inner) < 2 {
				return {}, .Invalid_Range
			}
			v_idx := _intern_datalog_var(q, inner) or_return
			return Datalog_Find_Item{
				agg     = a.kind,
				var_idx = v_idx,
				label   = token,
			}, nil
		}
	}

	if !strings.has_prefix(token, "?") || len(token) < 2 {
		return {}, .Invalid_Range
	}
	v_idx := _intern_datalog_var(q, token) or_return
	return Datalog_Find_Item{
		agg     = .None,
		var_idx = v_idx,
		label   = token,
	}, nil
}

@(private = "file")
_parse_datalog_clause :: proc(q: ^Datalog_Query, line: string, allocator: runtime.Allocator) -> (clause: Datalog_Clause, err: Error) {
	s := strings.trim_space(line)
	is_negated := false
	if strings.has_prefix(s, "not ") {
		is_negated = true
		s = strings.trim_space(s[len("not "):])
	}

	// Transitive graph traversal: `reach(?from, ?to, [?depth,] <edge_clause>)`
	if !is_negated && strings.has_prefix(s, "reach(") && strings.has_suffix(s, ")") {
		inner := strings.trim_space(s[len("reach(") : len(s) - 1])
		args := _split_top_level_comma_args(inner, allocator)
		if len(args) != 3 && len(args) != 4 {
			return {}, .Invalid_Range
		}
		if !strings.has_prefix(args[0], "?") || !strings.has_prefix(args[1], "?") {
			return {}, .Invalid_Range
		}
		from_var := _intern_datalog_var(q, args[0]) or_return
		to_var := _intern_datalog_var(q, args[1]) or_return
		depth_var := -1
		edge_str := args[2]
		if len(args) == 4 {
			if !strings.has_prefix(args[2], "?") {
				return {}, .Invalid_Range
			}
			depth_var = _intern_datalog_var(q, args[2]) or_return
			edge_str = args[3]
		}
		edge_clause := new(Datalog_Clause, allocator)
		edge_clause^ = _parse_datalog_clause(q, edge_str, allocator) or_return
		return Datalog_Clause{
			kind            = .Reach,
			reach_from_var  = from_var,
			reach_to_var    = to_var,
			reach_depth_var = depth_var,
			reach_edge      = edge_clause,
		}, nil
	}

	// Function-style predicates: `starts_with(?x, "prefix")` or `contains(?x, "sub")`
	if !is_negated && (strings.has_prefix(s, "starts_with(") || strings.has_prefix(s, "contains(")) {
		is_sw := strings.has_prefix(s, "starts_with(")
		open_p := strings.index_byte(s, '(')
		close_p := strings.last_index_byte(s, ')')
		if open_p < 0 || close_p <= open_p {
			return {}, .Invalid_Range
		}
		inner := s[open_p + 1 : close_p]
		comma_idx := strings.index_byte(inner, ',')
		if comma_idx < 0 {
			return {}, .Invalid_Range
		}
		vname := strings.trim_space(inner[:comma_idx])
		lit_raw := strings.trim_space(inner[comma_idx + 1:])
		if !strings.has_prefix(vname, "?") {
			return {}, .Invalid_Range
		}
		lhs_var := _intern_datalog_var(q, vname) or_return
		rhs_val := _parse_datalog_value(lit_raw) or_return
		return Datalog_Clause{
			kind         = .Predicate,
			pred_op      = .Starts_With if is_sw else .Contains,
			pred_lhs_var = lhs_var,
			pred_rhs_var = -1,
			pred_rhs_lit = rhs_val,
		}, nil
	}

	// Binary comparison predicates when line starts with `?var`
	if !is_negated && strings.has_prefix(s, "?") {
		return _parse_datalog_predicate(q, s)
	}

	// Pattern or Not_Pattern clause
	clause.kind = .Not_Pattern if is_negated else .Pattern
	clause.moment_kind = .Default_Moment
	clause.moment_var = -1
	clause.rhs_var = -1

	// Optional `@moment` or `@?m` prefix
	if strings.has_prefix(s, "@") {
		s = s[1:]
		if strings.has_prefix(s, "?") {
			end_v := 1
			for end_v < len(s) && s[end_v] != '.' && s[end_v] != '[' && s[end_v] != '$' && s[end_v] != '#' && s[end_v] != '%' && s[end_v] != '^' && s[end_v] != ' ' {
				end_v += 1
			}
			m_var := _intern_datalog_var(q, s[:end_v]) or_return
			clause.moment_kind = .Var_Moment
			clause.moment_var = m_var
			s = s[end_v:]
		} else {
			end_m := 0
			if end_m < len(s) && s[end_m] == '-' {
				end_m += 1
			}
			for end_m < len(s) && s[end_m] >= '0' && s[end_m] <= '9' {
				end_m += 1
			}
			m_idx, ok := strconv.parse_i64(s[:end_m])
			if !ok {
				return {}, .Invalid_Range
			}
			clause.moment_kind = .Literal_Moment
			clause.moment_lit = m_idx
			s = s[end_m:]
		}
	}

	// Split optional `= <rhs>`
	eq_idx := _find_top_level_equals(s)
	path_part := s
	if eq_idx >= 0 {
		path_part = strings.trim_space(s[:eq_idx])
		rhs_str := strings.trim_space(s[eq_idx + 1:])
		if strings.has_prefix(rhs_str, "?") {
			v_idx := _intern_datalog_var(q, rhs_str) or_return
			clause.rhs_kind = .Var
			clause.rhs_var = v_idx
		} else {
			val := _parse_datalog_value(rhs_str) or_return
			clause.rhs_kind = .Literal
			clause.rhs_lit = val
		}
	} else {
		clause.rhs_kind = .None
	}

	clause.steps = _parse_datalog_steps(q, path_part, allocator) or_return
	return clause, nil
}

@(private = "file")
_split_top_level_comma_args :: proc(s: string, allocator: runtime.Allocator) -> []string {
	args := make([dynamic]string, 0, 4, allocator)
	in_quotes := false
	depth := 0
	start := 0
	for i in 0 ..< len(s) {
		ch := s[i]
		if ch == '"' {
			in_quotes = !in_quotes
		} else if !in_quotes {
			if ch == '(' || ch == '[' || ch == '{' {
				depth += 1
			} else if ch == ')' || ch == ']' || ch == '}' {
				depth -= 1
			} else if ch == ',' && depth == 0 {
				append(&args, strings.trim_space(s[start:i]))
				start = i + 1
			}
		}
	}
	if start < len(s) {
		append(&args, strings.trim_space(s[start:]))
	}
	return args[:]
}

@(private = "file")
_find_top_level_equals :: proc(s: string) -> int {
	in_quotes := false
	bracket_depth := 0
	for i in 0 ..< len(s) {
		ch := s[i]
		if ch == '"' {
			in_quotes = !in_quotes
		} else if !in_quotes {
			if ch == '[' {
				bracket_depth += 1
			} else if ch == ']' {
				bracket_depth -= 1
			} else if ch == '=' && bracket_depth == 0 {
				return i
			}
		}
	}
	return -1
}

@(private = "file")
_parse_datalog_predicate :: proc(q: ^Datalog_Query, s: string) -> (clause: Datalog_Clause, err: Error) {
	ops := [?]struct {
		token: string,
		op:    Datalog_Pred_Op,
	}{
		{"==", .Eq},
		{"!=", .Neq},
		{"<=", .Lte},
		{">=", .Gte},
		{"<", .Lt},
		{">", .Gt},
	}

	for entry in ops {
		if idx := strings.index(s, entry.token); idx > 0 {
			lhs_str := strings.trim_space(s[:idx])
			rhs_str := strings.trim_space(s[idx + len(entry.token):])
			if !strings.has_prefix(lhs_str, "?") {
				return {}, .Invalid_Range
			}
			lhs_var := _intern_datalog_var(q, lhs_str) or_return
			rhs_var := -1
			var_lit: Pull_Value
			if strings.has_prefix(rhs_str, "?") {
				rhs_var = _intern_datalog_var(q, rhs_str) or_return
			} else {
				var_lit = _parse_datalog_value(rhs_str) or_return
			}
			return Datalog_Clause{
				kind         = .Predicate,
				pred_op      = entry.op,
				pred_lhs_var = lhs_var,
				pred_rhs_var = rhs_var,
				pred_rhs_lit = var_lit,
			}, nil
		}
	}
	return {}, .Invalid_Range
}

@(private = "file")
_parse_datalog_value :: proc(raw: string) -> (res: Pull_Value, err: Error) {
	wdata := _parse_script_literal(raw) or_return
	switch v in wdata {
	case string:
		return v, nil
	case u64:
		return v, nil
	case i64:
		return v, nil
	case f64:
		return v, nil
	case Bytes:
		return v, nil
	case Uint:
		return v.value, nil
	case Int:
		return v.value, nil
	case Float:
		return v.value, nil
	case Slot, []u8, nil:
		return nil, .Invalid_Range
	}
	return nil, .Invalid_Range
}

@(private = "file")
_parse_datalog_steps :: proc(q: ^Datalog_Query, path_str: string, allocator: runtime.Allocator) -> (res: []Datalog_Step, err: Error) {
	s := strings.trim_space(path_str)
	steps := make([dynamic]Datalog_Step, 0, 8, allocator)
	i := 0

	for i < len(s) {
		ch := s[i]
		switch ch {
		case '.', '#', '$', '%', '^':
			kind: Step_Kind = .Hash_Map_Key
			if ch == '#' {
				if i + 1 < len(s) && s[i + 1] == '%' {
					kind = .Counted_Set_Member
					i += 1
				} else {
					kind = .Counted_Hash_Map_Key
				}
			} else if ch == '$' {
				kind = .Sorted_Map_Key
			} else if ch == '%' {
				kind = .Hash_Set_Member
			} else if ch == '^' {
				kind = .Sorted_Set_Member
			}
			i += 1
			step, next_i := _parse_datalog_key_or_var(q, s, i, kind) or_return
			append(&steps, step)
			i = next_i

		case '[':
			if i + 1 < len(s) && s[i + 1] == '[' {
				// Linked_Array_List: [[i]] or [[?idx]]
				i += 2
				start := i
				for i < len(s) && s[i] != ']' {
					i += 1
				}
				if i + 1 >= len(s) || s[i] != ']' || s[i + 1] != ']' {
					return nil, .Invalid_Range
				}
				inner := strings.trim_space(s[start:i])
				if strings.has_prefix(inner, "?") {
					v_idx := _intern_datalog_var(q, inner) or_return
					append(&steps, Datalog_Step{kind = .Linked_List_Idx, is_var = true, var_idx = v_idx})
				} else {
					idx, ok := strconv.parse_i64(inner)
					if !ok {
						return nil, .Invalid_Range
					}
					append(&steps, Datalog_Step{kind = .Linked_List_Idx, is_var = false, lit_idx = idx})
				}
				i += 2
			} else if i + 1 < len(s) && (s[i + 1] == '"' || s[i + 1] == '\'') {
				key, next_i := _parse_bracketed_string(s, i) or_return
				append(&steps, Datalog_Step{kind = .Hash_Map_Key, is_var = false, lit_key = key})
				i = next_i
			} else {
				// Either `?var` key on preceding map or Array_List `[i]` / `[?idx]`
				i += 1
				start := i
				for i < len(s) && s[i] != ']' {
					i += 1
				}
				if i >= len(s) || s[i] != ']' {
					return nil, .Invalid_Range
				}
				inner := strings.trim_space(s[start:i])
				if strings.has_prefix(inner, "?") {
					v_idx := _intern_datalog_var(q, inner) or_return
					append(&steps, Datalog_Step{kind = .Hash_Map_Key, is_var = true, var_idx = v_idx})
				} else {
					idx, ok := strconv.parse_i64(inner)
					if !ok {
						return nil, .Invalid_Range
					}
					append(&steps, Datalog_Step{kind = .Array_List_Idx, is_var = false, lit_idx = idx})
				}
				i += 1
			}

		case:
			step, next_i := _parse_datalog_key_or_var(q, s, i, .Hash_Map_Key) or_return
			append(&steps, step)
			i = next_i
		}
	}

	return steps[:], nil
}

@(private = "file")
_parse_datalog_key_or_var :: proc(q: ^Datalog_Query, s: string, start_i: int, kind: Step_Kind) -> (step: Datalog_Step, next_i: int, err: Error) {
	if start_i >= len(s) {
		return {}, start_i, .Invalid_Range
	}
	if s[start_i] == '[' {
		if start_i + 1 < len(s) && s[start_i + 1] == '?' {
			end_b := start_i + 1
			for end_b < len(s) && s[end_b] != ']' {
				end_b += 1
			}
			if end_b >= len(s) {
				return {}, start_i, .Invalid_Range
			}
			vname := strings.trim_space(s[start_i + 1 : end_b])
			v_idx := _intern_datalog_var(q, vname) or_return
			return Datalog_Step{kind = kind, is_var = true, var_idx = v_idx}, end_b + 1, nil
		}
		key, ni := _parse_bracketed_string(s, start_i) or_return
		return Datalog_Step{kind = kind, is_var = false, lit_key = key}, ni, nil
	}
	if s[start_i] == '?' {
		i := start_i + 1
		for i < len(s) {
			ch := s[i]
			if ch == '.' || ch == '[' || ch == '#' || ch == '$' || ch == '%' || ch == '^' || ch == ' ' {
				break
			}
			i += 1
		}
		v_idx := _intern_datalog_var(q, s[start_i:i]) or_return
		return Datalog_Step{kind = kind, is_var = true, var_idx = v_idx}, i, nil
	}
	key, ni := _parse_step_ident_or_bracket(s, start_i) or_return
	return Datalog_Step{kind = kind, is_var = false, lit_key = key}, ni, nil
}

// Execute a Datalog query against `db` (defaults to the latest moment `-1` for unqualified clauses).
query_datalog :: proc(db: ^Database, query_str: string, default_moment: i64 = -1, allocator := context.temp_allocator) -> (res: Datalog_Result, err: Error) {
	q := parse_datalog(query_str, allocator) or_return
	return datalog_execute(db, &q, default_moment, allocator)
}

datalog_execute :: proc(db: ^Database, q: ^Datalog_Query, default_moment: i64 = -1, allocator := context.temp_allocator) -> (res: Datalog_Result, err: Error) {
	raw_rows := make([dynamic][]Pull_Value, 0, 8, allocator)
	matched_envs := make([dynamic]Datalog_Env, 0, 8, allocator)
	env := Datalog_Env{}

	_eval_datalog_clauses(db, q, 0, default_moment, env, &raw_rows, &matched_envs, false, allocator) or_return

	vars := make([]string, len(q.find_items), allocator)
	for item, i in q.find_items {
		vars[i] = item.label
	}

	if !q.has_aggregates {
		return Datalog_Result{vars = vars, rows = raw_rows[:]}, nil
	}

	agg_rows := _compute_datalog_aggregations(q, matched_envs[:], allocator)
	return Datalog_Result{vars = vars, rows = agg_rows}, nil
}

// Lookup a variable's value in a specific result row by name (e.g. `"?name"` or `"count(?id)"`).
datalog_row_get :: proc(res: Datalog_Result, row_idx: int, var_name: string) -> (val: Pull_Value, ok: bool) {
	if row_idx < 0 || row_idx >= len(res.rows) {
		return nil, false
	}
	for v, col_idx in res.vars {
		if v == var_name {
			return res.rows[row_idx][col_idx], true
		}
	}
	return nil, false
}

// Extract an entire column of `string` results for `var_name`.
datalog_column_strings :: proc(res: Datalog_Result, var_name: string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, 0, len(res.rows), allocator)
	for r_idx in 0 ..< len(res.rows) {
		if v, ok := datalog_row_get(res, r_idx, var_name); ok {
			if s, is_str := v.(string); is_str {
				append(&out, s)
			}
		}
	}
	return out[:]
}

@(private = "file")
_Datalog_Group_Bucket :: struct {
	key_env:    Datalog_Env,
	counts:     [MAX_DATALOG_VARS]u64,
	sum_i64:    [MAX_DATALOG_VARS]i64,
	sum_u64:    [MAX_DATALOG_VARS]u64,
	sum_f64:    [MAX_DATALOG_VARS]f64,
	sum_kind:   [MAX_DATALOG_VARS]u8, // 0 = u64, 1 = i64, 2 = f64
	min_vals:   [MAX_DATALOG_VARS]Pull_Value,
	max_vals:   [MAX_DATALOG_VARS]Pull_Value,
	has_minmax: [MAX_DATALOG_VARS]bool,
}

@(private = "file")
_compute_datalog_aggregations :: proc(q: ^Datalog_Query, envs: []Datalog_Env, allocator: runtime.Allocator) -> [][]Pull_Value {
	buckets := make([dynamic]_Datalog_Group_Bucket, 0, 8, allocator)

	has_group_keys := false
	for item in q.find_items {
		if item.agg == .None {
			has_group_keys = true
			break
		}
	}

	for env in envs {
		b_idx := -1
		for &b, i in buckets {
			same_group := true
			for item in q.find_items {
				if item.agg == .None {
					if !_pull_value_equals(b.key_env.vals[item.var_idx], env.vals[item.var_idx]) {
						same_group = false
						break
					}
				}
			}
			if same_group {
				b_idx = i
				break
			}
		}

		if b_idx < 0 {
			b_idx = len(buckets)
			append(&buckets, _Datalog_Group_Bucket{key_env = env})
		}

		b := &buckets[b_idx]
		for item, col_i in q.find_items {
			if !env.bound[item.var_idx] {
				continue
			}
			val := env.vals[item.var_idx]
			switch item.agg {
			case .None:
			case .Count:
				b.counts[col_i] += 1
			case .Sum:
				#partial switch v in val {
				case u64:
					b.sum_u64[col_i] += v
				case i64:
					b.sum_kind[col_i] = 1
					b.sum_i64[col_i] += v
				case f64:
					b.sum_kind[col_i] = 2
					b.sum_f64[col_i] += v
				}
			case .Min:
				if !b.has_minmax[col_i] {
					b.min_vals[col_i] = val
					b.max_vals[col_i] = val
					b.has_minmax[col_i] = true
				} else if cmp, ok := _compare_pull_values(val, b.min_vals[col_i]); ok && cmp < 0 {
					b.min_vals[col_i] = val
				}
			case .Max:
				if !b.has_minmax[col_i] {
					b.min_vals[col_i] = val
					b.max_vals[col_i] = val
					b.has_minmax[col_i] = true
				} else if cmp, ok := _compare_pull_values(val, b.max_vals[col_i]); ok && cmp > 0 {
					b.max_vals[col_i] = val
				}
			}
		}
	}

	// If global aggregation (no group-by keys) matched 0 rows and only `count`/`sum` are requested, return 1 zeroed row
	if len(buckets) == 0 && !has_group_keys {
		only_count_or_sum := true
		for item in q.find_items {
			if item.agg != .Count && item.agg != .Sum {
				only_count_or_sum = false
				break
			}
		}
		if only_count_or_sum {
			append(&buckets, _Datalog_Group_Bucket{})
		}
	}

	rows := make([][]Pull_Value, len(buckets), allocator)
	for &b, r_idx in buckets {
		row := make([]Pull_Value, len(q.find_items), allocator)
		for item, col_i in q.find_items {
			switch item.agg {
			case .None:
				row[col_i] = b.key_env.vals[item.var_idx]
			case .Count:
				row[col_i] = b.counts[col_i]
			case .Sum:
				if b.sum_kind[col_i] == 2 {
					row[col_i] = b.sum_f64[col_i] + f64(b.sum_i64[col_i]) + f64(b.sum_u64[col_i])
				} else if b.sum_kind[col_i] == 1 {
					row[col_i] = b.sum_i64[col_i] + i64(b.sum_u64[col_i])
				} else {
					row[col_i] = b.sum_u64[col_i]
				}
			case .Min:
				row[col_i] = b.min_vals[col_i]
			case .Max:
				row[col_i] = b.max_vals[col_i]
			}
		}
		rows[r_idx] = row
	}
	return rows
}

@(private = "file")
_eval_datalog_clauses :: proc(
	db: ^Database,
	q: ^Datalog_Query,
	clause_idx: int,
	default_moment: i64,
	env: Datalog_Env,
	out_rows: ^[dynamic][]Pull_Value,
	out_envs: ^[dynamic]Datalog_Env,
	stop_after_first: bool,
	allocator: runtime.Allocator,
) -> (matched_any: bool, err: Error) {
	if clause_idx >= len(q.clauses) {
		if !stop_after_first {
			if q.has_aggregates && out_envs != nil {
				append(out_envs, env)
			} else {
				row := make([]Pull_Value, len(q.find_items), allocator)
				for item, i in q.find_items {
					row[i] = env.vals[item.var_idx]
				}
				append(out_rows, row)
			}
		}
		return true, nil
	}

	clause := q.clauses[clause_idx]
	switch clause.kind {
	case .Predicate:
		next_env := env
		if !_eval_datalog_predicate(clause, &next_env) {
			return false, nil
		}
		return _eval_datalog_clauses(db, q, clause_idx + 1, default_moment, next_env, out_rows, out_envs, stop_after_first, allocator)

	case .Not_Pattern:
		neg_clause := clause
		neg_clause.kind = .Pattern
		has_match := _eval_pattern_moment(db, q, neg_clause, -1, default_moment, env, out_rows, out_envs, true, allocator) or_return
		if has_match {
			return false, nil
		}
		return _eval_datalog_clauses(db, q, clause_idx + 1, default_moment, env, out_rows, out_envs, stop_after_first, allocator)

	case .Reach:
		return _eval_reach_clause(db, q, clause, clause_idx, default_moment, env, out_rows, out_envs, stop_after_first, allocator)

	case .Pattern:
		return _eval_pattern_moment(db, q, clause, clause_idx, default_moment, env, out_rows, out_envs, stop_after_first, allocator)
	}

	return false, nil
}

@(private = "file")
_Reach_Queue_Item :: struct {
	node:  Pull_Value,
	depth: u64,
}

@(private = "file")
_eval_reach_clause :: proc(
	db: ^Database,
	q: ^Datalog_Query,
	clause: Datalog_Clause,
	clause_idx: int,
	default_moment: i64,
	env: Datalog_Env,
	out_rows: ^[dynamic][]Pull_Value,
	out_envs: ^[dynamic]Datalog_Env,
	stop_after_first: bool,
	allocator: runtime.Allocator,
) -> (matched_any: bool, err: Error) {
	if clause.reach_edge == nil {
		return false, nil
	}

	// Build a 1-clause helper query to step `clause.reach_edge^`
	step_q := Datalog_Query{
		var_names  = q.var_names,
		var_count  = q.var_count,
		find_items = make([dynamic]Datalog_Find_Item, 1, 1, allocator),
		clauses    = make([dynamic]Datalog_Clause, 1, 1, allocator),
		allocator  = allocator,
	}
	step_q.clauses[0] = clause.reach_edge^

	// 1. Resolve starting `from` seed(s)
	seeds := make([dynamic]Pull_Value, 0, 4, allocator)
	if env.bound[clause.reach_from_var] {
		append(&seeds, env.vals[clause.reach_from_var])
	} else {
		step_q.find_items[0] = Datalog_Find_Item{agg = .None, var_idx = clause.reach_from_var}
		seed_rows := make([dynamic][]Pull_Value, 0, 8, allocator)
		seed_env := env
		seed_env.bound[clause.reach_from_var] = false
		seed_env.bound[clause.reach_to_var] = false
		_ = _eval_pattern_moment(db, &step_q, clause.reach_edge^, 0, default_moment, seed_env, &seed_rows, nil, false, allocator) or_return
		for sr in seed_rows {
			if !_pull_slice_contains(seeds[:], sr[0]) {
				append(&seeds, sr[0])
			}
		}
	}

	step_q.find_items[0] = Datalog_Find_Item{agg = .None, var_idx = clause.reach_to_var}

	// 2. For each seed, run cycle-safe BFS
	for seed in seeds {
		visited := make([dynamic]Pull_Value, 0, 8, allocator)
		queue := make([dynamic]_Reach_Queue_Item, 0, 8, allocator)
		append(&queue, _Reach_Queue_Item{node = seed, depth = 0})

		q_head := 0
		for q_head < len(queue) {
			curr := queue[q_head]
			q_head += 1

			edge_env := env
			edge_env.bound[clause.reach_from_var] = true
			edge_env.vals[clause.reach_from_var] = curr.node
			edge_env.bound[clause.reach_to_var] = false

			neighbor_rows := make([dynamic][]Pull_Value, 0, 4, allocator)
			_ = _eval_pattern_moment(db, &step_q, clause.reach_edge^, 0, default_moment, edge_env, &neighbor_rows, nil, false, allocator) or_return

			for nrow in neighbor_rows {
				next_node := nrow[0]
				if _pull_slice_contains(visited[:], next_node) {
					continue
				}
				next_depth := curr.depth + 1
				append(&visited, next_node)
				append(&queue, _Reach_Queue_Item{node = next_node, depth = next_depth})

				// Check if `reach_to_var` or `reach_depth_var` was already bound in outer `env`
				if env.bound[clause.reach_to_var] && !_pull_value_equals(env.vals[clause.reach_to_var], next_node) {
					continue
				}
				if clause.reach_depth_var >= 0 && env.bound[clause.reach_depth_var] {
					if !_pull_value_equals(env.vals[clause.reach_depth_var], next_depth) {
						continue
					}
				}

				next_env := env
				next_env.bound[clause.reach_from_var] = true
				next_env.vals[clause.reach_from_var] = seed
				next_env.bound[clause.reach_to_var] = true
				next_env.vals[clause.reach_to_var] = next_node
				if clause.reach_depth_var >= 0 {
					next_env.bound[clause.reach_depth_var] = true
					next_env.vals[clause.reach_depth_var] = next_depth
				}

				m := _eval_datalog_clauses(db, q, clause_idx + 1, default_moment, next_env, out_rows, out_envs, stop_after_first, allocator) or_return
				if m {
					matched_any = true
					if stop_after_first {
						return true, nil
					}
				}
			}
		}
	}

	return matched_any, nil
}

@(private = "file")
_pull_slice_contains :: proc(list: []Pull_Value, target: Pull_Value) -> bool {
	for item in list {
		if _pull_value_equals(item, target) {
			return true
		}
	}
	return false
}

@(private = "file")
_eval_pattern_moment :: proc(
	db: ^Database,
	q: ^Datalog_Query,
	clause: Datalog_Clause,
	clause_idx: int,
	default_moment: i64,
	env: Datalog_Env,
	out_rows: ^[dynamic][]Pull_Value,
	out_envs: ^[dynamic]Datalog_Env,
	check_only: bool,
	allocator: runtime.Allocator,
) -> (matched_any: bool, err: Error) {
	rc := database_root_cursor(db).read_cursor
	root_slot := cursor_slot(rc) or_return

	if root_slot.tag != .Array_List {
		// Non-Array_List top-level database root
		return _eval_pattern_steps(db, q, clause, 0, rc, clause_idx, default_moment, env, out_rows, out_envs, check_only, allocator)
	}

	history := read_array_list_init(rc) or_return
	moment_count := array_list_count(history) or_return
	if moment_count == 0 {
		return false, nil
	}

	switch clause.moment_kind {
	case .Default_Moment:
		mc_maybe := array_list_get_cursor(history, default_moment) or_return
		mc, ok := mc_maybe.?
		if !ok {
			return false, nil
		}
		return _eval_pattern_steps(db, q, clause, 0, mc, clause_idx, default_moment, env, out_rows, out_envs, check_only, allocator)

	case .Literal_Moment:
		mc_maybe := array_list_get_cursor(history, clause.moment_lit) or_return
		mc, ok := mc_maybe.?
		if !ok {
			return false, nil
		}
		return _eval_pattern_steps(db, q, clause, 0, mc, clause_idx, default_moment, env, out_rows, out_envs, check_only, allocator)

	case .Var_Moment:
		if env.bound[clause.moment_var] {
			m_idx, ok := _pull_val_as_i64(env.vals[clause.moment_var])
			if !ok {
				return false, nil
			}
			mc_maybe := array_list_get_cursor(history, m_idx) or_return
			mc, has_mc := mc_maybe.?
			if !has_mc {
				return false, nil
			}
			return _eval_pattern_steps(db, q, clause, 0, mc, clause_idx, default_moment, env, out_rows, out_envs, check_only, allocator)
		}
		for m_idx: i64 = 0; m_idx < moment_count; m_idx += 1 {
			mc_maybe := array_list_get_cursor(history, m_idx) or_return
			mc, has_mc := mc_maybe.?
			if !has_mc {
				continue
			}
			next_env := env
			next_env.bound[clause.moment_var] = true
			next_env.vals[clause.moment_var] = m_idx
			m_matched := _eval_pattern_steps(db, q, clause, 0, mc, clause_idx, default_moment, next_env, out_rows, out_envs, check_only, allocator) or_return
			if m_matched {
				matched_any = true
				if check_only {
					return true, nil
				}
			}
		}
		return matched_any, nil
	}

	return false, nil
}

@(private = "file")
_eval_pattern_steps :: proc(
	db: ^Database,
	q: ^Datalog_Query,
	clause: Datalog_Clause,
	step_idx: int,
	cur: Read_Cursor,
	clause_idx: int,
	default_moment: i64,
	env: Datalog_Env,
	out_rows: ^[dynamic][]Pull_Value,
	out_envs: ^[dynamic]Datalog_Env,
	check_only: bool,
	allocator: runtime.Allocator,
) -> (matched_any: bool, err: Error) {
	if step_idx >= len(clause.steps) {
		next_env := env
		switch clause.rhs_kind {
		case .None:
		case .Literal:
			actual := _pull_cursor_value(cur, allocator) or_return
			if !_pull_value_equals(actual, clause.rhs_lit) {
				return false, nil
			}
		case .Var:
			actual := _pull_cursor_value(cur, allocator) or_return
			if next_env.bound[clause.rhs_var] {
				if !_pull_value_equals(next_env.vals[clause.rhs_var], actual) {
					return false, nil
				}
			} else {
				next_env.bound[clause.rhs_var] = true
				next_env.vals[clause.rhs_var] = actual
			}
		}
		if check_only {
			return true, nil
		}
		return _eval_datalog_clauses(db, q, clause_idx + 1, default_moment, next_env, out_rows, out_envs, false, allocator)
	}

	step := clause.steps[step_idx]
	slot := cursor_slot(cur) or_return
	if slot.tag == .None {
		return false, nil
	}

	// 1. Literal step OR already-bound variable step -> O(log_16 N) point lookup!
	if !step.is_var || env.bound[step.var_idx] {
		ps: Path_Step
		ps.kind = step.kind
		if !step.is_var {
			ps.key = step.lit_key
			ps.index = step.lit_idx
		} else {
			bval := env.vals[step.var_idx]
			if slot.tag == .Array_List || slot.tag == .Linked_Array_List {
				idx_val, ok := _pull_val_as_i64(bval)
				if !ok {
					return false, nil
				}
				ps.kind = .Linked_List_Idx if slot.tag == .Linked_Array_List else .Array_List_Idx
				ps.index = idx_val
			} else {
				k_str, ok := bval.(string)
				if !ok {
					return false, nil
				}
				ps.key = k_str
				if slot.tag == .Sorted_Map {
					ps.kind = .Sorted_Map_Key
				} else if slot.tag == .Counted_Hash_Map {
					ps.kind = .Counted_Hash_Map_Key
				}
			}
		}
		next_cur_maybe := read_steps_cursor(cur, []Path_Step{ps}) or_return
		next_cur, ok := next_cur_maybe.?
		if !ok {
			return false, nil
		}
		return _eval_pattern_steps(db, q, clause, step_idx + 1, next_cur, clause_idx, default_moment, env, out_rows, out_envs, check_only, allocator)
	}

	// 2. Unbound variable step -> B+Tree prefix/range seek or collection iterator
	#partial switch slot.tag {
	case .Sorted_Map, .Sorted_Set:
		prefix_hint, has_prefix := _find_prefix_hint(q, step.var_idx)
		lower_hint, has_lower := _find_lower_bound_hint(q, step.var_idx)
		it: Cursor_Iterator
		if has_prefix {
			it = cursor_iterator_sorted_from_key(cur, transmute([]u8)prefix_hint) or_return
		} else if has_lower {
			it = cursor_iterator_sorted_from_key(cur, transmute([]u8)lower_hint) or_return
		} else {
			it = cursor_iterator(cur) or_return
		}
		for {
			c_maybe := cursor_iterator_next(&it) or_return
			c, has_c := c_maybe.?
			if !has_c {
				break
			}
			kv := cursor_read_kv_pair(c, allocator) or_return
			k_str := cursor_read_string(kv.key_cursor, 0, allocator) or_return
			if has_prefix && !strings.has_prefix(k_str, prefix_hint) {
				break
			}
			next_env := env
			next_env.bound[step.var_idx] = true
			next_env.vals[step.var_idx] = k_str
			child_cur := kv.key_cursor if slot.tag == .Sorted_Set else kv.value_cursor
			m := _eval_pattern_steps(db, q, clause, step_idx + 1, child_cur, clause_idx, default_moment, next_env, out_rows, out_envs, check_only, allocator) or_return
			if m {
				matched_any = true
				if check_only {
					return true, nil
				}
			}
		}
		return matched_any, nil

	case .Hash_Map, .Counted_Hash_Map, .Hash_Set, .Counted_Hash_Set:
		is_set := slot.tag == .Hash_Set || slot.tag == .Counted_Hash_Set
		it := cursor_iterator(cur) or_return
		for {
			c_maybe := cursor_iterator_next(&it) or_return
			c, has_c := c_maybe.?
			if !has_c {
				break
			}
			kv := cursor_read_kv_pair(c, allocator) or_return
			k_str := cursor_read_string(kv.key_cursor, 0, allocator) or_return
			if step_idx == 0 && k_str == "__tx" {
				continue
			}
			next_env := env
			next_env.bound[step.var_idx] = true
			next_env.vals[step.var_idx] = k_str
			child_cur := kv.key_cursor if is_set else kv.value_cursor
			m := _eval_pattern_steps(db, q, clause, step_idx + 1, child_cur, clause_idx, default_moment, next_env, out_rows, out_envs, check_only, allocator) or_return
			if m {
				matched_any = true
				if check_only {
					return true, nil
				}
			}
		}
		return matched_any, nil

	case .Array_List, .Linked_Array_List:
		it := cursor_iterator(cur) or_return
		idx: i64 = 0
		for {
			c_maybe := cursor_iterator_next(&it) or_return
			c, has_c := c_maybe.?
			if !has_c {
				break
			}
			next_env := env
			next_env.bound[step.var_idx] = true
			next_env.vals[step.var_idx] = idx
			idx += 1
			m := _eval_pattern_steps(db, q, clause, step_idx + 1, c, clause_idx, default_moment, next_env, out_rows, out_envs, check_only, allocator) or_return
			if m {
				matched_any = true
				if check_only {
					return true, nil
				}
			}
		}
		return matched_any, nil
	}

	return false, nil
}

@(private = "file")
_find_prefix_hint :: proc(q: ^Datalog_Query, var_idx: int) -> (prefix: string, ok: bool) {
	for c in q.clauses {
		if c.kind == .Predicate && c.pred_op == .Starts_With && c.pred_lhs_var == var_idx {
			if s, is_s := c.pred_rhs_lit.(string); is_s {
				return s, true
			}
		}
	}
	return "", false
}

@(private = "file")
_find_lower_bound_hint :: proc(q: ^Datalog_Query, var_idx: int) -> (bound: string, ok: bool) {
	for c in q.clauses {
		if c.kind == .Predicate && (c.pred_op == .Gte || c.pred_op == .Gt) && c.pred_lhs_var == var_idx && c.pred_rhs_var == -1 {
			if s, is_s := c.pred_rhs_lit.(string); is_s {
				return s, true
			}
		}
	}
	return "", false
}

@(private = "file")
_eval_datalog_predicate :: proc(clause: Datalog_Clause, env: ^Datalog_Env) -> bool {
	if !env.bound[clause.pred_lhs_var] {
		if clause.pred_op == .Eq {
			if clause.pred_rhs_var < 0 {
				env.bound[clause.pred_lhs_var] = true
				env.vals[clause.pred_lhs_var] = clause.pred_rhs_lit
				return true
			} else if env.bound[clause.pred_rhs_var] {
				env.bound[clause.pred_lhs_var] = true
				env.vals[clause.pred_lhs_var] = env.vals[clause.pred_rhs_var]
				return true
			}
		}
		return false
	}
	lhs := env.vals[clause.pred_lhs_var]
	rhs := clause.pred_rhs_lit
	if clause.pred_rhs_var >= 0 {
		if !env.bound[clause.pred_rhs_var] {
			if clause.pred_op == .Eq {
				env.bound[clause.pred_rhs_var] = true
				env.vals[clause.pred_rhs_var] = lhs
				return true
			}
			return false
		}
		rhs = env.vals[clause.pred_rhs_var]
	}

	switch clause.pred_op {
	case .Eq:
		return _pull_value_equals(lhs, rhs)
	case .Neq:
		return !_pull_value_equals(lhs, rhs)
	case .Starts_With:
		ls, ok1 := lhs.(string)
		rs, ok2 := rhs.(string)
		return ok1 && ok2 && strings.has_prefix(ls, rs)
	case .Contains:
		ls, ok1 := lhs.(string)
		rs, ok2 := rhs.(string)
		return ok1 && ok2 && strings.contains(ls, rs)
	case .Lt, .Lte, .Gt, .Gte:
		cmp, ok := _compare_pull_values(lhs, rhs)
		if !ok {
			return false
		}
		if clause.pred_op == .Lt {
			return cmp < 0
		}
		if clause.pred_op == .Lte {
			return cmp <= 0
		}
		if clause.pred_op == .Gt {
			return cmp > 0
		}
		return cmp >= 0
	}
	return false
}

@(private = "file")
_pull_val_as_i64 :: proc(v: Pull_Value) -> (res: i64, ok: bool) {
	#partial switch val in v {
	case i64:
		return val, true
	case u64:
		return i64(val), true
	}
	return 0, false
}

@(private = "file")
_pull_value_equals :: proc(a, b: Pull_Value) -> bool {
	if ai, ok1 := _pull_val_as_i64(a); ok1 {
		if bi, ok2 := _pull_val_as_i64(b); ok2 {
			return ai == bi
		}
	}
	#partial switch va in a {
	case string:
		if vb, ok := b.(string); ok {
			return va == vb
		}
	case f64:
		if vb, ok := b.(f64); ok {
			return va == vb
		}
	}
	return false
}

@(private = "file")
_compare_pull_values :: proc(a, b: Pull_Value) -> (cmp: int, ok: bool) {
	if ai, ok1 := _pull_val_as_i64(a); ok1 {
		if bi, ok2 := _pull_val_as_i64(b); ok2 {
			if ai < bi {
				return -1, true
			}
			if ai > bi {
				return 1, true
			}
			return 0, true
		}
	}
	#partial switch va in a {
	case string:
		if vb, is_s := b.(string); is_s {
			return strings.compare(va, vb), true
		}
	case f64:
		if vb, is_f := b.(f64); is_f {
			if va < vb {
				return -1, true
			}
			if va > vb {
				return 1, true
			}
			return 0, true
		}
	}
	return 0, false
}
