import { describe, it, expect } from "vitest";
import { renderTemplate, needsClipboard, validateText } from "./templates";
import { searchActions } from "./search";
import { blankAction } from "./types";
import { readFileSync } from "node:fs";
describe("templates", () => {
  it("uses one pass and one clock instant", () =>
    expect(
      renderTemplate(
        "{{clipboard}} {{date}} {{date}} {{time}}",
        "{{date}}",
        new Date(2026, 9, 6, 13, 5),
      ),
    ).toBe("{{date}} 2026-10-06 2026-10-06 13:05"));
  it("handles paired and unpaired escapes", () =>
    expect(
      renderTemplate(
        String.raw`\{{date}} \\{{date}} \\\{{date}}`,
        "sample",
        new Date(2026, 9, 6),
      ),
    ).toBe(String.raw`{{date}} \2026-10-06 \{{date}}`));
  it("leaves ordinary braces and unicode unchanged", () =>
    expect(renderTemplate('{"ok":true} Olá 😃\n  text', "")).toBe(
      '{"ok":true} Olá 😃\n  text',
    ));
  it("preserves other template languages and ordinary double braces", () => {
    const cases: string[] = JSON.parse(
      readFileSync(
        new URL(
          "../../tests/fixtures/literal-placeholders.json",
          import.meta.url,
        ),
        "utf8",
      ),
    );
    for (const template of cases) {
      expect(renderTemplate(template, "clipboard text")).toBe(template);
      expect(needsClipboard(template)).toBe(false);
    }
    expect(
      renderTemplate(
        "@{{upstream}} {{clipboard}} {{date}} {{time}}",
        "text",
        new Date(2026, 9, 6, 13, 5),
      ),
    ).toBe("@{{upstream}} text 2026-10-06 13:05");
  });
  it("reads clipboard only for an unescaped token", () => {
    expect(needsClipboard("Hi {{clipboard}}")).toBe(true);
    expect(needsClipboard(String.raw`Hi \{{clipboard}}`)).toBe(false);
    expect(needsClipboard("literal \uE000")).toBe(false);
    expect(renderTemplate("{{clipboard}}", " \r\n ")).toBe(" \r\n ");
  });
  it("rejects controls and large output instead of truncating", () => {
    expect(() => validateText("Hi\x1b")).toThrow();
    expect(() =>
      renderTemplate("{{clipboard}}{{clipboard}}", "x".repeat(600000)),
    ).toThrow();
  });
});
describe("search", () => {
  const a = (name: string, fields = {}) => ({
    ...blankAction(),
    name,
    template: "Text",
    ...fields,
  });
  it("ranks exact above a favorite fuzzy match", () => {
    const exact = a("Resolve CI");
    expect(
      searchActions(
        [a("Resolve complicated issue", { favorite: true }), exact],
        "resolve ci",
      )[0].id,
    ).toBe(exact.id);
  });
  it("supports accents, aliases, multi-field tokens, and typos", () => {
    const action = a("Revisão", {
      aliases: ["resolve CI"],
      tags: ["git"],
      category: "Coding",
    });
    expect(searchActions([action], "revisao")).toEqual([action]);
    expect(searchActions([action], "res ci git")).toEqual([action]);
    expect(searchActions([action], "rslv")).toEqual([action]);
    const emoji = a("🚀 Resolve CI");
    expect(searchActions([emoji], "🚀ci")).toEqual([emoji]);
    expect(searchActions([action], "rslv missing")).toEqual([]);
  });
  it("excludes disabled actions and does not search bodies", () => {
    expect(
      searchActions(
        [a("disabled", { enabled: false }), a("other", { template: "secret" })],
        "disabled",
      ),
    ).toEqual([]);
    expect(
      searchActions([a("other", { template: "secret" })], "secret"),
    ).toEqual([]);
  });
  it("orders favorites, then recents, then names without duplicates", () => {
    const favorite = a("Z", { favorite: true }),
      recent = a("B", { lastUsedAt: "2026-10-06T12:00:00Z" }),
      alpha = a("A");
    expect(searchActions([alpha, recent, favorite], "")).toEqual([
      favorite,
      recent,
      alpha,
    ]);
  });
});
