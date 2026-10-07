import { expect, it } from "vitest";
import { shortcutKey, matchesShortcut } from "./shortcuts";
it("records physical keys across shifted layouts", () => {
  expect(
    shortcutKey({
      code: "Equal",
      key: "+",
      metaKey: true,
      ctrlKey: false,
      altKey: false,
      shiftKey: true,
    }),
  ).toBe("Equal");
  expect(
    shortcutKey({
      code: "KeyC",
      key: "ç",
      metaKey: false,
      ctrlKey: true,
      altKey: false,
      shiftKey: false,
    }),
  ).toBe("C");
});
it("matches the complete requested chord", () => {
  const event = {
    code: "Space",
    key: " ",
    metaKey: true,
    ctrlKey: false,
    altKey: false,
    shiftKey: true,
  };
  expect(matchesShortcut(event, "Super+Shift+Space")).toBe(true);
  expect(matchesShortcut(event, "Super+Space")).toBe(false);
  expect(matchesShortcut(event, "Control+Shift+Space")).toBe(false);
  expect(matchesShortcut(event, "")).toBe(false);
});
