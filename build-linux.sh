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

# Configure OpenSSL for native build (auto-detect platform)
./Configure \
    --prefix=$DEPS_DIR \
    --openssldir=$DEPS_DIR/ssl \
    no-shared \
    no-tests \
    -Os

make -j$(nproc 2>/dev/null || echo 4)
make install_sw install_ssldirs

# Create pkg-config files for OpenSSL
mkdir -p $DEPS_DIR/lib/pkgconfig

cat > $DEPS_DIR/lib/pkgconfig/openssl.pc <<EOF
prefix=$DEPS_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: OpenSSL
Description: Secure Sockets Layer and cryptography libraries and tools
Version: $OPENSSL_VERSION
Requires: libssl libcrypto
EOF

cat > $DEPS_DIR/lib/pkgconfig/libssl.pc <<EOF
prefix=$DEPS_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: OpenSSL-libssl
Description: Secure Sockets Layer and cryptography libraries
Version: $OPENSSL_VERSION
Requires.private: libcrypto
Libs: -L\${libdir} -lssl
Cflags: -I\${includedir}
EOF

cat > $DEPS_DIR/lib/pkgconfig/libcrypto.pc <<EOF
prefix=$DEPS_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: OpenSSL-libcrypto
Description: OpenSSL cryptography library
Version: $OPENSSL_VERSION
Libs: -L\${libdir} -lcrypto
Cflags: -I\${includedir}
EOF

# Set PKG_CONFIG_PATH to include our dependencies
export PKG_CONFIG_PATH=$DEPS_DIR/lib/pkgconfig:${PKG_CONFIG_PATH:-}

# Build LAME
echo "Building Lame..."
cd $BUILD_DIR
tar -xf $BASE_DIR/$LAME_TARBALL
cd lame-$LAME_VERSION
./configure \
    --prefix=$DEPS_DIR \
    --disable-shared \
    --enable-static \
    --disable-frontend \
    CFLAGS="-Os"
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

cd $BUILD_DIR

cd $BUILD_DIR
tar --strip-components=1 -xf $BASE_DIR/$FFMPEG_TARBALL

FFMPEG_CONFIGURE_FLAGS+=(
    --prefix=$BASE_DIR/$OUTPUT_DIR
    --extra-cflags="-I$DEPS_DIR/include -Os"
    --extra-ldflags="-L$DEPS_DIR/lib -Wl,--gc-sections"
    --extra-libs="-lpthread -lm"
    --enable-gpl
    --enable-version3
    --enable-openssl
    --enable-nonfree
    --enable-libmp3lame
    --enable-encoder=libmp3lame
    --enable-filter=aresample
    --enable-small
)

# Debug: Print PKG_CONFIG_PATH
echo "PKG_CONFIG_PATH=$PKG_CONFIG_PATH"
echo "Contents of $DEPS_DIR/lib/pkgconfig:"
ls -la $DEPS_DIR/lib/pkgconfig/ || echo "Directory not found"
echo "Content of openssl.pc:"
cat $DEPS_DIR/lib/pkgconfig/openssl.pc || echo "File not found"
echo "Checking pkg-config for openssl:"
pkg-config --exists openssl && echo "OpenSSL found via pkg-config" || echo "OpenSSL NOT found via pkg-config"
pkg-config --modversion openssl 2>/dev/null || echo "Cannot get OpenSSL version"

./configure "${FFMPEG_CONFIGURE_FLAGS[@]}" || (cat ffbuild/config.log && exit 1)

make
make install

# Strip binaries to reduce size
echo "Stripping binaries to reduce size..."
strip $BASE_DIR/$OUTPUT_DIR/bin/ffmpeg
strip $BASE_DIR/$OUTPUT_DIR/bin/ffprobe

# Show final sizes
echo "Final binary sizes:"
ls -lh $BASE_DIR/$OUTPUT_DIR/bin/ffmpeg
ls -lh $BASE_DIR/$OUTPUT_DIR/bin/ffprobe

chown $(stat -c '%u:%g' $BASE_DIR) -R $BASE_DIR/$OUTPUT_DIR
