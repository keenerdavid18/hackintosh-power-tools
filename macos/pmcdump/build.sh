#!/bin/bash
# Build PMCDump.kext (read-only PCI config space dumper) with the Xcode SDK.
set -e
cd "$(dirname "$0")"
SDK=$(xcrun --show-sdk-path); K=$SDK/System/Library/Frameworks/Kernel.framework/Headers
FL=(-arch x86_64 -mkernel -fapple-kext -nostdlib -fno-builtin -fno-common -mno-red-zone -fno-stack-protector
    -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT -I"$K" -isysroot "$SDK" -mmacosx-version-min=11.0 -O2)
xcrun clang++ "${FL[@]}" -std=c++17 -fno-exceptions -fno-rtti -c PMCDump.cpp -o PMCDump.o
xcrun clang "${FL[@]}" -c kmod_info.c -o kmod_info.o
mkdir -p PMCDump.kext/Contents/MacOS
xcrun clang++ -arch x86_64 -nostdlib -Xlinker -kext -Xlinker -export_dynamic -mmacosx-version-min=11.0 -isysroot "$SDK" \
    PMCDump.o kmod_info.o -lkmod -lkmodc++ -lcc_kext -o PMCDump.kext/Contents/MacOS/PMCDump
rm -f PMCDump.o kmod_info.o
echo built PMCDump.kext
