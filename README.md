# coreos-builder

This is a small utility to create CoreOS images ready to boot from a CD or a USB device. Also you can use it to install the CoreOS OS into a VFAT partition instead of standard CoreOS disk layout.

In the script, it will create a working directory and download the latest CoreOS PXE images with all the required components inside (syslinux, memtest and Hardware detector etc.) and a cloud-config.yml which you can edit after installing to local storage. to fit your requirement.

Default is to create a ISO image which can be dumped into a USB device or burned onto a CD, but in this case, you will no be able to edit the cloud-config configuration file.



```
Usage: $0 [-V version] [-D /dev/device]
Options:
    -C CHANNEL          Release channel to use (e.g. beta, alpha, stable) [default: stable ]
    -V VERSION_ID       Version to install (e.g. current) [default: current ]

    -b                  Build CoreOS ISO image, (default)
    -i                  Install CoreOS to the given VFAT partition, work with -D argument
    -d DEVICE/file.iso  Install CoreOS to a VFAT partition (e.g. /dev/sda1), or build the CoreOS ISO image
                        with given name,  [default:coreos_production_<VERSION>.iso]
    -L label            Volume Lable be use for output ISO or VFAT partition. [default: COREOS ]
    -R label            local overlay storage for the writable root filesystem while continuing to boot 
                        (e.g. /dev/sda2 or LABEL=ROOT). [default: ROOT]

    -a                  Enable coreos.autologin on boot
    -u cloud-config.yml Insert a cloud-init config to be executed on boot. [default: cloud-config.yml]
    -o oem-config.yml   OEM config to build (to /usr/share/oem) [default: oem-config.yml ]
    -U URL              URL for cloud-config to be executed on boot.

    -h                  Show myself ;-)
    -v                  Super verbose, for debugging.
```
