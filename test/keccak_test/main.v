module main

fn hex_of(b [32]u8) string {
	mut sb := []u8{}
	hex_digits := '0123456789abcdef'.bytes()
	for byte_v in b {
		sb << hex_digits[byte_v >> 4]
		sb << hex_digits[byte_v & 0x0f]
	}
	return sb.bytestr()
}

fn main() {
	// Known Ethereum keccak256 test vectors.
	cases := [
		['', 'c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470'],
		['abc', '4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45'],
		['hello', '1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8'],
	]
	mut all_ok := true
	for c in cases {
		digest := keccak256(c[0].bytes())
		got := hex_of(digest)
		want := c[1]
		ok := got == want
		if !ok {
			all_ok = false
		}
		println('input="${c[0]}" got=${got} want=${want} ok=${ok}')
	}
	// Also verify against the known selector for transfer(address,uint256) = a9059cbb
	sel := keccak256_str('transfer(address,uint256)')
	sel_hex := hex_of(sel)[..8]
	println('transfer(address,uint256) selector = ${sel_hex} (want a9059cbb) ok=${sel_hex == 'a9059cbb'}')
	if sel_hex != 'a9059cbb' {
		all_ok = false
	}
	if !all_ok {
		println('FAILURES DETECTED')
		exit(1)
	}
	println('ALL KECCAK TESTS PASSED')
}
