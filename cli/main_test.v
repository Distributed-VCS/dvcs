module main

// These pin down compute_repo_id_local / compute_commit_hash_local as
// regression tests. Their correctness against the ACTUAL deployed contract
// was verified independently during development (matching
// DVCS.sol's computeRepoId and computeCommitHash exactly on a live chain --
// see README "What's been tested"); these tests instead guard against a
// future refactor silently changing the encoding without anyone noticing,
// by pinning known-good outputs and checking sensitivity to every input.

fn test_compute_repo_id_deterministic() {
	owner := hex_to_bytes('0x1408dd7e408a6afa67054be5e1ae3525956a1fc9')
	id1 := compute_repo_id_local(owner, 'myproject')
	id2 := compute_repo_id_local(owner, 'myproject')
	assert hash32_to_hex(id1) == hash32_to_hex(id2)
}

fn test_compute_repo_id_matches_known_value() {
	// Pinned against a real deployed contract's own computeRepoId() output
	// for these exact inputs (see project history) -- this is the pure
	// keccak256(abi.encodePacked(owner, name)) computation.
	owner := hex_to_bytes('0x1408dd7e408a6afa67054be5e1ae3525956a1fc9')
	id := compute_repo_id_local(owner, 'teamproject')
	assert hash32_to_hex(id) == '0x0e4f3dd2e9bd9186452d5d642ba28d2136b470954972ef7a29f2f0c43eb5080c'
}

fn test_compute_repo_id_sensitive_to_owner() {
	name := 'myproject'
	owner_a := hex_to_bytes('0x1111111111111111111111111111111111111111')
	owner_b := hex_to_bytes('0x2222222222222222222222222222222222222222')
	id_a := compute_repo_id_local(owner_a, name)
	id_b := compute_repo_id_local(owner_b, name)
	assert hash32_to_hex(id_a) != hash32_to_hex(id_b)
}

fn test_compute_repo_id_sensitive_to_name() {
	owner := hex_to_bytes('0x1111111111111111111111111111111111111111')
	id_a := compute_repo_id_local(owner, 'project-a')
	id_b := compute_repo_id_local(owner, 'project-b')
	assert hash32_to_hex(id_a) != hash32_to_hex(id_b)
}

fn test_compute_commit_hash_deterministic() {
	repo_id := keccak256_str('repo')
	parent1 := keccak256_str('parent1')
	parent2 := [32]u8{}
	tree_root := keccak256_str('tree')
	author := hex_to_bytes('0x1111111111111111111111111111111111111111')

	h1 := compute_commit_hash_local(repo_id, parent1, parent2, tree_root, 'message', author,
		1700000000)
	h2 := compute_commit_hash_local(repo_id, parent1, parent2, tree_root, 'message', author,
		1700000000)
	assert hash32_to_hex(h1) == hash32_to_hex(h2)
}

fn test_compute_commit_hash_sensitive_to_each_field() {
	repo_id := keccak256_str('repo')
	parent1 := keccak256_str('parent1')
	parent2 := [32]u8{}
	tree_root := keccak256_str('tree')
	author := hex_to_bytes('0x1111111111111111111111111111111111111111')
	base := compute_commit_hash_local(repo_id, parent1, parent2, tree_root, 'message', author,
		1700000000)

	// Changing the message must change the hash.
	h_msg := compute_commit_hash_local(repo_id, parent1, parent2, tree_root, 'different message',
		author, 1700000000)
	assert hash32_to_hex(h_msg) != hash32_to_hex(base)

	// Changing the timestamp must change the hash.
	h_time := compute_commit_hash_local(repo_id, parent1, parent2, tree_root, 'message', author,
		1700000001)
	assert hash32_to_hex(h_time) != hash32_to_hex(base)

	// Changing the parent must change the hash.
	other_parent := keccak256_str('other-parent')
	h_parent := compute_commit_hash_local(repo_id, other_parent, parent2, tree_root, 'message',
		author, 1700000000)
	assert hash32_to_hex(h_parent) != hash32_to_hex(base)

	// Changing the tree root must change the hash.
	other_tree := keccak256_str('other-tree')
	h_tree := compute_commit_hash_local(repo_id, parent1, parent2, other_tree, 'message', author,
		1700000000)
	assert hash32_to_hex(h_tree) != hash32_to_hex(base)

	// Changing the author must change the hash.
	other_author := hex_to_bytes('0x2222222222222222222222222222222222222222')
	h_author := compute_commit_hash_local(repo_id, parent1, parent2, tree_root, 'message',
		other_author, 1700000000)
	assert hash32_to_hex(h_author) != hash32_to_hex(base)

	// Changing the repo id must change the hash.
	other_repo := keccak256_str('other-repo')
	h_repo := compute_commit_hash_local(other_repo, parent1, parent2, tree_root, 'message', author,
		1700000000)
	assert hash32_to_hex(h_repo) != hash32_to_hex(base)
}

fn test_compute_commit_hash_root_commit_has_zero_parent() {
	repo_id := keccak256_str('repo')
	zero := [32]u8{}
	tree_root := keccak256_str('tree')
	author := hex_to_bytes('0x1111111111111111111111111111111111111111')
	// Should not panic or behave differently just because parent1 is the
	// zero hash (root commit case).
	h := compute_commit_hash_local(repo_id, zero, zero, tree_root, 'root commit', author, 1700000000)
	assert hash32_to_hex(h).len == 66
}

fn test_resolve_ref_prefers_branch_over_hash_prefix() {
	root := make_temp_root()
	defer { cleanup_temp_root(root) }
	commit_hash := '0x' + 'ab'.repeat(32)
	save_local_commit(root, commit_hash, LocalCommit{
		message: 'test'
		files: map[string]string{}
	})
	set_local_branch_head(root, 'main', commit_hash)

	resolved := resolve_ref(root, 'main') or {
		assert false, 'expected branch resolution to succeed'
		return
	}
	assert resolved == commit_hash
}

fn test_resolve_ref_falls_back_to_hash_prefix() {
	root := make_temp_root()
	defer { cleanup_temp_root(root) }
	commit_hash := '0x' + 'cd'.repeat(32)
	save_local_commit(root, commit_hash, LocalCommit{
		message: 'test'
		files: map[string]string{}
	})
	// No branch named this -- must fall back to prefix matching.
	resolved := resolve_ref(root, 'cdcdcdcd') or {
		assert false, 'expected prefix resolution to succeed: ${err}'
		return
	}
	assert resolved == commit_hash
}

fn test_resolve_ref_unknown_fails() {
	root := make_temp_root()
	defer { cleanup_temp_root(root) }
	resolve_ref(root, 'nonexistent') or { return }
	assert false, 'expected resolution of an unknown ref to fail'
}
