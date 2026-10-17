module main

fn test_merge3_no_conflict_unchanged() {
	base := {
		'a.txt': 'h1'
	}
	ours := {
		'a.txt': 'h1'
	}
	theirs := {
		'a.txt': 'h1'
	}
	r := merge3_files(base, ours, theirs)
	assert r.conflicts.len == 0
	assert r.files['a.txt'] == 'h1'
}

fn test_merge3_ours_changed_theirs_unchanged() {
	base := {
		'a.txt': 'h1'
	}
	ours := {
		'a.txt': 'h2'
	}
	theirs := {
		'a.txt': 'h1'
	}
	r := merge3_files(base, ours, theirs)
	assert r.conflicts.len == 0
	assert r.files['a.txt'] == 'h2'
}

fn test_merge3_theirs_changed_ours_unchanged() {
	base := {
		'a.txt': 'h1'
	}
	ours := {
		'a.txt': 'h1'
	}
	theirs := {
		'a.txt': 'h3'
	}
	r := merge3_files(base, ours, theirs)
	assert r.conflicts.len == 0
	assert r.files['a.txt'] == 'h3'
}

fn test_merge3_both_changed_same_way_no_conflict() {
	base := {
		'a.txt': 'h1'
	}
	ours := {
		'a.txt': 'h9'
	}
	theirs := {
		'a.txt': 'h9'
	}
	r := merge3_files(base, ours, theirs)
	assert r.conflicts.len == 0
	assert r.files['a.txt'] == 'h9'
}

fn test_merge3_both_changed_differently_is_conflict() {
	base := {
		'a.txt': 'h1'
	}
	ours := {
		'a.txt': 'h2'
	}
	theirs := {
		'a.txt': 'h3'
	}
	r := merge3_files(base, ours, theirs)
	assert r.conflicts.len == 1
	assert r.conflicts[0] == 'a.txt'
}

fn test_merge3_addition_only_ours() {
	base := map[string]string{}
	ours := {
		'new.txt': 'h1'
	}
	theirs := map[string]string{}
	r := merge3_files(base, ours, theirs)
	assert r.conflicts.len == 0
	assert r.files['new.txt'] == 'h1'
}

fn test_merge3_addition_only_theirs() {
	base := map[string]string{}
	ours := map[string]string{}
	theirs := {
		'new.txt': 'h1'
	}
	r := merge3_files(base, ours, theirs)
	assert r.conflicts.len == 0
	assert r.files['new.txt'] == 'h1'
}

fn test_merge3_addition_both_same_content_no_conflict() {
	base := map[string]string{}
	ours := {
		'new.txt': 'h1'
	}
	theirs := {
		'new.txt': 'h1'
	}
	r := merge3_files(base, ours, theirs)
	assert r.conflicts.len == 0
	assert r.files['new.txt'] == 'h1'
}

fn test_merge3_addition_both_different_content_is_conflict() {
	base := map[string]string{}
	ours := {
		'new.txt': 'h1'
	}
	theirs := {
		'new.txt': 'h2'
	}
	r := merge3_files(base, ours, theirs)
	assert r.conflicts.len == 1
	assert r.conflicts[0] == 'new.txt'
}

fn test_merge3_delete_ours_unchanged_theirs() {
	base := {
		'a.txt': 'h1'
	}
	ours := map[string]string{} // ours deleted it
	theirs := {
		'a.txt': 'h1'
	} // theirs unchanged
	r := merge3_files(base, ours, theirs)
	assert r.conflicts.len == 0
	assert 'a.txt' !in r.files
}

fn test_merge3_delete_theirs_modify_ours_is_conflict() {
	base := {
		'a.txt': 'h1'
	}
	ours := {
		'a.txt': 'h2'
	} // ours modified it
	theirs := map[string]string{} // theirs deleted it
	r := merge3_files(base, ours, theirs)
	assert r.conflicts.len == 1
	assert r.conflicts[0] == 'a.txt'
}

fn test_merge3_delete_both_no_conflict() {
	base := {
		'a.txt': 'h1'
	}
	ours := map[string]string{}
	theirs := map[string]string{}
	r := merge3_files(base, ours, theirs)
	assert r.conflicts.len == 0
	assert 'a.txt' !in r.files
}

fn test_merge3_unrelated_paths_independent() {
	base := {
		'a.txt': 'h1'
		'b.txt': 'h1'
	}
	ours := {
		'a.txt': 'h2'
		'b.txt': 'h1'
	}
	theirs := {
		'a.txt': 'h1'
		'b.txt': 'h3'
	}
	r := merge3_files(base, ours, theirs)
	assert r.conflicts.len == 0
	assert r.files['a.txt'] == 'h2'
	assert r.files['b.txt'] == 'h3'
}

fn test_apply_strategy_ours() {
	base := {
		'a.txt': 'h1'
	}
	ours := {
		'a.txt': 'h2'
	}
	theirs := {
		'a.txt': 'h3'
	}
	r := merge3_files(base, ours, theirs)
	assert r.conflicts.len == 1
	resolved := apply_strategy(r, ours, theirs, 'ours')
	assert resolved['a.txt'] == 'h2'
}

fn test_apply_strategy_theirs() {
	base := {
		'a.txt': 'h1'
	}
	ours := {
		'a.txt': 'h2'
	}
	theirs := {
		'a.txt': 'h3'
	}
	r := merge3_files(base, ours, theirs)
	resolved := apply_strategy(r, ours, theirs, 'theirs')
	assert resolved['a.txt'] == 'h3'
}
