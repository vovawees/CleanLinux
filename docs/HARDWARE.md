# Железо: профили и их статус

Профиль описывает устройство: CPU (`CPU_FLAGS`), GPU (`VIDEO_CARDS`), ядро (`KERNEL_FRAGMENT`,
`KERNEL_CMDLINE`), нужную firmware (`FIRMWARE`) и особенности (`handheld`, `battery`). Профили лежат в
[`profiles/`](../profiles), формат — в [DESIGN.md burn](https://github.com/vovawees/burn/blob/main/docs/DESIGN.md#конфиг-и-профили);
`burn profile detect` выбирает профиль по DMI и device tree, установщик предлагает его сам.

## Как читать таблицу

- **проверено** — работало на этом железе (где проверялось в QEMU, так и написано);
- **описано** — профиль и рецепты содержат всё нужное (драйвер ядра, firmware, Mesa, UCM), на устройстве
  ещё не проверялось;
- **нет** — не сделано; в скобках — чего не хватает.

**Честно о состоянии:** ни один профиль устройства ещё не запускался на настоящем железе. Проверен только
`generic-x86_64` в QEMU (UEFI/OVMF, без KVM): загрузка до `login:`, сервисы dinit, DHCP, zram, `burn doctor`,
установка `cleanlinux-install` на второй диск и загрузка установленной системы (`tests/boot.py`,
`tests/install.py`). Отчёты с устройств — самое полезное, что можно прислать (как — ниже).

## Статус

| Профиль | Арх. | Загрузка | GPU | Звук | Wi-Fi / BT | Сон | Батарея | Ввод |
|---|---|---|---|---|---|---|---|---|
| `generic-x86_64` | x86-64-v2 | проверено в QEMU (UEFI, systemd-boot, btrfs) | описано (amd, intel, nouveau, virgl) | описано (HDA, SOF) | описано | описано (s2idle) | — | описано |
| `generic-x86_64-v3` | x86-64-v3 | описано (та же сборка с `-march=x86-64-v3`) | описано | описано | описано | описано | — | описано |
| `generic-aarch64` | arm64 | описано (UEFI, systemd-boot; в QEMU не проверялось) | описано (freedreno, panfrost, v3d, virgl, …) | описано | описано | — | — | описано |
| `steam-deck` | x86-64 | описано (UEFI) | описано (radeonsi, RADV) | описано (SOF AMD Vangogh, `alsa-ucm-conf`) | описано (firmware по `FIRMWARE`) | описано | описано | описано (`hid-steam`, датчики) |
| `rog-ally` | x86-64 | описано (UEFI) | описано (RDNA 3) | описано (HDA + усилители CS35L41) | описано (MT7922) | описано | описано | описано (`hid-asus`, BMI323) |
| `rog-xbox-ally-x` | x86-64 | описано (UEFI) | описано (RDNA 3.5) | описано | описано | описано | описано | описано |
| `legion-go` | x86-64 | описано (UEFI) | описано (RDNA 3) | описано (CS35L41) | описано | описано | описано | описано (`hid-lenovo-go`, BMI323) |
| `legion-go-s` | x86-64 | описано (UEFI) | описано (RDNA 2) | описано | описано | описано | описано | описано (`hid-lenovo-go-s`) |
| `msi-claw` | x86-64 | описано (UEFI) | описано (iris, ANV; Mesa собирает OpenCL C-ядра через LLVM) | описано (SOF Intel) | описано | описано | описано | описано (`hid-msi`) |
| `msi-claw-ai-plus` | x86-64 | описано (UEFI) | описано (Xe2: iris, ANV, ядро `xe`) | описано (SOF Intel) | описано | описано | описано | описано (`hid-msi`) |
| `asus-x540ya` | x86-64 | описано (UEFI) | описано (amdgpu для GCN 1.1: `amdgpu.cik_support=1`) | описано (HDA) | описано | описано | описано | — |
| `rk3566-handheld` | arm64 | нет (U-Boot с EFI и его рецепт) | описано (panfrost) | описано | описано | — | описано | описано (device tree в ядре: Anbernic, PowKiddy) |
| `raspberry-pi-5` | arm64 | нет (firmware загрузки Pi или UEFI для Pi 5) | описано (v3d, vc4) | описано | описано | — | — | — |
| `retroid-pocket-5` | arm64 | нет (ABL + `boot.img`; device tree не в основном ядре) | описано (freedreno, turnip) | нет (UCM Snapdragon) | описано | — | описано | нет |
| `ayn-odin2` | arm64 | нет (ABL + `boot.img`; device tree не в основном ядре) | описано (freedreno, turnip) | нет (UCM Snapdragon) | описано | — | описано | нет |
| `mangmi-air-x` | arm64 | нет (ABL + `boot.img`; device tree не в основном ядре) | описано (freedreno) | нет (UCM Snapdragon) | описано | — | описано | нет |

«Описано» для GPU значит: драйвер ядра (`VIDEO_CARDS` → конфиг ядра) и драйверы Mesa (`video_cards_*`) есть в
рецептах; сборка Mesa для каждого набора карт на этой машине ещё не проверялась. Для Snapdragon-устройств
нужны device tree и драйверы вне основного ядра — это следующая большая работа по arm64.

## Как проверить устройство

```sh
burn profile detect                       # какой профиль подходит этому устройству
bootstrap/bootstrap.sh --profile steam-deck disk     # образ под профиль; записать на USB: dd if=… of=/dev/sdX
```

На устройстве, после загрузки:

| Что | Как проверить |
|---|---|
| загрузка | дошло до `login:`; `dmesg --level=err,warn` |
| GPU | `ls /dev/dri`; `cat /sys/kernel/debug/dri/*/name` (от root); в сборке — `eglinfo`, `vulkaninfo --summary` |
| звук | `aplay -l`; `alsaucm listcards`; `speaker-test -c 2` |
| Wi-Fi / BT | `iwctl station list`; `bluetoothctl list` |
| сон | `cat /sys/power/mem_sleep`; `echo freeze > /sys/power/state`, затем проснуться кнопкой |
| батарея | `cat /sys/class/power_supply/BAT*/{status,capacity}` |
| ввод | `cat /proc/bus/input/devices`; `libinput list-devices`; `ls /sys/bus/iio/devices` |
| питание | `cat /sys/firmware/acpi/platform_profile`; `cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference` |

Результат — issue в [CleanLinux](https://github.com/vovawees/CleanLinux/issues) с профилем, выводом
`burn profile detect` и `dmesg`: таблица выше обновляется по таким отчётам.
