#!/usr/bin/env bash
set -euo pipefail
asko_repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
cd "$asko_repo"
asko_toolchain=$(cat .cache/toolchain-path)
# llama.cpp v0.8.0; keep the build tied to an immutable commit.
asko_revision=8642541b255bfb5dc39cd351a178be09013a55d6
asko_upstream=https://github.com/ggml-org/llama.cpp.git
asko_source="$asko_repo/.cache/jina/llama.cpp"
asko_ndk="$asko_toolchain/android-ndk-r30"
if [ ! -f "$asko_ndk/build/cmake/android.toolchain.cmake" ]; then
    printf 'Android NDK r30 is missing: %s\n' "$asko_ndk" >&2
    exit 1
fi
asko_ndk=$(cd -- "$asko_ndk" && pwd -P)
mkdir -p .cache/jina
if [ -L "$asko_source" ] || { [ -e "$asko_source" ] && [ ! -d "$asko_source/.git" ]; }; then
    printf 'Refusing to replace an unexpected llama.cpp cache: %s\n' "$asko_source" >&2
    exit 1
fi
if [ ! -d "$asko_source/.git" ]; then
    git init -q "$asko_source"
    git -C "$asko_source" remote add origin "$asko_upstream"
fi
# The build lives outside this checkout, so even ignored files are unexpected.
asko_changes=$(git -C "$asko_source" status --porcelain --untracked-files=all --ignored=matching)
if [ -n "$asko_changes" ]; then
    printf 'llama.cpp cache has local changes; preserve them before retrying: %s\n' "$asko_source" >&2
    exit 1
fi
asko_cached_revision=$(git -C "$asko_source" rev-parse --verify HEAD 2>/dev/null || true)
if [ "$asko_cached_revision" != "$asko_revision" ]; then
    git -C "$asko_source" fetch --no-tags --depth 1 "$asko_upstream" "$asko_revision"
    git -C "$asko_source" checkout --detach --no-overwrite-ignore "$asko_revision"
fi
test "$(git -C "$asko_source" rev-parse HEAD)" = "$asko_revision"
asko_cmake_options=(
  -G Ninja
  "-DCMAKE_TOOLCHAIN_FILE=$asko_ndk/build/cmake/android.toolchain.cmake"
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-26 -DANDROID_STL=c++_static
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_OPENMP=OFF
  -DGGML_NATIVE=OFF -DLLAMA_OPENSSL=OFF -DLLAMA_BUILD_TESTS=OFF
  -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TOOLS=ON -DLLAMA_BUILD_SERVER=ON
  -DLLAMA_BUILD_UI=OFF -DLLAMA_USE_PREBUILT_UI=OFF -DLLAMA_BUILD_APP=OFF
)
# Separate revisions, toolchains, paths and build options; preserve old caches.
asko_build_key=$(printf '%s\n' "$asko_revision" "$asko_source" "${asko_cmake_options[@]}" | sha256sum)
asko_build="$asko_repo/.cache/jina/build-android-${asko_build_key:0:16}"
if [ ! -f .cache/jina/model.gguf ]; then
    curl -fLsS --retry 2 -o .cache/jina/model.gguf.part \
      https://huggingface.co/jinaai/jina-embeddings-v5-text-nano-retrieval-GGUF/resolve/59cfaceeeb7d738c404659435af4c0da74d06c96/v5-nano-retrieval-Q8_0.gguf
    printf '%s  %s\n' 86b6e6279e9b9e71389f02a082764a2ac2b15a50e37482c26f98d69092f12442 .cache/jina/model.gguf.part | sha256sum -c -
    mv .cache/jina/model.gguf.part .cache/jina/model.gguf
fi
printf '%s  %s\n' 86b6e6279e9b9e71389f02a082764a2ac2b15a50e37482c26f98d69092f12442 .cache/jina/model.gguf | sha256sum -c -
cmake -S "$asko_source" -B "$asko_build" "${asko_cmake_options[@]}"
cmake --build "$asko_build" --target llama-server -j "${ASKO_JOBS:-8}"
test -x "$asko_build/bin/llama-server"
printf '%s\n' "$asko_build" > .cache/jina/build-path.part
mv .cache/jina/build-path.part .cache/jina/build-path
