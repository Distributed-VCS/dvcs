module main

fn test_config_roundtrip() {
	root := make_temp_root()
	defer { cleanup_temp_root(root) }

	cfg := RepoConfig{
		rpc_url: 'http://127.0.0.1:8545'
		contract: '0x1111111111111111111111111111111111111111'
		account: '0x2222222222222222222222222222222222222222'
		owner: '0x2222222222222222222222222222222222222222'
		name: 'myproject'
		repo_id: '0x' + '33'.repeat(32)
		encrypt: true
		salt: 'aabbcc'
		verify_tag: 'ddeeff'
	}
	write_config(root, cfg) or {
		assert false, 'write_config failed: ${err}'
		return
	}
	loaded := read_config(root) or {
		assert false, 'read_config failed: ${err}'
		return
	}
	assert loaded.rpc_url == cfg.rpc_url
	assert loaded.contract == cfg.contract
	assert loaded.account == cfg.account
	assert loaded.owner == cfg.owner
	assert loaded.name == cfg.name
	assert loaded.repo_id == cfg.repo_id
	assert loaded.encrypt == true
	assert loaded.salt == cfg.salt
	assert loaded.verify_tag == cfg.verify_tag
}

fn test_config_encrypt_false_roundtrip() {
	root := make_temp_root()
	defer { cleanup_temp_root(root) }

	cfg := RepoConfig{
		encrypt: false
	}
	write_config(root, cfg) or {
		assert false, 'write_config failed: ${err}'
		return
	}
	loaded := read_config(root) or {
		assert false, 'read_config failed: ${err}'
		return
	}
	assert loaded.encrypt == false
}

fn test_current_branch_defaults_to_main() {
	root := make_temp_root()
	defer { cleanup_temp_root(root) }
	// No HEAD file written yet -- should default sensibly rather than crash.
	assert current_branch(root) == 'main'
}

fn test_set_and_get_current_branch() {
	root := make_temp_root()
	defer { cleanup_temp_root(root) }
	set_current_branch(root, 'develop')
	assert current_branch(root) == 'develop'
}

fn test_branch_head_roundtrip() {
	root := make_temp_root()
	defer { cleanup_temp_root(root) }
	commit_hash := '0x' + 'ab'.repeat(32)
	set_local_branch_head(root, 'main', commit_hash)
	head := local_branch_head(root, 'main') or {
		assert false, 'expected a branch head'
		return
	}
	assert head == commit_hash
}

fn test_branch_head_missing_returns_none() {
	root := make_temp_root()
	defer { cleanup_temp_root(root) }
	head := local_branch_head(root, 'nonexistent')
	assert head == none
}

fn test_list_local_branches() {
	root := make_temp_root()
	defer { cleanup_temp_root(root) }
	set_local_branch_head(root, 'main', '0x' + 'aa'.repeat(32))
	set_local_branch_head(root, 'feature-x', '0x' + 'bb'.repeat(32))
	branches := list_local_branches(root)
	assert branches.len == 2
	assert 'main' in branches
	assert 'feature-x' in branches
}

fn test_list_local_branches_empty_when_none() {
	root := make_temp_root()
	defer { cleanup_temp_root(root) }
	branches := list_local_branches(root)
	assert branches.len == 0
}

fn test_delete_local_branch() {
	root := make_temp_root()
	defer { cleanup_temp_root(root) }
	set_local_branch_head(root, 'to-delete', '0x' + 'cc'.repeat(32))
	assert list_local_branches(root).len == 1
	delete_local_branch(root, 'to-delete') or {
		assert false, 'delete should have succeeded: ${err}'
		return
	}
	assert list_local_branches(root).len == 0
}

fn test_delete_nonexistent_branch_fails() {
	root := make_temp_root()
	defer { cleanup_temp_root(root) }
	delete_local_branch(root, 'never-existed') or { return }
	assert false, 'deleting a nonexistent branch should have failed'
}

fn test_index_roundtrip() {
	root := make_temp_root()
	defer { cleanup_temp_root(root) }
	idx := {
		'src/main.v': 'hash1'
		'README.md':  'hash2'
	}
	write_index(root, idx)
	loaded := read_index(root)
	assert loaded.len == 2
	assert loaded['src/main.v'] == 'hash1'
	assert loaded['README.md'] == 'hash2'
}

fn test_index_empty_when_never_written() {
	root := make_temp_root()
	defer { cleanup_temp_root(root) }
	idx := read_index(root)
	assert idx.len == 0
}

fn test_index_can_be_cleared() {
	root := make_temp_root()
	defer { cleanup_temp_root(root) }
	write_index(root, {
		'a.txt': 'h1'
	})
	assert read_index(root).len == 1
	write_index(root, map[string]string{})
	assert read_index(root).len == 0
}

fn test_local_commit_roundtrip() {
	root := make_temp_root()
	defer { cleanup_temp_root(root) }
	commit_hash := '0x' + 'de'.repeat(32)
	original := LocalCommit{
		parent1: '0x' + '00'.repeat(32)
		parent2: '0x' + '00'.repeat(32)
		tree_root: '0x' + 'ee'.repeat(32)
		message: 'Initial commit'
		author: '0x' + 'ff'.repeat(20)
		timestamp: 1700000000
		cid: 'onchain:abc123'
		files: {
			'src/main.v': 'blobhash1'
			'README.md':  'blobhash2'
		}
	}
	save_local_commit(root, commit_hash, original)
	loaded := load_local_commit(root, commit_hash) or {
		assert false, 'expected to load the saved commit'
		return
	}
	assert loaded.parent1 == original.parent1
	assert loaded.tree_root == original.tree_root
	assert loaded.message == original.message
	assert loaded.author == original.author
	assert loaded.timestamp == original.timestamp
	assert loaded.cid == original.cid
	assert loaded.files.len == 2
	assert loaded.files['src/main.v'] == 'blobhash1'
	assert loaded.files['README.md'] == 'blobhash2'
}

fn test_local_commit_multiline_message_roundtrip() {
	root := make_temp_root()
	defer { cleanup_temp_root(root) }
	commit_hash := '0x' + 'aa'.repeat(32)
	msg := 'Summary line\n\nA longer description\nspanning multiple lines.'
	save_local_commit(root, commit_hash, LocalCommit{
		message: msg
		files: map[string]string{}
	})
	loaded := load_local_commit(root, commit_hash) or {
		assert false, 'expected to load the commit'
		return
	}
	assert loaded.message == msg
}

fn test_local_commit_missing_returns_none() {
	root := make_temp_root()
	defer { cleanup_temp_root(root) }
	result := load_local_commit(root, '0x' + '99'.repeat(32))
	assert result == none
}

fn test_local_commit_empty_files_roundtrip() {
	root := make_temp_root()
	defer { cleanup_temp_root(root) }
	commit_hash := '0x' + 'bb'.repeat(32)
	save_local_commit(root, commit_hash, LocalCommit{
		message: 'no files'
		files: map[string]string{}
	})
	loaded := load_local_commit(root, commit_hash) or {
		assert false, 'expected to load the commit'
		return
	}
	assert loaded.files.len == 0
}
