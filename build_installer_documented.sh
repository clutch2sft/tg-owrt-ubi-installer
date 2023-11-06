#!/bin/bash -x
set -o errexit
set -o nounset
set -o pipefail

DESTDIR="$PWD"

OPENWRT_PGP="0xCD54E82DADB3684D"
KEYSERVER="keyserver.ubuntu.com"
INSTALLERDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
OPENWRT_DIR="${INSTALLERDIR}/openwrt-ib"

CPIO="${OPENWRT_DIR}/staging_dir/host/bin/cpio"
MKIMAGE="${OPENWRT_DIR}/staging_dir/host/bin/mkimage"
OPKG="${OPENWRT_DIR}/staging_dir/host/bin/opkg"
XZ="${OPENWRT_DIR}/staging_dir/host/bin/xz"
#Location and Compilation:
#UNFIT is expected to be located in the INSTALLERDIR directory.
#If unfit is not found or is not executable ([ -x "$UNFIT" ]), the script attempts to compile it from source.
#Building from Source:
#The script changes the directory to ${INSTALLERDIR}/src (which is assumed to contain the source code of unfit) 
#and uses cmake to prepare the build environment and then make all to compile the unfit tool.
#After successful compilation, the binary is copied to the parent directory (cp unfit ..), which would be INSTALLERDIR.
#The error message suggests that gcc (the GNU Compiler Collection) and libfdt-dev (the development files for 
#the Flat Device Tree library) must be installed to compile unfit. This indicates that unfit is a C/C++ 
#program that relies on libfdt for device tree manipulation.
UNFIT="${INSTALLERDIR}/unfit"
[ -x "$UNFIT" ] || ( cd "${INSTALLERDIR}/src" ; cmake . ; make all ; cp unfit .. ) || {
	echo "can't build unfit. please install gcc and libfdt-dev"
	exit 0
}


SOURCE_DATE_EPOCH=$(git log -1 --pretty=%ct -C "${INSTALLERDIR}")
DTC=
FILEBASE=
WORKDIR=
ITSFILE=


prepare_openwrt_ib() {
	#GNUPGHOME is set to a new temporary directory created by mktemp -d, which is meant to hold 
	#GPG (GNU Privacy Guard) related files, such as keyrings.
	GNUPGHOME="$(mktemp -d)"
	#export GNUPGHOME makes this directory known to GPG as the home directory.
	export GNUPGHOME
	#ensures that this temporary directory is deleted when the script exits.
	trap 'rm -rf -- "${GNUPGHOME}"' EXIT
	#ensures that a directory for downloading files exists.
	mkdir -p "${INSTALLERDIR}/dl"
	#changes the current working directory to this download directory.
	cd "${INSTALLERDIR}/dl"
	#The script checks if the OpenWrt PGP key exists in the custom keyring (openwrt-keyring). 
	#If not, it attempts to download the key from a keyserver.
	#If the key still can't be found after attempting to download it, the script exits with status 0.
	gpg --no-default-keyring --keyring "${INSTALLERDIR}/openwrt-keyring" --list-key $OPENWRT_PGP 1>/dev/null 2>/dev/null || gpg --no-default-keyring --keyring "${INSTALLERDIR}/openwrt-keyring" --keyserver ${KEYSERVER}	--recv-key $OPENWRT_PGP
	gpg --no-default-keyring --keyring "${INSTALLERDIR}/openwrt-keyring" --list-key $OPENWRT_PGP 1>/dev/null 2>/dev/null || exit 0
	#The script removes any existing checksum files (sha256sums.asc and sha256sums).
	rm -f "sha256sums.asc" "sha256sums"
	#It then downloads new checksum files from the OpenWrt target directory using wget
	wget "${OPENWRT_TARGET}/sha256sums.asc"
	wget "${OPENWRT_TARGET}/sha256sums"
	#GPG is used to verify the signature of the checksums file. If the verification fails, the script 
	#exits with status 1.
	gpg --no-default-keyring --keyring "${INSTALLERDIR}/openwrt-keyring" --verify sha256sums.asc sha256sums || exit 1
	#clears the previously set trap for the EXIT signal, and the script manually removes the 
	#GNUPGHOME directory and unsets the GNUPGHOME environment variable.
	trap - EXIT
	rm -rf -- "${GNUPGHOME}"
	export -n GNUPGHOME
	#The sha256sum command checks any existing files against the checksums. If there's a mismatch, it removes 
	#the potentially corrupted files.
	sha256sum -c sha256sums --ignore-missing || rm -f "$OPENWRT_SYSUPGRADE" "$OPENWRT_IB" "$OPENWRT_INITRD"
	#The script uses wget -c to continue incomplete downloads (if any) of the OpenWrt Image Builder, the 
	#sysupgrade file, and the initial ramdisk file from the OpenWrt target directory.
	# The wget -c command is used to continue downloads that were interrupted. If the files were partially 
	#downloaded before, this command would pick up where it left off. If the files are not present at all, 
	#wget -c functions the same as wget alone

	#This is typically an initial RAM disk image. An initrd is a temporary root file system loaded into memory as part of the 
	#Linux boot process. On OpenWRT, this might be used for recovery or initial setup purposes, as it would allow the system 
	#to boot and operate without accessing the flash memory or the main storage.
	wget -c "${OPENWRT_TARGET}/${OPENWRT_INITRD}"
	#The system upgrade image. In OpenWRT, a sysupgrade file is used to upgrade the router's firmware 
	#while preserving the configuration files. It's the image you would use when updating your OpenWRT installation to a 
	#new version without starting from scratch.
	wget -c "${OPENWRT_TARGET}/${OPENWRT_SYSUPGRADE}"
	#This stands for Image Builder. The OpenWRT Image Builder allows users to create custom images with specific packages 
	#installed without having to build the entire OpenWRT build environment and compile everything from source. It's a tool 
	#for advanced users who want to customize their firmware before flashing it to their devices.
	wget -c "${OPENWRT_TARGET}/${OPENWRT_IB}"
	#After verifying that the downloaded files are correct, the script creates a directory for the 
	#OpenWrt Image Builder if it does not already exist.
	sha256sum -c sha256sums --ignore-missing || exit 1
	mkdir -p "${OPENWRT_DIR}" || exit 1
	#It then extracts the Image Builder tarball to this directory, stripping the leading directory component 
	#from the tarball paths.
	tar -xJf "${INSTALLERDIR}/dl/${OPENWRT_IB}" -C "${OPENWRT_DIR}" --strip-components=1
	#The script sets the DTC variable to the path of the Device Tree Compiler (dtc) executable that comes with the 
	#Image Builder. It uses a wildcard search to locate it within the build directories.
	DTC="$(ls -1 "${OPENWRT_DIR}/build_dir/target-aarch64_cortex-a53_musl/linux-mediatek_mt7622/linux-"*"/scripts/dtc/dtc")"
	#If the dtc executable cannot be found, an error message is displayed, and the script exits with status 1.
	[ -x "$DTC" ] || {
		echo "can't find dtc executable in OpenWrt IB"
		exit 1
	}
}

its_add_data() {
	#This will hold each line of the file as it's read
	local line
	#A flag to indicate whether the current line is inside the images block.
	local in_images=0
	#A flag to indicate whether the current line is inside an individual image definition.
	local in_image=0
	#A counter to keep track of the level of braces (nested structures) within an image definition.
	local br_level=0
	#This will hold the name of the image extracted from the line that begins the definition of an image.
	local img_name
	#The loop starts, reading each line of the ITS file into the variable line.
	while read -r line; do
		#Each line is echoed, which means it will be printed to standard output.
		echo "$line"
		#The following if and case statements work together to determine if the current line is within the images 
		#block and act accordingly.
		if [ "$in_images" = "0" ]; then
			#If in_images is 0 (we are not yet inside an images block), and the line contains "images {", then 
			#in_images is set to 1 and the loop continues to the next iteration.
			case "$line" in
				*"images {"*)
					in_images=1
					continue;
				;;
			esac
		fi
		if [ "$in_images" = "1" ] && [ "$in_image" = "0" ]; then
			#If in_images is 1 (we are inside an images block) and in_image is 0 (not yet inside an image definition), 
			#and the line contains an opening brace {, then in_image is set to 1. 
			case "$line" in
				*"{"*)
					in_image=1
					#The image name is extracted from the line and stored in img_name.
					img_name="$(echo "$line" | cut -d'{' -f1 | sed 's/ *$//g' )"
					continue;
				;;
			esac
		fi
		if [ "$in_images" = "1" ] && [ "$in_image" = "1" ]; then
			#If in_images is 1 and in_image is 1 (inside an image definition), several cases are checked:
			case "$line" in
				#If the line contains "type = ", it adds a new line with data = /incbin/(\"./${img_name}\"); to include 
				#binary data.
				*"type = "*)
					echo "data = /incbin/(\"./${img_name}\");"
					;;
				#If the line contains an opening brace {, it 
				*"{"*)
					#increments br_level to track nested structures.
					br_level=$((br_level + 1))
					continue;
					;;
				#If the line contains a closing brace }, it checks the br_level. 
				*"}"*)
					if [ $br_level -gt 0 ]; then
						#if br_level is greater than 0, it decrements it
						br_level=$((br_level - 1))
					else
						#else it sets in_image to 0 to indicate that the image definition has ended.
						in_image=0
					fi
					continue;
					;;
			esac
		fi
	#The loop ends when all lines from the ITS file have been read.
	done < "${ITSFILE}"
	#The output of this entire process (the echoed lines and any added data = /incbin/(...) lines) is captured by 
	#the > redirection operator in the calling function (refit_image()) and written to a new file.
}

unfit_image() {
	#Assign the input file to a variable:
	INFILE="$1"
	#basename strips the directory and suffix from filenames. Here it's used to get the base name of the 
	#input file without the .itb extension.
	FILEBASE="$(basename "$INFILE" .itb)"
	#creates a temporary directory and returns its path, which is then stored in the WORKDIR variable.
	WORKDIR="$(mktemp -d)"
	#his sets the path where the output ITS (Image Tree Source) file will be saved.
	ITSFILE="${WORKDIR}/image.its"
	#creates the directory specified by WORKDIR and also makes parent directories as needed. 
	#However, since mktemp -d already creates the directory, this line is somewhat redundant.
	mkdir -p "$WORKDIR"
	#Changes the current directory to WORKDIR, so all subsequent operations are done in the context of this 
	#temporary directory.
	cd "$WORKDIR"
	#UNFIT is a custom or specific utility that's not part of standard Unix commands. It is documeneted fully
	#in README_BUILDINSTALLER.md The `unfit` utility extracts images (like kernels, ramdisks, etc.) from a 
	#Flat Image Tree (FIT) image. FIT images are a custom format used by U-Boot, which is a popular bootloader for embedded devices.
	"$UNFIT" "$INFILE"
	# -I This option tells dtc that the input format is a Device Tree Blob (.dtb), which is a binary 
	#representation of a device tree.
	# -O This tells dtc to output the Device Tree Source (.dts), which is a human-readable and editable text 
	#representation of the device tree.
	# -o This option specifies the output file for the command. The variable ITSFILE should contain the desired path for 
	#the output .dts file.
	#$INFILE": This is the input file for the command, likely a .dtb file. The variable INFILE should contain the path to this input file.
	#|| exit 2: This part of the command ensures that if the dtc command fails (returns a non-zero exit status), 
	#the script running it will exit with an exit code of 2. This can be used to indicate that a certain type of error occurred.
	"$DTC" -I dtb -O dts -o "$ITSFILE" "$INFILE" || exit 2

	# figure out exact FIT image type
	EXTERNAL=
	STATIC=
	#This line checks if the ITS file contains a reference to data-size, which would indicate the use of 
	#external data. If it does, the EXTERNAL flag is set to 1.
	grep -q "data-size = " "$ITSFILE" && EXTERNAL=1
	#Similarly, this checks for data-position references, which would indicate static data positioning. 
	#If found, STATIC is set to 1.
	grep -q "data-position = " "$ITSFILE" && STATIC=1

	# filter-out existing data nodes
	#This command uses grep -v to exclude (-v inverts the match) lines containing certain patterns from the 
	#ITS file and redirects the output to a new file (${ITSFILE}.new).
	#These patterns include "data =", "data-size =", "data-offset =", and "data-position =", 
	#which are all related to the actual binary data included in the FIT image.
	#The purpose of filtering out these lines is to remove references to the binary data within the ITS file. 
	#This can be done to create a new ITS file that does not include the binary blobs, which might be necessary 
	#for certain operations such as editing or restructuring the FIT image without the actual binary data.
	#So after this grep command is executed, ${ITSFILE}.new will have a version of the ITS without the binary data, 
	#which means it will no longer have the properties that point to the actual content of the images, but it will still 
	#retain the structure and other metadata.
	grep -v -e "data = " -e "data-size = " -e "data-offset = " -e "data-position = " "$ITSFILE" > "${ITSFILE}.new"
	#This moves the filtered file back to the original filename, effectively updating it to exclude the 
	#lines matching the earlier grep patterns.
	mv "${ITSFILE}.new" "${ITSFILE}"
}

refit_image() {
	#This sets a local variable blocksize to the value of the first argument passed to the function, which 
	#specifies the block size for the image.
	local blocksize="${1}"
	#This declares a local variable imgtype without initializing it.
	local imgtype
	#This checks if the second argument to the function is non-empty; if it is, it sets imgtype to the value 
	#of the second argument.
	[ -n "${2-}" ] && imgtype="${2}"
	#This initializes an array to hold parameters for the mkimage command.
	local MKIMAGE_PARM=()

	# re-add data nodes from files
	#This command executes its_add_data() and redirects its output to a file named after the original ITS file but with a 
	#.new extension. The function reads the original ITS file, processes its contents, and outputs a modified version of it.
	#The /incbin/ directive in the ITS file does not include the binary data itself in the .its file; instead, 
	#it includes a reference to the binary file's location. When the FIT image is created using the mkimage utility 
	#later on, the mkimage tool reads these /incbin/ directives and physically includes the binary data from the 
	#referenced files into the final .itb (Image Tree Blob) file.
	its_add_data > "${ITSFILE}.new"
	#The conditionals check whether the EXTERNAL or STATIC variables are set to 1 and, if so, append 
	#corresponding parameters to the MKIMAGE_PARM array. These parameters adjust the behavior of mkimage when 
	#creating the FIT image.
	[ "$EXTERNAL" = "1" ] && MKIMAGE_PARM=("${MKIMAGE_PARM[@]}" -E -B 0x1000)
	[ "$STATIC" = "1" ] && MKIMAGE_PARM=("${MKIMAGE_PARM[@]}" -p 0x1000)
	#he script updates the PATH variable to include the directory containing the Device Tree Compiler (DTC), 
	#sets the SOURCE_DATE_EPOCH environment variable (for reproducibility), and runs the mkimage command with the 
	#parameters collected in MKIMAGE_PARM. The -f option specifies the ITS file to use as input, and the output 
	#file is named after FILEBASE with -refit.itb appended.
	PATH="$PATH:$(dirname "$DTC")" \
		SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH \
		"$MKIMAGE" "${MKIMAGE_PARM[@]}" -f "${ITSFILE}.new" "${FILEBASE}-refit.itb"
	#This echoes the image type being processed, or "(unset)" if imgtype is not set.
	echo "imgtype: \"${imgtype:-(unset)}\""
	#This uses the dd command to copy the refit FIT image to a new file. The file name is derived from 
	#FILEBASE and, if imgtype is set, it is appended with a hyphen before the type. The bs="$blocksize" 
	#sets the dd block size, and conv=sync pads the final block of output to the full block size with NUL bytes.
	dd if="${FILEBASE}-refit.itb" of="${FILEBASE}${imgtype:+-$imgtype}.itb" bs="$blocksize" conv=sync
}

extract_initrd() {
	 #checks if the file initrd-1 exists in the WORKDIR directory. If the file doesn't exist, 
	 #the function returns 1, indicating an error, and the rest of the function is not executed.
	[ -e "${WORKDIR}/initrd-1" ] || return 1
	#checks if a directory named initrd exists within WORKDIR. If it does, it's removed recursively with 
	#rm -rf. This ensures that the function starts with a clean state.
	[ -e "${WORKDIR}/initrd" ] && rm -rf "${WORKDIR}/initrd"
	#creates a new directory named initrd within WORKDIR.
	mkdir "${WORKDIR}/initrd"
	#Decompress and Extract initrd Image:
	#${XZ} -d decompresses the initrd image. The -d flag tells xz to decompress 
	#the input file (initrd-1). The decompressed data is then piped (|) to cpio.
	#${CPIO} -i -D "${WORKDIR}/initrd" tells cpio to extract the files (-i for extract) to the directory 
	#specified by the -D flag, which is the initrd directory just created.
	"${XZ}" -d < "${WORKDIR}/initrd-1" | "${CPIO}" -i -D "${WORKDIR}/initrd"
	#deletes the compressed initrd file named initrd-1 from the WORKDIR to free up space and because 
	#it's no longer needed after extraction.
	rm "${WORKDIR}/initrd-1"

	echo "initrd extracted in '${WORKDIR}/initrd'"
	#indicates that the function has completed successfully.
	return 0
}

repack_initrd() {
	#[ -d "${WORKDIR}/initrd" ] || return 1: This checks if the ${WORKDIR}/initrd directory exists. 
	#If it doesn't, the function returns 1, indicating an error. This directory is expected to contain the 
	#extracted contents of the initrd image.
	[ -d "${WORKDIR}/initrd" ] || return 1
	#find "${WORKDIR}/initrd" -newermt "@${SOURCE_DATE_EPOCH}" -print0 | xargs -0r touch --no-dereference 
	#--date="@${SOURCE_DATE_EPOCH}": This command finds all files within the initrd directory that have been 
	#modified after the SOURCE_DATE_EPOCH timestamp. It then uses xargs to pass these file names to the touch 
	#command, setting their modification times to SOURCE_DATE_EPOCH. This step ensures that the files have a 
	#consistent timestamp for reproducibility.
	find "${WORKDIR}/initrd" -newermt "@${SOURCE_DATE_EPOCH}" -print0 |
		xargs -0r touch --no-dereference --date="@${SOURCE_DATE_EPOCH}"
	echo "re-compressing initrd..."
	#The subshell ( cd "${WORKDIR}/initrd" ; ... ): changes to the initrd directory.
	#find . | LC_ALL=C sort: This finds all files and directories in the current directory, sorts them in a 
	#locale-independent way (LC_ALL=C ensures consistent sorting behavior regardless of the user's locale settings).
	#"${CPIO}" --reproducible -o -H newc -R 0:0: This pipes the sorted list of files to cpio to create a new 
	#archive (-o for creating). The --reproducible flag is used to ensure that the resulting cpio archive 
	#is the same for identical input files and directories. The -H newc option specifies the new (SVR4) portable 
	#format, and -R 0:0 sets the owner of the files to the user ID 0 and group ID 0 (root).
	#"${XZ}" -T0 -c -9 --check=crc32 > "${WORKDIR}/initrd-1": This pipes the output from cpio to xz to compress 
	#the archive. The -T0 option tells xz to use all available CPU cores for faster compression. 
	#The -c flag writes the output to standard output, and -9 requests the highest level of compression. 
	#--check=crc32 specifies the integrity check to use CRC32. The compressed output is then redirected to a 
	#file named initrd-1 in WORKDIR.
	( cd "${WORKDIR}/initrd" ; find . | LC_ALL=C sort | "${CPIO}" --reproducible -o -H newc -R 0:0 | "${XZ}" -T0 -c -9  --check=crc32 > "${WORKDIR}/initrd-1" )
	return 0
}

allow_mtd_write() {
	#This command uses the Device Tree Compiler (DTC) to convert a binary device tree blob (DTB) into a 
	#human-readable device tree source (DTS) file.
	"$DTC" -I dtb -O dts -o "${WORKDIR}/fdt-1.dts" "${WORKDIR}/fdt-1"
	#Deletes the original DTB file, as it's no longer needed in its binary form; the modifications will 
	#be made to the DTS file.
	rm "${WORKDIR}/fdt-1"
	#This line creates a new DTS file where any lines containing 'read-only' are removed 
	#(grep -v inverts the search, excluding lines that match the pattern). This is likely done to change the 
	#properties of MTD partitions to allow them to be writable.
	grep -v 'read-only' "${WORKDIR}/fdt-1.dts" > "${WORKDIR}/fdt-1.dts.patched"
	#The patched DTS file is then converted back into a binary DTB file for use by the system. 
	#This new DTB file no longer has the 'read-only' restrictions on the MTD partitions, allowing for 
	#writing operations.
	"$DTC" -I dts -O dtb -o "${WORKDIR}/fdt-1" "${WORKDIR}/fdt-1.dts.patched"
}

enable_services() {
	cd "${WORKDIR}/initrd"
	#This loop iterates over every file in the etc/init.d directory of the initrd. Files in this directory 
	#are typically service initialization scripts used to start and stop system services.
	for service in ./etc/init.d/*; do
	#Inside the loop, for each service (which is a path to a script), a subshell is spawned ( ... ) where:
	# cd "${WORKDIR}/initrd" is used again to ensure that the script is executed within the right directory 
	#context.
	# IPKG_INSTROOT="${WORKDIR}/initrd" sets an environment variable that tells the scripts where the root 
	#of the file system is located. This is important when working in a chroot-like environment or with an 
	#alternative root directory, as is the case with initrd.
	# $(command -v bash) dynamically finds the path to the bash shell and uses it to execute the script. 
	#The use of command -v ensures that the script uses the system's bash and not a different shell that might 
	#be specified in the script's shebang line.
	# ./etc/rc.common "$service" enable runs the rc.common script with the service script as an argument along 
	#with the enable command. In OpenWRT and other similar systems, rc.common provides common functions for 
	#service scripts, and calling it with enable will set the service to start automatically on boot.
	# 2>/dev/null redirects any error output to /dev/null, effectively silencing any errors that occur 
	#during the process.
		( cd "${WORKDIR}/initrd" ; IPKG_INSTROOT="${WORKDIR}/initrd" $(command -v bash) ./etc/rc.common "$service" enable 2>/dev/null )
	done
}

bundle_initrd() {
	# When the bundle_initrd function is entered, $1 and $2 are the positional parameters that 
	# the function can access. If shift is called without an argument inside bundle_initrd, 
	# then recovery would be discarded, and the path resulting from "${INSTALLERDIR}/dl/${OPENWRT_INITRD}" 
	# would become the new $1
	local imgtype=$1
	shift
	# calls unfit_image with the path to an OpenWrt initramfs recovery image (.itb file). 
	# This extracts the image components into a working directory and converts it 
	# to a device tree source (DTS) format using the dtc command.
	unfit_image "$1"
	shift

	extract_initrd
	# it is invoking the opkg package manager binary that is part of the OpenWrt Image Builder tools, 
	# and it operates in an "offline" mode against the filesystem unpacked into ${WORKDIR}/initrd. 
	# This is not the system's native opkg binary (which would be used if running OpenWrt natively), 
	# but a version that runs on the host OS (likely x86) 
	#Package Management:

	# Remove Packages: If there are packages listed to be removed (specified by the OPENWRT_REMOVE_PACKAGES array), 
	# it uses the opkg command to remove them from the extracted initrd. This step is done within the chroot 
	# environment of the initrd, meaning it's as if the commands are being run on the actual system that the 
	# initrd represents.
	#${INSTALLERDIR}/openwrt-ib/staging_dir/host/bin/opkg
	[[ ${#OPENWRT_REMOVE_PACKAGES[@]} -gt 0 ]] && IPKG_NO_SCRIPT=1 IPKG_INSTROOT="${WORKDIR}/initrd" \
		"${OPKG}" --offline-root="${WORKDIR}/initrd" -f "${WORKDIR}/initrd/etc/opkg.conf" \
		remove "${OPENWRT_REMOVE_PACKAGES[@]}"
	# Update Package Lists: It then updates the package lists using opkg update, which ensures that the 
	# package database within the initrd is up-to-date.
	PATH="$(dirname "${OPKG}"):$PATH" \
	OPKG_KEYS="${WORKDIR}/initrd/etc/opkg/keys" \
	TMPDIR="${WORKDIR}/initrd/tmp" \
		"${OPKG}" --offline-root="${WORKDIR}/initrd" -f "${WORKDIR}/initrd/etc/opkg.conf" \
			--verify-program="${WORKDIR}/initrd/usr/sbin/opkg-key" \
			update
	# Add Packages: If there are additional packages to be added (specified by the OPENWRT_ADD_PACKAGES array), 
	# they are installed using opkg as well.
	[[ ${#OPENWRT_ADD_PACKAGES[@]} -gt 0 ]] && \
		PATH="$(dirname "${OPKG}"):$PATH" \
		OPKG_KEYS="${WORKDIR}/initrd/etc/opkg/keys" \
		TMPDIR="${WORKDIR}/initrd/tmp" \
		IPKG_NO_SCRIPT=1 IPKG_INSTROOT="${WORKDIR}/initrd" \
		"${OPKG}" --offline-root="${WORKDIR}/initrd" -f "${WORKDIR}/initrd/etc/opkg.conf" \
		--verify-program="${WORKDIR}/initrd/usr/sbin/opkg-key" \
		--force-postinst install "${OPENWRT_ADD_PACKAGES[@]}"

	case "$imgtype" in
		recovery)
			# If additional packages specific to recovery mode are defined in OPENWRT_ADD_REC_PACKAGES, 
			# these are also installed into the initrd.
			[[ ${#OPENWRT_ADD_REC_PACKAGES[@]} -gt 0 ]] && \
			PATH="$(dirname "${OPKG}"):$PATH" \
			OPKG_KEYS="${WORKDIR}/initrd/etc/opkg/keys" \
			TMPDIR="${WORKDIR}/initrd/tmp" \
			IPKG_NO_SCRIPT=1 IPKG_INSTROOT="${WORKDIR}/initrd" \
				"${OPKG}" --offline-root="${WORKDIR}/initrd" -f "${WORKDIR}/initrd/etc/opkg.conf" \
				--verify-program="${WORKDIR}/initrd/usr/sbin/opkg-key" \
				--force-postinst install "${OPENWRT_ADD_REC_PACKAGES[@]}"
			;;
		installer)
			#The options used are:
			#-a: Archive mode; preserves the specified attributes (e.g., directory structure, permissions, timestamps) when 
			#copying.
			#-v: Verbose; prints the name of each file as it is copied.
			#-r: Recursive; copies directories and their contents.
			#The purpose of this line is to copy any additional files that are required for the installation process into 
			#the working directory of the initrd (initial ramdisk).
			cp -avr "${INSTALLERDIR}/files/"* "${WORKDIR}/initrd"
			#The -v option makes the command print the name of each file as it's copied.
			#The "$@" is a special shell variable that holds all the arguments passed to the script. So, this line is 
			#effectively copying additional files passed as arguments when the script is called into the installer directory 
			#inside the initrd working directory.
			#This could be used, for instance, to include certain binaries or scripts that are part of the installation process 
			#itself.
			cp -v "$@" "${WORKDIR}/initrd/installer"
			;;
	esac
	#Here I can modify other files as I see fit on the ${WORKDIR}/initrd
	#for example:
	# Append a line to the dropbear configuration
	#echo "#example of adding text in a config file" >> "${WORKDIR}/initrd/etc/config/dropbear"


	# it modifies the timestamp in the status file of the opkg package management system to match 
	# SOURCE_DATE_EPOCH, ensuring reproducibility of the build.
	sed -i "s/Installed-Time: .*/Installed-Time: ${SOURCE_DATE_EPOCH}/" ${WORKDIR}/initrd/usr/lib/opkg/status
	# to enable all init scripts found in /etc/init.d within the initrd, ensuring that necessary 
	# services will start when the system boots.
	enable_services
	#removes any temporary files that might have been created during the process.
	rm -rf "${WORKDIR}/initrd/tmp/"*
	# Runs a find command to update the timestamps of all files in the initrd to SOURCE_DATE_EPOCH. 
	# This helps in achieving reproducible builds by ensuring that all files have the same timestamp 
	# regardless of when they were actually modified or created.
	find ${WORKDIR}/initrd/ -mindepth 1 -execdir touch -hcd "@${SOURCE_DATE_EPOCH}" "{}" +
	# The modified initrd file system is then repacked into a compressed image using cpio and xz. 
	# The --reproducible flag is used with cpio to ensure that the repacked initrd will be the same every time 
	# the script is run with the same inputs.
	repack_initrd

	cd "${WORKDIR}"
	case "$imgtype" in
		#refit_image to create a new FIT image from the modified ITS file, which now includes 
		#the modified initrd. 
		recovery)
			#If the recovery argument is passed, it also defines a specific block size for the image.
			refit_image 128k
			;;
		installer)
			allow_mtd_write
			refit_image 128k "$imgtype"
			;;
	esac
}

linksys_e8450_installer() {
	OPENWRT_RELEASE="22.03.2"
	OPENWRT_TARGET="https://downloads.openwrt.org/releases/${OPENWRT_RELEASE}/targets/mediatek/mt7622"
	OPENWRT_IB="openwrt-imagebuilder-${OPENWRT_RELEASE}-mediatek-mt7622.Linux-x86_64.tar.xz"
	OPENWRT_INITRD="openwrt-${OPENWRT_RELEASE}-mediatek-mt7622-linksys_e8450-ubi-initramfs-recovery.itb"
	OPENWRT_SYSUPGRADE="openwrt-${OPENWRT_RELEASE}-mediatek-mt7622-linksys_e8450-ubi-squashfs-sysupgrade.itb"
	OPENWRT_ADD_REC_PACKAGES=(kmod-mtd-rw)
	OPENWRT_REMOVE_PACKAGES=()
	OPENWRT_ADD_PACKAGES=()
	VENDOR_FW="https://web.archive.org/web/20220511153700if_/https://www.belkin.com/support/assets/belkin/firmware/FW_RT3200_1.1.01.272918_PROD_unsigned.img"
	VENDOR_FW_HASH="01a9efa97120ff6692c252f2958269afbc87acd2528b281adfc8b55b0ca6cf8a"
	# Sets up GPG keys and downloads OpenWrt image builder and verifies the checksums
	prepare_openwrt_ib
	#Prepares the initial ramdisk by adding or removing packages and files.
	bundle_initrd recovery "${INSTALLERDIR}/dl/${OPENWRT_INITRD}"

	mv "${WORKDIR}/${FILEBASE}.itb" "${DESTDIR}"
	rm -r "${WORKDIR}"
	cp "${INSTALLERDIR}/dl/${OPENWRT_SYSUPGRADE}" "${DESTDIR}"
	#specifies the location of the initial ramdisk image to be used. 
	bundle_initrd installer "${INSTALLERDIR}/dl/${OPENWRT_INITRD}" \
		#The bl2.img file is probably a secondary bootloader
		"${OPENWRT_DIR}/staging_dir/target-aarch64_cortex-a53_musl/image/mt7622-snand-1ddr-bl2.img" \
		#the u-boot.fip is likely a U-Boot (Universal Boot Loader) firmware image package
		"${OPENWRT_DIR}/staging_dir/target-aarch64_cortex-a53_musl/image/mt7622_linksys_e8450-u-boot.fip" \
		#specifies the output file for the bundled image. The .itb extension indicates an Image Tree Blob, 
		#which is a format used by U-Boot to store multiple images (like kernel, ramdisk, device tree, etc.) in a 
		#single file with a header describing the contents.
		"${DESTDIR}/${FILEBASE}.itb"

	# thanks to @linksys for leaving private key in the firmware
	#This line uses the wget command to download a file from the URL stored in the variable VENDOR_FW and save it as 
	#vendor.bin in the directory ${INSTALLERDIR}/dl. The -c option allows the download to continue if it was interrupted 
	#previously, and -O specifies the output filename.
	wget -c -O "${INSTALLERDIR}/dl/vendor.bin" "${VENDOR_FW}"
	#This line calculates the SHA256 hash of the downloaded vendor.bin file and stores it in the variable vendorhash. 
	#The cut command is used to extract just the hash value from the output of sha256sum.
	vendorhash="$(sha256sum "${INSTALLERDIR}/dl/vendor.bin" | cut -d' ' -f1)"
	#This line compares the calculated SHA256 hash of the vendor.bin file to a known hash value stored in VENDOR_FW_HASH. 
	#If they match, it indicates that the vendor.bin file has been downloaded correctly and has not been tampered with.
	if [ "$vendorhash" = "$VENDOR_FW_HASH" ]; then
		#his line uses unsquashfs, a tool to extract files from a squashfs filesystem (a compressed read-only filesystem), 
		#to extract the secring.gpg file from an offset of 2621440 bytes within the vendor.bin file into 
		#the ${WORKDIR}/rootfs directory. The secring.gpg file is part of the GNU Privacy Guard (GnuPG or GPG) software 
		#and contains private keys used for cryptographic operations.
		unsquashfs -o 2621440 -d "${WORKDIR}/rootfs" "${INSTALLERDIR}/dl/vendor.bin" "/root/.gnupg/secring.gpg"
		#This line imports the private keys from the secring.gpg file into a GnuPG keyring specified by ${INSTALLERDIR}/vendor-keyring.
		gpg --no-default-keyring --keyring "${INSTALLERDIR}/vendor-keyring" --import < "${WORKDIR}/rootfs/root/.gnupg/secring.gpg" || true
		#These commands set up GPG to use a specific keyring, designate a default and trusted key, and specify the recipient of 
		#the encrypted message (the email associated with the key). The -s option signs the input file, and -e encrypts it. 
		#The --batch option allows these commands to run non-interactively, and the output is specified by the [output-file] and 
		#[input-file] placeholders. If the signing or encryption fails, the script will continue due to the || true at the end of 
		#each command.
		gpg --no-default-keyring --keyring "${INSTALLERDIR}/vendor-keyring" --default-key 762AE637CDF0596EBA79444D99DAC426DCF76BA1 --trusted-key 16EBADDEF5B6755C -r aruba_recipient@linksys.com -s -e --batch --output "${WORKDIR}/${FILEBASE}-installer_signed.itb" "${WORKDIR}/${FILEBASE}-installer.itb" || true
		gpg --no-default-keyring --keyring "${INSTALLERDIR}/vendor-keyring" --default-key 762AE637CDF0596EBA79444D99DAC426DCF76BA1 --trusted-key 16EBADDEF5B6755C -r aruba_recipient@linksys.com -s -e --batch --output "${DESTDIR}/${FILEBASE}_signed.itb" "${DESTDIR}/${FILEBASE}.itb" || true
	#If the hash check fails, the else block is executed.
	else
		#This line removes the vendor.bin file if the hash does not match, which would indicate a corrupted or tampered file.
		rm "${INSTALLERDIR}/dl/vendor.bin"
	fi

	mv "${WORKDIR}/${FILEBASE}-installer"* "${DESTDIR}"
	rm -r "${WORKDIR}"
}

linksys_e8450_installer
