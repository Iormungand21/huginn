# Handoff: Huginn Bring-up on Raspberry Pi 5 (for Claude Code Agent)

## Goal (Current Priority)

Bring `huginn` up on a Raspberry Pi 5 as a **software-only** interactive LLM bot first.

Hardware features (GPIO/I2C/SPI/serial) are **de-prioritized** for now and should not block bring-up.

## Context

- Repo: `huginn`
- Local path (dev machine): `/home/ryan/projects/huginn`
- `huginn` was initialized from `muninn` history/codebase.
- Target runtime machine: Raspberry Pi 5 (fresh Raspberry Pi OS install, user is already SSH'd in).

## Important Direction Change

Earlier work focused on Pi hardware support because this codebase includes hardware tooling. The user explicitly clarified that **hardware features are not currently needed**.

### What to optimize for now

- Build success on Pi (aarch64)
- CLI agent/gateway/daemon functionality
- Config/provider setup
- Basic runtime diagnostics

### What not to block on

- GPIO bring-up
- I2C/SPI device validation
- Serial/UART hardware integration

## Changes Already Made in This Branch (Uncommitted)

### 1) `src/peripherals.zig`

Pi compatibility groundwork was added:

- Raspberry Pi GPIO backend now prefers `gpiod` CLI (`gpioget` / `gpioset`) and falls back to legacy sysfs.
- Serial path allowlist expanded to include Pi-style UART paths:
  - `/dev/ttyAMA*`
  - `/dev/ttyS*`
  - `/dev/serial*`
- Added parsing tests for `gpioget` output.

This is safe to keep even if hardware is currently unused.

### 2) `src/doctor.zig`

Doctor diagnostics were enhanced:

- Sandbox diagnostics now report configured/available/selected backend.
- Added Linux/Pi hardware readiness checks (GPIO/I2C/SPI/groups/serial path).

This is useful but should be treated as **informational** only for now.

## Current Git State (Expected)

Uncommitted changes exist.

- Modified: `src/doctor.zig`
- Modified: `src/peripherals.zig`
- New docs dir/files under `docs/`

Do **not** discard these changes unless the user explicitly asks.

## Limitation from Previous Agent Session

The previous agent could not run Zig tests in the development environment because `zig` was not installed there.

### What needs verification on the Pi

- `zig build`
- `zig build test`
- `./zig-out/bin/nullclaw doctor`
- `./zig-out/bin/nullclaw status`
- `./zig-out/bin/nullclaw agent -m "hello"`

## Immediate Tasks for Claude Code Agent on Pi (Software-Only)

### Phase 1: OS + Tooling Baseline (skip hardware extras unless needed)

Run/verify:

```bash
sudo apt update
sudo apt full-upgrade -y
sudo apt install -y git curl ca-certificates pkg-config build-essential
```

Install Zig (pinned version preferred).

### Phase 2: Clone / Build

```bash
git clone git@github.com:Iormungand21/huginn.git
cd huginn
zig build -Doptimize=ReleaseSmall
```

Then:

```bash
zig build test
```

If tests fail, prioritize:

1. Build breakages on aarch64/Linux
2. Missing runtime/tool dependencies
3. Any regressions introduced by `src/peripherals.zig` / `src/doctor.zig` edits

## Phase 3: Runtime Bring-up (No hardware dependency)

### Basic smoke tests

```bash
./zig-out/bin/nullclaw --help
./zig-out/bin/nullclaw status
./zig-out/bin/nullclaw doctor
```

### Configure provider + model

Use onboard flow (preferred):

```bash
./zig-out/bin/nullclaw onboard --interactive
```

Or direct flags (if supported in this build):

```bash
./zig-out/bin/nullclaw onboard --api-key <KEY> --provider openrouter
```

### First agent message

```bash
./zig-out/bin/nullclaw agent -m "hello"
```

## Phase 4: Optional Service/Gateway Bring-up

After CLI agent works:

```bash
./zig-out/bin/nullclaw gateway
# or
./zig-out/bin/nullclaw daemon
```

Validate:

- local bind behavior (prefer localhost by default)
- logs / status output
- restart reliability (if using service mode)

## Prioritized Debugging Guidance

If something fails, use this order:

1. **Compilation/toolchain** (Zig version mismatch, missing deps)
2. **Config/provider** (API key/model/provider config)
3. **Runtime permissions** (file paths, home dir, workspace)
4. **Networking** (DNS/firewall/API endpoint access)
5. **Hardware checks** (ignore unless they break software-only paths)

## Notes on Doctor Output

`doctor` now includes hardware readiness warnings on Linux/Pi. These warnings are expected if hardware interfaces/tools are not configured and should not block software-only acceptance.

Treat the following as non-blocking for now:

- missing `/dev/i2c-*`
- missing `/dev/spidev*`
- missing `gpioget`/`gpioset`
- missing `gpio/i2c/spi/dialout` groups

## Acceptance Criteria (Current Sprint)

Software-only bring-up is complete when all are true:

- `zig build` succeeds on Pi 5
- `zig build test` completes (or failures are identified and documented)
- `nullclaw doctor` runs
- `nullclaw status` runs
- `nullclaw agent -m "hello"` returns a valid response using configured provider

## Recommended Deliverables Back to User

1. Exact commands run on Pi
2. Zig version installed
3. Build/test results (pass/fail + errors)
4. Any code patches made (with file list)
5. Whether `agent`, `gateway`, and/or `daemon` were successfully started

