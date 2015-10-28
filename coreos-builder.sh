#!/bin/bash
#
# Copyright 2015, Yongxin Solutions
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Author: George Li
#

set -e

# Everything we do should be user-access only!
umask 077

## Variables -----------------------------------------------------------------

SCRIPT_NAME=${SCRIPT_NAME:-$(basename $0)}
SCRIPT_DIR=$(cd $(dirname "$0") && pwd)
SCRIPT_ACTION="BUILD"
SCRIPT_OUTPUT=""
SCRIPT_USAGE="Usage: $0 [-V version] [-D /dev/device]
Options:
    -C CHANNEL          Release channel to use (e.g. beta, alpha, stable) [default: ${COREOS_CHANNEL_ID}]
    -V VERSION_ID       Version to install (e.g. current) [default: ${COREOS_VERSION_ID}]

    -b                  Build CoreOS ISO image, (default)
    -i                  Install CoreOS to the given VFAT partition, work with -D argument
    -d DEVICE/file.iso  Install CoreOS to a VFAT partition (e.g. /dev/sda1), or build the CoreOS ISO image
                        with given name,  [default: ${SCRIPT_DIR}/coreos_production_<VERSION>.iso]
    -L label            Volume Lable be use for output ISO or VFAT partition. [default: ${COREOS_VOL_LABEL}]
    -R label            local overlay storage for the writable root filesystem while continuing to boot 
                        (e.g. /dev/sda2 or LABEL=ROOT). [default: ${COREOS_ROOTFS_LABEL}]

    -a                  Enable coreos.autologin on boot
    -u cloud-config.yml Insert a cloud-init config to be executed on boot. [default: ${COREOS_CLOUD_CONFIG}]
    -o oem-config.yml   OEM config / packages (*.tar.gz) to install (to /usr/share/oem) [default: ${COREOS_OEM_CONFIG}]
    -U URL              URL for cloud-config to be executed on boot.

    -h                  Show myself ;-)
    -v                  Super verbose, for debugging.

This tools will create a CoreOS bootable ISO or installs CoreOS on a VFAT partition. but you also can use booted CoreOS
on a machine then use coreos-install to make a permanent install.
"

# CoreOS variables
COREOS_CHANNEL_ID="stable"
COREOS_VERSION_ID="current"
COREOS_CLOUD_CONFIG="${SCRIPT_DIR}/cloud-config.yml"
COREOS_OEM_CONFIG="${SCRIPT_DIR}/oem-config.yml"
COREOS_KERN_BASENAME="coreos_production_pxe.vmlinuz"
COREOS_INITRD_BASENAME="coreos_production_pxe_image.cpio.gz"
COREOS_BOOT_PARAM=""
COREOS_VOL_LABEL="COREOS"
COREOS_ROOTFS_LABEL="LABEL=ROOT"

# Syslinux Boot Manager variables
SYSLINUX_VERSION="6.03"
SYSLINUX_BASENAME="syslinux-${SYSLINUX_VERSION}"
SYSLINUX_BASE_URL="https://www.kernel.org/pub/linux/utils/boot/syslinux"
SYSLINUX_URL="${SYSLINUX_BASE_URL}/${SYSLINUX_BASENAME}.tar.gz"
SYSLINUX_BACKGROUND="splash.png"

# Extra utilities
MEMTEST_VERSION="5.01"
MEMTEST_BASE_URL="http://www.memtest.org/download"
PCIID_URL="http://pciids.sourceforge.net/v2.2/pci.ids"

## Functions -----------------------------------------------------------------

# download function with output
download() {

    local url="$1"
    local destin="$2"

    echo -n "   "
    if [ ! -z "${destin}" ]; then
        wget --progress=dot "${url}" -O  "${destin}" 2>&1 | grep --line-buffered "%" | \
        sed -u -e "s,\.,,g" | awk '{printf("\b\b\b\b%4s", $2)}'
    else
        wget --progress=dot "${url}" 2>&1 | grep --line-buffered "%" | \
        sed -u -e "s,\.,,g" | awk '{printf("\b\b\b\b%4s", $2)}'
    fi
    echo -ne "\b\b\b\b"
    echo "  done"

}

get_diskname() {

    local disk=${1#/dev/*}

    if [ -n "$disk" ]; then
        echo "/dev/$disk" | sed -e 's/^\([^0-9]*\)[0-9]*$/\1/g' \
                           -e 's/^\(.*[0-9]\{1,\}\)p[0-9]\{1,\}$/\1/g'
    fi

}

argument_check() {

    local destin="$1"
    local action="$2"

    if [ "${action}" == "INSTALL" ]; then

        # If the destination is not a disk device (e.g. /dev/sda1), exit.
        if [ "${destin#/dev/*}" == "${destin}" ]; then

            echo "${SCRIPT_NAME}: The destination ${destin} is not a disk device and should not allow for installation."
            echo "Program terminated!"
            echo "Try '${SCRIPT_NAME} -h' for more information."
            exit 1
        fi

        # Check if login by root 
        if [ ! "$UID" = "0" ]; then

            echo "${SCRIPT_NAME}: You need to run this script ${SCRIPT_NAME} as root."
            echo "Program terminated!"
            echo "Try '${SCRIPT_NAME} -h' for more information."
            echo ""
            echo "You can change to root user by running 'sudo -i' "
            exit 1

        fi

        # If the destination disk is not MBR partition table (e.g. GPT), exit. this program only works for MBR disk.
        if [ -z "$(LC_ALL=C sudo parted -s $(get_diskname ${destin}) print | grep -iE "^Partition Table:" | grep -iE "msdos")" ]; then

            echo "${SCRIPT_NAME}: The partition table of $(get_diskname ${destin}) is not for MBR (Master Boot Record)."
            echo "Program terminated!"
            echo "Try '${SCRIPT_NAME} -h' for more information."
            echo ""
            echo "Following procedure can be use to setup the disk partition ."
            echo ""
            echo "1. change to root user by running:  'sudo -i' "
            echo "2. You might need to use utility 'cfdisk -z /dev/xda' to partition. "
            echo "3. Execute command 'cat /boot/syslinux/mbr.bin > /dev/sda' to create MBR in the disk. "
            echo "4. format partition with command '/boot/syslinux/mkfs.vfat -n ${COREOS_VOL_LABEL} /dev/sda1' "
            echo "5. Install booting by command '/boot/syslinux/syslinux-4.05 -i -f /dev/sda1' "
            echo "6. execute the script to install the CoreOS. "
            exit 1

        fi

        # Check if destination partition is a FAT partition
        if [ -z "$(LC_ALL=C sudo blkid -c /dev/null ${destin} | grep -iE "fat")"  ]; then

            echo -n "${SCRIPT_NAME}: The partition ${destin}: "
            echo -n "$(LC_ALL=C sudo blkid -c /dev/null ${destin} | grep -o -E '\<TYPE="[^[:space:]]*"($|[[:space:]]+)')"
            echo -n "doesn't look like a valid FAT or vFAT file system."
            echo "Program terminated!"
            echo "Try '${SCRIPT_NAME} -h' for more information."
            echo ""
            echo "Following procedure can be use to setup the disk partition ."
            echo ""
            echo "1. change to root user by running:  'sudo -i' "
            echo "2. You might need to use utility 'cfdisk -z /dev/xda' to partition. "
            echo "3. Execute command 'cat /boot/syslinux/mbr.bin > /dev/sda' to create MBR in the disk. "
            echo "4. format partition with command '/boot/syslinux/mkfs.vfat -n ${COREOS_VOL_LABEL} /dev/sda1' "
            echo "5. Install booting by command '/boot/syslinux/syslinux-4.05 -i -f /dev/sda1' "
            echo "6. execute the script to install the CoreOS. "
            exit 1

        fi

        # Check if destination folder is writable

        if [ ! -w "${SCRIPT_DIR}" ] && [ ! -w "/tmp" ]; then

            echo "There is no temporary folder for mounting destination partition. "
            echo "Program terminated!"
            echo "Try '${SCRIPT_NAME} -h' for more information."
            exit 1

        fi

    elif [ "${action}" == "BUILD" ]; then

        # If the destination is not a disk device (e.g. /dev/sda1), exit.
        if [ ! "${destin#/dev/*}" == "${destin}" ]; then

            echo "${SCRIPT_NAME}: The destination ${destin} is a disk device and should not allow for building ISO image."
            echo "Program terminated!"
            echo "Try '${SCRIPT_NAME} -h' for more information."
            exit 1

        fi

        # Check the destination folder is writable
        if [ ! -w $(dirname "${destin}") ]; then

            echo "${SCRIPT_NAME}: The destination $(dirname "${destin}") is not writable. "
            echo "Program terminated!"
            echo "Try '${SCRIPT_NAME} -h' for more information."
            exit 1

        fi

         return 0

    fi

}


# Build work directory and download required packages
prepare_coreos() {

    local destin="$1"
    local action="$2"
    local cloudcfg="$3"
    local oemcfg="$4"

    # Creating working directory
    echo -n "--> Creating work directory in $(dirname $destin)... "
    mkdir -p "${destin}/coreos"
    mkdir -p "${destin}/memtest"
    mkdir -p "${destin}/syslinux"
    echo "  done"

    if [ "${action}" == "BUILD" ]; then

        echo -n "--> Downloading syslinux ${SYSLINUX_URL} ... "
        mkdir -p "${destin}/source"
        download "${SYSLINUX_BASE_URL}/${SYSLINUX_BASENAME}.tar.gz" "${destin}/source/${SYSLINUX_BASENAME}.tar.gz"
        tar zxf "${destin}/source/${SYSLINUX_BASENAME}.tar.gz" -C "${destin}/source"
        rm -f "${destin}/source/${SYSLINUX_BASENAME}.tar.gz"

        # copying syslinux packages from latest build
        echo -n "--> Copying syslinux packages from latest build ... "
        cp "${destin}/source/${SYSLINUX_BASENAME}"/bios/memdisk/memdisk "${destin}/syslinux"
        cp "${destin}/source/${SYSLINUX_BASENAME}"/bios/core/isolinux.bin "${destin}/syslinux"
        cp "${destin}/source/${SYSLINUX_BASENAME}"/bios/core/ldlinux.* "${destin}/syslinux"
        cp "${destin}/source/${SYSLINUX_BASENAME}"/bios/core/pxelinux.* "${destin}/syslinux"
        cp "${destin}/source/${SYSLINUX_BASENAME}"/bios/mbr/mbr.bin "${destin}/syslinux"
        cp "${destin}/source/${SYSLINUX_BASENAME}"/bios/com32/chain/*.c32 "${destin}/syslinux"
        cp "${destin}/source/${SYSLINUX_BASENAME}"/bios/com32/lib/*.c32 "${destin}/syslinux"
        cp "${destin}/source/${SYSLINUX_BASENAME}"/bios/com32/libutil/*.c32 "${destin}/syslinux"
        cp "${destin}/source/${SYSLINUX_BASENAME}"/bios/com32/elflink/ldlinux/ldlinux.c32 "${destin}/syslinux"
        cp "${destin}/source/${SYSLINUX_BASENAME}"/bios/com32/gpllib/*.c32 "${destin}/syslinux"
        cp "${destin}/source/${SYSLINUX_BASENAME}"/bios/com32/menu/*.c32 "${destin}/syslinux"
        cp "${destin}/source/${SYSLINUX_BASENAME}"/bios/com32/cmenu/complex.c32 "${destin}/syslinux"
        cp "${destin}/source/${SYSLINUX_BASENAME}"/bios/com32/cmenu/display.c32 "${destin}/syslinux"
        cp "${destin}/source/${SYSLINUX_BASENAME}"/bios/com32/cmenu/libmenu/*.c32 "${destin}/syslinux"
        cp "${destin}/source/${SYSLINUX_BASENAME}"/bios/com32/gfxboot/*.c32 "${destin}/syslinux"
        cp "${destin}/source/${SYSLINUX_BASENAME}"/bios/com32/hdt/*.c32 "${destin}/syslinux"
        cp "${destin}/source/${SYSLINUX_BASENAME}"/bios/com32/lua/src/*.c32 "${destin}/syslinux"
        cp "${destin}/source/${SYSLINUX_BASENAME}"/bios/com32/mboot/*.c32 "${destin}/syslinux"
        cp "${destin}/source/${SYSLINUX_BASENAME}"/bios/com32/modules/*.c32 "${destin}/syslinux"
        cp "${destin}/source/${SYSLINUX_BASENAME}"/bios/com32/rosh/*.c32 "${destin}/syslinux"
        cp "${destin}/source/${SYSLINUX_BASENAME}"/bios/com32/sysdump/*.c32 "${destin}/syslinux"
        echo "  done"

        # Extracting additional syslinux utilities.
        echo -n "--> Extracting additional Syslinux utilities ... "
        mkdir -p "${destin}/source/utility"
        tar zxf "${SCRIPT_DIR}/syslinux.tar.gz" -C  "${destin}/source/utility"
        cp "${destin}/source/utility/mcopy" "${destin}/syslinux"
        cp "${destin}/source/utility/mtools" "${destin}/syslinux"
        cp "${destin}/source/utility/mattrib" "${destin}/syslinux"
        cp "${destin}/source/utility/mkfs.vfat" "${destin}/syslinux"
        cp "${destin}/source/utility/mkfs.ntfs" "${destin}/syslinux"
        cp "${destin}/source/utility/cpio" "${destin}/syslinux"
        cp "${destin}/source/utility/syslinux-6.03" "${destin}/syslinux/syslinux-6.03"
        cp "${destin}/source/utility/syslinux-4.05" "${destin}/syslinux/syslinux-4.05"
        cp "${destin}/source/utility/menu-4.05.c32" "${destin}/syslinux/menu-4.05.c32"
        cp "${destin}/source/utility/vesamenu-4.05.c32" "${destin}/syslinux/vesamenu-4.05.c32"
        cp "${destin}/source/utility/hdt-4.05.c32" "${destin}/syslinux/hdt-4.05.c32"
        cp "${destin}/source/utility/reboot-4.05.c32" "${destin}/syslinux/reboot-4.05.c32"
        echo "  done"

        # Downloading hardware Detection Tool
        echo -n "--> Downloading Hardware Detection Tool (PCIID) ... "
        download "${PCIID_URL}" "${destin}/syslinux/pci.ids"

        # Download Memtest.
        echo -n "--> Downloading memtest ... "
        download "${MEMTEST_BASE_URL}/${MEMTEST_VERSION}/memtest86+-${MEMTEST_VERSION}.bin.gz" "${destin}/source/memtest86+-${MEMTEST_VERSION}.bin.gz"
        gzip -d --stdout "${destin}/source/memtest86+-${MEMTEST_VERSION}.bin.gz" > "${destin}/memtest/memtest.bin"

        # Remove source folder
        rm -rf "${destin}/source"

        # CoreOS PXE images USR-A
        echo -n "--> Downloading CoreOS's kernel (vminuz) ... "
        download "${COREOS_BASE_URL}/${COREOS_VERSION_ID}/${COREOS_KERN_BASENAME}" "${destin}/coreos/vmlinuz-a"
        echo -n "--> Downloading CoreOS's initrd (cpio.gz) ... "
        download "${COREOS_BASE_URL}/${COREOS_VERSION_ID}/${COREOS_INITRD_BASENAME}" "${destin}/coreos/cpio-a.gz"


    elif [ ${action} == "INSTALL" ]; then

        echo -n "--> Copying Syslinux Packages ... "
        cp ${SCRIPT_DIR}/syslinux/* ${destin}/syslinux

        # using vesamenu 4.05
        mv "${destin}/syslinux/vesamenu.c32" "${destin}/syslinux/vesamenu-6.03.c32"
        mv "${destin}/syslinux/menu.c32" "${destin}/syslinux/menu-6.03.c32"
        cp -a "${SCRIPT_DIR}/syslinux/vesamenu-4.05.c32" "${destin}/syslinux/vesamenu.c32"
        cp -a "${SCRIPT_DIR}/syslinux/menu-4.05.c32" "${destin}/syslinux/menu.c32"
        cp -a "${SCRIPT_DIR}/syslinux/hdt-4.05.c32" "${destin}/syslinux/hdt.c32"
        cp -a "${SCRIPT_DIR}/syslinux/reboot-4.05.c32" "${destin}/syslinux/reboot.c32"
        echo "  done"

        echo -n "--> Copying memtest ... "
        cp -a "${SCRIPT_DIR}/memtest/memtest.bin" "${destin}/memtest/memtest.bin"
        echo "  done"

        # CoreOS PXE images USR-A
        echo -n "--> Copying CoreOS's kernel (vminuz) ... "
        cp -a "${SCRIPT_DIR}/coreos/vmlinuz-a" "${destin}/coreos/vmlinuz-a"
        echo "  done"
        echo -n "--> Copying CoreOS's initrd (cpio.gz) ... "
        cp -a "${SCRIPT_DIR}/coreos/cpio-a.gz" "${destin}/coreos/cpio-a.gz"
        echo "  done"

    fi

    # copy script into destination
    cp -a "${SCRIPT_DIR}/${SCRIPT_NAME}" "${destin}"
    cp -a "${cloudcfg}" "${destin}"
    cp -a "${oemcfg}" "${destin}"

}

prepare_sysmenu() {

    local destin="$1"
    local action="$2"

    # Create syslinux configuration file ...
    echo -n "--> Create syslinux configuration (menu) file ... "
    cat <<EOF > "${destin}/syslinux/syslinux.cfg"
PROMPT 3
TIMEOUT 30
ONTIMEOUT USR-A
DEFAULT USR-A

UI vesamenu.c32

MENU TITLE "CoreOS Live Boot Menu"

MENU WIDTH              78
MENU MARGIN             4
MENU ROWS               6
MENU VSHIFT             5
MENU TABMSGROW          16
MENU CMDLINEROW         16
MENU HELPMSGROW         22
MENU HELPMSGENDROW      29

MENU BACKGROUND ${SYSLINUX_BACKGROUND}

MENU COLOR border       37;44   #40ffffff #a0000000 std
MENU COLOR title        1;37;44 #9033ccff #a0000000 std
MENU COLOR sel          7;37;40 #e0ffffff #20ffffff all
MENU COLOR unsel        37;40   #50ffffff #a0000000 std
MENU COLOR help         37;40   #c0ffffff #a0000000 std
MENU COLOR timeout_msg  37;40   #80ffffff #00000000 std
MENU COLOR timeout      1;37;40 #c0ffffff #00000000 std
MENU COLOR msg07        37;40   #90ffffff #a0000000 std
MENU COLOR tabmsg       31;40   #30ffffff #00000000 std

LABEL USR-A
    MENU LABEL CoreOS USR-A
    KERNEL /coreos/vmlinuz-a
    APPEND initrd=/coreos/cpio-a.gz
    TEXT HELP
USR-A Active / passtive Partition (Kernal and initrd) Holding CoreOS

CoreOS is Linux distribution designed for security, consistency,
and reliability.rearchitected to provide features to run modern
infrastructure stacks.
    ENDTEXT

EOF

if [ ${action} == "INSTALL" ]; then

    cat <<EOF >> "${destin}/syslinux/syslinux.cfg"
LABEL USR-B
    MENU LABEL CoreOS USR-B
    KERNEL /coreos/vmlinuz-b
    APPEND initrd=/coreos/cpio-b.gz
    TEXT HELP
USR-B Active / passtive Partition (Kernal and initrd) Holding CoreOS

CoreOS is Linux distribution designed for security, consistency,
and reliability.rearchitected to provide features to run modern
infrastructure stacks.
    ENDTEXT
EOF

elif [ ${action} == "BUILD" ]; then

    cat <<EOF >> "${destin}/syslinux/syslinux.cfg"
LABEL bootlocal
    MENU LABEL Boot first BIOS disk
    localboot 0x80
    TEXT HELP
Boot the operating system from the first bios disk.
    ENDTEXT
EOF

fi

cat <<EOF >> "${destin}/syslinux/syslinux.cfg"

LABEL HDT
    MENU LABEL Hardware Detection Tool
    COM32 hdt.c32
    APPEND pciids=pci.ids
    TEXT HELP
HDT (Hardware Detection Tool) displays hardware low-level information.
    ENDTEXT

LABEL memtest
    MENU LABEL Memtest86+
    LINUX ../memtest/memtest.bin
    TEXT HELP
Memtest86+ checks RAM for errors by doing stress tests operations.
    ENDTEXT

LABEL reboot
    MENU LABEL Reboot
    COM32 reboot.c32

LABEL poweroff
    MENU LABEL Power Off
    COM32 poweroff.c32

EOF

    echo "  done"

}

parepare_cloudconfig() {

    local destin="$1"
    local cloudcfg="$(basename $2)"
    local oemcfg="$(basename $3)"
    local diskvol="$4"

    mkdir -p "${destin}/coreos/usr/share/oem"

    if [ -f "${SCRIPT_DIR}/oem.tar.gz" ]; then
        echo -n "--> Copying OEM Pack into place ... "
        tar zxf "${SCRIPT_DIR}/oem.tar.gz" -C "${destin}/coreos/usr/share/oem"
        echo "  done"
    fi

    # Update label and oem config file name in oem cloud-config.yml
    sed "s/_===TAG===_/${diskvol}/g;s/_===CONFIG===_/${cloudcfg}/g" \
        "${oemcfg}" > "${destin}/coreos/usr/share/oem/cloud-config.yml"

    pushd "${destin}/coreos" >> /dev/null

        echo -n "--> Integrating OEM configuration for reading cloud-config from source disk ... "
        gzip -d cpio-a.gz && find usr | cpio --quiet -o -A -H newc -O cpio-a && gzip cpio-a
        echo "  done"

    popd >> /dev/null

    rm -rf ${destin}/coreos/usr

}

# building ISO image
build_iso() {

    local destin="$1"
    local label="$2"
    local output="$3"

    echo -n "--> Making ISO image $(basename ${output}) ... "
    cd "${destin}"
    mkisofs -V "${label}" -quiet -l -r -J -input-charset utf-8 -o "${output}" \
            -b syslinux/isolinux.bin -c syslinux/boot.cat \
            -no-emul-boot -boot-load-size 4 -boot-info-table .
    echo "  done"

}


## Main -----------------------------------------------------------------------

# passed to getopt using -o option for short options
# Each single character stands for an option.
# A : [colon character] tells that the option has a required argument
# A :: tells that the option has an optional argument
# Example:
# the option string f:gh::i: means that there are four options,
# f has a required argument, g has no argument, h has an optional and i has a required argument
while getopts "C:V:bid:L:R:au:o:U:hv" OPTION
do
    case $OPTION in
        C) COREOS_CHANNEL_ID="${OPTARG}" ;;
        V) COREOS_VERSION_ID="${OPTARG}" ;;
        b) SCRIPT_ACTION="BUILD" ;;
        i) SCRIPT_ACTION="INSTALL" ;;
        d) SCRIPT_OUTPUT="${OPTARG}" ;;
        L) COREOS_VOL_LABEL="${OPTARG}" ;;
        R) COREOS_ROOTFS_LABEL="${OPTARG}" ;;
        a) COREOS_BOOT_PARAM="${COREOS_BOOT_PARAMS} coreos.autologin" ;;
        u) COREOS_CLOUD_CONFIG="${OPTARG}" ;;
        o) COREOS_OEM_CONFIG="${OPTARG}" ;;
        U) COREOS_CLOUD_URL="${OPTARG}" ;;
        h) echo "${SCRIPT_USAGE}"; exit;;
        v) set -x ;;
        *) echo "${SCRIPT_USAGE}"; exit;;
    esac
done

# Update URL with inputed arguments
COREOS_BASE_URL="http://${COREOS_CHANNEL_ID}.release.core-os.net/amd64-usr"
[ -z "${SCRIPT_OUTPUT}" ] && SCRIPT_OUTPUT="${SCRIPT_DIR}/coreos_production_${COREOS_VERSION_ID}.iso"

# Check argument.
if [ ! -f "${COREOS_CLOUD_CONFIG}" ] || [ ! -f "${COREOS_OEM_CONFIG}" ]; then

    echo "${SCRIPT_NAME}: The ${COREOS_CLOUD_CONFIG} or ${COREOS_OEM_CONFIG} doesn't exist in ${SCRIPT_DIR}."
    echo "Please check the files before run the script."
    echo "Program terminated!"
    echo "Try '${SCRIPT_NAME} -h' for more information."
    exit 1

fi

# Check output
argument_check "${SCRIPT_OUTPUT}" "${SCRIPT_ACTION}"

if [ "${SCRIPT_ACTION}" == "BUILD" ]; then

    if wget --inet4-only --spider --quiet "${COREOS_BASE_URL}/${COREOS_VERSION_ID}/version.txt"; then

        WORK_DIR="${SCRIPT_OUTPUT%.*}_$$"
        mkdir -p ${WORK_DIR}
        echo -n "-->Retrieving CoreOS version.txt from ${COREOS_BASE_URL}/${COREOS_VERSION_ID} ... "
        download "${COREOS_BASE_URL}/${COREOS_VERSION_ID}/version.txt" "${WORK_DIR}/version.txt"

    else

        echo "${SCRIPT_NAME}: The ${COREOS_VERSION_ID} doesn't exist in ${COREOS_BASE_URL}."
        echo "Program terminated!"
        echo "Try '${SCRIPT_NAME} -h' for more information."
        exit 1

    fi

    # Preparing work directory and copy required files in place.
    prepare_coreos "${WORK_DIR}" "${SCRIPT_ACTION}" "${COREOS_CLOUD_CONFIG}" "${COREOS_OEM_CONFIG}"

    # Preparing syslinux booting menu
    prepare_sysmenu "${WORK_DIR}" "${SCRIPT_ACTION}"

    # Packing OEM cloud-config into CoreOS image
    parepare_cloudconfig "${WORK_DIR}" "${COREOS_CLOUD_CONFIG}" "${COREOS_OEM_CONFIG}" "${COREOS_VOL_LABEL}"

    # Retreive the version information from version.txt
    COREOS_VERSION_ID=$(cat "${WORK_DIR}/version.txt" | grep -iE "VERSION_ID" | awk '{split($0,a,"="); print a[2]}')

    if [ ! -z $(echo ${SCRIPT_OUTPUT} | grep -iE "coreos_production_current" ) ]; then
        SCRIPT_OUTPUT="${SCRIPT_DIR}/coreos_production_${COREOS_VERSION_ID}.iso"
    fi

    # Building ISO image
    build_iso "${WORK_DIR}" "${COREOS_VOL_LABEL}" "${SCRIPT_OUTPUT}"

    rm -rf  "${WORK_DIR}"

    echo "image ${SCRIPT_OUTPUT} has be build, you can use this to boot the machine ... "

elif [ "${SCRIPT_ACTION}" == "INSTALL" ]; then

    if [ -w "${SCRIPT_DIR}" ]; then
        WORK_DIR="${SCRIPT_DIR}/coreos_production_${COREOS_VERSION_ID}_$$"
    elif [ -w "/tmp" ]; then
        WORK_DIR="/tmp/coreos_production_${COREOS_VERSION_ID}_$$"
    fi

    if [ -f "${SCRIPT_DIR}/version.txt" ]; then

        mkdir -p ${WORK_DIR}
        mount -o rw ${SCRIPT_OUTPUT} ${WORK_DIR}

        echo -n "--> Copying CoreOS version.txt from ${SCRIPT_DIR} ."
        cp -a "${SCRIPT_DIR}/version.txt" "${WORK_DIR}/version.txt"
        echo "  done"

    fi

    # Preparing work directory and copy required files in place.
    prepare_coreos "${WORK_DIR}" "${SCRIPT_ACTION}" "${COREOS_CLOUD_CONFIG}" "${COREOS_OEM_CONFIG}"

    # Preparing syslinux booting menu
    prepare_sysmenu "${WORK_DIR}" "${SCRIPT_ACTION}"

    # Create booting record
    echo -n "--> Creating boot record to ${SCRIPT_OUTPUT} ... "
    pushd ${WORK_DIR}/syslinux > /dev/null

	    cat mbr.bin > $(get_diskname ${SCRIPT_OUTPUT})
	    ./syslinux-4.05 -f -i ${SCRIPT_OUTPUT}

    popd > /dev/null
    echo "  done"

    umount ${WORK_DIR}
    
    echo "Installation is successful, please eject the CD and reboot the machine ..."

fi
