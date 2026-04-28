const fs = require("node:fs");
const path = require("node:path");
const { spawn } = require("node:child_process");

function getCandidatePaths(relativePath) {
  const candidates = [
    path.resolve(__dirname, "..", "node_modules", "azure-functions-core-tools", relativePath),
  ];

  if (process.platform === "win32" && process.env.APPDATA) {
    candidates.push(
      path.resolve(process.env.APPDATA, "npm", "node_modules", "azure-functions-core-tools", relativePath),
    );
  }

  return candidates;
}

function resolveFirstExisting(candidates) {
  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) {
      return candidate;
    }
  }

  throw new Error(`Unable to find Azure Functions Core Tools entry point. Checked: ${candidates.join(", ")}`);
}

const projectRoot = path.resolve(__dirname, "..");
const nodeExecutable = process.execPath;
const nodeDirectory = path.dirname(nodeExecutable);
const functionsEntry = resolveFirstExisting(getCandidatePaths(path.join("lib", "main.js")));

const env = {
  ...process.env,
  PATH: `${nodeDirectory}${path.delimiter}${process.env.PATH || ""}`,
};

const child = spawn(
  nodeExecutable,
  [functionsEntry, "start", "--port", "7071", "--script-root", projectRoot],
  {
    cwd: projectRoot,
    stdio: "inherit",
    env,
  },
);

child.on("exit", (code, signal) => {
  if (signal) {
    process.kill(process.pid, signal);
    return;
  }

  process.exit(code ?? 1);
});
