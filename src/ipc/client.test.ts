import { beforeAll, describe, expect, it, vi } from "vitest";
import { indexedDB, IDBKeyRange } from "fake-indexeddb";
import { readFileSync } from "node:fs";
vi.stubGlobal("window", {});
vi.stubGlobal("indexedDB", indexedDB);
vi.stubGlobal("IDBKeyRange", IDBKeyRange);
let clipboard = "";
const write = vi.fn(async (text: string) => {
  clipboard = text;
});
vi.stubGlobal("navigator", {
  platform: "MacIntel",
  clipboard: { readText: async () => clipboard, writeText: write },
});
vi.stubGlobal(
  "BroadcastChannel",
  class {
    onmessage: unknown;
    postMessage() {}
  },
);
const api = await import("./client");
import { blankAction, type Action } from "../domain/types";
let saved: Action;
beforeAll(async () => {
  saved = await api.operation<Action>("save", {
    ...blankAction(),
    name: "Unicode action",
    template: "Olá 😃\n  {{clipboard}}",
  });
});
describe("browser persistence and delivery", () => {
  it("persists and rejects a stale save", async () => {
    expect(
      (await api.getSnapshot()).actions.some((a) => a.id === saved.id),
    ).toBe(true);
    await expect(
      api.operation("save", { ...saved, revision: 0 }),
    ).rejects.toThrow("changed");
  });
  it("reads before writing, expands once, and retries without another write", async () => {
    clipboard = "{{date}}\r\n  unchanged";
    const result = await api.execute(saved, { key: "one-copy" });
    expect(result.status).toBe("copied");
    expect(clipboard).toBe("Olá 😃\n  {{date}}\r\n  unchanged");
    await api.execute(saved, { key: "one-copy" });
    expect(write).toHaveBeenCalledTimes(1);
    expect(
      (await api.getSnapshot()).actions.find((a) => a.id === saved.id)
        ?.useCount,
    ).toBe(1);
  });
  it("saves and copies the publishing prompt without altering its placeholders", async () => {
    const template = readFileSync(
      new URL("../../tests/fixtures/publishing-prompt.txt", import.meta.url),
      "utf8",
    ).replace(/\n$/, "");
    const action = await api.operation<Action>("save", {
      ...blankAction(),
      name: "Create PR or Merge Request",
      template,
    });
    expect(
      (await api.execute(action, { key: "literal-publishing-prompt" })).status,
    ).toBe("copied");
    expect(clipboard).toBe(template);
    expect(
      (await api.getSnapshot()).actions.find((a) => a.id === action.id)
        ?.template,
    ).toBe(template);
  });
  it("validates imports before mutation and rejects executable fields", async () => {
    const payload = {
      schemaVersion: 1,
      exportedAt: new Date().toISOString(),
      actions: [
        {
          id: crypto.randomUUID(),
          name: "Inert HTML",
          description: "",
          template: "<script>alert(1)</script>",
          aliases: [],
          tags: [],
          category: null,
          deliveryMode: "paste",
          favorite: false,
          enabled: true,
        },
      ],
    };
    expect(api.validateImport(JSON.stringify(payload))[0].template).toContain(
      "<script>",
    );
    expect(() =>
      api.validateImport(
        JSON.stringify({
          ...payload,
          actions: [{ ...payload.actions[0], command: "rm -rf /" }],
        }),
      ),
    ).toThrow("unsupported");
    expect(() =>
      api.validateImport(
        JSON.stringify({
          ...payload,
          actions: [payload.actions[0], payload.actions[0]],
        }),
      ),
    ).toThrow("duplicate");
  });
  it("imports with new IDs and copy-only delivery, and invalidates stale previews", async () => {
    const data = {
      schemaVersion: 1,
      exportedAt: new Date().toISOString(),
      actions: [
        {
          id: saved.id,
          name: "Imported",
          description: "",
          template: "Stored template",
          aliases: [],
          tags: [],
          category: "Writing",
          deliveryMode: "paste",
          favorite: false,
          enabled: true,
        },
      ],
    };
    const file = { text: async () => JSON.stringify(data) } as File;
    const p = await api.previewImport(file);
    await api.commitImport(p!.token, false);
    const s = await api.getSnapshot();
    const imported = s.actions.find((a) => a.name === "Imported");
    expect(imported?.id).not.toBe(saved.id);
    expect(imported?.deliveryMode).toBe("copy");
    const p2 = await api.previewImport(file);
    await api.operation("save", { ...saved, name: "Changed" });
    await expect(api.commitImport(p2!.token, true)).rejects.toThrow("changed");
    expect(
      (await api.getSnapshot()).actions.filter((a) => a.name === "Imported"),
    ).toHaveLength(1);
  });
  it("rolls back an invalid onboarding batch", async () => {
    const before = await api.getSnapshot();
    await expect(
      api.operation("onboard", {
        revision: before.revision,
        settings: { ...before.settings, onboarded: true },
        actions: [
          { ...blankAction(), name: "Valid starter", template: "valid" },
          {
            ...blankAction(),
            name: "Invalid starter",
            template: "invalid\u0000text",
          },
        ],
      }),
    ).rejects.toThrow("control character");
    const after = await api.getSnapshot();
    expect(after.actions.length).toBe(before.actions.length);
    expect(after.settings.onboarded).toBe(false);
  });
});
