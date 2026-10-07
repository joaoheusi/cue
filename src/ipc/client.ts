import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import {
  blankAction,
  defaults,
  type Action,
  type Capabilities,
  type ExportAction,
  type ImportPreview,
  type Settings,
  type Snapshot,
} from "../domain/types";
import {
  bytes,
  needsClipboard,
  renderTemplate,
  validateText,
} from "../domain/templates";
import { nameKey } from "../domain/search";
export const native = "__TAURI_INTERNALS__" in window;
const changes = new EventTarget();
const channel = new BroadcastChannel("cue-web-preview");
channel.onmessage = () => changes.dispatchEvent(new Event("change"));
let dbPromise: Promise<IDBDatabase> | undefined;
function database() {
  return (dbPromise ||= new Promise<IDBDatabase>((resolve, reject) => {
    const r = indexedDB.open("cue-web-preview", 1);
    r.onupgradeneeded = () => r.result.createObjectStore("state");
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(Error("Could not open local browser storage."));
  }));
}
async function transact<T>(fn: (s: Snapshot) => T, write = false): Promise<T> {
  const db = await database();
  return new Promise((resolve, reject) => {
    const tx = db.transaction("state", write ? "readwrite" : "readonly");
    const store = tx.objectStore("state");
    const r = store.get("library");
    let value: T;
    r.onsuccess = () => {
      try {
        const s: Snapshot = r.result || {
          actions: [],
          categories: [],
          settings: defaults,
          revision: 1,
          shortcuts: [],
        };
        value = fn(s);
        if (write) {
          s.revision++;
          store.put(s, "library");
        }
      } catch (e) {
        tx.abort();
        reject(e);
      }
    };
    tx.oncomplete = () => {
      resolve(value);
      if (write) {
        changes.dispatchEvent(new Event("change"));
        channel.postMessage("change");
      }
    };
    tx.onerror = () => reject(Error("Could not save local data."));
  });
}
function validate(a: Action) {
  if (!a.name.trim() || [...a.name.trim()].length > 100)
    throw Error("Name must contain 1–100 characters.");
  if ([...a.description].length > 300)
    throw Error("Description is limited to 300 characters.");
  validateText(a.template);
  renderTemplate(a.template, "sample clipboard");
  for (const [items, max] of [
    [a.aliases, 50],
    [a.tags, 30],
  ] as const) {
    if (
      items.length > 10 ||
      items.some((s) => !s.trim() || [...s].length > max)
    )
      throw Error(`Use at most 10 entries, each up to ${max} characters.`);
  }
  if (
    a.category !== null &&
    (!a.category.trim() || [...a.category.trim()].length > 50)
  )
    throw Error("Category names must contain 1–50 characters.");
}
function save(s: Snapshot, a: Action): Action {
  validate(a);
  const old = s.actions.find((x) => x.id === a.id);
  if ((old?.revision || 0) !== a.revision)
    throw Error("Action changed. Reload before saving.");
  if (!old && s.actions.length >= 5000)
    throw Error("The library is limited to 5,000 actions.");
  const saved = {
    ...a,
    name: a.name.trim(),
    template: a.template.replace(/\r\n?/g, "\n"),
    revision: a.revision + 1,
    updatedAt: new Date().toISOString(),
    useCount: old?.useCount || 0,
    lastUsedAt: old?.lastUsedAt || null,
  };
  const dedup = (items: string[]) => {
    const names = new Map<string, string>();
    for (const item of items) {
      const value = item.trim();
      if (!names.has(nameKey(value))) names.set(nameKey(value), value);
    }
    return [...names.values()];
  };
  saved.tags = dedup(saved.tags);
  saved.aliases = dedup(saved.aliases);
  if (saved.category) {
    const c = s.categories.find((c) => nameKey(c) === nameKey(saved.category!));
    saved.category = c || saved.category.trim();
    if (!c) s.categories.push(saved.category);
  }
  s.actions = old
    ? s.actions.map((x) => (x.id === a.id ? saved : x))
    : [...s.actions, saved];
  return saved;
}
export async function getSnapshot(): Promise<Snapshot> {
  return native ? invoke("get_snapshot") : transact((s) => s);
}
export async function getCapabilities(): Promise<Capabilities> {
  return native
    ? invoke("get_capabilities")
    : {
        session: "Browser preview",
        clipboard: "available with browser permission",
        globalShortcut: "unavailable",
        targetCapture: "unavailable",
        focusRestoration: "unavailable",
        pasteInjection: "unsupported",
        tray: "unavailable",
        native: false,
      };
}
export async function operation<T = void>(
  op: string,
  args: unknown,
): Promise<T> {
  if (native) return invoke("library_operation", { op, args });
  return transact((s) => {
    const a = args as Action & {
      id: string;
      revision: number;
      name: string;
      old?: string;
      settings: Settings;
    };
    switch (op) {
      case "onboard": {
        if (s.settings.onboarded) break;
        const setup = args as {
          actions: Action[];
          settings: Settings;
          revision: number;
        };
        if (setup.revision !== s.revision)
          throw Error("Library changed. Try setup again.");
        for (const action of setup.actions) save(s, action);
        s.settings = {
          ...setup.settings,
          onboarded: true,
          defaultDelivery: "paste",
        };
        break;
      }
      case "save":
        return save(s, a);
      case "duplicate": {
        const old = s.actions.find((x) => x.id === a.id);
        if (!old || old.revision !== a.revision)
          throw Error("Action changed. Reload before duplicating.");
        return save(s, {
          ...old,
          ...blankAction(old.category),
          name: `${old.name.slice(0, 95)} copy`,
          description: old.description,
          template: old.template,
          aliases: old.aliases,
          tags: old.tags,
          deliveryMode: old.deliveryMode,
          favorite: old.favorite,
          enabled: old.enabled,
        });
      }
      case "delete": {
        const old = s.actions.find((x) => x.id === a.id);
        if (!old || old.revision !== a.revision)
          throw Error("Action changed. Reload before deleting.");
        s.actions = s.actions.filter((x) => x.id !== a.id);
        s.shortcuts = s.shortcuts.filter((x) => x.owner !== `action:${a.id}`);
        break;
      }
      case "settings":
        if (s.revision !== a.revision)
          throw Error("Settings changed. Reload and try again.");
        s.settings = a.settings;
        break;
      case "category":
        if (s.revision !== a.revision)
          throw Error("Library changed. Try again.");
        if (a.name && s.categories.some((c) => nameKey(c) === nameKey(a.name)))
          throw Error("A category with this name already exists.");
        if (a.old) {
          s.categories = s.categories.filter((c) => c !== a.old);
          s.actions = s.actions.map((x) =>
            x.category === a.old
              ? { ...x, category: a.name || null, revision: x.revision + 1 }
              : x,
          );
        }
        if (a.name) s.categories.push(a.name.trim());
        break;
      case "clear_usage":
        s.actions = s.actions.map((x) => ({
          ...x,
          useCount: 0,
          lastUsedAt: null,
        }));
        break;
      default:
        throw Error("Unknown operation.");
    }
    return undefined;
  }, true) as Promise<T>;
}
export async function onChange(fn: () => void) {
  if (native) return listen("actions_changed", fn);
  changes.addEventListener("change", fn);
  return () => changes.removeEventListener("change", fn);
}
export async function onEvent<T>(name: string, fn: (payload: T) => void) {
  if (native) return listen<T>(name, (e) => fn(e.payload));
  return () => {};
}
export const configureShortcut = (owner: string, chord: string) =>
  native
    ? invoke("configure_shortcut", { owner, chord })
    : Promise.reject(
        Error(
          "Global shortcuts require the desktop app. In this preview, use ⌘⇧Space while Cue is focused.",
        ),
      );
export const toggleShortcuts = () => invoke("toggle_shortcuts");
export const openPalette = () => invoke<string>("open_palette");
export const closePalette = () => invoke("close_palette");
export const paletteContext = () => invoke<string>("palette_context");
export const showLibrary = (page: string, actionId?: string) =>
  invoke("show_library", { page, actionId: actionId || null });
export const quit = () => invoke("quit_app");
export const closeLibrary = () => invoke("close_library");
export const requestPastePermission = () => invoke("request_paste_permission");
export interface ExecutionResult {
  status:
    | "copied"
    | "pasted"
    | "copied_not_pasted"
    | "blocked"
    | "failed_before_copy"
    | "cancelled";
  message: string;
  usageSaved?: boolean;
}
let busy = false;
const results = new Map<
  string,
  { identity: string; result: ExecutionResult; time: number }
>();
export async function execute(
  a: Action,
  options: { invocation?: string; copy?: boolean; key?: string } = {},
): Promise<ExecutionResult> {
  const key = options.key || crypto.randomUUID();
  if (native)
    return invoke(options.invocation ? "execute_action" : "copy_action", {
      id: a.id,
      revision: a.revision,
      key,
      invocation: options.invocation,
      overrideCopy: !!options.copy,
    });
  for (const [key, entry] of results)
    if (Date.now() - entry.time > 300000) results.delete(key);
  const identity = `${a.id}:${a.revision}`;
  const prior = results.get(key);
  if (prior) {
    if (prior.identity !== identity)
      throw Error("An execution key cannot be reused for a different action.");
    return prior.result;
  }
  if (results.size >= 1024)
    throw Error("Too many recent deliveries. Wait before copying again.");
  if (busy) throw Error("An action is already being prepared.");
  busy = true;
  try {
    const current = await transact((s) => s.actions.find((x) => x.id === a.id));
    if (!current || current.revision !== a.revision)
      throw Error("Action changed. Reload before copying.");
    if (!current.enabled) throw Error("Enable this action before using it.");
    const settings = await transact((s) => s.settings);
    if (
      options.invocation &&
      !options.copy &&
      (a.deliveryMode === "paste" ||
        (a.deliveryMode === "inherit" && settings.defaultDelivery === "paste"))
    )
      return {
        status: "blocked",
        message:
          "Use the macOS app to paste into another app. Copy is available in this browser preview.",
      };
    const clipboard = needsClipboard(current.template)
      ? await navigator.clipboard.readText()
      : "";
    if (needsClipboard(current.template) && !clipboard)
      throw Error("Copy source text before using this action.");
    if (bytes(clipboard) > 1048576)
      throw Error("Clipboard text exceeds 1 MiB.");
    const text = renderTemplate(current.template, clipboard);
    await navigator.clipboard.writeText(text);
    let usageSaved = true;
    try {
      await transact((s) => {
        const x = s.actions.find((x) => x.id === a.id);
        if (x) {
          x.useCount++;
          x.lastUsedAt = new Date().toISOString();
        }
      }, true);
    } catch {
      usageSaved = false;
    }
    const result: ExecutionResult = {
      status: "copied",
      message: "Copied.",
      usageSaved,
    };
    results.set(key, { identity, result, time: Date.now() });

    return result;
  } finally {
    busy = false;
  }
}
let pending: { preview: ImportPreview; expires: number } | null = null;
const exportFields = [
  "id",
  "name",
  "description",
  "template",
  "aliases",
  "tags",
  "category",
  "deliveryMode",
  "favorite",
  "enabled",
];
export function validateImport(text: string): ExportAction[] {
  if (bytes(text) > 10 * 1024 * 1024)
    throw Error("Import file exceeds 10 MiB.");
  const data = JSON.parse(text);
  if (
    !data ||
    Object.keys(data).sort().join(",") !== "actions,exportedAt,schemaVersion" ||
    data.schemaVersion !== 1 ||
    typeof data.exportedAt !== "string" ||
    !/^\d{4}-\d\d-\d\dT/.test(data.exportedAt) ||
    Number.isNaN(Date.parse(data.exportedAt)) ||
    !Array.isArray(data.actions)
  )
    throw Error("Expected Cue JSON schema version 1.");
  const ids = new Set();
  for (const entry of data.actions) {
    if (
      !entry ||
      typeof entry !== "object" ||
      Object.keys(entry).sort().join(",") !== [...exportFields].sort().join(",")
    )
      throw Error("Import contains unsupported or missing fields.");
    if (
      typeof entry.id !== "string" ||
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
        entry.id,
      ) ||
      ids.has(entry.id)
    )
      throw Error("Invalid or duplicate action ID.");
    ids.add(entry.id);
    if (
      !["name", "description", "template"].every(
        (k) => typeof entry[k] === "string",
      ) ||
      !["aliases", "tags"].every(
        (k) =>
          Array.isArray(entry[k]) &&
          entry[k].every((x: unknown) => typeof x === "string"),
      ) ||
      (entry.category !== null && typeof entry.category !== "string") ||
      !["inherit", "copy", "paste"].includes(entry.deliveryMode) ||
      typeof entry.favorite !== "boolean" ||
      typeof entry.enabled !== "boolean"
    )
      throw Error("Import has invalid field types.");
    validate({ ...blankAction(), ...entry });
  }
  return data.actions;
}
export async function previewImport(
  file?: File,
): Promise<ImportPreview | null> {
  if (native) return invoke("preview_import");
  if (!file) return null;
  const actions = validateImport(await file.text());
  const s = await getSnapshot();
  if (s.actions.length + actions.length > 5000)
    throw Error("Import would exceed 5,000 actions.");
  const preview = {
    token: crypto.randomUUID(),
    actions,
    revision: s.revision,
    duplicateIds: actions.filter((a) => s.actions.some((b) => b.id === a.id))
      .length,
    duplicateNames: actions.filter((a) =>
      s.actions.some((b) => nameKey(a.name) === nameKey(b.name)),
    ).length,
    newCategories: [
      ...new Set(
        actions.flatMap((a) =>
          a.category &&
          !s.categories.some((c) => nameKey(c) === nameKey(a.category!))
            ? [a.category]
            : [],
        ),
      ),
    ],
  };
  pending = { preview, expires: Date.now() + 300000 };
  return preview;
}
export async function commitImport(token: string, update: boolean) {
  if (native) return invoke("commit_import", { token, update });
  const p = pending;
  pending = null;
  if (!p || p.preview.token !== token || p.expires < Date.now())
    throw Error("Import preview expired. Select the file again.");
  return transact((s) => {
    if (s.revision !== p.preview.revision)
      throw Error("Library changed. Select the file again.");
    for (const entry of p.preview.actions) {
      const old = update ? s.actions.find((a) => a.id === entry.id) : undefined;
      save(s, {
        ...blankAction(),
        ...entry,
        id: old?.id || crypto.randomUUID(),
        revision: old?.revision || 0,
        deliveryMode: "copy",
      });
    }
  }, true);
}
export async function exportActions() {
  if (native) return invoke<boolean>("export_actions");
  const s = await getSnapshot();
  const data = {
    schemaVersion: 1,
    exportedAt: new Date().toISOString(),
    actions: s.actions.map((a) =>
      Object.fromEntries(exportFields.map((k) => [k, a[k as keyof Action]])),
    ),
  };
  const url = URL.createObjectURL(
    new Blob([JSON.stringify(data, null, 2)], { type: "application/json" }),
  );
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = "cue-actions.json";
  anchor.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
  return true;
}
export const message = (e: unknown) =>
  e instanceof Error
    ? e.message
    : (e as { message?: string })?.message ||
      "This operation could not complete. Try again.";
