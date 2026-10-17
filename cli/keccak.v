module main

// Keccak-256 (the Ethereum / Solidity flavour, NOT NIST SHA3-256 which uses
// different padding). This is used everywhere we need a hash that matches
// what `keccak256(...)` produces in the Solidity contract: repository ids,
// commit hashes, function selectors and Merkle tree roots.

const keccak_rounds = 24

const round_constants = [
	u64(0x0000000000000001), u64(0x0000000000008082), u64(0x800000000000808a),
	u64(0x8000000080008000), u64(0x000000000000808b), u64(0x0000000080000001),
	u64(0x8000000080008081), u64(0x8000000000008009), u64(0x000000000000008a),
	u64(0x0000000000000088), u64(0x0000000080008009), u64(0x000000008000000a),
	u64(0x000000008000808b), u64(0x800000000000008b), u64(0x8000000000008089),
	u64(0x8000000000008003), u64(0x8000000000008002), u64(0x8000000000000080),
	u64(0x000000000000800a), u64(0x800000008000000a), u64(0x8000000080008081),
	u64(0x8000000000008080), u64(0x0000000080000001), u64(0x8000000080008008),
]

// Rotation offsets and lane-permutation indices for the combined Rho+Pi
// step, in the standard (Saarinen public-domain) ordering: rotc[i] is the
// rotation applied when moving the lane that ends up at piln[i].
const rotc = [
	1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 2, 14,
	27, 41, 56, 8, 25, 43, 62, 18, 39, 61, 20, 44,
]

const piln = [
	10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4,
	15, 23, 19, 13, 12, 2, 20, 14, 22, 9, 6, 1,
]

fn rotl64(x u64, n int) u64 {
	if n == 0 {
		return x
	}
	return (x << u32(n)) | (x >> u32(64 - n))
}

struct KeccakState {
mut:
	s [25]u64
}

fn (mut st KeccakState) keccak_f() {
	mut bc := [5]u64{}
	for round := 0; round < keccak_rounds; round++ {
		// Theta
		for i in 0 .. 5 {
			bc[i] = st.s[i] ^ st.s[i + 5] ^ st.s[i + 10] ^ st.s[i + 15] ^ st.s[i + 20]
		}
		for i in 0 .. 5 {
			t := bc[(i + 4) % 5] ^ rotl64(bc[(i + 1) % 5], 1)
			for j := 0; j < 25; j += 5 {
				st.s[j + i] ^= t
			}
		}

		// Rho + Pi (combined, in-place, standard ordering)
		mut current := st.s[1]
		for i in 0 .. 24 {
			j := piln[i]
			tmp := st.s[j]
			st.s[j] = rotl64(current, rotc[i])
			current = tmp
		}

		// Chi
		for j := 0; j < 25; j += 5 {
			mut row := [5]u64{}
			for i in 0 .. 5 {
				row[i] = st.s[j + i]
			}
			for i in 0 .. 5 {
				st.s[j + i] = row[i] ^ (~row[(i + 1) % 5] & row[(i + 2) % 5])
			}
		}

		// Iota
		st.s[0] ^= round_constants[round]
	}
}

// keccak256 computes the Ethereum-style Keccak-256 digest of `data`.
pub fn keccak256(data []u8) [32]u8 {
	rate_bytes := 136 // 1088 bits for Keccak-256 (capacity = 512 bits)
	mut st := KeccakState{}

	mut offset := 0
	for offset + rate_bytes <= data.len {
		absorb_block(mut st, data[offset..offset + rate_bytes])
		st.keccak_f()
		offset += rate_bytes
	}

	// Final block with Keccak padding: 0x01 ... 0x80 (multi-rate padding,
	// distinct from NIST SHA3's 0x06 domain separator).
	mut last := []u8{len: rate_bytes, init: 0}
	remaining := data.len - offset
	for i in 0 .. remaining {
		last[i] = data[offset + i]
	}
	last[remaining] ^= 0x01
	last[rate_bytes - 1] ^= 0x80
	absorb_block(mut st, last)
	st.keccak_f()

	mut out := [32]u8{}
	for i in 0 .. 4 {
		lane := st.s[i]
		for b in 0 .. 8 {
			out[i * 8 + b] = u8(lane >> u32(b * 8))
		}
	}
	return out
}

fn absorb_block(mut st KeccakState, block []u8) {
	nlanes := block.len / 8
	for i in 0 .. nlanes {
		mut lane := u64(0)
		for b in 0 .. 8 {
			lane |= u64(block[i * 8 + b]) << u32(b * 8)
		}
		st.s[i] ^= lane
	}
}

pub fn keccak256_str(s string) [32]u8 {
	return keccak256(s.bytes())
}
