package xitdb

import "base:intrinsics"
import "core:encoding/endian"
import "core:hash"
import "core:io"
import "core:os"
import "core:simd"
import "core:simd/x86"

// Protocol constants (wire-compatible with xitdb v1).
VERSION                    :: u16(1)
MAGIC_NUMBER               :: [3]u8{'x', 'i', 't'}
BIT_COUNT                  :: 4
SLOT_COUNT                 :: 1 << BIT_COUNT // 16
MASK                       :: u64(SLOT_COUNT - 1)
SLOT_LENGTH                :: 9
INDEX_BLOCK_SIZE           :: SLOT_LENGTH * SLOT_COUNT // 144
MAX_BRANCH_LENGTH          :: 16

// B-Tree constants (used by Linked_Array_List, Sorted_Map, Sorted_Set).
BTREE_SLOT_COUNT         :: 16
BTREE_SPLIT_COUNT        :: (BTREE_SLOT_COUNT + 1) / 2 // 8
BTREE_NODE_HEADER_SIZE   :: 2
BTREE_LEAF_BLOCK_SIZE    :: BTREE_NODE_HEADER_SIZE + SLOT_LENGTH * BTREE_SLOT_COUNT // 146
BTREE_BRANCH_BLOCK_SIZE  :: BTREE_NODE_HEADER_SIZE + (SLOT_LENGTH + 8) * BTREE_SLOT_COUNT // 274
SORTED_LEAF_BLOCK_SIZE   :: BTREE_LEAF_BLOCK_SIZE // 146
SORTED_BRANCH_BLOCK_SIZE :: BTREE_NODE_HEADER_SIZE + (SLOT_LENGTH * 2 + 8) * BTREE_SLOT_COUNT // 418

// Header and Trailer offsets.
HEADER_LENGTH       :: 20
ROOT_HEADER_START   :: 20
ROOT_HEADER_LENGTH  :: 17
ROOT_HEADER_END     :: ROOT_HEADER_START + ROOT_HEADER_LENGTH // 37
ROOT_TRAILER_LENGTH :: 25

ARRAY_LIST_HEADER_LENGTH :: 16
BTREE_HEADER_LENGTH      :: 16
KEY_VALUE_PAIR_BASE_LEN  :: 18
SORTED_KEY_VALUE_LEN     :: 18
SORTED_KV_PAIR_LENGTH    :: 18
ITERATOR_STACK_SIZE      :: 16

// Tag identifies the data structure or primitive stored in a Slot.
Tag :: enum u8 {
	None              = 0,
	Index             = 1,
	Array_List        = 2,
	Linked_Array_List = 3,
	Hash_Map          = 4,
	KV_Pair           = 5,
	Bytes             = 6,
	Short_Bytes       = 7,
	Uint              = 8,
	Int               = 9,
	Float             = 10,
	Hash_Set          = 11,
	Counted_Hash_Map  = 12,
	Counted_Hash_Set  = 13,
	Sorted_Map        = 14,
	Sorted_Set        = 15,
	Sorted_KV_Pair    = 16,
}

MAX_TAG_VALUE :: u8(Tag.Sorted_KV_Pair)

tag_validate :: #force_inline proc(t: Tag) -> Error {
	if u8(t) > MAX_TAG_VALUE {
		return .Unexpected_Tag
	}
	return nil
}

// Write_Mode controls how a path traversal resolves a slot.
Write_Mode :: enum {
	Read_Only,
	Read_Write,
}

// Xitdb_Error enumerates database-specific failure modes.
Xitdb_Error :: enum {
	None = 0,
	Expected_Unsigned_Long,
	Invalid_Database,
	Invalid_Version,
	Invalid_Hash_Size,
	Invalid_Format_Tag_Size,
	Invalid_Range,
	Invalid_BTree_Node_Kind,
	Invalid_BTree_Node,
	Invalid_Offset_Table_Size,
	Truncated_Database,
	Target_Not_Empty,
	Key_Offset_Exceeded,
	Max_Shift_Exceeded,
	Key_Not_Found,
	Unexpected_Tag,
	Write_Not_Allowed,
	Cursor_Not_Writeable,
	Expected_Tx_Start,
	Expired_Transaction,
	Nested_Top_Level_Write,
	Frozen_Slot,
	Frozen_Bytes,
	Expected_Slot_Position,
	Invalid_Offset,
	Path_Part_Must_Be_At_End,
	Stream_Too_Long,
	End_Of_Stream,
	Unexpected_Writer_Position,
	Write_Failed,
	Unexpected_EOF,
	Unreachable,
}

// Error is the unified error union returned by xitdb operations.
Error :: union #shared_nil {
	Xitdb_Error,
	os.Error,
	io.Error,
}

// Hasher computes a key digest of `hash_size` bytes.
Hasher :: struct {
	hash_proc: proc(data: []u8, out_hash: []u8, user_data: rawptr),
	hash_size: u16,
	id:        u32,
	file_id:   u64,
	user_data: rawptr,
}

// Hash_ID helpers (4-byte ASCII identifier stored as big-endian u32).
bytes_to_id :: proc(buf: [4]u8) -> u32 {
	b := buf
	res, _ := endian.get_u32(b[:], .Big)
	return res
}

string_to_id :: proc(s: string) -> u32 {
	b: [4]u8
	copy(b[:], transmute([]u8)s)
	return bytes_to_id(b)
}

id_to_bytes :: proc(id: u32) -> [4]u8 {
	b: [4]u8
	endian.put_u32(b[:], .Big, id)
	return b
}

when ODIN_ARCH == .amd64 {
	@(private = "file")
	_has_sha_ni: bool

	@(init, private = "file")
	_init_sha_ni :: proc "contextless" () {
		max_id, _, _, _ := intrinsics.x86_cpuid(0, 0)
		if max_id < 7 {
			return
		}
		_, _, ecx1, edx1 := intrinsics.x86_cpuid(1, 0)
		has_sse2  := ((edx1 >> 26) & 1) != 0
		has_ssse3 := ((ecx1 >> 9)  & 1) != 0
		has_sse41 := ((ecx1 >> 19) & 1) != 0
		_, ebx7, _, _ := intrinsics.x86_cpuid(7, 0)
		has_sha   := ((ebx7 >> 29) & 1) != 0
		_has_sha_ni = has_sse2 && has_ssse3 && has_sse41 && has_sha
	}

	@(private = "file")
	SHA1_SHUF_MASK   :: x86.__m128i{0x08090a0b0c0d0e0f, 0x0001020304050607}
	@(private = "file")
	SHA256_SHUF_MASK :: x86.__m128i{0x0405060700010203, 0x0c0d0e0f08090a0b}

	@(private = "file", enable_target_feature = "sse2,ssse3,sse4.1,sha")
	sha1_transf_hw :: proc "contextless" (state: ^[5]u32, data: []u8) #no_bounds_check {
		// Load initial state: state[0..3] = A, B, C, D; state[4] = E
		abcd := intrinsics.unaligned_load((^x86.__m128i)(&state[0]))
		abcd = x86._mm_shuffle_epi32(abcd, 0x1B) // lane 3..0 = A, B, C, D
		e0 := x86._mm_set_epi32(i32(state[4]), 0, 0, 0)

		data := data
		for len(data) >= 64 {
			abcd_save := abcd
			e0_save := e0

			// Rounds 0..3
			msg0 := intrinsics.unaligned_load((^x86.__m128i)(raw_data(data[0:])))
			msg0 = x86._mm_shuffle_epi8(msg0, SHA1_SHUF_MASK)
			e0 = x86._mm_add_epi32(e0, msg0)
			e1 := abcd
			abcd = x86._mm_sha1rnds4_epu32(abcd, e0, 0)

			// Rounds 4..7
			msg1 := intrinsics.unaligned_load((^x86.__m128i)(raw_data(data[16:])))
			msg1 = x86._mm_shuffle_epi8(msg1, SHA1_SHUF_MASK)
			e1 = x86._mm_sha1nexte_epu32(e1, msg1)
			e0 = abcd
			abcd = x86._mm_sha1rnds4_epu32(abcd, e1, 0)
			msg0 = x86._mm_sha1msg1_epu32(msg0, msg1)

			// Rounds 8..11
			msg2 := intrinsics.unaligned_load((^x86.__m128i)(raw_data(data[32:])))
			msg2 = x86._mm_shuffle_epi8(msg2, SHA1_SHUF_MASK)
			e0 = x86._mm_sha1nexte_epu32(e0, msg2)
			e1 = abcd
			abcd = x86._mm_sha1rnds4_epu32(abcd, e0, 0)
			msg1 = x86._mm_sha1msg1_epu32(msg1, msg2)
			msg0 = x86._mm_xor_si128(msg0, msg2)

			// Rounds 12..15
			msg3 := intrinsics.unaligned_load((^x86.__m128i)(raw_data(data[48:])))
			msg3 = x86._mm_shuffle_epi8(msg3, SHA1_SHUF_MASK)
			e1 = x86._mm_sha1nexte_epu32(e1, msg3)
			e0 = abcd
			msg0 = x86._mm_sha1msg2_epu32(msg0, msg3)
			abcd = x86._mm_sha1rnds4_epu32(abcd, e1, 0)
			msg2 = x86._mm_sha1msg1_epu32(msg2, msg3)
			msg1 = x86._mm_xor_si128(msg1, msg3)

			// Rounds 16..19
			e0 = x86._mm_sha1nexte_epu32(e0, msg0)
			e1 = abcd
			msg1 = x86._mm_sha1msg2_epu32(msg1, msg0)
			abcd = x86._mm_sha1rnds4_epu32(abcd, e0, 0)
			msg3 = x86._mm_sha1msg1_epu32(msg3, msg0)
			msg2 = x86._mm_xor_si128(msg2, msg0)

			// Rounds 20..23
			e1 = x86._mm_sha1nexte_epu32(e1, msg1)
			e0 = abcd
			msg2 = x86._mm_sha1msg2_epu32(msg2, msg1)
			abcd = x86._mm_sha1rnds4_epu32(abcd, e1, 1)
			msg0 = x86._mm_sha1msg1_epu32(msg0, msg1)
			msg3 = x86._mm_xor_si128(msg3, msg1)

			// Rounds 24..27
			e0 = x86._mm_sha1nexte_epu32(e0, msg2)
			e1 = abcd
			msg3 = x86._mm_sha1msg2_epu32(msg3, msg2)
			abcd = x86._mm_sha1rnds4_epu32(abcd, e0, 1)
			msg1 = x86._mm_sha1msg1_epu32(msg1, msg2)
			msg0 = x86._mm_xor_si128(msg0, msg2)

			// Rounds 28..31
			e1 = x86._mm_sha1nexte_epu32(e1, msg3)
			e0 = abcd
			msg0 = x86._mm_sha1msg2_epu32(msg0, msg3)
			abcd = x86._mm_sha1rnds4_epu32(abcd, e1, 1)
			msg2 = x86._mm_sha1msg1_epu32(msg2, msg3)
			msg1 = x86._mm_xor_si128(msg1, msg3)

			// Rounds 32..35
			e0 = x86._mm_sha1nexte_epu32(e0, msg0)
			e1 = abcd
			msg1 = x86._mm_sha1msg2_epu32(msg1, msg0)
			abcd = x86._mm_sha1rnds4_epu32(abcd, e0, 1)
			msg3 = x86._mm_sha1msg1_epu32(msg3, msg0)
			msg2 = x86._mm_xor_si128(msg2, msg0)

			// Rounds 36..39
			e1 = x86._mm_sha1nexte_epu32(e1, msg1)
			e0 = abcd
			msg2 = x86._mm_sha1msg2_epu32(msg2, msg1)
			abcd = x86._mm_sha1rnds4_epu32(abcd, e1, 1)
			msg0 = x86._mm_sha1msg1_epu32(msg0, msg1)
			msg3 = x86._mm_xor_si128(msg3, msg1)

			// Rounds 40..43
			e0 = x86._mm_sha1nexte_epu32(e0, msg2)
			e1 = abcd
			msg3 = x86._mm_sha1msg2_epu32(msg3, msg2)
			abcd = x86._mm_sha1rnds4_epu32(abcd, e0, 2)
			msg1 = x86._mm_sha1msg1_epu32(msg1, msg2)
			msg0 = x86._mm_xor_si128(msg0, msg2)

			// Rounds 44..47
			e1 = x86._mm_sha1nexte_epu32(e1, msg3)
			e0 = abcd
			msg0 = x86._mm_sha1msg2_epu32(msg0, msg3)
			abcd = x86._mm_sha1rnds4_epu32(abcd, e1, 2)
			msg2 = x86._mm_sha1msg1_epu32(msg2, msg3)
			msg1 = x86._mm_xor_si128(msg1, msg3)

			// Rounds 48..51
			e0 = x86._mm_sha1nexte_epu32(e0, msg0)
			e1 = abcd
			msg1 = x86._mm_sha1msg2_epu32(msg1, msg0)
			abcd = x86._mm_sha1rnds4_epu32(abcd, e0, 2)
			msg3 = x86._mm_sha1msg1_epu32(msg3, msg0)
			msg2 = x86._mm_xor_si128(msg2, msg0)

			// Rounds 52..55
			e1 = x86._mm_sha1nexte_epu32(e1, msg1)
			e0 = abcd
			msg2 = x86._mm_sha1msg2_epu32(msg2, msg1)
			abcd = x86._mm_sha1rnds4_epu32(abcd, e1, 2)
			msg0 = x86._mm_sha1msg1_epu32(msg0, msg1)
			msg3 = x86._mm_xor_si128(msg3, msg1)

			// Rounds 56..59
			e0 = x86._mm_sha1nexte_epu32(e0, msg2)
			e1 = abcd
			msg3 = x86._mm_sha1msg2_epu32(msg3, msg2)
			abcd = x86._mm_sha1rnds4_epu32(abcd, e0, 2)
			msg1 = x86._mm_sha1msg1_epu32(msg1, msg2)
			msg0 = x86._mm_xor_si128(msg0, msg2)

			// Rounds 60..63
			e1 = x86._mm_sha1nexte_epu32(e1, msg3)
			e0 = abcd
			msg0 = x86._mm_sha1msg2_epu32(msg0, msg3)
			abcd = x86._mm_sha1rnds4_epu32(abcd, e1, 3)
			msg2 = x86._mm_sha1msg1_epu32(msg2, msg3)
			msg1 = x86._mm_xor_si128(msg1, msg3)

			// Rounds 64..67
			e0 = x86._mm_sha1nexte_epu32(e0, msg0)
			e1 = abcd
			msg1 = x86._mm_sha1msg2_epu32(msg1, msg0)
			abcd = x86._mm_sha1rnds4_epu32(abcd, e0, 3)
			msg3 = x86._mm_sha1msg1_epu32(msg3, msg0)
			msg2 = x86._mm_xor_si128(msg2, msg0)

			// Rounds 68..71
			e1 = x86._mm_sha1nexte_epu32(e1, msg1)
			e0 = abcd
			msg2 = x86._mm_sha1msg2_epu32(msg2, msg1)
			abcd = x86._mm_sha1rnds4_epu32(abcd, e1, 3)
			msg3 = x86._mm_xor_si128(msg3, msg1)

			// Rounds 72..75
			e0 = x86._mm_sha1nexte_epu32(e0, msg2)
			e1 = abcd
			msg3 = x86._mm_sha1msg2_epu32(msg3, msg2)
			abcd = x86._mm_sha1rnds4_epu32(abcd, e0, 3)

			// Rounds 76..79
			e1 = x86._mm_sha1nexte_epu32(e1, msg3)
			e0 = abcd
			abcd = x86._mm_sha1rnds4_epu32(abcd, e1, 3)

			// Combine state
			e0 = x86._mm_sha1nexte_epu32(e0, e0_save)
			abcd = x86._mm_add_epi32(abcd, abcd_save)

			data = data[64:]
		}

		abcd = x86._mm_shuffle_epi32(abcd, 0x1B)
		intrinsics.unaligned_store((^x86.__m128i)(&state[0]), abcd)
		state[4] = u32(x86._mm_extract_epi32(e0, 3))
	}

	@(private = "file")
	SHA256_K_0  :: simd.u64x2{0x71374491428a2f98, 0xe9b5dba5b5c0fbcf}
	@(private = "file")
	SHA256_K_1  :: simd.u64x2{0x59f111f13956c25b, 0xab1c5ed5923f82a4}
	@(private = "file")
	SHA256_K_2  :: simd.u64x2{0x12835b01d807aa98, 0x550c7dc3243185be}
	@(private = "file")
	SHA256_K_3  :: simd.u64x2{0x80deb1fe72be5d74, 0xc19bf1749bdc06a7}
	@(private = "file")
	SHA256_K_4  :: simd.u64x2{0xefbe4786e49b69c1, 0x240ca1cc0fc19dc6}
	@(private = "file")
	SHA256_K_5  :: simd.u64x2{0x4a7484aa2de92c6f, 0x76f988da5cb0a9dc}
	@(private = "file")
	SHA256_K_6  :: simd.u64x2{0xa831c66d983e5152, 0xbf597fc7b00327c8}
	@(private = "file")
	SHA256_K_7  :: simd.u64x2{0xd5a79147c6e00bf3, 0x1429296706ca6351}
	@(private = "file")
	SHA256_K_8  :: simd.u64x2{0x2e1b213827b70a85, 0x53380d134d2c6dfc}
	@(private = "file")
	SHA256_K_9  :: simd.u64x2{0x766a0abb650a7354, 0x92722c8581c2c92e}
	@(private = "file")
	SHA256_K_10 :: simd.u64x2{0xa81a664ba2bfe8a1, 0xc76c51a3c24b8b70}
	@(private = "file")
	SHA256_K_11 :: simd.u64x2{0xd6990624d192e819, 0x106aa070f40e3585}
	@(private = "file")
	SHA256_K_12 :: simd.u64x2{0x1e376c0819a4c116, 0x34b0bcb52748774c}
	@(private = "file")
	SHA256_K_13 :: simd.u64x2{0x4ed8aa4a391c0cb3, 0x682e6ff35b9cca4f}
	@(private = "file")
	SHA256_K_14 :: simd.u64x2{0x78a5636f748f82ee, 0x8cc7020884c87814}
	@(private = "file")
	SHA256_K_15 :: simd.u64x2{0xa4506ceb90befffa, 0xc67178f2bef9a3f7}

	@(private = "file", enable_target_feature = "sse2,ssse3,sse4.1,sha")
	sha256_transf_hw :: proc "contextless" (h: ^[8]u32, data: []u8) #no_bounds_check {
		tmp := intrinsics.unaligned_load((^x86.__m128i)(&h[0]))
		state_1 := intrinsics.unaligned_load((^x86.__m128i)(&h[4]))

		tmp = x86._mm_shuffle_epi32(tmp, 0xb1)            // CDAB
		state_1 = x86._mm_shuffle_epi32(state_1, 0x1b)    // EFGH
		state_0 := x86._mm_alignr_epi8(tmp, state_1, 8)   // ABEF
		state_1 = x86._mm_blend_epi16(state_1, tmp, 0xf0) // CDGH

		data := data
		for len(data) >= 64 {
			state_0_save, state_1_save := state_0, state_1

			// Rounds 0-3
			msg := intrinsics.unaligned_load((^x86.__m128i)(raw_data(data)))
			msg_0 := x86._mm_shuffle_epi8(msg, SHA256_SHUF_MASK)
			msg = x86._mm_add_epi32(msg_0, x86.__m128i(SHA256_K_0))
			state_1 = x86._mm_sha256rnds2_epu32(state_1, state_0, msg)
			msg = x86._mm_shuffle_epi32(msg, 0x0e)
			state_0 = x86._mm_sha256rnds2_epu32(state_0, state_1, msg)

			// Rounds 4-7
			msg_1 := intrinsics.unaligned_load((^x86.__m128i)(raw_data(data[16:])))
			msg_1 = x86._mm_shuffle_epi8(msg_1, SHA256_SHUF_MASK)
			msg = x86._mm_add_epi32(msg_1, x86.__m128i(SHA256_K_1))
			state_1 = x86._mm_sha256rnds2_epu32(state_1, state_0, msg)
			msg = x86._mm_shuffle_epi32(msg, 0x0e)
			state_0 = x86._mm_sha256rnds2_epu32(state_0, state_1, msg)
			msg_0 = x86._mm_sha256msg1_epu32(msg_0, msg_1)

			// Rounds 8-11
			msg_2 := intrinsics.unaligned_load((^x86.__m128i)(raw_data(data[32:])))
			msg_2 = x86._mm_shuffle_epi8(msg_2, SHA256_SHUF_MASK)
			msg = x86._mm_add_epi32(msg_2, x86.__m128i(SHA256_K_2))
			state_1 = x86._mm_sha256rnds2_epu32(state_1, state_0, msg)
			msg = x86._mm_shuffle_epi32(msg, 0x0e)
			state_0 = x86._mm_sha256rnds2_epu32(state_0, state_1, msg)
			msg_1 = x86._mm_sha256msg1_epu32(msg_1, msg_2)

			// Rounds 12-15
			msg_3 := intrinsics.unaligned_load((^x86.__m128i)(raw_data(data[48:])))
			msg_3 = x86._mm_shuffle_epi8(msg_3, SHA256_SHUF_MASK)
			msg = x86._mm_add_epi32(msg_3, x86.__m128i(SHA256_K_3))
			state_1 = x86._mm_sha256rnds2_epu32(state_1, state_0, msg)
			tmp = x86._mm_alignr_epi8(msg_3, msg_2, 4)
			msg_0 = x86._mm_add_epi32(msg_0, tmp)
			msg_0 = x86._mm_sha256msg2_epu32(msg_0, msg_3)
			msg = x86._mm_shuffle_epi32(msg, 0x0e)
			state_0 = x86._mm_sha256rnds2_epu32(state_0, state_1, msg)
			msg_2 = x86._mm_sha256msg1_epu32(msg_2, msg_3)

			// Rounds 16-19
			msg = x86._mm_add_epi32(msg_0, x86.__m128i(SHA256_K_4))
			state_1 = x86._mm_sha256rnds2_epu32(state_1, state_0, msg)
			tmp = x86._mm_alignr_epi8(msg_0, msg_3, 4)
			msg_1 = x86._mm_add_epi32(msg_1, tmp)
			msg_1 = x86._mm_sha256msg2_epu32(msg_1, msg_0)
			msg = x86._mm_shuffle_epi32(msg, 0x0e)
			state_0 = x86._mm_sha256rnds2_epu32(state_0, state_1, msg)
			msg_3 = x86._mm_sha256msg1_epu32(msg_3, msg_0)

			// Rounds 20-23
			msg = x86._mm_add_epi32(msg_1, x86.__m128i(SHA256_K_5))
			state_1 = x86._mm_sha256rnds2_epu32(state_1, state_0, msg)
			tmp = x86._mm_alignr_epi8(msg_1, msg_0, 4)
			msg_2 = x86._mm_add_epi32(msg_2, tmp)
			msg_2 = x86._mm_sha256msg2_epu32(msg_2, msg_1)
			msg = x86._mm_shuffle_epi32(msg, 0x0e)
			state_0 = x86._mm_sha256rnds2_epu32(state_0, state_1, msg)
			msg_0 = x86._mm_sha256msg1_epu32(msg_0, msg_1)

			// Rounds 24-27
			msg = x86._mm_add_epi32(msg_2, x86.__m128i(SHA256_K_6))
			state_1 = x86._mm_sha256rnds2_epu32(state_1, state_0, msg)
			tmp = x86._mm_alignr_epi8(msg_2, msg_1, 4)
			msg_3 = x86._mm_add_epi32(msg_3, tmp)
			msg_3 = x86._mm_sha256msg2_epu32(msg_3, msg_2)
			msg = x86._mm_shuffle_epi32(msg, 0x0e)
			state_0 = x86._mm_sha256rnds2_epu32(state_0, state_1, msg)
			msg_1 = x86._mm_sha256msg1_epu32(msg_1, msg_2)

			// Rounds 28-31
			msg = x86._mm_add_epi32(msg_3, x86.__m128i(SHA256_K_7))
			state_1 = x86._mm_sha256rnds2_epu32(state_1, state_0, msg)
			tmp = x86._mm_alignr_epi8(msg_3, msg_2, 4)
			msg_0 = x86._mm_add_epi32(msg_0, tmp)
			msg_0 = x86._mm_sha256msg2_epu32(msg_0, msg_3)
			msg = x86._mm_shuffle_epi32(msg, 0x0e)
			state_0 = x86._mm_sha256rnds2_epu32(state_0, state_1, msg)
			msg_2 = x86._mm_sha256msg1_epu32(msg_2, msg_3)

			// Rounds 32-35
			msg = x86._mm_add_epi32(msg_0, x86.__m128i(SHA256_K_8))
			state_1 = x86._mm_sha256rnds2_epu32(state_1, state_0, msg)
			tmp = x86._mm_alignr_epi8(msg_0, msg_3, 4)
			msg_1 = x86._mm_add_epi32(msg_1, tmp)
			msg_1 = x86._mm_sha256msg2_epu32(msg_1, msg_0)
			msg = x86._mm_shuffle_epi32(msg, 0x0e)
			state_0 = x86._mm_sha256rnds2_epu32(state_0, state_1, msg)
			msg_3 = x86._mm_sha256msg1_epu32(msg_3, msg_0)

			// Rounds 36-39
			msg = x86._mm_add_epi32(msg_1, x86.__m128i(SHA256_K_9))
			state_1 = x86._mm_sha256rnds2_epu32(state_1, state_0, msg)
			tmp = x86._mm_alignr_epi8(msg_1, msg_0, 4)
			msg_2 = x86._mm_add_epi32(msg_2, tmp)
			msg_2 = x86._mm_sha256msg2_epu32(msg_2, msg_1)
			msg = x86._mm_shuffle_epi32(msg, 0x0e)
			state_0 = x86._mm_sha256rnds2_epu32(state_0, state_1, msg)
			msg_0 = x86._mm_sha256msg1_epu32(msg_0, msg_1)

			// Rounds 40-43
			msg = x86._mm_add_epi32(msg_2, x86.__m128i(SHA256_K_10))
			state_1 = x86._mm_sha256rnds2_epu32(state_1, state_0, msg)
			tmp = x86._mm_alignr_epi8(msg_2, msg_1, 4)
			msg_3 = x86._mm_add_epi32(msg_3, tmp)
			msg_3 = x86._mm_sha256msg2_epu32(msg_3, msg_2)
			msg = x86._mm_shuffle_epi32(msg, 0x0e)
			state_0 = x86._mm_sha256rnds2_epu32(state_0, state_1, msg)
			msg_1 = x86._mm_sha256msg1_epu32(msg_1, msg_2)

			// Rounds 44-47
			msg = x86._mm_add_epi32(msg_3, x86.__m128i(SHA256_K_11))
			state_1 = x86._mm_sha256rnds2_epu32(state_1, state_0, msg)
			tmp = x86._mm_alignr_epi8(msg_3, msg_2, 4)
			msg_0 = x86._mm_add_epi32(msg_0, tmp)
			msg_0 = x86._mm_sha256msg2_epu32(msg_0, msg_3)
			msg = x86._mm_shuffle_epi32(msg, 0x0e)
			state_0 = x86._mm_sha256rnds2_epu32(state_0, state_1, msg)
			msg_2 = x86._mm_sha256msg1_epu32(msg_2, msg_3)

			// Rounds 48-51
			msg = x86._mm_add_epi32(msg_0, x86.__m128i(SHA256_K_12))
			state_1 = x86._mm_sha256rnds2_epu32(state_1, state_0, msg)
			tmp = x86._mm_alignr_epi8(msg_0, msg_3, 4)
			msg_1 = x86._mm_add_epi32(msg_1, tmp)
			msg_1 = x86._mm_sha256msg2_epu32(msg_1, msg_0)
			msg = x86._mm_shuffle_epi32(msg, 0x0e)
			state_0 = x86._mm_sha256rnds2_epu32(state_0, state_1, msg)
			msg_3 = x86._mm_sha256msg1_epu32(msg_3, msg_0)

			// Rounds 52-55
			msg = x86._mm_add_epi32(msg_1, x86.__m128i(SHA256_K_13))
			state_1 = x86._mm_sha256rnds2_epu32(state_1, state_0, msg)
			tmp = x86._mm_alignr_epi8(msg_1, msg_0, 4)
			msg_2 = x86._mm_add_epi32(msg_2, tmp)
			msg_2 = x86._mm_sha256msg2_epu32(msg_2, msg_1)
			msg = x86._mm_shuffle_epi32(msg, 0x0e)
			state_0 = x86._mm_sha256rnds2_epu32(state_0, state_1, msg)

			// Rounds 56-59
			msg = x86._mm_add_epi32(msg_2, x86.__m128i(SHA256_K_14))
			state_1 = x86._mm_sha256rnds2_epu32(state_1, state_0, msg)
			tmp = x86._mm_alignr_epi8(msg_2, msg_1, 4)
			msg_3 = x86._mm_add_epi32(msg_3, tmp)
			msg_3 = x86._mm_sha256msg2_epu32(msg_3, msg_2)
			msg = x86._mm_shuffle_epi32(msg, 0x0e)
			state_0 = x86._mm_sha256rnds2_epu32(state_0, state_1, msg)

			// Rounds 60-63
			msg = x86._mm_add_epi32(msg_3, x86.__m128i(SHA256_K_15))
			state_1 = x86._mm_sha256rnds2_epu32(state_1, state_0, msg)
			msg = x86._mm_shuffle_epi32(msg, 0x0e)
			state_0 = x86._mm_sha256rnds2_epu32(state_0, state_1, msg)

			state_0 = x86._mm_add_epi32(state_0, state_0_save)
			state_1 = x86._mm_add_epi32(state_1, state_1_save)

			data = data[64:]
		}

		tmp = x86._mm_shuffle_epi32(state_0, 0x1b)        // FEBA
		state_1 = x86._mm_shuffle_epi32(state_1, 0xb1)    // DCHG
		state_0 = x86._mm_blend_epi16(tmp, state_1, 0xf0) // DCBA
		state_1 = x86._mm_alignr_epi8(state_1, tmp, 8)    // ABEF

		intrinsics.unaligned_store((^x86.__m128i)(&h[0]), state_0)
		intrinsics.unaligned_store((^x86.__m128i)(&h[4]), state_1)
	}
}

// Pure-Odin SHA-1 implementation (RFC 3174, 20-byte digest) with hardware SHA-NI acceleration on amd64.
sha1_sum_into :: proc(data: []u8, out: []u8) #no_bounds_check {
	state := [5]u32{
		0x67452301,
		0xEFCDAB89,
		0x98BADCFE,
		0x10325476,
		0xC3D2E1F0,
	}

	when ODIN_ARCH == .amd64 {
		if _has_sha_ni {
			full_len := len(data) & ~int(63)
			if full_len > 0 {
				sha1_transf_hw(&state, data[:full_len])
			}
			rem := len(data) - full_len
			bit_len := u64(len(data)) * 8
			if rem < 56 {
				tail: [64]u8
				copy(tail[:rem], data[full_len:])
				tail[rem] = 0x80
				endian.unchecked_put_u64be(tail[56:64], bit_len)
				sha1_transf_hw(&state, tail[0:64])
			} else {
				tail: [128]u8
				copy(tail[:rem], data[full_len:])
				tail[rem] = 0x80
				endian.unchecked_put_u64be(tail[120:128], bit_len)
				sha1_transf_hw(&state, tail[0:128])
			}
			endian.unchecked_put_u32be(out[0:4], state[0])
			endian.unchecked_put_u32be(out[4:8], state[1])
			endian.unchecked_put_u32be(out[8:12], state[2])
			endian.unchecked_put_u32be(out[12:16], state[3])
			endian.unchecked_put_u32be(out[16:20], state[4])
			return
		}
	}

	h0, h1, h2, h3, h4 := state[0], state[1], state[2], state[3], state[4]

	rol32 :: #force_inline proc(x: u32, n: uint) -> u32 {
		return (x << n) | (x >> (32 - n))
	}

	process_block :: proc(block: []u8, h0, h1, h2, h3, h4: ^u32) {
		w: [80]u32
		for i in 0 ..< 16 {
			v, _ := endian.get_u32(block[i * 4:i * 4 + 4], .Big)
			w[i] = v
		}
		for i in 16 ..< 80 {
			x := w[i - 3] ~ w[i - 8] ~ w[i - 14] ~ w[i - 16]
			w[i] = (x << 1) | (x >> 31)
		}

		a := h0^
		b := h1^
		c := h2^
		d := h3^
		e := h4^

		for i in 0 ..< 80 {
			f, k: u32
			if i < 20 {
				f = (b & c) | ((~b) & d)
				k = 0x5A827999
			} else if i < 40 {
				f = b ~ c ~ d
				k = 0x6ED9EBA1
			} else if i < 60 {
				f = (b & c) | (b & d) | (c & d)
				k = 0x8F1BBCDC
			} else {
				f = b ~ c ~ d
				k = 0xCA62C1D6
			}
			temp := ((a << 5) | (a >> 27)) + f + e + k + w[i]
			e = d
			d = c
			c = (b << 30) | (b >> 2)
			b = a
			a = temp
		}

		h0^ += a
		h1^ += b
		h2^ += c
		h3^ += d
		h4^ += e
	}

	i := 0
	for i + 64 <= len(data) {
		process_block(data[i:i + 64], &h0, &h1, &h2, &h3, &h4)
		i += 64
	}

	rem := len(data) - i
	bit_len := u64(len(data)) * 8
	if rem < 56 {
		tail: [64]u8
		copy(tail[:rem], data[i:])
		tail[rem] = 0x80
		endian.put_u64(tail[56:64], .Big, bit_len)
		process_block(tail[0:64], &h0, &h1, &h2, &h3, &h4)
	} else {
		tail: [128]u8
		copy(tail[:rem], data[i:])
		tail[rem] = 0x80
		endian.put_u64(tail[120:128], .Big, bit_len)
		process_block(tail[0:64], &h0, &h1, &h2, &h3, &h4)
		process_block(tail[64:128], &h0, &h1, &h2, &h3, &h4)
	}

	endian.put_u32(out[0:4], .Big, h0)
	endian.put_u32(out[4:8], .Big, h1)
	endian.put_u32(out[8:12], .Big, h2)
	endian.put_u32(out[12:16], .Big, h3)
	endian.put_u32(out[16:20], .Big, h4)
}

sha1_sum :: proc(data: []u8) -> [20]u8 {
	out: [20]u8 = ---
	sha1_sum_into(data, out[:])
	return out
}

// Pure-Odin SHA-256 implementation (FIPS 180-4, 32-byte digest) with hardware SHA-NI acceleration on amd64.
sha256_sum_into :: proc(data: []u8, out: []u8) #no_bounds_check {
	h := [8]u32{
		0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
		0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
	}

	when ODIN_ARCH == .amd64 {
		if _has_sha_ni {
			full_len := len(data) & ~int(63)
			if full_len > 0 {
				sha256_transf_hw(&h, data[:full_len])
			}
			rem := len(data) - full_len
			bit_len := u64(len(data)) * 8
			if rem < 56 {
				tail: [64]u8
				copy(tail[:rem], data[full_len:])
				tail[rem] = 0x80
				endian.unchecked_put_u64be(tail[56:64], bit_len)
				sha256_transf_hw(&h, tail[0:64])
			} else {
				tail: [128]u8
				copy(tail[:rem], data[full_len:])
				tail[rem] = 0x80
				endian.unchecked_put_u64be(tail[120:128], bit_len)
				sha256_transf_hw(&h, tail[0:128])
			}
			for j in 0 ..< 8 {
				endian.unchecked_put_u32be(out[j * 4:j * 4 + 4], h[j])
			}
			return
		}
	}

	K := [64]u32{
		0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
		0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
		0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
		0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
		0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
		0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
		0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
		0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
	}

	ror32 :: #force_inline proc(x: u32, n: uint) -> u32 {
		return (x >> n) | (x << (32 - n))
	}

	process_block :: proc(block: []u8, h: ^[8]u32, K: ^[64]u32) {
		w: [64]u32
		for i in 0 ..< 16 {
			v, _ := endian.get_u32(block[i * 4:i * 4 + 4], .Big)
			w[i] = v
		}
		for i in 16 ..< 64 {
			s0 := ((w[i - 15] >> 7) | (w[i - 15] << 25)) ~ ((w[i - 15] >> 18) | (w[i - 15] << 14)) ~ (w[i - 15] >> 3)
			s1 := ((w[i - 2] >> 17) | (w[i - 2] << 15)) ~ ((w[i - 2] >> 19) | (w[i - 2] << 13)) ~ (w[i - 2] >> 10)
			w[i] = w[i - 16] + s0 + w[i - 7] + s1
		}

		a, b, c, d, e, f, g, hh := h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7]
		for i in 0 ..< 64 {
			S1 := ((e >> 6) | (e << 26)) ~ ((e >> 11) | (e << 21)) ~ ((e >> 25) | (e << 7))
			ch := (e & f) ~ ((~e) & g)
			temp1 := hh + S1 + ch + K[i] + w[i]
			S0 := ((a >> 2) | (a << 30)) ~ ((a >> 13) | (a << 19)) ~ ((a >> 22) | (a << 10))
			maj := (a & b) ~ (a & c) ~ (b & c)
			temp2 := S0 + maj

			hh = g
			g = f
			f = e
			e = d + temp1
			d = c
			c = b
			b = a
			a = temp1 + temp2
		}

		h[0] += a
		h[1] += b
		h[2] += c
		h[3] += d
		h[4] += e
		h[5] += f
		h[6] += g
		h[7] += hh
	}

	i := 0
	for i + 64 <= len(data) {
		process_block(data[i:i + 64], &h, &K)
		i += 64
	}

	rem := len(data) - i
	bit_len := u64(len(data)) * 8
	if rem < 56 {
		tail: [64]u8
		copy(tail[:rem], data[i:])
		tail[rem] = 0x80
		endian.put_u64(tail[56:64], .Big, bit_len)
		process_block(tail[0:64], &h, &K)
	} else {
		tail: [128]u8
		copy(tail[:rem], data[i:])
		tail[rem] = 0x80
		endian.put_u64(tail[120:128], .Big, bit_len)
		process_block(tail[0:64], &h, &K)
		process_block(tail[64:128], &h, &K)
	}

	for j in 0 ..< 8 {
		endian.put_u32(out[j * 4:j * 4 + 4], .Big, h[j])
	}
}

sha256_sum :: proc(data: []u8) -> [32]u8 {
	out: [32]u8 = ---
	sha256_sum_into(data, out[:])
	return out
}

// Built-in SHA-1 hasher (20 bytes).
sha1_hasher :: proc(id: u32 = 0, file_id: u64 = 0) -> Hasher {
	return Hasher{
		hash_proc = proc(data: []u8, out_hash: []u8, _: rawptr) {
			sha1_sum_into(data, out_hash)
		},
		hash_size = 20,
		id        = id,
		file_id   = file_id,
	}
}

// Built-in SHA-256 hasher (32 bytes).
sha256_hasher :: proc(id: u32 = 0, file_id: u64 = 0) -> Hasher {
	return Hasher{
		hash_proc = proc(data: []u8, out_hash: []u8, _: rawptr) {
			sha256_sum_into(data, out_hash)
		},
		hash_size = 32,
		id        = id,
		file_id   = file_id,
	}
}

// Slot is the fundamental 9-byte tagged pointer / immediate value in xitdb.
Slot :: struct {
	value: i64,
	tag:   Tag,
	full:  bool,
}

slot_empty :: proc(s: Slot) -> bool {
	return s.tag == .None && !s.full
}

slot_with_tag :: proc(s: Slot, tag: Tag) -> Slot {
	res := s
	res.tag = tag
	return res
}

slot_with_full :: proc(s: Slot, full: bool) -> Slot {
	res := s
	res.full = full
	return res
}

slot_to_bytes :: #force_inline proc(s: Slot) -> [SLOT_LENGTH]u8 {
	buf: [SLOT_LENGTH]u8 = ---
	full_bit := u8(0x80) if s.full else u8(0)
	buf[0] = full_bit | (u8(s.tag) & 0x7f)
	endian.unchecked_put_u64be(buf[1:9], u64(s.value))
	return buf
}

// Decode a Slot without validating the tag yet (matches Go SlotFromBytes + Tag.validate()).
slot_from_bytes_raw :: #force_inline proc(buf: [SLOT_LENGTH]u8) -> Slot {
	b := buf
	full := (b[0] & 0x80) != 0
	raw_tag := b[0] & 0x7f
	val := endian.unchecked_get_u64be(b[1:9])
	return Slot{
		value = i64(val),
		tag   = Tag(raw_tag),
		full  = full,
	}
}

slot_from_slice_raw :: #force_inline proc(b: []u8) -> Slot #no_bounds_check {
	full := (b[0] & 0x80) != 0
	raw_tag := b[0] & 0x7f
	val := endian.unchecked_get_u64be(b[1:9])
	return Slot{
		value = i64(val),
		tag   = Tag(raw_tag),
		full  = full,
	}
}

slot_from_bytes :: #force_inline proc(buf: [SLOT_LENGTH]u8) -> (s: Slot, err: Error) {
	s = slot_from_bytes_raw(buf)
	tag_validate(s.tag) or_return
	return s, nil
}

slot_from_slice :: #force_inline proc(b: []u8) -> (s: Slot, err: Error) #no_bounds_check {
	s = slot_from_slice_raw(b)
	tag_validate(s.tag) or_return
	return s, nil
}

// Slot_Pointer pairs an optional file offset with a resolved Slot.
Slot_Pointer :: struct {
	position: Maybe(i64),
	slot:     Slot,
}

slot_pointer_with_slot :: proc(sp: Slot_Pointer, s: Slot) -> Slot_Pointer {
	return Slot_Pointer{position = sp.position, slot = s}
}

// Header represents the 20-byte header at offset 0 of a xitdb file.
Header :: struct {
	file_id:      u64,
	hash_id:      u32,
	hash_size:    u16,
	version:      u16,
	padding:      u8,
	magic_number: [3]u8,
}

header_validate :: proc(h: Header) -> Error {
	if h.magic_number != MAGIC_NUMBER {
		return .Invalid_Database
	}
	if h.version != VERSION {
		return .Invalid_Version
	}
	return nil
}

header_to_bytes :: proc(h: Header) -> [HEADER_LENGTH]u8 {
	buf: [HEADER_LENGTH]u8
	buf[0] = h.magic_number[0]
	buf[1] = h.magic_number[1]
	buf[2] = h.magic_number[2]
	buf[3] = h.padding
	endian.put_u16(buf[4:6], .Big, h.version)
	endian.put_u16(buf[6:8], .Big, h.hash_size)
	endian.put_u32(buf[8:12], .Big, h.hash_id)
	endian.put_u64(buf[12:20], .Big, h.file_id)
	return buf
}

header_from_bytes :: proc(buf: [HEADER_LENGTH]u8) -> Header {
	b := buf
	version, _ := endian.get_u16(b[4:6], .Big)
	hash_size, _ := endian.get_u16(b[6:8], .Big)
	hash_id, _ := endian.get_u32(b[8:12], .Big)
	file_id, _ := endian.get_u64(b[12:20], .Big)
	return Header{
		magic_number = {b[0], b[1], b[2]},
		padding      = b[3],
		version      = version,
		hash_size    = hash_size,
		hash_id      = hash_id,
		file_id      = file_id,
	}
}

header_read :: proc(r: ^Core) -> (h: Header, err: Error) {
	buf: [HEADER_LENGTH]u8
	core_read_exact(r, buf[:]) or_return
	return header_from_bytes(buf), nil
}

header_read_at :: proc(r: ^Core, pos: i64 = 0) -> (h: Header, err: Error) {
	buf: [HEADER_LENGTH]u8
	core_read_exact_at(r, pos, buf[:]) or_return
	return header_from_bytes(buf), nil
}

header_write :: proc(h: Header, w: ^Core) -> Error {
	buf := header_to_bytes(h)
	return core_write_all(w, buf[:])
}

// Root_Header represents the 17-byte root header at offset 20..37.
Root_Header :: struct {
	file_size: i64,
	root:      Slot,
}

root_header_to_bytes :: proc(rh: Root_Header) -> [ROOT_HEADER_LENGTH]u8 {
	buf: [ROOT_HEADER_LENGTH]u8
	slot_bytes := slot_to_bytes(rh.root)
	copy(buf[0:9], slot_bytes[:])
	endian.put_u64(buf[9:17], .Big, u64(rh.file_size))
	return buf
}

root_header_from_bytes :: proc(buf: [ROOT_HEADER_LENGTH]u8) -> Root_Header {
	b := buf
	slot_buf: [SLOT_LENGTH]u8
	copy(slot_buf[:], b[0:9])
	root := slot_from_bytes_raw(slot_buf)
	file_size, _ := endian.get_u64(b[9:17], .Big)
	return Root_Header{
		file_size = i64(file_size),
		root      = root,
	}
}

// Root_Trailer represents the 25-byte commit trailer at the end of each transaction.
Root_Trailer :: struct {
	checksum:  u64,
	commit_id: u64,
	root:      Slot,
}

compute_root_trailer_checksum :: proc(file_id: u64, position: i64, root: Slot, commit_id: u64) -> u64 {
	data: [33]u8
	endian.put_u64(data[0:8], .Big, file_id)
	endian.put_u64(data[8:16], .Big, u64(position))
	slot_bytes := slot_to_bytes(root)
	copy(data[16:25], slot_bytes[:])
	endian.put_u64(data[25:33], .Big, commit_id)
	return hash.crc64_xz(data[:])
}

new_root_trailer :: proc(file_id: u64, position: i64, root: Slot, commit_id: u64) -> Root_Trailer {
	return Root_Trailer{
		checksum  = compute_root_trailer_checksum(file_id, position, root, commit_id),
		commit_id = commit_id,
		root      = root,
	}
}

root_trailer_to_bytes :: proc(rt: Root_Trailer) -> [ROOT_TRAILER_LENGTH]u8 {
	buf: [ROOT_TRAILER_LENGTH]u8
	slot_bytes := slot_to_bytes(rt.root)
	copy(buf[0:9], slot_bytes[:])
	endian.put_u64(buf[9:17], .Big, rt.commit_id)
	endian.put_u64(buf[17:25], .Big, rt.checksum)
	return buf
}

root_trailer_from_bytes :: proc(buf: [ROOT_TRAILER_LENGTH]u8) -> Root_Trailer {
	b := buf
	slot_buf: [SLOT_LENGTH]u8
	copy(slot_buf[:], b[0:9])
	root := slot_from_bytes_raw(slot_buf)
	commit_id, _ := endian.get_u64(b[9:17], .Big)
	checksum, _ := endian.get_u64(b[17:25], .Big)
	return Root_Trailer{
		checksum  = checksum,
		commit_id = commit_id,
		root      = root,
	}
}

// Replica_State summarizes a replica's committed size and latest trailer checksum.
Replica_State :: struct {
	committed_size: i64,
	checksum:       u64,
}

// Array_List_Header is 16 bytes on disk: [0..8] size (i64 BE), [8..16] ptr (i64 BE).
Array_List_Header :: struct {
	ptr:  i64,
	size: i64,
}

array_list_header_with_ptr :: proc(h: Array_List_Header, ptr: i64) -> Array_List_Header {
	return Array_List_Header{ptr = ptr, size = h.size}
}

array_list_header_to_bytes :: #force_inline proc(h: Array_List_Header) -> [ARRAY_LIST_HEADER_LENGTH]u8 {
	buf: [ARRAY_LIST_HEADER_LENGTH]u8 = ---
	endian.unchecked_put_u64be(buf[0:8], u64(h.size))
	endian.unchecked_put_u64be(buf[8:16], u64(h.ptr))
	return buf
}

array_list_header_from_bytes :: #force_inline proc(buf: [ARRAY_LIST_HEADER_LENGTH]u8) -> (res: Array_List_Header, err: Error) {
	b := buf
	size := i64(endian.unchecked_get_u64be(b[0:8]))
	ptr := i64(endian.unchecked_get_u64be(b[8:16]))
	if size < 0 || ptr < 0 {
		return {}, .Expected_Unsigned_Long
	}
	return Array_List_Header{ptr = ptr, size = size}, nil
}

// BTree_Header is 16 bytes on disk: [0..8] size (i64 BE), [8..16] root_ptr (i64 BE).
BTree_Header :: struct {
	root_ptr: i64,
	size:     i64,
}

btree_header_to_bytes :: #force_inline proc(h: BTree_Header) -> [BTREE_HEADER_LENGTH]u8 {
	buf: [BTREE_HEADER_LENGTH]u8 = ---
	endian.unchecked_put_u64be(buf[0:8], u64(h.size))
	endian.unchecked_put_u64be(buf[8:16], u64(h.root_ptr))
	return buf
}

btree_header_from_bytes :: #force_inline proc(buf: [BTREE_HEADER_LENGTH]u8) -> (res: BTree_Header, err: Error) {
	b := buf
	size := i64(endian.unchecked_get_u64be(b[0:8]))
	root_ptr := i64(endian.unchecked_get_u64be(b[8:16]))
	if size < 0 || root_ptr < 0 {
		return {}, .Expected_Unsigned_Long
	}
	return BTree_Header{root_ptr = root_ptr, size = size}, nil
}

// Key_Value_Pair is stored in HAMT maps/sets (with hash) or Sorted maps/sets (without hash on disk).
Key_Value_Pair :: struct {
	value_slot: Slot,
	key_slot:   Slot,
	hash:       []u8,
}

kv_pair_length :: proc(hash_size: int) -> int {
	return hash_size + SLOT_LENGTH * 2
}

kv_pair_to_bytes :: proc(kv: Key_Value_Pair, allocator := context.temp_allocator) -> []u8 {
	buf := make([]u8, len(kv.hash) + SLOT_LENGTH * 2, allocator)
	copy(buf, kv.hash)
	kb := slot_to_bytes(kv.key_slot)
	copy(buf[len(kv.hash):], kb[:])
	vb := slot_to_bytes(kv.value_slot)
	copy(buf[len(kv.hash) + SLOT_LENGTH:], vb[:])
	return buf
}

kv_pair_from_bytes :: proc(b: []u8, hash_size: int, allocator := context.allocator) -> Key_Value_Pair {
	h: []u8
	if hash_size > 0 {
		h = make([]u8, hash_size, allocator)
		copy(h, b[:hash_size])
	}
	key_slot := slot_from_slice_raw(b[hash_size : hash_size + SLOT_LENGTH])
	val_slot := slot_from_slice_raw(b[hash_size + SLOT_LENGTH : hash_size + SLOT_LENGTH * 2])
	return Key_Value_Pair{value_slot = val_slot, key_slot = key_slot, hash = h}
}

kv_pair_write :: proc(kv: Key_Value_Pair, c: ^Core) -> Error {
	return encode_kv_pair(c, .KV_Pair, kv)
}

kv_pair_read :: proc(c: ^Core, hash_size: int, allocator := context.allocator) -> (kv: Key_Value_Pair, err: Error) {
	return decode_kv_pair(c, .KV_Pair, hash_size, allocator)
}

decode_kv_pair :: proc(c: ^Core, tag: Tag, hash_size: int, allocator := context.allocator) -> (kv: Key_Value_Pair, err: Error) {
	#partial switch tag {
	case .KV_Pair:
		kv_len := kv_pair_length(hash_size)
		if kv_len <= 128 {
			stack_buf: [128]u8 = ---
			b := stack_buf[:kv_len]
			core_read_exact(c, b) or_return
			kv = kv_pair_from_bytes(b, hash_size, allocator)
		} else {
			b := make([]u8, kv_len, context.temp_allocator)
			core_read_exact(c, b) or_return
			kv = kv_pair_from_bytes(b, hash_size, allocator)
		}
	case .Sorted_KV_Pair:
		b: [SORTED_KEY_VALUE_LEN]u8 = ---
		core_read_exact(c, b[:]) or_return
		kv = kv_pair_from_bytes(b[:], 0, allocator)
	case:
		return {}, .Unexpected_Tag
	}
	if err := tag_validate(kv.key_slot.tag); err != nil {
		if kv.hash != nil {
			delete(kv.hash, allocator)
		}
		return {}, err
	}
	if err := tag_validate(kv.value_slot.tag); err != nil {
		if kv.hash != nil {
			delete(kv.hash, allocator)
		}
		return {}, err
	}
	return kv, nil
}

// Zero-allocation KV_Pair reader using a caller-supplied buffer for the hash digest.
kv_pair_read_buf :: proc(c: ^Core, hash_buf: []u8) -> (kv: Key_Value_Pair, err: Error) {
	hash_size := len(hash_buf)
	kv_len := kv_pair_length(hash_size)
	stack_buf: [128]u8 = ---
	b := stack_buf[:kv_len] if kv_len <= len(stack_buf) else make([]u8, kv_len, context.temp_allocator)
	core_read_exact(c, b) or_return
	copy(hash_buf, b[:hash_size])
	key_slot := slot_from_slice_raw(b[hash_size : hash_size + SLOT_LENGTH])
	tag_validate(key_slot.tag) or_return
	val_slot := slot_from_slice_raw(b[hash_size + SLOT_LENGTH : hash_size + SLOT_LENGTH * 2])
	tag_validate(val_slot.tag) or_return
	return Key_Value_Pair{value_slot = val_slot, key_slot = key_slot, hash = hash_buf}, nil
}

decode_kv_pair_at :: proc(c: ^Core, pos: i64, tag: Tag, hash_size: int, allocator := context.allocator) -> (kv: Key_Value_Pair, err: Error) {
	#partial switch tag {
	case .KV_Pair:
		kv_len := kv_pair_length(hash_size)
		if kv_len <= 128 {
			stack_buf: [128]u8 = ---
			b := stack_buf[:kv_len]
			core_read_exact_at(c, pos, b) or_return
			kv = kv_pair_from_bytes(b, hash_size, allocator)
		} else {
			b := make([]u8, kv_len, context.temp_allocator)
			core_read_exact_at(c, pos, b) or_return
			kv = kv_pair_from_bytes(b, hash_size, allocator)
		}
	case .Sorted_KV_Pair:
		b: [SORTED_KEY_VALUE_LEN]u8 = ---
		core_read_exact_at(c, pos, b[:]) or_return
		kv = kv_pair_from_bytes(b[:], 0, allocator)
	case:
		return {}, .Unexpected_Tag
	}
	if err := tag_validate(kv.key_slot.tag); err != nil {
		if kv.hash != nil {
			delete(kv.hash, allocator)
		}
		return {}, err
	}
	if err := tag_validate(kv.value_slot.tag); err != nil {
		if kv.hash != nil {
			delete(kv.hash, allocator)
		}
		return {}, err
	}
	return kv, nil
}

kv_pair_read_buf_at :: proc(c: ^Core, pos: i64, hash_buf: []u8) -> (kv: Key_Value_Pair, err: Error) {
	hash_size := len(hash_buf)
	kv_len := kv_pair_length(hash_size)
	stack_buf: [128]u8 = ---
	b := stack_buf[:kv_len] if kv_len <= len(stack_buf) else make([]u8, kv_len, context.temp_allocator)
	core_read_exact_at(c, pos, b) or_return
	copy(hash_buf, b[:hash_size])
	key_slot := slot_from_slice_raw(b[hash_size : hash_size + SLOT_LENGTH])
	tag_validate(key_slot.tag) or_return
	val_slot := slot_from_slice_raw(b[hash_size + SLOT_LENGTH : hash_size + SLOT_LENGTH * 2])
	tag_validate(val_slot.tag) or_return
	return Key_Value_Pair{value_slot = val_slot, key_slot = key_slot, hash = hash_buf}, nil
}

encode_kv_pair :: proc(c: ^Core, tag: Tag, kv: Key_Value_Pair) -> Error {
	#partial switch tag {
	case .KV_Pair:
		kb := slot_to_bytes(kv.key_slot)
		vb := slot_to_bytes(kv.value_slot)
		total := len(kv.hash) + SLOT_LENGTH * 2
		if total <= 128 {
			buf: [128]u8 = ---
			copy(buf[:len(kv.hash)], kv.hash)
			copy(buf[len(kv.hash):len(kv.hash) + SLOT_LENGTH], kb[:])
			copy(buf[len(kv.hash) + SLOT_LENGTH:total], vb[:])
			return core_write_all(c, buf[:total])
		}
		core_write_all(c, kv.hash) or_return
		core_write_all(c, kb[:]) or_return
		return core_write_all(c, vb[:])
	case .Sorted_KV_Pair:
		buf: [SORTED_KEY_VALUE_LEN]u8 = ---
		kb := slot_to_bytes(kv.key_slot)
		vb := slot_to_bytes(kv.value_slot)
		copy(buf[:SLOT_LENGTH], kb[:])
		copy(buf[SLOT_LENGTH:], vb[:])
		return core_write_all(c, buf[:])
	case:
		return .Unexpected_Tag
	}
}

// BTree_Node_Kind distinguishes leaf (0) and branch (1) nodes.
BTree_Node_Kind :: enum u8 {
	Leaf   = 0,
	Branch = 1,
}

// BTree_Node backs Linked_Array_List.
BTree_Node :: struct {
	kind:     BTree_Node_Kind,
	num:      int,
	values:   [BTREE_SLOT_COUNT]Slot,
	children: [BTREE_SLOT_COUNT]Slot,
	counts:   [BTREE_SLOT_COUNT]i64,
}

btree_node_subtree_count :: proc(n: BTree_Node) -> i64 {
	if n.kind == .Leaf {
		return i64(n.num)
	}
	total: i64 = 0
	for i in 0 ..< n.num {
		total += n.counts[i]
	}
	return total
}

BTree_Node_Ref :: struct {
	node_ptr: i64,
	count:    i64,
}

BTree_Insert_Result :: struct {
	node_ptr:       i64,
	count:          i64,
	value_position: i64,
	split:          Maybe(BTree_Node_Ref),
}

BTree_Write_Slot :: struct {
	node_ptr:       i64,
	value_position: i64,
	slot:           Slot,
}

BTree_Join_Result :: struct {
	node_ptr: i64,
	count:    i64,
	split:    Maybe(BTree_Node_Ref),
}

BTree_Split_Result :: struct {
	left:  i64,
	right: i64,
}

// Sorted_Node backs Sorted_Map and Sorted_Set.
Sorted_Node :: struct {
	kind:       BTree_Node_Kind,
	num:        int,
	entries:    [BTREE_SLOT_COUNT]Slot,
	children:   [BTREE_SLOT_COUNT]Slot,
	separators: [BTREE_SLOT_COUNT]Slot,
	counts:     [BTREE_SLOT_COUNT]i64,
}

sorted_node_subtree_count :: proc(n: Sorted_Node) -> i64 {
	if n.kind == .Leaf {
		return i64(n.num)
	}
	total: i64 = 0
	for i in 0 ..< n.num {
		total += n.counts[i]
	}
	return total
}

Sorted_Split :: struct {
	node_ptr:  i64,
	count:     i64,
	separator: Slot,
}

Sorted_Insert_Result :: struct {
	node_ptr: i64,
	count:    i64,
	entry:    Slot,
	added:    bool,
	split:    Maybe(Sorted_Split),
}

Sorted_Remove_Result :: struct {
	node_ptr: i64,
	found:    bool,
}

Sorted_Slot :: struct {
	slot:     Slot,
	key_slot: Slot,
	position: i64,
}

is_key_only_entry :: #force_inline proc(entry: Slot) -> bool {
	return entry.tag == .Bytes || entry.tag == .Short_Bytes
}

// Bytes represents a byte array with an optional 2-byte format tag.
Bytes :: struct {
	value:      []u8,
	format_tag: []u8, // nil or 2 bytes
}

bytes_is_short :: proc(b: Bytes) -> bool {
	total_size := 6 if b.format_tag != nil else 8
	if len(b.value) > total_size {
		return false
	}
	for ch in b.value {
		if ch == 0 {
			return false
		}
	}
	return true
}

new_bytes :: proc(v: []u8) -> Bytes {
	return Bytes{value = v, format_tag = nil}
}

new_string :: proc(s: string) -> Bytes {
	return Bytes{value = transmute([]u8)s, format_tag = nil}
}

new_tagged_bytes :: proc(v: []u8, format_tag: []u8) -> Bytes {
	return Bytes{value = v, format_tag = format_tag}
}

new_tagged_string :: proc(s: string, format_tag: []u8) -> Bytes {
	return Bytes{value = transmute([]u8)s, format_tag = format_tag}
}

// Explicit typed wrappers for Writeable_Data.
Uint :: struct {
	value: u64,
}

Int :: struct {
	value: i64,
}

Float :: struct {
	value: f64,
}

new_uint :: proc(v: u64) -> Uint {
	return Uint{value = v}
}

new_int :: proc(v: i64) -> Int {
	return Int{value = v}
}

new_float :: proc(v: f64) -> Float {
	return Float{value = v}
}

// Writeable_Data is the union of values that can be written into a Slot.
Writeable_Data :: union {
	Slot,
	Uint,
	Int,
	Float,
	Bytes,
	u64,
	i64,
	f64,
	string,
	[]u8,
}

// Extract the 4-bit HAMT nibble at `key_offset` from big-endian `key_hash`.
hamt_nibble :: #force_inline proc(key_hash: []u8, key_offset: u8) -> int {
	hash_size := len(key_hash)
	byte_idx := hash_size - 1 - int(key_offset >> 1)
	shift := (key_offset & 1) << 2
	return int((key_hash[byte_idx] >> shift) & 0x0F)
}

// Compute floor(log_16(key)) for Radix Trie height calculation in 1 cycle using CLZ.
radix_shift :: #force_inline proc(key: i64) -> u8 {
	if key < SLOT_COUNT {
		return 0
	}
	return u8((63 - intrinsics.count_leading_zeros(u64(key))) >> 2)
}

check_long :: proc(n: i64) -> (res: i64, err: Error) {
	if n < 0 {
		return 0, .Expected_Unsigned_Long
	}
	return n, nil
}
