module main

fn test_ignore_exact_match() {
	patterns := ['.env']
	assert is_ignored('.env', patterns) == true
	// A bare pattern with no path separator matches by basename at any
	// depth, same as .gitignore semantics for "node_modules" etc.
	assert is_ignored('src/.env', patterns) == true
	assert is_ignored('other.txt', patterns) == false
}

fn test_ignore_wildcard_suffix() {
	patterns := ['*.log']
	assert is_ignored('debug.log', patterns) == true
	assert is_ignored('nested/path/debug.log', patterns) == true
	assert is_ignored('debug.txt', patterns) == false
}

fn test_ignore_directory_prefix() {
	patterns := ['build/']
	assert is_ignored('build/output.bin', patterns) == true
	assert is_ignored('build/nested/output.bin', patterns) == true
	assert is_ignored('build', patterns) == true
	assert is_ignored('rebuild/output.bin', patterns) == false
}

fn test_ignore_multiple_patterns() {
	patterns := ['*.log', '.env', 'node_modules/']
	assert is_ignored('app.log', patterns) == true
	assert is_ignored('.env', patterns) == true
	assert is_ignored('node_modules/pkg/index.js', patterns) == true
	assert is_ignored('src/main.v', patterns) == false
}

fn test_ignore_dvcsignore_itself_never_ignored() {
	patterns := ['*']
	assert is_ignored('.dvcsignore', patterns) == false
}

fn test_ignore_empty_patterns_ignores_nothing() {
	patterns := []string{}
	assert is_ignored('anything.txt', patterns) == false
}

fn test_glob_match_prefix_and_suffix() {
	assert glob_match('*.txt', 'readme.txt') == true
	assert glob_match('*.txt', 'readme.md') == false
	assert glob_match('test*', 'test_file.v') == true
	assert glob_match('test*', 'other_test.v') == false
}

fn test_glob_match_multiple_wildcards() {
	assert glob_match('a*b*c', 'axxbyyc') == true
	assert glob_match('a*b*c', 'abc') == true
	assert glob_match('a*b*c', 'axxbyy') == false
}
