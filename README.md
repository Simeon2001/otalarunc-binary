# otala-runc

**Pre-built binaries for the otala-runc container runtime.**

These are statically built releases. No Go toolchain or source code needed.

---

## Quick install

```bash
curl -fsSL https://raw.githubusercontent.com/Simeon2001/otalarunc-binary/main/install.sh | sudo bash
```

This installs `otala-runc` to `/usr/local/bin` along with required system dependencies.

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

- Linux with **systemd**
- **pasta** (from `passt` package) — user-mode networking
- **shadow-utils** — `newuidmap`, `newgidmap`, `getsubids`
- **libseccomp** — seccomp-BPF syscall filtering

## Usage

```bash
otala-runc run --command "echo hello from inside a container"
otala-runc run --script main.py --language python --copy ./project
otala-runc run --command "npm test" --memory-limit 512 --mount ./app
```

See the [main project README](https://github.com/Simeon2001/otalarunc) for full usage.

## Releases

Binaries are published as GitHub Releases. Each release includes:

| File | Architecture |
|------|-------------|
| `otala-runc-linux-amd64` | x86_64 |
| `otala-runc-linux-arm64` | AArch64 / ARM64 |
| `*.sha256` | Checksum for each binary |

## License

Apache 2.0
