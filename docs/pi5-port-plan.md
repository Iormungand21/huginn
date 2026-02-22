# Huginn Pi 5 Port Plan

This document is the execution plan to port `huginn` from the current RISC-V-focused baseline (`muninn` codebase) to Raspberry Pi 5.

## 1. Scope and Goals

- Base project: `muninn` code imported into `huginn`.
- Target device: Raspberry Pi 5 (aarch64, Raspberry Pi OS).
- Goal: reliable native runtime on Pi 5 with working GPIO/I2C/SPI/serial tooling and stable sandbox behavior.

## 2. Current Known Gaps in Codebase

From current source review:

- `src/peripherals.zig` Pi GPIO backend uses sysfs (`/sys/class/gpio/...`), which is deprecated and often unavailable on modern Pi kernels.
- `src/peripherals.zig` serial allowlist is USB-centric (`/dev/ttyACM*`, `/dev/ttyUSB*`) and may reject onboard UART paths (`/dev/ttyAMA0`, `/dev/serial0`).
- Linux hardware tools for I2C/SPI already exist and should work once OS/device permissions are configured.
- Sandbox auto-detect exists (`landlock -> firejail -> bubblewrap -> docker -> noop`) and can remain native-first.

## 3. Phase A: SD Card and OS Bring-up

### 3.1 Confirm SD target device on host (required every flash)

Run before and after inserting card to avoid selecting the wrong disk:

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,TRAN
```

Current observed removable candidate was `sdb` (~29.1G), but always re-verify each time.

### 3.2 Flash Raspberry Pi OS

Use Raspberry Pi Imager:

- OS: Raspberry Pi OS Lite (64-bit, Bookworm)
- Storage: verified SD card
- Advanced options:
  - set hostname: `huginn-pi5`
  - enable SSH
  - set username/password
  - configure Wi-Fi if needed
  - set locale/timezone

### 3.3 First boot OS setup (on Pi)

```bash
sudo apt update
sudo apt full-upgrade -y
sudo reboot
```

After reboot:

```bash
sudo raspi-config
```

Enable interfaces:

- I2C
- SPI
- Serial port (hardware UART)

Then:

```bash
sudo adduser $USER gpio
sudo adduser $USER i2c
sudo adduser $USER spi
sudo adduser $USER dialout
sudo reboot
```

### 3.4 Install base build/runtime dependencies

```bash
sudo apt install -y git curl ca-certificates pkg-config build-essential
```

Optional tooling for diagnostics:

```bash
sudo apt install -y i2c-tools gpiod libgpiod-dev
```

## 4. Phase B: Build Huginn on Pi 5

### 4.1 Clone and build

```bash
git clone git@github.com:Iormungand21/huginn.git
cd huginn
zig build -Doptimize=ReleaseSmall
```

If `zig` is missing, install your preferred version manager/package source and use a pinned Zig version for repeatability.

### 4.2 Sanity checks

```bash
zig build test
./zig-out/bin/nullclaw --help
./zig-out/bin/nullclaw doctor
./zig-out/bin/nullclaw status
```

## 5. Phase C: Code Port Tasks (Pi 5 Compatibility)

### 5.1 Replace sysfs GPIO backend

Files:

- `src/peripherals.zig`

Tasks:

- Replace `RpiGpioPeripheral` sysfs read/write implementation with `libgpiod` (`/dev/gpiochip*`) implementation.
- Keep existing peripheral interface unchanged so tool APIs stay stable.
- Support pin direction and read/write with clear errors for unavailable lines/chips.
- Add tests for parser/validation logic where pure unit testing is possible.

Definition of done:

- GPIO read/write works on Pi 5 without `/sys/class/gpio`.

### 5.2 Expand serial device allowlist for Pi UART

Files:

- `src/peripherals.zig`

Tasks:

- Extend allowed serial prefixes to include common Pi UART paths:
  - `/dev/ttyAMA`
  - `/dev/ttyS`
  - `/dev/serial`
- Keep allowlist approach (do not relax to arbitrary path access).

Definition of done:

- Serial mode can open onboard UART devices when configured.

### 5.3 Add Pi-focused runtime smoke command path

Files (candidate):

- `src/doctor.zig`
- `src/tools/hardware_info.zig`

Tasks:

- Ensure `doctor` reports clear hardware/sandbox status relevant to Pi.
- Add checks for GPIO/I2C/SPI availability and permission guidance.

Definition of done:

- Single command gives actionable Pi readiness output.

### 5.4 Verify sandbox behavior on Pi kernel/userspace

Files:

- `src/security/detect.zig`
- `src/security/*`

Tasks:

- Validate auto-detect picks an available backend on Pi.
- Confirm behavior when preferred backend is unavailable (graceful fallback).

Definition of done:

- Tool execution works with deterministic, visible sandbox selection.

## 6. Phase D: Hardware Validation Matrix on Pi

Run after code changes:

### 6.1 Core runtime

```bash
zig build -Doptimize=ReleaseSmall
zig build test
./zig-out/bin/nullclaw doctor
./zig-out/bin/nullclaw status
```

### 6.2 GPIO

- Wire test LED or known-safe test pin.
- Validate read/write path via whichever command flow currently exposes GPIO tools.
- Confirm expected transitions (LOW/HIGH).

### 6.3 I2C

- Connect known I2C device.
- Detect bus and scan addresses.
- Perform a register read/write test where safe.

### 6.4 SPI

- Connect known SPI peripheral.
- Enumerate and run a minimal transfer/read test.

### 6.5 Serial

- Validate opening configured UART/USB serial path.
- Perform read/write smoke exchange.

## 7. Milestones and Deliverables

### M1: Platform Ready

- Pi booted, updated, interfaces enabled, permissions set.

### M2: Native Build Ready

- `zig build` and `zig build test` pass on Pi 5.

### M3: Peripheral Port Complete

- GPIO backend migrated to `libgpiod`.
- Serial allowlist includes Pi UART paths.

### M4: Acceptance

- Full validation matrix passes on target hardware.
- Issues tracked and documented.

## 8. Risk Register

- Wrong flash target device on host.
  - Mitigation: mandatory `lsblk` before every write.
- Kernel/userspace mismatch for GPIO access.
  - Mitigation: standardize on `libgpiod` path and package dependencies.
- Permission/group issues blocking peripheral devices.
  - Mitigation: enforce group membership + reboot + `doctor` checks.
- Sandbox backend differences across Pi OS versions.
  - Mitigation: explicit backend reporting and fallback testing.

## 9. Immediate Next Actions

1. Flash SD and complete Phase A on the Pi.
2. Run Phase B build + sanity checks and capture first-failure logs.
3. Implement Phase C.1 (GPIO `libgpiod` migration) first, then C.2.
4. Execute Phase D matrix and record pass/fail per subsystem.
