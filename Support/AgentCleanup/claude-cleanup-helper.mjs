import { createInterface } from "node:readline";

const reader = createInterface({ input: process.stdin, crlfDelay: Infinity });
const line = await new Promise((resolve) => reader.once("line", resolve));
reader.close();

try {
  const request = JSON.parse(line);
  if (request.claudeHome) process.env.CLAUDE_CONFIG_DIR = request.claudeHome;
  const sdk = await import("./claude-agent-sdk/sdk.mjs");
  if (typeof sdk.deleteSession !== "function"
      || typeof sdk.getSessionInfo !== "function"
      || typeof sdk.listSessions !== "function") {
    throw new Error("Required official session APIs are unavailable");
  }

  if (request.operation === "probe") {
    console.log(JSON.stringify({ sdkVersion: "0.3.220" }));
  } else if (request.operation === "delete") {
    const options = { dir: request.dir };
    const before = await sdk.getSessionInfo(request.sessionId, options);
    if (!before) {
      const sessions = await sdk.listSessions({
        dir: request.dir,
        includeWorktrees: false,
        includeProgrammatic: true,
      });
      const exists = sessions.some((session) => session.sessionId === request.sessionId);
      if (exists) throw new Error("Session lookup is inconsistent");
      console.log(JSON.stringify({ alreadyAbsent: true }));
    } else {
      if (before.sessionId !== request.sessionId || before.cwd !== request.dir) {
        throw new Error("Session identity or project directory changed");
      }
      await sdk.deleteSession(request.sessionId, options);
      const after = await sdk.getSessionInfo(request.sessionId, options);
      if (after) throw new Error("Official SDK did not confirm deletion");
      console.log(JSON.stringify({ deleted: true }));
    }
  } else {
    throw new Error("Unsupported helper operation");
  }
} catch (error) {
  console.log(JSON.stringify({ error: error instanceof Error ? error.message : String(error) }));
  process.exitCode = 1;
}
