# Железо: профили и их статус

Профиль описывает устройство: CPU (`CPU_FLAGS`), GPU (`VIDEO_CARDS`), ядро (`KERNEL_FRAGMENT`,
`KERNEL_CMDLINE`), загрузчик и device tree (`BOOTLOADER`, `DEVICE_TREE`), нужную firmware (`FIRMWARE`) и
особенности (`handheld`, `battery`). Профили лежат в
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
| `rk3566-handheld` | arm64 | описано (U-Boot устройства + `extlinux.conf`, device tree выбирает U-Boot; рецепта U-Boot нет) | описано (panfrost) | описано | описано | — | описано | описано (device tree в ядре: Anbernic, PowKiddy) |
| `raspberry-pi-5` | arm64 | описано (прошивка Pi 5 из EEPROM: `config.txt`, `bcm2712-rpi-5-b.dtb`) | описано (v3d, vc4) | описано | описано | — | — | — |
| `retroid-pocket-5` | arm64 | описано (ABL + Android boot image, прошивка в `boot`); device tree не в основном ядре — `devicetree=` в `/etc/cleanlinux/boot.d` | описано (freedreno, turnip) | нет (UCM Snapdragon) | описано | — | описано | нет |
| `ayn-odin2` | arm64 | описано (ABL + Android boot image, прошивка в `boot`); device tree не в основном ядре — `devicetree=` в `/etc/cleanlinux/boot.d` | описано (freedreno, turnip) | нет (UCM Snapdragon) | описано | — | описано | нет |
| `mangmi-air-x` | arm64 | нет (ABL + `boot.img`; device tree не в основном ядре) | описано (freedreno) | нет (UCM Snapdragon) | описано | — | описано | нет |

«Описано» для GPU значит: драйвер ядра (`VIDEO_CARDS` → конфиг ядра) и драйверы Mesa (`video_cards_*`) есть в
рецептах; сборка Mesa для каждого набора карт на этой машине ещё не проверялась. Для Snapdragon-устройств
нужны device tree и драйверы вне основного ядра — это следующая большая работа по arm64.

## Каталог устройства

У профиля устройства может быть свой каталог `profiles/devices/<имя>/` (на него ссылается профиль через
`$PROFILE_DIR/<имя>/…`):

| Файл | Что это | Кто читает |
|---|---|---|
| `kernel.config` | драйверы устройства — фрагмент конфига ядра (`KERNEL_FRAGMENT`): контроллер, звук, Wi-Fi/BT, датчики, накопитель корня. Почти всё это есть и в общем `x86.config`/`arm64.config` рецепта `linux` (generic-образ работает на устройстве), здесь — собственный список устройства, который проверяется | рецепт `linux`; `tests/kernel-config.sh` |
| `boards` | device tree плат (arm64), по строке: `rockchip/плата.dts` — у каждого включённого узла должен быть драйвер; `ref qcom/плата.dts` — эталонная плата SoC, когда дерева устройства нет в основном ядре (считается только цепочка накопителя); `root mmc,pci,usb` — где может лежать корень; `ignore vendor,блок` — узел, которому свой драйвер не нужен | `tests/kernel-config.sh` → `tools/dt-kconfig.py` |
| `quirks/` | каталог `QUIRKS`, устроенный как `/usr/lib`: `udev/rules.d`, `udev/hwdb.d`, `modprobe.d`, `sysctl.d`, `cleanlinux/initramfs.d`, `cleanlinux/boot.d`; `libinput/` уходит в `/usr/share/libinput` | рецепт `hardware` |

`tests/kernel-config.sh КОД_ЯДРА|linux-X.tar.xz [ПРОФИЛЬ…]` (или `tools/check.sh --kernel …`; в `--full` —
само) прогоняет `do_configure` рецепта `linux` для каждого профиля и проверяет, что каждый параметр
фрагмента дошёл до итогового `.config` (зависимости Kconfig молча выключают то, чего не хватает), а для
плат из `boards` — что `tools/dt-kconfig.py` нашёл драйвер каждого узла и что вся цепочка накопителя корня
(контроллер, его клоки, сбросы, питание, PHY, пины, родительские шины) собрана в ядро (`=y`): без initramfs
корень монтируется до загрузки модулей. Так найдено и исправлено: UFS Snapdragon 8 Gen 2/865
(`SCSI_UFS_QCOM`, `PHY_QCOM_QMP_UFS`), PCIe и RP1 Raspberry Pi 5 (NVMe, USB), `SPI_AMD` + `SPI_MEM` у
усилителей Steam Deck LCD, `SERIAL_MULTI_INSTANTIATE` у усилителей CS35L41 ROG Ally и Legion Go.

У RK3566 одно ядро на много плат: драйверы экранов собраны модулями и перечислены в
`quirks/cleanlinux/initramfs.d/20-display.conf` как `optional=` (cleanlinux-boot ≥ 0.3.1) — с
зашифрованным корнем драйвер экрана нужной платы оказывается в initramfs и запрос пароля виден.

Что уже есть в основных проектах и не дублируется в `quirks/`:

- поворот экрана: `drm_panel_orientation_quirks` ядра знает Steam Deck (LCD и OLED) и Legion Go; у
  ROG Ally, Legion Go S и MSI Claw панель горизонтальная; у arm64-плат поворот задан в device tree;
- hwdb eudev: матрица акселерометра ROG Ally X и Legion Go, датчики Steam Deck, клавиши Legion Go S и
  MSI Claw;
- геймпады: `hid-steam`, `hid-asus`, `hid-lenovo-go`, `hid-lenovo-go-s`, `hid-msi`, `xpad` (их ID в ядре).

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
