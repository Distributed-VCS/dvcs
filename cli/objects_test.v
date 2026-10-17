module main

fn test_merkle_root_empty() {
	files := []TrackedFile{}
	root := merkle_root(files)
	// Defined as keccak256 of an empty byte string.
	assert hash32_to_hex(root) == hash32_to_hex(keccak256([]u8{}))
}

fn test_merkle_root_single_file_deterministic() {
	f := TrackedFile{
		path: 'a.txt'
		hash: keccak256_str('content-a')
	}
	root1 := merkle_root([f])
	root2 := merkle_root([f])
	assert hash32_to_hex(root1) == hash32_to_hex(root2)
}

fn test_merkle_root_order_independent() {
	// Sorted internally by path, so add-order shouldn't matter.
	fa := TrackedFile{
		path: 'a.txt'
		hash: keccak256_str('content-a')
	}
	fb := TrackedFile{
		path: 'b.txt'
		hash: keccak256_str('content-b')
	}
	root_ab := merkle_root([fa, fb])
	root_ba := merkle_root([fb, fa])
	assert hash32_to_hex(root_ab) == hash32_to_hex(root_ba)
}

fn test_merkle_root_changes_with_content() {
	fa := TrackedFile{
		path: 'a.txt'
		hash: keccak256_str('content-a')
	}
	fa_changed := TrackedFile{
		path: 'a.txt'
		hash: keccak256_str('different-content')
	}
	root1 := merkle_root([fa])
	root2 := merkle_root([fa_changed])
	assert hash32_to_hex(root1) != hash32_to_hex(root2)
}

fn test_merkle_root_changes_with_file_count() {
	fa := TrackedFile{
		path: 'a.txt'
		hash: keccak256_str('content-a')
	}
	fb := TrackedFile{
		path: 'b.txt'
		hash: keccak256_str('content-b')
	}
	root_one := merkle_root([fa])
	root_two := merkle_root([fa, fb])
	assert hash32_to_hex(root_one) != hash32_to_hex(root_two)
}

fn test_merkle_root_odd_count_no_crash() {
	// Exercises the "duplicate last node" path for odd-sized levels.
	mut files := []TrackedFile{}
	for i in 0 .. 5 {
		files << TrackedFile{
			path: 'file${i}.txt'
			hash: keccak256_str('content-${i}')
		}
	}
	root := merkle_root(files)
	assert hash32_to_hex(root).len == 66
}
