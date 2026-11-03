# CleanLinux

Экспериментальный Linux, собранный **с нуля** (не LFS) для портативных консолей и ПК на **x86_64 и arm64**.
Всё собирается из исходников прямо на устройстве — под его процессор и видеокарту, а система обновляется по модели **rolling release+++**.
Пакетный менеджер **`burn`** «прожигает» исходники в пакеты под твоё железо.

*English summary [below](#english).*

> **Статус: pre-alpha.** Уже работают пакетный менеджер `burn`, профили железа, рецепты базовой системы и bootstrap с нуля.
> Проверено: x86_64 (`generic-x86_64`) и arm64 (`mangmi-air-x`) собираются от компилятора хоста до rootfs из 21 пакета
> (GCC 16.2, glibc 2.44, bash, coreutils, util-linux, dinit, …): x86_64 — архив 28 МБ, проверен в chroot (`burn doctor` внутри системы);
> arm64 — 25 МБ, проверен через qemu-user. Загрузочного образа (ядро + загрузчик) пока нет — см. [docs/ROADMAP.md](docs/ROADMAP.md).

## Идея

| | |
|---|---|
| **С нуля, но не LFS** | Свой пакетный менеджер, свой формат рецептов и свой cross-first bootstrap вместо книги с ручными шагами. |
| **Без бинарников** | Репозиторий [CleanLinux-Recipes](https://github.com/vovawees/CleanLinux-Recipes) — как AUR: только ссылки на исходники upstream, sha256 и рецепты. |
| **Под твоё железо** | Профиль устройства задаёт `-march`/`-mcpu`, драйверы GPU, параметры ядра и features (аналог USE-флагов). |
| **Минимум ресурсов** | dinit вместо systemd, без документации, лишних локалей и статических библиотек, LTO, Wayland-first. |
| **Совместимость** | glibc (не musl), merged `/usr` — Steam/Proton, проприетарные драйверы и обычные бинарные программы работают. |
| **Свежее всё** | GCC 16, glibc 2.44, binutils 2.47, Linux 7.3, coreutils 9.12, bash 5.3, … — `tools/updates.sh` каждый день сверяет рецепты с upstream и публикует проверенные обновления в канал `edge`. |
| **Быстрая сборка** | Все исходники скачиваются параллельно и проверяются до начала сборки; `CCACHE=1`, `LINKER=mold`, LTO, `-O3` для горячего кода (zstd, lz4, zlib-ng). |
| **Воспроизводимость** | Тот же рецепт + флаги + тулчейн → побайтно тот же пакет (`SOURCE_DATE_EPOCH`, `-ffile-prefix-map`, фиксированные времена файлов). |
| **Игры и консоли** | Ядро с NTSYNC (Proton), BBR + fq, zswap/zram на zstd, MGLRU, `PREEMPT_DYNAMIC`, драйверы ROG Ally, Legion Go, MSI Claw, AYANEO, OneXPlayer; `vm.max_map_count` для игр. |
| **x86_64 + arm64** | Обе архитектуры равноправны; любую можно собрать с любой (cross-first). |

## Rolling release+++

Обычный rolling — «обновил всё и надейся». В CleanLinux у обновления есть страховка:

1. **План** — `burn plan` показывает, что обновится, риск (`core` / `major`) и какие пакеты придётся пересобрать.
2. **Сначала сборка, потом установка** — всё собирается в кеш; если хоть что-то не собралось, система не тронута.
3. **Снимок** — pre-update хуки (btrfs-снимок из коробки).
4. **ABI-aware** — сменилась soname библиотеки → старая сохраняется (*preserved libs*), зависимые пакеты пересобираются автоматически.
5. **Проверка** — `burn doctor` ищет пропавшие и устаревшие библиотеки.
6. **Откат и заморозка** — `burn rollback <pkg>`, `burn hold <pkg>`, журнал `burn history`.
7. **Каналы** — `main` (прошёл CI), `edge` (новые версии upstream каждый день, ссылки и sha256 проверены автоматически), `security` *(план)*.

Подробнее: [docs/ROLLING.md](docs/ROLLING.md).

## Поддерживаемое железо

| Профиль | Устройство | CPU | `VIDEO_CARDS` |
|---|---|---|---|
| `native` | эта машина (автоопределение) | `-march=native` / `-mcpu=native` | по `/sys` |
| `generic-x86_64` | любой x86_64 ПК с ~2009 г. | `x86-64-v2` | amd intel nouveau virgl |
| `generic-x86_64-v3` | современные ПК (Haswell+, Zen+) | `x86-64-v3` (AVX2, FMA) | amd intel nouveau virgl |
| `generic-aarch64` | любая arm64-плата или консоль | `armv8-a` | freedreno panfrost v3d lima etnaviv virgl |
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
burn/        пакетный менеджер (bash): burn, lib/, buildtypes/, hooks/, burn.conf
profiles/     профили железа: base, generic-*, native, devices/*
bootstrap/    сборка системы с нуля: тулчейн → базовая система → образ
tests/        smoke-тест на настоящих рецептах и тест rolling+++
docs/         архитектура, rolling+++, рецепты, roadmap
```

## Быстрый старт

Попробовать `burn` без root — пакеты ставятся в отдельный корень:

```sh
git clone https://github.com/vovawees/CleanLinux
git clone https://github.com/vovawees/CleanLinux-Recipes
cd CleanLinux
alias burn="$PWD/burn/burn -R $PWD/../CleanLinux-Recipes/packages"

burn search
burn info zstd
burn profile detect
tests/smoke.sh      # собирает и ставит zstd, zlib-ng, xz, lz4, pkgconf в тестовый корень
tests/rolling.sh    # soname bump, preserved libs, ABI-пересборка, hold, rollback
```

Собрать систему с нуля (нужны gcc/g++, make, bison, gawk, m4, perl, python3, meson, ninja, cmake, pkg-config, git, curl; для чужой архитектуры — `qemu-user`):

```sh
bootstrap/bootstrap.sh --arch x86_64 toolchain        # кросс-тулчейн + glibc в rootfs
bootstrap/bootstrap.sh --profile mangmi-air-x all     # arm64: тулчейн, base, tarball
```

На 2 ядрах тулчейн собирается примерно за 45 минут, base — ещё около 30. Каждый шаг пишет лог в `build/<arch>/logs/` и отметку в `build/<arch>/stamps/`, поэтому прерванный bootstrap продолжается с того же места.

## Документация

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — из чего состоит система и почему так
- [docs/ROLLING.md](docs/ROLLING.md) — как устроены обновления rolling release+++
- [docs/RECIPES.md](docs/RECIPES.md) — как писать рецепты
- [docs/ROADMAP.md](docs/ROADMAP.md) — что дальше

## Лицензия

MIT — см. [LICENSE](LICENSE). Пакеты распространяются под своими лицензиями (указаны в рецептах).

## English

**CleanLinux** is an experimental Linux distribution built **from scratch** (not LFS) for handheld consoles and PCs, on **x86_64 and arm64**.
There are no binary repositories: the [CleanLinux-Recipes](https://github.com/vovawees/CleanLinux-Recipes) repository holds only upstream source links, checksums and build recipes (like the AUR, but for the whole system), and the `burn` package manager builds everything locally, tuned by a hardware profile (CPU flags, GPU drivers, kernel options, features).

- glibc (not musl), GCC 16, merged `/usr`, dinit, Wayland-first; minimal by default (no docs, extra locales or static libraries; LTO).
- **Rolling release+++**: updates are planned, fully built before anything is installed, snapshotted, ABI-aware (preserved libraries + automatic rebuilds after soname changes), verified with `burn doctor`, and can be rolled back or held per package. A daily upstream watcher publishes verified version bumps to the `edge` channel.
- `burn` ("burns" sources into packages for your hardware): parallel, verified prefetch of every source before building, reproducible packages (`SOURCE_DATE_EPOCH`, `-ffile-prefix-map`, clamped file times), `CCACHE=1`, `LINKER=mold|lld`, `-O3` for hot code.
- Handheld-ready kernel defaults: NTSYNC for Proton, BBR + fq, zstd zswap/zram, MGLRU, `PREEMPT_DYNAMIC`, ROG Ally / Legion Go / MSI Claw / AYANEO / OneXPlayer drivers. Profiles for Steam Deck, ROG Ally (X), ROG Xbox Ally X, Legion Go / Go S / Go 2, MSI Claw, Retroid Pocket 5, AYN Odin 2, Mangmi Air X and more.
- Cross-first bootstrap: `bootstrap/bootstrap.sh` builds a cross toolchain, glibc and the base system for either architecture from any host.
- Status: pre-alpha. Verified: x86_64 and arm64 (Mangmi Air X profile) bootstrap from a host compiler to a 21-package rootfs (GCC 16.2, glibc 2.44, dinit, ...), tested in a chroot (x86_64) and under qemu-user (arm64). A bootable image (kernel + bootloader) is next (see [docs/ROADMAP.md](docs/ROADMAP.md)).
