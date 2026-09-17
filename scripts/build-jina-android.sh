#!/usr/bin/env bash
set -euo pipefail
asko_repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
cd "$asko_repo"
asko_toolchain=$(cat .cache/toolchain-path)
asko_revision=ebbb185227c31f1652f1445e2623563d2f67fe5a
mkdir -p .cache/jina
if [ ! -d .cache/jina/llama.cpp/.git ]; then
    git init -q .cache/jina/llama.cpp
    git -C .cache/jina/llama.cpp remote add origin https://github.com/ggml-org/llama.cpp.git
    git -C .cache/jina/llama.cpp fetch --depth 1 origin "$asko_revision"
    git -C .cache/jina/llama.cpp checkout --detach FETCH_HEAD
fi
test "$(git -C .cache/jina/llama.cpp rev-parse HEAD)" = "$asko_revision"
if [ ! -f .cache/jina/model.gguf ]; then
    curl -fLsS --retry 2 -o .cache/jina/model.gguf.part \
      https://huggingface.co/jinaai/jina-embeddings-v5-text-nano-retrieval-GGUF/resolve/59cfaceeeb7d738c404659435af4c0da74d06c96/v5-nano-retrieval-Q8_0.gguf
    printf '%s  %s\n' 86b6e6279e9b9e71389f02a082764a2ac2b15a50e37482c26f98d69092f12442 .cache/jina/model.gguf.part | sha256sum -c -
    mv .cache/jina/model.gguf.part .cache/jina/model.gguf
fi
printf '%s  %s\n' 86b6e6279e9b9e71389f02a082764a2ac2b15a50e37482c26f98d69092f12442 .cache/jina/model.gguf | sha256sum -c -
cmake -S .cache/jina/llama.cpp -B .cache/jina/build-android -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$asko_toolchain/android-ndk-r29/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-26 -DANDROID_STL=c++_static \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_OPENMP=OFF \
  -DGGML_NATIVE=OFF -DLLAMA_OPENSSL=OFF -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TOOLS=ON -DLLAMA_BUILD_SERVER=ON
cmake --build .cache/jina/build-android --target llama-server -j "${ASKO_JOBS:-8}"
