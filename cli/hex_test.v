module main

fn test_hex_roundtrip() {
	original := [u8(0), 1, 2, 254, 255, 16, 128]
	hex := bytes_to_hex(original)
	back := hex_to_bytes(hex)
	assert back.len == original.len
	for i in 0 .. original.len {
		assert back[i] == original[i]
	}
}

fn test_hex_to_bytes_with_0x_prefix() {
	b := hex_to_bytes('0xdeadbeef')
	assert b.len == 4
	assert b[0] == 0xde
	assert b[1] == 0xad
	assert b[2] == 0xbe
	assert b[3] == 0xef
}

fn test_hex_to_bytes_without_prefix() {
	b := hex_to_bytes('deadbeef')
	assert b.len == 4
	assert b[0] == 0xde
}

fn test_left_pad32() {
	b := left_pad32([u8(1), 2, 3])
	assert b.len == 32
	for i in 0 .. 29 {
		assert b[i] == 0
	}
	assert b[29] == 1
	assert b[30] == 2
	assert b[31] == 3
}

fn test_u64_to_be_bytes() {
	b := u64_to_be_bytes(u64(0x0102030405060708))
	assert b.len == 8
	assert b[0] == 0x01
	assert b[7] == 0x08
}

fn test_hash32_roundtrip() {
	digest := keccak256_str('test')
	b := hash32_to_bytes(digest)
	back := bytes_to_hash32(b)
	for i in 0 .. 32 {
		assert digest[i] == back[i]
	}
}

fn test_hash32_to_hex_format() {
	digest := keccak256_str('')
	hex := hash32_to_hex(digest)
	assert hex.starts_with('0x')
	assert hex.len == 66 // 0x + 64 hex chars
}
