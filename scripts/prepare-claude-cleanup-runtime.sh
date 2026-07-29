#!/bin/zsh
set -euo pipefail

sdk_version="0.3.220"
sdk_sha256="6e631effbd48827bb09d8e07a7c715fd8059bccdaaa553635794be1c663bc7a9"
node_version="24.14.1"
node_arm64_sha256="25495ff85bd89e2d8a24d88566d7e2f827c6b0d3d872b2cebf75371f93fcb1fe"
node_x64_sha256="2526230ad7d922be82d4fdb1e7ee1e84303e133e3b4b0ec4c2897ab31de0253d"

cache_root="$(getconf DARWIN_USER_CACHE_DIR)/com.jianyintang.FindDiskKiller/AgentCleanup"
resource_root="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/AgentCleanup"
sdk_archive="${cache_root}/claude-agent-sdk-${sdk_version}.tgz"
mkdir -p "${cache_root}" "${resource_root}/claude-agent-sdk"

verify_sha256() {
  local expected="$1"
  local file="$2"
  [[ "$(shasum -a 256 "${file}" | awk '{print $1}')" == "${expected}" ]]
}

if [[ ! -f "${sdk_archive}" ]] || ! verify_sha256 "${sdk_sha256}" "${sdk_archive}"; then
  curl --http1.1 --retry 3 -sSfL \
    "https://registry.npmjs.org/@anthropic-ai/claude-agent-sdk/-/claude-agent-sdk-${sdk_version}.tgz" \
    -o "${sdk_archive}.download"
  verify_sha256 "${sdk_sha256}" "${sdk_archive}.download"
  mv "${sdk_archive}.download" "${sdk_archive}"
fi

sdk_stage="$(mktemp -d "${TMPDIR%/}/fdk-claude-sdk.XXXXXX")"
trap 'rm -rf "${sdk_stage}"' EXIT
tar -xzf "${sdk_archive}" -C "${sdk_stage}"
cp "${sdk_stage}/package/sdk.mjs" "${resource_root}/claude-agent-sdk/sdk.mjs"
cp "${sdk_stage}/package/package.json" "${resource_root}/claude-agent-sdk/package.json"
cp "${sdk_stage}/package/LICENSE.md" "${resource_root}/claude-agent-sdk/LICENSE.md"
cp "${SRCROOT}/Support/AgentCleanup/claude-cleanup-helper.mjs" "${resource_root}/claude-cleanup-helper.mjs"

node_binaries=()
build_architectures=("${(@s: :)ARCHS}")
for node_arch in "${build_architectures[@]}"; do
  [[ "${node_arch}" == "arm64" || "${node_arch}" == "x86_64" ]] || continue
  [[ "${node_arch}" == "x86_64" ]] && node_arch="x64"
  installed_node="$(command -v node || true)"
  if [[ -n "${installed_node}" \
      && "$("${installed_node}" --version)" == "v${node_version}" \
      && "$(file "${installed_node}")" == *"${node_arch/x64/x86_64}"* ]]; then
    node_binaries+=("${installed_node}")
    continue
  fi
  node_archive="${cache_root}/node-v${node_version}-darwin-${node_arch}.tar.gz"
  expected_sha="${node_arm64_sha256}"
  [[ "${node_arch}" == "x64" ]] && expected_sha="${node_x64_sha256}"
  if [[ ! -f "${node_archive}" ]] || ! verify_sha256 "${expected_sha}" "${node_archive}"; then
    curl --http1.1 --retry 3 -sSfL \
      "https://nodejs.org/dist/v${node_version}/node-v${node_version}-darwin-${node_arch}.tar.gz" \
      -o "${node_archive}.download"
    verify_sha256 "${expected_sha}" "${node_archive}.download"
    mv "${node_archive}.download" "${node_archive}"
  fi
  node_stage="${sdk_stage}/node-${node_arch}"
  mkdir -p "${node_stage}"
  tar -xzf "${node_archive}" -C "${node_stage}" --strip-components=1
  node_binaries+=("${node_stage}/bin/node")
done

[[ "${#node_binaries[@]}" -gt 0 ]]
lipo -create "${node_binaries[@]}" -output "${resource_root}/node"
chmod 755 "${resource_root}/node"
signing_identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
codesign --force --sign "${signing_identity}" --timestamp=none "${resource_root}/node"
