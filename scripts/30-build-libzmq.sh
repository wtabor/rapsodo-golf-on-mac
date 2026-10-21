#!/usr/bin/env bash
# Cross-build libzmq 4.3.5 for Windows x64 (UCRT) with the Wine deadlock patch,
# linked against the app's own libsodium-26.dll. Output: $RGM_BUILD/libzmq.dll
#
# Why: libzmq's make_fdpair_tcpip pushes 1 MB through a blocking loopback socket
# before reading it ("TCP slow start" workaround, zeromq #1608). Windows buffers
# that; Wine on macOS blocks forever, so the app never connects to the monitor.
#
# Needs: brew install mingw-w64 cmake
set -euo pipefail
. "$(dirname "$0")/env.sh"

command -v x86_64-w64-mingw32-g++ >/dev/null || { echo "brew install mingw-w64" >&2; exit 1; }
command -v cmake >/dev/null || { echo "brew install cmake" >&2; exit 1; }

B="$RGM_BUILD/libzmq"
mkdir -p "$B"
cd "$B"

[ -d zeromq-4.3.5 ] || { curl -fsSL https://github.com/zeromq/libzmq/releases/download/v4.3.5/zeromq-4.3.5.tar.gz | tar xz; }
[ -d libsodium-win64 ] || { curl -fsSL https://download.libsodium.org/libsodium/releases/libsodium-1.0.20-mingw.tar.gz | tar xz; }

# Wine fix (idempotent).
if ! grep -q "if (false && \*r_ != INVALID_SOCKET)" zeromq-4.3.5/src/ip.cpp; then
  patch -d zeromq-4.3.5 -p1 < "$RGM_REPO/patches/libzmq-4.3.5-no-fdpair-slowstart.patch"
fi
# MinGW cross-build fix: CMake detects AF_UNIX IPC, but ipc_address.hpp only
# includes afunix.h under MSVC. The original DLL used the TCP signaler anyway.
sed -i '' 's|^#cmakedefine ZMQ_HAVE_IPC$|/* IPC off for MinGW cross-build */|; s|^#cmakedefine ZMQ_HAVE_STRUCT_SOCKADDR_UN$|/* sockaddr_un off */|' \
  zeromq-4.3.5/builds/cmake/platform.hpp.in

cat > mingw.cmake <<'EOF'
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_C_COMPILER x86_64-w64-mingw32-gcc)
set(CMAKE_CXX_COMPILER x86_64-w64-mingw32-g++)
set(CMAKE_RC_COMPILER x86_64-w64-mingw32-windres)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
EOF

S="$PWD/libsodium-win64"
rm -rf build
cmake -S zeromq-4.3.5 -B build -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_TOOLCHAIN_FILE="$PWD/mingw.cmake" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_SYSTEM_VERSION=10.0 -DZMQ_WIN32_WINNT=0x0A00 \
  -DWITH_LIBSODIUM=ON -DENABLE_CURVE=ON -DPOLLER=select \
  -DBUILD_TESTS=OFF -DBUILD_STATIC=OFF -DBUILD_SHARED=ON \
  -DWITH_PERF_TOOL=OFF -DWITH_DOCS=OFF -DENABLE_DRAFTS=OFF -DENABLE_PRECOMPILED=OFF \
  -DSODIUM_INCLUDE_DIRS="$S/include" -DSODIUM_LIBRARIES="$S/lib/libsodium.dll.a" \
  -DCMAKE_SHARED_LINKER_FLAGS="-static-libgcc -static-libstdc++" >/dev/null

grep -q "#define ZMQ_HAVE_CURVE" build/platform.hpp || { echo "CURVE not enabled; libsodium not found" >&2; exit 1; }
cmake --build build -j "$(sysctl -n hw.ncpu)" >/dev/null
cp build/bin/libzmq.dll "$RGM_BUILD/libzmq.dll"
imports="$(x86_64-w64-mingw32-objdump -p "$RGM_BUILD/libzmq.dll")"
grep -q "libsodium-26.dll" <<<"$imports" || { echo "built DLL doesn't link libsodium-26.dll" >&2; exit 1; }
echo "Built $RGM_BUILD/libzmq.dll"
