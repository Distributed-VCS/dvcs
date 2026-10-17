module main

import os
import time

pub const dvcs_dir_name = '.dvcs'

pub struct RepoConfig {
pub mut:
	rpc_url     string
	contract    string
	account     string
	owner       string
	name        string
	repo_id     string
	encrypt     bool
	salt        string // hex, safe to store -- not secret on its own
	verify_tag  string // hex sha256(derived key) -- lets the CLI check a
	// passphrase is correct before trying to decrypt anything with it
}

pub fn dvcs_root() !string {
	mut dir := os.getwd()
	for {
		candidate := os.join_path(dir, dvcs_dir_name)
		if os.is_dir(candidate) {
			return dir
		}
		parent := os.dir(dir)
		if parent == dir {
			return error('not a dvcs repository (or any parent up to /): run `dvcs init` first')
		}
		dir = parent
	}
	return error('not a dvcs repository')
}

fn config_path(root string) string {
	return os.join_path(root, dvcs_dir_name, 'config')
}

pub fn read_config(root string) !RepoConfig {
	path := config_path(root)
	content := os.read_file(path) or { return error('cannot read config: ${err}') }
	mut cfg := RepoConfig{}
	for line in content.split_into_lines() {
		l := line.trim_space()
		if l.len == 0 || l.starts_with('#') {
			continue
		}
		parts := l.split_nth('=', 2)
		if parts.len != 2 {
			continue
		}
		key := parts[0].trim_space()
		val := parts[1].trim_space()
		match key {
			'rpc_url' { cfg.rpc_url = val }
			'contract' { cfg.contract = val }
			'account' { cfg.account = val }
			'owner' { cfg.owner = val }
			'name' { cfg.name = val }
			'repo_id' { cfg.repo_id = val }
			'encrypt' { cfg.encrypt = val == 'true' }
			'salt' { cfg.salt = val }
			'verify_tag' { cfg.verify_tag = val }
			else {}
		}
	}
	return cfg
}

pub fn write_config(root string, cfg RepoConfig) ! {
	mut lines := []string{}
	lines << 'rpc_url=${cfg.rpc_url}'
	lines << 'contract=${cfg.contract}'
	lines << 'account=${cfg.account}'
	lines << 'owner=${cfg.owner}'
	lines << 'name=${cfg.name}'
	lines << 'repo_id=${cfg.repo_id}'
	lines << 'encrypt=${cfg.encrypt}'
	lines << 'salt=${cfg.salt}'
	lines << 'verify_tag=${cfg.verify_tag}'
	os.write_file(config_path(root), lines.join('\n') + '\n') or {
		return error('cannot write config: ${err}')
	}
}

// --- HEAD / refs ---

fn head_path(root string) string {
	return os.join_path(root, dvcs_dir_name, 'HEAD')
}

pub fn current_branch(root string) string {
	path := head_path(root)
	content := os.read_file(path) or { return 'main' }
	trimmed := content.trim_space()
	prefix := 'ref: refs/heads/'
	if trimmed.starts_with(prefix) {
		return trimmed[prefix.len..]
	}
	return 'main'
}

pub fn set_current_branch(root string, branch string) {
	os.write_file(head_path(root), 'ref: refs/heads/${branch}\n') or {
		panic('cannot write HEAD: ${err}')
	}
}

fn ref_path(root string, branch string) string {
	return os.join_path(root, dvcs_dir_name, 'refs', 'heads', branch)
}

pub fn local_branch_head(root string, branch string) ?string {
	path := ref_path(root, branch)
	content := os.read_file(path) or { return none }
	h := content.trim_space()
	if h.len == 0 {
		return none
	}
	return h
}

pub fn set_local_branch_head(root string, branch string, commit_hash string) {
	dir := os.join_path(root, dvcs_dir_name, 'refs', 'heads')
	if !os.exists(dir) {
		os.mkdir_all(dir) or { panic('cannot create refs dir: ${err}') }
	}
	os.write_file(ref_path(root, branch), commit_hash + '\n') or {
		panic('cannot write ref: ${err}')
	}
}

pub fn list_local_branches(root string) []string {
	dir := os.join_path(root, dvcs_dir_name, 'refs', 'heads')
	if !os.exists(dir) {
		return []
	}
	entries := os.ls(dir) or { return [] }
	mut out := entries.clone()
	out.sort()
	return out
}

pub fn delete_local_branch(root string, branch string) ! {
	path := ref_path(root, branch)
	if !os.exists(path) {
		return error('no such local branch "${branch}"')
	}
	os.rm(path) or { return error('cannot delete branch ref: ${err}') }
}

// --- staging index ---

fn index_path(root string) string {
	return os.join_path(root, dvcs_dir_name, 'index')
}

pub fn read_index(root string) map[string]string {
	mut idx := map[string]string{}
	content := os.read_file(index_path(root)) or { return idx }
	for line in content.split_into_lines() {
		if line.trim_space().len == 0 {
			continue
		}
		parts := line.split('\t')
		if parts.len == 2 {
			idx[parts[0]] = parts[1]
		}
	}
	return idx
}

pub fn write_index(root string, idx map[string]string) {
	mut paths := idx.keys()
	paths.sort()
	mut lines := []string{}
	for p in paths {
		lines << '${p}\t${idx[p]}'
	}
	os.write_file(index_path(root), lines.join('\n') + '\n') or {
		panic('cannot write index: ${err}')
	}
}

// --- local commit metadata cache (mirrors what gets pushed on-chain, plus
//     the file list needed to materialize a working tree on checkout) ---

fn commit_meta_path(root string, commit_hash string) string {
	h := commit_hash.replace('0x', '')
	return os.join_path(root, dvcs_dir_name, 'commit-meta', h + '.txt')
}

pub struct LocalCommit {
pub mut:
	parent1   string
	parent2   string
	tree_root string
	message   string
	author    string
	timestamp u64
	cid       string
	files     map[string]string // path -> blob hash hex
}

pub fn save_local_commit(root string, commit_hash string, c LocalCommit) {
	dir := os.join_path(root, dvcs_dir_name, 'commit-meta')
	if !os.exists(dir) {
		os.mkdir_all(dir) or { panic('cannot create commit-meta dir: ${err}') }
	}
	mut lines := []string{}
	lines << 'parent1=${c.parent1}'
	lines << 'parent2=${c.parent2}'
	lines << 'tree_root=${c.tree_root}'
	lines << 'author=${c.author}'
	lines << 'timestamp=${c.timestamp}'
	lines << 'cid=${c.cid}'
	// message may contain newlines; store it last, everything after the
	// marker line belongs to the message so we don't need escaping.
	lines << 'message>>>'
	lines << c.message
	lines << '<<<message'
	mut file_paths := c.files.keys()
	file_paths.sort()
	for p in file_paths {
		lines << 'file\t${p}\t${c.files[p]}'
	}
	os.write_file(commit_meta_path(root, commit_hash), lines.join('\n') + '\n') or {
		panic('cannot write commit metadata: ${err}')
	}
}

pub fn load_local_commit(root string, commit_hash string) ?LocalCommit {
	content := os.read_file(commit_meta_path(root, commit_hash)) or { return none }
	lines := content.split_into_lines()
	mut c := LocalCommit{}
	mut i := 0
	for i < lines.len {
		line := lines[i]
		if line.starts_with('parent1=') {
			c.parent1 = line['parent1='.len..]
		} else if line.starts_with('parent2=') {
			c.parent2 = line['parent2='.len..]
		} else if line.starts_with('tree_root=') {
			c.tree_root = line['tree_root='.len..]
		} else if line.starts_with('author=') {
			c.author = line['author='.len..]
		} else if line.starts_with('timestamp=') {
			c.timestamp = line['timestamp='.len..].u64()
		} else if line.starts_with('cid=') {
			c.cid = line['cid='.len..]
		} else if line == 'message>>>' {
			mut msg_lines := []string{}
			i += 1
			for i < lines.len && lines[i] != '<<<message' {
				msg_lines << lines[i]
				i += 1
			}
			c.message = msg_lines.join('\n')
		} else if line.starts_with('file\t') {
			parts := line.split('\t')
			if parts.len == 3 {
				c.files[parts[1]] = parts[2]
			}
		}
		i += 1
	}
	return c
}

pub fn now_unix() u64 {
	return u64(time.now().unix())
}
