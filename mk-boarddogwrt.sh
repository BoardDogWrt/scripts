#!/bin/bash

set -eu

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

TARGET_BOARDDOGWRT_CONFIG=$1
BOARDDOGWRT_SRC_PATHNAME=$2
TARGET_PLAT=$3

true ${WRT_JOB:=4}
WRT_JOB=$WRT_JOBS

cd ${TOP_DIR}/${BOARDDOGWRT_SRC_PATHNAME}
if [ ! -f .config ]; then
	if [ -d ${TOP_DIR}/configs/${TARGET_BOARDDOGWRT_CONFIG} ]; then
		CURRPATH=$PWD
		readonly CURRPATH
		touch ${CURRPATH}/.config
		(cd ${TOP_DIR}/configs/${TARGET_BOARDDOGWRT_CONFIG} && {
			for FILE in $(ls); do
				if [ -f ${FILE} ]; then
					echo "# apply ${FILE} to .config"
					cat ${FILE} >>${CURRPATH}/.config
				fi
			done
		})
	else
		cp ${TOP_DIR}/configs/${TARGET_BOARDDOGWRT_CONFIG} .config
	fi
	sed -i -e '/^#  -/d' .config
	echo CONFIG_ALL_KMODS=y >>.config

	# Fix compilation errors on the arm64 platform
	if uname -mpi | grep aarch64 >/dev/null; then
		if [ -e /usr/lib/go ]; then
			if grep -q "CONFIG_GOLANG_EXTERNAL_BOOTSTRAP_ROOT" .config; then
				sed -i '/CONFIG_GOLANG_EXTERNAL_BOOTSTRAP_ROOT/d' .config
			fi
			echo "CONFIG_GOLANG_EXTERNAL_BOOTSTRAP_ROOT=\"/usr/lib/go\"" >>.config
		fi
		if [ ! -e /usr/include/asm ]; then
			sudo ln -s /usr/include/aarch64-linux-gnu/asm /usr/include/asm
		fi
	fi

	make defconfig
else
	echo "using .config file"
fi

true ${DEBUG_DOT_CONFIG:=0}
if [ $DEBUG_DOT_CONFIG -eq 1 ]; then
	echo "Abort because DEBUG_DOT_CONFIG=1"
	exit 0
fi

if [ ! -d dl ]; then
	# FORTEST
	# cp -af /opt4/openwrt-full-dl ./dl
	echo "dl directory doesn't  exist. Will make download full package from openwrt site."
fi
make download -j$WRT_JOB
find dl -size -1024c -exec ls -l {} \;
find dl -size -1024c -exec rm -f {} \;

make -j$WRT_JOB
RET=$?
if [ $RET -eq 0 ]; then
	exit 0
fi

make -j1 V=s
RET=$?
if [ $RET -eq 0 ]; then
	exit 0
fi

exit 1
