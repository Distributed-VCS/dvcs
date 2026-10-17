module main

import os
import time

// A push can be interrupted at any point (network drop, process killed,
// wrong passphrase discovered halfway through, etc.). Structurally, that's
// already safe: every commit and every blob chunk is its own independent,
// separately-confirmed transaction (see MAX_CHUNK_BYTES in DVCS.sol), and
// `blobAnnounced` / `commitExists` let a re-run of `push` skip anything
// already on-chain rather than resend it. This changelog is the visible
// half of that story: a local, append-only, human-readable record of every
// on-chain action this CLI has taken from this directory, in order, with
// its transaction hash -- so after an interrupted push you can see exactly
// what confirmed and what didn't, without needing an explorer, and `push`
// run again will pick up cleanly from there.

fn changelog_path(root string) string {
	return os.join_path(root, dvcs_dir_name, 'changelog')
}

pub fn append_changelog(root string, action string, details string, tx_hash string) {
	ts := time.now().format_ss()
	tx_field := if tx_hash.len > 0 { tx_hash } else { '-' }
	line := '${ts}\t${action}\t${details}\t${tx_field}\n'
	mut f := os.open_append(changelog_path(root)) or {
		os.write_file(changelog_path(root), line) or { return }
		return
	}
	f.write_string(line) or {}
	f.close()
}

pub struct ChangelogEntry {
pub:
	timestamp string
	action    string
	details   string
	tx_hash   string
}

pub fn read_changelog(root string) []ChangelogEntry {
	content := os.read_file(changelog_path(root)) or { return [] }
	mut out := []ChangelogEntry{}
	for line in content.split_into_lines() {
		if line.trim_space().len == 0 {
			continue
		}
		parts := line.split('\t')
		if parts.len != 4 {
			continue
		}
		out << ChangelogEntry{
			timestamp: parts[0]
			action: parts[1]
			details: parts[2]
			tx_hash: parts[3]
		}
	}
	return out
}
