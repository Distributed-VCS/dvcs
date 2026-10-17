module main

import os

// A deliberately small pattern language -- not full .gitignore syntax, but
// covers the common cases: exact paths, directory prefixes ("build/"),
// and single '*' wildcards (e.g. "*.log", "*.tmp").

pub fn load_ignore_patterns(root string) []string {
	path := os.join_path(root, '.dvcsignore')
	content := os.read_file(path) or { return [] }
	mut patterns := []string{}
	for line in content.split_into_lines() {
		l := line.trim_space()
		if l.len == 0 || l.starts_with('#') {
			continue
		}
		patterns << l
	}
	return patterns
}

pub fn is_ignored(rel_path string, patterns []string) bool {
	if rel_path == '.dvcsignore' {
		return false
	}
	basename := os.base(rel_path)
	for p in patterns {
		if p.ends_with('/') {
			dir := p[..p.len - 1]
			if rel_path == dir || rel_path.starts_with(dir + '/') {
				return true
			}
			continue
		}
		if p.contains('*') {
			if glob_match(p, rel_path) || glob_match(p, basename) {
				return true
			}
			continue
		}
		if rel_path == p || basename == p || rel_path.starts_with(p + '/') {
			return true
		}
	}
	return false
}

// glob_match supports patterns with any number of '*' wildcards (each
// matching zero or more characters), which is enough for common cases like
// "*.log", "build/*", "*.tmp*".
fn glob_match(pattern string, text string) bool {
	parts := pattern.split('*')
	if parts.len == 1 {
		return pattern == text
	}
	mut pos := 0
	for i, part in parts {
		if part.len == 0 {
			continue
		}
		if i == 0 {
			if !text.starts_with(part) {
				return false
			}
			pos = part.len
			continue
		}
		if i == parts.len - 1 {
			return text[pos..].ends_with(part)
		}
		idx := text.index_after_(part, pos)
		if idx == -1 {
			return false
		}
		pos = idx + part.len
	}
	return true
}
