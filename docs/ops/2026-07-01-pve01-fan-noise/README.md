# pve01 fan noise investigation

## Incident

On 2026-07-01, the fan on `pve01` remained unusually loud well after startup.
Linux power-saving settings lowered CPU/GPU temperatures, and the fan became
noticeably quieter after disconnecting the HDMI monitor and USB wireless
keyboard dongle.

HDMI was connected during the investigation for BIOS access; it was not connected
when the noise first appeared. The USB dongle was present from the start.

## Environment

- Host: `pve01`, Proxmox VE
- Hardware: HC Technology HCAR5000-MI, AMD Ryzen 7 5800U with Radeon Graphics
- BIOS: American Megatrends International, LLC. `0.22`, released 2023-06-21
- Kernel: `6.17.9-1-pve`; CPU driver: `amd-pstate-epp`

## Findings

- CPU idle was around 95–98% and GPU utilization was 0%, despite elevated temperatures.
- The CPU governor, EPP, and GPU DPM state were set to `performance` after boot.
- EPP initially offered only `performance`. Changing the governor to `powersave` restored the other EPP options, so the restricted selection alone did not establish a BIOS problem.
- CPU idle states through C3 were visible.
- The preceding shutdown was a normal, manual response to the noise.
- Fan RPM/PWM sensors were not exposed to Linux. Changes in fan activity were assessed by ear, not measured directly.

A similar incident after a planned power outage on 2026-05-14 also showed a
`performance` governor/EPP and a CPU temperature around 69°C despite high CPU
idle. A BIOS settings reset or weakening CMOS battery was suspected then but
not confirmed.

## Mitigation and results

The following settings were applied temporarily, then made persistent:

| Setting | Before | Applied |
| --- | --- | --- |
| CPU governor | `performance` | `powersave` |
| CPU EPP | `performance` | `balance_power` |
| amdgpu `power_dpm_force_performance_level` | `auto` | `auto` |
| amdgpu `power_dpm_state` | `performance` | `balanced` |

Temperature readings during the investigation:

| Stage | CPU | GPU |
| --- | --- | --- |
| Before changing the power settings | 71.6°C | 73.0°C |
| 60 seconds after changing the settings | 64.9°C | 63.0°C |
| Over roughly five minutes with HDMI connected | 66–67°C | 64–66°C |
| After disconnecting HDMI and the USB dongle | 64.5–64.8°C | 61–62°C |
| Later reading immediately after Ansible deployment | 68.5°C | 68.0°C |

The fan became audibly quieter after the peripherals were disconnected.
These spot readings do not establish sustained temperature improvement.

## Assessment

The temperature drop after changing the power settings supports CPU/GPU power
management as a significant contributor. Why the settings had returned to
`performance` after boot was not established.

HDMI may have contributed to the noise that persisted during diagnosis, but it
cannot explain the initial onset because it was connected later. HDMI and the
USB dongle were removed together, so their individual effects were not isolated.

A BIOS reset and the host's exact fan-curve thresholds were not confirmed.
No BIOS or EC update was performed.

## Persistent fix

The [Ansible role](../../../ansible/roles/proxmox_power_profile/) and
[host configuration](../../../ansible/host_vars/pve01.yaml) manage the applied
settings. The `pve-power-profile.service` oneshot service runs before
`pve-guests.service`. A power-profile failure is reported by systemd without
blocking VM startup, since noise reduction should not prevent VMs from running.

Deployment confirmed the service was enabled and active, the CPU settings were
applied to all 16 logical CPUs, and the GPU settings matched the table above.
A second playbook run reported `changed=0`.

## Outstanding checks

- At the next maintenance reboot, verify the applied power settings and that `pve-power-profile.service` is enabled and `active (exited)`. Persistence across reboot had not yet been verified.
- From a quiet baseline, connect only the USB keyboard dongle and monitor temperatures and load for about five minutes to isolate its effect.
- If the issue recurs, check the OS power profile and look for BIOS clock drift or other signs of a CMOS battery problem.
