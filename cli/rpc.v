module main

import net.http
import json2
import time

// This CLI is designed to talk to a local Ethereum-compatible development
// node (Anvil, Hardhat Network, or Ganache) whose accounts are unlocked, so
// `eth_sendTransaction` can be used with a plain `from` address instead of
// requiring the CLI to hold private keys and sign raw transactions itself.
// That is a deliberate scope decision for this prototype -- see README.md
// "Signing model" for the production alternative (local key + eth_sendRawTransaction).

struct RpcError {
	message string
}

const rpc_max_retries = 3
const rpc_retry_base_delay_ms = 150

// Note: JSON-RPC params built in this file always embed hex-encoded data
// (addresses, calldata, tx hashes) rather than arbitrary user text -- commit
// messages, repo/branch names etc. are ABI-encoded into that hex calldata
// before ever reaching here, so no JSON string-escaping is needed.

fn rpc_call(url string, method string, params string) !json2.Any {
	mut last_err := ''
	for attempt in 0 .. rpc_max_retries {
		if attempt > 0 {
			// Observed occasional transient failures against local dev
			// nodes (connection reset / empty response on a reused
			// keep-alive connection under rapid sequential requests) that
			// a plain retry always resolved in testing. A short,
			// exponentially-growing backoff avoids hammering a node that's
			// genuinely struggling, while staying invisible for the
			// common case of a single flaky request.
			time.sleep(rpc_retry_base_delay_ms * (1 << u32(attempt - 1)) * time.millisecond)
		}
		result := rpc_call_once(url, method, params) or {
			last_err = err.msg()
			continue
		}
		return result
	}
	return error('${last_err} (after ${rpc_max_retries} attempts)')
}

fn rpc_call_once(url string, method string, params string) !json2.Any {
	body := '{"jsonrpc":"2.0","id":1,"method":"${method}","params":${params}}'
	resp := http.post_json(url, body) or { return error('RPC transport error: ${err}') }
	if resp.status_code != 200 {
		return error('RPC HTTP ${resp.status_code}: ${resp.body}')
	}
	parsed := json2.decode[json2.Any](resp.body, json2.DecoderOptions{}) or {
		return error('RPC response not valid JSON: ${err}')
	}
	m := parsed.as_map()
	if 'error' in m {
		em := (m['error'] or { json2.Any(map[string]json2.Any{}) }).as_map()
		msg := if 'message' in em {
			(em['message'] or { json2.Any('') }).str()
		} else {
			'unknown RPC error'
		}
		return error('RPC error calling ${method}: ${msg}')
	}
	if 'result' !in m {
		return error('RPC response for ${method} missing "result" field')
	}
	return m['result'] or { json2.Any('') }
}

// eth_call executes a read-only contract call and returns the raw hex return data.
pub fn eth_call(url string, to string, data_hex string) !string {
	params := '[{"to":"${to}","data":"${data_hex}"},"latest"]'
	result := rpc_call(url, 'eth_call', params)!
	return result.str()
}

pub fn eth_estimate_gas(url string, from string, to string, data_hex string) !string {
	params := '[{"from":"${from}","to":"${to}","data":"${data_hex}"}]'
	result := rpc_call(url, 'eth_estimateGas', params)!
	return result.str()
}

// eth_send_transaction submits a state-changing transaction from an
// unlocked account and returns the transaction hash. If `gas_hex` is empty,
// gas is estimated first and a 25% buffer is added -- mirroring what a
// real wallet does, since many nodes (this CLI's target dev chains
// included) fall back to a low default gas limit rather than estimating
// automatically for `eth_sendTransaction`.
pub fn eth_send_transaction(url string, from string, to string, data_hex string, gas_hex string) !string {
	mut gas := gas_hex
	if gas.len == 0 {
		estimated := eth_estimate_gas(url, from, to, data_hex) or {
			return error('gas estimation failed (the transaction would likely revert): ${err}')
		}
		gas_val := hex_to_u64(estimated)
		buffered := gas_val + gas_val / 4 // +25% safety margin
		gas = '0x' + buffered.hex()
	}
	params := '[{"from":"${from}","to":"${to}","data":"${data_hex}","gas":"${gas}"}]'
	result := rpc_call(url, 'eth_sendTransaction', params)!
	return result.str()
}

fn hex_to_u64(s string) u64 {
	mut str := s
	if str.starts_with('0x') || str.starts_with('0X') {
		str = str[2..]
	}
	mut v := u64(0)
	for c in str.bytes() {
		mut digit := u64(0)
		if c >= `0` && c <= `9` {
			digit = u64(c - `0`)
		} else if c >= `a` && c <= `f` {
			digit = u64(c - `a`) + 10
		} else if c >= `A` && c <= `F` {
			digit = u64(c - `A`) + 10
		}
		v = (v << u32(4)) | digit
	}
	return v
}

pub fn eth_block_number(url string) !string {
	result := rpc_call(url, 'eth_blockNumber', '[]')!
	return result.str()
}

pub fn eth_chain_id(url string) !string {
	result := rpc_call(url, 'eth_chainId', '[]')!
	return result.str()
}

pub fn eth_accounts(url string) ![]string {
	result := rpc_call(url, 'eth_accounts', '[]')!
	mut out := []string{}
	for a in result.as_array() {
		out << a.str()
	}
	return out
}

pub struct LogEntry {
pub:
	topics []string
	data   string
}

// eth_get_logs fetches event logs matching the given contract address and
// topic filter (each entry either an exact 32-byte-hex topic, or '' to mean
// "any value" at that position). This is how the CLI reconstructs blob
// content that was pushed via BlobChunk events, without needing IPFS or
// any other off-chain service -- the chain's own log index *is* the
// storage/retrieval layer.
pub fn eth_get_logs(url string, address string, topics []string) ![]LogEntry {
	mut topics_json := []string{}
	for t in topics {
		if t.len == 0 {
			topics_json << 'null'
		} else {
			topics_json << '"${t}"'
		}
	}
	// Trim trailing "any" entries -- eth_getLogs topic arrays only need to
	// specify positions up to the last one actually constrained.
	mut trimmed := topics_json.clone()
	for trimmed.len > 0 && trimmed[trimmed.len - 1] == 'null' {
		trimmed = trimmed[..trimmed.len - 1].clone()
	}
	params := '[{"address":"${address}","topics":[${trimmed.join(',')}],"fromBlock":"0x0","toBlock":"latest"}]'
	result := rpc_call(url, 'eth_getLogs', params)!
	mut out := []LogEntry{}
	for entry in result.as_array() {
		m := entry.as_map()
		mut topic_strs := []string{}
		if 'topics' in m {
			for t in (m['topics'] or { json2.Any([]json2.Any{}) }).as_array() {
				topic_strs << t.str()
			}
		}
		data_str := if 'data' in m { (m['data'] or { json2.Any('') }).str() } else { '' }
		out << LogEntry{
			topics: topic_strs
			data: data_str
		}
	}
	return out
}

struct TxReceipt {
pub:
	status           string
	contract_address string
	block_number     string
	found            bool
}

pub fn eth_get_transaction_receipt(url string, tx_hash string) !TxReceipt {
	params := '["${tx_hash}"]'
	result := rpc_call(url, 'eth_getTransactionReceipt', params)!
	m := result.as_map()
	if m.len == 0 {
		return TxReceipt{
			found: false
		}
	}
	status := if 'status' in m { (m['status'] or { json2.Any('') }).str() } else { '' }
	contract_addr := if 'contractAddress' in m {
		(m['contractAddress'] or { json2.Any('') }).str()
	} else {
		''
	}
	block_num := if 'blockNumber' in m {
		(m['blockNumber'] or { json2.Any('') }).str()
	} else {
		''
	}
	return TxReceipt{
		status: status
		contract_address: contract_addr
		block_number: block_num
		found: true
	}
}

// wait_for_receipt polls until the transaction is mined (or times out),
// mirroring what a real wallet/CLI would do after broadcasting a tx.
pub fn wait_for_receipt(url string, tx_hash string, timeout_secs int) !TxReceipt {
	mut waited := 0
	for waited < timeout_secs {
		receipt := eth_get_transaction_receipt(url, tx_hash) or { TxReceipt{ found: false } }
		if receipt.found {
			return receipt
		}
		time.sleep(1 * time.second)
		waited += 1
	}
	return error('timed out waiting for transaction ${tx_hash} to be mined')
}
