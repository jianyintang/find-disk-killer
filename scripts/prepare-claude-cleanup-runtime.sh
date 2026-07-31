#!/bin/zsh
set -euo pipefail

sdk_version="0.3.220"
sdk_sha256="6e631effbd48827bb09d8e07a7c715fd8059bccdaaa553635794be1c663bc7a9"

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

# The Node.js runtime is no longer embedded: the app reuses a compatible local
# installation at runtime or downloads the pinned official build on demand.
# Remove any runtime left behind by incremental builds of older revisions.
rm -f "${resource_root}/node"
