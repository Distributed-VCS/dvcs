module main

const hex_chars = '0123456789abcdef'.bytes()

pub fn bytes_to_hex(b []u8) string {
	mut sb := []u8{cap: b.len * 2}
	for v in b {
		sb << hex_chars[v >> 4]
		sb << hex_chars[v & 0x0f]
	}
	return sb.bytestr()
}

pub fn hash32_to_hex(h [32]u8) string {
	mut b := []u8{len: 32}
	for i in 0 .. 32 {
		b[i] = h[i]
	}
	return '0x' + bytes_to_hex(b)
}

fn hex_val(c u8) int {
	if c >= `0` && c <= `9` {
		return int(c - `0`)
	}
	if c >= `a` && c <= `f` {
		return int(c - `a`) + 10
	}
	if c >= `A` && c <= `F` {
		return int(c - `A`) + 10
	}
	return 0
}

pub fn hex_to_bytes(s string) []u8 {
	mut str := s
	if str.starts_with('0x') || str.starts_with('0X') {
		str = str[2..]
	}
	if str.len % 2 != 0 {
		str = '0' + str
	}
	mut out := []u8{cap: str.len / 2}
	b := str.bytes()
	mut i := 0
	for i < b.len {
		hi := hex_val(b[i])
		lo := hex_val(b[i + 1])
		out << u8((u8(hi) << 4) | u8(lo))
		i += 2
	}
	return out
}

// left_pad32 left-pads `b` with zero bytes to 32 bytes (big-endian), as used
// for ABI-encoding fixed-size types (uint*, bytes32, bool, address).
pub fn left_pad32(b []u8) []u8 {
	mut out := []u8{len: 32, init: 0}
	start := 32 - b.len
	for i in 0 .. b.len {
		out[start + i] = b[i]
	}
	return out
}

pub fn u64_to_be_bytes(v u64) []u8 {
	mut out := []u8{len: 8}
	for i in 0 .. 8 {
		out[7 - i] = u8(v >> u32(i * 8))
	}
	return out
}

pub fn hash32_to_bytes(h [32]u8) []u8 {
	mut out := []u8{len: 32}
	for i in 0 .. 32 {
		out[i] = h[i]
	}
	return out
}

pub fn bytes_to_hash32(b []u8) [32]u8 {
	mut out := [32]u8{}
	n := if b.len < 32 { b.len } else { 32 }
	for i in 0 .. n {
		out[i] = b[i]
	}
	return out
}
