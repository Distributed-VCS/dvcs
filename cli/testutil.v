module main

import os

// Test-only helpers. Kept in a regular .v file (not *_test.v) so they're
// visible to every test file uniformly, whether V is invoked on a single
// test file (`v test some_test.v`, which only pulls in regular .v files
// plus that one test file) or the whole directory (`v test .`, which
// compiles every file together -- where duplicate definitions across
// multiple _test.v files would collide).

// make_temp_root creates an isolated temp directory with a bare `.dvcs`
// subdirectory (just enough for the functions under test to fill in the
// rest themselves via their own mkdir_all calls), so tests never touch a
// real repo and can run without interfering with each other.
pub fn make_temp_root() string {
	root := os.join_path(os.temp_dir(), 'dvcs_test_${test_rand_suffix()}')
	os.mkdir_all(os.join_path(root, '.dvcs')) or { panic('cannot create temp root: ${err}') }
	return root
}

fn test_rand_suffix() string {
	// Not cryptographic -- just needs to not collide between concurrent
	// test runs on the same machine.
	return (now_unix() * 1000000 + u64(os.getpid()) * 1000 + u64(rand_int_hack())).str()
}

fn rand_int_hack() int {
	// Avoids pulling in the `rand` module just for a tiebreaker; the
	// address of a fresh heap allocation is as good as anything here.
	x := []int{len: 1}
	return int(u64(&x[0]) & 0xffff)
}

pub fn cleanup_temp_root(root string) {
	os.rmdir_all(root) or {}
}
