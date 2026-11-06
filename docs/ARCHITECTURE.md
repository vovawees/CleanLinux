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
3. **burn** ([отдельный репозиторий](https://github.com/vovawees/burn), C) — как собирать и ставить: скачивание и проверка, сборка в кеш, установка, база пакетов, обновления rolling release+++.
4. **bootstrap** (`bootstrap/`) — как получить первую систему, когда ещё ничего нет.

## Базовые решения

| Решение | Почему |
|---|---|
| **glibc**, не musl | Проприетарные драйверы, Flatpak/AppImage и почти любой бинарный софт (в том числе тот, что ставят сборки) рассчитаны на glibc. Быстрый malloc и полная поддержка локалей — бонус. |
| **GCC 16 + binutils** | Основной тулчейн для обеих архитектур; лучшая поддержка `-march`/`-mcpu` под конкретные ядра (znver4, cortex-a73.cortex-a53…). LLVM собирается только там, где он нужен (Mesa для Intel и Mali, llvmpipe); Clang как компилятор системы — опция на будущее. |
| **Merged `/usr`** | `/bin`, `/sbin`, `/lib`, `/lib64` — симлинки в `/usr`. Один каталог с программами, совместимость с бинарниками из других дистрибутивов (`/lib64/ld-linux-x86-64.so.2`, `/lib/ld-linux-aarch64.so.1`). |
| **dinit** | Маленький и быстрый init с зависимостями и супервизией сервисов, без тяжёлого стека systemd. Важно для слабых устройств с 2–4 ГБ RAM. |
| **Стек выбирает сборка** | Wayland или X11, PipeWire или PulseAudio — features программного стека задаёт сборка (или пользователь), а не база и не профиль железа. Рецепты по умолчанию следуют upstream. |
| **zlib-ng, zstd** | zlib-ng — та же ABI, что у zlib, но с SIMD на x86_64 и arm64. zstd — для пакетов (`.tar.zst`) и сжатия btrfs. |
| **btrfs + zstd** (рекомендация) | Снимки перед каждым обновлением (burn делает их сам через ioctl btrfs, `SNAPSHOTS` в `burn.conf`), прозрачное сжатие — меньше места на маленьких eMMC/SD. |
| **Свой triple** | `x86_64-cleanlinux-linux-gnu`, `aarch64-cleanlinux-linux-gnu` — тулчейн никогда не перепутает систему с хостом. |
| **burn на C** | Один бинарник, только libc + libzstd: рецепты разбираются без запуска bash, tar, zstd, sha256 и ELF работают внутри процесса, установка атомарна. bash остаётся для команд сборки внутри рецептов. |

## burn

Пакетный менеджер живёт в своём репозитории: [burn](https://github.com/vovawees/burn), устройство — в его
`docs/DESIGN.md`. CleanLinux берёт его как любой другой пакет: рецепт `burn` в CleanLinux-Recipes собирает
релиз (tarball + sha256), `base` зависит от него. Bootstrap собирает для хоста тот же релиз
(`bootstrap/host-burn.sh`, нужны компилятор C и заголовки libzstd); `BURN_BIN=путь` подставляет другую сборку.

C-версия писалась по bash-прототипу и сверялась с ним команда за командой; прототип остался в истории
CleanLinux, тег [`burn-prototype`](https://github.com/vovawees/CleanLinux/tree/burn-prototype/burn) — с ним
сравнивает `make proto` в репозитории burn.

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
2. `VIDEO_CARDS` профиля: особенности `video_cards_<карта>` (как USE_EXPAND в Gentoo) — Mesa собирает
   только драйверы видеокарт профиля и тянет LLVM, только если он нужен им
3. профиль: `PROFILE_FEATURES`
4. подключённые сборки: `SPIN_FEATURES` из их `spin.conf`
5. `/etc/burn/burn.conf`: `FEATURES="-nls x11"`
6. `package.features` сборок, затем `/etc/burn/package.features`: `mesa -video_cards_intel`
7. командная строка: `burn -f "x11" install ...`

Учитываются только особенности, которые рецепт объявил. Зависимость `pkg:feat` нужна только при включённой
feature, `pkg:!feat` — только при выключенной. Для meson по умолчанию `--auto-features=disabled`: сборка не
зависит от того, что «случайно нашлось» в системе.

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
- `--host-deps` (и любая кросс-сборка) — инструменты сборки берутся с машины сборки: `makedepends` слоёв
  `devel` и `core` (компиляторы, meson, cmake, perl, python, openssl) не собираются, а заголовки и данные
  остальных слоёв (`xorgproto`, `wayland-protocols`, `hwdata`) собираются в корень — он и есть sysroot.

### Изоляция и права

Каждая фаза сборки идёт в своём сетевом пространстве имён (только `lo`): исходники скачаны и проверены
заранее, а сборка не может ничего скачать сама (`cargo fetch` — единственное исключение, до сборки). От root
burn собирает под пользователем `burn` (`BUILD_USER`, создаётся sysusers) с `no_new_privs`, без root —
внутри user namespace; `ISOLATE=auto|1|0`.

Рецепты слоя `nonfree` (драйвер NVIDIA) burn не собирает и не ставит, пока в `burn.conf` нет
`ALLOW_NONFREE=1`. Рецепты с `options=(late)` — внешние модули ядра — `burn update` собирает после того, как
обновление применено, против нового ядра.

### Конфиги

Файлы из `backup=()` рецепта обновляются как в pacman: burn хранит sha256 установленной версии
(`/var/lib/burn/installed/<pkg>/backup-sums`). Нетронутый файл получает новую версию по умолчанию, изменённый
остаётся, а новая версия ложится рядом как `.burnnew`; при удалении пакета сохраняется (`.burnsave`) только
изменённый файл.

### Файлы на системе

| Путь | Что там |
|---|---|
| `/etc/burn/burn.conf` | настройки (пример — `/usr/share/burn/burn.conf.example`) |
| `/etc/burn/package.features` | features для отдельных пакетов |
| `/etc/burn/hold` | замороженные пакеты |
| `/etc/burn/profiles/` | свои профили (ищутся первыми) |
| `/etc/burn/hooks/{pre,post}-update.d/` | хуки обновления |
| `/usr/share/burn/profiles/` | профили железа из этого репозитория (пакет `cleanlinux-profiles`) |
| `/.snapshots/burn-*` | read-only снимки btrfs перед обновлениями |
| `/var/lib/burn/installed/<pkg>/` | `meta`, `files`, `provides-so`, `needs-so`, `backup-sums`, `preserved` |
| `/var/lib/burn/spins/<имя>/` | подключённые сборки: `spin.conf`, рецепты, `package.features` ([SPINS.md](SPINS.md)) |
| `/var/lib/burn/state/history` | журнал транзакций |
| `/var/lib/burn/repos/` | git-клоны репозиториев рецептов |
| `/var/cache/burn/` | исходники, собранные пакеты (для отката), `ccache/` |

## Профили

Профиль — статический файл переменных (то же подмножество shell, что и верхний уровень рецепта: burn читает его
сам, без bash), наследование через `inherit`:

```bash
inherit base
PROFILE_DESC="Mangmi Air X: Snapdragon 662 (SM6115, 4x Cortex-A73 + 4x Cortex-A53), Adreno 610"
CARCH=aarch64
CPU_FLAGS="-mcpu=cortex-a73.cortex-a53 -mfix-cortex-a53-835769 -mfix-cortex-a53-843419"
VIDEO_CARDS=freedreno
PROFILE_FEATURES+=" handheld battery"
FIRMWARE="qcom/a630_sqe qcom/qrb4210/ ath10k/WCN3990 qca/crbtfw qca/crnv"
KERNEL_CMDLINE="clk_ignore_unused pd_ignore_unused"
```

| Переменная | Что это |
|---|---|
| `CARCH`, `CPU_FLAGS` | архитектура и флаги процессора (`-march=znver2`, `-mcpu=cortex-a76.cortex-a55`) |
| `VIDEO_CARDS` | драйверы GPU: ядро, libdrm и Mesa (`video_cards_*`) |
| `KERNEL_CONFIG`, `KERNEL_FRAGMENT` | полный конфиг ядра вместо defconfig; фрагмент устройства, накладывается последним |
| `KERNEL_CMDLINE` | параметры ядра устройства (пакет `hardware` кладёт их в `/usr/lib/kernel/cmdline.d/`) |
| `FIRMWARE` | firmware устройства из linux-firmware (пусто — всё) |
| `MODULES`, `QUIRKS` | модули для загрузки при старте; дерево устройства, устроенное как `/usr/lib`: `udev/rules.d`, `udev/hwdb.d`, `modprobe.d`, `sysctl.d`, `cleanlinux/initramfs.d` (`libinput/` — в `/usr/share/libinput`) |
| `BOOTLOADER`, `DEVICE_TREE` | чем грузится устройство (`systemd-boot`, `extlinux`, `rpi`, `android`) и его device tree (`vendor/board.dtb` или `vendor/`); пакет `hardware` пишет их в `/usr/lib/cleanlinux/boot.d/` |
| `PROFILE_FEATURES` | аппаратные features (`handheld`, `battery`), не программный стек |

Значения профиля, которые упоминает рецепт, входят в его BUILDID: ядро для Steam Deck и ядро для ROG Ally —
разные сборки в кеше, а пакеты, которым железо безразлично, общие. Профиль описывает только железо. `native`
берёт архитектуру и видеокарты машины (`HOST_ARCH`, `HOST_VIDEO_CARDS` — их определяет burn по
`/sys/class/drm`), `burn profile detect` подбирает профиль устройства по DMI и device tree или печатает
заготовку для `/etc/burn/profiles/`. Что проверено на каком профиле — [HARDWARE.md](HARDWARE.md).

Свои файлы устройство держит в `profiles/devices/<имя>/`: `kernel.config` (`KERNEL_FRAGMENT`), `quirks/`
(`QUIRKS`) и `boards` — его device tree. `tests/kernel-config.sh` прогоняет `do_configure` рецепта `linux`
для каждого профиля и проверяет, что каждый параметр фрагмента дошёл до `.config`, а `tools/dt-kconfig.py`
по device tree плат — что у каждого узла есть драйвер и что цепочка накопителя корня собрана в ядро
(подробно — в [HARDWARE.md](HARDWARE.md#каталог-устройства)).

Профили приходят в систему пакетом `cleanlinux-profiles` (входит в `base`), новые устройства — обычным
`burn update`. Его исходник — архив `profiles/` из `tools/profiles-tarball.sh ВЕРСИЯ`, выложенный в релиз
`profiles-ВЕРСИЯ` этого репозитория; bootstrap копирует `profiles/` в rootfs, только пока пакета там нет, и
предупреждает, если рабочее дерево разошлось с установленным пакетом.

## Загрузка и установка

- **cleanlinux-boot** ([репозиторий](https://github.com/vovawees/cleanlinux-boot)) — сервисы dinit и помощник на
  C: ранние ФС, fsck, udev и coldplug модулей, hostname, sysctl, seed, часы, sysusers и tmpfiles, getty на tty и
  последовательном порту; swap на zram по объёму RAM (`zram.d`), яркость подсветки, настройки питания
  (`power.d`: профиль платформы, governor и EPP, пороги заряда, лимиты мощности); триггер burn кладёт ядра в
  загрузочный раздел под загрузчик устройства из `boot.d`: записи systemd-boot (UEFI), `extlinux.conf` для U-Boot
  (RK3566), `config.txt` для прошивки Raspberry Pi 5, Android boot image для ABL (Snapdragon) с осторожной
  прошивкой в раздел `boot`; device tree и оверлеи — из `/usr/lib/modules/<версия>/dtbs`. Корень монтируется без
  initramfs (`root=PARTUUID=`, драйверы накопителей и btrfs встроены в ядро). Шифрования корня (LUKS) в
  базе нет. initramfs собирается только там, где он нужен: живой системе (`initramfs.d`: `enable=yes`) и
  устройствам, которым модули нужны до корня. На arm64 `vmlinuz` — EFI-программа (zboot), рядом лежит обычный
  `Image` для U-Boot, прошивки Pi и boot.img.
- **cleanlinux-install** ([репозиторий](https://github.com/vovawees/cleanlinux-install)) — установщик на C:
  разметка GPT (ESP 512 MiB + btrfs с подтомами `@`, `@home`, `@snapshots`, zstd), **копия слоёв носителя**
  живой системы (`@/`, по выбору `nonfree/` и `spins/NAME/`, но не `live/`: whiteout'ы и непрозрачные каталоги
  overlayfs, xattr, жёсткие ссылки, `copy_file_range`), fstab по PARTUUID, загрузчик профиля (systemd-boot,
  extlinux, config.txt, boot.img), root и пользователь, автовход на tty1 (`--autologin`), Wi-Fi через iwd,
  параметры ядра профиля; без носителя — `burn clone` из кеша пакетов. `cleanlinux-setup` — его экраны (TUI на
  C без ncurses, English и русский, шаги слева): язык, раскладка, часовой пояс с поиском, диск (носитель живой
  системы и занятые диски выбрать нельзя), компьютер и пользователь, «Система» (рабочий стол — спины с
  носителя, проприетарные драйверы, профиль по `burn profile detect`, автовход), сводка, «Стереть диск?»,
  прогресс копирования; на последовательной консоли и `TERM=vt100` — ASCII.
- **Живая система** (live-образ, `bootstrap.sh live`): сырой GPT-образ для флешки или SD-карты — ESP
  (`CL_EFI`: systemd-boot, ядро, initramfs) и один раздел btrfs (zstd:15) или ext4 с меткой `CL_LIVE_<дата>`,
  где лежат обычные деревья файлов без squashfs и ISO 9660: `@/` (система, которую копирует установщик),
  `nonfree/` (проприетарные драйверы), `spins/NAME/` (слой сборки), `live/` (автовход root, установщик,
  hostname `cleanlinux-live`, motd). `root=live:LABEL=…`: init из initramfs cleanlinux-boot находит раздел,
  монтирует его только для чтения и собирает корень overlay `live/` + `spins/NAME/` (`cleanlinux.live.spin=`) +
  `nonfree/` (`cleanlinux.live.nonfree=0` — без него) + `@/` с tmpfs сверху (`cleanlinux.live.toram` — сначала
  копирует раздел в память); точки монтирования — `/run/cleanlinux/live/{medium,rw,toram}`. Слои `nonfree/` и
  `spins/NAME/` — разница с `@/` (`bootstrap/layer.py`: что добавила или изменила `burn install`, whiteout'ы для
  удалённого), поэтому сборка работает и с проприетарными драйверами, и без них. root входит сам
  (`agetty --autologin`); на главной консоли открывается `cleanlinux-setup --auto`, а с labwc — рабочий стол
  и установщик в окне. Кеша пакетов на носителе нет: установщик копирует сами деревья, поэтому установка не
  требует сети и даёт ровно ту же систему.
- Пользовательские сервисы сеанса — `dinit --user` через turnstile (он же даёт `XDG_RUNTIME_DIR`), сессионная
  шина D-Bus — пользовательский сервис; сборки включают свои через `/etc/dinit.d/user/boot.d`.

## Bootstrap

`bootstrap/bootstrap.sh` собирает систему, имея на хосте только компилятор:

| Этап | Шаги |
|---|---|
| `toolchain` | проверка хоста → скелет rootfs (merged `/usr`) → кросс-binutils → GCC pass 1 (без libc) → заголовки Linux → glibc → финальный GCC (C, C++) → runtime-библиотеки GCC в rootfs → тест (hello на C/C++, запуск через ld.so из rootfs или qemu) |
| `base` | `burn --target <triple> install filesystem linux-headers glibc`, затем `base`; при повторном запуске — `burn update`; `burn doctor` |
| `native` | компилятор для цели, затем rootfs сам собирает `base-devel` (perl, python, cmake, …) своим gcc и burn — в chroot внутри user namespace, без инструментов хоста |
| `image` | burn внутри rootfs, проверка через chroot/qemu, архив rootfs `.tar.zst` |
| `disk` | загрузочный образ без root: GPT, ESP (systemd-boot, ядро профиля) + btrfs (`@`, `@home`, `@snapshots`, zstd); `--spin` добавляет сборку, `DISK_PACKAGE_FEATURES` — строки `package.features` образа |
| `live` | live-образ без root: корень с `LIVE_PACKAGES` (linux-firmware по списку `LIVE_FIRMWARE`, wireless-regdb) и `base-devel` (стадия `native` выполнится первой, если его нет), слои `nonfree/` (`LIVE_NONFREE`), `spins/NAME/` (`--spin`) и `live/`; раздел btrfs (`mkfs.btrfs --rootdir --compress zstd:15 --shrink`) или ext4 (`LIVE_FS=ext4`), ESP с systemd-boot, ядром и initramfs живой системы (до 6 пунктов меню: сборка, консоль, copy to RAM, safe graphics, без проприетарных драйверов, serial) — сырой GPT-образ `cleanlinux-<arch>-<профиль>[-<сборка>]-<дата>.img` + `.sha256` |

Образ диска проверяют `tests/boot.py` (загрузка в QEMU до входа, монтирования, сервисы, zram, `burn doctor`) и
`tests/install.py` (установка на второй диск через `cleanlinux-install`, загрузка установленной системы, вход
root и пользователя). Live-образ проверяет `tests/live.py`: загрузка с него как с USB-флешки (xHCI,
usb-storage), проход по экранам установщика по-русски через последовательную консоль (маленький эмулятор
терминала), проверки живой системы (overlay из слоёв носителя, без squashfs и кеша пакетов, сервисы), затем
загрузка только нового диска и проверки выбранного (часовой пояс, раскладка, пользователь, пароли, слои,
ничего живого). `tests/layer.sh` проверяет `bootstrap/layer.py`: слой поверх основы даёт в overlayfs ровно
изменённое дерево.
После этапа `native` `tests/native-repro.sh` пересобирает внутри rootfs (своим gcc и burn, в том же chroot в
user namespace) каждый пакет, сделанный кросс-сборкой, и сравнивает содержимое с кросс-пакетом файл за
файлом (путь, права, sha256; `.BURN/meta` с датой и флагами не сравнивается); `--compare A B` сравнивает
два готовых пакета.

Все исходники берутся через `burn unpack` из тех же рецептов, что и у обычных пакетов, — у тулчейна нет отдельных «волшебных» версий. Так же bootstrap берёт и meson: tarball рецепта `meson` запускается python3 хоста из `build/<arch>/tools/bin` (meson хоста бывает слишком старым для рецептов). Каждый шаг пишет лог и отметку, повторный запуск продолжает с места остановки. rootfs — это и sysroot кросс-тулчейна, поэтому в образ не попадает ничего с хоста.
