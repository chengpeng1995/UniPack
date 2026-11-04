#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
OUTPUT="${1:-$ROOT/.build/file-signer}"
OPENSSL_ROOT="${UNIPACK_OPENSSL_ROOT:-/opt/homebrew/opt/openssl@3}"
SOURCE="$ROOT/Vendor/zsign/src"
OBJECTS="$OUTPUT/obj"
mkdir -p "$OBJECTS" "$OUTPUT/bin" "$OUTPUT/Frameworks/ossl-modules"
if [[ ! -f "$OPENSSL_ROOT/lib/libcrypto.3.dylib" ]]; then
  echo '缺少 OpenSSL 3；请先安装 Homebrew openssl@3，或指定 UNIPACK_OPENSSL_ROOT。' >&2
  exit 1
fi
CXXFLAGS=(-std=c++11 -O2 -mmacosx-version-min=26.0 -I"$SOURCE" -I"$SOURCE/common" -I"$SOURCE/third-party/zlib" -I"$OPENSSL_ROOT/include")
object_files=()
for source_file in "$SOURCE"/*.cpp "$SOURCE"/common/*.cpp "$ROOT/tools/file-signer/main.cpp"; do
  case "$(basename "$source_file")" in zsign.cpp|certcheck.cpp) continue ;; esac
  object_file="$OBJECTS/$(basename "$source_file").o"
  if [[ ! -f "$object_file" || "$source_file" -nt "$object_file" ]]; then
    xcrun clang++ "${CXXFLAGS[@]}" -c "$source_file" -o "$object_file"
  fi
  object_files+=("$object_file")
done
for source_file in "$SOURCE"/third-party/zlib/*.c "$SOURCE"/third-party/minizip/ioapi.c "$SOURCE"/third-party/minizip/zip.c "$SOURCE"/third-party/minizip/unzip.c; do
  object_file="$OBJECTS/$(basename "$source_file").o"
  if [[ ! -f "$object_file" || "$source_file" -nt "$object_file" ]]; then
    xcrun clang -O2 -mmacosx-version-min=26.0 -I"$SOURCE/third-party/zlib" -c "$source_file" -o "$object_file"
  fi
  object_files+=("$object_file")
done
xcrun clang++ -mmacosx-version-min=26.0 "${object_files[@]}" -L"$OPENSSL_ROOT/lib" -lssl -lcrypto -Wl,-rpath,@executable_path/../Frameworks -o "$OUTPUT/bin/unipack-file-signer"
cp -f -L "$OPENSSL_ROOT/lib/libcrypto.3.dylib" "$OUTPUT/Frameworks/"
cp -f -L "$OPENSSL_ROOT/lib/libssl.3.dylib" "$OUTPUT/Frameworks/"
cp -f -L "$OPENSSL_ROOT/lib/ossl-modules/legacy.dylib" "$OUTPUT/Frameworks/ossl-modules/"
chmod u+w "$OUTPUT/Frameworks/libcrypto.3.dylib" "$OUTPUT/Frameworks/libssl.3.dylib" "$OUTPUT/Frameworks/ossl-modules/legacy.dylib"
for binary in "$OUTPUT/bin/unipack-file-signer" "$OUTPUT/Frameworks/libcrypto.3.dylib" "$OUTPUT/Frameworks/libssl.3.dylib" "$OUTPUT/Frameworks/ossl-modules/legacy.dylib"; do
  while IFS= read -r dependency; do
    case "$(basename "$dependency")" in
      libcrypto.3.dylib) install_name_tool -change "$dependency" '@rpath/libcrypto.3.dylib' "$binary" ;;
      libssl.3.dylib) install_name_tool -change "$dependency" '@rpath/libssl.3.dylib' "$binary" ;;
    esac
  done < <(otool -L "$binary" | awk 'NR>1 {print $1}')
  codesign --force --sign - "$binary"
done
