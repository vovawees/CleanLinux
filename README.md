# CleanLinux

**База для Linux-сборок, как Arch.** Система, собранная **с нуля** (не LFS), драйверы и оптимизация под
конкретное железо — ПК, ноутбуки, портативные консоли и одноплатники на **x86_64 и arm64**.
Всё собирается из исходников прямо на устройстве — под его процессор и видеокарту, а система обновляется по модели **rolling release+++**.
Пакетный менеджер **`burn`** «прожигает» исходники в пакеты под твоё железо.

KDE Plasma, labwc, sway и любые другие DE и WM, приложения, Steam — **не часть базы**: они ставятся поверх,
отдельными *сборками*. База ничего не выбирает за тебя, но даёт всё, чтобы любая сборка хорошо работала на твоём железе.

*English summary [below](#english).*

> **Статус: pre-alpha.** Работают пакетный менеджер `burn`, профили железа, рецепты базы, драйверов и платформы, bootstrap с нуля
> и загрузочный образ: `bootstrap.sh disk` собирает GPT-образ (ESP с systemd-boot + btrfs), который загружается в QEMU (UEFI)
> до входа в систему и ставится на диск установщиком `cleanlinux-install` (`tests/boot.py`, `tests/install.py`; проверен x86_64).
> Сборки ставятся поверх (`burn spin`, первая — [labwc](https://github.com/vovawees/cleanlinux-spin-labwc)). На настоящих устройствах
> профили ещё не проверены ([docs/HARDWARE.md](docs/HARDWARE.md)); что дальше — [docs/ROADMAP.md](docs/ROADMAP.md) и доска
> [CleanLinux roadmap](https://github.com/users/vovawees/projects/1).

## Идея

| | |
|---|---|
| **База, а не витрина** | Только система, драйверы и оптимизация под железо. DE, WM, приложения и игры — сборки поверх; правило, что куда относится, — в [docs/SCOPE.md](docs/SCOPE.md). |
| **С нуля, но не LFS** | Свой пакетный менеджер, свой формат рецептов и свой cross-first bootstrap вместо книги с ручными шагами. |
| **Без бинарников** | Репозиторий [CleanLinux-Recipes](https://github.com/vovawees/CleanLinux-Recipes) — как AUR: только ссылки на исходники upstream, sha256 и рецепты. |
| **Под твоё железо** | Профиль устройства задаёт `-march`/`-mcpu`, драйверы GPU, параметры ядра и аппаратные features (аналог USE-флагов). |
| **Минимум ресурсов** | dinit вместо systemd, без документации, лишних локалей и статических библиотек, LTO. |
| **Совместимость** | glibc (не musl), merged `/usr` — проприетарные драйверы, Flatpak/AppImage и обычные бинарные программы работают. |
| **Свежее всё** | GCC 16, glibc 2.44, binutils 2.47, Linux 7.3, coreutils 9.12, bash 5.3, … — `tools/updates.sh` каждый день сверяет рецепты с upstream и публикует проверенные обновления в канал `edge`. |
| **Быстрая сборка** | Все исходники скачиваются параллельно и проверяются до начала сборки; `CCACHE=1`, `LINKER=mold`, LTO, `-O3` для горячего кода (zstd, lz4, zlib-ng). |
| **Воспроизводимость** | Тот же рецепт + флаги + тулчейн → побайтно тот же пакет (`SOURCE_DATE_EPOCH`, `-ffile-prefix-map`, фиксированные времена файлов). |
| **Железо** | Ядро под класс устройства: zswap/zram на zstd, MGLRU, BFQ для флеша, amd-pstate EPP, `PREEMPT_DYNAMIC`, BBR + fq; платформенные драйверы и встроенные контроллеры ROG Ally, Legion Go, MSI Claw, AYANEO, OneXPlayer, Steam Deck. |
| **x86_64 + arm64** | Обе архитектуры равноправны; любую можно собрать с любой (cross-first). |

## База и сборки

```
 сборки     KDE Plasma │ labwc │ sway │ консольный интерфейс │ твоя        отдельные репозитории
 ───────────────────────────────────────────────────────────────────────────────────────────
 platform   Wayland/X11-библиотеки, libinput, seatd/elogind, D-Bus, PipeWire, шрифтовый стек
 hardware   ядро под профиль, firmware, Mesa/Vulkan, звук, ввод, питание, датчики, quirks
 core       filesystem, glibc, bash, coreutils, util-linux, dinit, kmod, burn, …   (base)
```

CleanLinux отвечает за три нижних слоя. Сборка — это репозиторий со своими рецептами, набором пакетов,
features и настройками; она ставится и обновляется тем же `burn` и не меняет базу.

## Rolling release+++

Обычный rolling — «обновил всё и надейся». В CleanLinux у обновления есть страховка:

1. **План** — `burn plan` показывает, что обновится, риск (`core` / `major`) и какие пакеты придётся пересобрать.
2. **Сначала сборка, потом установка** — всё собирается в кеш; если хоть что-то не собралось, система не тронута.
3. **Снимок** — read-only снимок btrfs перед применением (burn делает его сам, без btrfs-progs) и pre-update хуки.
4. **ABI-aware** — сменилась soname библиотеки → старая сохраняется (*preserved libs*), зависимые пакеты пересобираются автоматически.
5. **Проверка** — `burn doctor` ищет пропавшие и устаревшие библиотеки.
6. **Откат и заморозка** — `burn rollback <pkg>`, `burn hold <pkg>`, журнал `burn history`.
7. **Каналы** — `main` (прошёл проверки `tools/check.sh`), `edge` (новые версии upstream каждый день, ссылки и sha256 проверены автоматически), `security` (`burn update --security`: только исправления уязвимостей).

Подробнее: [docs/ROLLING.md](docs/ROLLING.md).

## Поддерживаемое железо

| Профиль | Устройство | CPU | `VIDEO_CARDS` |
|---|---|---|---|
| `native` | эта машина (автоопределение) | `-march=native` / `-mcpu=native` | по `/sys` |
| `generic-x86_64` | любой x86_64 ПК с ~2009 г. | `x86-64-v2` | amd intel nouveau virgl |
| `generic-x86_64-v3` | современные ПК (Haswell+, Zen+) | `x86-64-v3` (AVX2, FMA) | amd intel nouveau virgl |
| `generic-aarch64` | любая arm64-плата или устройство | `armv8-a` | freedreno panfrost v3d lima etnaviv virgl |
| `steam-deck` | Valve Steam Deck LCD/OLED | `znver2` | amd |
| `rog-ally` | ASUS ROG Ally / Ally X | `znver4` | amd |
| `rog-xbox-ally-x` | ASUS ROG Xbox Ally X, Lenovo Legion Go 2 (Z2 Extreme) | `znver5` | amd |
| `legion-go` | Lenovo Legion Go (Z1 Extreme) | `znver4` | amd |
| `legion-go-s` | Lenovo Legion Go S (Z2 Go) | `znver3` | amd |
| `msi-claw` | MSI Claw A1M (Meteor Lake) | `meteorlake` | intel |
| `msi-claw-ai-plus` | MSI Claw 7/8 AI+ (Lunar Lake) | `lunarlake` | intel |
| `mangmi-air-x` | Mangmi Air X (Snapdragon 662) | `cortex-a73.cortex-a53` + обход errata A53 | freedreno |
| `retroid-pocket-5` | Retroid Pocket 5 / Mini (Snapdragon 865) | `cortex-a77` | freedreno |
| `ayn-odin2` | AYN Odin 2 / Mini / Portal (Snapdragon 8 Gen 2) | `armv8.6-a+fp16fml`, tune `cortex-a715` | freedreno |
| `raspberry-pi-5` | Raspberry Pi 5 | `cortex-a76` | v3d |
| `rk3566-handheld` | Anbernic RG353/RG503, PowKiddy (RK3566) | `cortex-a55` | panfrost |
| `asus-x540ya` | ASUS X540YA (AMD E2-6110, Radeon R2) | `btver2` | amd (GCN 1.1 через amdgpu) |

```sh
burn profile list      # все профили
burn profile detect    # какой профиль подходит этой машине
burn profile show      # итоговые CFLAGS, features, драйверы
```

## Структура

```
profiles/     профили железа: base, generic-*, native, devices/*
bootstrap/    сборка системы с нуля: тулчейн → базовая система → образ (burn для хоста — host-burn.sh)
tests/        smoke-тест на настоящих рецептах, rolling+++, загрузка и установка образа в QEMU (boot.py, install.py)
tools/        локальные проверки (check.sh, hooks/pre-push), источник пакета профилей (profiles-tarball.sh)
docs/         архитектура, rolling+++, рецепты, roadmap
```

## Быстрый старт

Попробовать `burn` без root — пакеты ставятся в отдельный корень:

```sh
git clone https://github.com/vovawees/CleanLinux
git clone https://github.com/vovawees/CleanLinux-Recipes
git clone https://github.com/vovawees/burn && make -C burn    # компилятор C и libzstd
cd CleanLinux
alias burn="$PWD/../burn/burn -R $PWD/../CleanLinux-Recipes/packages"
export BURN_PROFILE_DIR=$PWD/profiles

burn search
burn info zstd
burn profile detect
tests/smoke.sh      # собирает и ставит zstd, zlib-ng, xz, lz4, pkgconf в тестовый корень
tests/rolling.sh    # soname bump, preserved libs, ABI-пересборка, hold, rollback
```

Собрать систему с нуля (нужны gcc/g++, make, bison, gawk, m4, perl, python3, meson, ninja, cmake, pkg-config, git, curl и заголовки libzstd; для чужой архитектуры — `qemu-user`). burn для хоста bootstrap собирает сам — из того же релиза, что ставится в образ:

```sh
bootstrap/bootstrap.sh --arch x86_64 toolchain        # кросс-тулчейн + glibc в rootfs
bootstrap/bootstrap.sh --profile mangmi-air-x all     # arm64: тулчейн, base, tarball
```

На 2 ядрах тулчейн собирается примерно за 45 минут, base — ещё около 30. Каждый шаг пишет лог в `build/<arch>/logs/` и отметку в `build/<arch>/stamps/`, поэтому прерванный bootstrap продолжается с того же места.

## Документация

- [docs/SCOPE.md](docs/SCOPE.md) — что входит в базу, а что ставится сверху
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — из чего состоит система и почему так
- [docs/ROLLING.md](docs/ROLLING.md) — как устроены обновления rolling release+++
- [docs/RECIPES.md](docs/RECIPES.md) — как писать рецепты
- [docs/SPINS.md](docs/SPINS.md) — как сделать сборку поверх базы и что база ей гарантирует
- [docs/HARDWARE.md](docs/HARDWARE.md) — профили устройств и что на них проверено
- [docs/ROADMAP.md](docs/ROADMAP.md) — что дальше (и [доска roadmap](https://github.com/users/vovawees/projects/1))
- [CONTRIBUTING.md](CONTRIBUTING.md) — как участвовать: проверки `tools/check.sh`, коммиты, pull request'ы

## Лицензия

MIT — см. [LICENSE](LICENSE). Пакеты распространяются под своими лицензиями (указаны в рецептах).

## English

**CleanLinux** is a **base for Linux spins, like Arch**: a system built **from scratch** (not LFS), drivers and
hardware-specific tuning for PCs, laptops, handhelds and boards, on **x86_64 and arm64**. Desktops, window
managers, applications and games are not part of the base: they are *spins* on top (KDE Plasma, labwc, sway, ...),
maintained in their own repositories and installed with the same package manager (see [docs/SCOPE.md](docs/SCOPE.md)).

There are no binary repositories: the [CleanLinux-Recipes](https://github.com/vovawees/CleanLinux-Recipes) repository holds only upstream source links, checksums and build recipes (like the AUR, but for the whole system), and the `burn` package manager builds everything locally, tuned by a hardware profile (CPU flags, GPU drivers, kernel options, hardware features).

- glibc (not musl), GCC 16, merged `/usr`, dinit; minimal by default (no docs, extra locales or static libraries; LTO). The software stack (Wayland or X11, PipeWire, ...) is chosen by spins, not by the base.
- **Rolling release+++**: updates are planned, fully built before anything is installed, snapshotted, ABI-aware (preserved libraries + automatic rebuilds after soname changes), verified with `burn doctor`, and can be rolled back or held per package. A daily upstream watcher publishes verified version bumps to the `edge` channel.
- `burn` ("burns" sources into packages for your hardware): parallel, verified prefetch of every source before building, reproducible packages (`SOURCE_DATE_EPOCH`, `-ffile-prefix-map`, clamped file times), `CCACHE=1`, `LINKER=mold|lld`, `-O3` for hot code.
- Hardware: kernel defaults per device class (zstd zswap/zram, MGLRU, BFQ for flash, amd-pstate EPP, `PREEMPT_DYNAMIC`, BBR + fq), platform and built-in controller drivers for ROG Ally / Legion Go / MSI Claw / AYANEO / OneXPlayer / Steam Deck. Profiles for Steam Deck, ROG Ally (X), ROG Xbox Ally X, Legion Go / Go S / Go 2, MSI Claw, Retroid Pocket 5, AYN Odin 2, Mangmi Air X, Raspberry Pi 5 and more.
- Cross-first bootstrap: `bootstrap/bootstrap.sh` builds a cross toolchain, glibc and the base system for either architecture from any host.
- Status: pre-alpha. `bootstrap.sh disk` builds a bootable GPT image (ESP with systemd-boot + btrfs) that boots in QEMU (UEFI) to a login prompt and installs onto a disk with `cleanlinux-install` (`tests/boot.py`, `tests/install.py`; verified on x86_64). Spins go on top (`burn spin`; the first one is labwc). Real devices are not verified yet ([docs/HARDWARE.md](docs/HARDWARE.md)); next steps: [docs/ROADMAP.md](docs/ROADMAP.md) and the [roadmap board](https://github.com/users/vovawees/projects/1). Contributing: [CONTRIBUTING.md](CONTRIBUTING.md) (no hosted CI: `tools/check.sh`).
