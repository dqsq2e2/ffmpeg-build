#!/usr/bin/env bash

set -eu

cd $(dirname $0)
BASE_DIR=$(pwd)

source common.sh

if [ ! -e $FFMPEG_TARBALL ]
then
	curl -s -L -O $FFMPEG_TARBALL_URL
fi

# LAME configuration
LAME_VERSION=3.100
LAME_TARBALL=lame-$LAME_VERSION.tar.gz
LAME_URL=https://downloads.sourceforge.net/project/lame/lame/$LAME_VERSION/$LAME_TARBALL

if [ ! -e $LAME_TARBALL ]; then
    echo "Downloading Lame $LAME_VERSION..."
    curl -s -L -o $LAME_TARBALL $LAME_URL
fi

: ${ARCH?}

OUTPUT_DIR=artifacts/ffmpeg-$FFMPEG_VERSION-audio-$ARCH-linux-gnu

LAME_HOST=""
LAME_CFLAGS=""

case $ARCH in
    x86_64)
        ;;
    i686)
        FFMPEG_CONFIGURE_FLAGS+=(--cc="gcc -m32")
        LAME_CFLAGS="-m32"
        ;;
    arm64)
        FFMPEG_CONFIGURE_FLAGS+=(
            --enable-cross-compile
            --cross-prefix=aarch64-linux-gnu-
            --target-os=linux
            --arch=aarch64
        )
        LAME_HOST="aarch64-linux-gnu"
        ;;
    arm*)
        FFMPEG_CONFIGURE_FLAGS+=(
            --enable-cross-compile
            --cross-prefix=arm-linux-gnueabihf-
            --target-os=linux
            --arch=arm
        )
        LAME_HOST="arm-linux-gnueabihf"
        case $ARCH in
            armv7-a)
                FFMPEG_CONFIGURE_FLAGS+=(
                    --cpu=armv7-a
                )
                ;;
            armv8-a)
                FFMPEG_CONFIGURE_FLAGS+=(
                    --cpu=armv8-a
                )
                ;;
            armhf-rpi2)
                FFMPEG_CONFIGURE_FLAGS+=(
                    --cpu=cortex-a7
                    --extra-cflags='-fPIC -mcpu=cortex-a7 -mfloat-abi=hard -mfpu=neon-vfpv4 -mvectorize-with-neon-quad'
                )
                LAME_CFLAGS="-fPIC -mcpu=cortex-a7 -mfloat-abi=hard -mfpu=neon-vfpv4"
                ;;
            armhf-rpi3)
                FFMPEG_CONFIGURE_FLAGS+=(
                    --cpu=cortex-a53
                    --extra-cflags='-fPIC -mcpu=cortex-a53 -mfloat-abi=hard -mfpu=neon-fp-armv8 -mvectorize-with-neon-quad'
                )
                LAME_CFLAGS="-fPIC -mcpu=cortex-a53 -mfloat-abi=hard -mfpu=neon-fp-armv8"
                ;;
        esac
        ;;
    *)
        echo "Unknown architecture: $ARCH"
        exit 1
        ;;
esac

BUILD_DIR=$(mktemp -d -p $(pwd) build.XXXXXXXX)
trap 'rm -rf $BUILD_DIR' EXIT

# Build dependencies directory
DEPS_DIR=$BASE_DIR/deps-$ARCH
mkdir -p $DEPS_DIR

# Build LAME
echo "Building Lame..."
cd $BUILD_DIR
tar -xf $BASE_DIR/$LAME_TARBALL
cd lame-$LAME_VERSION
./configure \
    --prefix=$DEPS_DIR \
    ${LAME_HOST:+--host=$LAME_HOST} \
    --disable-shared \
    --enable-static \
    --disable-frontend \
    ${LAME_CFLAGS:+CFLAGS="$LAME_CFLAGS"}
make -j$(nproc 2>/dev/null || echo 4)
make install

# Create pkg-config file for Lame
mkdir -p $DEPS_DIR/lib/pkgconfig
cat > $DEPS_DIR/lib/pkgconfig/libmp3lame.pc <<EOF
prefix=$DEPS_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: libmp3lame
Description: High quality MPEG Audio Layer III (MP3) encoder
Version: $LAME_VERSION
Libs: -L\${libdir} -lmp3lame
Cflags: -I\${includedir}
EOF

export PKG_CONFIG_PATH=$DEPS_DIR/lib/pkgconfig:${PKG_CONFIG_PATH:-}
cd $BUILD_DIR

cd $BUILD_DIR
tar --strip-components=1 -xf $BASE_DIR/$FFMPEG_TARBALL

FFMPEG_CONFIGURE_FLAGS+=(
    --prefix=$BASE_DIR/$OUTPUT_DIR
    --extra-cflags="-I$DEPS_DIR/include"
    --extra-ldflags="-L$DEPS_DIR/lib"
    --enable-gpl
    --enable-libmp3lame
    --enable-encoder=libmp3lame
    --enable-filter=aresample
)

./configure "${FFMPEG_CONFIGURE_FLAGS[@]}" || (cat ffbuild/config.log && exit 1)

make
make install

chown $(stat -c '%u:%g' $BASE_DIR) -R $BASE_DIR/$OUTPUT_DIR
