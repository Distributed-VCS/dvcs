module main

// A fixed 32-byte key for tests that exercise AES-GCM's own correctness
// (encrypt/decrypt/tamper-detection). AES-GCM doesn't care how a key was
// derived -- PBKDF2's job is covered separately below -- so using a fixed
// key here keeps this file fast instead of paying PBKDF2's deliberately
// expensive cost on every single test.
fn dummy_key() []u8 {
	mut k := []u8{len: 32}
	for i in 0 .. 32 {
		k[i] = u8(i * 7 + 1)
	}
	return k
}

// Low iteration count for tests that only check the KDF's *properties*
// (determinism, sensitivity to inputs) rather than its production cost.
const test_kdf_iterations = 50

fn test_derive_key_n_deterministic() {
	salt := [u8(1), 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
	k1 := derive_key_n('same passphrase', salt, test_kdf_iterations)
	k2 := derive_key_n('same passphrase', salt, test_kdf_iterations)
	assert bytes_to_hex(k1) == bytes_to_hex(k2)
}

fn test_derive_key_n_length_is_32_bytes() {
	salt := random_salt()
	k := derive_key_n('any passphrase', salt, test_kdf_iterations)
	assert k.len == 32 // AES-256
}

fn test_derive_key_n_different_passphrase_different_key() {
	salt := [u8(1), 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
	k1 := derive_key_n('passphrase-a', salt, test_kdf_iterations)
	k2 := derive_key_n('passphrase-b', salt, test_kdf_iterations)
	assert bytes_to_hex(k1) != bytes_to_hex(k2)
}

fn test_derive_key_n_different_salt_different_key() {
	salt_a := [u8(1), 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
	salt_b := [u8(16), 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1]
	k1 := derive_key_n('same passphrase', salt_a, test_kdf_iterations)
	k2 := derive_key_n('same passphrase', salt_b, test_kdf_iterations)
	assert bytes_to_hex(k1) != bytes_to_hex(k2)
}

fn test_derive_key_n_different_iterations_different_key() {
	salt := random_salt()
	k1 := derive_key_n('pw', salt, 10)
	k2 := derive_key_n('pw', salt, 20)
	assert bytes_to_hex(k1) != bytes_to_hex(k2)
}

fn test_derive_key_production_path_sanity() {
	// The one test that pays the full, deliberately-expensive production
	// PBKDF2 cost (200,000 iterations) -- confirms the real `derive_key`
	// used by push/pull actually works end to end, without every other
	// test in this file paying that cost too.
	k := derive_key('production passphrase', random_salt())
	assert k.len == 32
}

fn test_random_salt_length() {
	s := random_salt()
	assert s.len == 16
}

fn test_random_salt_is_actually_random() {
	s1 := random_salt()
	s2 := random_salt()
	// Astronomically unlikely to collide if the RNG is working.
	assert bytes_to_hex(s1) != bytes_to_hex(s2)
}

fn test_verification_tag_deterministic() {
	key := dummy_key()
	t1 := verification_tag(key)
	t2 := verification_tag(key)
	assert t1 == t2
}

fn test_verification_tag_differs_for_different_keys() {
	mut k2 := dummy_key()
	k2[0] = k2[0] ^ 0xff
	assert verification_tag(dummy_key()) != verification_tag(k2)
}

fn test_encrypt_decrypt_roundtrip() {
	key := dummy_key()
	plaintext := 'hello, this is secret file content'.bytes()
	blob_hash := keccak256(plaintext)

	ciphertext := encrypt_blob(key, blob_hash, plaintext)
	decrypted := decrypt_blob(key, blob_hash, ciphertext) or {
		assert false, 'decryption should have succeeded: ${err}'
		return
	}
	assert decrypted.bytestr() == plaintext.bytestr()
}

fn test_encrypt_produces_different_ciphertext_each_time() {
	// Random nonce per encryption -- same plaintext should NOT produce
	// identical ciphertext twice (that would indicate nonce reuse, a real
	// AES-GCM vulnerability).
	key := dummy_key()
	plaintext := 'identical content'.bytes()
	blob_hash := keccak256(plaintext)

	c1 := encrypt_blob(key, blob_hash, plaintext)
	c2 := encrypt_blob(key, blob_hash, plaintext)
	assert bytes_to_hex(c1) != bytes_to_hex(c2)

	// But both should still decrypt to the same plaintext.
	d1 := decrypt_blob(key, blob_hash, c1) or {
		assert false, 'd1 failed: ${err}'
		return
	}
	d2 := decrypt_blob(key, blob_hash, c2) or {
		assert false, 'd2 failed: ${err}'
		return
	}
	assert d1.bytestr() == d2.bytestr()
}

fn test_decrypt_with_wrong_key_fails() {
	right_key := dummy_key()
	mut wrong_key := dummy_key()
	wrong_key[0] = wrong_key[0] ^ 0xff
	plaintext := 'secret'.bytes()
	blob_hash := keccak256(plaintext)

	ciphertext := encrypt_blob(right_key, blob_hash, plaintext)
	decrypt_blob(wrong_key, blob_hash, ciphertext) or { return }
	assert false, 'decryption with the wrong key should have failed but succeeded'
}

fn test_decrypt_with_tampered_ciphertext_fails() {
	key := dummy_key()
	plaintext := 'secret content'.bytes()
	blob_hash := keccak256(plaintext)
	mut ciphertext := encrypt_blob(key, blob_hash, plaintext)

	// Flip a bit somewhere in the middle of the ciphertext (past the
	// nonce) -- AES-GCM's authentication tag must catch this.
	mid := ciphertext.len / 2
	ciphertext[mid] = ciphertext[mid] ^ 0xff

	decrypt_blob(key, blob_hash, ciphertext) or { return }
	assert false, 'decryption of tampered ciphertext should have failed but succeeded'
}

fn test_decrypt_with_wrong_associated_data_fails() {
	// blob_hash is used as AEAD associated data, binding ciphertext to a
	// specific identifier -- decrypting under a DIFFERENT blob_hash (even
	// with the right key) should fail, preventing a ciphertext meant for
	// one blob id from being silently accepted as another's.
	key := dummy_key()
	plaintext := 'secret content'.bytes()
	real_hash := keccak256(plaintext)
	wrong_hash := keccak256('different-identifier'.bytes())

	ciphertext := encrypt_blob(key, real_hash, plaintext)
	decrypt_blob(key, wrong_hash, ciphertext) or { return }
	assert false, 'decryption under the wrong associated data should have failed but succeeded'
}

fn test_decrypt_rejects_too_short_payload() {
	key := dummy_key()
	blob_hash := keccak256('x'.bytes())
	decrypt_blob(key, blob_hash, [u8(1), 2, 3]) or { return } // shorter than the 12-byte nonce
	assert false, 'decryption of a too-short payload should have failed but succeeded'
}

fn test_encrypt_decrypt_empty_plaintext() {
	key := dummy_key()
	plaintext := []u8{}
	blob_hash := keccak256(plaintext)
	ciphertext := encrypt_blob(key, blob_hash, plaintext)
	decrypted := decrypt_blob(key, blob_hash, ciphertext) or {
		assert false, 'should decrypt empty content: ${err}'
		return
	}
	assert decrypted.len == 0
}

fn test_encrypt_decrypt_large_content() {
	key := dummy_key()
	mut plaintext := []u8{cap: 100000}
	for i in 0 .. 100000 {
		plaintext << u8(i % 256)
	}
	blob_hash := keccak256(plaintext)
	ciphertext := encrypt_blob(key, blob_hash, plaintext)
	decrypted := decrypt_blob(key, blob_hash, ciphertext) or {
		assert false, 'should decrypt large content: ${err}'
		return
	}
	assert decrypted.len == plaintext.len
	assert decrypted[50000] == plaintext[50000]
}
