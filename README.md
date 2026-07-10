# otala-runc

**Container runtime guided by Obatala's principles of purity and wise isolation.**

Pre-built binaries for the [otala-runc](https://github.com/Simeon2001/otalarunc) container runtime — a lightweight, rootless container runtime that runs commands and scripts inside isolated Alpine Linux environments. No Go toolchain or source code needed.

> **Binary name:** `otala-runc` — the compiled binary.  
> **CLI command:** `otala-box` is printed by `--help`, but the binary is invoked as `otala-runc`. Both refer to the same tool.

---

## Table of Contents

- [Quick install](#quick-install)
- [Manual install](#manual-install)
- [Requirements](#requirements)
- [Usage](#usage)
  - [Subcommands](#subcommands)
  - [Run flags](#run-flags)
  - [Flag validation rules](#flag-validation-rules)
- [Examples](#examples)
  - [Shell commands](#shell-commands)
  - [Language runtimes (--script)](#language-runtimes---script)
  - [Language runtimes (--script vs --command)](#language-runtimes---script-vs---command)
  - [Port forwarding & proxy](#port-forwarding--proxy)
  - [Environment variables](#environment-variables)
  - [APK package installation](#apk-package-installation)
  - [CPU limits & memory limits](#cpu-limits--memory-limits)
  - [Memory limits & cleanup](#memory-limits--cleanup)
  - [Preloaded dependencies](#preloaded-dependencies)
  - [Network isolation](#network-isolation)
  - [Unix socket bind-mount](#unix-socket-bind-mount)
  - [Proxy client](#proxy-client)
- [Mount & copy directory layout](#mount--copy-directory-layout)
- [Language runtimes](#language-runtimes)
  - [JavaScript / Node.js](#javascript--nodejs)
  - [Python](#python)
  - [Go](#go)
  - [Bash](#bash)
  - [Rust & Java (planned)](#rust--java-planned)
- [Configuration file](#configuration-file)
- [How it works](#how-it-works)
  - [Filesystem isolation](#filesystem-isolation)
  - [Namespaces](#namespaces)
  - [Security](#security)
  - [Resource limits (rlimits)](#resource-limits-rlimits)
  - [Networking](#networking)
  - [Port management database](#port-management-database)
  - [Container lifecycle](#container-lifecycle)
- [Architecture](#architecture)
- [Releases](#releases)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

## Quick install

```bash
curl -fsSL https://raw.githubusercontent.com/Simeon2001/otalarunc-binary/main/install.sh | sudo bash
```

This installs `otala-runc` to `/usr/local/bin/otala-runc` and handles system dependencies (pasta, shadow-utils, libseccomp) for Debian/Ubuntu, Fedora, Arch, and openSUSE.

## Manual install

```bash
# Download for your architecture
ARCH=$(uname -m)
case $ARCH in
  x86_64)  FILE="otala-runc-linux-amd64" ;;
  aarch64) FILE="otala-runc-linux-arm64" ;;
  armv7l)  FILE="otala-runc-linux-armv7"  ;;
esac

curl -fsSL "https://github.com/Simeon2001/otalarunc-binary/releases/latest/download/$FILE" -o /tmp/otala-runc
chmod +x /tmp/otala-runc
sudo cp /tmp/otala-runc /usr/local/bin/otala-runc
```

## Requirements

- **Linux with systemd** — for cgroup memory management via transient scopes
- **pasta** (from `passt` package) — user-mode networking
- **shadow-utils** — provides `newuidmap`, `newgidmap`, `getsubids`
- **libseccomp** — seccomp-BPF syscall filtering

The install script handles all of these for Debian/Ubuntu, Fedora, Arch, and openSUSE.

---

## Usage

### Subcommands

| Subcommand | Description |
|------------|-------------|
| `otala-runc run [flags]` | Run a container with the specified configuration |
| `otala-runc proxy-client [--server addr]` | Connect to a proxy server for container tunneling |
| `otala-runc version` | Show version information |

### Run flags

| Flag | Alias | Default | Description |
|------|-------|---------|-------------|
| `--command` | `-cmd` | — | Name of an executable in the container's PATH (e.g. `echo`, `node`, `python3`, `sh`). Pass each argument as a separate `--args` (e.g., `--args -la --args /app`). Does NOT interpret shell metacharacters — for pipes/redirects use `--command sh --args -c --args "command \| wc -l"` |
| `--script` | `-s` | — | Script file to execute (relative to the copied/mounted project directory). Requires `--language` |
| `--language` | `-l` | — | Runtime language (`javascript`, `python`, `golang`, `rust`, `java`, `bash`). Required when using `--script`. Determines the executor automatically (e.g. `node`, `python3`, `go run`) and auto-detects dependency files. Use with `--script`, NOT with `--command` |
| `--args` | `-a` | — | Arguments passed to the script or command. Repeatable: `-a arg1 -a arg2` |
| `--copy` | `-cp` | — | Snapshot a host directory into the container's project root at `/MDIR-{id}`. No host dependency after start. At least one of `--copy` or `--mount` is required. Defaults to current working directory if neither is given |
| `--mount` | `-m` | — | Bind-mount host paths into the container. Repeatable. Three syntaxes (see [Mount & copy directory layout](#mount--copy-directory-layout)): `--mount /host/path` (places at `/MDIR-{id}`), `--mount /host/path:/abs/dest` (places at exact path), `--mount /host/path:rel/dest` (places at `/MDIR-{id}/rel/dest`). Can be combined with `--copy` |
| `--memory-limit` | `-ml` | `100` | Memory limit in MB |
| `--cpus` | — | `0.5` | Fractional vCPU limit (e.g., `0.5` = half a core, `2.0` = two full cores) |
| `--net` | `-n` | `true` | Enable/disable pasta networking. `--net=false` creates a fully air-gapped container |
| `--port` | `-p` | `0` | Container port to expose to the host. Used with `--proxy` to enable port forwarding via pasta |
| `--proxy` | `-px` | `false` | Enable proxy port forwarding. When true, the allocated host port is forwarded to the container on `--port` |
| `--env` | `-e` | — | Set environment variables inside the container. Two forms: `-e KEY=VALUE` (set explicitly) or `-e KEY` (pass through from host). Repeatable |
| `--preload-deps` | `-pd` | `false` | Skip npm/pip/go dependency download. Trust pre-existing `node_modules/`, `.venv/`, or `vendor/` in the project directory. Useful with `--net=false` or private registries |
| `--install` | `-i` | — | APK packages to install before execution (e.g. `--install 'curl git nodejs'`). Space or comma separated |
| `--delete` | `-d` | `false` | Delete container filesystem and artifacts on completion |
| `--unix-socket` | `-us` | `false` | Bind-mount a Unix socket into the container for host IPC. The socket is sourced from `$XDG_RUNTIME_DIR/otala-runc/otala.sock` and mounted at `/run/otala-runc.sock` inside the container |
| `--project-id` | `-pid` | — | Stable subdomain prefix for the proxy tunnel. When set with `--proxy --port`, the public URL becomes `{project-id}.otarunpxy.name.ng`. Must be unique — duplicates are rejected. Useful for memorable URLs that survive restarts. If omitted, the proxy server auto-generates a random short code instead |
| `--config` | `-cf` | — | Path to a JSON configuration file (see [Configuration file](#configuration-file)) |

### Flag validation rules

| Rule | Details |
|------|---------|
| `--script` vs `--command` | Exactly one must be specified. They are mutually exclusive |
| `--script` + `--language` | `--language` is required when `--script` is used |
| `--copy` vs `--mount` | Can be used together. `--copy` populates `/MDIR-{id}`, `--mount` adds extra bind-mounts. At least one must be specified |
| `--copy` paths | Must be absolute host paths that exist |
| `--mount` paths | Host path must be absolute and exist. Container dest syntax: `--mount /host/path` → mounts at `/MDIR-{id}`; `--mount /host/path:/abs/path` → mounts at exact path; `--mount /host/path:rel/path` → mounts at `/MDIR-{id}/rel/path` |
| Working directory | Set by `--copy` when present (WD = `/MDIR-{id}`). Otherwise set by the first `--mount` entry: no colon → `/MDIR-{id}`; absolute dest → that path; relative dest → `/MDIR-{id}/<dest>` |
| Script path resolution | Resolved relative to the working directory |
| `--language` values | Must be one of: `javascript`, `python`, `golang`, `rust`, `java`, `bash` |
| `--command` metacharacters | Rejected if they contain `\|`, `;`, `&`, `` ` ``. The command runs directly (no shell), so use `--command sh --args -c --args "command \| wc -l"` when shell features are needed |
| `--install` chars | Package names must not contain: `;`, `\|`, `&`, `` ` ``, `$`, `(`, `)`, `{`, `}` |
| `--install` empty names | Empty package names are rejected |
| `--preload-deps` | When set, dependency download (npm/pip/go) is skipped entirely. Dependencies must already exist in the project directory. Combine with `--net=false` for air-gapped workflows |
| `--unix-socket` | If enabled, the host socket file at `$XDG_RUNTIME_DIR/otala-runc/otala.sock` must exist. If `$XDG_RUNTIME_DIR` is unset, falls back to `/run/user/<UID>/otala-runc/otala.sock` |

---

## Mount & copy directory layout

Understanding where files land inside the container is critical. Every container has a **project root** at `/MDIR-{containerID}` (e.g., `/MDIR-otalacon-abc123`). Here's how `--copy` and `--mount` place files relative to it.

### Container filesystem overview

```
/  (container rootfs — Alpine Linux overlay)
├── MDIR-{id}/        ← project root (working directory by default)
│   ├── your-files    ← from --copy, or --mount /host/path
│   ├── node_modules/ ← from --mount /host/cache:node_modules
│   └── uploads/      ← from --mount /host/data:uploads
├── app/              ← from --mount /host/project:/app  (outside MDIR-{id})
├── data/             ← from --mount /host/data:/data    (outside MDIR-{id})
├── bin/
├── etc/
└── ...
```

### `--copy` (snapshot, copied once at start)

```bash
--copy /home/user/project
# Result:  /home/user/project/*  →  /MDIR-{id}/
#          Working directory = /MDIR-{id}
```

The host directory is **copied** (not mounted). Changes to the host dir after start are **not** reflected inside the container. The container operates independently.

### `--mount` (live bind, 3 syntaxes)

| Syntax | Example | Host source | Container destination |
|---|---|---|---|
| **No dest** — lands at project root | `--mount /data` | `/data` | `/MDIR-{id}` |
| **Absolute dest** — lands anywhere | `--mount /data:/app/uploads` | `/data` | `/app/uploads` |
| **Relative dest** — lands inside project root | `--mount /data:uploads` | `/data` | `/MDIR-{id}/uploads` |

#### 1. No dest — `--mount /host/path`

Places the host path at the container's **project root** (`/MDIR-{id}`). Replaces whatever would have been in the project root (use this when you only have one source).

```bash
--mount /home/user/project
# → /home/user/project  is mounted at  /MDIR-{id}
# → Working directory = /MDIR-{id}
```

#### 2. Absolute dest — `--mount /host/path:/absolute/path`

Places the host path at an **exact location** anywhere in the container's root filesystem. Use this when a tool expects files at a specific path (e.g., `/var/lib/data`, `/etc/config`, `/app`).

```bash
--mount /home/user/project:/app
# → /home/user/project  is mounted at  /app
# → Working directory = /app
```

⚠️ **Absolute dest paths live OUTSIDE `/MDIR-{id}`.** They can be anywhere in the container. This is intentional — use it for placing files where your runtime expects them (e.g., `/app`, `/data`, `/var/log`).

#### 3. Relative dest — `--mount /host/path:relative/path`

Places the host path **inside the project root** at the given relative path. Use this to add supplementary directories to your project (e.g., a fast SSD cache for `node_modules`, a separate data directory, config files).

```bash
--mount /ssd/cache:node_modules
# → /ssd/cache  is mounted at  /MDIR-{id}/node_modules
# → Working directory = /MDIR-{id} (from first mount or --copy)
```

✅ **Relative paths always stay inside `/MDIR-{id}`.** There is no way to escape the project root with a relative dest.

### Combining `--copy` and `--mount`

When used together, `--copy` populates the project root (`/MDIR-{id}`) and `--mount` adds extra bind-mounts on top. The working directory is always `/MDIR-{id}` (set by `--copy`).

```bash
otala-runc run \
  --copy /home/user/project \           # copies into /MDIR-{id}
  --mount /ssd/cache:node_modules \      # mounts at /MDIR-{id}/node_modules
  --mount /mnt/data:data \               # mounts at /MDIR-{id}/data
  --language javascript --script server.mjs

# Result:
#   /MDIR-{id}/          ← project files from --copy
#   /MDIR-{id}/node_modules/  ← SSD cache bind-mount
#   /MDIR-{id}/data/     ← data bind-mount
#   Working directory = /MDIR-{id}
```

### Working directory rules

| Scenario | Working directory |
|---|---|
| `--copy /path` | Always `/MDIR-{id}` |
| `--mount /path` (no colon) | `/MDIR-{id}` |
| `--mount /path:/app` (abs dest) | `/app` |
| `--mount /path:subdir` (rel dest) | `/MDIR-{id}/subdir` |
| `--copy /path --mount /path2:/app` | `/MDIR-{id}` (copy wins) |

---

## Examples

### Shell commands

`--command` takes the name of an executable in PATH. Each `--args` value becomes one argv element — **do not group multiple words under one `--args`** (the shell passes the entire quoted string as a single argument).

```bash
# ✅ Each word as separate --args
otala-runc run --command ls --args -la --args /app --args /app/static

# ❌ WRONG — the quoted string becomes ONE arg with spaces
otala-runc run --command ls --args "-la /app /app/static"

# Simple echo (a single string arg is fine)
otala-runc run --command echo --args "hello from inside a container"

# Shell with pipes/redirects — -c and command are separate args
otala-runc run --command sh --args -c --args "ps aux | grep node | wc -l"

# Interactive shell
otala-runc run --command sh
```

### Language runtimes (--script)

When using `--script`, the runtime detects the language, sets up the correct executor, and optionally installs dependencies.

```bash
# Node.js script with dependencies
otala-runc run --script index.js --language javascript --copy ./my-node-app

# Python script with arguments
otala-runc run --script analyze.py --language python -a data.csv -a --verbose \
  --copy ./ml-project --install 'curl wget' --memory-limit 512

# Go script
otala-runc run --script main.go --language golang --copy ./go-project

# Python with virtualenv and requirements.txt
otala-runc run --script app.py --language python --copy ./python-app

# Bash script
otala-runc run --script deploy.sh --language bash --copy ./scripts
```

### Language runtimes (--script vs --command)

Use `--language` with `--script` (not `--command`). The language resolver automatically picks the correct executor.

```bash
# WRONG — --language sets the executor, don't use --command
otala-runc run --proxy --port 8080 --language javascript --command node --args server.mjs

# RIGHT — let the language resolver handle the executor
otala-runc run --proxy --port 8080 --language javascript --script server.mjs --args 8080
```

### Port forwarding & proxy

```bash
# Single mount — host path lands at /MDIR-{id}
otala-runc run --command python3 --args -m --args http.server --args 8080 \
  --mount /home/user/webapp --port 8080

# Multiple mounts with explicit destinations
otala-runc run --language javascript --script server.mjs \
  --mount /home/user/project:/app \        # mounts at /app (outside MDIR-{id})
  --mount /home/user/data:/app/data \      # mounts at /app/data
  --mount /home/user/cache:node_modules    # mounts at /MDIR-{id}/node_modules
  --proxy --port 3000

# Combine --copy (project root) with --mount (extras)
otala-runc run --language javascript --script server.mjs \
  --copy /home/user/project \              # copies into /MDIR-{id}
  --mount /ssd/cache:node_modules \        # mounts at /MDIR-{id}/node_modules
  --proxy --port 3000

# With proxy flag enabled (--language + --script, not --command)
otala-runc run --proxy --port 8080 --language javascript --script server.mjs --args 8080
```

When `--proxy` is enabled, a host port is automatically allocated from the range 10000–60000 and forwarded to the container port specified by `--port`. Port allocations are tracked in a SQLite database and recycled when containers stop.

### Environment variables

```bash
# Set explicit variables (use sh -c for variable expansion)
otala-runc run --command sh --args -c --args "echo \$API_KEY" -e API_KEY=sk-abc123 --net=false

# Multiple variables, including one with spaces
otala-runc run --script app.py --language python \
  -e DEBUG=true -e 'GREETING=hello world' --copy .

# Pass through a variable from the host (use sh -c for variable expansion)
export SECRET_TOKEN=xyz789
otala-runc run --command sh --args -c --args "echo \$SECRET_TOKEN" -e SECRET_TOKEN --net=false
```

### APK package installation

Install Alpine packages before your script runs using `--install`:

```bash
# Install curl and git for a deployment script
otala-runc run --script deploy.sh --language bash \
  --copy ./scripts --install 'curl git'

# Install npm + node, then run a script with --language
otala-runc run --language javascript --script app.js \
  --copy . --install 'npm node'

# Install multiple packages for a build
otala-runc run --script build.sh --language bash \
  --copy . --install 'build-base python3 py3-pip'
```

Packages are installed via `apk add --no-cache` inside the container. Alpine's APK repository is updated before each install.

### CPU limits & memory limits

```bash
# Default: 0.5 vCPUs (half a core)
otala-runc run --command echo --args "limited to 0.5 vCPU"

# Specify 2 full vCPUs
otala-runc run --cpus 2.0 --command echo --args "two cores"

# Fractional: 1.5 vCPUs
otala-runc run --cpus 1.5 --command stress --args --cpu --args 4

# Combine CPU + memory limits
otala-runc run --cpus 1.0 --memory-limit 512 --script app.py --language python --copy .
```

The CPU limit is enforced via systemd's `CPUQuotaPerSecUSec` property, which controls the Completely Fair Scheduler (CFS) bandwidth. A value of `0.5` vCPUs translates to 500ms of CPU time per real-world second.

### Memory limits & cleanup

```bash
# Limit to 512 MB
otala-runc run --command stress --args --vm --args 1 --args --vm-bytes --args 400M \
  --memory-limit 512

# Auto-delete container artifacts on exit
otala-runc run --command echo --args done --delete

# Delete is useful in CI/CD pipelines
otala-runc run --script test.js --language javascript --copy . --delete
```

### Preloaded dependencies

```bash
# Pre-install deps on the host, then run air-gapped
cd my-node-app && npm install
otala-runc run --script server.js --language javascript --copy ./my-node-app \
  --preload-deps --net=false

# Preload works with --mount too
otala-runc run --script app.py --language python --mount /home/user/python-app \
  --preload-deps --net=false
```

### Network isolation

```bash
# Fully air-gapped (no network at all)
otala-runc run --command cat --args /etc/hostname --net=false

# Default: network enabled with pasta
otala-runc run --command curl --args https://example.com
```

### Unix socket bind-mount

```bash
# Bind-mount the host Unix socket into the container for IPC
otala-runc run --command sh --unix-socket

# Combine with a script
otala-runc run --script app.py --language python --copy . --unix-socket
```

When `--unix-socket` is enabled, the container gets a bind-mounted socket at `/run/otala-runc.sock` linked to `$XDG_RUNTIME_DIR/otala-runc/otala.sock` on the host. This allows the container to communicate with a host-side daemon or proxy over a Unix socket.

### Proxy client

The proxy client connects to a remote proxy server and tunnels HTTP requests to containers via WebSocket + yamux.

```bash
# Start the proxy client with a server address
otala-runc proxy-client --server ws://proxy.example.com:8080/ws

# Or set the server via environment variable
export OTALA_SERVER=ws://proxy.example.com:8080/ws
otala-runc proxy-client
```

---

## Language runtimes

| Language | Executor | Dependency file | Package manager | Auto-build |
|----------|----------|----------------|-----------------|------------|
| JavaScript | `node` | `package.json` / `yarn.lock` | `npm install` or `yarn install` | `npm run build` / `yarn build` / `pnpm run build` (if `build` script exists) |
| Python | `python3` | `requirements.txt` | `pip` inside virtualenv (`/opt/venv`) | — |
| Go | `go run <script>` | `go.mod` + `go.sum` | `go mod download` | — |
| Bash | `sh` | — | — | — |
| Rust | (planned) | — | — | — |
| Java | (planned) | — | — | — |

### JavaScript / Node.js

Uses `node` as the executor. When `--script` is used, the script file is passed as the first argument, followed by any `--args`. Dependencies are auto-installed if `package.json` is found:
- `yarn.lock` → `yarn install`
- `pnpm-lock.yaml` → used for build step only
- Otherwise → `npm install`

If `package.json` contains a `"build"` script, it runs `pnpm run build`, `yarn build`, or `npm run build` after installing dependencies.

### Python

Uses `python3` as the executor. When `requirements.txt` is found, a virtual environment is created at `/opt/venv` and dependencies are installed via `pip install --no-cache-dir -r requirements.txt`. The virtual environment is added to `PATH` and `VIRTUAL_ENV` is set.

### Go

Uses `go run <script>` as the executor. If `go.mod` is found, `go mod download` runs before execution.

### Bash

Uses `sh` as the executor. No dependency management.

### Rust & Java (planned)

Support for `Cargo.toml` (Rust) and `pom.xml`/`build.gradle` (Java) is planned.

---

## Configuration file

Instead of passing flags on the CLI, you can specify a JSON configuration file with `--config`:

```bash
otala-runc run --config /path/to/config.json
```

Example `config.json`:

```json
{
  "script": "server.mjs",
  "language": "javascript",
  "port": 8080,
  "proxy": true,
  "memory_limit": 256,
  "mount": "/home/user/myapp",
  "install": ["npm", "node"],
  "unix_socket": true,
  "env": ["NODE_ENV=production", "DEBUG"],
  "delete": true
}
```

---

## How it works

### Filesystem isolation

An embedded Alpine minirootfs (~5 MB) is compiled into the binary via `//go:embed`. At runtime, it is extracted once to `~/.local/share/` and used as the **lower layer** of an OverlayFS mount. A per-container temp directory serves as the **upper layer** (writable). After `pivot_root`, the container sees only its overlay — writes go to the temp upper dir and are discarded on cleanup.

### Namespaces

All 7 Linux namespaces are created in a single `clone()` call:

| Namespace | Purpose |
|-----------|---------|
| **User** | Root inside the container, unprivileged user outside. UID/GID are mapped via `newuidmap`/`newgidmap` |
| **Mount** | Private mount tree with overlay, `/proc`, `/sys`, `/dev` |
| **PID** | Processes are isolated; the container sees itself as PID 1 |
| **Network** | Full network stack isolation via pasta |
| **UTS** | Isolated hostname (`HOSTNAME=otala-runc`) |
| **IPC** | System V IPC / POSIX message queues isolated |
| **Cgroup** | Cgroup hierarchy isolated from the host |

### Security

- **Seccomp-BPF** — Default-deny filter that allows only ~300 syscalls needed for normal operation. Blocks `bpf`, `setns`, `kexec`, module loading, `perf_event_open`, and other dangerous operations
- **Capabilities** — 11 capabilities are retained (CHOWN, DAC_OVERRIDE, FOWNER, FSETID, KILL, NET_BIND_SERVICE, SETFCAP, SETGID, SETPCAP, SETUID, SYS_CHROOT). Everything else is dropped from the bounding set
- **Rlimits** — `RLIMIT_NOFILE` (max open file descriptors) and `RLIMIT_NPROC` (max processes/threads) are set to 1,048,576 each. See [Resource limits (rlimits)](#resource-limits-rlimits) for details
- **Signal cleanup** — `Pdeathsig: SIGKILL` ensures the child process dies if the parent dies
- **AppArmor / SELinux** — The install script configures profiles for supported distributions
- **Clean environment** — `os.Clearenv()` wipes the host environment; only explicitly set variables are passed through

### Resource limits (rlimits)

**rlimits** are kernel-enforced per-process quotas that prevent a container from exhausting host resources. Unlike cgroups (which limit a cgroup as a whole), rlimits apply to each process individually and are inherited by child processes.

| Limit | Field | Value | Purpose |
|-------|-------|-------|---------|
| `RLIMIT_NOFILE` | Max open file descriptors | 1,048,576 | Prevents "too many open files" errors in web servers, databases, and network-heavy applications. Covers files, sockets, pipes, and epoll FDs |
| `RLIMIT_NPROC` | Max processes/threads per user | 1,048,576 | Prevents fork-bomb style resource exhaustion. Limits the total number of tasks (processes + threads) the container's user can create |

These are enforced by the kernel via `setrlimit()` — set once at process start, inherited by all children, zero-overhead enforcement at syscall time.

#### Checking rlimits

Inside the container:
```bash
ulimit -n   # RLIMIT_NOFILE (open files)
ulimit -u   # RLIMIT_NPROC (max user processes)
```

From the host, using a running container's PID:
```bash
cat /proc/<PID>/limits | grep -E "Max open files|Max processes"
# or
prlimit --pid <PID>
```

### Networking

Uses **pasta** (from the `passt` project) for user-mode networking. Pasta translates packets between the container's network namespace and the host's network stack entirely in userspace — no `CAP_NET_ADMIN` or veth pairs needed.

| Mode | Behavior |
|------|----------|
| Default (`--net=true`) | Full network isolation. Container can reach external hosts. Host loopback is NOT accessible from inside the container (prevents host service scanning) |
| Port forwarding (`--proxy --port N`) | A host port (10000–60000 range) is allocated and forwarded to container port N via pasta |
| Disabled (`--net=false`) | No network namespace setup. Container has only `lo` (loopback), no external connectivity |

### Port management database

Port allocations are tracked in a SQLite database at `~/.local/share/otala-runc/ports.db`:

- Ports are allocated monotonically from 10000 to 60000
- When a container stops, its port is marked `stopped` and can be recycled
- Stale allocations (process died or PID wrapped around) are detected and reclaimed
- Ports are verified to be physically free on the host before allocation

### Container lifecycle

1. **Parse CLI/config** — Validate all flags, build `RunConfig`
2. **Setup systemd scope** — Create a transient systemd scope with memory and CPU limits via D-Bus
3. **OverlayFS setup** — Mount lower (Alpine rootfs) + upper (per-container tmpdir) + workdir
4. **Child fork** — Fork process into all 7 namespaces simultaneously
5. **UID/GID mapping** — Apply `newuidmap`/`newgidmap` for rootless operation
6. **Re-exec for capabilities** — Child re-execs itself via `/proc/self/exe` to gain full capabilities in its user namespace
7. **JSON pipe messaging** — Parent sends config, network info, and seccomp profile to the child via pipe FDs
8. **Mount + pivot_root** — Mount overlay, `/proc`, `/sys`, `/dev`, pivot into the new root
9. **Network setup** — Start pasta in the container's network namespace; forward ports if `--proxy` is set
10. **Install packages** — Run `apk add --no-cache` for any `--install` packages
11. **Language setup** — Detect dependency files. If `--net=false` and dependencies exist, return an error (network required to download). If `--preload-deps` is set, skip download entirely. Otherwise run `npm install` / `pip install` / `go mod download`, then run build step if applicable
12. **Apply seccomp + capabilities** — Lock down the container
13. **Exec** — Execute the user's command or script via `execve`
14. **Cleanup** — On exit: stop systemd scope, kill process group, remove temp files (if `--delete`)

---

## Architecture

```
otala-runc run --script app.py --language python --copy ./project
        │
        ▼
  ┌─────────────────────────┐
  │   CLI (urfave/cli/v3)   │
  │   Parse flags & config   │
  └──────┬──────────────────┘
         │
         ▼
  ┌─────────────────────────┐
  │  systemd transient scope │
  │  Set memory + CPU limit  │
  │  via D-Bus (session bus) │
  └──────┬──────────────────┘
         │
         ▼
  ┌─────────────────────────┐
  │  OverlayFS setup         │
  │  Alpine rootfs (lower)   │
  │  + copy/mount (upper)    │
  └──────┬──────────────────┘
         │
         ▼
  ┌─────────────────────────┐
  │  User namespace fork     │
  │  (CLONE_NEWUSER|NS..)   │
  │  UID/GID via newuidmap   │
  └──────┬──────────────────┘
         │
         ▼
  ┌─────────────────────────┐
  │  Network namespace       │
  │  pasta (standard/strict) │
  └──────┬──────────────────┘
         │
         ▼
  ┌─────────────────────────┐
  │  Seccomp + capabilities  │
  │  Apply BPF filter        │
  └──────┬──────────────────┘
         │
         ▼
  ┌─────────────────────────┐
  │  Install packages        │
  │  apk add + language      │
  │  dependency manager      │
  └──────┬──────────────────┘
         │
         ▼
  ┌─────────────────────────┐
  │   Execute script/cmd     │
  │   chroot + exec          │
  └─────────────────────────┘
```

### Proxy overlay architecture

When `--proxy` is used, an additional layer connects the container to a remote proxy server:

```
  otala-runc proxy-client
        │
        ▼
  ┌──────────────────────┐
  │  WebSocket connection │
  │  to proxy server      │
  └──────┬───────────────┘
         │
         ▼
  ┌──────────────────────┐
  │  yamux multiplexed   │
  │  TCP tunnels          │
  └──────┬───────────────┘
         │
         ▼
  ┌──────────────────────┐
  │  IPC database watch   │
  │  (SQLite port allocs) │
  └──────┬───────────────┘
         │
         ▼
  ┌──────────────────────┐
  │  Forward HTTP traffic │
  │  to container port    │
  └──────────────────────┘
```

The proxy client watches the IPC database for new container registrations, then tunnels inbound HTTP requests through the WebSocket connection using yamux streams.

---

## Releases

Binaries are published as GitHub Releases. Each release includes:

| File | Architecture |
|------|-------------|
| `otala-runc-linux-amd64` | x86_64 |
| `otala-runc-linux-arm64` | AArch64 / ARM64 |
| `*.sha256` | Checksum for each binary |

## Troubleshooting

| Error | Likely cause | Fix |
|-------|-------------|-----|
| `pasta: command not found` | `passt` package not installed | Run the install script, or manually install `passt` |
| `newuidmap: command not found` | `shadow-utils` not installed | Install `shadow-utils` (or `uidmap` on Arch) |
| `failed to install packages` | APK repository unreachable or package name wrong | Check the package name is valid for Alpine; use `--net=true` to ensure network access |
| `script file does not exist` | Script path is wrong | The script path is relative to the copied/mounted project directory, not an absolute host path |
| `--language is required when using --script` | `--script` used without `--language` | Add `--language <runtime>` (e.g., `--language javascript`) |
| `cannot specify both --script and --command` | Both flags used together | Choose one: either a script file or a direct command |
| `must specify either --copy or --mount` | Neither flag provided | Add `--copy <path>` or `--mount <path>` |
| `--mount entry X: host path must be absolute` | Relative host path in `--mount` | Always use absolute host paths with `--mount` (e.g., `/home/user/project`) |
| `mount path does not exist` | Host path in `--mount` doesn't exist on host | Verify the directory exists on the host before running |
| `unsupported language: X` | Invalid language name | Use one of: `javascript`, `python`, `golang`, `rust`, `java`, `bash` |
| systemd scope errors | systemd not available or D-Bus not running | Ensure systemd is running (check with `pidof systemd`) |
| Permission denied on `/proc/self/exe` | AppArmor or SELinux blocking re-exec | Run the install script to set up proper profiles |
| Port allocation fails (range exhausted) | No ports available in 10000–60000 range | Check for stale port allocations with `lsof -i :10000-60000` |

---

## License

Apache 2.0
