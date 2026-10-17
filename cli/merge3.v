module main

// A git-style 3-way merge, but at the file-hash level rather than
// line-level (this system has no textual diff/merge -- files are either
// "the same blob" or "different", never partially reconciled). Given the
// state of each tracked path at a common ancestor (`base`), on one side
// (`ours`), and the other (`theirs`), decide the merged result per path:
//
//   ours == theirs                    -> agree, take it (covers both
//                                         sides deleting the same path)
//   base == ours (ours didn't change) -> take theirs
//   base == theirs (theirs didn't change) -> take ours
//   all three differ pairwise         -> CONFLICT
//
// A missing path is represented as an empty string. Returns the merged
// map and the list of conflicting paths (empty map entries for those
// paths in the result -- callers must check conflicts.len before trusting
// the merged map).
pub struct MergeResult {
pub:
	files     map[string]string
	conflicts []string
}

pub fn merge3_files(base map[string]string, ours map[string]string, theirs map[string]string) MergeResult {
	mut all_paths := map[string]bool{}
	for p, _ in base {
		all_paths[p] = true
	}
	for p, _ in ours {
		all_paths[p] = true
	}
	for p, _ in theirs {
		all_paths[p] = true
	}

	mut merged := map[string]string{}
	mut conflicts := []string{}

	mut paths := all_paths.keys()
	paths.sort()
	for p in paths {
		b := base[p] or { '' }
		o := ours[p] or { '' }
		t := theirs[p] or { '' }

		if o == t {
			if o.len > 0 {
				merged[p] = o
			}
			continue
		}
		if b == o {
			// ours unchanged from base -> take theirs (including theirs
			// deleting it, i.e. t == '')
			if t.len > 0 {
				merged[p] = t
			}
			continue
		}
		if b == t {
			// theirs unchanged from base -> keep ours
			if o.len > 0 {
				merged[p] = o
			}
			continue
		}
		// All three differ pairwise: both sides changed this path
		// (possibly one/both deleted it) in incompatible ways.
		conflicts << p
	}

	return MergeResult{
		files: merged
		conflicts: conflicts
	}
}

// apply_strategy resolves conflicts from a MergeResult using a fixed rule
// ('ours' or 'theirs'), for callers that opt out of manual resolution.
// Only meaningful when called with a non-empty conflicts list.
pub fn apply_strategy(result MergeResult, ours map[string]string, theirs map[string]string, strategy string) map[string]string {
	mut out := result.files.clone()
	for p in result.conflicts {
		if strategy == 'theirs' {
			v := theirs[p] or { '' }
			if v.len > 0 {
				out[p] = v
			}
		} else {
			// default / 'ours'
			v := ours[p] or { '' }
			if v.len > 0 {
				out[p] = v
			}
		}
	}
	return out
}
