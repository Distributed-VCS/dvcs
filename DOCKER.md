# DOCKER — the easiest path on Windows (no WSL2 setup needed)

If you're on Windows and don't want to set up WSL2, a C compiler, Node,
and V by hand, this is the shortest path: install one thing (Docker
Desktop), then everything else — V, Node, Hardhat, compiling the
contract, building the CLI — happens automatically inside a container the
first time you build the image. You never touch bash, `apt`, or any of
SETUP.md's individual install steps directly on Windows.

**Important, upfront and honest:** the Dockerfile and entrypoint below
were written and carefully reviewed, and every individual command they run
was separately verified working in an equivalent Linux environment during
this project's development — but the *container build itself* has not
been run start-to-finish in the environment this project was built in (no
Docker daemon was available there). If something in "Building the image"
below doesn't work exactly as described, please treat this section as a
strong starting point rather than a guarantee, and see "Troubleshooting"
at the end.

---

## 1. Install Docker Desktop

Download from [docker.com/products/docker-desktop](https://www.docker.com/products/docker-desktop/)
and install it. On Windows, it will offer to use the WSL2 backend — accept
that; it manages WSL2 for you automatically, which is different from
setting it up yourself as SETUP.md describes for a native install. You do
not need to interact with WSL2 directly at all.

Confirm it's working (PowerShell, cmd, or a Windows terminal — no bash
needed):
```
docker --version
docker compose version
```

## 2. Get the project

Unzip the project wherever you like, e.g. `Documents\dvcs-project`, then
open a terminal there.

## 3. Build the image

```
docker compose build
```
This will take a few minutes the first time — it's compiling the V
compiler from source, compiling the contract, building the CLI, and
installing Hardhat, all inside the image. Subsequent builds are much
faster (Docker caches layers that haven't changed).

## 4. Run the demo

```
docker compose run --rm dvcs
```
That's it — this starts a fresh Hardhat chain *inside the container*,
deploys the contract, and runs the entire tutorial narrative
automatically: real commits, a real feature branch, a real pull request
with a blocked self-approval, a real merge conflict, and a private
encrypted repo — narrated with timed pauses so you can talk over it while
recording. See `VIDEO_SCRIPT.md` for what each scene is showing.

Useful variations:
```
docker compose run --rm dvcs demo --pause 8            # slower, more time to narrate
docker compose run --rm dvcs demo --type-speed 0        # skip the typing animation
docker compose run --rm dvcs shell                      # interactive shell, dvcs already on PATH
docker compose run --rm dvcs test                       # unit test suite
docker compose run --rm dvcs integration-test            # full integration suite
```
Each `docker compose run` starts a brand-new container — so every demo
run is automatically fresh (new chain, new contract address, no leftover
state), which is exactly the repeatability problem this setup solves.

**Without Compose**, the equivalent plain `docker` commands:
```
docker build -t dvcs-demo .
docker run --rm -it dvcs-demo
docker run --rm -it dvcs-demo shell
```

## 5. Explore manually (optional)

```
docker compose run --rm dvcs shell
```
drops you into a container with `dvcs` already built and on `PATH`, and
the contract already compiled. From there you can follow `TUTORIAL.md`
yourself, step by step, exactly as written — start your own Hardhat node
(`cd scripts && npx hardhat node &`), deploy (`node deploy.js`), and run
`dvcs` commands directly. Anything you create only exists for the
lifetime of that container unless you set up a volume mount (see below).

**Persisting work across container runs:** by default, everything you do
inside the container (repos, chain state) disappears when the container
exits — appropriate for a demo, less so if you want to keep working on
something. To persist a directory, mount it as a volume:
```
docker compose run --rm -v "${PWD}/my-work:/app/my-work" dvcs shell
```
(PowerShell: use `${PWD}` as shown; cmd.exe: use `%cd%` instead.)

---

## Troubleshooting

**Build hangs for a long time or seems stuck on "Building the CLI"** —
this was a real issue found while building this project: recent V builds
can trigger a very slow, memory-heavy internal self-check with the
default `cc`/`gcc` backend on a project this size. The Dockerfile already
installs `tcc` and builds with `-cc tcc` specifically to avoid this — if
you're seeing it anyway (e.g. after editing the Dockerfile), that flag is
the fix. See SETUP.md's Troubleshooting section for more detail.

**Build fails during the V compiler step** — this compiles V from source
via `make`, which needs a working C toolchain; the image installs
`build-essential` for this. If it fails, the error from `make` itself will
be in the build output — that's the most useful thing to search for or
share if asking for help.

**Build fails during `compile-contract.sh`** — this step needs network
access (it fetches `solcjs` via `npx` the first time). Make sure Docker
Desktop itself has network access (default), and retry — `npx` downloads
can occasionally be flaky on a slow connection.

**"Cannot connect to the Docker daemon"** — Docker Desktop isn't running.
Start it from the Start menu and wait for it to say "Docker Desktop is
running" before retrying.

**Demo runs but output looks garbled / no colors** — your terminal may not
render ANSI colors well. Try `docker compose run --rm dvcs demo --no-color`.

**Want to change the demo's internal port** (default 8555, only relevant
inside the container) — `docker compose run --rm dvcs demo --port 8556`.

**Rebuilding after changing project files** — `docker compose build`
again; Docker only re-runs the steps affected by what changed.

---

## Why Docker instead of native install or WSL2

- **Fewer moving parts on Windows itself** — Docker Desktop is the only
  thing installed directly on the host; V, Node, solc, and Hardhat all
  live inside the image, versioned and reproducible.
- **Solves "I always get a new address"** — `scripts/demo.sh` (see
  `VIDEO_SCRIPT.md`) already solves this by deploying fresh and capturing
  the result automatically, but running it inside a fresh container each
  time adds a second layer of the same guarantee: nothing from a previous
  run can leak into the next one.
- **Same image works on Windows, macOS, and Linux** — anyone with Docker
  Desktop (or plain Docker on Linux) gets an identical environment.

If you'd rather install everything directly (no Docker), `SETUP.md` is
the from-scratch guide for that path, including WSL2 for Windows.
