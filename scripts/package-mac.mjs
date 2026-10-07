import { execFileSync, spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
} from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  selectSigningIdentity,
  verifySigningIdentity,
} from "./mac-signing.mjs";

if (process.platform !== "darwin") {
  throw new Error("Build the macOS installer on macOS.");
}
const root = dirname(dirname(fileURLToPath(import.meta.url)));
const signingIdentity = selectSigningIdentity(
  execFileSync("security", ["find-identity", "-v", "-p", "codesigning"], {
    encoding: "utf8",
  }),
  process.env.APPLE_SIGNING_IDENTITY,
);
const run = (command, args) =>
  execFileSync(command, args, {
    cwd: root,
    stdio: "inherit",
    env: { ...process.env, APPLE_SIGNING_IDENTITY: signingIdentity },
  });

run("npx", ["--no-install", "tauri", "build", "--bundles", "app"]);
const app = join(root, "src-tauri/target/release/bundle/macos/Cue.app");
run("codesign", ["--verify", "--deep", "--strict", app]);
// codesign prints display output to stderr even on success.
const inspect = (args) => {
  const result = spawnSync("codesign", args, { encoding: "utf8" });
  if (result.error || result.status !== 0)
    throw result.error || new Error(result.stderr);
  return result.stdout + result.stderr;
};
const config = JSON.parse(
  readFileSync(join(root, "src-tauri/tauri.conf.json"), "utf8"),
);
verifySigningIdentity(
  inspect(["-dv", "--verbose=4", app]),
  inspect(["-dr", "-", app]),
  config.identifier,
);
const runtime = join(root, "src-tauri/target/dmg-runtime");
const python = join(runtime, "bin/python");
if (!existsSync(python)) run("python3", ["-m", "venv", runtime]);
run(python, [
  "-m",
  "pip",
  "install",
  "--disable-pip-version-check",
  "--requirement",
  "scripts/dmg-requirements.txt",
]);

const { version } = JSON.parse(
  readFileSync(join(root, "package.json"), "utf8"),
);
const architecture = process.arch === "arm64" ? "aarch64" : process.arch;
const output = join(root, "src-tauri/target/release/bundle/dmg");
mkdirSync(output, { recursive: true });
const target = join(output, `Cue_${version}_${architecture}.dmg`);
const temporary = join(output, `Cue_${version}_${architecture}.building.dmg`);
rmSync(temporary, { force: true });
try {
  run(join(runtime, "bin/dmgbuild"), [
    "--settings",
    "scripts/dmg-settings.py",
    "-D",
    `app=${app}`,
    "-D",
    `icon=${join(root, "src-tauri/icons/icon.icns")}`,
    "Cue",
    temporary,
  ]);
  renameSync(temporary, target);
  console.log(`Installer ready: ${target}`);
} finally {
  rmSync(temporary, { force: true });
}
