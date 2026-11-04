# Сборки (spins)

CleanLinux — база: core, железо (hardware) и общий фундамент (platform), см. [SCOPE.md](SCOPE.md). Всё, что
делает из базы рабочий стол, киоск или консоль под задачу, — **сборка**: отдельный git-репозиторий со своими
рецептами, набором пакетов, features и настройками. Сборка ставится, обновляется и удаляется через burn, как
пакет, и не трогает то, что принадлежит базе.

Начать проще всего с шаблона [cleanlinux-spin-template](https://github.com/vovawees/cleanlinux-spin-template);
пример настоящей сборки — [cleanlinux-spin-labwc](https://github.com/vovawees/cleanlinux-spin-labwc).

## Репозиторий сборки

```
spin.conf               что сборка ставит и включает (статический shell, как burn.conf)
packages/<имя>/recipe   свои рецепты (category=extra): то, чего нет в базе, и пакет настроек сборки
package.features        особенности отдельных пакетов (необязательно), формат /etc/burn/package.features
```

```sh
SPIN_NAME=labwc
SPIN_DESC="labwc: лёгкий стековый Wayland-композитор"
SPIN_BASE=1                           # самый старый уровень контракта базы (CLEANLINUX_BASE), на котором она работает
SPIN_PACKAGES=(labwc foot labwc-spin) # ставятся с зависимостями; настройки сборки — тоже пакет
SPIN_FEATURES="wayland -x11"          # для всех рецептов: между профилем и burn.conf пользователя
SPIN_SERVICES=(seatd dbus)            # системные сервисы dinit, включаются при загрузке
SPIN_USER_SERVICES=(dbus)             # сервисы dinit --user, включаются у каждого пользователя
```

Настройки — это **пакет** (обычно `<сборка>-spin`, `build_type=custom`): конфиги в `/etc/xdg/…` или
`/usr/share/…`, файлы в каталогах `*.d` базы (ниже), свои сервисы dinit. Тогда `burn spin remove` убирает их
вместе со сборкой, а правки пользователя в `/etc` защищены, как у любого пакета (`backup=`).

## Команды

```sh
burn spin add https://github.com/vovawees/cleanlinux-spin-labwc   # или каталог
burn spin list
burn spin show labwc
burn sync && burn plan && burn update      # сборка обновляется вместе с базой
burn spin remove labwc
```

- `spin add` клонирует репозиторий в `/var/lib/burn/spins/<имя>` (каталог — подключает ссылкой), проверяет
  `SPIN_BASE` против `CLEANLINUX_BASE` системы, ставит `SPIN_PACKAGES` с зависимостями, пересобирает пакеты,
  которым изменили особенности `SPIN_FEATURES`, и включает сервисы (ссылки в `/etc/dinit.d/boot.d` и
  `/etc/dinit.d/user/boot.d`).
- `burn sync` подтягивает git-сборки, `burn plan` показывает новые пакеты сборки (`new: spin <имя>`),
  `burn update` собирает всё до установки и ставит; ABI-пересборка касается и пакетов сборки.
- `spin remove` выключает её сервисы, убирает её особенности и принесённые ею пакеты — кроме тех, что нужны
  пользователю или другой сборке.

Подробности — в [DESIGN.md burn](https://github.com/vovawees/burn/blob/main/docs/DESIGN.md#сборки-spins).

## Образ со сборкой

```sh
bootstrap/bootstrap.sh --profile steam-deck --spin https://github.com/vovawees/cleanlinux-spin-labwc disk
```

`--spin` (можно несколько) добавляет сборку в корень образа после базы, ядра и загрузчика: её пакеты
cross-собираются под профиль, а в кеш пакетов образа попадают все пакеты, так что установщик переносит на
диск систему вместе со сборкой (`burn clone`). Сборка из каталога копируется в образ. Образ называется
`cleanlinux-<arch>-<профиль>-<сборка>.img`.

То, что cross-сборки пакетов запускают на самой машине сборки, bootstrap собирает в `build/<arch>/tools`
шагом `94-disk-native`: `wayland-scanner` той версии, что в рецепте `wayland` (сам wayland требует ровно
свою версию, wlroots — свежую), со статической expat из рецепта `expat`. meson cross-сборок ищет такие
программы через `PKG_CONFIG_PATH_FOR_BUILD`, который bootstrap направляет туда же.

## Что база обещает сборкам — контракт, уровень 1

Уровень контракта записан в `/usr/lib/os-release`:

```
ID=cleanlinux
BUILD_ID=rolling
CLEANLINUX_BASE=1
```

Он растёт, когда меняется что-то из списка ниже так, что сборке нужно что-то менять у себя (имя пакета или
feature, путь, каталог сервисов). Добавления (новые пакеты, новые features) уровень не меняют. Каждое изменение
записывается в «Историю контракта» в конце этого файла.

**Система**
- glibc, merged `/usr` (`/bin`, `/sbin`, `/lib`, `/lib64` — ссылки в `/usr`), FHS; `bash` — `/usr/bin/bash`;
- профиль железа (`burn profile show`) задаёт CPU, `VIDEO_CARDS`, ядро и firmware — сборка их не меняет;
- обновления rolling release+++ (`burn update`): сначала собирается всё, потом ставится; снимок btrfs до него.

**Пакеты platform** (рецепты базы, `base` их не ставит — их тянут сборки): `wayland`, `wayland-protocols`,
`libxkbcommon`, `xkeyboard-config`, `pixman`, `libdrm`, `mesa`, `vulkan-loader`, `libinput`, `libevdev`, `mtdev`,
`hwdata`, `libdisplay-info`, `seatd`, `elogind`, `dbus`, `polkit`, `turnstile`, `pipewire`, `wireplumber`,
`alsa-lib`, `freetype`, `harfbuzz`, `fontconfig`, `fribidi`, `cairo`, `pango`, `libpng`, `glib`, `libxml2`,
`libepoxy`, `xwayland` и библиотеки X11 (`libx11`, `libxcb`, …), `xdg-desktop-portal` (бэкенды — в сборках),
`bubblewrap`, `fuse3`, `gstreamer`, `gst-plugins-base`, `gdk-pixbuf`, `json-glib`, `libgudev`, `iio-sensor-proxy`
(акселерометр и датчик света по D-Bus: поворот экрана; запускается сам, когда udev находит датчик). Шрифты,
тулкиты (GTK, Qt) и приложения — дело сборок.

**Features** (стабильные имена):

| Feature | Что включает |
|---|---|
| `wayland` | поддержку Wayland (по умолчанию включена: mesa, vulkan-loader) |
| `x11` | X11 и Xwayland: GLX в mesa, xcb в libxkbcommon и libepoxy, X11 в vulkan-loader и gst-plugins-base |
| `elogind` | logind API вместо seatd/turnstile-рундира (KDE, GNOME): seatd, pipewire, wireplumber, turnstile |
| `alsa`, `pulseaudio`, `jack`, `bluetooth` | звук в pipewire (`pipewire-pulse`, JACK, Bluetooth), ALSA в gst-plugins-base |
| `llvmpipe` | программный OpenGL/Vulkan через LLVM (иначе — softpipe без LLVM) |
| `nls` | переводы |
| `video_cards_<карта>` | драйверы GPU по `VIDEO_CARDS` профиля (`amd`, `intel`, `nouveau`, `freedreno`, `panfrost`, `v3d`, `lima`, `etnaviv`, `virgl`); сборка их не задаёт |

**Сервисы** — dinit:
- системные сервисы пакетов — `/usr/lib/dinit.d`, администратора — `/etc/dinit.d`; включённые при загрузке —
  ссылки в `/etc/dinit.d/boot.d`; сервис сборки зависит от `system` (`depends-on: system`), сервисы входа —
  `login`;
- пользовательские — `dinit --user`, его запускает turnstile при первом входе: `/usr/lib/dinit.d/user`,
  `/etc/dinit.d/user`, `~/.config/dinit.d`; для всех пользователей включаются ссылками в
  `/etc/dinit.d/user/boot.d`;
- `XDG_RUNTIME_DIR=/run/user/<uid>` — turnstile (с feature `elogind` — elogind); сессионная шина D-Bus —
  пользовательский сервис `dbus` на `$XDG_RUNTIME_DIR/bus` (`DBUS_SESSION_BUS_ADDRESS` в сеансе);
- места: seatd даёт место группе `seat` (пользователь сборки добавляется в неё), с feature `elogind` — elogind.

**Каталоги для файлов сборки** (их читает `cleanlinux-boot` при загрузке и burn при установке):
`/usr/lib/sysctl.d`, `/usr/lib/modules-load.d`, `/usr/lib/modprobe.d`, `/usr/lib/udev/rules.d`,
`/usr/lib/sysusers.d`, `/usr/lib/tmpfiles.d`, `/usr/lib/dinit.d`, `/usr/lib/dinit.d/user`, хуки burn —
`/etc/burn/hooks/{pre,post}-update.d/`. Настройки питания и zram — `power.d` и `zram.d` (это железо: их
ставят профили, сборке они не нужны).

## Правила

- Сборка **не переопределяет** рецепты core и hardware и не меняет профили железа. Не хватает чего-то в базе —
  это исправляется в базе, для всех ([CleanLinux-Recipes](https://github.com/vovawees/CleanLinux-Recipes)).
- Рецепты сборки — `category=extra`, и их имена не совпадают с пакетами базы: рецепт сборки ищется раньше
  рецептов базы и перекрыл бы его у всех, кто её поставил.
- Features программного стека — в `SPIN_FEATURES`, не в профилях; пользователь может переопределить их в
  `/etc/burn/burn.conf` и `/etc/burn/package.features`.
- Файлы базы сборка не правит: только свои пакеты и каталоги `*.d` выше.

## История контракта

| Уровень | Когда | Что |
|---|---|---|
| 1 | 2026-11 | первая версия: всё, что выше |
