# Self-contained image for the DVCS project: builds the V compiler, the
# CLI, and the contract, and pre-installs Hardhat, so a container built
# from this image can run the demo/tutorial/tests immediately with no
# further compilation or network access needed at `docker run` time.
#
# Built and intended to be run via Docker Desktop -- see DOCKER.md. This
# is the recommended path on Windows: it sidesteps needing WSL2, a C
# compiler, Node, or V installed on the host at all. Docker Desktop is the
# only thing you install directly on Windows; everything else happens
# inside the container.

FROM node:20-bookworm

# --- V compiler ---
# V has no package-manager install; build it from source (this is exactly
# what SETUP.md has a human do manually -- same steps, just baked into the
# image instead). `tcc` is also installed and used as V's C backend below:
# recent V builds can otherwise trigger a very slow, memory-heavy internal
# self-check on a project this size with the default cc/gcc backend --
# confirmed while building this project, where identical source compiled
# in seconds with tcc and did not complete with plain cc in a
# memory-constrained test. See SETUP.md's Troubleshooting section.
RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        build-essential \
        python3 \
        curl \
        ca-certificates \
        tcc \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 https://github.com/vlang/v.git /opt/v \
    && cd /opt/v && make
ENV PATH="/opt/v:${PATH}"

WORKDIR /app
COPY . .

# --- Build the contract and the CLI at image-build time ---
RUN chmod +x scripts/compile-contract.sh scripts/demo.sh test/integration/run.sh \
    && ./scripts/compile-contract.sh \
    && cd cli && v -cc tcc -o dvcs . && cd ..

# --- Pre-install Hardhat + ethers so `docker run` needs no network access ---
RUN cd scripts && npm install --save-dev "hardhat@^2.22.0" ethers \
    && cd ../test/integration && npm install --save-dev "hardhat@^2.22.0" ethers

# Make the CLI available as a plain `dvcs` command inside the container --
# this is the "set PATH" step from SETUP.md, done once, here, instead of
# per-user on the host.
RUN ln -s /app/cli/dvcs /usr/local/bin/dvcs

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["demo"]
