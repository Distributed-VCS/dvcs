module main

// A small, purpose-built ABI encoder/decoder. It only supports the types
// DVCS.sol actually uses (address, bool, uint64, uint256, bytes32, string),
// but implements the general head/tail layout so dynamic types (string) are
// handled correctly alongside static ones, matching solc's encoding.

pub enum AbiKind {
	address_
	bool_
	uint
	bytes32_
	string_
	bytes_
}

pub struct AbiValue {
pub:
	kind    AbiKind
	bytes20 []u8 // for address
	flag    bool // for bool
	num     u64  // for uint (any width -- ABI always encodes a full 32-byte word)
	b32     []u8 // for bytes32 (32 bytes)
	str     string
	raw     []u8 // for dynamic bytes
}

pub fn av_address(addr []u8) AbiValue {
	return AbiValue{
		kind: .address_
		bytes20: addr
	}
}

pub fn av_bool(v bool) AbiValue {
	return AbiValue{
		kind: .bool_
		flag: v
	}
}

pub fn av_uint(v u64) AbiValue {
	return AbiValue{
		kind: .uint
		num: v
	}
}

pub fn av_bytes32(v []u8) AbiValue {
	return AbiValue{
		kind: .bytes32_
		b32: v
	}
}

pub fn av_string(v string) AbiValue {
	return AbiValue{
		kind: .string_
		str: v
	}
}

pub fn av_bytes(v []u8) AbiValue {
	return AbiValue{
		kind: .bytes_
		raw: v
	}
}

fn function_selector(signature string) []u8 {
	digest := keccak256_str(signature)
	return hash32_to_bytes(digest)[..4].clone()
}

// encode_call builds full calldata: 4-byte selector followed by the
// head/tail-encoded arguments, per the standard Solidity contract ABI.
pub fn encode_call(signature string, args []AbiValue) []u8 {
	selector := function_selector(signature)

	n := args.len
	mut heads := [][]u8{len: n}
	mut tails := [][]u8{len: n}

	// First pass: static values go straight into head; dynamic values get a
	// placeholder offset in head and their real payload in tail.
	for i, a in args {
		match a.kind {
			.address_ {
				heads[i] = left_pad32(a.bytes20)
			}
			.bool_ {
				v := if a.flag { u8(1) } else { u8(0) }
				heads[i] = left_pad32([v])
			}
			.uint {
				heads[i] = left_pad32(u64_to_be_bytes(a.num))
			}
			.bytes32_ {
				heads[i] = a.b32.clone()
			}
			.string_ {
				heads[i] = []u8{len: 32} // placeholder, patched below
				tails[i] = encode_dynamic_bytes(a.str.bytes())
			}
			.bytes_ {
				heads[i] = []u8{len: 32} // placeholder, patched below
				tails[i] = encode_dynamic_bytes(a.raw)
			}
		}
	}

	// Second pass: compute real offsets (relative to the start of the args
	// block, i.e. right after the 32*n head words) and patch placeholders.
	mut head_total := 0
	for h in heads {
		head_total += h.len
	}
	mut running_offset := head_total
	for i, a in args {
		if a.kind == .string_ || a.kind == .bytes_ {
			heads[i] = left_pad32(u64_to_be_bytes(u64(running_offset)))
			running_offset += tails[i].len
		}
	}

	mut out := []u8{}
	out << selector
	for h in heads {
		out << h
	}
	for t in tails {
		out << t
	}
	return out
}

fn encode_dynamic_bytes(data []u8) []u8 {
	mut out := []u8{}
	out << left_pad32(u64_to_be_bytes(u64(data.len)))
	out << data
	pad := (32 - data.len % 32) % 32
	for _ in 0 .. pad {
		out << u8(0)
	}
	return out
}

// --- Decoding helpers for eth_call return data ---

// decode_word reads the 32-byte word at `idx` (0-based word index).
pub fn decode_word(data []u8, idx int) []u8 {
	start := idx * 32
	if start + 32 > data.len {
		return []u8{len: 32}
	}
	return data[start..start + 32].clone()
}

pub fn decode_uint(data []u8, idx int) u64 {
	w := decode_word(data, idx)
	mut v := u64(0)
	for i in 24 .. 32 {
		v = (v << u32(8)) | u64(w[i])
	}
	return v
}

pub fn decode_bool(data []u8, idx int) bool {
	return decode_uint(data, idx) != 0
}

pub fn decode_address(data []u8, idx int) []u8 {
	w := decode_word(data, idx)
	return w[12..32].clone()
}

pub fn decode_bytes32(data []u8, idx int) []u8 {
	return decode_word(data, idx)
}

// decode_string reads a dynamic string given the word index of its offset
// pointer (offset is relative to the start of `data`).
pub fn decode_string(data []u8, offset_word_idx int) string {
	offset := int(decode_uint(data, offset_word_idx))
	if offset + 32 > data.len {
		return ''
	}
	mut len_bytes := data[offset..offset + 32].clone()
	mut length := u64(0)
	for i in 24 .. 32 {
		length = (length << u32(8)) | u64(len_bytes[i])
	}
	start := offset + 32
	end := start + int(length)
	if end > data.len {
		return ''
	}
	return data[start..end].bytestr()
}

// decode_string_array reads a dynamic string[] given the word index of its
// offset pointer. Used for listBranches()/collaborators() style returns
// only where element type is address (fixed) -- kept generic enough for
// bytes32[]/address[] via decode_fixed_array below; string[] not currently
// needed by this CLI but included for completeness of the ABI helper set.
pub fn decode_bytes32_array(data []u8, offset_word_idx int) [][]u8 {
	offset := int(decode_uint(data, offset_word_idx))
	if offset + 32 > data.len {
		return [][]u8{}
	}
	length := int(decode_uint_at_byte(data, offset))
	mut out := [][]u8{cap: length}
	start := offset + 32
	for i in 0 .. length {
		s := start + i * 32
		if s + 32 > data.len {
			break
		}
		out << data[s..s + 32].clone()
	}
	return out
}

fn decode_uint_at_byte(data []u8, byte_offset int) u64 {
	mut v := u64(0)
	for i in 24 .. 32 {
		v = (v << u32(8)) | u64(data[byte_offset + i])
	}
	return v
}

// decode_bytes_dyn reads a dynamic `bytes` value given the word index of
// its offset pointer, relative to the start of `data`. Same layout as
// decode_string, but returns raw bytes instead of interpreting as UTF-8.
pub fn decode_bytes_dyn(data []u8, offset_word_idx int) []u8 {
	offset := int(decode_uint(data, offset_word_idx))
	if offset + 32 > data.len {
		return []u8{}
	}
	length := int(decode_uint_at_byte(data, offset))
	start := offset + 32
	end := start + length
	if end > data.len {
		return []u8{}
	}
	return data[start..end].clone()
}

pub fn decode_string_array(data []u8, offset_word_idx int) []string {
	offset := int(decode_uint(data, offset_word_idx))
	if offset + 32 > data.len {
		return []string{}
	}
	length := int(decode_uint_at_byte(data, offset))
	mut out := []string{cap: length}
	// Each element is itself an offset, relative to the start of this array's data (i.e. `offset`).
	for i in 0 .. length {
		rel_word := offset + 32 + i * 32
		elem_offset := int(decode_uint_at_byte(data, rel_word))
		abs_pos := offset + 32 + elem_offset
		if abs_pos + 32 > data.len {
			continue
		}
		elen := int(decode_uint_at_byte(data, abs_pos))
		s := abs_pos + 32
		e := s + elen
		if e > data.len {
			continue
		}
		out << data[s..e].bytestr()
	}
	return out
}
