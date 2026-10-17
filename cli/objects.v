module main

import os

// Local object store, conceptually the same idea as git's `.git/objects`:
// content is addressed by the keccak256 hash of its bytes, so identical
// file content is only ever stored once, and any tampering is detectable.

fn objects_dir(repo_root string) string {
	return os.join_path(repo_root, '.dvcs', 'objects')
}

pub fn store_blob(repo_root string, content []u8) [32]u8 {
	h := keccak256(content)
	hex := bytes_to_hex(hash32_to_bytes(h))
	dir := os.join_path(objects_dir(repo_root), hex[..2])
	if !os.exists(dir) {
		os.mkdir_all(dir) or { panic('cannot create object dir: ${err}') }
	}
	path := os.join_path(dir, hex[2..])
	if !os.exists(path) {
		os.write_file(path, content.bytestr()) or { panic('cannot write object: ${err}') }
	}
	return h
}

pub fn load_blob(repo_root string, h [32]u8) ![]u8 {
	hex := bytes_to_hex(hash32_to_bytes(h))
	path := os.join_path(objects_dir(repo_root), hex[..2], hex[2..])
	content := os.read_file(path) or { return error('object ${hex} not found locally') }
	return content.bytes()
}

pub struct TrackedFile {
pub:
	path string
	hash [32]u8
}

// merkle_root computes a pairwise (Bitcoin/RFC 6962-style) keccak256 Merkle
// root over the leaves `keccak256(path || blobHash)` for each tracked file,
// sorted by path so the root is independent of add/staging order.
pub fn merkle_root(files []TrackedFile) [32]u8 {
	if files.len == 0 {
		return keccak256([]u8{})
	}
	mut sorted := files.clone()
	sorted.sort(a.path < b.path)

	mut level := [][32]u8{cap: sorted.len}
	for f in sorted {
		mut leaf_input := []u8{}
		leaf_input << f.path.bytes()
		leaf_input << hash32_to_bytes(f.hash)
		level << keccak256(leaf_input)
	}

	for level.len > 1 {
		mut next := [][32]u8{cap: (level.len + 1) / 2}
		mut i := 0
		for i < level.len {
			if i + 1 < level.len {
				mut combined := []u8{}
				combined << hash32_to_bytes(level[i])
				combined << hash32_to_bytes(level[i + 1])
				next << keccak256(combined)
			} else {
				// odd one out: duplicate, standard Merkle-tree convention
				mut combined := []u8{}
				combined << hash32_to_bytes(level[i])
				combined << hash32_to_bytes(level[i])
				next << keccak256(combined)
			}
			i += 2
		}
		level = next.clone()
	}
	return level[0]
}
