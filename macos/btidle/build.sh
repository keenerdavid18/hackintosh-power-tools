#!/bin/bash
# Build BTIdle.kext (Bluetooth USB idle policy) with the Xcode SDK.
set -e
cd "$(dirname "$0")"
SDK=$(xcrun --show-sdk-path); K=$SDK/System/Library/Frameworks/Kernel.framework/Headers
FL=(-arch x86_64 -mkernel -fapple-kext -nostdlib -fno-builtin -fno-common -mno-red-zone -fno-stack-protector
    -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT -I"$K" -isysroot "$SDK" -mmacosx-version-min=11.0 -O2)
xcrun clang++ "${FL[@]}" -std=c++17 -fno-exceptions -fno-rtti -Wno-inconsistent-missing-override -Wno-deprecated-declarations -c BTIdle.cpp -o BTIdle.o
xcrun clang "${FL[@]}" -c kmod_info.c -o kmod_info.o
mkdir -p BTIdle.kext/Contents/MacOS
xcrun clang++ -arch x86_64 -nostdlib -Xlinker -kext -Xlinker -export_dynamic -mmacosx-version-min=11.0 -isysroot "$SDK" \
    BTIdle.o kmod_info.o -lkmod -lkmodc++ -lcc_kext -o BTIdle.kext/Contents/MacOS/BTIdle
rm -f BTIdle.o kmod_info.o
echo built BTIdle.kext
