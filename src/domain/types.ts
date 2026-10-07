export type Delivery = "inherit" | "copy" | "paste";
export interface Action {
  id: string;
  name: string;
  description: string;
  template: string;
  aliases: string[];
  tags: string[];
  category: string | null;
  deliveryMode: Delivery;
  favorite: boolean;
  enabled: boolean;
  revision: number;
  useCount: number;
  lastUsedAt: string | null;
  createdAt: string;
  updatedAt: string;
}
export interface Settings {
  theme: "system" | "dark" | "light";
  defaultDelivery: "copy" | "paste";
  onboarded: boolean;
  paletteShortcut: string;
  launchAtLogin: boolean;
  keepRunning: boolean;
  preview: boolean;
}
export interface ShortcutStatus {
  owner: string;
  requested: string;
  active: string | null;
  error: string | null;
}
export interface Snapshot {
  actions: Action[];
  categories: string[];
  settings: Settings;
  revision: number;
  shortcuts: ShortcutStatus[];
}
export interface Capabilities {
  session: string;
  clipboard: string;
  globalShortcut: string;
  targetCapture: string;
  focusRestoration: string;
  pasteInjection: string;
  tray: string;
  native: boolean;
}
export interface ExportAction {
  id: string;
  name: string;
  description: string;
  template: string;
  aliases: string[];
  tags: string[];
  category: string | null;
  deliveryMode: Delivery;
  favorite: boolean;
  enabled: boolean;
}
export interface ImportPreview {
  token: string;
  actions: ExportAction[];
  duplicateIds: number;
  duplicateNames: number;
  newCategories: string[];
  revision: number;
}
export const defaults: Settings = {
  theme: "system",
  defaultDelivery: "paste",
  onboarded: false,
  paletteShortcut: navigator.platform.includes("Mac")
    ? "Super+Shift+Space"
    : "Control+Shift+Space",
  launchAtLogin: false,
  keepRunning: true,
  preview: false,
};
export const blankAction = (category: string | null = null): Action => ({
  id: crypto.randomUUID(),
  name: "",
  description: "",
  template: "",
  aliases: [],
  tags: [],
  category,
  deliveryMode: "inherit",
  favorite: false,
  enabled: true,
  revision: 0,
  useCount: 0,
  lastUsedAt: null,
  createdAt: new Date().toISOString(),
  updatedAt: new Date().toISOString(),
});
