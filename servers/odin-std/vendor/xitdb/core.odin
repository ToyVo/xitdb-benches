package xitdb

import "base:runtime"
import "core:encoding/endian"
import "core:io"
import "core:mem"
import vmem "core:mem/virtual"
import "core:os"

DEFAULT_BUFFER_SIZE :: 2 * 1024 * 1024

when size_of(int) >= 8 {
	DEFAULT_VMEM_RESERVE_SIZE :: 1 << 30 // 1 GiB virtual reservation on 64-bit platforms
} else {
	DEFAULT_VMEM_RESERVE_SIZE :: 128 << 20 // 128 MiB on 32-bit platforms
}

// Core_Memory stores a xitdb database in a contiguous byte array in memory.
// When initialized via core_memory_init / core_memory_init_from_bytes, it reserves a
// fixed virtual address space (vmem_reserved > 0) and commits physical pages on demand
// so raw_data(buf) never moves across appends, enabling lock-free concurrent readers.
Core_Memory :: struct {
	buf:           [dynamic]u8,
	pos:           i64,
	max_size:      Maybe(i64),
	allocator:     runtime.Allocator,
	vmem_reserved: int,
}

// Core_File stores a xitdb database directly on an OS file handle.
Core_File :: struct {
	file:  ^os.File,
	fsync: bool,
}

// Core_Buffered_File wraps an OS file handle with an in-memory contiguous write window
// matching xitdb's CoreBufferedFile semantics.
Core_Buffered_File :: struct {
	memory:          Core_Memory,
	memory_max_size: i64,
	memory_pos:      i64,
	pos:             i64,
	file:            Core_File,
	file_len:        Maybe(i64),
}

// Core is the unified storage backend union.
Core :: union {
	Core_Memory,
	Core_File,
	Core_Buffered_File,
}

@(private)
_vmem_align_page :: #force_inline proc(size: int) -> int {
	page_sz := int(mem.PAGE_SIZE)
	if page_sz <= 0 {
		page_sz = 4096
	}
	return mem.align_forward_int(max(size, page_sz), page_sz)
}

core_memory_init :: proc(allocator := context.allocator, reserve_size: int = DEFAULT_VMEM_RESERVE_SIZE) -> Core {
	if reserve_size > 0 {
		aligned_reserve := _vmem_align_page(reserve_size)
		if reserved_slice, r_err := vmem.reserve(uint(aligned_reserve)); r_err == .None && raw_data(reserved_slice) != nil {
			initial_commit := min(_vmem_align_page(4096), aligned_reserve)
			if c_err := vmem.commit(raw_data(reserved_slice), uint(initial_commit)); c_err == .None {
				raw_arr := runtime.Raw_Dynamic_Array{
					data      = raw_data(reserved_slice),
					len       = 0,
					cap       = initial_commit,
					allocator = runtime.nil_allocator(),
				}
				return Core_Memory{
					buf           = transmute([dynamic]u8)raw_arr,
					pos           = 0,
					allocator     = allocator,
					vmem_reserved = aligned_reserve,
				}
			}
			vmem.release(raw_data(reserved_slice), uint(aligned_reserve))
		}
	}
	return Core_Memory{
		buf       = make([dynamic]u8, 0, 1024, allocator),
		pos       = 0,
		allocator = allocator,
	}
}

core_memory_init_from_bytes :: proc(data: []u8, allocator := context.allocator, reserve_size: int = DEFAULT_VMEM_RESERVE_SIZE) -> Core {
	c := core_memory_init(allocator, max(reserve_size, len(data)))
	if len(data) > 0 {
		m := &c.(Core_Memory)
		if err := _memory_resize(m, len(data)); err == nil {
			copy(m.buf[:len(data)], data)
		}
	}
	return c
}

core_memory_bytes :: proc(c: ^Core) -> []u8 {
	#partial switch &v in c {
	case Core_Memory:
		return v.buf[:]
	}
	return nil
}

core_file_init :: proc(file: ^os.File, fsync := true) -> Core {
	return Core_File{file = file, fsync = fsync}
}

core_memory_from_bytes :: proc(data: []u8, allocator := context.allocator) -> Core {
	return core_memory_init_from_bytes(data, allocator)
}

core_file_open :: proc(path: string, flags := os.File_Flags{.Read, .Write, .Create}, fsync := true) -> (c: Core, err: Error) {
	f := os.open(path, flags, os.Permissions_Default_File) or_return
	return Core_File{file = f, fsync = fsync}, nil
}

core_buffered_file_init :: proc(file: ^os.File, buffer_size: i64 = DEFAULT_BUFFER_SIZE, fsync := true, allocator := context.allocator) -> Core {
	sz := buffer_size if buffer_size > 0 else DEFAULT_BUFFER_SIZE
	return Core_Buffered_File{
		memory = Core_Memory{
			buf       = make([dynamic]u8, 0, int(min(sz, 65536)), allocator),
			pos       = 0,
			allocator = allocator,
		},
		memory_max_size = sz,
		memory_pos      = 0,
		pos             = 0,
		file            = Core_File{file = file, fsync = fsync},
		file_len        = nil,
	}
}

core_buffered_file_open :: proc(path: string, buffer_size: i64 = DEFAULT_BUFFER_SIZE, flags := os.File_Flags{.Read, .Write, .Create}, fsync := true, allocator := context.allocator) -> (c: Core, err: Error) {
	f := os.open(path, flags, os.Permissions_Default_File) or_return
	return core_buffered_file_init(f, buffer_size, fsync, allocator), nil
}

core_destroy :: proc(c: ^Core, close_file := false) -> Error {
	switch &v in c {
	case Core_Memory:
		if v.vmem_reserved > 0 {
			if raw_data(v.buf) != nil {
				vmem.release(raw_data(v.buf), uint(v.vmem_reserved))
			}
			v.buf = nil
			v.vmem_reserved = 0
		} else {
			delete(v.buf)
			v.buf = nil
		}
		v.pos = 0
	case Core_File:
		if close_file && v.file != nil {
			os.close(v.file) or_return
			v.file = nil
		}
	case Core_Buffered_File:
		_ = _buffered_flush(&v)
		if v.memory.vmem_reserved > 0 {
			if raw_data(v.memory.buf) != nil {
				vmem.release(raw_data(v.memory.buf), uint(v.memory.vmem_reserved))
			}
			v.memory.buf = nil
			v.memory.vmem_reserved = 0
		} else {
			delete(v.memory.buf)
			v.memory.buf = nil
		}
		if close_file && v.file.file != nil {
			os.close(v.file.file) or_return
			v.file.file = nil
		}
	}
	return nil
}

@(private)
_buffered_write_to_file :: proc(bf: ^Core_Buffered_File, pos: i64, data: []u8) -> Error {
	cached_len := bf.file_len
	bf.file_len = nil
	os.seek(bf.file.file, pos, .Start) or_return
	written := 0
	for written < len(data) {
		n := os.write(bf.file.file, data[written:]) or_return
		if n == 0 {
			return io.Error.Short_Write
		}
		written += n
	}
	if cl, ok := cached_len.?; ok {
		bf.file_len = max(cl, pos + i64(len(data)))
	}
	return nil
}

@(private)
_buffered_flush :: proc(bf: ^Core_Buffered_File) -> Error {
	bf.file_len = nil
	if len(bf.memory.buf) > 0 {
		_buffered_write_to_file(bf, bf.memory_pos, bf.memory.buf[:]) or_return
		clear(&bf.memory.buf)
	}
	return nil
}

core_length :: proc(c: ^Core) -> (length: i64, err: Error) {
	switch &v in c {
	case Core_Memory:
		return i64(len(v.buf)), nil
	case Core_File:
		return os.file_size(v.file)
	case Core_Buffered_File:
		flen: i64
		if fl, ok := v.file_len.?; ok {
			flen = fl
		} else {
			flen = os.file_size(v.file.file) or_return
		}
		buf_size := i64(len(v.memory.buf))
		if buf_size == 0 {
			return flen, nil
		}
		return max(v.memory_pos + buf_size, flen), nil
	}
	return 0, .Invalid_Database
}

core_seek_to :: proc(c: ^Core, pos: i64) -> Error {
	if pos < 0 {
		return .Expected_Unsigned_Long
	}
	switch &v in c {
	case Core_Memory:
		v.pos = pos
		return nil
	case Core_File:
		os.seek(v.file, pos, .Start) or_return
		return nil
	case Core_Buffered_File:
		v.pos = pos
		return nil
	}
	return .Invalid_Database
}

core_position :: proc(c: ^Core) -> (pos: i64, err: Error) {
	switch &v in c {
	case Core_Memory:
		return v.pos, nil
	case Core_File:
		return os.seek(v.file, 0, .Current)
	case Core_Buffered_File:
		return v.pos, nil
	}
	return 0, .Invalid_Database
}

core_flush :: proc(c: ^Core) -> Error {
	switch &v in c {
	case Core_Memory:
		return nil
	case Core_File:
		return os.flush(v.file)
	case Core_Buffered_File:
		_buffered_flush(&v) or_return
		return os.flush(v.file.file)
	}
	return .Invalid_Database
}

core_sync :: proc(c: ^Core) -> Error {
	switch &v in c {
	case Core_Memory:
		return nil
	case Core_File:
		if !v.fsync {
			return nil
		}
		return os.sync(v.file)
	case Core_Buffered_File:
		_buffered_flush(&v) or_return
		if !v.file.fsync {
			return nil
		}
		return os.sync(v.file.file)
	}
	return .Invalid_Database
}

core_set_length :: proc(c: ^Core, new_len: i64) -> Error {
	if new_len < 0 {
		return .Expected_Unsigned_Long
	}
	switch &v in c {
	case Core_Memory:
		if new_len > i64(len(v.buf)) {
			return Xitdb_Error.Invalid_Offset
		}
		if v.vmem_reserved > 0 {
			raw_arr := (^runtime.Raw_Dynamic_Array)(&v.buf)
			raw_arr.len = int(new_len)
		} else {
			resize(&v.buf, int(new_len))
		}
		if v.pos > new_len {
			v.pos = new_len
		}
		return nil
	case Core_File:
		err := os.truncate(v.file, new_len)
		if err != nil {
			// Read-only file handles ignore setLength just like Zig/Go xitdb.
			return nil
		}
		pos := os.seek(v.file, 0, .Current) or_return
		if pos > new_len {
			os.seek(v.file, new_len, .Start) or_return
		}
		return nil
	case Core_Buffered_File:
		buf_size := i64(len(v.memory.buf))
		if new_len <= v.memory_pos {
			clear(&v.memory.buf)
		} else if new_len < v.memory_pos + buf_size {
			new_buf_len := int(new_len - v.memory_pos)
			if v.memory.vmem_reserved > 0 {
				raw_arr := (^runtime.Raw_Dynamic_Array)(&v.memory.buf)
				raw_arr.len = new_buf_len
			} else {
				resize(&v.memory.buf, new_buf_len)
			}
		}
		v.file_len = nil
		_ = os.truncate(v.file.file, new_len)
		if v.pos > new_len {
			v.pos = new_len
		}
		return nil
	}
	return .Invalid_Database
}

// Read up to len(p) bytes into p. Returns 0, io.Error.EOF at end of stream.
core_read :: proc(c: ^Core, p: []u8) -> (read_n: int, err: Error) {
	if len(p) == 0 {
		return 0, nil
	}
	switch &v in c {
	case Core_Memory:
		if v.pos >= i64(len(v.buf)) {
			return 0, io.Error.EOF
		}
		avail := int(i64(len(v.buf)) - v.pos)
		to_read := min(len(p), avail)
		copy(p[:to_read], v.buf[int(v.pos):int(v.pos) + to_read])
		v.pos += i64(to_read)
		return to_read, nil
	case Core_File:
		n, r_err := os.read(v.file, p)
		if r_err == io.Error.EOF {
			return n, io.Error.EOF
		}
		return n, r_err
	case Core_Buffered_File:
		buf_len := i64(len(v.memory.buf))
		if buf_len > 0 && v.pos >= v.memory_pos && v.pos < v.memory_pos + buf_len {
			mem_off := int(v.pos - v.memory_pos)
			size := min(len(p), int(buf_len) - mem_off)
			copy(p[:size], v.memory.buf[mem_off:mem_off + size])
			v.pos += i64(size)
			return size, nil
		}
		os.seek(v.file.file, v.pos, .Start) or_return
		max_size := len(p)
		if buf_len > 0 && v.pos < v.memory_pos {
			max_size = min(len(p), int(v.memory_pos - v.pos))
		}
		n, r_err := os.read(v.file.file, p[:max_size])
		v.pos += i64(n)
		if r_err == io.Error.EOF {
			return n, io.Error.EOF
		}
		return n, r_err
	}
	return 0, .Invalid_Database
}

// Read exactly len(p) bytes or return an error (.Unexpected_EOF on short read).
core_read_exact :: proc(c: ^Core, p: []u8) -> Error {
	if len(p) == 0 {
		return nil
	}
	#partial switch &v in c {
	case Core_Memory:
		end_pos := v.pos + i64(len(p))
		if v.pos < 0 || end_pos > i64(len(v.buf)) {
			v.pos = i64(len(v.buf))
			return Xitdb_Error.Unexpected_EOF
		}
		copy(p, v.buf[int(v.pos):int(end_pos)])
		v.pos = end_pos
		return nil
	}
	total := 0
	for total < len(p) {
		n, err := core_read(c, p[total:])
		total += n
		if err != nil {
			if err == io.Error.EOF {
				if total == len(p) {
					return nil
				}
				return Xitdb_Error.Unexpected_EOF
			}
			return err
		}
		if n == 0 {
			return Xitdb_Error.Unexpected_EOF
		}
	}
	return nil
}

// Stateless positional read up to len(p) bytes at `pos` without mutating any cursor position.
core_read_at :: proc(c: ^Core, pos: i64, p: []u8) -> (read_n: int, err: Error) {
	if pos < 0 {
		return 0, Xitdb_Error.Expected_Unsigned_Long
	}
	if len(p) == 0 {
		return 0, nil
	}
	switch &v in c {
	case Core_Memory:
		if pos >= i64(len(v.buf)) {
			return 0, io.Error.EOF
		}
		avail := int(i64(len(v.buf)) - pos)
		to_read := min(len(p), avail)
		copy(p[:to_read], v.buf[int(pos):int(pos) + to_read])
		return to_read, nil
	case Core_File:
		n, r_err := os.read_at(v.file, p, pos)
		if r_err == io.Error.EOF {
			return n, io.Error.EOF
		}
		return n, r_err
	case Core_Buffered_File:
		buf_len := i64(len(v.memory.buf))
		if buf_len > 0 && pos >= v.memory_pos && pos < v.memory_pos + buf_len {
			mem_off := int(pos - v.memory_pos)
			size := min(len(p), int(buf_len) - mem_off)
			copy(p[:size], v.memory.buf[mem_off:mem_off + size])
			return size, nil
		}
		max_size := len(p)
		if buf_len > 0 && pos < v.memory_pos {
			max_size = min(len(p), int(v.memory_pos - pos))
		}
		n, r_err := os.read_at(v.file.file, p[:max_size], pos)
		if r_err == io.Error.EOF {
			return n, io.Error.EOF
		}
		return n, r_err
	}
	return 0, .Invalid_Database
}

// Stateless positional read of exactly len(p) bytes at `pos` without mutating any cursor position.
core_read_exact_at :: proc(c: ^Core, pos: i64, p: []u8) -> Error {
	if pos < 0 {
		return Xitdb_Error.Expected_Unsigned_Long
	}
	if len(p) == 0 {
		return nil
	}
	#partial switch &v in c {
	case Core_Memory:
		end_pos := pos + i64(len(p))
		if end_pos > i64(len(v.buf)) {
			return Xitdb_Error.Unexpected_EOF
		}
		copy(p, v.buf[int(pos):int(end_pos)])
		return nil
	case Core_Buffered_File:
		buf_len := i64(len(v.memory.buf))
		if buf_len > 0 && pos >= v.memory_pos && pos + i64(len(p)) <= v.memory_pos + buf_len {
			mem_off := int(pos - v.memory_pos)
			copy(p, v.memory.buf[mem_off : mem_off + len(p)])
			return nil
		}
	}
	total := 0
	for total < len(p) {
		n, err := core_read_at(c, pos + i64(total), p[total:])
		total += n
		if err != nil {
			if err == io.Error.EOF {
				if total == len(p) {
					return nil
				}
				return Xitdb_Error.Unexpected_EOF
			}
			return err
		}
		if n == 0 {
			return Xitdb_Error.Unexpected_EOF
		}
	}
	return nil
}

// Write all bytes of `p` to `c`.
@(private)
_memory_reserve :: #force_inline proc(m: ^Core_Memory, want_cap: int) -> Error {
	if want_cap <= cap(m.buf) {
		return nil
	}
	if max_sz, ok := m.max_size.?; ok && i64(want_cap) > max_sz {
		return Xitdb_Error.Write_Failed
	}
	if m.vmem_reserved > 0 {
		if want_cap > m.vmem_reserved {
			return Xitdb_Error.Write_Failed
		}
		raw_arr := (^runtime.Raw_Dynamic_Array)(&m.buf)
		cur_cap := raw_arr.cap
		new_cap := max(cur_cap * 2, want_cap, 65536)
		new_cap = min(_vmem_align_page(new_cap), m.vmem_reserved)
		commit_ptr := rawptr(uintptr(raw_arr.data) + uintptr(cur_cap))
		commit_size := uint(new_cap - cur_cap)
		if c_err := vmem.commit(commit_ptr, commit_size); c_err != .None {
			return Xitdb_Error.Write_Failed
		}
		raw_arr.cap = new_cap
		return nil
	}
	if alloc_err := reserve(&m.buf, want_cap); alloc_err != nil {
		return Xitdb_Error.Write_Failed
	}
	return nil
}

@(private)
_memory_resize :: #force_inline proc(m: ^Core_Memory, end_pos: int) -> Error {
	if end_pos > len(m.buf) {
		if max_sz, ok := m.max_size.?; ok && i64(end_pos) > max_sz {
			return Xitdb_Error.Write_Failed
		}
		if m.vmem_reserved > 0 {
			if end_pos > cap(m.buf) {
				_memory_reserve(m, end_pos) or_return
			}
			raw_arr := (^runtime.Raw_Dynamic_Array)(&m.buf)
			raw_arr.len = end_pos
			return nil
		}
		if alloc_err := resize(&m.buf, end_pos); alloc_err != nil {
			return Xitdb_Error.Write_Failed
		}
	}
	return nil
}

core_write_all :: proc(c: ^Core, p: []u8) -> Error {
	if len(p) == 0 {
		return nil
	}
	switch &v in c {
	case Core_Memory:
		end_pos := int(v.pos) + len(p)
		_memory_resize(&v, end_pos) or_return
		copy(v.buf[int(v.pos):end_pos], p)
		v.pos = i64(end_pos)
		return nil
	case Core_File:
		written := 0
		for written < len(p) {
			n := os.write(v.file, p[written:]) or_return
			if n == 0 {
				return io.Error.Short_Write
			}
			written += n
		}
		return nil
	case Core_Buffered_File:
		n := i64(len(p))
		buf_size := i64(len(v.memory.buf))
		if buf_size == 0 ||
		   v.pos > v.memory_pos + buf_size ||
		   (v.pos >= v.memory_pos && v.pos - v.memory_pos + n > v.memory_max_size) {
			_buffered_flush(&v) or_return
			v.memory_pos = v.pos
		}
		if v.pos >= v.memory_pos && v.pos - v.memory_pos + n <= v.memory_max_size {
			fl: i64
			if existing_fl, ok := v.file_len.?; ok {
				fl = existing_fl
			} else {
				fl = os.file_size(v.file.file) or_return
			}
			rel_off := int(v.pos - v.memory_pos)
			end_off := rel_off + len(p)
			_memory_resize(&v.memory, end_off) or_return
			v.file_len = fl
			copy(v.memory.buf[rel_off:end_off], p)
		} else {
			if v.pos < v.memory_pos + i64(len(v.memory.buf)) && v.pos + n > v.memory_pos {
				_buffered_flush(&v) or_return
			}
			if _, ok := v.file_len.?; !ok {
				v.file_len = os.file_size(v.file.file) or_return
			}
			_buffered_write_to_file(&v, v.pos, p) or_return
		}
		v.pos += n
		return nil
	}
	return .Invalid_Database
}

// Returns a read-only slice of `n` bytes at `pos` when backed by an in-memory buffer,
// or `(nil, false, nil)` when file I/O is required.
core_slice_at :: #force_inline proc(c: ^Core, pos: i64, n: int) -> (slice: []u8, in_mem: bool, err: Error) {
	#partial switch &v in c {
	case Core_Memory:
		p := int(pos)
		if p < 0 || p + n > len(v.buf) {
			return nil, true, Xitdb_Error.Unexpected_EOF
		}
		return v.buf[p : p + n], true, nil
	case Core_Buffered_File:
		buf_len := i64(len(v.memory.buf))
		if buf_len > 0 && pos >= v.memory_pos && pos + i64(n) <= v.memory_pos + buf_len {
			mem_off := int(pos - v.memory_pos)
			return v.memory.buf[mem_off : mem_off + n], true, nil
		}
	}
	return nil, false, nil
}

core_read_byte :: proc(c: ^Core) -> (v: u8, err: Error) {
	b: [1]u8 = ---
	core_read_exact(c, b[:]) or_return
	return b[0], nil
}

core_write_byte :: proc(c: ^Core, v: u8) -> Error {
	b := [1]u8{v}
	return core_write_all(c, b[:])
}

core_read_u16 :: proc(c: ^Core) -> (v: u16, err: Error) {
	b: [2]u8 = ---
	core_read_exact(c, b[:]) or_return
	return endian.unchecked_get_u16be(b[:]), nil
}

core_write_u16 :: proc(c: ^Core, v: u16) -> Error {
	b: [2]u8 = ---
	endian.unchecked_put_u16be(b[:], v)
	return core_write_all(c, b[:])
}

core_read_u32 :: proc(c: ^Core) -> (v: u32, err: Error) {
	b: [4]u8 = ---
	core_read_exact(c, b[:]) or_return
	return endian.unchecked_get_u32be(b[:]), nil
}

core_write_u32 :: proc(c: ^Core, v: u32) -> Error {
	b: [4]u8 = ---
	endian.unchecked_put_u32be(b[:], v)
	return core_write_all(c, b[:])
}

core_read_long :: #force_inline proc(c: ^Core) -> (res: i64, err: Error) {
	res = core_read_i64(c) or_return
	if res < 0 {
		return 0, Xitdb_Error.Expected_Unsigned_Long
	}
	return res, nil
}

core_write_long :: #force_inline proc(c: ^Core, v: i64) -> Error {
	if v < 0 {
		return Xitdb_Error.Expected_Unsigned_Long
	}
	return core_write_i64(c, v)
}

core_read_i64 :: #force_inline proc(c: ^Core) -> (res: i64, err: Error) {
	#partial switch &v in c {
	case Core_Memory:
		end_pos := v.pos + 8
		if v.pos < 0 || end_pos > i64(len(v.buf)) {
			v.pos = i64(len(v.buf))
			return 0, Xitdb_Error.Unexpected_EOF
		}
		res = i64(endian.unchecked_get_u64be(v.buf[int(v.pos):int(end_pos)]))
		v.pos = end_pos
		return res, nil
	case Core_Buffered_File:
		buf_len := i64(len(v.memory.buf))
		if buf_len > 0 && v.pos >= v.memory_pos && v.pos + 8 <= v.memory_pos + buf_len {
			mem_off := int(v.pos - v.memory_pos)
			res = i64(endian.unchecked_get_u64be(v.memory.buf[mem_off : mem_off + 8]))
			v.pos += 8
			return res, nil
		}
	}
	b: [8]u8 = ---
	core_read_exact(c, b[:]) or_return
	return i64(endian.unchecked_get_u64be(b[:])), nil
}

core_write_i64 :: #force_inline proc(c: ^Core, v: i64) -> Error {
	#partial switch &m in c {
	case Core_Memory:
		pos := int(m.pos)
		end_pos := pos + 8
		_memory_resize(&m, end_pos) or_return
		endian.unchecked_put_u64be(m.buf[pos:end_pos], u64(v))
		m.pos = i64(end_pos)
		return nil
	}
	b: [8]u8 = ---
	endian.unchecked_put_u64be(b[:], u64(v))
	return core_write_all(c, b[:])
}

core_read_slot_raw :: #force_inline proc(c: ^Core) -> (s: Slot, err: Error) {
	#partial switch &v in c {
	case Core_Memory:
		end_pos := v.pos + SLOT_LENGTH
		if v.pos < 0 || end_pos > i64(len(v.buf)) {
			v.pos = i64(len(v.buf))
			return {}, Xitdb_Error.Unexpected_EOF
		}
		s = slot_from_slice_raw(v.buf[int(v.pos):int(end_pos)])
		v.pos = end_pos
		return s, nil
	case Core_Buffered_File:
		buf_len := i64(len(v.memory.buf))
		if buf_len > 0 && v.pos >= v.memory_pos && v.pos + SLOT_LENGTH <= v.memory_pos + buf_len {
			mem_off := int(v.pos - v.memory_pos)
			s = slot_from_slice_raw(v.memory.buf[mem_off : mem_off + SLOT_LENGTH])
			v.pos += SLOT_LENGTH
			return s, nil
		}
	}
	buf: [SLOT_LENGTH]u8 = ---
	core_read_exact(c, buf[:]) or_return
	return slot_from_bytes_raw(buf), nil
}

core_read_slot :: #force_inline proc(c: ^Core) -> (s: Slot, err: Error) {
	s = core_read_slot_raw(c) or_return
	tag_validate(s.tag) or_return
	return s, nil
}

core_write_slot :: #force_inline proc(c: ^Core, s: Slot) -> Error {
	#partial switch &v in c {
	case Core_Memory:
		pos := int(v.pos)
		end_pos := pos + SLOT_LENGTH
		_memory_resize(&v, end_pos) or_return
		full_bit := u8(0x80) if s.full else u8(0)
		v.buf[pos] = full_bit | (u8(s.tag) & 0x7f)
		endian.unchecked_put_u64be(v.buf[pos + 1 : end_pos], u64(s.value))
		v.pos = i64(end_pos)
		return nil
	}
	buf := slot_to_bytes(s)
	return core_write_all(c, buf[:])
}

core_read_byte_at :: #force_inline proc(c: ^Core, pos: i64) -> (v: u8, err: Error) {
	#partial switch &m in c {
	case Core_Memory:
		if pos < 0 || pos >= i64(len(m.buf)) {
			return 0, Xitdb_Error.Unexpected_EOF
		}
		return m.buf[int(pos)], nil
	case Core_Buffered_File:
		buf_len := i64(len(m.memory.buf))
		if buf_len > 0 && pos >= m.memory_pos && pos < m.memory_pos + buf_len {
			return m.memory.buf[int(pos - m.memory_pos)], nil
		}
	}
	b: [1]u8 = ---
	core_read_exact_at(c, pos, b[:]) or_return
	return b[0], nil
}

core_read_u16_at :: #force_inline proc(c: ^Core, pos: i64) -> (v: u16, err: Error) {
	b: [2]u8 = ---
	core_read_exact_at(c, pos, b[:]) or_return
	return endian.unchecked_get_u16be(b[:]), nil
}

core_read_u32_at :: #force_inline proc(c: ^Core, pos: i64) -> (v: u32, err: Error) {
	b: [4]u8 = ---
	core_read_exact_at(c, pos, b[:]) or_return
	return endian.unchecked_get_u32be(b[:]), nil
}

core_read_i64_at :: #force_inline proc(c: ^Core, pos: i64) -> (res: i64, err: Error) {
	#partial switch &v in c {
	case Core_Memory:
		end_pos := pos + 8
		if pos < 0 || end_pos > i64(len(v.buf)) {
			return 0, Xitdb_Error.Unexpected_EOF
		}
		return i64(endian.unchecked_get_u64be(v.buf[int(pos):int(end_pos)])), nil
	case Core_Buffered_File:
		buf_len := i64(len(v.memory.buf))
		if buf_len > 0 && pos >= v.memory_pos && pos + 8 <= v.memory_pos + buf_len {
			mem_off := int(pos - v.memory_pos)
			return i64(endian.unchecked_get_u64be(v.memory.buf[mem_off : mem_off + 8])), nil
		}
	}
	b: [8]u8 = ---
	core_read_exact_at(c, pos, b[:]) or_return
	return i64(endian.unchecked_get_u64be(b[:])), nil
}

core_read_long_at :: #force_inline proc(c: ^Core, pos: i64) -> (res: i64, err: Error) {
	res = core_read_i64_at(c, pos) or_return
	if res < 0 {
		return 0, Xitdb_Error.Expected_Unsigned_Long
	}
	return res, nil
}

core_read_slot_raw_at :: #force_inline proc(c: ^Core, pos: i64) -> (s: Slot, err: Error) {
	#partial switch &v in c {
	case Core_Memory:
		end_pos := pos + SLOT_LENGTH
		if pos < 0 || end_pos > i64(len(v.buf)) {
			return {}, Xitdb_Error.Unexpected_EOF
		}
		return slot_from_slice_raw(v.buf[int(pos):int(end_pos)]), nil
	case Core_Buffered_File:
		buf_len := i64(len(v.memory.buf))
		if buf_len > 0 && pos >= v.memory_pos && pos + SLOT_LENGTH <= v.memory_pos + buf_len {
			mem_off := int(pos - v.memory_pos)
			return slot_from_slice_raw(v.memory.buf[mem_off : mem_off + SLOT_LENGTH]), nil
		}
	}
	buf: [SLOT_LENGTH]u8 = ---
	core_read_exact_at(c, pos, buf[:]) or_return
	return slot_from_bytes_raw(buf), nil
}

core_read_slot_at :: #force_inline proc(c: ^Core, pos: i64) -> (s: Slot, err: Error) {
	s = core_read_slot_raw_at(c, pos) or_return
	tag_validate(s.tag) or_return
	return s, nil
}

