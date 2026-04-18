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
    
    # Verify download
    if [ ! -s $LAME_TARBALL ]; then
        echo "Error: Lame download failed (empty file)"
        rm -f $LAME_TARBALL
        exit 1
    fi
    
    # Verify it's a valid gzip file
    if ! gzip -t $LAME_TARBALL 2>/dev/null; then
        echo "Error: Downloaded Lame file is not a valid gzip archive"
        rm -f $LAME_TARBALL
        exit 1
    fi
    
    echo "Lame download verified successfully"
fi

# OpenSSL configuration (for HTTPS support)
OPENSSL_VERSION=3.0.15
OPENSSL_TARBALL=openssl-$OPENSSL_VERSION.tar.gz
OPENSSL_URL=https://www.openssl.org/source/$OPENSSL_TARBALL
OPENSSL_SHA256=23c666d0edf20f14249b3d8f0368acaee9ab585b09e1de82107c66e1f3ec9533

if [ ! -e $OPENSSL_TARBALL ]; then
    echo "Downloading OpenSSL $OPENSSL_VERSION..."
    curl -s -L -o $OPENSSL_TARBALL $OPENSSL_URL
    
    # Verify download
    if [ ! -s $OPENSSL_TARBALL ]; then
        echo "Error: OpenSSL download failed (empty file)"
        rm -f $OPENSSL_TARBALL
        exit 1
    fi
    
    # Verify it's a valid gzip file
    if ! gzip -t $OPENSSL_TARBALL 2>/dev/null; then
        echo "Error: Downloaded OpenSSL file is not a valid gzip archive"
        echo "File size: $(stat -c%s $OPENSSL_TARBALL 2>/dev/null || stat -f%z $OPENSSL_TARBALL 2>/dev/null || echo 'unknown')"
        rm -f $OPENSSL_TARBALL
        exit 1
    fi
    
    # Verify SHA256 checksum
    if command -v sha256sum >/dev/null 2>&1; then
        echo "$OPENSSL_SHA256  $OPENSSL_TARBALL" | sha256sum -c - || {
            echo "Error: OpenSSL checksum verification failed"
            rm -f $OPENSSL_TARBALL
            exit 1
        }
    fi
    
    echo "OpenSSL download verified successfully"
fi

: ${ARCH?}

OUTPUT_DIR=artifacts/ffmpeg-$FFMPEG_VERSION-audio-$ARCH-linux-gnu

LAME_HOST=""
LAME_CFLAGS=""
OPENSSL_TARGET=""
OPENSSL_EXTRA_FLAGS=""
OPENSSL_CROSS_COMPILE=""

case $ARCH in
    x86_64)
        OPENSSL_TARGET="linux-x86_64"
        ;;
    i686)
        FFMPEG_CONFIGURE_FLAGS+=(--cc="gcc -m32")
        LAME_CFLAGS="-m32"
        OPENSSL_TARGET="linux-x86"
        OPENSSL_EXTRA_FLAGS="-m32"
        ;;
    arm64)
        FFMPEG_CONFIGURE_FLAGS+=(
            --enable-cross-compile
            --cross-prefix=aarch64-linux-gnu-
            --target-os=linux
            --arch=aarch64
        )
        LAME_HOST="aarch64-linux-gnu"
        OPENSSL_TARGET="linux-aarch64"
        OPENSSL_CROSS_COMPILE="aarch64-linux-gnu-"
        ;;
    arm*)
        FFMPEG_CONFIGURE_FLAGS+=(
            --enable-cross-compile
            --cross-prefix=arm-linux-gnueabihf-
            --target-os=linux
            --arch=arm
        )
        LAME_HOST="arm-linux-gnueabihf"
        OPENSSL_TARGET="linux-armv4"
        OPENSSL_CROSS_COMPILE="arm-linux-gnueabihf-"
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

# Build OpenSSL
echo "Building OpenSSL..."
cd $BUILD_DIR
tar -xf $BASE_DIR/$OPENSSL_TARBALL
cd openssl-$OPENSSL_VERSION

# Configure OpenSSL with cross-compile support
OPENSSL_CONFIGURE_CMD="./Configure $OPENSSL_TARGET \
    --prefix=$DEPS_DIR \
    --openssldir=$DEPS_DIR/ssl \
    no-shared \
    no-tests"

# Add cross-compile prefix if set
if [ -n "$OPENSSL_CROSS_COMPILE" ]; then
    OPENSSL_CONFIGURE_CMD="$OPENSSL_CONFIGURE_CMD --cross-compile-prefix=$OPENSSL_CROSS_COMPILE"
fi

# Add extra flags if set
if [ -n "$OPENSSL_EXTRA_FLAGS" ]; then
    OPENSSL_CONFIGURE_CMD="$OPENSSL_CONFIGURE_CMD $OPENSSL_EXTRA_FLAGS"
fi

eval $OPENSSL_CONFIGURE_CMD
make -j$(nproc 2>/dev/null || echo 4)
make install_sw install_ssldirs

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
    --enable-version3
    --enable-openssl
    --enable-libmp3lame
    --enable-encoder=libmp3lame
    --enable-filter=aresample
)

./configure "${FFMPEG_CONFIGURE_FLAGS[@]}" || (cat ffbuild/config.log && exit 1)

make
make install

chown $(stat -c '%u:%g' $BASE_DIR) -R $BASE_DIR/$OUTPUT_DIR
