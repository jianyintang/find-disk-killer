#!/bin/zsh
set -euo pipefail

app_path="${1:-/private/tmp/find-disk-killer-official-agent-cleanup-derived/Build/Products/Debug/FindDiskKiller.app}"
claude_helper="${app_path}/Contents/MacOS/FindDiskKillerClaudeCleanupHelper"
codex_binary="${FDK_CODEX_APP_SERVER:-/Applications/ChatGPT.app/Contents/Resources/codex}"

[[ -x "${claude_helper}" ]] || { echo "Bundled Claude helper not found" >&2; exit 69; }
[[ -x "${codex_binary}" ]] || { echo "Official Codex app-server not found" >&2; exit 69; }

# The helper no longer embeds a Node.js runtime; pin one explicitly so the
# fixture run does not depend on the helper's own fallback search.
if [[ -z "${FDK_NODE_BINARY:-}" ]]; then
  node_binary="$(command -v node || true)"
  [[ -x "${node_binary}" ]] || { echo "Node.js runtime not found for fixtures" >&2; exit 69; }
  export FDK_NODE_BINARY="${node_binary}"
fi

fixture_root="$(mktemp -d "${TMPDIR%/}/fdk-agent-cleanup-fixtures.XXXXXX")"
trap '[[ "${fixture_root}" == "${TMPDIR%/}"/fdk-agent-cleanup-fixtures.* ]] && rm -rf "${fixture_root}"' EXIT

claude_home="${fixture_root}/claude-home"
workspace="${fixture_root}/workspace"
mkdir -p "${claude_home}" "${workspace}"
workspace="$(cd "${workspace}" && pwd -P)"
project_key="$(printf '%s' "${workspace}" | sed 's/[^a-zA-Z0-9]/-/g')"
session_id="11111111-1111-1111-1111-111111111111"
session_root="${claude_home}/projects/${project_key}"
mkdir -p "${session_root}/${session_id}/subagents" "${claude_home}/tasks/${session_id}"
printf '%s\n' '{"type":"user","sessionId":"11111111-1111-1111-1111-111111111111","uuid":"22222222-2222-2222-2222-222222222222","timestamp":"2026-07-29T00:00:00.000Z","cwd":"'"${workspace}"'","message":{"role":"user","content":"fixture"}}' > "${session_root}/${session_id}.jsonl"
printf '%s\n' '{"type":"assistant","sessionId":"11111111-1111-1111-1111-111111111111","uuid":"33333333-3333-3333-3333-333333333333","parentUuid":"22222222-2222-2222-2222-222222222222","timestamp":"2026-07-29T00:00:01.000Z","cwd":"'"${workspace}"'","message":{"role":"assistant","content":"ok"}}' > "${session_root}/${session_id}/subagents/agent-fixture.jsonl"
printf retained > "${claude_home}/tasks/${session_id}/retained"

claude_result="$(jq -nc \
  --arg id "${session_id}" --arg dir "${workspace}" --arg home "${claude_home}" \
  '{operation:"delete",sessionId:$id,dir:$dir,claudeHome:$home}' | "${claude_helper}")"
[[ "$(jq -r '.deleted' <<<"${claude_result}")" == "true" ]]
[[ ! -e "${session_root}/${session_id}.jsonl" ]]
[[ ! -e "${session_root}/${session_id}" ]]
[[ -e "${claude_home}/tasks/${session_id}/retained" ]]

codex_home="${fixture_root}/codex-home"
mkdir -p "${codex_home}"
codex_home="$(cd "${codex_home}" && pwd -P)"
CODEX_HOME="${codex_home}" CODEX_BIN="${codex_binary}" ruby -rjson -ropen3 -rfileutils -rtime -rsecurerandom <<'RUBY'
def request(stdin, stdout, id, method, params)
  stdin.puts({ id: id, method: method, params: params }.to_json)
  stdin.flush
  loop do
    response = JSON.parse(stdout.readline)
    return response if response["id"] == id
  end
end

def start_server
  stdin, stdout, stderr, wait = Open3.popen3(ENV.fetch("CODEX_BIN"), "app-server")
  initialized = request(stdin, stdout, 1, "initialize", {
    clientInfo: { name: "find-disk-killer-fixture", version: "1" },
    capabilities: { experimentalApi: false }
  })
  abort "unexpected Codex home" unless initialized.dig("result", "codexHome") == ENV.fetch("CODEX_HOME")
  stdin.puts({ method: "initialized" }.to_json)
  stdin.flush
  [stdin, stdout, stderr, wait]
end

def stop_server(stdin, wait)
  stdin.close unless stdin.closed?
  Process.kill("TERM", wait.pid) if wait.alive?
  wait.value
rescue Errno::ESRCH, IOError
  nil
end

def write_rollout(
  thread_id,
  minute,
  source,
  session_id: thread_id,
  parent_thread_id: nil,
  paginated: false
)
  directory = File.join(ENV.fetch("CODEX_HOME"), "sessions", "2026", "07", "29")
  FileUtils.mkdir_p(directory)
  path = File.join(directory, "rollout-2026-07-29T00-#{format('%02d', minute)}-00-#{thread_id}.jsonl")
  timestamp = "2026-07-29T00:#{format('%02d', minute)}:00Z"
  metadata = {
    session_id: session_id,
    id: thread_id,
    timestamp: timestamp,
    cwd: Dir.pwd,
    originator: "codex",
    cli_version: "0.146.0",
    source: source,
    model_provider: "openai",
    base_instructions: nil
  }
  metadata[:parent_thread_id] = parent_thread_id if parent_thread_id
  metadata[:history_mode] = "paginated" if paginated
  lines = [{
    timestamp: "2026-07-29T00:#{format('%02d', minute)}:00Z",
    type: "session_meta",
    payload: metadata
  }, {
    timestamp: timestamp,
    type: "response_item",
    payload: {
      type: "message",
      role: "user",
      content: [{ type: "input_text", text: "fixture" }]
    }
  }]
  lines.each_with_index { |line, index| line[:ordinal] = index } if paginated
  File.write(path, lines.map(&:to_json).join("\n") + "\n")
  path
end

parent_id = SecureRandom.uuid
child_id = SecureRandom.uuid
grandchild_id = SecureRandom.uuid
parent_rollout = write_rollout(parent_id, 0, "vscode")
child_rollout = write_rollout(child_id, 1, {
  subagent: { thread_spawn: { parent_thread_id: parent_id, depth: 1 } }
}, session_id: parent_id, parent_thread_id: parent_id)
grandchild_rollout = write_rollout(grandchild_id, 2, {
  subagent: { thread_spawn: { parent_thread_id: child_id, depth: 2 } }
}, session_id: parent_id, parent_thread_id: child_id)

stdin, stdout, _stderr, wait = start_server
[
  [parent_id, nil],
  [child_id, parent_id],
  [grandchild_id, child_id]
].each_with_index do |(thread_id, expected_parent), index|
  response = request(stdin, stdout, index + 2, "thread/read", {
    threadId: thread_id, includeTurns: false
  })
  abort "thread/read failed for #{thread_id}: #{response}" unless response.dig("result", "thread", "id") == thread_id
  abort "wrong parent for #{thread_id}" unless response.dig("result", "thread", "parentThreadId") == expected_parent
end

deleted = request(stdin, stdout, 5, "thread/delete", { threadId: parent_id })
abort "thread/delete failed" unless deleted["result"] == {}
[[parent_id, parent_rollout], [child_id, child_rollout], [grandchild_id, grandchild_rollout]].each_with_index do |(thread_id, rollout), index|
  after = request(stdin, stdout, index + 6, "thread/read", {
    threadId: thread_id, includeTurns: false
  })
  abort "thread still exists: #{thread_id}" unless after.dig("error", "message")&.start_with?("thread not loaded:")
  abort "rollout still exists: #{rollout}" if File.exist?(rollout)
end

live_id = SecureRandom.uuid
live_rollout = write_rollout(live_id, 3, "vscode", paginated: true)
resumed = request(stdin, stdout, 9, "thread/resume", { threadId: live_id })
abort "thread/resume failed: #{resumed}" unless resumed.dig("result", "thread", "id") == live_id
abort "live fixture is not paginated: #{resumed}" unless resumed.dig("result", "thread", "historyMode") == "paginated"

writer_status, writer_error, writer_wait = Open3.capture3(
  "/usr/sbin/lsof", "-Fpa", "-w", live_rollout
)
abort "lsof failed for live writer: #{writer_error}" unless [0, 1].include?(writer_wait.exitstatus)
writer_access = writer_status.lines.map(&:strip).any? { |line| line == "aw" || line == "au" }
abort "live writer was not detected" unless writer_access
abort "live rollout was removed" unless File.exist?(live_rollout)
stop_server(stdin, wait)

other_stdin, other_stdout, _other_stderr, other_wait = start_server
released = request(other_stdin, other_stdout, 2, "thread/delete", { threadId: live_id })
abort "thread/delete after writer exit failed" unless released["result"] == {}
abort "live rollout still exists after release" if File.exist?(live_rollout)
stop_server(other_stdin, other_wait)

database = Dir[File.join(ENV.fetch("CODEX_HOME"), "state_*.sqlite")].first or abort "missing state database"
counts = Open3.capture2("sqlite3", "-readonly", database,
  "SELECT (SELECT COUNT(*) FROM threads WHERE id IN ('#{parent_id}','#{child_id}','#{grandchild_id}','#{live_id}')) + (SELECT COUNT(*) FROM thread_spawn_edges WHERE parent_thread_id IN ('#{parent_id}','#{child_id}','#{grandchild_id}') OR child_thread_id IN ('#{child_id}','#{grandchild_id}'));"
).first.strip
abort "associated Codex state remains" unless counts == "0"
RUBY

echo "Official Codex and Claude cleanup fixtures passed"
