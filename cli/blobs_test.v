module main

fn test_chunk_bytes_exact_multiple() {
	data := []u8{len: 40, init: 1}
	chunks := chunk_bytes(data, 10)
	assert chunks.len == 4
	for c in chunks {
		assert c.len == 10
	}
}

fn test_chunk_bytes_remainder() {
	data := []u8{len: 25, init: 1}
	chunks := chunk_bytes(data, 10)
	assert chunks.len == 3
	assert chunks[0].len == 10
	assert chunks[1].len == 10
	assert chunks[2].len == 5
}

fn test_chunk_bytes_smaller_than_chunk_size() {
	data := []u8{len: 3, init: 1}
	chunks := chunk_bytes(data, 100)
	assert chunks.len == 1
	assert chunks[0].len == 3
}

fn test_chunk_bytes_empty() {
	data := []u8{}
	chunks := chunk_bytes(data, 100)
	assert chunks.len == 1
	assert chunks[0].len == 0
}

fn test_chunk_bytes_reassembles_correctly() {
	mut data := []u8{}
	for i in 0 .. 55 {
		data << u8(i)
	}
	chunks := chunk_bytes(data, 8)
	mut reassembled := []u8{}
	for c in chunks {
		reassembled << c
	}
	assert reassembled.len == data.len
	for i in 0 .. data.len {
		assert reassembled[i] == data[i]
	}
}

fn test_manifest_roundtrip() {
	files := {
		'src/main.v':  'aaaa'
		'README.md':   'bbbb'
		'a/b/c.txt':   'cccc'
	}
	bytes := build_manifest(files)
	parsed := parse_manifest(bytes)
	assert parsed.len == 3
	assert parsed['src/main.v'] == 'aaaa'
	assert parsed['README.md'] == 'bbbb'
	assert parsed['a/b/c.txt'] == 'cccc'
}

fn test_manifest_empty() {
	files := map[string]string{}
	bytes := build_manifest(files)
	parsed := parse_manifest(bytes)
	assert parsed.len == 0
}

fn test_manifest_deterministic_order() {
	// build_manifest sorts by path, so identical file sets should always
	// serialize to identical bytes regardless of map iteration order.
	files := {
		'z.txt': 'h1'
		'a.txt': 'h2'
		'm.txt': 'h3'
	}
	b1 := build_manifest(files)
	b2 := build_manifest(files)
	assert b1.bytestr() == b2.bytestr()
	assert b1.bytestr().index('a.txt') or { -1 } < b1.bytestr().index('m.txt') or { -1 }
}
