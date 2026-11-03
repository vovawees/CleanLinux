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

## Сделано

- [x] `burn`: рецепты, features, профили, сборка в кеш, установка в любой корень, база пакетов, конфликты, `backup`
- [x] rolling release+++: `plan`, сборка до установки, хуки (btrfs-снимок), preserved libs, ABI-пересборка, `hold`, `rollback`, `history`, `doctor`
- [x] burn 0.3: параллельная предзагрузка с проверкой, воспроизводимые пакеты, `CCACHE=1`, `LINKER=mold|lld`, `options=(o3)`
- [x] канал `edge`: ежедневный `tools/updates.sh` (upstream GNU, kernel.org, GitHub) с автоматической проверкой ссылок и sha256
- [x] профили железа: `native`, `generic-x86_64(-v3)`, `generic-aarch64` и устройства — Steam Deck, ROG Ally, ROG Xbox Ally X, Legion Go / Go S, MSI Claw (Meteor Lake, Lunar Lake), Retroid Pocket 5, AYN Odin 2, Mangmi Air X, Raspberry Pi 5, RK3566, ASUS X540YA
- [x] рецепты базовой системы: GCC 16, glibc 2.44, binutils 2.47, Linux 7.3, bash, coreutils, util-linux, dinit, …
- [x] cross-first bootstrap для x86_64 и aarch64: тулчейн → 21 пакет `base` → архив rootfs (x86_64 проверен в chroot, aarch64 — под qemu-user)
- [x] ядро: zswap/zram на zstd, MGLRU, PSI, BFQ, BBR + fq, `PREEMPT_DYNAMIC`, amd-pstate EPP, платформенные драйверы и встроенные контроллеры handheld (ROG Ally, Legion Go, MSI Claw, AYANEO, OneXPlayer), sched_ext как feature
- [x] тесты: smoke на настоящих рецептах, полный цикл rolling+++, воспроизводимость пакетов

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
- [ ] сервисы dinit для загрузки: `/proc` `/sys` `/dev` `/run`, fsck и `mount -a`, hostname, `sysctl --system`, загрузка модулей, seed случайных чисел, часы, getty на tty и на последовательном порту, корректное выключение
- [ ] вход в систему: Linux-PAM, shadow (`passwd`, `useradd`), `login` и `su` из util-linux
- [ ] устройства: eudev (udev без systemd: правила, hwdb, `libudev` — без него не работают libinput, Mesa и любой DE)
- [ ] ядро: драйверы накопителей и файловые системы корня встроены (NVMe, AHCI, virtio, btrfs, vfat) — загрузка без initramfs по `root=PARTUUID=`; маленький генератор initramfs для случаев, где без него нельзя (LUKS, модульный storage на arm64)
- [ ] файловые системы: e2fsprogs, btrfs-progs, dosfstools
- [ ] загрузчик: systemd-boot на UEFI (собирается отдельно, без systemd); хук burn кладёт ядро в ESP и пишет запись загрузчика при установке и обновлении ядра
- [ ] образ диска `bootstrap.sh disk`: GPT, ESP + btrfs (подтома `@`, `@home`, `@snapshots`, сжатие zstd), собирается без root-прав
- [ ] тест загрузки в CI: образ грузится в QEMU до приглашения `login:` (x86_64, затем aarch64)
- [ ] сеть: iproute2, dhcpcd, iwd (Wi-Fi), openresolv, сервисы dinit
- [ ] установщик `cleanlinux-install`: разметка, `burn -r /mnt install base`, fstab, загрузчик, пользователь — как `pacstrap` + `genfstab`, без выбора DE

## Этап 2. Самодостаточная база

Цель: CleanLinux обновляет и пересобирает сама себя, без хоста.

- [ ] burn внутри системы: git, curl, ca-certificates, openssl; рецепт самого `burn` (из тега CleanLinux) — `burn sync && burn update` работают на устройстве
- [ ] `base-devel` для нативной сборки любого рецепта: perl, python, meson, ninja, cmake, flex, bc, elfutils (libelf для objtool ядра), autoconf/automake/libtool, gettext
- [ ] ускорители сборки внутри системы: ccache, mold, pahole (BTF для sched_ext)
- [ ] нативная пересборка всей базы на устройстве даёт те же пакеты, что и cross-сборка (воспроизводимость)
- [ ] консольный минимум администратора: procps-ng, psmisc, less, kbd (раскладки и шрифты консоли), man-db — без выбора редактора и оболочки за пользователя

## Этап 3. Железо: драйверы и оптимизация

Цель: на каждом поддерживаемом устройстве работает всё железо, а настройки под него приходят из профиля, а не из ручных твиков.

- [ ] профиль — полное описание устройства: фрагмент конфига ядра, `KERNEL_CMDLINE`, нужные firmware и модули, quirks (udev/hwdb-правила, `modprobe.d`, `sysctl.d`) — ставятся пакетом профиля
- [ ] firmware: linux-firmware из upstream, на устройство ставится только то, что нужно его профилю
- [ ] GPU: libdrm, Mesa по `VIDEO_CARDS` (radeonsi/RADV, iris/ANV, nouveau/NVK, freedreno/turnip, panfrost/panvk, v3d/v3dv, lima, etnaviv, virgl/venus), Vulkan loader; LLVM только там, где он нужен
- [ ] NVIDIA: nouveau/NVK из Mesa; проприетарный драйвер — отдельный рецепт категории `nonfree`, выключен по умолчанию
- [ ] звук: alsa-lib, alsa-utils, alsa-ucm-conf, SOF firmware; UCM-профили для handheld (Snapdragon, Steam Deck)
- [ ] ввод: встроенные контроллеры handheld, сенсорные экраны, поворот экрана и акселерометр (iio), libinput quirks
- [ ] питание: amd-pstate EPP / intel_pstate, `platform_profile`, лимиты TDP через стандартные интерфейсы ядра, сон (s2idle), подсветка, батарея — с настройками в `/etc`, без GUI
- [ ] оптимизация под профиль: I/O-планировщик по типу накопителя (udev), zram/zswap по объёму RAM, cpufreq governor, THP
- [ ] Bluetooth и Wi-Fi: bluez, firmware и regdb для беспроводных адаптеров профилей
- [ ] arm64: загрузка через U-Boot (RK3566), firmware для Raspberry Pi 5, ABL + `boot.img` для Snapdragon (Retroid Pocket 5, AYN Odin 2, Mangmi Air X), device tree из mainline
- [ ] определение железа: `burn profile detect` по DMI и device tree, установщик сам предлагает профиль
- [ ] таблица статуса по каждому профилю: загрузка, GPU, звук, Wi-Fi/Bluetooth, сон, батарея, контроллеры

## Этап 4. Платформа для сборок

Цель: общий нейтральный фундамент, на который встаёт любая сборка — KDE, labwc, sway, консольный интерфейс.
Эти рецепты лежат в CleanLinux-Recipes, но в `base` не входят: их ставит сборка.

- [ ] графика и ввод: wayland, wayland-protocols, libxkbcommon, xkeyboard-config, pixman, libinput, libevdev, mtdev, hwdata, libdisplay-info
- [ ] сеанс и права: seatd (минимум), elogind (для сборок, которым нужен logind API: KDE, GNOME), D-Bus, polkit, `XDG_RUNTIME_DIR` без systemd
- [ ] звук и видео: PipeWire + WirePlumber, совместимость с ALSA/PulseAudio/JACK по features
- [ ] шрифтовый стек: freetype, harfbuzz, fontconfig, fribidi (сами шрифты выбирает сборка)
- [ ] совместимость с X11 по feature `x11`: Xwayland и библиотеки X11
- [ ] xdg-desktop-portal (бэкенды KDE/wlr/GTK — в сборках)
- [ ] пользовательские сервисы dinit (`dinit --user`) для сеанса
- [ ] контракт для сборок: стабильные имена features, пути, каталоги сервисов, версия базы в `os-release`

## Этап 5. Сборки поверх базы

Цель: сделать свою сборку на CleanLinux так же просто, как свой пакет.

- [ ] формат сборки: репозиторий с `spin.conf` (пакеты, features, сервисы), своими рецептами (оверлей) и пакетом настроек — всё ставится, обновляется и удаляется через burn
- [ ] `burn spin add|remove|list|show`: подключить сборку из git-репозитория или каталога; её рецепты и features участвуют в `burn update`
- [ ] образ со сборкой: `bootstrap.sh disk --spin <repo>` — база + сборка + профиль железа → готовый образ
- [ ] `docs/SPINS.md`: как сделать свою сборку и что база ей гарантирует
- [ ] пустой шаблон сборки для старта своих репозиториев
- [ ] первые сборки — отдельными репозиториями (например, KDE Plasma и labwc); в базу они не входят

## burn (параллельно этапам)

- [ ] split-пакеты (например, `gcc-libs` отдельно от компилятора)
- [ ] сборка от непривилегированного пользователя, изоляция сборки (namespaces, без сети)
- [ ] канал `security`, подписи коммитов репозитория рецептов
- [ ] бинарный кеш *своих* сборок между своими устройствами (не публичный репозиторий бинарников)
- [ ] PGO для тяжёлых пакетов, опциональный Clang-тулчейн

## Не входит в базу

Это не «потом», а другой уровень — сборки и пользовательские оверлеи:

- DE и WM: KDE Plasma, GNOME, labwc, sway, Hyprland, …
- тулкиты и приложения: Qt, GTK, браузеры, офис, плееры
- игровое: Steam, Proton/Wine, gamescope, эмуляторы, FEX-Emu/Box64, игровые и 32-битные библиотеки для них
- темы, шрифты, обои, оформление
- твики под конкретную нагрузку («для игр», «для стриминга»), если они не про железо
