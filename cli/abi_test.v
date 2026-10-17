module main

fn test_abi_selector_matches_ethers_reference() {
	// Verified earlier (manually) against ethers.js's own encodeFunctionData
	// output for createRepository("sanitycheck", false) on a live node;
	// pinned here as a regression test.
	calldata := encode_call('createRepository(string,bool)', [av_string('sanitycheck'), av_bool(false)])
	hex := '0x' + bytes_to_hex(calldata)
	expected := '0x4e1e0c6e00000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000b73616e697479636865636b000000000000000000000000000000000000000000'
	assert hex == expected
}

fn test_abi_encode_decode_uint_roundtrip() {
	calldata := encode_call('f(uint256)', [av_uint(42)])
	// skip 4-byte selector, decode word 0
	args := calldata[4..].clone()
	assert decode_uint(args, 0) == 42
}

fn test_abi_encode_decode_bool_roundtrip() {
	calldata_true := encode_call('f(bool)', [av_bool(true)])
	calldata_false := encode_call('f(bool)', [av_bool(false)])
	assert decode_bool(calldata_true[4..].clone(), 0) == true
	assert decode_bool(calldata_false[4..].clone(), 0) == false
}

fn test_abi_encode_decode_address_roundtrip() {
	addr := hex_to_bytes('0x1234567890123456789012345678901234567890')
	calldata := encode_call('f(address)', [av_address(addr)])
	decoded := decode_address(calldata[4..].clone(), 0)
	assert bytes_to_hex(decoded) == bytes_to_hex(addr)
}

fn test_abi_encode_decode_bytes32_roundtrip() {
	digest := keccak256_str('some data')
	b := hash32_to_bytes(digest)
	calldata := encode_call('f(bytes32)', [av_bytes32(b)])
	decoded := decode_bytes32(calldata[4..].clone(), 0)
	assert bytes_to_hex(decoded) == bytes_to_hex(b)
}

fn test_abi_encode_decode_string_roundtrip() {
	calldata := encode_call('f(string)', [av_string('hello world')])
	args := calldata[4..].clone()
	decoded := decode_string(args, 0)
	assert decoded == 'hello world'
}

fn test_abi_encode_decode_bytes_roundtrip() {
	raw := [u8(1), 2, 3, 4, 250, 251, 252]
	calldata := encode_call('f(bytes)', [av_bytes(raw)])
	args := calldata[4..].clone()
	decoded := decode_bytes_dyn(args, 0)
	assert decoded.len == raw.len
	for i in 0 .. raw.len {
		assert decoded[i] == raw[i]
	}
}

fn test_abi_mixed_static_and_dynamic_args() {
	// Mirrors pushBlobChunk's real signature shape: static, static,
	// static, static, static, dynamic -- verifies the head/tail offset
	// bookkeeping doesn't break when only the last arg is dynamic.
	addr := hex_to_bytes('0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')
	raw := [u8(9), 9, 9]
	calldata := encode_call('f(address,uint256,bool,bytes)', [
		av_address(addr),
		av_uint(7),
		av_bool(true),
		av_bytes(raw),
	])
	args := calldata[4..].clone()
	assert bytes_to_hex(decode_address(args, 0)) == bytes_to_hex(addr)
	assert decode_uint(args, 1) == 7
	assert decode_bool(args, 2) == true
	decoded_bytes := decode_bytes_dyn(args, 3)
	assert decoded_bytes.len == 3
	assert decoded_bytes[0] == 9
}

fn test_abi_two_dynamic_args() {
	calldata := encode_call('f(string,string)', [av_string('first'), av_string('second')])
	args := calldata[4..].clone()
	assert decode_string(args, 0) == 'first'
	assert decode_string(args, 1) == 'second'
}
