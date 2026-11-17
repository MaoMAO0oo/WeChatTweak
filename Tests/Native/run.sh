#!/bin/sh
set -eu
if [ "$(uname -m)" != arm64 ]; then
    echo "arm64 entry ABI: skipped on another architecture"
    exit 0
fi
probe_project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
probe_output_dir=$(mktemp -d "${TMPDIR:-/tmp}/wechattweak-abi.XXXXXX")
trap 'rm -rf "$probe_output_dir"' EXIT
ulimit -c 0
xcrun clang++ -std=c++17 -arch arm64 -g -O0 \
    "$probe_project_dir/Tests/Native/EntryABIProbe.cpp" \
    "$probe_project_dir/Sources/WeChatTweakRuntime/Entries.S" \
    -o "$probe_output_dir/probe"
"$probe_output_dir/probe"
xcrun clang++ -std=c++17 -arch arm64 -fobjc-arc -framework Foundation \
    "$probe_project_dir/Tests/Native/CapturePolicyProbe.mm" \
    -o "$probe_output_dir/capture-probe"
"$probe_output_dir/capture-probe" "$probe_project_dir/config.json"
