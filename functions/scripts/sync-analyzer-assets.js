const fs = require("node:fs");
const path = require("node:path");

const projectRoot = path.resolve(__dirname, "..");
const sourceRoot = path.resolve(projectRoot, "..", "azure-vm-analysis");
const targetRoot = path.resolve(projectRoot, "assets", "azure-vm-analysis");

const filesToCopy = [
  "azure-vm-assessment.ps1",
  "azure-vm-assessment.config.jsonc",
];

fs.mkdirSync(targetRoot, { recursive: true });

for (const fileName of filesToCopy) {
  const sourcePath = path.join(sourceRoot, fileName);
  const targetPath = path.join(targetRoot, fileName);

  if (!fs.existsSync(sourcePath)) {
    throw new Error(`Missing analyzer asset: ${sourcePath}`);
  }

  fs.copyFileSync(sourcePath, targetPath);
}

process.stdout.write(`Synced analyzer assets to ${targetRoot}\n`);
