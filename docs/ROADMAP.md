# Roadmap

**CleanLinux — это база, как Arch Linux.** Главное здесь — сама система: она загружается, обновляется
(rolling release+++), полностью использует железо и собрана под конкретный процессор и видеокарту.
Проект даёт три вещи:

1. **Систему** — минимальную базу: загрузка, init, вход, устройства, сеть, файловые системы, `burn`.
2. **Драйверы** — ядро, firmware, GPU, звук, ввод, питание и датчики для каждого поддерживаемого устройства.
3. **Оптимизацию под железо** — профили: флаги CPU, конфиг ядра, параметры загрузки, quirks устройства.

Всё остальное идёт **поверх**: KDE Plasma, labwc, sway и любые другие DE и WM, приложения, Steam и игровые
библиотеки — это *сборки* (spins), отдельные репозитории со своими рецептами и настройками. База ничего не
выбирает за пользователя и не тянет вкусовщину, но даёт всё, чтобы любая сборка одинаково хорошо работала
на любом поддерживаемом железе.

Проект в стадии pre-alpha. Этапы идут в порядке работы, пункты внутри этапа — по зависимостям.
Открытые пункты — issues с меткой [`roadmap`](https://github.com/vovawees/CleanLinux/issues?q=is%3Aissue+label%3Aroadmap) и общая доска [CleanLinux roadmap](https://github.com/users/vovawees/projects/1) по всем репозиториям.

## Слои

| Слой | Что это | Где живёт |
|---|---|---|
| **core** | загрузка, dinit, пользователи и вход, устройства, сеть, файловые системы, `burn`, тулчейн для самосборки | `base`, `base-devel` |
| **hardware** | ядро под профиль, firmware, Mesa/Vulkan по `VIDEO_CARDS`, звук, ввод, питание, датчики, quirks | профили + рецепты |
| **platform** | нейтральный фундамент для сборок: Wayland- и X11-библиотеки, libinput, seatd/elogind, D-Bus, PipeWire, шрифтовый стек — один на всех, чтобы каждая сборка не тащила свой | рецепты; в `base` не входит |
| **сборки** | DE, WM, тулкиты, приложения, Steam, эмуляторы, темы, оформление | отдельные репозитории поверх базы |

Проверка для любого пакета и любой настройки: *нужно ли это, чтобы система загрузилась, обновлялась и полностью
использовала железо?* Да — это база. Если это выбор вкуса (какой DE, какой плеер, ставить ли Steam) — это сборка.
Подробно — в [SCOPE.md](SCOPE.md).

## Инструменты: C и отдельные репозитории

Всё, что работает на устройстве, пишется на C и живёт в своём репозитории — со своими тестами и релизами.
Shell остаётся только там, где он и есть правильный инструмент: команды сборки внутри рецептов и первая стадия
bootstrap на чужом хосте.

| Репозиторий | Что это | Статус |
|---|---|---|
| [burn](https://github.com/vovawees/burn) | пакетный менеджер на C (C17, только libc + libzstd): рецепты, сборка, установка, rolling+++ | используется: bootstrap собирает его из релиза, пакет `burn` в `base`; bash-прототип — тег `burn-prototype` |
| [cleanlinux-boot](https://github.com/vovawees/cleanlinux-boot) | сервисы dinit для загрузки и помощник на C: ранние ФС, udev, модули через libkmod, getty, выключение, ядра в ESP (systemd-boot), initramfs, zram, питание | используется: пакет `cleanlinux-boot` в `base` |
| [cleanlinux-install](https://github.com/vovawees/cleanlinux-install) | установщик на C: GPT + ESP + btrfs, `burn clone`, fstab по PARTUUID, systemd-boot, пользователь | используется: пакет `cleanlinux-install`, `tests/install.py` |
| [cleanlinux-spin-template](https://github.com/vovawees/cleanlinux-spin-template), [cleanlinux-spin-labwc](https://github.com/vovawees/cleanlinux-spin-labwc) | шаблон сборки и первая сборка (labwc) | этап 5 |
| CleanLinux | документация, профили железа, bootstrap, образы, тесты (`tools/check.sh`) | — |
| [CleanLinux-Recipes](https://github.com/vovawees/CleanLinux-Recipes) | рецепты базы: только текст, без бинарников | — |

## Сделано

- [x] `burn` (bash-прототип): рецепты, features, профили, сборка в кеш, установка в любой корень, база пакетов, конфликты, `backup`
- [x] rolling release+++: `plan`, сборка до установки, хуки (btrfs-снимок), preserved libs, ABI-пересборка, `hold`, `rollback`, `history`, `doctor`
- [x] burn 0.3: параллельная предзагрузка с проверкой, воспроизводимые пакеты, `CCACHE=1`, `LINKER=mold|lld`, `options=(o3)`
- [x] канал `edge`: ежедневный `tools/updates.sh` (upstream GNU, kernel.org, GitHub) с автоматической проверкой ссылок и sha256
- [x] профили железа: `native`, `generic-x86_64(-v3)`, `generic-aarch64` и устройства — Steam Deck, ROG Ally, ROG Xbox Ally X, Legion Go / Go S, MSI Claw (Meteor Lake, Lunar Lake), Retroid Pocket 5, AYN Odin 2, Mangmi Air X, Raspberry Pi 5, RK3566, ASUS X540YA
- [x] рецепты базовой системы: GCC 16, glibc 2.44, binutils 2.47, Linux 7.3, bash, coreutils, util-linux, dinit, …
- [x] cross-first bootstrap для x86_64 и aarch64: тулчейн → 21 пакет `base` → архив rootfs (x86_64 проверен в chroot, aarch64 — под qemu-user)
- [x] ядро: zswap/zram на zstd, MGLRU, PSI, BFQ, BBR + fq, `PREEMPT_DYNAMIC`, amd-pstate EPP, платформенные драйверы и встроенные контроллеры handheld (ROG Ally, Legion Go, MSI Claw, AYANEO, OneXPlayer), sched_ext как feature
- [x] тесты: smoke на настоящих рецептах, полный цикл rolling+++, воспроизводимость пакетов
- [x] загрузочный образ: `bootstrap.sh disk` (GPT, ESP с systemd-boot, btrfs `@` `@home` `@snapshots`) загружается в QEMU до входа и ставится на диск (`tests/boot.py`, `tests/install.py`, x86_64)
- [x] [cleanlinux-boot](https://github.com/vovawees/cleanlinux-boot) и [cleanlinux-install](https://github.com/vovawees/cleanlinux-install) на C; вход (Linux-PAM, shadow), eudev, сеть (dhcpcd, iwd), e2fsprogs, btrfs-progs, dosfstools
- [x] самосборка: `bootstrap native` — система собирает `base-devel` своим компилятором и своим burn
- [x] железо: FIRMWARE и KERNEL_CMDLINE в профилях, пакет `hardware` (quirks, модули, I/O-планировщик), Mesa/Vulkan по `VIDEO_CARDS`, ALSA и SOF, Bluetooth, NVIDIA (`nonfree`), zram, питание и подсветка
- [x] платформа для сборок: Wayland и Xwayland, libinput, seatd/elogind, D-Bus, polkit, PipeWire, шрифтовый стек, xdg-desktop-portal, turnstile (`dinit --user`), iio-sensor-proxy (датчики, поворот экрана)
- [x] сборки: `burn spin`, `bootstrap.sh disk --spin`, [SPINS.md](SPINS.md), [шаблон](https://github.com/vovawees/cleanlinux-spin-template) и [сборка labwc](https://github.com/vovawees/cleanlinux-spin-labwc)
- [x] локальные проверки вместо хостингового CI: `tools/check.sh` в каждом репозитории, `tools/edge.sh` для канала `edge`

## Этап 0. Границы проекта

- [x] [`docs/SCOPE.md`](SCOPE.md): слои, правило «база или сверху», что база обещает сборкам
- [x] README обоих репозиториев и ARCHITECTURE: CleanLinux — база для сборок, а не готовый дистрибутив «под игры»
- [x] профили описывают только железо: без feature `gaming`; features программного стека (`wayland`, `x11`, `pipewire`, …) выбирают сборки, а не профили
- [x] умолчания без вкусовщины: в базе остаются общие и аппаратные настройки (zswap, BBR, `vm.max_map_count` — как в Arch и Fedora), игровые твики (`kernel.split_lock_mitigate=0` и т.п.) уходят в сборки
- [x] категории рецептов по слоям (`core` `kernel` `firmware` `drivers` `platform` `devel` `meta`) и их проверка в lint

## Этап 1. Загружаемая база

Цель: образ, который загружается на обычном ПК и в QEMU до входа в консоль и ставится на диск одной командой.
Сначала x86_64 + UEFI, затем aarch64.

- [x] kmod (`depmod`, `modprobe`) и триггер burn: `modules.dep` пересобирается при каждой установке ядра или модулей
- [x] сервисы dinit для загрузки (`cleanlinux-boot`): декларативные сервисы и помощник на C вместо shell-скриптов — `/proc` `/sys` `/dev` `/run`, fsck и `mount -a`, hostname, sysctl, загрузка модулей через libkmod, seed случайных чисел, часы, getty на tty и на последовательном порту, корректное выключение
- [x] вход в систему: Linux-PAM, shadow (`passwd`, `useradd`), `login` и `su` из util-linux
- [x] устройства: eudev (udev без systemd: правила, hwdb, `libudev` — без него не работают libinput, Mesa и любой DE)
- [x] ядро: драйверы накопителей и файловые системы корня встроены (NVMe, AHCI, virtio, btrfs, vfat) — загрузка без initramfs по `root=PARTUUID=`; маленький генератор initramfs для случаев, где без него нельзя (LUKS, модульный storage на arm64)
- [x] файловые системы: e2fsprogs, btrfs-progs, dosfstools
- [x] загрузчик: systemd-boot на UEFI (собирается отдельно, без systemd); хук burn кладёт ядро в ESP и пишет запись загрузчика при установке и обновлении ядра
- [x] образ диска `bootstrap.sh disk`: GPT, ESP + btrfs (подтома `@`, `@home`, `@snapshots`, сжатие zstd), собирается без root-прав
- [ ] тест загрузки в QEMU (`tools/check.sh --full`): образ грузится в QEMU до приглашения `login:` (x86_64, затем aarch64) — x86_64 проходит (`tests/boot.py`, `tests/install.py`), aarch64 — [#1](https://github.com/vovawees/CleanLinux/issues/1)
- [x] сеть: iproute2, dhcpcd, iwd (Wi-Fi), openresolv, сервисы dinit
- [x] установщик `cleanlinux-install` (C, отдельный репозиторий): разметка, `burn -r /mnt install base`, fstab, загрузчик, пользователь — как `pacstrap` + `genfstab`, без выбора DE
- [ ] зашифрованный корень (LUKS2): cryptsetup, `cleanlinux-install --encrypt`, тест в QEMU — [#2](https://github.com/vovawees/CleanLinux/issues/2): рецепты (json-c, popt, lvm2/libdevmapper, cryptsetup), `--encrypt` в cleanlinux-install 0.5.0 и `tests/install.py --encrypt` готовы, осталось пройти тест на свежем образе

## Этап 2. Самодостаточная база

Цель: CleanLinux обновляет и пересобирает сама себя, без хоста.

- [x] burn внутри системы: пакет `burn` уже в `base`; нужны git, curl, ca-certificates, openssl — тогда `burn sync && burn update` работают на устройстве
- [x] `base-devel` для нативной сборки любого рецепта: perl, python, meson, ninja, cmake, flex, bc, elfutils (libelf для objtool ядра), autoconf/automake/libtool, gettext
- [x] ускорители сборки внутри системы: ccache, mold, pahole (BTF для sched_ext)
- [ ] нативная пересборка всей базы на устройстве даёт те же пакеты, что и cross-сборка (воспроизводимость) — проверка `tests/native-repro.sh` готова, прогон после `bootstrap native` и разбор расхождений — [#3](https://github.com/vovawees/CleanLinux/issues/3)
- [x] консольный минимум администратора: procps-ng, psmisc, less, kbd (раскладки и шрифты консоли), man-db — без выбора редактора и оболочки за пользователя

## Этап 3. Железо: драйверы и оптимизация

Цель: на каждом поддерживаемом устройстве работает всё железо, а настройки под него приходят из профиля, а не из ручных твиков.

- [x] профиль — полное описание устройства: фрагмент конфига ядра, `KERNEL_CMDLINE`, нужные firmware и модули, quirks (udev/hwdb-правила, `modprobe.d`, `sysctl.d`) — ставятся пакетом профиля (`hardware`); каталоги устройств `profiles/devices/<имя>/` (`kernel.config`, `quirks/`, `boards`) с проверкой `tests/kernel-config.sh` и `tools/dt-kconfig.py` ([#5](https://github.com/vovawees/CleanLinux/issues/5)); проверка на устройствах — [#8](https://github.com/vovawees/CleanLinux/issues/8)
- [x] firmware: linux-firmware из upstream, на устройство ставится только то, что нужно его профилю
- [x] GPU: libdrm, Mesa по `VIDEO_CARDS` (radeonsi/RADV, iris/ANV, nouveau/NVK, freedreno/turnip, panfrost/panvk, v3d/v3dv, lima, etnaviv, virgl/venus), Vulkan loader; LLVM только там, где он нужен
- [x] NVIDIA: nouveau/NVK из Mesa; проприетарный драйвер — отдельный рецепт категории `nonfree`, выключен по умолчанию
- [ ] звук: alsa-lib, alsa-utils, alsa-ucm-conf, SOF firmware; UCM-профили для handheld (Snapdragon, Steam Deck) — рецепты готовы; UCM-профили handheld — [#6](https://github.com/vovawees/CleanLinux/issues/6)
- [ ] ввод: встроенные контроллеры handheld, сенсорные экраны, поворот экрана и акселерометр (iio), libinput quirks — драйверы во фрагментах профилей, ориентация панелей и матрицы акселерометров ROG Ally X и Legion Go — в ядре и hwdb eudev, сервис датчиков `iio-sensor-proxy` (platform); остальные матрицы и quirks — по отчётам с устройств, [#7](https://github.com/vovawees/CleanLinux/issues/7)
- [x] питание: amd-pstate EPP / intel_pstate, `platform_profile`, лимиты TDP через стандартные интерфейсы ядра, сон (s2idle), подсветка, батарея — с настройками в `/etc`, без GUI
- [x] оптимизация под профиль: I/O-планировщик по типу накопителя (udev), zram/zswap по объёму RAM, cpufreq governor, THP
- [x] Bluetooth и Wi-Fi: bluez, firmware и regdb для беспроводных адаптеров профилей
- [x] arm64: загрузка через U-Boot (RK3566: `extlinux.conf`), прошивку Raspberry Pi 5 (`config.txt`), ABL + Android boot image для Snapdragon (заголовки 0–2, осторожная прошивка в `boot`), device tree и оверлеи из mainline — `BOOTLOADER`/`DEVICE_TREE` профиля, `boot.d` в cleanlinux-boot ([#4](https://github.com/vovawees/CleanLinux/issues/4)); проверка на устройствах — [#8](https://github.com/vovawees/CleanLinux/issues/8)
- [x] определение железа: `burn profile detect` по DMI и device tree, установщик сам предлагает профиль
- [x] таблица статуса по каждому профилю: загрузка, GPU, звук, Wi-Fi/Bluetooth, сон, батарея, контроллеры; проверка на настоящих устройствах — [#8](https://github.com/vovawees/CleanLinux/issues/8)

## Этап 4. Платформа для сборок

Цель: общий нейтральный фундамент, на который встаёт любая сборка — KDE, labwc, sway, консольный интерфейс.
Эти рецепты лежат в CleanLinux-Recipes, но в `base` не входят: их ставит сборка.

- [x] графика и ввод: wayland, wayland-protocols, libxkbcommon, xkeyboard-config, pixman, libinput, libevdev, mtdev, hwdata, libdisplay-info
- [x] сеанс и права: seatd (минимум), elogind (для сборок, которым нужен logind API: KDE, GNOME), D-Bus, polkit, `XDG_RUNTIME_DIR` без systemd
- [x] звук и видео: PipeWire + WirePlumber, совместимость с ALSA/PulseAudio/JACK по features
- [x] шрифтовый стек: freetype, harfbuzz, fontconfig, fribidi (сами шрифты выбирает сборка)
- [x] совместимость с X11 по feature `x11`: Xwayland и библиотеки X11
- [x] xdg-desktop-portal (бэкенды KDE/wlr/GTK — в сборках)
- [x] пользовательские сервисы dinit (`dinit --user`) для сеанса
- [x] контракт для сборок: стабильные имена features, пути, каталоги сервисов, версия базы в `os-release`

## Этап 5. Сборки поверх базы

Цель: сделать свою сборку на CleanLinux так же просто, как свой пакет.

- [x] формат сборки: репозиторий с `spin.conf` (пакеты, features, сервисы), своими рецептами (оверлей) и пакетом настроек — всё ставится, обновляется и удаляется через burn
- [x] `burn spin add|remove|list|show`: подключить сборку из git-репозитория или каталога; её рецепты и features участвуют в `burn update`
- [x] образ со сборкой: `bootstrap.sh disk --spin <repo>` — база + сборка + профиль железа → готовый образ
- [x] `docs/SPINS.md`: как сделать свою сборку и что база ей гарантирует
- [x] пустой шаблон сборки для старта своих репозиториев
- [ ] первые сборки — отдельными репозиториями (например, KDE Plasma и labwc); в базу они не входят — labwc: [cleanlinux-spin-labwc](https://github.com/vovawees/cleanlinux-spin-labwc); KDE Plasma — [#9](https://github.com/vovawees/CleanLinux/issues/9)

## burn на C (параллельно этапам)

Цель: тот же burn — те же рецепты, `burn.conf`, профили, база пакетов и формат `.pkg.tar.zst`, — но цельным
быстрым бинарником, без bash, tar, sed и awk в рабочем цикле. Переход незаметен: C-версия читает и пишет то же,
что bash-прототип, и проверяется сравнением с ним на всех рецептах.

- [x] репозиторий [burn](https://github.com/vovawees/burn): сборка через `make` (только libc + libzstd), unit-тесты, локальные проверки (`tools/check.sh`), сверка с прототипом (`make proto`)
- [x] язык рецептов: свой разбор статического подмножества shell (присваивания, массивы, `${v%…}`, `{001..020}`) — `info`, `query`, `search`, `lint` без запуска bash
- [x] конфиг и профили (статические: машину определяет burn — `HOST_ARCH`, `HOST_VIDEO_CARDS`); определение CPU и устройства на C (cpuid, DMI, device tree) — `profile show|list|detect`
- [x] база пакетов: `list`, `files`, `owner`, `hold`, `history`, `doctor` — индекс файлов в памяти вместо grep по спискам
- [x] пакеты: tar + zstd внутри процесса; атомарная установка (временный файл + `rename`, запись базы одним `RENAME_EXCHANGE`), пути только внутри корня (`openat2` + `RESOLVE_IN_ROOT`), защита конфигов, preserved libs; триггеры (`ldconfig`, `depmod`) — один раз на транзакцию; `install <файл>`, `remove`, `rollback`
- [x] сборка: параллельная загрузка, sha256 внутри процесса, типы сборки на C (autotools, meson, cmake, make, cargo, python, meta, custom); bash только для функций рецепта (`do_*`, `*_extra`, `post_install`, внутри них `bt_*` снова вызывает burn); разбор ELF на C (SONAME, NEEDED) вместо `readelf` на каждый файл, strip пачками; `build`, `unpack`, `install <рецепт>` с зависимостями и ABI-пересборкой — пакеты байт в байт как у прототипа
- [x] rolling+++: `sync`, `plan` (порядок зависимостей без bash), `update`, хуки — сверены с прототипом на тестовом репозитории рецептов
- [x] снимок btrfs перед `update` через ioctl, без btrfs-progs (`SNAPSHOTS=5`, `burn snapshot`) — проверен на настоящей btrfs в виртуальной машине; заменил хук прототипа `10-btrfs-snapshot`
- [x] переход: bootstrap (`bootstrap/host-burn.sh` собирает burn из релиза, закреплённого рецептом), тесты и образ используют C-burn; рецепт `burn` в CleanLinux-Recipes собирается из релизов и входит в `base`; bash-прототип удалён из CleanLinux и остался тегом `burn-prototype` — эталоном для `make proto`. Настоящая base, cross-собранная C-burn, совпадает с пакетами прототипа байт в байт
- [x] burn 0.7–0.9: split-пакеты (`split=()`); сборка от непривилегированного пользователя с изоляцией (namespaces, без сети, `BUILD_USER`); канал `security` (`security=()` в рецепте, `burn update --security`) и подписи Ed25519; бинарный кеш *своих* сборок между своими устройствами; PGO и опциональный Clang (`COMPILER=clang`); HTTP/2 через libcurl (`make CURL=1`); SHA-NI

## Не входит в базу

Это не «потом», а другой уровень — сборки и пользовательские оверлеи:

- DE и WM: KDE Plasma, GNOME, labwc, sway, Hyprland, …
- тулкиты и приложения: Qt, GTK, браузеры, офис, плееры
- игровое: Steam, Proton/Wine, gamescope, эмуляторы, FEX-Emu/Box64, игровые и 32-битные библиотеки для них
- темы, шрифты, обои, оформление
- твики под конкретную нагрузку («для игр», «для стриминга»), если они не про железо
