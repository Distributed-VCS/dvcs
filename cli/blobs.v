module main

pub fn chunk_bytes(data []u8, chunk_size int) [][]u8 {
	if data.len == 0 {
		return [[]u8{}]
	}
	mut out := [][]u8{}
	mut i := 0
	for i < data.len {
		end := if i + chunk_size < data.len { i + chunk_size } else { data.len }
		out << data[i..end].clone()
		i = end
	}
	return out
}

// push_blob_if_needed encrypts (if `key` is given) and chunks `plaintext`,
// then pushes it via pushBlobChunk -- unless the contract already has it
// (common when a file is unchanged between commits). `blob_hash` must be
// keccak256(plaintext) regardless of encryption. Chunks are capped at
// MAX_CHUNK_BYTES on the contract side; default_chunk_size here stays
// comfortably under that so a chunk transaction never risks failing
// because of its own size.
fn push_blob_if_needed(root string, cfg RepoConfig, repo_id_bytes []u8, blob_hash [32]u8, plaintext []u8, key []u8) ! {
	blob_hash_bytes := hash32_to_bytes(blob_hash)

	already := blob_announced_onchain(cfg, repo_id_bytes, blob_hash_bytes)!
	if already {
		return
	}

	encrypted := key.len > 0
	payload := if encrypted { encrypt_blob(key, blob_hash, plaintext) } else { plaintext }
	chunks := chunk_bytes(payload, default_chunk_size)

	for idx, chunk in chunks {
		calldata := encode_call(contract_signatures()['pushBlobChunk'], [
			av_bytes32(repo_id_bytes),
			av_bytes32(blob_hash_bytes),
			av_uint(u64(idx)),
			av_uint(u64(chunks.len)),
			av_bool(encrypted),
			av_bytes(chunk),
		])
		data_hex := '0x' + bytes_to_hex(calldata)
		tx := eth_send_transaction(cfg.rpc_url, cfg.account, cfg.contract, data_hex, '')!
		receipt := wait_for_receipt(cfg.rpc_url, tx, 60)!
		if receipt.status != '0x1' {
			return error('pushBlobChunk reverted for blob ${hash32_to_hex(blob_hash)} chunk ${idx}/${chunks.len} (tx ${tx})')
		}
		append_changelog(root, 'push-blob-chunk', 'blob=${hash32_to_hex(blob_hash)} chunk=${idx}/${chunks.len} encrypted=${encrypted}',
			tx)
	}
}

fn blob_announced_onchain(cfg RepoConfig, repo_id_bytes []u8, blob_hash_bytes []u8) !bool {
	calldata := encode_call(contract_signatures()['blobAnnounced'], [
		av_bytes32(repo_id_bytes),
		av_bytes32(blob_hash_bytes),
	])
	result_hex := eth_call(cfg.rpc_url, cfg.contract, '0x' + bytes_to_hex(calldata))!
	data := hex_to_bytes(result_hex)
	if data.len < 32 {
		return false
	}
	return decode_bool(data, 0)
}

// fetch_blob reconstructs a blob's plaintext content by reading every
// BlobChunk event for (repoId, blobHash) via eth_getLogs, concatenating in
// chunk order, decrypting if needed, and verifying the result actually
// hashes to `blob_hash`.
pub fn fetch_blob(cfg RepoConfig, repo_id_bytes []u8, blob_hash [32]u8, key []u8) ![]u8 {
	blob_hash_bytes := hash32_to_bytes(blob_hash)
	event_sig := hash32_to_hex(keccak256_str(blob_chunk_event_signature))
	repo_topic := '0x' + bytes_to_hex(left_pad32(repo_id_bytes))
	blob_topic := '0x' + bytes_to_hex(left_pad32(blob_hash_bytes))

	logs := eth_get_logs(cfg.rpc_url, cfg.contract, [event_sig, repo_topic, blob_topic])!
	if logs.len == 0 {
		return error('no on-chain content found for blob ${hash32_to_hex(blob_hash)} -- has it been pushed?')
	}

	mut chunks := map[int][]u8{}
	mut total := -1
	mut encrypted := false
	for log in logs {
		data := hex_to_bytes(log.data)
		chunk_index := int(decode_uint(data, 0))
		total_chunks := int(decode_uint(data, 1))
		enc := decode_bool(data, 2)
		payload := decode_bytes_dyn(data, 3)
		chunks[chunk_index] = payload
		total = total_chunks
		encrypted = enc
	}

	mut assembled := []u8{}
	for i in 0 .. total {
		if i !in chunks {
			return error('missing chunk ${i}/${total} for blob ${hash32_to_hex(blob_hash)}; on-chain data incomplete')
		}
		assembled << chunks[i]
	}

	if encrypted {
		if key.len == 0 {
			return error('blob ${hash32_to_hex(blob_hash)} is encrypted; supply the passphrase (--passphrase or DVCS_PASSPHRASE)')
		}
		return decrypt_blob(key, blob_hash, assembled)!
	}
	got_hash := keccak256(assembled)
	if hash32_to_hex(got_hash) != hash32_to_hex(blob_hash) {
		return error('fetched content for blob ${hash32_to_hex(blob_hash)} does not match its hash -- corrupted or incomplete')
	}
	return assembled
}

// build_manifest serializes a commit's path -> blobHash map into the
// simple "path\tblobHash\n" format that gets pushed on-chain as its own
// blob, so a puller can learn which files a commit tracks without needing
// off-chain access to whoever pushed it.
pub fn build_manifest(files map[string]string) []u8 {
	mut paths := files.keys()
	paths.sort()
	mut lines := []string{}
	for p in paths {
		lines << '${p}\t${files[p]}'
	}
	return (lines.join('\n') + '\n').bytes()
}

pub fn parse_manifest(data []u8) map[string]string {
	mut out := map[string]string{}
	content := data.bytestr()
	for line in content.split_into_lines() {
		if line.trim_space().len == 0 {
			continue
		}
		parts := line.split('\t')
		if parts.len == 2 {
			out[parts[0]] = parts[1]
		}
	}
	return out
}

pub const onchain_cid_prefix = 'onchain:'

// repo_salt_identifier is a deterministic (not content-derived) on-chain
// identifier for a repo's KDF salt, computed the same way by anyone who
// knows the repo id -- so a collaborator can discover the salt without any
// prior communication with whoever ran `crypto-init`. The salt itself is
// not secret (that's the point of a KDF salt); only the passphrase is,
// and that never goes on-chain in any form.
pub fn repo_salt_identifier(repo_id_bytes []u8) [32]u8 {
	mut buf := []u8{}
	buf << 'dvcs:salt:'.bytes()
	buf << repo_id_bytes
	return keccak256(buf)
}

// fetch_raw reconstructs whatever bytes were pushed under `id_hash` from
// BlobChunk events, with no encryption and no content-hash verification
// (unlike fetch_blob) -- used for values like the salt above where the
// identifier is deterministic rather than a hash of the content itself.
// Returns none rather than an error if nothing is found, since "this repo
// has no on-chain salt yet" is an expected, non-error outcome.
pub fn fetch_raw(cfg RepoConfig, repo_id_bytes []u8, id_hash [32]u8) ?[]u8 {
	id_bytes := hash32_to_bytes(id_hash)
	event_sig := hash32_to_hex(keccak256_str(blob_chunk_event_signature))
	repo_topic := '0x' + bytes_to_hex(left_pad32(repo_id_bytes))
	id_topic := '0x' + bytes_to_hex(left_pad32(id_bytes))

	logs := eth_get_logs(cfg.rpc_url, cfg.contract, [event_sig, repo_topic, id_topic]) or { return none }
	if logs.len == 0 {
		return none
	}
	mut chunks := map[int][]u8{}
	mut total := -1
	for log in logs {
		data := hex_to_bytes(log.data)
		chunk_index := int(decode_uint(data, 0))
		total_chunks := int(decode_uint(data, 1))
		payload := decode_bytes_dyn(data, 3)
		chunks[chunk_index] = payload
		total = total_chunks
	}
	mut assembled := []u8{}
	for i in 0 .. total {
		if i !in chunks {
			return none
		}
		assembled << chunks[i]
	}
	return assembled
}
