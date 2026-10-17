module main

import os
import time

// contract_signatures and command_help are built by functions rather than
// `const` map literals: V's codegen for large string-heavy const map
// literals can blow up compiler memory disproportionately (discovered the
// hard way -- this exact change was what fixed an out-of-memory compiler
// crash during development). Runtime cost of rebuilding these small maps
// on each lookup is negligible for a short-lived CLI process.
fn contract_signatures() map[string]string {
	return {
		'createRepository':     'createRepository(string,bool)'
		'pushCommit':           'pushCommit(bytes32,bytes32,bytes32,bytes32,string,uint64)'
		'setCommitCid':         'setCommitCid(bytes32,bytes32,string)'
		'updateBranch':         'updateBranch(bytes32,string,bytes32,bool)'
		'deleteBranch':         'deleteBranch(bytes32,string)'
		'branchHead':           'branchHead(bytes32,string)'
		'listBranches':         'listBranches(bytes32)'
		'getCommit':            'getCommit(bytes32,bytes32)'
		'getFirstParentChain':  'getFirstParentChain(bytes32,bytes32,uint256)'
		'commitExists':         'commitExists(bytes32,bytes32)'
		'repositoryInfo':       'repositoryInfo(bytes32)'
		'setCollaboratorRole':  'setCollaboratorRole(bytes32,address,uint8)'
		'roleOf':               'roleOf(bytes32,address)'
		'collaborators':        'collaborators(bytes32)'
		'createTag':            'createTag(bytes32,string,bytes32)'
		'pushBlobChunk':        'pushBlobChunk(bytes32,bytes32,uint32,uint32,bool,bytes)'
		'blobAnnounced':        'blobAnnounced(bytes32,bytes32)'
		'setVisibility':        'setVisibility(bytes32,bool)'
		'setMinApprovals':      'setMinApprovals(bytes32,uint8)'
		'openPullRequest':      'openPullRequest(bytes32,string,string,string,string)'
		'approvePullRequest':   'approvePullRequest(bytes32,uint256)'
		'mergePullRequest':     'mergePullRequest(bytes32,uint256)'
		'closePullRequest':     'closePullRequest(bytes32,uint256)'
		'getPullRequest':       'getPullRequest(bytes32,uint256)'
		'pullRequestCount':     'pullRequestCount(bytes32)'
		'registerHandle':       'registerHandle(string)'
		'releaseHandle':        'releaseHandle()'
		'resolveHandle':        'resolveHandle(string)'
		'addressHandle':        'addressHandle(address)'
	}
}

const role_names = ['none', 'reader', 'contributor', 'maintainer']
const pr_status_names = ['open', 'merged', 'closed']

const blob_chunk_event_signature = 'BlobChunk(bytes32,bytes32,uint32,uint32,bool,bytes)'
const default_chunk_size = 20_000 // bytes of (possibly encrypted) payload per pushBlobChunk tx -- stays under the contract's MAX_CHUNK_BYTES (24576)

struct CommandHelp {
	usage   string
	summary string
	detail  string
}

fn command_help_table() map[string]CommandHelp {
	return {
	'init':          CommandHelp{'dvcs init', 'Create a new local repository in the current directory.', 'Creates .dvcs/ with an empty object store, refs, and config. Run this once per project, from the directory you want to track.'}
	'remote':        CommandHelp{'dvcs remote <rpc-url> <contract-address> <account-address>', 'Configure which chain, contract, and signing account to use.', "The account must be unlocked on the target node (e.g. a local Anvil/Hardhat/Ganache dev account) -- this CLI signs via eth_sendTransaction, not a locally-held private key. See README 'Signing model'."}
	'repo-create':   CommandHelp{'dvcs repo-create <name> [--private]', 'Register a brand-new repository on-chain, owned by your configured account.', "Computes the repo's on-chain id from (your address, name) and saves it locally. --private marks the repo private AND requires `crypto-init` before any content push -- see `dvcs set-private`. On-chain metadata (commit messages, branch names, etc.) is always public regardless; only file content pushed after crypto-init is actually hidden from a block explorer."}
	'set-private':   CommandHelp{'dvcs set-private <true|false>', 'Mark a repository private or public on-chain.', "Private means: this CLI refuses to push file content unless encryption is enabled (crypto-init). It does NOT hide commit metadata (messages, authors, branch names, tree roots) from a block explorer -- only encrypted file content is actually unreadable to an outsider. Requires repo ownership."}
	'repo-connect':  CommandHelp{'dvcs repo-connect <owner-address> <name>', "Attach this local repo to someone else's existing on-chain repository.", "This is the 'clone' path for anyone who isn't the repo owner: it computes the same deterministic repo id and verifies the repo actually exists on-chain, but sends no transaction. You'll still need a role granted by the owner (via `dvcs member-add`) before you can push."}
	'crypto-init':   CommandHelp{'dvcs crypto-init <passphrase>', 'Turn on AES-256-GCM encryption for file content pushed from now on.', "On-chain data is public no matter what role-based access control says, so this is how you keep pushed file content actually private. The passphrase itself is never stored or sent anywhere -- share it with collaborators out of band. Every push/pull after this needs --passphrase or DVCS_PASSPHRASE. Required before pushing to a repo marked private."}
	'member-add':    CommandHelp{'dvcs member-add <address-or-handle> <role>', 'Grant (or change) a collaborator role: none, reader, contributor, or maintainer.', "Accepts a raw 0x address, or a handle registered via `dvcs identity-register` (resolved on-chain first). Contributor can push commits/content and create branches/tags. Maintainer can additionally force-push, delete branches, manage other collaborators, and approve pull requests. Requires Maintainer role or higher (or ownership) to call."}
	'member-list':   CommandHelp{'dvcs member-list', 'List every address with an explicit role on this repository, plus the owner.', 'Shows each registered handle alongside its address where one exists.'}
	'identity-register': CommandHelp{'dvcs identity-register <handle>', 'Claim a human-readable handle (e.g. an email-shaped string) for your configured account.', "This is a transaction FROM your account, so the binding is cryptographically signed by your own key -- nobody else can claim a handle 'as' your address. It does NOT verify you own that email inbox (no pure smart contract can check that) -- it's a self-claimed nickname, same trust level as a commit's author field. One handle per address; registering a new one releases your old one."}
	'identity-release':  CommandHelp{'dvcs identity-release', 'Release your currently registered handle, if any.', ''}
	'identity-resolve':  CommandHelp{'dvcs identity-resolve <handle>', 'Look up which address currently holds a handle.', ''}
	'whoami':        CommandHelp{'dvcs whoami', 'Show your configured account and its registered handle, if any.', ''}
	'add':           CommandHelp{'dvcs add <path> [<path>...]', 'Stage one or more files or directories.', 'Directories are added recursively. Anything matched by .dvcsignore (if present) is skipped, same idea as .gitignore: exact paths, "dir/" prefixes, and "*" wildcards are supported.'}
	'status':        CommandHelp{'dvcs status', 'Show the current branch, its head commit, and any staged files.', ''}
	'commit':        CommandHelp{'dvcs commit -m "<message>"', 'Record a local commit from the currently staged files.', "Each commit tracks the FULL file tree (unchanged files carry forward from the parent commit automatically), not just a diff -- so `checkout`/`pull` always have a complete snapshot to work with. Nothing is pushed on-chain yet; run `push` for that."}
	'log':           CommandHelp{'dvcs log [branch]', "Show a branch's commit history from the local cache.", 'Defaults to the current branch. Walks parent1 links only (first-parent), so merge history off the mainline is not shown.'}
	'branch':        CommandHelp{'dvcs branch [name] | dvcs branch -d <name>', 'List local branches, create a new one at HEAD, or delete one locally.', "`-d` only removes the local ref; it never touches chain state. To remove a branch on-chain, use `dvcs delete-branch` (needs Maintainer role or higher there)."}
	'checkout':      CommandHelp{'dvcs checkout <branch>', "Switch the current branch and restore that branch's files into the working directory.", 'Overwrites any local files tracked by that commit. Content not present in your local object store shows up as "missing" -- run `pull` first to fetch it from chain.'}
	'ls':            CommandHelp{'dvcs ls [branch-or-commit]', 'List every file tracked at a given commit (defaults to current branch HEAD).', 'Like `git ls-tree --name-only`. Reads only the local commit cache -- run `pull` first if the ref is not yet cached.'}
	'show':          CommandHelp{'dvcs show <branch-or-commit>', "Show a commit's full metadata and file list.", 'Like `git show --stat`: author, date, parent(s), tree root, message, and every tracked file.'}
	'diff':          CommandHelp{'dvcs diff <branch-or-commit-1> <branch-or-commit-2>', 'Show which files were added, removed, or modified between two commits.', "Compares file paths and blob hashes only (not line-by-line content diffs). Use `dvcs cat <ref> <path>` on each side to inspect actual content."}
	'cat':           CommandHelp{'dvcs cat <branch-or-commit> <path>', "Print a tracked file's content at a given commit, without checking it out.", 'Like `git show <commit>:<path>`. Requires the blob content to already be in your local object store (run `pull` first if needed).'}
	'rollback':      CommandHelp{'dvcs rollback <commit-hash-or-prefix> [--hard]', "Move the current branch's LOCAL pointer back to an earlier commit.", "Purely local, like `git reset` -- chain state is untouched. Without --hard, only the branch ref moves; with --hard, working-tree files are restored to match too (note: files added after the rollback target are NOT deleted, unlike real `git reset --hard`). Since this moves the branch backwards, a subsequent `push` needs --force."}
	'rebase':        CommandHelp{'dvcs rebase <onto-branch> [--ours | --theirs]', 'Replay commits unique to the current branch on top of another branch, locally.', "Purely local, like `git rebase`. Detects real conflicts (a path changed differently on both branches since they diverged) via a 3-way merge and, by default, stops at the first one and reports it rather than guessing. Pass --ours to keep your current branch's version of every conflicting path, or --theirs to take the other branch's version -- unlike git's own rebase, these mean exactly what they sound like (\"ours\" = my branch), not git's flipped convention. Since replaying changes commit hashes, a subsequent `push` needs --force."}
	'push':          CommandHelp{'dvcs push [branch] [--force] [--passphrase <p>]', "Push local-only commits and their file content on-chain, then update the branch pointer.", 'Each commit and each blob chunk is its own separately-confirmed transaction, so an interrupted push loses nothing already confirmed -- re-run `push` and it skips anything the contract already has (see `dvcs changelog`). --force is required after a rollback or any other history rewrite. If the repo has encryption enabled, pass --passphrase or set DVCS_PASSPHRASE.'}
	'pull':          CommandHelp{'dvcs pull [branch] [--passphrase <p>]', 'Sync commit metadata and file content for a branch from chain into the local cache.', "Fetches any commits not already cached locally, reconstructs each one's files from BlobChunk events (decrypting if needed), and updates the local branch ref. Run `checkout` afterwards to write the files into your working directory."}
	'delete-branch': CommandHelp{'dvcs delete-branch <name>', 'Delete a branch on-chain.', 'Requires the Maintainer role or higher (or repo ownership) on-chain -- this is enforced by the contract, not just the CLI.'}
	'pr-open':       CommandHelp{'dvcs pr-open <source-branch> <target-branch> "<title>" ["<description>"]', 'Open a pull request proposing to merge one branch into another.', 'Requires Contributor role or higher. Both branches must already exist on-chain. The PR always merges whatever the source branch currently points to at merge time, not a frozen snapshot -- push more commits to the source branch and the open PR reflects them.'}
	'pr-approve':    CommandHelp{'dvcs pr-approve <pr-id>', 'Approve an open pull request.', "Requires Maintainer role or higher (or ownership) -- genuine review authority, not just push access. You cannot approve your own PR. A repo's required approval count defaults to 1; change it with `dvcs pr-min-approvals`."}
	'pr-merge':      CommandHelp{'dvcs pr-merge <pr-id>', 'Merge a pull request once it has enough approvals.', "Fails with NotEnoughApprovals if it doesn't have enough yet, or NotFastForward if the target branch has moved in a way that makes this not a fast-forward merge (same protection as a normal `push`)."}
	'pr-close':      CommandHelp{'dvcs pr-close <pr-id>', 'Close a pull request without merging it.', 'The PR author, or anyone with Maintainer role or higher, may do this.'}
	'pr-list':       CommandHelp{'dvcs pr-list', 'List every pull request on this repository with its status.', ''}
	'pr-show':       CommandHelp{'dvcs pr-show <pr-id>', 'Show full detail for one pull request.', ''}
	'pr-min-approvals': CommandHelp{'dvcs pr-min-approvals <n>', 'Set how many approvals a pull request needs before it can be merged.', 'Requires Maintainer role or higher. Defaults to 1 if never set.'}
	'changelog':     CommandHelp{'dvcs changelog', 'Show every on-chain action this CLI has taken from this directory, in order.', "A local, append-only audit trail: action, details, and transaction hash for every confirmed transaction. Useful after an interrupted push to see exactly what landed on-chain before re-running `push`."}
	'remote-info':   CommandHelp{'dvcs remote-info', 'Show the configured RPC URL, contract address, account, and repo id.', ''}
	'accounts':      CommandHelp{'dvcs accounts', 'List accounts the configured RPC node exposes (via eth_accounts).', 'Useful for finding which addresses are unlocked and usable with `dvcs remote`.'}
	}
}

fn usage() {
	println('dvcs - a blockchain-backed decentralized version control system\n')
	println('USAGE:')
	println('  dvcs <command> [args]')
	println('  dvcs help [command]        show this list, or detailed help for one command\n')
	println('COMMANDS:')
	mut names := command_help_table().keys()
	for name in names {
		h := command_help_table()[name] or { CommandHelp{} }
		println('  ${name:-15} ${h.summary}')
	}
	println('\nRun `dvcs help <command>` for details on any command above.')
}

fn command_usage(cmd string) {
	h := command_help_table()[cmd] or {
		fail('unknown command "${cmd}" -- run `dvcs help` to see all commands')
		return
	}
	println(h.usage)
	println('')
	println(h.summary)
	if h.detail.len > 0 {
		println('')
		println(h.detail)
	}
}

fn fail(msg string) {
	eprintln('error: ${msg}')
	exit(1)
}

fn main() {
	args := os.args[1..]
	if args.len == 0 {
		usage()
		return
	}
	cmd := args[0]
	rest := args[1..]

	if cmd == '-h' || cmd == '--help' || cmd == 'help' {
		if rest.len > 0 {
			command_usage(rest[0])
		} else {
			usage()
		}
		return
	}
	if rest.contains('-h') || rest.contains('--help') {
		command_usage(cmd)
		return
	}

	match cmd {
		'init' { cmd_init() }
		'remote' { cmd_remote(rest) }
		'remote-info' { cmd_remote_info() }
		'repo-create' { cmd_repo_create(rest) }
		'repo-connect' { cmd_repo_connect(rest) }
		'set-private' { cmd_set_private(rest) }
		'crypto-init' { cmd_crypto_init(rest) }
		'member-add' { cmd_member_add(rest) }
		'member-list' { cmd_member_list() }
		'identity-register' { cmd_identity_register(rest) }
		'identity-release' { cmd_identity_release() }
		'identity-resolve' { cmd_identity_resolve(rest) }
		'whoami' { cmd_whoami() }
		'add' { cmd_add(rest) }
		'status' { cmd_status() }
		'commit' { cmd_commit(rest) }
		'log' { cmd_log(rest) }
		'branch' { cmd_branch(rest) }
		'checkout' { cmd_checkout(rest) }
		'ls' { cmd_ls(rest) }
		'show' { cmd_show(rest) }
		'diff' { cmd_diff(rest) }
		'cat' { cmd_cat(rest) }
		'rollback' { cmd_rollback(rest) }
		'rebase' { cmd_rebase(rest) }
		'push' { cmd_push(rest) }
		'pull' { cmd_pull(rest) }
		'delete-branch' { cmd_delete_branch(rest) }
		'pr-open' { cmd_pr_open(rest) }
		'pr-approve' { cmd_pr_approve(rest) }
		'pr-merge' { cmd_pr_merge(rest) }
		'pr-close' { cmd_pr_close(rest) }
		'pr-list' { cmd_pr_list() }
		'pr-show' { cmd_pr_show(rest) }
		'pr-min-approvals' { cmd_pr_min_approvals(rest) }
		'changelog' { cmd_changelog() }
		'accounts' { cmd_accounts() }
		else {
			usage()
			fail('unknown command "${cmd}"')
		}
	}
}

// --- init ---

fn cmd_init() {
	root := os.getwd()
	dvcs_path := os.join_path(root, dvcs_dir_name)
	if os.is_dir(dvcs_path) {
		fail('.dvcs already exists in ${root}')
	}
	os.mkdir_all(os.join_path(dvcs_path, 'objects')) or { fail('${err}') }
	os.mkdir_all(os.join_path(dvcs_path, 'refs', 'heads')) or { fail('${err}') }
	os.mkdir_all(os.join_path(dvcs_path, 'commit-meta')) or { fail('${err}') }
	write_config(root, RepoConfig{}) or { fail('${err}') }
	set_current_branch(root, 'main')
	os.write_file(os.join_path(dvcs_path, 'index'), '') or { fail('${err}') }
	println('Initialized empty dvcs repository in ${dvcs_path}')
}

// --- remote configuration ---

fn cmd_remote(rest []string) {
	root := dvcs_root() or { fail('${err}') return }
	if rest.len != 3 {
		fail('usage: dvcs remote <rpc-url> <contract-address> <account-address>')
	}
	mut cfg := read_config(root) or { RepoConfig{} }
	cfg.rpc_url = rest[0]
	cfg.contract = rest[1]
	cfg.account = rest[2]
	write_config(root, cfg) or { fail('${err}') }
	println('Configured remote:')
	println('  rpc_url  = ${cfg.rpc_url}')
	println('  contract = ${cfg.contract}')
	println('  account  = ${cfg.account}')
}

fn cmd_remote_info() {
	root := dvcs_root() or { fail('${err}') return }
	cfg := read_config(root) or { fail('${err}') return }
	println('rpc_url  = ${cfg.rpc_url}')
	println('contract = ${cfg.contract}')
	println('account  = ${cfg.account}')
	println('owner    = ${cfg.owner}')
	println('name     = ${cfg.name}')
	println('repo_id  = ${cfg.repo_id}')
}

// --- changelog ---

fn cmd_changelog() {
	root := dvcs_root() or { fail('${err}') return }
	entries := read_changelog(root)
	if entries.len == 0 {
		println('No on-chain actions recorded yet from this directory.')
		return
	}
	for e in entries {
		println('${e.timestamp}  ${e.action:-16} ${e.details}')
		if e.tx_hash != '-' {
			println('${' '.repeat(21)}tx: ${e.tx_hash}')
		}
	}
}

// --- crypto-init ---

// cmd_crypto_init turns on client-side encryption for future pushes. The
// passphrase itself is never written to disk or to chain -- only a random
// salt (public on-chain, once a repo is registered -- see
// repo_salt_identifier) and a local-only verification tag (sha256 of the
// derived key, kept off-chain) go anywhere. Every collaborator who needs to
// read file content must still be given the passphrase itself out of band
// (there's no per-user key management here -- see README "Known
// limitations"); the salt travels with the repo so they don't also need to
// separately learn that.
fn cmd_crypto_init(rest []string) {
	root := dvcs_root() or { fail('${err}') return }
	mut cfg := read_config(root) or { fail('${err}') return }
	if rest.len == 0 {
		fail('usage: dvcs crypto-init <passphrase>')
	}
	passphrase := rest[0]
	salt := random_salt()
	key := derive_key(passphrase, salt)
	tag := verification_tag(key)

	cfg.encrypt = true
	cfg.salt = bytes_to_hex(salt)
	cfg.verify_tag = tag
	write_config(root, cfg) or { fail('${err}') }
	append_changelog(root, 'crypto-init', 'encryption enabled (local only, no tx)', '')

	println('Encryption enabled for this repository.')
	println('File content pushed from now on will be AES-256-GCM encrypted before it')
	println('leaves this machine. Share the passphrase with collaborators out of band --')
	println('it is never stored in .dvcs/config or sent on-chain.')
	println('Every `push` and `pull` from now on needs --passphrase <p> or DVCS_PASSPHRASE.')

	if cfg.repo_id.len == 0 || cfg.rpc_url.len == 0 || cfg.contract.len == 0 {
		println('')
		println('Note: remote/repo not fully configured yet, so the (non-secret) salt was')
		println('NOT published on-chain. Collaborators using `repo-connect` will not auto-')
		println('discover it -- re-run `crypto-init` after `remote`/`repo-create`, or share')
		println('this salt with them directly: ${cfg.salt}')
		return
	}

	repo_id_bytes := hex_to_bytes(cfg.repo_id)
	salt_id := repo_salt_identifier(repo_id_bytes)
	push_blob_if_needed(root, cfg, repo_id_bytes, salt_id, salt, []u8{}) or {
		println('')
		println('warning: could not publish the salt on-chain (${err}); collaborators will')
		println('need it shared directly: ${cfg.salt}')
		return
	}
	println('Salt published on-chain (not secret) so `repo-connect` auto-discovers it.')
}

fn cmd_accounts() {
	root := dvcs_root() or { fail('${err}') return }
	cfg := read_config(root) or { fail('${err}') return }
	require_remote(cfg)
	accs := eth_accounts(cfg.rpc_url) or { fail('${err}') return }
	for a in accs {
		println(a)
	}
}

fn require_remote(cfg RepoConfig) {
	if cfg.rpc_url.len == 0 || cfg.contract.len == 0 || cfg.account.len == 0 {
		fail('remote not configured; run `dvcs remote <rpc-url> <contract-address> <account-address>` first')
	}
}

// --- repo-create: register this repo on-chain ---

fn cmd_repo_create(rest []string) {
	root := dvcs_root() or { fail('${err}') return }
	mut cfg := read_config(root) or { fail('${err}') return }
	require_remote(cfg)
	if rest.len == 0 {
		fail('usage: dvcs repo-create <name> [--private]')
	}
	name := rest[0]
	is_private := rest.len > 1 && rest[1] == '--private'

	calldata := encode_call(contract_signatures()['createRepository'], [av_string(name), av_bool(is_private)])
	data_hex := '0x' + bytes_to_hex(calldata)

	println('Submitting createRepository("${name}", ${is_private}) ...')
	tx_hash := eth_send_transaction(cfg.rpc_url, cfg.account, cfg.contract, data_hex, '') or {
		fail('${err}')
		return
	}
	println('  tx: ${tx_hash}')
	receipt := wait_for_receipt(cfg.rpc_url, tx_hash, 60) or { fail('${err}') return }
	if receipt.status != '0x1' {
		fail('transaction reverted (status=${receipt.status}); repository may already exist')
	}
	append_changelog(root, 'repo-create', 'name="${name}" private=${is_private}', tx_hash)

	owner_bytes := hex_to_bytes(cfg.account)
	repo_id := compute_repo_id_local(owner_bytes, name)
	repo_id_hex := hash32_to_hex(repo_id)

	cfg.owner = cfg.account
	cfg.name = name
	cfg.repo_id = repo_id_hex
	write_config(root, cfg) or { fail('${err}') }

	println('Repository created.')
	println('  repo_id = ${repo_id_hex}')
}

// compute_repo_id_local mirrors DVCS.sol's computeRepoId(address,string),
// i.e. keccak256(abi.encodePacked(owner, name)) -- packed encoding, so the
// address contributes exactly 20 raw bytes and the string contributes its
// raw UTF-8 bytes with no length prefix or padding.
fn compute_repo_id_local(owner_20 []u8, name string) [32]u8 {
	mut buf := []u8{}
	buf << owner_20
	buf << name.bytes()
	return keccak256(buf)
}

// cmd_repo_connect attaches this local repo to an existing on-chain
// repository owned by someone else (the realistic "clone" path): it
// computes the repo id locally from (owner, name) -- exactly like
// DVCS.sol's computeRepoId -- and verifies the repo actually exists
// on-chain before saving it, but does not submit any transaction.
fn cmd_repo_connect(rest []string) {
	root := dvcs_root() or { fail('${err}') return }
	mut cfg := read_config(root) or { fail('${err}') return }
	require_remote(cfg)
	if rest.len != 2 {
		fail('usage: dvcs repo-connect <owner-address> <name>')
	}
	owner := rest[0]
	name := rest[1]

	owner_bytes := hex_to_bytes(owner)
	repo_id := compute_repo_id_local(owner_bytes, name)
	repo_id_hex := hash32_to_hex(repo_id)

	calldata := encode_call(contract_signatures()['repositoryInfo'], [av_bytes32(hash32_to_bytes(repo_id))])
	data_hex := '0x' + bytes_to_hex(calldata)
	result_hex := eth_call(cfg.rpc_url, cfg.contract, data_hex) or {
		fail('repository not found on-chain for owner=${owner} name="${name}": ${err}')
		return
	}
	data := hex_to_bytes(result_hex)
	if data.len < 32 {
		fail('repository not found on-chain for owner=${owner} name="${name}"')
	}
	onchain_owner := decode_address(data, 0)
	commit_count := decode_uint(data, 3)

	cfg.owner = owner
	cfg.name = name
	cfg.repo_id = repo_id_hex
	write_config(root, cfg) or { fail('${err}') }

	println('Connected to on-chain repository.')
	println('  repo_id       = ${repo_id_hex}')
	println('  owner         = 0x${bytes_to_hex(onchain_owner)}')
	println('  commit_count  = ${commit_count}')
}

// compute_commit_hash_local mirrors computeCommitHash(...) in DVCS.sol.
fn compute_commit_hash_local(repo_id [32]u8, parent1 [32]u8, parent2 [32]u8, tree_root [32]u8, message string, author_20 []u8, timestamp u64) [32]u8 {
	mut buf := []u8{}
	buf << hash32_to_bytes(repo_id)
	buf << hash32_to_bytes(parent1)
	buf << hash32_to_bytes(parent2)
	buf << hash32_to_bytes(tree_root)
	buf << message.bytes()
	buf << author_20
	buf << u64_to_be_bytes(timestamp)
	return keccak256(buf)
}

// --- add / status ---

fn cmd_add(rest []string) {
	root := dvcs_root() or { fail('${err}') return }
	if rest.len == 0 {
		fail('usage: dvcs add <path> [<path>...]')
	}
	patterns := load_ignore_patterns(root)
	mut idx := read_index(root)
	mut count := 0
	for p in rest {
		count += add_path(root, p, patterns, mut idx)
	}
	write_index(root, idx)
	println('Staged ${count} file(s).')
}

fn add_path(root string, p string, patterns []string, mut idx map[string]string) int {
	abs_target := if os.is_abs_path(p) { p } else { os.join_path(root, p) }
	if !os.exists(abs_target) {
		fail('no such file or directory: ${p}')
	}
	mut count := 0
	if os.is_dir(abs_target) {
		entries := os.walk_ext(abs_target, '')
		for e in entries {
			if e.contains('/${dvcs_dir_name}/') || e.ends_with('/${dvcs_dir_name}') {
				continue
			}
			if os.is_dir(e) {
				continue
			}
			count += stage_file(root, e, patterns, mut idx)
		}
	} else {
		count += stage_file(root, abs_target, patterns, mut idx)
	}
	return count
}

fn stage_file(root string, abs_path string, patterns []string, mut idx map[string]string) int {
	rel := abs_path.replace(root + '/', '')
	if rel.starts_with(dvcs_dir_name) {
		return 0
	}
	if is_ignored(rel, patterns) {
		return 0
	}
	content := os.read_bytes(abs_path) or { fail('cannot read ${rel}: ${err}') return 0 }
	h := store_blob(root, content)
	idx[rel] = bytes_to_hex(hash32_to_bytes(h))
	return 1
}

fn cmd_status() {
	root := dvcs_root() or { fail('${err}') return }
	branch := current_branch(root)
	idx := read_index(root)
	println('On branch ${branch}')
	head := local_branch_head(root, branch) or { '' }
	if head == '' {
		println('No commits yet on this branch.')
	} else {
		println('HEAD: ${head}')
	}
	if idx.len == 0 {
		println('Nothing staged.')
		return
	}
	println('Staged files:')
	mut paths := idx.keys()
	paths.sort()
	for p in paths {
		println('  ${p}  (${idx[p]})')
	}
}

// --- commit ---

fn cmd_commit(rest []string) {
	root := dvcs_root() or { fail('${err}') return }
	cfg := read_config(root) or { fail('${err}') return }
	if cfg.repo_id.len == 0 {
		fail('repository not registered on-chain yet; run `dvcs repo-create <name>` first')
	}
	mut message := ''
	for i, a in rest {
		if a == '-m' && i + 1 < rest.len {
			message = rest[i + 1]
		}
	}
	if message.len == 0 {
		fail('usage: dvcs commit -m "<message>"')
	}

	idx := read_index(root)
	if idx.len == 0 {
		fail('nothing staged; use `dvcs add <path>` first')
	}

	branch := current_branch(root)
	parent1_hex := local_branch_head(root, branch) or { '0x' + '00'.repeat(32) }
	parent1 := bytes_to_hash32(hex_to_bytes(parent1_hex))
	parent2 := [32]u8{}

	// Each commit tracks the FULL file tree, not just what changed --
	// mirroring git's actual commit/tree model rather than a diff. Newly
	// staged paths override the parent's; anything else the parent tracked
	// carries forward unchanged.
	mut merged := map[string]string{}
	zero_hex := '0x' + '00'.repeat(32)
	if parent1_hex != zero_hex {
		parent_commit := load_local_commit(root, parent1_hex) or {
			fail('parent commit ${parent1_hex} not found locally; run `dvcs pull` first')
			return
		}
		for p, h in parent_commit.files {
			merged[p] = h
		}
	}
	for p, h in idx {
		merged[p] = h
	}

	mut files := []TrackedFile{}
	for path, hash_hex in merged {
		files << TrackedFile{
			path: path
			hash: bytes_to_hash32(hex_to_bytes(hash_hex))
		}
	}
	tree_root := merkle_root(files)

	timestamp := now_unix()
	repo_id := bytes_to_hash32(hex_to_bytes(cfg.repo_id))
	author := hex_to_bytes(cfg.account)

	commit_hash := compute_commit_hash_local(repo_id, parent1, parent2, tree_root, message,
		author, timestamp)
	commit_hash_hex := hash32_to_hex(commit_hash)

	save_local_commit(root, commit_hash_hex, LocalCommit{
		parent1: parent1_hex
		parent2: '0x' + '00'.repeat(32)
		tree_root: hash32_to_hex(tree_root)
		message: message
		author: cfg.account
		timestamp: timestamp
		cid: ''
		files: merged
	})
	set_local_branch_head(root, branch, commit_hash_hex)
	write_index(root, map[string]string{})

	println('[${branch} ${commit_hash_hex[2..10]}] ${message}')
	println('  ${idx.len} file(s) changed, ${files.len} tracked total, tree root ${hash32_to_hex(tree_root)}')
}

// --- log ---

fn cmd_log(rest []string) {
	root := dvcs_root() or { fail('${err}') return }
	branch := if rest.len > 0 { rest[0] } else { current_branch(root) }
	mut cur := local_branch_head(root, branch) or {
		println('No commits on branch "${branch}".')
		return
	}
	zero := '0x' + '00'.repeat(32)
	for cur != '' && cur != zero {
		c := load_local_commit(root, cur) or { break }
		println('commit ${cur}')
		println('Author: ${c.author}')
		println('Date:   ${time.unix(i64(c.timestamp))}')
		println('')
		for line in c.message.split_into_lines() {
			println('    ${line}')
		}
		println('')
		cur = c.parent1
	}
}

// --- branch / checkout ---

fn cmd_branch(rest []string) {
	root := dvcs_root() or { fail('${err}') return }
	if rest.len == 0 {
		branches := list_local_branches(root)
		current := current_branch(root)
		for b in branches {
			marker := if b == current { '* ' } else { '  ' }
			println('${marker}${b}')
		}
		return
	}
	if rest[0] == '-d' || rest[0] == '--delete' {
		if rest.len < 2 {
			fail('usage: dvcs branch -d <name>')
		}
		target := rest[1]
		current := current_branch(root)
		if target == current {
			fail('cannot delete the currently checked-out branch "${target}"; checkout another branch first')
		}
		delete_local_branch(root, target) or { fail('${err}') return }
		println('Deleted local branch "${target}" (this does not affect the on-chain branch -- see `dvcs delete-branch`).')
		return
	}
	new_branch := rest[0]
	current := current_branch(root)
	head := local_branch_head(root, current) or {
		fail('cannot branch: no commits yet on "${current}"')
		return
	}
	set_local_branch_head(root, new_branch, head)
	println('Created branch "${new_branch}" at ${head}')
}

// restore_working_tree writes out every file tracked by commit `head` from
// the local object store, overwriting whatever's on disk. Shared by
// checkout and rollback --hard.
fn restore_working_tree(root string, head string) (int, int) {
	c := load_local_commit(root, head) or { return 0, 0 }
	mut restored := 0
	mut missing := 0
	for path, hash_hex in c.files {
		blob := load_blob(root, bytes_to_hash32(hex_to_bytes(hash_hex))) or {
			missing += 1
			continue
		}
		full := os.join_path(root, path)
		dir := os.dir(full)
		if !os.exists(dir) {
			os.mkdir_all(dir) or {}
		}
		os.write_file(full, blob.bytestr()) or {}
		restored += 1
	}
	return restored, missing
}

fn cmd_checkout(rest []string) {
	root := dvcs_root() or { fail('${err}') return }
	if rest.len == 0 {
		fail('usage: dvcs checkout <branch>')
	}
	branch := rest[0]
	head := local_branch_head(root, branch) or {
		fail('unknown branch "${branch}"')
		return
	}
	set_current_branch(root, branch)
	maybe_commit := load_local_commit(root, head)
	if maybe_commit == none {
		println('Switched to branch "${branch}" (no commits yet).')
		return
	}
	restored, missing := restore_working_tree(root, head)
	println('Switched to branch "${branch}" at ${head}')
	println('  restored ${restored} file(s)${if missing > 0 { ', ${missing} missing locally' } else { '' }}')
}

// --- rollback ---

// cmd_rollback moves the current branch's LOCAL pointer back to an earlier
// commit. It is purely local (like `git reset`): it does not touch chain
// state. Since branch fast-forward is enforced on-chain, pushing after a
// rollback requires `dvcs push --force` -- the same protection that stops
// anyone else from silently rewriting shared history also applies to you.
fn cmd_rollback(rest []string) {
	root := dvcs_root() or { fail('${err}') return }
	if rest.len == 0 {
		fail('usage: dvcs rollback <commit-hash-or-prefix> [--hard]')
	}
	hard := rest.contains('--hard')
	target_ref := rest[0]
	target := resolve_commit_ref(root, target_ref) or { fail('${err}') return }

	maybe_target_commit := load_local_commit(root, target)
	if maybe_target_commit == none {
		fail('commit ${target} not found locally')
	}

	branch := current_branch(root)
	set_local_branch_head(root, branch, target)

	if hard {
		restored, missing := restore_working_tree(root, target)
		println('Rolled back branch "${branch}" to ${target} and restored ${restored} file(s)${if missing > 0 {
			', ${missing} missing locally'
		} else {
			''
		}}.')
	} else {
		println('Rolled back branch "${branch}" to ${target} (working tree left untouched; use --hard to also restore files).')
	}
	println('Note: this only changed your local branch pointer. To make the on-chain')
	println('branch match, run `dvcs push --force` -- a plain `push` will be rejected')
	println('since this moves the branch backwards, not forwards.')
}

// resolve_commit_ref accepts a full "0x..." hash or an unambiguous prefix
// (with or without "0x"), similar to git's abbreviated commit hashes.
fn resolve_commit_ref(root string, ref string) !string {
	mut r := ref
	if !r.starts_with('0x') {
		r = '0x' + r
	}
	if r.len == 66 {
		return r
	}
	dir := os.join_path(root, dvcs_dir_name, 'commit-meta')
	entries := os.ls(dir) or { return error('no commits found locally') }
	prefix := r[2..].clone()
	mut matches := []string{}
	for e in entries {
		if !e.ends_with('.txt') {
			continue
		}
		hash_part := e[..e.len - 4]
		if hash_part.starts_with(prefix) {
			matches << '0x' + hash_part
		}
	}
	if matches.len == 0 {
		return error('no commit matches "${ref}"')
	}
	if matches.len > 1 {
		return error('"${ref}" is ambiguous, matches ${matches.len} commits; use a longer prefix')
	}
	return matches[0]
}

// resolve_ref accepts either a local branch name or a commit hash/prefix,
// trying branch names first (git does the same for ambiguous refs).
fn resolve_ref(root string, ref string) !string {
	head := local_branch_head(root, ref) or { return resolve_commit_ref(root, ref) }
	return head
}

// --- ls / show / diff / cat ---

fn cmd_ls(rest []string) {
	root := dvcs_root() or { fail('${err}') return }
	ref := if rest.len > 0 { rest[0] } else { current_branch(root) }
	commit_hash := resolve_ref(root, ref) or { fail('${err}') return }
	c := load_local_commit(root, commit_hash) or {
		fail('commit ${commit_hash} not found locally')
		return
	}
	mut paths := c.files.keys()
	paths.sort()
	if paths.len == 0 {
		println('(no tracked files)')
		return
	}
	for p in paths {
		println('${c.files[p][2..10]}  ${p}')
	}
}

fn cmd_show(rest []string) {
	root := dvcs_root() or { fail('${err}') return }
	if rest.len == 0 {
		fail('usage: dvcs show <commit-or-branch>')
	}
	commit_hash := resolve_ref(root, rest[0]) or { fail('${err}') return }
	c := load_local_commit(root, commit_hash) or {
		fail('commit ${commit_hash} not found locally')
		return
	}
	println('commit ${commit_hash}')
	println('Author: ${c.author}')
	println('Date:   ${time.unix(i64(c.timestamp))}')
	println('Parent: ${c.parent1}')
	if c.parent2 != '0x' + '00'.repeat(32) {
		println('Merge:  ${c.parent2}')
	}
	println('Tree:   ${c.tree_root}')
	if c.cid.len > 0 {
		println('CID:    ${c.cid}')
	}
	println('')
	for line in c.message.split_into_lines() {
		println('    ${line}')
	}
	println('')
	println('${c.files.len} file(s):')
	mut paths := c.files.keys()
	paths.sort()
	for p in paths {
		println('  ${c.files[p][2..10]}  ${p}')
	}
}

fn cmd_diff(rest []string) {
	root := dvcs_root() or { fail('${err}') return }
	if rest.len != 2 {
		fail('usage: dvcs diff <commit-or-branch-1> <commit-or-branch-2>')
	}
	hash_a := resolve_ref(root, rest[0]) or { fail('${err}') return }
	hash_b := resolve_ref(root, rest[1]) or { fail('${err}') return }
	ca := load_local_commit(root, hash_a) or {
		fail('commit ${hash_a} not found locally')
		return
	}
	cb := load_local_commit(root, hash_b) or {
		fail('commit ${hash_b} not found locally')
		return
	}
	mut all_paths := map[string]bool{}
	for p, _ in ca.files {
		all_paths[p] = true
	}
	for p, _ in cb.files {
		all_paths[p] = true
	}
	mut paths := all_paths.keys()
	paths.sort()
	mut changes := 0
	for p in paths {
		ha := ca.files[p] or { '' }
		hb := cb.files[p] or { '' }
		if ha == hb {
			continue
		}
		changes += 1
		if ha == '' {
			println('added    ${p}')
		} else if hb == '' {
			println('removed  ${p}')
		} else {
			println('modified ${p}')
		}
	}
	if changes == 0 {
		println('No differences (identical file trees).')
	}
}

fn cmd_cat(rest []string) {
	root := dvcs_root() or { fail('${err}') return }
	if rest.len != 2 {
		fail('usage: dvcs cat <commit-or-branch> <path>')
	}
	commit_hash := resolve_ref(root, rest[0]) or { fail('${err}') return }
	path := rest[1]
	c := load_local_commit(root, commit_hash) or {
		fail('commit ${commit_hash} not found locally')
		return
	}
	blob_hash_hex := c.files[path] or {
		fail('"${path}" is not tracked in ${commit_hash}')
		return
	}
	content := load_blob(root, bytes_to_hash32(hex_to_bytes(blob_hash_hex))) or {
		fail('content for "${path}" not found locally; run `dvcs pull` first')
		return
	}
	print(content.bytestr())
}

// --- push ---

// resolve_key figures out the AES key (or none, as an empty slice) to use
// for this operation: reads --passphrase from args or DVCS_PASSPHRASE from
// the environment. If encryption wasn't explicitly configured locally but
// this repo has a salt published on-chain (see repo_salt_identifier), that
// counts as "this repo uses encryption" too -- so a collaborator who ran
// `repo-connect` before the owner's `crypto-init` published anything (or
// who just never re-synced config) still gets prompted for a passphrase
// instead of silently pushing/pulling unencrypted content the owner never
// intended to be public. When a local verify_tag is known, a wrong
// passphrase is rejected immediately, before spending any gas or fetching
// any chunks; when it isn't (a freshly auto-discovered salt has no local
// tag), a wrong passphrase is instead caught later by AES-GCM's own
// authentication check on decrypt, which is still a hard failure -- just a
// slightly later one.
fn resolve_key(root string, cfg RepoConfig, rest []string) ![]u8 {
	mut effective := cfg
	if !effective.encrypt && effective.repo_id.len > 0 && effective.rpc_url.len > 0 {
		repo_id_bytes := hex_to_bytes(effective.repo_id)
		salt_id := repo_salt_identifier(repo_id_bytes)
		maybe_salt := fetch_raw(effective, repo_id_bytes, salt_id)
		if maybe_salt != none {
			effective.encrypt = true
			effective.salt = bytes_to_hex(maybe_salt)
			// Persist so future push/pull calls don't repeat this lookup.
			mut persisted := effective
			persisted.verify_tag = '' // unknown until a correct passphrase is supplied once
			write_config(root, persisted) or {}
		}
	}
	if !effective.encrypt {
		return []u8{}
	}
	mut passphrase := os.getenv('DVCS_PASSPHRASE')
	for i, a in rest {
		if a == '--passphrase' && i + 1 < rest.len {
			passphrase = rest[i + 1]
		}
	}
	if passphrase.len == 0 {
		return error('this repository has encryption enabled; supply --passphrase <p> or set DVCS_PASSPHRASE')
	}
	key := derive_key(passphrase, hex_to_bytes(effective.salt))
	if effective.verify_tag.len == 0 {
		// No local tag to check against yet (a freshly auto-discovered
		// salt has no ground truth for what "correct" means). We
		// deliberately do NOT persist a tag here -- doing so from an
		// unverified passphrase could lock in a *wrong* tag and cause
		// every subsequent attempt, including a later correct one, to be
		// rejected. The real check happens when this key is actually used
		// to decrypt something (see cmd_pull), which is the first point a
		// wrong passphrase can be proven wrong (or right).
		return key
	}
	tag := verification_tag(key)
	if tag != effective.verify_tag {
		return error('wrong passphrase for this repository')
	}
	return key
}

fn cmd_push(rest []string) {
	root := dvcs_root() or { fail('${err}') return }
	cfg := read_config(root) or { fail('${err}') return }
	require_remote(cfg)
	if cfg.repo_id.len == 0 {
		fail('repository not registered on-chain yet; run `dvcs repo-create <name>` first')
	}
	key := resolve_key(root, cfg, rest) or { fail('${err}') return }

	// A repo marked private on-chain must not have unencrypted content
	// pushed to it -- on-chain data is public to any block explorer
	// regardless of role-based access control, so "private" only means
	// something if content is actually encrypted before it leaves here.
	repo_id_bytes_check := hex_to_bytes(cfg.repo_id)
	info_calldata := encode_call(contract_signatures()['repositoryInfo'], [av_bytes32(repo_id_bytes_check)])
	info_hex := eth_call(cfg.rpc_url, cfg.contract, '0x' + bytes_to_hex(info_calldata)) or {
		fail('${err}')
		return
	}
	info_data := hex_to_bytes(info_hex)
	is_private := decode_bool(info_data, 2)
	if is_private && key.len == 0 {
		fail('this repository is marked private but encryption is not enabled; run `dvcs crypto-init <passphrase>` before pushing content (or `dvcs set-private false` if you actually want it public)')
	}

	mut branch := current_branch(root)
	mut force := false
	mut skip_next := false
	for a in rest {
		if skip_next {
			skip_next = false
			continue
		}
		if a == '--force' {
			force = true
		} else if a == '--passphrase' {
			skip_next = true
		} else if !a.starts_with('--') {
			branch = a
		}
	}
	head := local_branch_head(root, branch) or {
		fail('nothing to push: no commits on "${branch}"')
		return
	}

	repo_id_bytes := hex_to_bytes(cfg.repo_id)

	// Walk parent1 chain collecting commits not yet known on-chain.
	mut to_push := []string{}
	mut cur := head
	zero := '0x' + '00'.repeat(32)
	for cur != '' && cur != zero {
		exists := commit_exists_onchain(cfg, cur) or { fail('${err}') return }
		if exists {
			break
		}
		to_push << cur
		c := load_local_commit(root, cur) or {
			fail('local commit metadata missing for ${cur}; cannot push')
			return
		}
		cur = c.parent1
	}
	to_push = reverse_strings(to_push)

	if to_push.len == 0 {
		println('Branch "${branch}" already up to date on-chain; updating ref only.')
	} else {
		println('Pushing ${to_push.len} commit(s) to branch "${branch}"...')
	}

	for h in to_push {
		c := load_local_commit(root, h) or { continue }
		calldata := encode_call(contract_signatures()['pushCommit'], [
			av_bytes32(repo_id_bytes),
			av_bytes32(hex_to_bytes(c.parent1)),
			av_bytes32(hex_to_bytes(c.parent2)),
			av_bytes32(hex_to_bytes(c.tree_root)),
			av_string(c.message),
			av_uint(c.timestamp),
		])
		data_hex := '0x' + bytes_to_hex(calldata)
		tx := eth_send_transaction(cfg.rpc_url, cfg.account, cfg.contract, data_hex, '') or {
			fail('push failed for ${h}: ${err}')
			return
		}
		receipt := wait_for_receipt(cfg.rpc_url, tx, 60) or { fail('${err}') return }
		if receipt.status != '0x1' {
			fail('pushCommit reverted for ${h} (tx ${tx})')
		}
		append_changelog(root, 'push-commit', 'commit=${h} branch=${branch}', tx)
		println('  pushed ${h}  (tx ${tx})')

		// Push this commit's file content (manifest + each blob, skipping
		// blobs the contract already has). No IPFS or other off-chain
		// service involved -- the content lives in BlobChunk event logs.
		manifest_bytes := build_manifest(c.files)
		manifest_hash := keccak256(manifest_bytes)
		push_blob_if_needed(root, cfg, repo_id_bytes, manifest_hash, manifest_bytes, key) or {
			fail('failed to push manifest for ${h}: ${err}')
			return
		}
		mut pushed_blobs := 0
		for path, blob_hash_hex in c.files {
			blob_hash := bytes_to_hash32(hex_to_bytes(blob_hash_hex))
			content := load_blob(root, blob_hash) or {
				println('  warning: local content for "${path}" not found, skipping upload (recipients won\'t be able to fetch it)')
				continue
			}
			push_blob_if_needed(root, cfg, repo_id_bytes, blob_hash, content, key) or {
				fail('failed to push content for "${path}" in ${h}: ${err}')
				return
			}
			pushed_blobs += 1
		}
		cid := onchain_cid_prefix + hash32_to_hex(manifest_hash)
		cid_calldata := encode_call(contract_signatures()['setCommitCid'], [
			av_bytes32(repo_id_bytes),
			av_bytes32(hex_to_bytes(h)),
			av_string(cid),
		])
		cid_tx := eth_send_transaction(cfg.rpc_url, cfg.account, cfg.contract, '0x' + bytes_to_hex(cid_calldata),
			'') or {
			fail('failed to record content location for ${h}: ${err}')
			return
		}
		wait_for_receipt(cfg.rpc_url, cid_tx, 60) or { fail('${err}') return }
		append_changelog(root, 'set-cid', 'commit=${h} cid=${cid}', cid_tx)
		enc_note := if key.len > 0 { ' (encrypted)' } else { '' }
		println('  content: ${c.files.len} tracked file(s), ${pushed_blobs} uploaded this push${enc_note}')
	}

	// Move the branch pointer.
	branch_calldata := encode_call(contract_signatures()['updateBranch'], [
		av_bytes32(repo_id_bytes),
		av_string(branch),
		av_bytes32(hex_to_bytes(head)),
		av_bool(force),
	])
	data_hex := '0x' + bytes_to_hex(branch_calldata)
	tx := eth_send_transaction(cfg.rpc_url, cfg.account, cfg.contract, data_hex, '') or {
		fail('updateBranch failed: ${err}')
		return
	}
	receipt := wait_for_receipt(cfg.rpc_url, tx, 60) or { fail('${err}') return }
	if receipt.status != '0x1' {
		fail('updateBranch reverted (tx ${tx}); the remote branch may have diverged -- try `dvcs pull` or `--force`')
	}
	append_changelog(root, 'update-branch', 'branch=${branch} head=${head} force=${force}', tx)
	println('Branch "${branch}" now points to ${head} on-chain (tx ${tx}).')
}

fn commit_exists_onchain(cfg RepoConfig, commit_hash string) !bool {
	repo_id_bytes := hex_to_bytes(cfg.repo_id)
	calldata := encode_call(contract_signatures()['commitExists'], [
		av_bytes32(repo_id_bytes),
		av_bytes32(hex_to_bytes(commit_hash)),
	])
	data_hex := '0x' + bytes_to_hex(calldata)
	result_hex := eth_call(cfg.rpc_url, cfg.contract, data_hex)!
	data := hex_to_bytes(result_hex)
	if data.len < 32 {
		return false
	}
	return decode_bool(data, 0)
}

fn reverse_strings(arr []string) []string {
	mut out := []string{cap: arr.len}
	for i := arr.len - 1; i >= 0; i-- {
		out << arr[i]
	}
	return out
}

// --- pull ---

fn cmd_pull(rest []string) {
	root := dvcs_root() or { fail('${err}') return }
	cfg := read_config(root) or { fail('${err}') return }
	require_remote(cfg)
	if cfg.repo_id.len == 0 {
		fail('repository not registered on-chain yet; run `dvcs repo-create <name>` first')
	}
	key := resolve_key(root, cfg, rest) or { fail('${err}') return }
	mut branch := current_branch(root)
	mut skip_next := false
	for a in rest {
		if skip_next {
			skip_next = false
			continue
		}
		if a == '--passphrase' {
			skip_next = true
		} else if !a.starts_with('--') {
			branch = a
		}
	}
	repo_id_bytes := hex_to_bytes(cfg.repo_id)

	head_calldata := encode_call(contract_signatures()['branchHead'], [
		av_bytes32(repo_id_bytes),
		av_string(branch),
	])
	head_hex := eth_call(cfg.rpc_url, cfg.contract, '0x' + bytes_to_hex(head_calldata)) or {
		fail('${err}')
		return
	}
	head_data := hex_to_bytes(head_hex)
	if head_data.len < 32 {
		fail('branch "${branch}" not found on-chain')
	}
	remote_head_bytes := decode_bytes32(head_data, 0)
	remote_head_hex := hash32_to_hex(bytes_to_hash32(remote_head_bytes))

	chain_calldata := encode_call(contract_signatures()['getFirstParentChain'], [
		av_bytes32(repo_id_bytes),
		av_bytes32(remote_head_bytes),
		av_uint(256),
	])
	chain_hex := eth_call(cfg.rpc_url, cfg.contract, '0x' + bytes_to_hex(chain_calldata)) or {
		fail('${err}')
		return
	}
	chain_data := hex_to_bytes(chain_hex)
	hashes := decode_bytes32_array(chain_data, 0)

	mut synced := 0
	mut content_synced := 0
	mut key_confirmed := false
	for h in hashes {
		h_hex := hash32_to_hex(bytes_to_hash32(h))
		if load_local_commit(root, h_hex) != none {
			continue // already cached locally
		}
		commit_calldata := encode_call(contract_signatures()['getCommit'], [
			av_bytes32(repo_id_bytes),
			av_bytes32(h),
		])
		res_hex := eth_call(cfg.rpc_url, cfg.contract, '0x' + bytes_to_hex(commit_calldata)) or {
			fail('${err}')
			return
		}
		res := hex_to_bytes(res_hex)
		parent1 := decode_bytes32(res, 0)
		parent2 := decode_bytes32(res, 1)
		tree_root := decode_bytes32(res, 2)
		cid := decode_string(res, 3)
		message := decode_string(res, 4)
		author := decode_address(res, 5)
		timestamp := decode_uint(res, 6)

		mut files := map[string]string{}
		if cid.starts_with(onchain_cid_prefix) {
			manifest_hash := bytes_to_hash32(hex_to_bytes(cid[onchain_cid_prefix.len..]))
			manifest_bytes := fetch_blob(cfg, repo_id_bytes, manifest_hash, key) or {
				println('  warning: could not fetch file manifest for ${h_hex}: ${err}')
				[]u8{}
			}
			if manifest_bytes.len > 0 {
				// A successful decrypt+hash-check here is proof `key` is
				// correct for this repo -- if we didn't have a local
				// verify_tag yet (freshly auto-discovered salt), this is
				// the first point we can safely save one, so the *next*
				// push/pull with this passphrase fails fast instead of
				// only failing after fetching chunks.
				if key.len > 0 && !key_confirmed {
					mut current_cfg := read_config(root) or { cfg }
					if current_cfg.verify_tag.len == 0 {
						current_cfg.verify_tag = verification_tag(key)
						write_config(root, current_cfg) or {}
					}
					key_confirmed = true
				}
				files = parse_manifest(manifest_bytes)
				for path, blob_hash_hex in files {
					blob_hash := bytes_to_hash32(hex_to_bytes(blob_hash_hex))
					content := fetch_blob(cfg, repo_id_bytes, blob_hash, key) or {
						println('  warning: could not fetch content for "${path}": ${err}')
						continue
					}
					store_blob(root, content)
					content_synced += 1
				}
			}
		}

		save_local_commit(root, h_hex, LocalCommit{
			parent1: hash32_to_hex(bytes_to_hash32(parent1))
			parent2: hash32_to_hex(bytes_to_hash32(parent2))
			tree_root: hash32_to_hex(bytes_to_hash32(tree_root))
			message: message
			author: '0x' + bytes_to_hex(author)
			timestamp: timestamp
			cid: cid
			files: files
		})
		synced += 1
	}

	set_local_branch_head(root, branch, remote_head_hex)
	println('Synced ${synced} new commit(s) and ${content_synced} file blob(s) for branch "${branch}".')
	println('Branch "${branch}" now at ${remote_head_hex}')
	println('Run `dvcs checkout ${branch}` to write the files into your working directory.')
}

// --- delete-branch (on-chain) ---

fn cmd_delete_branch(rest []string) {
	root := dvcs_root() or { fail('${err}') return }
	cfg := read_config(root) or { fail('${err}') return }
	require_remote(cfg)
	if cfg.repo_id.len == 0 {
		fail('repository not registered on-chain yet')
	}
	if rest.len == 0 {
		fail('usage: dvcs delete-branch <name>')
	}
	branch := rest[0]
	repo_id_bytes := hex_to_bytes(cfg.repo_id)
	calldata := encode_call(contract_signatures()['deleteBranch'], [
		av_bytes32(repo_id_bytes),
		av_string(branch),
	])
	tx := eth_send_transaction(cfg.rpc_url, cfg.account, cfg.contract, '0x' + bytes_to_hex(calldata),
		'') or {
		fail('${err}')
		return
	}
	receipt := wait_for_receipt(cfg.rpc_url, tx, 60) or { fail('${err}') return }
	if receipt.status != '0x1' {
		fail('deleteBranch reverted (tx ${tx}); you likely need the Maintainer role or higher')
	}
	append_changelog(root, 'delete-branch', 'branch=${branch}', tx)
	println('Deleted on-chain branch "${branch}" (tx ${tx}).')
}

// --- private repository ---

// cmd_set_private flips the on-chain `isPrivate` flag. This does NOT hide
// commit metadata or existing content from a block explorer -- Ethereum
// has no concept of private on-chain data. What it does control is this
// CLI's own behavior: cmd_push refuses to push file content to a private
// repo unless encryption is enabled (see resolve_key / crypto-init), so
// "private" in practice means "content is unreadable without the
// passphrase", not "hidden from the chain".
fn cmd_set_private(rest []string) {
	root := dvcs_root() or { fail('${err}') return }
	cfg := read_config(root) or { fail('${err}') return }
	require_remote(cfg)
	if cfg.repo_id.len == 0 {
		fail('repository not registered on-chain yet')
	}
	if rest.len == 0 || (rest[0] != 'true' && rest[0] != 'false') {
		fail('usage: dvcs set-private <true|false>')
	}
	is_private := rest[0] == 'true'
	repo_id_bytes := hex_to_bytes(cfg.repo_id)
	calldata := encode_call(contract_signatures()['setVisibility'], [
		av_bytes32(repo_id_bytes),
		av_bool(is_private),
	])
	tx := eth_send_transaction(cfg.rpc_url, cfg.account, cfg.contract, '0x' + bytes_to_hex(calldata),
		'') or {
		fail('${err}')
		return
	}
	receipt := wait_for_receipt(cfg.rpc_url, tx, 60) or { fail('${err}') return }
	if receipt.status != '0x1' {
		fail('setVisibility reverted (tx ${tx}); you likely need repo ownership')
	}
	append_changelog(root, 'set-private', 'private=${is_private}', tx)
	println('Repository marked ${if is_private { 'private' } else { 'public' }} on-chain (tx ${tx}).')
	if is_private && !cfg.encrypt {
		println('')
		println('Note: this repo is private but encryption is not yet set up locally.')
		println('Run `dvcs crypto-init <passphrase>` before pushing any file content --')
		println('pushes will be refused otherwise. Commit metadata is always public')
		println('regardless (that part of the chain can never be hidden).')
	}
}

// --- member management ---

// resolve_address_or_handle accepts either a raw "0x..." address (42 chars,
// valid hex) or a handle registered via `identity-register`, resolving the
// latter on-chain via resolveHandle. This is what lets `member-add` accept
// something like an email-shaped string instead of requiring you to already
// know someone's raw address.
fn resolve_address_or_handle(cfg RepoConfig, value string) ![]u8 {
	if value.starts_with('0x') && value.len == 42 {
		return hex_to_bytes(value)
	}
	calldata := encode_call(contract_signatures()['resolveHandle'], [av_string(value)])
	result_hex := eth_call(cfg.rpc_url, cfg.contract, '0x' + bytes_to_hex(calldata)) or {
		return error('"${value}" is not a 0x address and could not be resolved as a handle: ${err}')
	}
	data := hex_to_bytes(result_hex)
	if data.len < 32 {
		return error('"${value}" is not a registered handle')
	}
	return decode_address(data, 0)
}

fn cmd_member_add(rest []string) {
	root := dvcs_root() or { fail('${err}') return }
	cfg := read_config(root) or { fail('${err}') return }
	require_remote(cfg)
	if cfg.repo_id.len == 0 {
		fail('repository not registered on-chain yet')
	}
	if rest.len != 2 {
		fail('usage: dvcs member-add <address-or-handle> <none|reader|contributor|maintainer>')
	}
	role_name := rest[1].to_lower()
	mut role_idx := -1
	for i, n in role_names {
		if n == role_name {
			role_idx = i
		}
	}
	if role_idx == -1 {
		fail('unknown role "${rest[1]}"; use one of: none, reader, contributor, maintainer')
	}
	address_bytes := resolve_address_or_handle(cfg, rest[0]) or { fail('${err}') return }
	address_hex := '0x' + bytes_to_hex(address_bytes)
	repo_id_bytes := hex_to_bytes(cfg.repo_id)
	calldata := encode_call(contract_signatures()['setCollaboratorRole'], [
		av_bytes32(repo_id_bytes),
		av_address(address_bytes),
		av_uint(u64(role_idx)),
	])
	tx := eth_send_transaction(cfg.rpc_url, cfg.account, cfg.contract, '0x' + bytes_to_hex(calldata),
		'') or {
		fail('${err}')
		return
	}
	receipt := wait_for_receipt(cfg.rpc_url, tx, 60) or { fail('${err}') return }
	if receipt.status != '0x1' {
		fail('setCollaboratorRole reverted (tx ${tx}); you likely need the Maintainer role or higher')
	}
	append_changelog(root, 'member-add', 'address=${address_hex} (input="${rest[0]}") role=${role_name}',
		tx)
	println('Set ${rest[0]} (${address_hex}) to role "${role_name}" (tx ${tx}).')
}

fn cmd_member_list() {
	root := dvcs_root() or { fail('${err}') return }
	cfg := read_config(root) or { fail('${err}') return }
	require_remote(cfg)
	if cfg.repo_id.len == 0 {
		fail('repository not registered on-chain yet')
	}
	repo_id_bytes := hex_to_bytes(cfg.repo_id)

	info_calldata := encode_call(contract_signatures()['repositoryInfo'], [av_bytes32(repo_id_bytes)])
	info_hex := eth_call(cfg.rpc_url, cfg.contract, '0x' + bytes_to_hex(info_calldata)) or {
		fail('${err}')
		return
	}
	info_data := hex_to_bytes(info_hex)
	owner := decode_address(info_data, 0)
	println('0x${bytes_to_hex(owner)}  owner${format_handle_suffix(cfg, owner)}')

	list_calldata := encode_call(contract_signatures()['collaborators'], [av_bytes32(repo_id_bytes)])
	list_hex := eth_call(cfg.rpc_url, cfg.contract, '0x' + bytes_to_hex(list_calldata)) or {
		fail('${err}')
		return
	}
	list_data := hex_to_bytes(list_hex)
	offset := int(decode_uint(list_data, 0))
	count := int(decode_uint(list_data, offset / 32))
	for i in 0 .. count {
		addr_word := offset + 32 + i * 32
		addr := decode_address(list_data, addr_word / 32)
		addr_hex := '0x' + bytes_to_hex(addr)

		role_calldata := encode_call(contract_signatures()['roleOf'], [
			av_bytes32(repo_id_bytes),
			av_address(addr),
		])
		role_hex := eth_call(cfg.rpc_url, cfg.contract, '0x' + bytes_to_hex(role_calldata)) or {
			continue
		}
		role_idx := int(decode_uint(hex_to_bytes(role_hex), 0))
		role_name := if role_idx >= 0 && role_idx < role_names.len {
			role_names[role_idx]
		} else {
			'unknown'
		}
		println('${addr_hex}  ${role_name}${format_handle_suffix(cfg, addr)}')
	}
}

fn format_handle_suffix(cfg RepoConfig, addr []u8) string {
	calldata := encode_call(contract_signatures()['addressHandle'], [av_address(addr)])
	result_hex := eth_call(cfg.rpc_url, cfg.contract, '0x' + bytes_to_hex(calldata)) or { return '' }
	data := hex_to_bytes(result_hex)
	handle := decode_string(data, 0)
	if handle.len == 0 {
		return ''
	}
	return '  (${handle})'
}

// --- identity ---

fn cmd_identity_register(rest []string) {
	root := dvcs_root() or { fail('${err}') return }
	cfg := read_config(root) or { fail('${err}') return }
	require_remote(cfg)
	if rest.len == 0 {
		fail('usage: dvcs identity-register <handle>')
	}
	handle := rest[0]
	calldata := encode_call(contract_signatures()['registerHandle'], [av_string(handle)])
	tx := eth_send_transaction(cfg.rpc_url, cfg.account, cfg.contract, '0x' + bytes_to_hex(calldata),
		'') or {
		fail('${err}')
		return
	}
	receipt := wait_for_receipt(cfg.rpc_url, tx, 60) or { fail('${err}') return }
	if receipt.status != '0x1' {
		fail('registerHandle reverted (tx ${tx}); "${handle}" is likely already claimed by another address')
	}
	append_changelog(root, 'identity-register', 'handle="${handle}"', tx)
	println('Registered handle "${handle}" for ${cfg.account} (tx ${tx}).')
	println('This proves you control this address -- it does not verify you own any')
	println('email inbox this string might resemble. Anyone can now use `dvcs member-add')
	println('${handle} <role>` on a repo instead of your raw address.')
}

fn cmd_identity_release() {
	root := dvcs_root() or { fail('${err}') return }
	cfg := read_config(root) or { fail('${err}') return }
	require_remote(cfg)
	calldata := encode_call(contract_signatures()['releaseHandle'], [])
	tx := eth_send_transaction(cfg.rpc_url, cfg.account, cfg.contract, '0x' + bytes_to_hex(calldata),
		'') or {
		fail('${err}')
		return
	}
	receipt := wait_for_receipt(cfg.rpc_url, tx, 60) or { fail('${err}') return }
	if receipt.status != '0x1' {
		fail('releaseHandle reverted (tx ${tx}); you may not have a handle registered')
	}
	append_changelog(root, 'identity-release', '', tx)
	println('Released your registered handle (tx ${tx}).')
}

fn cmd_identity_resolve(rest []string) {
	root := dvcs_root() or { fail('${err}') return }
	cfg := read_config(root) or { fail('${err}') return }
	require_remote(cfg)
	if rest.len == 0 {
		fail('usage: dvcs identity-resolve <handle>')
	}
	address_bytes := resolve_address_or_handle(cfg, rest[0]) or { fail('${err}') return }
	println('${rest[0]} -> 0x${bytes_to_hex(address_bytes)}')
}

fn cmd_whoami() {
	root := dvcs_root() or { fail('${err}') return }
	cfg := read_config(root) or { fail('${err}') return }
	require_remote(cfg)
	println('account: ${cfg.account}')
	calldata := encode_call(contract_signatures()['addressHandle'], [av_address(hex_to_bytes(cfg.account))])
	result_hex := eth_call(cfg.rpc_url, cfg.contract, '0x' + bytes_to_hex(calldata)) or {
		fail('${err}')
		return
	}
	data := hex_to_bytes(result_hex)
	handle := decode_string(data, 0)
	if handle.len == 0 {
		println('handle:  (none registered -- run `dvcs identity-register <handle>`)')
	} else {
		println('handle:  ${handle}')
	}
}

// --- pull requests ---

fn cmd_pr_open(rest []string) {
	root := dvcs_root() or { fail('${err}') return }
	cfg := read_config(root) or { fail('${err}') return }
	require_remote(cfg)
	if cfg.repo_id.len == 0 {
		fail('repository not registered on-chain yet')
	}
	if rest.len < 3 {
		fail('usage: dvcs pr-open <source-branch> <target-branch> "<title>" ["<description>"]')
	}
	source := rest[0]
	target := rest[1]
	title := rest[2]
	description := if rest.len > 3 { rest[3] } else { '' }
	repo_id_bytes := hex_to_bytes(cfg.repo_id)
	calldata := encode_call(contract_signatures()['openPullRequest'], [
		av_bytes32(repo_id_bytes),
		av_string(source),
		av_string(target),
		av_string(title),
		av_string(description),
	])
	tx := eth_send_transaction(cfg.rpc_url, cfg.account, cfg.contract, '0x' + bytes_to_hex(calldata),
		'') or {
		fail('${err}')
		return
	}
	receipt := wait_for_receipt(cfg.rpc_url, tx, 60) or { fail('${err}') return }
	if receipt.status != '0x1' {
		fail('openPullRequest reverted (tx ${tx}); check both branches exist on-chain and you have Contributor role or higher')
	}
	append_changelog(root, 'pr-open', 'source=${source} target=${target} title="${title}"', tx)
	println('Opened pull request: ${source} -> ${target}')
	println('  "${title}"')
	println('  tx: ${tx}')
	println('Run `dvcs pr-list` to find its id.')
}

fn cmd_pr_approve(rest []string) {
	root := dvcs_root() or { fail('${err}') return }
	cfg := read_config(root) or { fail('${err}') return }
	require_remote(cfg)
	if rest.len == 0 {
		fail('usage: dvcs pr-approve <pr-id>')
	}
	pr_id := rest[0].u64()
	repo_id_bytes := hex_to_bytes(cfg.repo_id)
	calldata := encode_call(contract_signatures()['approvePullRequest'], [
		av_bytes32(repo_id_bytes),
		av_uint(pr_id),
	])
	tx := eth_send_transaction(cfg.rpc_url, cfg.account, cfg.contract, '0x' + bytes_to_hex(calldata),
		'') or {
		fail('${err}')
		return
	}
	receipt := wait_for_receipt(cfg.rpc_url, tx, 60) or { fail('${err}') return }
	if receipt.status != '0x1' {
		fail('approvePullRequest reverted (tx ${tx}); you may lack Maintainer role, already approved, or be the PR author')
	}
	append_changelog(root, 'pr-approve', 'pr_id=${pr_id}', tx)
	println('Approved PR #${pr_id} (tx ${tx}).')
}

// fetch_branch_head_onchain reads a branch's CURRENT head directly from
// the contract (not the local cache, which can be stale).
fn fetch_branch_head_onchain(cfg RepoConfig, repo_id_bytes []u8, branch string) !string {
	calldata := encode_call(contract_signatures()['branchHead'], [
		av_bytes32(repo_id_bytes),
		av_string(branch),
	])
	result_hex := eth_call(cfg.rpc_url, cfg.contract, '0x' + bytes_to_hex(calldata))!
	data := hex_to_bytes(result_hex)
	if data.len < 32 {
		return error('branch "${branch}" not found on-chain')
	}
	return hash32_to_hex(bytes_to_hash32(decode_bytes32(data, 0)))
}

// is_ancestor_locally walks `descendant`'s first-parent chain in the LOCAL
// commit cache looking for `ancestor`. Returns none if the local cache runs
// out before reaching either a match or the root -- meaning "can't tell",
// not "false" -- so callers don't act on an inconclusive answer.
fn is_ancestor_locally(root string, ancestor string, descendant string) ?bool {
	zero := '0x' + '00'.repeat(32)
	mut cur := descendant
	mut steps := 0
	for cur != '' && cur != zero && steps < 1000 {
		if cur == ancestor {
			return true
		}
		c := load_local_commit(root, cur) or { return none }
		cur = c.parent1
		steps += 1
	}
	if cur == zero || cur == '' {
		return false // walked all the way to the root without finding it
	}
	return none // hit the step bound without a definitive answer
}

fn cmd_pr_merge(rest []string) {
	root := dvcs_root() or { fail('${err}') return }
	cfg := read_config(root) or { fail('${err}') return }
	require_remote(cfg)
	if rest.len == 0 {
		fail('usage: dvcs pr-merge <pr-id>')
	}
	pr_id := rest[0].u64()
	repo_id_bytes := hex_to_bytes(cfg.repo_id)

	pr := fetch_pr(cfg, repo_id_bytes, pr_id) or { fail('${err}') return }

	// Proactively check whether this would even be a fast-forward, using
	// CURRENT on-chain branch heads (not the possibly-stale local cache)
	// so the error, if any, is accurate and actionable rather than just
	// "reverted" from the contract's own fast-forward check.
	source_head := fetch_branch_head_onchain(cfg, repo_id_bytes, pr.source_branch) or { '' }
	target_head := fetch_branch_head_onchain(cfg, repo_id_bytes, pr.target_branch) or { '' }
	if source_head.len > 0 && target_head.len > 0 {
		ff := is_ancestor_locally(root, target_head, source_head)
		if ff != none {
			if !ff {
				fail('cannot merge PR #${pr_id}: "${pr.target_branch}" has advanced independently since ' +
					'"${pr.source_branch}" diverged from it (this would not be a fast-forward). This system ' +
					"has no automatic merge-commit creation for PRs -- resolve the same way `dvcs rebase` " +
					'handles divergence:\n' + '  dvcs checkout ${pr.source_branch}\n' + '  dvcs pull ${pr.target_branch}\n' +
					'  dvcs rebase ${pr.target_branch}   (add --ours/--theirs if it reports conflicts)\n' +
					'  dvcs push ${pr.source_branch} --force\n' + 'then retry `dvcs pr-merge ${pr_id}`.')
			}
		}
	}

	calldata := encode_call(contract_signatures()['mergePullRequest'], [
		av_bytes32(repo_id_bytes),
		av_uint(pr_id),
	])
	tx := eth_send_transaction(cfg.rpc_url, cfg.account, cfg.contract, '0x' + bytes_to_hex(calldata),
		'') or {
		fail('${err}')
		return
	}
	receipt := wait_for_receipt(cfg.rpc_url, tx, 60) or { fail('${err}') return }
	if receipt.status != '0x1' {
		fail('mergePullRequest reverted (tx ${tx}); not enough approvals yet, or the merge is not a fast-forward')
	}
	append_changelog(root, 'pr-merge', 'pr_id=${pr_id}', tx)
	println('Merged PR #${pr_id} (tx ${tx}).')
	println('Run `dvcs pull <target-branch>` to sync the merged commit locally.')
}

fn cmd_pr_close(rest []string) {
	root := dvcs_root() or { fail('${err}') return }
	cfg := read_config(root) or { fail('${err}') return }
	require_remote(cfg)
	if rest.len == 0 {
		fail('usage: dvcs pr-close <pr-id>')
	}
	pr_id := rest[0].u64()
	repo_id_bytes := hex_to_bytes(cfg.repo_id)
	calldata := encode_call(contract_signatures()['closePullRequest'], [
		av_bytes32(repo_id_bytes),
		av_uint(pr_id),
	])
	tx := eth_send_transaction(cfg.rpc_url, cfg.account, cfg.contract, '0x' + bytes_to_hex(calldata),
		'') or {
		fail('${err}')
		return
	}
	receipt := wait_for_receipt(cfg.rpc_url, tx, 60) or { fail('${err}') return }
	if receipt.status != '0x1' {
		fail('closePullRequest reverted (tx ${tx})')
	}
	append_changelog(root, 'pr-close', 'pr_id=${pr_id}', tx)
	println('Closed PR #${pr_id} (tx ${tx}).')
}

fn cmd_pr_min_approvals(rest []string) {
	root := dvcs_root() or { fail('${err}') return }
	cfg := read_config(root) or { fail('${err}') return }
	require_remote(cfg)
	if rest.len == 0 {
		fail('usage: dvcs pr-min-approvals <n>')
	}
	n := rest[0].u64()
	repo_id_bytes := hex_to_bytes(cfg.repo_id)
	calldata := encode_call(contract_signatures()['setMinApprovals'], [
		av_bytes32(repo_id_bytes),
		av_uint(n),
	])
	tx := eth_send_transaction(cfg.rpc_url, cfg.account, cfg.contract, '0x' + bytes_to_hex(calldata),
		'') or {
		fail('${err}')
		return
	}
	receipt := wait_for_receipt(cfg.rpc_url, tx, 60) or { fail('${err}') return }
	if receipt.status != '0x1' {
		fail('setMinApprovals reverted (tx ${tx}); you likely need the Maintainer role or higher')
	}
	append_changelog(root, 'pr-min-approvals', 'n=${n}', tx)
	println('Minimum approvals to merge a PR set to ${n} (tx ${tx}).')
}

fn cmd_pr_list() {
	root := dvcs_root() or { fail('${err}') return }
	cfg := read_config(root) or { fail('${err}') return }
	require_remote(cfg)
	repo_id_bytes := hex_to_bytes(cfg.repo_id)
	count_calldata := encode_call(contract_signatures()['pullRequestCount'], [av_bytes32(repo_id_bytes)])
	count_hex := eth_call(cfg.rpc_url, cfg.contract, '0x' + bytes_to_hex(count_calldata)) or {
		fail('${err}')
		return
	}
	count := int(decode_uint(hex_to_bytes(count_hex), 0))
	if count == 0 {
		println('No pull requests yet.')
		return
	}
	for i in 0 .. count {
		pr := fetch_pr(cfg, repo_id_bytes, u64(i)) or { continue }
		status := if pr.status < pr_status_names.len { pr_status_names[pr.status] } else { '?' }
		println('#${i}  [${status}]  ${pr.source_branch} -> ${pr.target_branch}  "${pr.title}"  (${pr.approval_count} approval(s))')
	}
}

fn cmd_pr_show(rest []string) {
	root := dvcs_root() or { fail('${err}') return }
	cfg := read_config(root) or { fail('${err}') return }
	require_remote(cfg)
	if rest.len == 0 {
		fail('usage: dvcs pr-show <pr-id>')
	}
	pr_id := rest[0].u64()
	repo_id_bytes := hex_to_bytes(cfg.repo_id)
	pr := fetch_pr(cfg, repo_id_bytes, pr_id) or {
		fail('${err}')
		return
	}
	status := if pr.status < pr_status_names.len { pr_status_names[pr.status] } else { '?' }
	println('PR #${pr_id}: ${pr.title}')
	println('  ${pr.source_branch} -> ${pr.target_branch}')
	println('  status:      ${status}')
	println('  author:      ${pr.author}')
	println('  approvals:   ${pr.approval_count}')
	println('  created:     ${time.unix(i64(pr.created_at))}')
	if pr.merged_commit != '0x' + '00'.repeat(32) {
		println('  merged as:   ${pr.merged_commit}')
	}
	if pr.description.len > 0 {
		println('')
		for line in pr.description.split_into_lines() {
			println('  ${line}')
		}
	}
}

struct PullRequestInfo {
	source_branch  string
	target_branch  string
	author         string
	title          string
	description    string
	status         int
	approval_count u64
	merged_commit  string
	created_at     u64
}

fn fetch_pr(cfg RepoConfig, repo_id_bytes []u8, pr_id u64) !PullRequestInfo {
	calldata := encode_call(contract_signatures()['getPullRequest'], [
		av_bytes32(repo_id_bytes),
		av_uint(pr_id),
	])
	res_hex := eth_call(cfg.rpc_url, cfg.contract, '0x' + bytes_to_hex(calldata))!
	res := hex_to_bytes(res_hex)
	return PullRequestInfo{
		source_branch: decode_string(res, 0)
		target_branch: decode_string(res, 1)
		author: '0x' + bytes_to_hex(decode_address(res, 2))
		title: decode_string(res, 3)
		description: decode_string(res, 4)
		status: int(decode_uint(res, 5))
		approval_count: decode_uint(res, 6)
		merged_commit: hash32_to_hex(bytes_to_hash32(decode_bytes32(res, 7)))
		created_at: decode_uint(res, 8)
	}
}

// --- rebase ---

// cmd_rebase replays commits unique to the current branch on top of
// <onto-branch>, purely locally (chain state untouched, like rollback).
// Each commit here already stores its FULL file tree rather than a diff,
// so replaying commit C means: recompute what C *changed* relative to its
// own original parent (its "delta"), then 3-way-merge that delta into the
// evolving target tree (see merge3.v) -- exactly like git applying one
// patch at a time during a rebase, just at the file-hash level instead of
// line level. Real conflicts (both sides changed the same path
// differently since diverging) are detected and, by default, stop the
// rebase at that commit rather than silently picking a winner; pass
// --ours or --theirs to auto-resolve every conflict the same way instead.
fn cmd_rebase(rest []string) {
	root := dvcs_root() or { fail('${err}') return }
	cfg := read_config(root) or { fail('${err}') return }
	if rest.len == 0 {
		fail('usage: dvcs rebase <onto-branch> [--ours | --theirs]')
	}
	onto := rest[0]
	mut strategy := 'abort'
	if rest.contains('--ours') {
		strategy = 'ours'
	} else if rest.contains('--theirs') {
		strategy = 'theirs'
	}

	current := current_branch(root)
	if onto == current {
		fail('cannot rebase branch "${current}" onto itself')
	}

	cur_head := local_branch_head(root, current) or {
		fail('nothing to rebase: no commits on "${current}"')
		return
	}
	onto_head := local_branch_head(root, onto) or {
		fail('branch "${onto}" not found locally or has no commits')
		return
	}

	zero := '0x' + '00'.repeat(32)

	mut onto_ancestors := map[string]bool{}
	mut walk := onto_head
	for walk != '' && walk != zero {
		onto_ancestors[walk] = true
		c := load_local_commit(root, walk) or { break }
		walk = c.parent1
	}

	mut to_replay := []string{}
	mut cur := cur_head
	mut merge_base := zero
	for cur != '' && cur != zero {
		if cur in onto_ancestors {
			merge_base = cur
			break
		}
		to_replay << cur
		c := load_local_commit(root, cur) or {
			fail('local commit metadata missing for ${cur}; cannot rebase')
			return
		}
		cur = c.parent1
	}
	to_replay = reverse_strings(to_replay) // oldest-first

	if to_replay.len == 0 {
		println('Nothing to rebase: "${current}" has no commits beyond ${merge_base} that "${onto}" lacks.')
		return
	}

	repo_id := bytes_to_hash32(hex_to_bytes(cfg.repo_id))
	mut new_parent_hex := onto_head
	mut ours_files := (load_local_commit(root, onto_head) or { LocalCommit{} }).files.clone()
	mut replayed := 0

	for old_hash in to_replay {
		old_c := load_local_commit(root, old_hash) or { continue }
		base_files := if old_c.parent1 == zero {
			map[string]string{}
		} else {
			(load_local_commit(root, old_c.parent1) or { LocalCommit{} }).files.clone()
		}
		theirs_files := old_c.files.clone()

		result := merge3_files(base_files, ours_files, theirs_files)
		mut merged_files := result.files.clone()

		if result.conflicts.len > 0 {
			if strategy == 'abort' {
				println('')
				println('CONFLICT: rebasing ${old_hash} ("${old_c.message}") onto "${onto}" hit')
				println('${result.conflicts.len} conflicting path(s) (both sides changed these since diverging):')
				for p in result.conflicts {
					println('  ${p}')
				}
				println('')
				if replayed > 0 {
					set_local_branch_head(root, current, new_parent_hex)
					println('Replayed ${replayed} commit(s) before stopping; "${current}" now at ${new_parent_hex}.')
				} else {
					println('Nothing was replayed; "${current}" is unchanged.')
				}
				println('Re-run with --ours (keep "${current}"\'s own version of conflicting paths) or')
				println('--theirs (take "${onto}"\'s version) to auto-resolve and continue, or')
				println('inspect both sides yourself with `dvcs cat <ref> <path>`.')
				return
			}
			println('  resolving ${result.conflicts.len} conflict(s) in ${old_hash[2..10]} via --${strategy}: ${result.conflicts.join(', ')}')
			// NOTE: "ours"/"theirs" here mean what a user would intuitively
			// expect -- "ours" = my current branch's own version, "theirs"
			// = the other (onto) branch's version -- deliberately NOT
			// git's own rebase convention, where those two are flipped
			// from merge's meaning (a well-known source of confusion).
			merged_files = apply_strategy(result, theirs_files, ours_files, strategy)
		}

		mut tracked := []TrackedFile{}
		for path, hash_hex in merged_files {
			tracked << TrackedFile{
				path: path
				hash: bytes_to_hash32(hex_to_bytes(hash_hex))
			}
		}
		new_tree_root := merkle_root(tracked)

		timestamp := now_unix()
		author_bytes := hex_to_bytes(old_c.author)
		new_parent := bytes_to_hash32(hex_to_bytes(new_parent_hex))

		new_hash := compute_commit_hash_local(repo_id, new_parent, [32]u8{}, new_tree_root, old_c.message,
			author_bytes, timestamp)
		new_hash_hex := hash32_to_hex(new_hash)

		save_local_commit(root, new_hash_hex, LocalCommit{
			parent1: new_parent_hex
			parent2: zero
			tree_root: hash32_to_hex(new_tree_root)
			message: old_c.message
			author: old_c.author
			timestamp: timestamp
			cid: ''
			files: merged_files
		})

		println('  ${old_hash[2..10]} -> ${new_hash_hex[2..10]}  ${old_c.message}')
		new_parent_hex = new_hash_hex
		ours_files = merged_files.clone()
		replayed += 1
	}

	set_local_branch_head(root, current, new_parent_hex)
	println('Rebased ${replayed} commit(s) of "${current}" onto "${onto}" (${onto_head}).')
	println('New head: ${new_parent_hex}')
	println('')
	println('Note: this only changed local commit hashes and your branch pointer.')
	println('The old commits (if already pushed) still exist on-chain unchanged.')
	println('To push the rebased history, run `dvcs push --force`.')
}
