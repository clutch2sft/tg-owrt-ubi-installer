The bundle_initrd recovery invocation is part of a function called bundle_initrd within the script, which handles preparing the initial ramdisk (initrd) for the OpenWrt firmware image. The recovery argument specifies the mode in which the function operates, meaning it is preparing a recovery image. Here's a detailed step-by-step breakdown of what this function does when invoked with the recovery argument:

Unpack the FIT Image: It calls unfit_image with the path to an OpenWrt initramfs recovery image (.itb file). This extracts the image components into a working directory and converts it to a device tree source (DTS) format using the dtc command.

Extract the Initial Ramdisk: It then checks for the existence of the initial ramdisk within the extracted image and, if found, decompresses it into a directory structure. This is done using the xz command to decompress and cpio to extract the file system.

Package Management:

Remove Packages: If there are packages listed to be removed (specified by the OPENWRT_REMOVE_PACKAGES array), it uses the opkg command to remove them from the extracted initrd. This step is done within the chroot environment of the initrd, meaning it's as if the commands are being run on the actual system that the initrd represents.
Update Package Lists: It then updates the package lists using opkg update, which ensures that the package database within the initrd is up-to-date.
Add Packages: If there are additional packages to be added (specified by the OPENWRT_ADD_PACKAGES array), they are installed using opkg as well.
Special Handling for Recovery Images:

If additional packages specific to recovery mode are defined in OPENWRT_ADD_REC_PACKAGES, these are also installed into the initrd.
Modify Installed Packages List: It modifies the timestamp in the status file of the opkg package management system to match SOURCE_DATE_EPOCH, ensuring reproducibility of the build.

Enable Services: It calls enable_services to enable all init scripts found in /etc/init.d within the initrd, ensuring that necessary services will start when the system boots.

Clean Temporary Files: It removes any temporary files that might have been created during the process.

Normalize File Timestamps: It runs a find command to update the timestamps of all files in the initrd to SOURCE_DATE_EPOCH. This helps in achieving reproducible builds by ensuring that all files have the same timestamp regardless of when they were actually modified or created.

Repack the Initial Ramdisk: The modified initrd file system is then repacked into a compressed image using cpio and xz. The --reproducible flag is used with cpio to ensure that the repacked initrd will be the same every time the script is run with the same inputs.

Recreate the FIT Image: Finally, it calls refit_image to create a new FIT image from the modified ITS file, which now includes the modified initrd. If the recovery argument is passed, it also defines a specific block size for the image.

In summary, the bundle_initrd recovery command alters the initial ramdisk of a recovery image by potentially adding or removing packages, enabling services, normalizing file timestamps, and repacking it into a new FIT image ready for use in a recovery scenario.

[[ ${#OPENWRT_REMOVE_PACKAGES[@]} -gt 0 ]] && IPKG_NO_SCRIPT=1 IPKG_INSTROOT="${WORKDIR}/initrd" \
		"${OPKG}" --offline-root="${WORKDIR}/initrd" -f "${WORKDIR}/initrd/etc/opkg.conf" \
		remove "${OPENWRT_REMOVE_PACKAGES[@]}"

Explained:

This command is a conditional command using Bash's [[ ]] test syntax and the logical AND && operator. It checks a condition and executes a command if that condition is true. Let's break it down:

Condition Check:
* [[ ${#OPENWRT_REMOVE_PACKAGES[@]} -gt 0 ]]

* [[ ... ]] is the test command, which allows you to perform comparisons and test file attributes.
* ${#OPENWRT_REMOVE_PACKAGES[@]} gets the count of elements in the array OPENWRT_REMOVE_PACKAGES.
* -gt 0 checks if the number is greater than zero. This part of the command checks if there are any elements in the OPENWRT_REMOVE_PACKAGES array. If the array has one or more elements, it means there are packages specified for removal.

Command Execution:
If the condition is true (i.e., if there are packages to remove), the following command is executed:

IPKG_NO_SCRIPT=1 IPKG_INSTROOT="${WORKDIR}/initrd" "${OPKG}" --offline-root="${WORKDIR}/initrd" -f "${WORKDIR}/initrd/etc/opkg.conf" remove "${OPENWRT_REMOVE_PACKAGES[@]}"

This is a single command with a couple of environment variable assignments and arguments passed to the opkg command:

* IPKG_NO_SCRIPT=1: This sets an environment variable that tells opkg not to run any package scripts (like post-installation scripts). It is a way to modify the behavior of opkg for this command invocation.

* IPKG_INSTROOT="${WORKDIR}/initrd": This sets the environment variable IPKG_INSTROOT to the path where the initial ramdisk is located. It tells opkg to treat this directory as its root for the installation process, which is necessary when modifying an image or chroot environment instead of the currently running system.

* "${OPKG}": This is the variable holding the path to the opkg binary that will be executed.
--offline-root="${WORKDIR}/initrd": This opkg option specifies the root directory for offline operations. It is similar to the IPKG_INSTROOT environment variable and is used for the same purpose.

* -f "${WORKDIR}/initrd/etc/opkg.conf": This tells opkg to use the specified configuration file instead of the default one. This is important when working in a chroot or alternative root directory because it will contain the correct settings for that environment.

* remove "${OPENWRT_REMOVE_PACKAGES[@]}": This is the opkg command to remove packages. The remove subcommand is followed by the array of package names to be removed. The array is expanded so that each element becomes a separate argument to the remove command.

The entire command sequence is meant to conditionally remove a list of packages from a root filesystem represented by an initial ramdisk (initrd), which is typically used for things like firmware recovery or installation environments.


dtc stands for Device Tree Compiler. It's a tool used in the Linux kernel development process and is relevant for systems that use a device tree, which is a data structure for describing the hardware components of a system without the need for probing the hardware or hard-coding hardware information into the kernel.

Here are some key points about dtc:

Device Tree Source: dtc compiles device tree source files (DTS), which are human-readable descriptions of the hardware, into binary device tree blob files (DTB) which the kernel can read.

Hardware Abstraction: Device trees are particularly important in the embedded world, such as with ARM or PowerPC architectures, where they abstract the hardware configuration away from the kernel. This means the same kernel binary can run on different hardware configurations without modification.

Compilation and Decompilation: dtc can also decompile DTB files back into DTS files, allowing developers to examine and modify the hardware description.

Flattened Image Trees (FIT): dtc is also used in the creation of Flattened Image Trees, which are structures that can contain the kernel, device tree blobs, and other information in a single binary image. This is particularly used in bootloaders like U-Boot.

Kernel Integration: Typically, dtc is included with the Linux kernel sources in the scripts/dtc/ directory, and it can be compiled along with the kernel.

Boot Process: During the boot process, the bootloader passes the DTB to the kernel. The kernel uses the information to initialize drivers and hardware.

Linux Source Tree: If you have the Linux kernel source, you can usually find device tree files in the arch/<architecture>/boot/dts/ directory, where <architecture> is the target architecture (e.g., arm, powerpc, etc.).

In the context of the script you provided, dtc is used to interact with these device tree structures as part of the process of preparing a firmware image for OpenWrt, which is a Linux distribution for embedded devices.


The `unfit` utility extracts images (like kernels, ramdisks, etc.) from a Flat Image Tree (FIT) image. FIT images are a custom format used by U-Boot, which is a popular bootloader for embedded devices. Here's a walkthrough of the code:

1. The `#define` preprocessor directives set up constants for various property names that will be used to find data within the FIT image.

2. `write_file` function:
   - Takes an image name, a pointer to the image data, and the length of the image data.
   - It opens the file (creating it if it doesn't exist), writes the image data to it, and then closes the file.

3. `main` function:
   - Checks for the correct number of arguments. It expects at least the FIT image file path and optionally a specific image name to extract.
   - Opens the FIT image file and uses `fstat` to obtain the file size.
   - Maps the file into memory using `mmap`.
   - Checks if the mapped file has a valid FIT header with `fdt_check_header`.
   - Ensures that the total FIT size is not larger than the actual file size.
   - Looks for the `/images` node within the FIT image, which contains the different image entries.
   - Iterates over each subnode (image) within the `/images` node:
     - Retrieves the image name and type.
     - Retrieves the properties like data offset, position, and length, converting them from big-endian to host byte order.
     - Determines the location of the image data within the FIT image. If `data` property is present, it uses that; otherwise, it calculates the location based on the `data-offset` or `data-position` properties.
     - If an image description is available, it retrieves that as well.
     - If a specific image name was given as an argument, it only writes the file for that image; otherwise, it writes files for all images.
     - Prints out information about each sub-image found.

4. Cleanup:
   - Unmaps the memory-mapped file.
   - Closes the file descriptor.

This utility can be used in scenarios where you need to extract specific components from a FIT image, such as during the process of firmware development or modification. The `fdt_*` family of functions come from the libfdt library, which is a utility for manipulating device tree blobs, commonly used in embedded systems for storing hardware configuration.