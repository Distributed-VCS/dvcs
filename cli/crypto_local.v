module main

import crypto.aes
import crypto.rand
import crypto.pbkdf2
import crypto.sha256

// This is entirely optional and entirely local: the passphrase never
// leaves the machine, and never gets written to chain or to .dvcs/config
// in recoverable form. It exists because pushBlobChunk's event data is
// public to anyone reading the chain, no matter what role a repo's access
// control assigns them -- so "private repo" only means "no IPFS-style
// public URL and no unauthorized writer", not "confidential contents",
// unless the content is encrypted before it's pushed.

const pbkdf2_iterations = 200_000
const key_len = 32 // AES-256
const salt_len = 16
const nonce_len = 12 // AES-GCM standard nonce size

pub fn derive_key(passphrase string, salt []u8) []u8 {
	return derive_key_n(passphrase, salt, pbkdf2_iterations)
}

// derive_key_n is the same derivation with a configurable iteration count.
// Exists so tests can verify the algorithm's *properties* (determinism,
// sensitivity to inputs) with a cheap iteration count instead of paying
// the full, deliberately-expensive production cost on every test run;
// `derive_key` above always uses the real count for anything that touches
// actual encrypted content.
pub fn derive_key_n(passphrase string, salt []u8, iterations int) []u8 {
	return pbkdf2.key(passphrase.bytes(), salt, iterations, key_len, sha256.new()) or {
		panic('key derivation failed: ${err}')
	}
}

pub fn random_salt() []u8 {
	return rand.bytes(salt_len) or { panic('cannot generate salt: ${err}') }
}

// verification_tag lets the CLI check a supplied passphrase is correct
// *before* trying to decrypt anything with it, without ever storing the
// passphrase or key itself -- only this tag goes in .dvcs/config.
pub fn verification_tag(key []u8) string {
	return bytes_to_hex(sha256.sum(key))
}

// encrypt_blob encrypts `plaintext` under `key`, returning
// nonce(12) ++ ciphertext ++ tag(16), ready to be chunked and pushed.
// `blob_hash` (of the plaintext) is bound in as authenticated associated
// data, so a chunk can't be silently reattached to a different blob id.
pub fn encrypt_blob(key []u8, blob_hash [32]u8, plaintext []u8) []u8 {
	gcm := aes.new_aes_gcm(key) or { panic('AES-GCM init failed: ${err}') }
	nonce := rand.bytes(nonce_len) or { panic('cannot generate nonce: ${err}') }
	ciphertext := gcm.encrypt(plaintext, nonce, hash32_to_bytes(blob_hash)) or {
		panic('encryption failed: ${err}')
	}
	mut out := []u8{cap: nonce_len + ciphertext.len}
	out << nonce
	out << ciphertext
	return out
}

// decrypt_blob reverses encrypt_blob and additionally verifies the
// decrypted plaintext actually hashes to `blob_hash`, catching any
// corruption or tampering that (implausibly) got past the GCM tag.
pub fn decrypt_blob(key []u8, blob_hash [32]u8, payload []u8) ![]u8 {
	if payload.len < nonce_len {
		return error('encrypted payload too short')
	}
	nonce := payload[..nonce_len]
	ciphertext := payload[nonce_len..]
	gcm := aes.new_aes_gcm(key) or { return error('AES-GCM init failed: ${err}') }
	plaintext := gcm.decrypt(ciphertext, nonce, hash32_to_bytes(blob_hash)) or {
		return error('decryption failed (wrong passphrase, or data was tampered with): ${err}')
	}
	got_hash := keccak256(plaintext)
	if hash32_to_hex(got_hash) != hash32_to_hex(blob_hash) {
		return error('decrypted content does not match expected hash -- data corruption?')
	}
	return plaintext
}
