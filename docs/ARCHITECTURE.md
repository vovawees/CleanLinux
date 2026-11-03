# Архитектура CleanLinux

CleanLinux — база, как Arch: система, драйверы и оптимизация под железо (слои core, hardware и platform).
DE, WM и приложения ставятся поверх сборками — что куда относится, описано в [SCOPE.md](SCOPE.md).

База состоит из трёх частей:

```
CleanLinux-Recipes  ──►  burn  ──►  система на устройстве
 (ссылки + рецепты)      (сборка,     /usr, /etc, /var/lib/burn
                          установка,
 profiles/ ─────────────► обновления)
 (железо пользователя)
```

1. **Рецепты** ([CleanLinux-Recipes](https://github.com/vovawees/CleanLinux-Recipes)) — что собирать: ссылка на исходник upstream, sha256, тип сборки, зависимости, features. Бинарников там нет и не будет.
2. **Профиль** (`profiles/`) — под что собирать: архитектура, флаги CPU, драйверы GPU, параметры ядра, набор features.
3. **burn** ([отдельный репозиторий](https://github.com/vovawees/burn), C; в `burn/` — bash-прототип до паритета) — как собирать и ставить: скачивание и проверка, сборка в кеш, установка, база пакетов, обновления rolling release+++.
4. **bootstrap** (`bootstrap/`) — как получить первую систему, когда ещё ничего нет.

## Базовые решения

| Решение | Почему |
|---|---|
| **glibc**, не musl | Проприетарные драйверы, Flatpak/AppImage и почти любой бинарный софт (в том числе тот, что ставят сборки) рассчитаны на glibc. Быстрый malloc и полная поддержка локалей — бонус. |
| **GCC 16 + binutils** | Основной тулчейн для обеих архитектур; лучшая поддержка `-march`/`-mcpu` под конкретные ядра (znver4, cortex-a73.cortex-a53…). Clang/LLVM появится как опция (нужен и для Mesa). |
| **Merged `/usr`** | `/bin`, `/sbin`, `/lib`, `/lib64` — симлинки в `/usr`. Один каталог с программами, совместимость с бинарниками из других дистрибутивов (`/lib64/ld-linux-x86-64.so.2`, `/lib/ld-linux-aarch64.so.1`). |
| **dinit** | Маленький и быстрый init с зависимостями и супервизией сервисов, без тяжёлого стека systemd. Важно для слабых устройств с 2–4 ГБ RAM. |
| **Стек выбирает сборка** | Wayland или X11, PipeWire или PulseAudio — features программного стека задаёт сборка (или пользователь), а не база и не профиль железа. Рецепты по умолчанию следуют upstream. |
| **zlib-ng, zstd** | zlib-ng — та же ABI, что у zlib, но с SIMD на x86_64 и arm64. zstd — для пакетов (`.tar.zst`) и сжатия btrfs. |
| **btrfs + zstd** (рекомендация) | Снимки перед каждым обновлением (`hooks/pre-update.d/10-btrfs-snapshot`), прозрачное сжатие — меньше места на маленьких eMMC/SD. |
| **Свой triple** | `x86_64-cleanlinux-linux-gnu`, `aarch64-cleanlinux-linux-gnu` — тулчейн никогда не перепутает систему с хостом. |
| **burn на C** | Один бинарник, только libc + libzstd: рецепты разбираются без запуска bash, tar и zstd работают внутри процесса, установка атомарна. bash остаётся для команд сборки внутри рецептов. Bash-прототип в `burn/` — эталон поведения, пока C-версия не догонит его. |

## burn

C-версия и её устройство — в репозитории [burn](https://github.com/vovawees/burn) (`docs/DESIGN.md`). Ниже — bash-прототип,
который остаётся эталоном поведения до паритета:

```
burn/burn             точка входа, разбор опций
burn/lib/config.sh     burn.conf, профиль, флаги компилятора, тулчейн (native/cross)
burn/lib/recipe.sh     загрузка рецептов, features, условные зависимости, lint
burn/lib/fetch.sh      скачивание (зеркала gnu://, kernel://), sha256, распаковка, патчи
burn/lib/build.sh      сборка в DESTDIR, чистка, strip, упаковка в .tar.zst, BUILDID
burn/lib/db.sh         база установленных пакетов, установка/удаление, конфликты, история
burn/lib/deps.sh       порядок зависимостей
burn/lib/update.sh     sync, plan, update, ABI-follow-up, doctor
burn/lib/cli.sh        команды
burn/buildtypes/*.sh   autotools, meson, cmake, make, cargo, python, custom, meta
burn/hooks/            хуки (снимок btrfs перед обновлением)
```

### Конвейер сборки

`fetch` (https, проверка sha256) → `unpack` → патчи → `do_prepare` → `configure` → `build` → (`check`) → `install` в `DESTDIR` →
чистка (документация, лишние локали, `.la`, статические библиотеки при наличии `.so`, пустые каталоги) → `strip` → сбор `provides-so`/`needs-so` → пакет `.tar.zst` в кеше.

Каждая сборка получает **BUILDID** — хеш от: рецепта и его файлов (`rid`), `CHOST`, итоговых флагов компилятора, включённых features и **soname библиотек, которые дают установленные прямые зависимости**. Если зависимость сменила ABI, BUILDID меняется и кешированный пакет не будет переиспользован по ошибке.

`install`, `update` и ABI-пересборка сначала скачивают **все** недостающие исходники параллельно (`FETCH_JOBS`, общие архивы — один раз) и проверяют sha256 каждого: долгое обновление не остановится на середине из-за мёртвой ссылки или битого архива.

### Воспроизводимые пакеты

Тот же рецепт + флаги + тулчейн дают побайтно тот же пакет — на любой машине и в любом рабочем каталоге:

- `SOURCE_DATE_EPOCH` — время последнего коммита, менявшего рецепт (или самого нового его файла); от него же дата сборки в `meta` и `KBUILD_BUILD_TIMESTAMP` ядра;
- `-ffile-prefix-map=<work>=/usr/src/<pkg>` — пути сборки не попадают в бинарники;
- `tar --sort=name --mtime=@SOURCE_DATE_EPOCH --clamp-mtime`, владелец `0:0`.

Это основа для будущего кеша *своих* сборок между своими устройствами (ROADMAP): одинаковый BUILDID значит одинаковые байты.

### Ускорение сборки

| Настройка | Что делает |
|---|---|
| `CCACHE=1`, `CCACHE_SIZE=5G` | каталог-маскарад ccache первым в `PATH` (`cc`, `gcc`, `$CHOST-gcc`, …), кеш в `/var/cache/burn/ccache`; пересборка после смены рецепта почти бесплатна |
| `LINKER=mold\|lld\|bfd` | `-fuse-ld=…`, если пробная линковка настоящим компилятором прошла (GCC < 12 получает mold через `libexec/mold/ld`); иначе предупреждение и линкер по умолчанию; рецепты могут отказаться: `options=(!linker)` (glibc, gcc) |
| `options=(o3)` | `-O2` → `-O3` для горячего кода, который upstream собирает с `-O3` (zstd, lz4, zlib-ng); `-Os` не трогается |
| `FETCH_JOBS=4` | параллельные загрузки |

### Features (аналог USE-флагов)

Порядок, в котором применяются переключатели (последний побеждает):

1. значения по умолчанию в рецепте: `features=(+wayland -x11)`
2. профиль: `PROFILE_FEATURES`
3. `/etc/burn/burn.conf`: `FEATURES="-nls x11"`
4. `/etc/burn/package.features`: `mesa -x11 +vulkan`
5. командная строка: `burn -f "x11" install ...`

Зависимость `pkg:feat` нужна только при включённой feature, `pkg:!feat` — только при выключенной. Для meson по умолчанию `--auto-features=disabled`: сборка не зависит от того, что «случайно нашлось» в системе.

### Флаги компилятора

- `OPT_FLAGS` (по умолчанию `-O2 -pipe`) + `CPU_FLAGS` из профиля;
- hardening: `-fstack-clash-protection -D_FORTIFY_SOURCE=3` (=2 на GCC < 12), `-fcf-protection` на x86_64, `-mbranch-protection=standard` на arm64;
- `LDFLAGS`: `-O1 --as-needed --sort-common -z relro -z now -z pack-relative-relocs` (последний отключается автоматически, если libc не поддерживает DT_RELR);
- LTO для всех рецептов без `options=(!lto)`;
- `options=(o3)` — `-O3` для горячего кода; `LINKER=` — mold/lld (см. «Ускорение сборки»).

### Корни и кросс-компиляция

- `burn -r /mnt/root install …` — установка в другой корень (с проверкой конфликтов, базой пакетов и историей внутри него).
- В режиме *staging root* (корень ≠ `/`, без кросса) заголовки и библиотеки берутся из корня: `-isystem`, `-L`, `-Wl,-rpath-link`, `PKG_CONFIG_PATH`.
- `--target aarch64-cleanlinux-linux-gnu` — кросс-сборка: корень одновременно sysroot тулчейна, так что всё линкуется ровно с той glibc, с которой будет работать.
- `--host-deps` — инструменты сборки (meson, cmake, …) берутся с хоста, их `makedepends` не ставятся в корень.

### Файлы на системе

| Путь | Что там |
|---|---|
| `/etc/burn/burn.conf` | настройки (см. `burn/burn.conf`) |
| `/etc/burn/package.features` | features для отдельных пакетов |
| `/etc/burn/hold` | замороженные пакеты |
| `/etc/burn/profiles/` | свои профили (ищутся первыми) |
| `/etc/burn/hooks/{pre,post}-update.d/` | хуки обновления |
| `/var/lib/burn/installed/<pkg>/` | `meta`, `files`, `provides-so`, `needs-so`, `preserved` |
| `/var/lib/burn/state/history` | журнал транзакций |
| `/var/lib/burn/repos/` | git-клоны репозиториев рецептов |
| `/var/cache/burn/` | исходники, собранные пакеты (для отката), `ccache/` |

## Профили

Профиль — bash-файл с переменными, наследование через `inherit`:

```bash
inherit base
PROFILE_DESC="Mangmi Air X: Snapdragon 662 (SM6115, 4x Cortex-A73 + 4x Cortex-A53), Adreno 610"
CARCH=aarch64
CPU_FLAGS="-mcpu=cortex-a73.cortex-a53 -mfix-cortex-a53-835769 -mfix-cortex-a53-843419"
VIDEO_CARDS=freedreno
PROFILE_FEATURES+=" handheld battery"
```

Переменные: `CARCH`, `CPU_FLAGS`, `VIDEO_CARDS`, `PROFILE_FEATURES`, `KERNEL_CMDLINE`, `KERNEL_CONFIG` (фрагмент конфигурации ядра). Профиль описывает только железо: в `PROFILE_FEATURES` — аппаратные features (`handheld`, `battery`, …), а не программный стек. Профиль `native` определяет CPU и GPU сам (`-march=native`/`-mcpu=native`, видеокарты по `/sys`), `burn profile detect` подбирает готовый профиль устройства или печатает заготовку для `/etc/burn/profiles/`.

## Bootstrap

`bootstrap/bootstrap.sh` собирает систему, имея на хосте только компилятор:

| Этап | Шаги |
|---|---|
| `toolchain` | проверка хоста → скелет rootfs (merged `/usr`) → кросс-binutils → GCC pass 1 (без libc) → заголовки Linux → glibc → финальный GCC (C, C++) → runtime-библиотеки GCC в rootfs → тест (hello на C/C++, запуск через ld.so из rootfs или qemu) |
| `base` | `burn --target <triple> install filesystem linux-headers glibc`, затем `base`; `burn doctor` |
| `image` | burn внутри rootfs, проверка через chroot/qemu, архив rootfs `.tar.zst` |

Все исходники берутся через `burn unpack` из тех же рецептов, что и у обычных пакетов, — у тулчейна нет отдельных «волшебных» версий. Каждый шаг пишет лог и отметку, повторный запуск продолжает с места остановки. rootfs — это и sysroot кросс-тулчейна, поэтому в образ не попадает ничего с хоста.
