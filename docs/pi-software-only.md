# Software-Only Pi Profile

Huginn defaults to a software-only profile suitable for Raspberry Pi use
without hardware peripherals attached. This document describes the
profile defaults and how to switch between modes.

## Doctor Profile

The `doctor.profile` config key controls which diagnostic categories are
evaluated:

| Profile         | Hardware checks | Use case                          |
|-----------------|-----------------|-----------------------------------|
| `software_only` | Skipped         | Pi running LLM agent, no GPIO/I2C |
| `full`          | Run             | Pi with boards/sensors attached    |

The default is `software_only`. Set `"full"` when you connect hardware.

### Example config.json

```json
{
  "doctor": {
    "profile": "software_only"
  }
}
```

## Recommended Defaults for Software-Only Pi

These are the shipped defaults — no config changes required for a
software-only setup:

| Section       | Key               | Default          | Notes                       |
|---------------|-------------------|------------------|-----------------------------|
| hardware      | enabled           | `false`          | No GPIO/serial probing      |
| hardware      | transport         | `"none"`         | No hardware transport       |
| peripherals   | enabled           | `false`          | No board enumeration        |
| doctor        | profile           | `"software_only"`| Suppresses hardware warnings|
| security      | sandbox.backend   | `"auto"`         | Picks landlock on Pi OS     |
| autonomy      | level             | `"supervised"`   | Safe default                |
| gateway       | host              | `"127.0.0.1"`   | Loopback only               |

## Switching to Full Hardware Mode

To enable hardware diagnostics and peripheral support:

```json
{
  "doctor": { "profile": "full" },
  "hardware": { "enabled": true, "transport": "native" },
  "peripherals": { "enabled": true }
}
```

Then run `nullclaw doctor` to verify GPIO, I2C, SPI, and serial
readiness.
