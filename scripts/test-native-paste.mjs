import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

if (process.platform !== "darwin") {
  console.log("Native paste tests require macOS.");
  process.exit(0);
}
const root = dirname(dirname(fileURLToPath(import.meta.url)));
const temporary = mkdtempSync(join(tmpdir(), "cue-paste-tests-"));
try {
  const binary = join(temporary, "paste-tests");
  execFileSync(
    "xcrun",
    [
      "clang",
      "-fobjc-arc",
      "-fblocks",
      "-Wno-deprecated-declarations",
      join(root, "src-tauri/native/paste.test.m"),
      "-framework",
      "AppKit",
      "-framework",
      "ApplicationServices",
      "-framework",
      "Carbon",
      "-o",
      binary,
    ],
    { stdio: "inherit" },
  );
  execFileSync(binary, [], { stdio: "inherit" });
} finally {
  rmSync(temporary, { recursive: true, force: true });
}
