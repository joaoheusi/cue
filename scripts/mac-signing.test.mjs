import { test } from "vitest";
import assert from "node:assert/strict";
import {
  selectSigningIdentity,
  verifySigningIdentity,
} from "./mac-signing.mjs";

const a = "A".repeat(40),
  b = "B".repeat(40);
const identity = (hash, name = "Cue (TEAM123456)") =>
  `1) ${hash} "Developer ID Application: ${name}"`;
test("packaging refuses unsigned and ad-hoc releases", () => {
  assert.throws(() => selectSigningIdentity("0 valid identities found"));
  assert.throws(() => selectSigningIdentity(identity(a), "-"));
  assert.throws(() =>
    verifySigningIdentity(
      "Identifier=cue-random\nSignature=adhoc",
      "designated => cdhash H'abc'",
      "app.cue.launcher",
    ),
  );
});
test("certificate renewal keeps one developer identity, independent of keychain order", () => {
  assert.equal(selectSigningIdentity(identity(b) + "\n" + identity(a)), a);
  assert.equal(selectSigningIdentity(identity(a) + "\n" + identity(b)), a);
});
test("different developers require an explicit selection", () => {
  const output = identity(a) + "\n" + identity(b, "Other (OTHER12345)");
  assert.throws(() => selectSigningIdentity(output));
  assert.equal(selectSigningIdentity(output, b), b);
});
test("verification requires the expected bundle, Developer ID, and stable requirement", () => {
  const details =
    "Identifier=app.cue.launcher\nTeamIdentifier=TEAM123456\nAuthority=Developer ID Application: Cue (TEAM123456)\n";
  const requirement =
    'designated => identifier "app.cue.launcher" and anchor apple generic and certificate leaf[subject.OU] = TEAM123456';
  assert.doesNotThrow(() =>
    verifySigningIdentity(details, requirement, "app.cue.launcher"),
  );
  assert.throws(() => verifySigningIdentity(details, requirement, "app.other"));
});
