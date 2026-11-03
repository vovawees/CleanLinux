# Архитектура CleanLinux

CleanLinux — дистрибутив из трёх частей:

```
CleanLinux-Recipes  ──►  broom  ──►  система на устройстве
 (ссылки + рецепты)      (сборка,     /usr, /etc, /var/lib/broom
                          установка,
 profiles/ ─────────────► обновления)
 (железо пользователя)
```

1. **Рецепты** ([CleanLinux-Recipes](https://github.com/vovawees/CleanLinux-Recipes)) — что собирать: ссылка на исходник upstream, sha256, тип сборки, зависимости, features. Бинарников там нет и не будет.
2. **Профиль** (`profiles/`) — под что собирать: архитектура, флаги CPU, драйверы GPU, параметры ядра, набор features.
3. **broom** (`broom/`) — как собирать и ставить: скачивание и проверка, сборка в кеш, установка, база пакетов, обновления rolling release+++.
4. **bootstrap** (`bootstrap/`) — как получить первую систему, когда ещё ничего нет.

## Базовые решения

| Решение | Почему |
|---|---|
| **glibc**, не musl | Steam, Proton, Wine, проприетарные драйверы, AppImage/Flatpak и почти любой бинарный софт рассчитаны на glibc. Быстрый malloc и полная поддержка локалей — бонус. |
| **GCC 16 + binutils** | Основной тулчейн для обеих архитектур; лучшая поддержка `-march`/`-mcpu` под конкретные ядра (znver4, cortex-a73.cortex-a53…). Clang/LLVM появится как опция (нужен и для Mesa). |
| **Merged `/usr`** | `/bin`, `/sbin`, `/lib`, `/lib64` — симлинки в `/usr`. Один каталог с программами, совместимость с бинарниками из других дистрибутивов (`/lib64/ld-linux-x86-64.so.2`, `/lib/ld-linux-aarch64.so.1`). |
| **dinit** | Маленький и быстрый init с зависимостями и супервизией сервисов, без тяжёлого стека systemd. Важно для консолей с 2–4 ГБ RAM. |
| **Wayland-first** | features по умолчанию: `wayland vulkan opengl pipewire`, `-x11 -pulseaudio`. X11 включается одной строкой. |
| **zlib-ng, zstd** | zlib-ng — та же ABI, что у zlib, но с SIMD на x86_64 и arm64. zstd — для пакетов (`.tar.zst`) и сжатия btrfs. |
| **btrfs + zstd** (рекомендация) | Снимки перед каждым обновлением (`hooks/pre-update.d/10-btrfs-snapshot`), прозрачное сжатие — меньше места на маленьких eMMC/SD. |
| **Свой triple** | `x86_64-cleanlinux-linux-gnu`, `aarch64-cleanlinux-linux-gnu` — тулчейн никогда не перепутает систему с хостом. |
| **bash для broom** | Ноль зависимостей: broom работает на любом хосте с bash, coreutils, tar, zstd и git — значит, и во время bootstrap. |

## broom

```
broom/broom             точка входа, разбор опций
broom/lib/config.sh     broom.conf, профиль, флаги компилятора, тулчейн (native/cross)
broom/lib/recipe.sh     загрузка рецептов, features, условные зависимости, lint
broom/lib/fetch.sh      скачивание (зеркала gnu://, kernel://), sha256, распаковка, патчи
broom/lib/build.sh      сборка в DESTDIR, чистка, strip, упаковка в .tar.zst, BUILDID
broom/lib/db.sh         база установленных пакетов, установка/удаление, конфликты, история
broom/lib/deps.sh       порядок зависимостей
broom/lib/update.sh     sync, plan, update, ABI-follow-up, doctor
broom/lib/cli.sh        команды
broom/buildtypes/*.sh   autotools, meson, cmake, make, cargo, python, custom, meta
broom/hooks/            хуки (снимок btrfs перед обновлением)
```

### Конвейер сборки

`fetch` (https, проверка sha256) → `unpack` → патчи → `do_prepare` → `configure` → `build` → (`check`) → `install` в `DESTDIR` →
чистка (документация, лишние локали, `.la`, статические библиотеки при наличии `.so`, пустые каталоги) → `strip` → сбор `provides-so`/`needs-so` → пакет `.tar.zst` в кеше.

Каждая сборка получает **BUILDID** — хеш от: рецепта и его файлов (`rid`), `CHOST`, итоговых флагов компилятора, включённых features и **soname библиотек, которые дают установленные прямые зависимости**. Если зависимость сменила ABI, BUILDID меняется и кешированный пакет не будет переиспользован по ошибке.

### Features (аналог USE-флагов)

Порядок, в котором применяются переключатели (последний побеждает):

1. значения по умолчанию в рецепте: `features=(+wayland -x11)`
2. профиль: `PROFILE_FEATURES`
3. `/etc/broom/broom.conf`: `FEATURES="-nls x11"`
4. `/etc/broom/package.features`: `mesa -x11 +vulkan`
5. командная строка: `broom -f "x11" install ...`

Зависимость `pkg:feat` нужна только при включённой feature, `pkg:!feat` — только при выключенной. Для meson по умолчанию `--auto-features=disabled`: сборка не зависит от того, что «случайно нашлось» в системе.

### Флаги компилятора

- `OPT_FLAGS` (по умолчанию `-O2 -pipe`) + `CPU_FLAGS` из профиля;
- hardening: `-fstack-clash-protection -D_FORTIFY_SOURCE=3` (=2 на GCC < 12), `-fcf-protection` на x86_64, `-mbranch-protection=standard` на arm64;
- `LDFLAGS`: `-O1 --as-needed --sort-common -z relro -z now -z pack-relative-relocs` (последний отключается автоматически, если libc не поддерживает DT_RELR);
- LTO для всех рецептов без `options=(!lto)`.

### Корни и кросс-компиляция

- `broom -r /mnt/root install …` — установка в другой корень (с проверкой конфликтов, базой пакетов и историей внутри него).
- В режиме *staging root* (корень ≠ `/`, без кросса) заголовки и библиотеки берутся из корня: `-isystem`, `-L`, `-Wl,-rpath-link`, `PKG_CONFIG_PATH`.
- `--target aarch64-cleanlinux-linux-gnu` — кросс-сборка: корень одновременно sysroot тулчейна, так что всё линкуется ровно с той glibc, с которой будет работать.
- `--host-deps` — инструменты сборки (meson, cmake, …) берутся с хоста, их `makedepends` не ставятся в корень.

### Файлы на системе

| Путь | Что там |
|---|---|
| `/etc/broom/broom.conf` | настройки (см. `broom/broom.conf`) |
| `/etc/broom/package.features` | features для отдельных пакетов |
| `/etc/broom/hold` | замороженные пакеты |
| `/etc/broom/profiles/` | свои профили (ищутся первыми) |
| `/etc/broom/hooks/{pre,post}-update.d/` | хуки обновления |
| `/var/lib/broom/installed/<pkg>/` | `meta`, `files`, `provides-so`, `needs-so`, `preserved` |
| `/var/lib/broom/state/history` | журнал транзакций |
| `/var/lib/broom/repos/` | git-клоны репозиториев рецептов |
| `/var/cache/broom/` | исходники и собранные пакеты (для отката) |

## Профили

Профиль — bash-файл с переменными, наследование через `inherit`:

```bash
inherit base
PROFILE_DESC="Mangmi Air X: Snapdragon 662 (SM6115, 4x Cortex-A73 + 4x Cortex-A53), Adreno 610"
CARCH=aarch64
CPU_FLAGS="-mcpu=cortex-a73.cortex-a53 -mfix-cortex-a53-835769 -mfix-cortex-a53-843419"
VIDEO_CARDS=freedreno
PROFILE_FEATURES+=" gaming handheld battery"
```

Переменные: `CARCH`, `CPU_FLAGS`, `VIDEO_CARDS`, `PROFILE_FEATURES`, `KERNEL_CMDLINE`, `KERNEL_CONFIG` (фрагмент конфигурации ядра). Профиль `native` определяет CPU и GPU сам (`-march=native`/`-mcpu=native`, видеокарты по `/sys`), `broom profile detect` подбирает готовый профиль устройства или печатает заготовку для `/etc/broom/profiles/`.

## Bootstrap

`bootstrap/bootstrap.sh` собирает систему, имея на хосте только компилятор:

| Этап | Шаги |
|---|---|
| `toolchain` | проверка хоста → скелет rootfs (merged `/usr`) → кросс-binutils → GCC pass 1 (без libc) → заголовки Linux → glibc → финальный GCC (C, C++) → runtime-библиотеки GCC в rootfs → тест (hello на C/C++, запуск через ld.so из rootfs или qemu) |
| `base` | `broom --target <triple> install filesystem linux-headers glibc`, затем `base`; `broom doctor` |
| `image` | broom внутри rootfs, проверка через chroot/qemu, архив rootfs `.tar.zst` |

Все исходники берутся через `broom unpack` из тех же рецептов, что и у обычных пакетов, — у тулчейна нет отдельных «волшебных» версий. Каждый шаг пишет лог и отметку, повторный запуск продолжает с места остановки. rootfs — это и sysroot кросс-тулчейна, поэтому в образ не попадает ничего с хоста.
