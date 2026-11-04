# shellcheck shell=bash
inherit base
PROFILE_DESC="Raspberry Pi 5: BCM2712 (4x Cortex-A76), VideoCore VII"
CARCH=aarch64
CPU_FLAGS="-mcpu=cortex-a76"
VIDEO_CARDS=v3d
# firmware from linux-firmware (paths or name prefixes under /usr/lib/firmware); not yet checked on the device
# CYW43455 Wi-Fi (brcmfmac); its Bluetooth firmware (BCM4345C0.hcd) is not in linux-firmware
FIRMWARE="brcm/brcmfmac43455-sdio cypress/cyfmac43455"
# the firmware in the EEPROM reads config.txt of the boot partition (os_prefix: the kernel directory)
BOOTLOADER=rpi
DEVICE_TREE=broadcom/bcm2712-rpi-5-b.dtb
