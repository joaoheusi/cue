import { useState } from "react";
import {
  ArrowLeft,
  Download,
  Upload,
  RefreshCw,
  Monitor,
  ShieldCheck,
  Keyboard,
  Database,
  Sun,
  Moon,
  Check,
  ExternalLink,
} from "lucide-react";
import type {
  Snapshot,
  Settings as Preferences,
  Capabilities,
} from "./domain/types";
import * as api from "./ipc/client";
import { Keys, Toggle, ShortcutRecorder, Mark } from "./components/ui";
export default function Settings({
  snapshot,
  capabilities,
  onSave,
  onBack,
  onImport,
  onExport,
  onClear,
  onRecheck,
  onError,
}: {
  snapshot: Snapshot;
  capabilities: Capabilities | null;
  onSave: (s: Preferences) => void;
  onBack: () => void;
  onImport: () => void;
  onExport: () => void;
  onClear: () => void;
  onRecheck: () => void;
  onError: (s: string) => void;
}) {
  const [tab, setTab] = useState("General"),
    [chord, setChord] = useState(
      snapshot.shortcuts.find((s) => s.owner === "palette")?.requested ||
        snapshot.settings.paletteShortcut,
    ),
    [busy, setBusy] = useState(false);
  const s = snapshot.settings;
  const status = snapshot.shortcuts.find((s) => s.owner === "palette");
  const pasteReady =
    capabilities?.targetCapture === "available" &&
    capabilities.pasteInjection === "available";
  async function saveChord() {
    setBusy(true);
    try {
      await api.configureShortcut("palette", chord);
      onSave({ ...s, paletteShortcut: chord });
    } catch (e) {
      onError(api.message(e));
    } finally {
      setBusy(false);
    }
  }
  return (
    <section className="settings">
      <header className="settings-header">
        <button className="text-button" onClick={onBack}>
          <ArrowLeft size={15} /> Library
        </button>
        <h1>Settings</h1>
        <p>Make Cue work the way you do.</p>
      </header>
      <nav className="settings-tabs">
        {[
          ["General", Monitor],
          ["Shortcuts", Keyboard],
          ["Paste & permissions", ShieldCheck],
          ["Data", Database],
        ].map(([label, Icon]) => (
          <button
            key={String(label)}
            className={tab === label ? "chosen" : ""}
            onClick={() => setTab(String(label))}
          >
            {typeof Icon !== "string" && <Icon size={15} />} {String(label)}
          </button>
        ))}
      </nav>
      <div className="settings-body">
        {tab === "General" && (
          <>
            <h2>Appearance</h2>
            <p className="muted">Cue follows your system by default.</p>
            <div className="theme-options">
              {(["system", "light", "dark"] as const).map((theme) => (
                <button
                  className={s.theme === theme ? "chosen" : ""}
                  key={theme}
                  onClick={() => onSave({ ...s, theme })}
                >
                  <span className={`theme-mini ${theme}`}>
                    <i />
                    <i />
                    <i />
                  </span>
                  <span>
                    {theme === "system" ? (
                      <Monitor size={14} />
                    ) : theme === "light" ? (
                      <Sun size={14} />
                    ) : (
                      <Moon size={14} />
                    )}{" "}
                    {theme.charAt(0).toUpperCase() + theme.slice(1)}
                    {s.theme === theme && <Check size={13} />}
                  </span>
                </button>
              ))}
            </div>
            <h2>Behavior</h2>
            <div className="setting-row">
              <div>
                <h3>Launch at login</h3>
                <p>Ready when you need it. Starts in the background.</p>
              </div>
              <Toggle
                disabled={!api.native}
                checked={s.launchAtLogin}
                onChange={(v) => onSave({ ...s, launchAtLogin: v })}
                label="Launch at login"
              />
            </div>
            <div className="setting-row">
              <div>
                <h3>Keep running when the library closes</h3>
                <p>
                  Use the menu bar or your shortcut to open Cue. Choose Quit to
                  stop it.
                </p>
              </div>
              <Toggle
                disabled={!api.native || capabilities?.tray !== "available"}
                checked={s.keepRunning}
                onChange={(v) => onSave({ ...s, keepRunning: v })}
                label="Keep running"
              />
            </div>
            <div className="setting-row">
              <div>
                <h3>Show text preview in the palette</h3>
                <p>Only the saved template. Never your live clipboard.</p>
              </div>
              <Toggle
                checked={s.preview}
                onChange={(v) => onSave({ ...s, preview: v })}
                label="Show palette preview"
              />
            </div>
          </>
        )}
        {tab === "Shortcuts" && (
          <>
            <h2>Open the palette</h2>
            <p className="muted">
              Call up your actions from any app. A global binding may replace
              that app’s normal use of the keys.
            </p>
            <div className="shortcut-setting">
              <ShortcutRecorder value={chord} onChange={setChord} />
              <button disabled={busy} onClick={() => void saveChord()}>
                {busy ? "Registering…" : "Apply shortcut"}
              </button>
            </div>
            <div className="status-card">
              <span>Requested</span>
              <Keys value={status?.requested || chord} />
              <span>Active</span>
              {status?.active ? (
                <>
                  <span className="status-dot" />
                  <Keys value={status.active} />
                </>
              ) : (
                <span className="muted">
                  {status?.error || "Not registered"}
                </span>
              )}
            </div>
            {!api.native && (
              <p className="notice">
                This is the browser preview. Global shortcuts work in the
                desktop app. The palette shortcut works here while Cue is
                focused.
              </p>
            )}
            <h2>Direct action shortcuts</h2>
            <p className="muted">
              Set a shortcut in an action’s editor. Disabled actions never
              execute.
            </p>
            {snapshot.shortcuts
              .filter((s) => s.owner !== "palette")
              .map((s) => (
                <div className="setting-row" key={s.owner}>
                  <span>
                    {snapshot.actions.find((a) => `action:${a.id}` === s.owner)
                      ?.name || "Deleted action"}
                  </span>
                  <Keys value={s.requested} />
                  <span>{s.active ? "Active" : s.error || "Inactive"}</span>
                </div>
              ))}
            {api.native && (
              <button
                className="secondary"
                onClick={() =>
                  void api
                    .toggleShortcuts()
                    .catch((e) => onError(api.message(e)))
                }
              >
                Pause / resume shortcuts
              </button>
            )}
          </>
        )}
        {tab === "Paste & permissions" && (
          <>
            <h2>Paste into the app you’re using.</h2>
            <p className="muted">
              Focus a text field, open Cue with your shortcut, and press Enter
              to paste. Shift+Enter copies instead. Cue never presses Enter in
              the other app.
            </p>
            <div className="permission-notice">
              <ShieldCheck size={24} />
              <div>
                <h3>
                  {pasteReady
                    ? "Ready to paste"
                    : capabilities?.session === "macOS"
                      ? "Allow Cue to paste"
                      : "Automatic paste requires the macOS app"}
                </h3>
                <p>
                  {pasteReady
                    ? "Cue returns to the window and text field you opened it from."
                    : capabilities?.session === "macOS"
                      ? "In System Settings → Privacy & Security → Accessibility, enable Cue. If it is already enabled, turn it off and on, then quit and reopen Cue."
                      : "Use Cue on macOS for automatic paste. Copy remains available here."}
                </p>
              </div>
            </div>
            {capabilities?.session === "macOS" && !pasteReady && (
              <button
                className="primary"
                onClick={() =>
                  void api
                    .requestPastePermission()
                    .catch((e) => onError(api.message(e)))
                }
              >
                Open Accessibility settings <ExternalLink size={14} />
              </button>
            )}
            <div className="setting-row">
              <div>
                <h3>Default delivery</h3>
                <p>Actions can override this preference.</p>
              </div>
              <select
                aria-label="Default delivery"
                value={s.defaultDelivery}
                onChange={(e) =>
                  onSave({
                    ...s,
                    defaultDelivery: e.target.value as "paste" | "copy",
                  })
                }
                style={{ width: "auto" }}
              >
                <option value="paste">Paste</option>
                <option value="copy">Copy</option>
              </select>
            </div>
            <h2>
              Platform status{" "}
              <button className="text-button" onClick={onRecheck}>
                <RefreshCw size={13} /> Recheck
              </button>
            </h2>
            <div className="capability-list">
              {[
                ["Session", capabilities?.session],
                ["Clipboard", capabilities?.clipboard],
                ["Global shortcuts", capabilities?.globalShortcut],
                ["Target capture", capabilities?.targetCapture],
                ["Focus restoration", capabilities?.focusRestoration],
                ["Paste injection", capabilities?.pasteInjection],
                ["Menu bar / tray", capabilities?.tray],
              ].map(([label, value]) => (
                <div key={label}>
                  <span>{label}</span>
                  <span>{value || "Checking…"}</span>
                </div>
              ))}
            </div>
            <p className="notice-small">
              Text stays on your clipboard after delivery. Terminal apps use
              Copy.
            </p>
          </>
        )}
        {tab === "Data" && (
          <>
            <h2>Your actions. On your device.</h2>
            <p className="muted">
              No account, sync, or telemetry. Templates are stored locally as
              readable text.
            </p>
            <div className="data-card">
              <Upload size={20} />
              <div>
                <h3>Import actions</h3>
                <p>
                  Preview a Cue JSON file before adding anything. Imports use
                  Copy and have no shortcuts.
                </p>
              </div>
              <button onClick={onImport}>Choose file</button>
            </div>
            <div className="data-card">
              <Download size={20} />
              <div>
                <h3>Export actions</h3>
                <p>
                  Save {snapshot.actions.length} actions. Permissions,
                  shortcuts, and usage stay on this device.
                </p>
              </div>
              <button onClick={onExport}>Export JSON</button>
            </div>
            <div className="data-card">
              <RefreshCw size={20} />
              <div>
                <h3>Clear usage history</h3>
                <p>Reset recent actions and use counts. Keep every action.</p>
              </div>
              <button onClick={onClear}>Clear usage</button>
            </div>
            {api.native && (
              <p className="notice-small">
                Cue makes a SQLite backup before imports and migrations. It
                keeps the latest five. Deleting a record is not a secure erase.
              </p>
            )}
          </>
        )}
        <div className="about">
          <Mark size={26} />
          <div>
            <strong>
              cue <span>0.1.0</span>
            </strong>
            <p>Your prompts, on cue.</p>
          </div>
          <span>
            {api.native ? "Desktop" : "Browser preview"}
            <ExternalLink size={12} />
          </span>
        </div>
      </div>
    </section>
  );
}
