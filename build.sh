#!/bin/bash
set -eu

# only for debug
true ${KEEP_CACHE:=1}
true ${EXTERNAL_ROOTFS_DIR:=}
true ${NJOBS:=8}

SCRIPTS_DIR=$(
	cd $(dirname $0)
	pwd
)
if [ -h $0 ]; then
	CMD=$(readlink $0)
	SCRIPTS_DIR=$(dirname $CMD)
fi
cd $SCRIPTS_DIR
cd ../
TOP_DIR=$(pwd)

SDFUSE_DIR=$TOP_DIR/scripts/sd-fuse
# These arrays will be populated in the.mk file
true ${BOARDDOGWRT_PACKAGE_DIR:=}
declare -a BOARDDOGWRT_FILES=("")
declare -a BOARDDOGWRT_PATCHS=("")

PREBUILTS_GCC_AARCH64_PATH="${TOP_DIR}/prebuilts/gcc/linux-x86/aarch64/gcc-arm-11.3-x86_64-aarch64-none-linux-gnu/"

firsttime_usage() {
	echo ""
	echo "# select board: "
	ALL_MK=$(find ./device/boarddog -type f -name "*.mk" -printf "%f\n")
	for mk in ${ALL_MK}; do
		if [ ${mk} != "base.mk" ]; then
			echo "  ./build.sh $mk"
		fi
	done
	ALL_MK_LINK=$(find ./device/boarddog -type l -name "*.mk" -printf "%f\n")
	for mk in ${ALL_MK_LINK}; do
		if [ ${mk} != "base.mk" ]; then
			echo "  ./build.sh $mk"
		fi
	done
	echo ""
}

usage() {
	echo "USAGE: ./build.sh <parameter>"
	firsttime_usage
	echo "# build module: "
	echo "  ./build.sh all                -build all"
	echo "  ./build.sh uboot              -build uboot only"
	echo "  ./build.sh kernel             -build kernel only"
	echo "  ./build.sh boarddogwrt        -build boarddogwrt rootfs only"
	echo "  ./build.sh sd-img             -pack sd-card image, used to create bootable SD card"
	echo "  ./build.sh emmc-img           -pack sd-card image, used to write boarddogwrt to emmc"
	echo "# clean"
	echo "  ./build.sh clean              -remove old images"
	echo "  ./build.sh cleanall"
	echo ""
}

if [ $# -ne 1 ]; then
	usage
	exit 1
fi

function log_error() {
	local now=$(date +%s)
	printf "\033[1;31m[ERROR]: $*\033[0m \n"
}

function log_warn() {
	local now=$(date +%s)
	printf "\033[1;31m[WARN]: $*\033[0m \n"
}

function log_info() {
	local now=$(date +%s)
	printf "\033[1;32m[INFO]: $* \033[0m \n"
}

function build_uboot() {
	# build uboot
	echo "============Start building uboot============"
	echo "SRC							= ${TOP_DIR}/u-boot"
	echo "TARGET_ARCH					= $TARGET_ARCH"
	echo "TARGET_PLAT					= $TARGET_PLAT"
	echo "TARGET_UBOOT_CONFIG			= $TARGET_UBOOT_CONFIG"
	echo "TARGET_OSNAME	 				= $TARGET_OSNAME"
	echo "========================================="

	if uname -mpi | grep aarch64 >/dev/null; then
		echo "====Skip U-Boot compilation and use prebuilt files!===="
		return 0
	fi

	(cd ${SDFUSE_DIR} && {
		DISABLE_MKIMG=1 UBOOT_SRC=${TOP_DIR}/u-boot UBOOT_JOBS=$NJOBS ./build-uboot.sh ${TARGET_OSNAME}
	})

	if [ $? -eq 0 ]; then
		echo "====Building uboot ok!===="
	else
		echo "====Building uboot failed!===="
		exit 1
	fi
}

function build_kernel() {
	# build kernel
	echo "============Start building kernel============"
	echo "SRC				  			= ${TOP_DIR}/kernel"
	echo "TARGET_ARCH		  			= $TARGET_ARCH"
	echo "TARGET_PLAT		  			= $TARGET_PLAT"
	echo "TARGET_KERNEL_CONFIG 			= $TARGET_KERNEL_CONFIG"
	echo "TARGET_OSNAME					= $TARGET_OSNAME"
	echo "=========================================="
	# cpu number CCPU=$(nproc)
	(cd ${SDFUSE_DIR} && {
		DISABLE_MKIMG=1 KCFG="${TARGET_KERNEL_CONFIG}" KERNEL_SRC=${TOP_DIR}/kernel KERNEL_JOBS=$NJOBS ./build-kernel.sh ${TARGET_OSNAME}
	})

	if [ $? -eq 0 ]; then
		echo "====Building kernel ok!===="
	else
		echo "====Building kernel failed!===="
		exit 1
	fi
}

function app_process() {
	[ -d ${TOP_DIR}/app/config/ ] && {
		mkdir -p ${TOP_DIR}/boarddogwrt/package/app/
		cp -arf ${TOP_DIR}/app/config/* ${TOP_DIR}/boarddogwrt/package/app/
		log_info "install app/config/ to boarddogwrt/package/app/"
	}
	[ -d ${TOP_DIR}/app/theme/ ] && {
		mkdir -p ${TOP_DIR}/boarddogwrt/package/theme/
		cp -arf ${TOP_DIR}/app/theme/* ${TOP_DIR}/boarddogwrt/package/theme/
		log_info "install app/theme/ to boarddogwrt/package/theme/"
	}
}

function build_boarddogwrt() {
	# build boarddogwrt
	echo "==========Start build boarddogwrt=========="
	echo "TARGET_BOARDDOGWRT_CONFIG		= $TARGET_BOARDDOGWRT_CONFIG"
	echo "BOARDDOGWRT_SRC				= $BOARDDOGWRT_SRC"
	echo "TARGET_PLAT					= $TARGET_PLAT"
	echo "========================================="

	app_process

	(cd ${BOARDDOGWRT_SRC} && {
		./scripts/feeds update -a && ./scripts/feeds install -a
		if [ $? -ne 0 ]; then
			echo "====Building boarddogwrt failed!===="
			exit 1
		fi
	})

	(cd ${TOP_DIR}/${BOARDDOGWRT_SRC} && {
		for ((i = 0; i < ${#BOARDDOGWRT_PATCHS[@]}; i++)); do
			if [ ! -z ${BOARDDOGWRT_PATCHS[$i]} ]; then
				OLD_IFS="$IFS"
				IFS=";"
				ARR=(${BOARDDOGWRT_PATCHS[$i]})
				IFS="$OLD_IFS"
				if [ ${#ARR[@]} -eq 1 ]; then
					# apply patch to boarddogwrt root dir
					log_info "Applying ${BOARDDOGWRT_PATCHS[$i]} to ${BOARDDOGWRT_SRC}"
					git am -3 ${TOP_DIR}/${BOARDDOGWRT_PATCHS[$i]}
				elif [ ${#ARR[@]} -eq 2 ]; then
					# apply patch to sub dir
					if [ -d ${TOP_DIR}/${ARR[1]} ]; then
						(cd ${TOP_DIR}/${ARR[1]} && {
							PATCHS=$(ls)
							cd ${TOP_DIR}/${BOARDDOGWRT_SRC}/${ARR[0]}
							for FILE in ${PATCHS}; do
								log_info "Applying ${FILE} to ${PWD}"
								git am -3 ${TOP_DIR}/${ARR[1]}/${FILE}
							done
						})
					else
						(cd ${ARR[0]} && {
							log_info "Applying ${ARR[1]} to ${BOARDDOGWRT_SRC}/${ARR[0]}"
							git am -3 ${TOP_DIR}/${ARR[1]}
						})
					fi
				else
					echo "failed to apply patch: ${BOARDDOGWRT_PATCHS[$i]}, wrong format, please check it."
				fi
			fi
		done
	})

	true ${DEBUG_DOT_CONFIG:=0}
	WRT_JOBS=$NJOBS $SCRIPTS_DIR/mk-boarddogwrt.sh $TARGET_BOARDDOGWRT_CONFIG $BOARDDOGWRT_SRC $TARGET_PLAT
	if [ $? -eq 0 ]; then
		if [ $DEBUG_DOT_CONFIG -eq 0 ]; then
			echo "====Building boarddogwrt ok!===="
		fi
	else
		echo "====Building boarddogwrt failed!===="
		exit 1
	fi
}

function build_all() {
	build_uboot
	build_kernel
	build_boarddogwrt
	build_sdimg
}

function clean_old_images() {
	(cd $TOP_DIR/out && {
		rm -f *.img
		rm -f *.7z
		rm -f *.zip
		rm -rf boot.*
		rm -rf rootfs.*
	})
}

function clean_all() {
	echo "clean uboot, kernel, boarddogwrt, img files"
	cd $TOP_DIR/u-boot/ && make distclean && cd -
	cd $TOP_DIR/kernel && make distclean && cd -
	cd $TOP_DIR/boarddogwrt && make clean && cd -
	cd ${SDFUSE_DIR} && ./clean.sh && cd -
}

function copy_and_verify() {
	if [ ! -f $1 ]; then
		echo "not found: $1"
		echo "$3"
		exit 1
	fi
	cp $1 $2
}

function prepare_image_for_boarddog_eflasher() {
	local OS_DIR=$1
	local ROOTFS=$2
	if [ ! -d ${SDFUSE_DIR}/${OS_DIR} ]; then
		mkdir ${SDFUSE_DIR}/${OS_DIR}
	fi
	rm -rf ${SDFUSE_DIR}/${OS_DIR}/*

	# clean
	rm -rf ${SDFUSE_DIR}/out/boot.*

	local ROOTFS_DIR=${EXTERNAL_ROOTFS_DIR}
	if [ -z $ROOTFS_DIR ]; then
		rm -rf ${SDFUSE_DIR}/out/rootfs.*
		ROOTFS_DIR=$(mktemp -d ${SDFUSE_DIR}/out/rootfs.XXXXXXXXX)
	fi
	log_info "Copying ${TOP_DIR}/${BOARDDOGWRT_SRC}/${BOARDDOGWRT_ROOTFS} to ${ROOTFS_DIR}/"
	cp -af ${TOP_DIR}/${BOARDDOGWRT_SRC}/${BOARDDOGWRT_ROOTFS}/* ${ROOTFS_DIR}/

	echo "$(date +%Y%m%d)" >${ROOTFS_DIR}/etc/rom-version
	for ((i = 0; i < ${#BOARDDOGWRT_FILES[@]}; i++)); do
		# apply patch to rootfs
		if [ ! -z ${BOARDDOGWRT_FILES[$i]} ]; then
			log_info "Applying ${BOARDDOGWRT_FILES[$i]} to ${ROOTFS_DIR}"
			if [ -f ${TOP_DIR}/${BOARDDOGWRT_FILES[$i]}/install.sh ]; then
				(cd ${TOP_DIR}/${BOARDDOGWRT_FILES[$i]} && {
					TOP_DIR=${TOP_DIR} ./install.sh ${ROOTFS_DIR}
				})
			else
				rsync -a --no-o --no-g --exclude='.git' ${TOP_DIR}/${BOARDDOGWRT_FILES[$i]}/* ${ROOTFS_DIR}/
			fi
		fi
	done

	# Notes:
	# The following operation must be applied after BOARDDOGWRT_FILES has been applied
	#
	PKG_DIR=${BOARDDOGWRT_PACKAGE_DIR}
	if [ -z ${PKG_DIR} ]; then
		log_error "pkg_dir is empty, why?"
		exit 1
	else
		[ -d ${ROOTFS_DIR}/opt ] || mkdir ${ROOTFS_DIR}/opt
		cp -af ${TOP_DIR}/${BOARDDOGWRT_SRC}/${PKG_DIR} ${ROOTFS_DIR}/opt/
		sed -i -e '/file\:\/\/opt\/$(basename ${PKG_DIR})/d' ${ROOTFS_DIR}/etc/opkg/distfeeds.conf
		echo "src/gz boarddogwrt_packages file://opt/$(basename ${PKG_DIR})" >>${ROOTFS_DIR}/etc/opkg/distfeeds.conf
		sed -i '/check_signature/d' ${ROOTFS_DIR}/etc/opkg.conf
	fi

	local BOOT_DIR=$(mktemp -d ${SDFUSE_DIR}/out/boot.XXXXXXXXX)

	# prepare uboot bin, boot.img and rootfs.img
	local UBOOT_DIR=${TOP_DIR}/u-boot
	local KERNEL_DIR=${TOP_DIR}/kernel
	(cd ${SDFUSE_DIR} && {
		if uname -mpi | grep aarch64 >/dev/null; then
			./tools/fill_prebuilt_uboot_bin.sh ./${OS_DIR}
		else
			./tools/update_uboot_bin.sh ${UBOOT_DIR} ./${OS_DIR}
			if [ $? -ne 0 ]; then
				log_error "error: fail to copy uboot bin file."
				return 1
			fi
		fi

		./tools/setup_boot_and_rootfs.sh ${UBOOT_DIR} ${KERNEL_DIR} ${BOOT_DIR} ${ROOTFS_DIR} ./prebuilt ${OS_DIR}
		if [ $? -ne 0 ]; then
			log_error "error: fail to copy kernel to rootfs.img."
			return 1
		fi

		./tools/prepare_boarddogwrt_kernelmodules.sh ${ROOTFS_DIR}
		if [ $? -ne 0 ]; then
			log_error "error: fail to fix kernel module for boarddogwrt to rootfs.img."
			return 1
		fi

		log_info "prepare boot.img ..."
		./build-boot-img.sh ${BOOT_DIR} ./${OS_DIR}/boot.img
		if [ $? -ne 0 ]; then
			log_error "error: fail to gen boot.img."
			return 1
		fi

		log_info "prepare rootfs.img ..."
		./build-rootfs-img.sh ${ROOTFS_DIR} ${OS_DIR} 0
		if [ $? -ne 0 ]; then
			log_error "error: fail to gen rootfs.img."
			return 1
		fi

		cat >./${OS_DIR}/info.conf <<EOL
title=${OS_DIR}
require-board=${TARGET_PLAT}
version=$(date +%Y-%m-%d)
EOL
		./tools/update_prebuilt.sh ./${OS_DIR} ./prebuilt
		if [ $? -ne 0 ]; then
			log_error "error: fail to copy prebuilt images."
			return 1
		fi
		return 0
	})
	if [ $? -ne 0 ]; then
		return 1
	fi

	# clean
	if [ ${KEEP_CACHE} -eq 0 ]; then
		log_info "clean ..."
		rm -rf ${ROOTFS_DIR}
		rm -rf ${BOOT_DIR}
	else
		echo "-----------------------------------------"
		echo "rootfs dir:"
		echo "	${ROOTFS_DIR}"
		echo "boot dir:"
		echo "	${BOOT_DIR}"
		echo "-----------------------------------------"
	fi
	return 0
}

function clean_device_files() {
	# create tmp dir
	if [ ! -d ${1}/tmp ]; then
		mkdir ${1}/tmp
	fi
	chmod 1777 ${1}/tmp
	chown root:root ${1}/tmp
	(cd ${1}/dev && find . ! -type d -exec rm {} \;)
}

function build_sdimg() {
	source ${SDFUSE_DIR}/tools/util.sh
	local HAS_BUILT_UBOOT=$(has_built_uboot ${TOP_DIR}/u-boot ${SDFUSE_DIR}/out)
	local HAS_BUILD_KERN=$(has_built_kernel ${TOP_DIR}/kernel ${SDFUSE_DIR}/out)
	local HAS_BUILD_KERN_MODULES=$(has_built_kernel_modules ${TOP_DIR}/kernel ${SDFUSE_DIR}/out)

	# log_info "HAS_BUILT_UBOOT = ${HAS_BUILT_UBOOT}"
	# log_info "HAS_BUILD_KERN = ${HAS_BUILD_KERN}"
	# log_info "HAS_BUILD_KERN_MODULES = ${HAS_BUILD_KERN_MODULES}"

	if ! uname -mpi | grep aarch64 >/dev/null; then
		if [ ${HAS_BUILT_UBOOT} -ne 1 ]; then
			log_error "error: please build u-boot first."
			exit 1
		fi
	fi

	if [ ${HAS_BUILD_KERN} -ne 1 ]; then
		log_error "error: please build kernel first."
		exit 1
	fi

	if [ ${HAS_BUILD_KERN_MODULES} -ne 1 ]; then
		log_error "error: please build kernel first (miss kernel modules)."
		exit 1
	fi

	local ROOTFS=${TOP_DIR}/${BOARDDOGWRT_SRC}/${BOARDDOGWRT_ROOTFS}
	prepare_image_for_boarddog_eflasher ${TARGET_IMAGE_DIRNAME} ${ROOTFS} && (cd ${SDFUSE_DIR} && {
		./mk-sd-image.sh ${TARGET_IMAGE_DIRNAME} ${TARGET_SD_RAW_FILENAME}
		(cd out && {
			rm -f ${TARGET_SD_RAW_FILENAME}.gz
			gzip --keep ${TARGET_SD_RAW_FILENAME}
		})
		echo "-----------------------------------------"
		echo "Run the following command for sdcard install:"
		echo "	sudo dd if=out/${TARGET_SD_RAW_FILENAME} bs=1M of=/dev/sdX"
		echo "-----------------------------------------"
	})
}

function install_toolchain() {
	if [ ! -d "$PREBUILTS_GCC_AARCH64_PATH" ]; then
		mkdir -p $PREBUILTS_GCC_AARCH64_PATH
		log_info "installing toolchain: aarch-linux-gcc 11.3"
		git clone https://github.com/BoardDogWrt/gcc-arm-11.3-x86_64-aarch64-none-linux-gnu.git -b boarddogwrt --depth 1 "${PREBUILTS_GCC_AARCH64_PATH}"
	fi
}

function build_emmcimg() {
	local ROOTFS=${TOP_DIR}/${BOARDDOGWRT_SRC}/${BOARDDOGWRT_ROOTFS}
	prepare_image_for_boarddog_eflasher ${TARGET_IMAGE_DIRNAME} ${ROOTFS} && (cd ${SDFUSE_DIR} && {
		# auto download eflasher image
		if [ ! -f "eflasher/rootfs.img" ]; then
			./tools/get_rom.sh eflasher
		fi
		./mk-emmc-image.sh ${TARGET_IMAGE_DIRNAME} filename=${TARGET_EFLASHER_RAW_FILENAME} autostart=yes
		echo "-----------------------------------------"
		echo "Run the following command for sdcard install:"
		echo "	sudo dd if=out/${TARGET_EFLASHER_RAW_FILENAME} bs=1M of=/dev/sdX"
		echo "-----------------------------------------"
	})
}

##############################################

MK_LINK=".current_config.mk"
FOUND_MK_FILE=$(find device/boarddog -name ${1} | wc -l)
if [ $FOUND_MK_FILE -gt 0 ]; then
	MK_FILE=$(ls device/boarddog/*/${1})
	echo "using config ${MK_FILE}"
	rm -f ${MK_LINK}
	ln -s ${MK_FILE} ${MK_LINK}
	source ${MK_LINK}
	install_toolchain
	build_all
else
	BUILD_TARGET=${1}

	if [ -e "${MK_LINK}" ]; then
		source ${MK_LINK}

		# display var
		# ( set -o posix ; set ) | less
	else
		echo "no .current_config.mk, please select a board first."
		firsttime_usage
		exit 1
	fi
	install_toolchain

	#=========================
	# build target
	#=========================
	if [ $BUILD_TARGET == uboot -o $BUILD_TARGET == u-boot ]; then
		build_uboot
		exit 0
	elif [ $BUILD_TARGET == kernel ]; then
		build_kernel
		exit 0
	elif [ $BUILD_TARGET == boarddogwrt ]; then
		build_boarddogwrt
		exit 0
	elif [ $BUILD_TARGET == sd-img ]; then
		build_sdimg
		exit 0
	elif [ $BUILD_TARGET == emmc-img ]; then
		build_emmcimg
		exit 0
	elif [ $BUILD_TARGET == all ]; then
		build_all
		exit 0
	elif [ $BUILD_TARGET == clean ]; then
		clean_old_images
		exit 0
	elif [ $BUILD_TARGET == cleanall ]; then
		# Automatically re-run script under sudo if not root
		if [ $(id -u) -ne 0 ]; then
			echo "Re-running script under sudo..."
			sudo "$0" "$@"
			exit
		fi
		clean_all
		exit 0
	else
		echo "Can't find a build config file, please check again"
		usage
		exit 1
	fi
fi

exit 0
