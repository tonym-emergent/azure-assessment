const fs = require("node:fs");
const path = require("node:path");
const { spawn } = require("node:child_process");

function getCandidatePaths(relativePath) {
  const candidates = [
    path.resolve(__dirname, "..", "node_modules", "azurite", relativePath),
  ];

  if (process.platform === "win32" && process.env.APPDATA) {
    candidates.push(path.resolve(process.env.APPDATA, "npm", "node_modules", "azurite", relativePath));
  }

  return candidates;
}

function resolveFirstExisting(candidates) {
  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) {
      return candidate;
    }
  }

  throw new Error(`Unable to find Azurite entry point. Checked: ${candidates.join(", ")}`);
}

const projectRoot = path.resolve(__dirname, "..");
const nodeExecutable = process.execPath;
const nodeDirectory = path.dirname(nodeExecutable);
const azuriteEntry = resolveFirstExisting(getCandidatePaths(path.join("dist", "src", "azurite.js")));
const azuritePath = path.join(projectRoot, ".azurite");

fs.mkdirSync(azuritePath, { recursive: true });

const env = {
  ...process.env,
  PATH: `${nodeDirectory}${path.delimiter}${process.env.PATH || ""}`,
};

const child = spawn(
  nodeExecutable,
  [
    azuriteEntry,
    "--location",
    azuritePath,
    "--debug",
    path.join(azuritePath, "debug.log"),
    "--skipApiVersionCheck",
    "--silent",
  ],
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
