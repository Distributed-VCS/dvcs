module main

fn test_keccak256_empty() {
	digest := keccak256_str('')
	assert hash32_to_hex(digest) == '0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470'
}

fn test_keccak256_abc() {
	digest := keccak256_str('abc')
	assert hash32_to_hex(digest) == '0x4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45'
}

fn test_keccak256_hello() {
	digest := keccak256_str('hello')
	assert hash32_to_hex(digest) == '0x1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8'
}

fn test_keccak256_function_selector() {
	// Known ERC-20 transfer(address,uint256) selector.
	digest := keccak256_str('transfer(address,uint256)')
	hex := hash32_to_hex(digest)
	selector := hex[2..10]
	assert selector == 'a9059cbb'
}

fn test_keccak256_deterministic() {
	a := keccak256_str('same input')
	b := keccak256_str('same input')
	assert hash32_to_hex(a) == hash32_to_hex(b)
}

fn test_keccak256_avalanche() {
	// Changing the input should change the digest completely -- a weak
	// sanity check against a broken/degenerate implementation that e.g.
	// ignores part of the input.
	a := keccak256_str('input-a')
	b := keccak256_str('input-b')
	assert hash32_to_hex(a) != hash32_to_hex(b)
}
