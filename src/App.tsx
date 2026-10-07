import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  Grid2X2,
  Star,
  Clock3,
  Folder,
  Plus,
  Ban,
  Settings as SettingsIcon,
  Search,
  Command,
  ArrowRight,
  Check,
  Copy,
  Keyboard,
  ChevronLeft,
  AlertCircle,
  X,
  MoreHorizontal,
} from "lucide-react";
import {
  blankAction,
  type Action,
  type Snapshot,
  type Capabilities,
  type ImportPreview,
  type Settings as Preferences,
} from "./domain/types";
import { matchesShortcut } from "./domain/shortcuts";
import { searchActions } from "./domain/search";
import { starterActions } from "./domain/starters";
import * as api from "./ipc/client";
import {
  Keys,
  Mark,
  Modal,
  IconButton,
  ShortcutRecorder,
  Toggle,
  mac,
} from "./components/ui";
import Editor from "./Editor";
import Palette from "./Palette";
import Settings from "./Settings";
type Confirm = {
  title: string;
  body: string;
  label: string;
  danger?: boolean;
  run: () => void;
};
export default function App() {
  const paletteWindow =
    new URLSearchParams(location.search).get("surface") === "palette";
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null),
    [capabilities, setCapabilities] = useState<Capabilities | null>(null),
    [loadError, setLoadError] = useState(""),
    [filter, setFilter] = useState("all"),
    [query, setQuery] = useState(""),
    [draft, setDraft] = useState<Action | null>(null),
    [baseline, setBaseline] = useState(""),
    [shortcut, setShortcut] = useState(""),
    [shortcutBaseline, setShortcutBaseline] = useState(""),
    [page, setPage] = useState("library"),
    [palette, setPalette] = useState(false),
    [saving, setSaving] = useState(false),
    [error, setError] = useState(""),
    [toast, setToast] = useState(""),
    [confirm, setConfirm] = useState<Confirm | null>(null),
    [categoryDialog, setCategoryDialog] = useState<{
      old?: string;
      name: string;
    } | null>(null),
    [importPreview, setImportPreview] = useState<ImportPreview | null>(null),
    [importUpdate, setImportUpdate] = useState(false),
    [onboardingStep, setOnboardingStep] = useState(0),
    [addStarters, setAddStarters] = useState(true),
    [onboardChord, setOnboardChord] = useState(
      mac ? "Super+Shift+Space" : "Control+Shift+Space",
    ),
    [categoryMenu, setCategoryMenu] = useState<string | null>(null);
  const fileInput = useRef<HTMLInputElement>(null);
  const stateRef = useRef({
    dirty: false,
    close: (_quit?: boolean) => {},
    navigate: (_page: string, _actionId?: string) => {},
  });
  const dirty =
    !!draft &&
    (JSON.stringify(draft) !== baseline || shortcut !== shortcutBaseline);
  const refresh = useCallback(async () => {
    try {
      const s = await api.getSnapshot();
      setSnapshot(s);
      setLoadError("");
      return s;
    } catch (e) {
      setLoadError(api.message(e));
      return null;
    }
  }, []);
  const notify = (text: string) => {
    setToast(text);
  };
  const refreshCapabilities = useCallback(() => {
    void api
      .getCapabilities()
      .then(setCapabilities)
      .catch((e) => setError(api.message(e)));
  }, []);
  useEffect(() => {
    window.addEventListener("focus", refreshCapabilities);
    return () => window.removeEventListener("focus", refreshCapabilities);
  }, [refreshCapabilities]);
  useEffect(() => {
    void refresh();
    refreshCapabilities();
    let disposed = false;
    let unsub = () => {},
      nav = () => {},
      close = () => {},
      execution = () => {},
      quit = () => {};
    void api
      .onChange(() => void refresh())
      .then((fn) => {
        if (disposed) fn();
        else unsub = fn;
      });
    void api
      .onEvent<string | { page: string; actionId?: string }>(
        "navigate",
        (p) => {
          if (typeof p === "string") stateRef.current.navigate(p);
          else stateRef.current.navigate(p.page, p.actionId);
        },
      )
      .then((fn) => {
        if (disposed) fn();
        else nav = fn;
      });
    void api
      .onEvent("close_requested", () => stateRef.current.close())
      .then((fn) => {
        if (disposed) fn();
        else close = fn;
      });
    void api
      .onEvent("quit_requested", () => stateRef.current.close(true))
      .then((fn) => {
        if (disposed) fn();
        else quit = fn;
      });
    void api
      .onEvent<api.ExecutionResult>("execution_result", (r) => {
        if (r.status === "copied" || r.status === "pasted") notify(r.message);
        else {
          setError(r.message);
          setPage("settings");
        }
      })
      .then((fn) => {
        if (disposed) fn();
        else execution = fn;
      });
    return () => {
      disposed = true;
      unsub();
      nav();
      close();
      execution();
      quit();
    };
  }, [refresh, refreshCapabilities]);
  useEffect(() => {
    if (!toast) return;
    const t = setTimeout(() => setToast(""), 3500);
    return () => clearTimeout(t);
  }, [toast]);
  useEffect(() => {
    if (!snapshot) return;
    document.documentElement.dataset.theme = snapshot.settings.theme;
  }, [snapshot?.settings.theme]);
  function select(a: Action | null, s = snapshot) {
    setDraft(a ? structuredClone(a) : null);
    setBaseline(JSON.stringify(a));
    const c =
      s?.shortcuts.find((c) => c.owner === `action:${a?.id}`)?.requested || "";
    setShortcut(c);
    setShortcutBaseline(c);
    setError("");
  }
  useEffect(() => {
    if (snapshot?.settings.onboarded && !draft && snapshot.actions.length)
      select(
        snapshot.actions.find((a) => a.name === "Resolve CI") ||
          searchActions(snapshot.actions, "", false)[0],
        snapshot,
      );
  }, [snapshot?.settings.onboarded]);
  useEffect(() => {
    if (snapshot && draft?.revision && !dirty) {
      const latest = snapshot.actions.find((a) => a.id === draft.id);
      if (latest && JSON.stringify(latest) !== baseline)
        select(latest, snapshot);
    }
  }, [snapshot?.revision]);
  function guarded(fn: () => void) {
    if (dirty)
      setConfirm({
        title: "Discard unsaved changes?",
        body: "Your saved action stays as it is. Changes in this editor will be lost.",
        label: "Discard changes",
        danger: true,
        run: fn,
      });
    else fn();
  }
  function navigate(p: string, id?: string) {
    guarded(() => {
      setPage(p === "settings" ? "settings" : "library");
      setPalette(false);
      if (api.native && paletteWindow) {
        void api.showLibrary(p, id).catch((e) => setError(api.message(e)));
        return;
      }
      if (["favorite", "disable", "duplicate"].includes(p) && id) {
        const action = snapshot?.actions.find((a) => a.id === id);
        if (action) {
          const operation =
            p === "duplicate"
              ? api.operation<Action>("duplicate", {
                  id: action.id,
                  revision: action.revision,
                })
              : api.operation<Action>("save", {
                  ...action,
                  ...(p === "favorite"
                    ? { favorite: !action.favorite }
                    : { enabled: false }),
                });
          void operation
            .then(async (action) => {
              const s = await refresh();
              select(action, s);
            })
            .catch((e) => setError(api.message(e)));
        }
        return;
      }
      if (p === "new")
        select(
          blankAction(
            !["all", "favorites", "recent", "disabled"].includes(filter)
              ? filter
              : null,
          ),
        );
      else if (id) select(snapshot?.actions.find((a) => a.id === id) || null);
    });
  }
  function close(forceQuit = false) {
    if (
      !forceQuit &&
      snapshot?.settings.keepRunning &&
      capabilities?.tray === "available"
    ) {
      void api.closeLibrary().catch((e) => setError(api.message(e)));
      return;
    }
    guarded(() => {
      if (forceQuit) {
        void api.quit();
        return;
      }
      if (!snapshot && api.native) {
        void api.quit();
        return;
      }
      if (snapshot)
        void api.closeLibrary().catch((e) => setError(api.message(e)));
    });
  }
  stateRef.current = { dirty, close, navigate };
  const actions = useMemo(
    () =>
      snapshot
        ? searchActions(snapshot.actions, query, false).filter(
            (a) =>
              filter === "all" ||
              (filter === "favorites" && a.favorite) ||
              (filter === "recent" && a.lastUsedAt) ||
              (filter === "disabled" && !a.enabled) ||
              a.category === filter,
          )
        : [],
    [snapshot, query, filter],
  );
  async function save() {
    if (!draft || saving) return;
    setSaving(true);
    setError("");
    try {
      let a = await api.operation<Action>("save", draft);
      setDraft(a);
      setBaseline(JSON.stringify(a));
      if (shortcut !== shortcutBaseline) {
        try {
          await api.configureShortcut(`action:${a.id}`, shortcut);
          setShortcutBaseline(shortcut);
        } catch (e) {
          setError(`Action saved. ${api.message(e)}`);
        }
      }
      const s = await refresh();
      if (s) {
        a = s.actions.find((b) => b.id === a.id) || a;
        setDraft(a);
        setBaseline(JSON.stringify(a));
      }
      notify("Saved.");
    } catch (e) {
      setError(api.message(e));
    } finally {
      setSaving(false);
    }
  }
  async function copy() {
    if (!draft) return;
    try {
      const r = await api.execute(draft, { copy: true });
      if (r.status === "copied") {
        notify(
          r.usageSaved === false
            ? "Copied. Usage could not be saved."
            : r.message,
        );
        void refresh();
      } else setError(r.message);
    } catch (e) {
      setError(api.message(e));
    }
  }
  async function duplicate() {
    if (!draft) return;
    try {
      const a = await api.operation<Action>("duplicate", {
        id: draft.id,
        revision: draft.revision,
      });
      const s = await refresh();
      select(a, s);
      notify("Duplicated.");
    } catch (e) {
      setError(api.message(e));
    }
  }
  function deleteAction() {
    if (!draft) return;
    const a = draft;
    setConfirm({
      title: `Delete “${a.name}”?`,
      body: "This removes the action and its direct shortcut. Export it first if you want to keep a copy.",
      label: "Delete action",
      danger: true,
      run: () => {
        void api
          .operation("delete", { id: a.id, revision: a.revision })
          .then(async () => {
            const s = await refresh();
            select(s?.actions[0] || null, s);
            notify("Deleted.");
          })
          .catch((e) => setError(api.message(e)));
      },
    });
  }
  async function saveSettings(s: Preferences) {
    if (!snapshot) return;
    try {
      await api.operation("settings", {
        settings: s,
        revision: snapshot.revision,
      });
      await refresh();
    } catch (e) {
      setError(api.message(e));
      void refresh();
    }
  }
  async function finishOnboarding() {
    if (!snapshot || saving) return;
    setSaving(true);
    setError("");
    try {
      await api.operation("onboard", {
        actions: addStarters ? starterActions() : [],
        settings: {
          ...snapshot.settings,
          onboarded: true,
          paletteShortcut: onboardChord,
        },
        revision: snapshot.revision,
      });
      let s = await refresh();
      if (!s) return;
      if (api.native && onboardChord) {
        try {
          await api.configureShortcut("palette", onboardChord);
        } catch (e) {
          notify(api.message(e));
        }
      }
      s = await refresh();
      select(
        s?.actions.find((a) => a.name === "Resolve CI") ||
          s?.actions[0] ||
          null,
        s,
      );
    } catch (e) {
      setError(api.message(e));
    } finally {
      setSaving(false);
    }
  }
  function open() {
    if (api.native)
      void api.openPalette().catch((e) => setError(api.message(e)));
    else setPalette((v) => !v);
  }
  useEffect(() => {
    function key(e: KeyboardEvent) {
      if (
        e.isComposing ||
        e.keyCode === 229 ||
        confirm ||
        categoryDialog ||
        importPreview
      )
        return;
      if (!snapshot?.settings.onboarded || paletteWindow || palette) return;
      if (
        !api.native &&
        matchesShortcut(e, snapshot.settings.paletteShortcut)
      ) {
        e.preventDefault();
        open();
        return;
      }
      if (
        (e.metaKey || e.ctrlKey) &&
        e.key.toLowerCase() === "s" &&
        page === "library"
      ) {
        e.preventDefault();
        void save();
      }
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "n") {
        e.preventDefault();
        navigate("new");
      }
      if ((e.metaKey || e.ctrlKey) && e.key === ",") {
        e.preventDefault();
        navigate("settings");
      }
      if (e.key === "Escape" && draft) {
        guarded(() =>
          select(snapshot?.actions.find((a) => a.id === draft.id) || null),
        );
      }
    }
    window.addEventListener("keydown", key);
    const unload = (e: BeforeUnloadEvent) => {
      if (stateRef.current.dirty) {
        e.preventDefault();
        e.returnValue = "";
      }
    };
    window.addEventListener("beforeunload", unload);
    return () => {
      window.removeEventListener("keydown", key);
      window.removeEventListener("beforeunload", unload);
    };
  });
  async function beginImport(file?: File) {
    try {
      const preview = await api.previewImport(file);
      if (preview) {
        setImportPreview(preview);
        setImportUpdate(false);
      }
    } catch (e) {
      setError(api.message(e));
    }
  }
  async function commit() {
    if (!importPreview) return;
    try {
      await api.commitImport(importPreview.token, importUpdate);
      setImportPreview(null);
      await refresh();
      notify("Imported.");
    } catch (e) {
      setImportPreview(null);
      setError(api.message(e));
    }
  }
  async function saveCategory() {
    if (!categoryDialog || !snapshot) return;
    try {
      await api.operation("category", {
        ...categoryDialog,
        revision: snapshot.revision,
      });
      setCategoryDialog(null);
      await refresh();
    } catch (e) {
      setError(api.message(e));
    }
  }
  if (!snapshot)
    return (
      <div className="loading">
        <Mark size={40} />
        {loadError ? (
          <>
            <h2>Could not open your library</h2>
            <p role="alert">{loadError}</p>
            <button onClick={() => void refresh()}>Try again</button>
          </>
        ) : (
          <p>Opening Cue…</p>
        )}
      </div>
    );
  if (paletteWindow)
    return (
      <Palette
        snapshot={snapshot}
        onClose={(copied) => {
          if (!copied) void api.closePalette();
        }}
        onNavigate={navigate}
        onRefresh={() => void refresh()}
      />
    );
  if (!snapshot.settings.onboarded)
    return (
      <main className="onboarding">
        <div className="window-drag" data-tauri-drag-region />
        <div className="onboard-shell">
          <div className="brand">
            <Mark size={42} />
            <span>cue</span>
          </div>
          <span className="eyebrow">YOUR PROMPTS, ON CUE.</span>
          {onboardingStep === 0 ? (
            <>
              <h1>
                The right words.
                <br />
                One shortcut away.
              </h1>
              <p className="intro">
                Save an instruction once. Call it up from any app.
                <br />
                Keep working where you already are.
              </p>
              <div className="flow-demo">
                <div>
                  <span>
                    <Keyboard size={18} />
                  </span>
                  <strong>Call it up</strong>
                  <Keys value={onboardChord} />
                </div>
                <ArrowRight size={16} />
                <div>
                  <span>
                    <Search size={18} />
                  </span>
                  <strong>Find your action</strong>
                  <small>resolve ci</small>
                </div>
                <ArrowRight size={16} />
                <div>
                  <span>
                    <Copy size={18} />
                  </span>
                  <strong>Copy & continue</strong>
                  <small>Right into your draft</small>
                </div>
              </div>
              <div className="onboard-note">
                <span className="status-dot" /> Local only. No account. No AI
                inside.
              </div>
              <button className="primary" onClick={() => setOnboardingStep(1)}>
                Set up Cue <ArrowRight size={16} />
              </button>
            </>
          ) : (
            <>
              <h1>Make it yours.</h1>
              <p className="intro">
                A shortcut and a few good starting points.
              </p>
              <div className="setup-block">
                <label>Open the palette</label>
                <ShortcutRecorder
                  value={onboardChord}
                  onChange={setOnboardChord}
                />
                <p>
                  {api.native
                    ? "We’ll register this shortcut when you finish. You can change it later."
                    : "In the browser preview, use this shortcut while Cue is focused. Global registration requires the desktop app."}
                </p>
              </div>
              <div className="setup-block">
                <div className="setting-row">
                  <div>
                    <h3>Start with six useful actions</h3>
                    <p>
                      CI fixes, PR reviews, clear writing, and more. All
                      editable.
                    </p>
                  </div>
                  <Toggle
                    checked={addStarters}
                    onChange={setAddStarters}
                    label="Add starter actions"
                  />
                </div>
                <div className="starter-chips">
                  {["Resolve CI", "Explain this PR", "Rewrite clearly"].map(
                    (s) => (
                      <span key={s}>{s}</span>
                    ),
                  )}
                </div>
              </div>
              <div className="copy-first">
                <Copy size={18} />
                <div>
                  <strong>Paste into the app you’re using</strong>
                  <p>
                    Open Cue from a text field, choose an action, and press
                    Enter. macOS needs Accessibility access to paste.
                    Shift+Enter copies instead.
                  </p>
                </div>
              </div>
              {error && (
                <p className="inline-error" role="alert">
                  {error}
                </p>
              )}
              <div className="onboarding-actions">
                <button
                  className="text-button"
                  onClick={() => setOnboardingStep(0)}
                >
                  <ChevronLeft size={15} /> Back
                </button>
                <button
                  className="primary"
                  disabled={saving}
                  onClick={() => void finishOnboarding()}
                >
                  {saving ? "Setting up…" : "Open my library"}
                  <ArrowRight size={15} />
                </button>
              </div>
            </>
          )}
          <div className="onboarding-footer">
            <span>Built for your working context.</span>
            <span>01 / 0{onboardingStep + 1}</span>
          </div>
        </div>
      </main>
    );
  const count = (fn: (a: Action) => boolean) =>
    snapshot.actions.filter(fn).length;
  const status = snapshot.shortcuts.find((s) => s.owner === "palette");
  return (
    <main className={`app ${page === "settings" ? "settings-page" : ""}`}>
      <div className="window-drag" data-tauri-drag-region />
      <aside className="sidebar">
        <div className="sidebar-brand">
          <Mark size={24} />
          <span>cue</span>
        </div>
        <div className="nav-main">
          {[
            ["all", "All actions", Grid2X2, snapshot.actions.length],
            ["favorites", "Favorites", Star, count((a) => a.favorite)],
            ["recent", "Recent", Clock3, count((a) => !!a.lastUsedAt)],
          ].map(([id, label, Icon, n]) => (
            <button
              key={String(id)}
              className={filter === id && page === "library" ? "selected" : ""}
              onClick={() =>
                guarded(() => {
                  setFilter(String(id));
                  setPage("library");
                  setQuery("");
                })
              }
            >
              {typeof Icon === "function" || typeof Icon === "object" ? (
                <Icon size={15} />
              ) : null}
              <span>{String(label)}</span>
              <small>{Number(n) || ""}</small>
            </button>
          ))}
        </div>
        <div className="sidebar-section-label">Categories</div>
        {snapshot.categories.map((c) => (
          <div className="category-nav" key={c}>
            <button
              className={filter === c && page === "library" ? "selected" : ""}
              onClick={() =>
                guarded(() => {
                  setFilter(c);
                  setPage("library");
                  setQuery("");
                })
              }
            >
              <Folder size={15} />
              <span>{c}</span>
              <small>{count((a) => a.category === c) || ""}</small>
            </button>
            <button
              className="category-more"
              aria-label={`Manage ${c}`}
              onClick={() => setCategoryMenu(categoryMenu === c ? null : c)}
            >
              <MoreHorizontal size={13} />
            </button>
            {categoryMenu === c && (
              <div className="category-popup">
                <button
                  onClick={() => {
                    setCategoryDialog({ old: c, name: c });
                    setCategoryMenu(null);
                  }}
                >
                  Rename category
                </button>
                <button
                  onClick={() => {
                    setCategoryMenu(null);
                    setConfirm({
                      title: `Delete “${c}” category?`,
                      body: "Its actions will stay in your library without a category.",
                      label: "Delete category",
                      danger: true,
                      run: () => {
                        void api
                          .operation("category", {
                            old: c,
                            name: "",
                            revision: snapshot.revision,
                          })
                          .then(() => {
                            setFilter("all");
                            void refresh();
                          })
                          .catch((e) => setError(api.message(e)));
                      },
                    });
                  }}
                >
                  Delete category
                </button>
              </div>
            )}
          </div>
        ))}
        <button
          className="new-category"
          onClick={() => setCategoryDialog({ name: "" })}
        >
          <Plus size={15} />
          <span>New category</span>
        </button>
        <div className="sidebar-section-label">Hidden</div>
        <button
          className={
            filter === "disabled" && page === "library" ? "selected" : ""
          }
          onClick={() =>
            guarded(() => {
              setFilter("disabled");
              setPage("library");
              setQuery("");
            })
          }
        >
          <Ban size={15} />
          <span>Disabled</span>
          <small>{count((a) => !a.enabled) || ""}</small>
        </button>
        <div className="sidebar-bottom">
          <button
            className={page === "settings" ? "selected" : ""}
            onClick={() => navigate("settings")}
          >
            <SettingsIcon size={15} />
            <span>Settings</span>
            <span className="nav-key">{mac ? "⌘," : "Ctrl+,"}</span>
          </button>
          <button className="palette-launch" onClick={open}>
            <span className="status-dot" />
            <span>
              {status?.active ? (
                <>
                  <Keys value={status.active} /> active
                </>
              ) : api.native ? (
                "Open palette"
              ) : (
                "Try the palette"
              )}
            </span>
            {!status?.active && <Command size={13} />}
          </button>
        </div>
      </aside>
      {page === "settings" ? (
        <Settings
          snapshot={snapshot}
          capabilities={capabilities}
          onSave={(s) => void saveSettings(s)}
          onBack={() => setPage("library")}
          onImport={() => {
            if (api.native) void beginImport();
            else fileInput.current?.click();
          }}
          onExport={() =>
            void api
              .exportActions()
              .then((ok) => ok && notify("Exported."))
              .catch((e) => setError(api.message(e)))
          }
          onClear={() =>
            setConfirm({
              title: "Clear usage history?",
              body: "This resets use counts and recent actions. All templates stay in your library.",
              label: "Clear usage",
              run: () => {
                void api
                  .operation("clear_usage", {})
                  .then(() => {
                    void refresh();
                    notify("Usage cleared.");
                  })
                  .catch((e) => setError(api.message(e)));
              },
            })
          }
          onRecheck={refreshCapabilities}
          onError={setError}
        />
      ) : (
        <>
          <section className="action-list">
            <header>
              <div className="filter-input">
                <Search size={15} />
                <input
                  aria-label="Filter actions"
                  placeholder="Filter actions"
                  value={query}
                  onChange={(e) => setQuery(e.target.value)}
                />
                {query && (
                  <button
                    aria-label="Clear filter"
                    onClick={() => setQuery("")}
                  >
                    <X size={12} />
                  </button>
                )}
              </div>
              <IconButton label="New action" onClick={() => navigate("new")}>
                <Plus size={18} />
              </IconButton>
            </header>
            <div className="list-section">
              {filter === "all"
                ? "All actions"
                : filter === "favorites"
                  ? "Favorites"
                  : filter === "recent"
                    ? "Recent"
                    : filter === "disabled"
                      ? "Disabled"
                      : filter}
              <span>{actions.length}</span>
            </div>
            <div
              className="action-list-scroll"
              role="listbox"
              aria-label="Library actions"
              onKeyDown={(e) => {
                if (e.key === "ArrowDown" || e.key === "ArrowUp") {
                  e.preventDefault();
                  const i = actions.findIndex((a) => a.id === draft?.id);
                  const a =
                    actions[
                      (i + (e.key === "ArrowDown" ? 1 : -1) + actions.length) %
                        actions.length
                    ];
                  if (a) guarded(() => select(a));
                }
              }}
            >
              {actions.map((a) => (
                <button
                  role="option"
                  aria-selected={draft?.id === a.id}
                  key={a.id}
                  className={`library-row ${draft?.id === a.id ? "selected" : ""} ${!a.enabled ? "disabled-action" : ""}`}
                  onClick={() => guarded(() => select(a))}
                >
                  <span className="row-name">
                    {a.name}
                    {a.favorite && (
                      <Star
                        size={10}
                        className="favorite-star"
                        fill="currentColor"
                      />
                    )}
                    {draft?.id === a.id && dirty && (
                      <span className="unsaved-dot" />
                    )}
                  </span>
                  <span className="row-description">
                    {a.category || "Uncategorized"} ·{" "}
                    {!a.enabled
                      ? "disabled"
                      : a.template.includes("{{clipboard}}")
                        ? "uses clipboard"
                        : a.useCount
                          ? `used ${a.useCount}×`
                          : "never used"}
                  </span>
                </button>
              ))}
              {!actions.length && (
                <div className="empty-state">
                  <Search size={24} />
                  <h3>{query ? "No matching actions" : "Nothing here yet"}</h3>
                  <p>
                    {query
                      ? "Try another name or tag."
                      : "Add your first reusable instruction."}
                  </p>
                  <button onClick={() => navigate("new")}>
                    <Plus size={13} /> New action
                  </button>
                </div>
              )}
            </div>
            <footer className="list-footer">
              <span>{snapshot.actions.length} local actions</span>
              <button
                aria-label="Open palette"
                title="Open palette"
                onClick={open}
              >
                <Command size={14} />
              </button>
            </footer>
          </section>
          {draft ? (
            <Editor
              key={draft.id}
              onBack={() => guarded(() => select(null))}
              draft={draft}
              setDraft={setDraft}
              snapshot={snapshot}
              dirty={dirty}
              shortcut={shortcut}
              setShortcut={setShortcut}
              onSave={() => void save()}
              onDiscard={() =>
                guarded(() =>
                  select(
                    snapshot.actions.find((a) => a.id === draft.id) || null,
                  ),
                )
              }
              onCopy={() => void copy()}
              onDuplicate={() => void duplicate()}
              onDelete={deleteAction}
              saving={saving}
              error={error}
            />
          ) : (
            <section className="no-selection">
              <Mark size={48} />
              <h2>Your next instruction starts here.</h2>
              <p>Save the words you use again and again.</p>
              <button onClick={() => navigate("new")}>
                <Plus size={14} /> New action
              </button>
              <span>
                <Keys value={`${mac ? "Super" : "Control"}+N`} />
              </span>
            </section>
          )}
        </>
      )}
      {page === "settings" && error && (
        <div className="error-banner" role="alert">
          <AlertCircle size={16} />
          {error}
          <IconButton label="Dismiss error" onClick={() => setError("")}>
            <X size={14} />
          </IconButton>
        </div>
      )}
      {toast && (
        <div className="toast" role="status">
          <Check size={16} />
          {toast}
        </div>
      )}
      {!api.native && palette && (
        <div
          className="palette-scrim"
          onMouseDown={(e) => {
            if (e.target === e.currentTarget) setPalette(false);
          }}
        >
          <Palette
            snapshot={snapshot}
            onClose={(copied) => {
              setPalette(false);
              if (copied) notify("Copied.");
            }}
            onNavigate={navigate}
            onRefresh={() => void refresh()}
          />
        </div>
      )}
      {confirm && (
        <Modal
          title={confirm.title}
          onClose={() => setConfirm(null)}
          footer={
            <>
              <button autoFocus onClick={() => setConfirm(null)}>
                Cancel
              </button>
              <button
                className={confirm.danger ? "danger" : "primary"}
                onClick={() => {
                  const run = confirm.run;
                  setConfirm(null);
                  run();
                }}
              >
                {confirm.label}
              </button>
            </>
          }
        >
          <p>{confirm.body}</p>
        </Modal>
      )}
      {categoryDialog && (
        <Modal
          title={categoryDialog.old ? "Rename category" : "New category"}
          onClose={() => setCategoryDialog(null)}
          footer={
            <>
              <button onClick={() => setCategoryDialog(null)}>Cancel</button>
              <button
                className="primary"
                disabled={!categoryDialog.name.trim()}
                onClick={() => void saveCategory()}
              >
                Save category
              </button>
            </>
          }
        >
          <label>
            Category name
            <input
              autoFocus
              value={categoryDialog.name}
              maxLength={50}
              onChange={(e) =>
                setCategoryDialog({ ...categoryDialog, name: e.target.value })
              }
              onKeyDown={(e) => {
                if (e.key === "Enter") void saveCategory();
              }}
            />
          </label>
          {error && <p className="inline-error">{error}</p>}
        </Modal>
      )}
      {importPreview && (
        <Modal
          title="Import actions"
          onClose={() => setImportPreview(null)}
          footer={
            <>
              <button onClick={() => setImportPreview(null)}>Cancel</button>
              <button
                className="primary"
                onClick={() => {
                  if (importUpdate)
                    setConfirm({
                      title: "Update matching action IDs?",
                      body: `Replace ${importPreview.duplicateIds} existing actions with the displayed imported text. Their shortcuts are removed and delivery changes to Copy.`,
                      label: "Update and import",
                      run: () => void commit(),
                    });
                  else void commit();
                }}
              >
                Import {importPreview.actions.length} actions
              </button>
            </>
          }
        >
          <p className="muted">
            Schema v1 · validated. Nothing has changed yet.
          </p>
          <div className="import-stats">
            {[
              [importPreview.actions.length, "actions"],
              [importPreview.newCategories.length, "new categories"],
              [importPreview.duplicateNames, "same names"],
              [importPreview.duplicateIds, "same IDs"],
            ].map(([n, l]) => (
              <div key={l}>
                <strong>{n}</strong>
                <span>{l}</span>
              </div>
            ))}
          </div>
          <label className="radio-label">
            <input
              type="radio"
              checked={!importUpdate}
              onChange={() => setImportUpdate(false)}
            />
            <div>
              <strong>Add as new actions</strong>
              <p>Fresh IDs. Keep all existing actions.</p>
            </div>
          </label>
          <label className="radio-label">
            <input
              type="radio"
              disabled={!importPreview.duplicateIds}
              checked={importUpdate}
              onChange={() => setImportUpdate(true)}
            />
            <div>
              <strong>Update matching IDs</strong>
              <p>Names alone never overwrite.</p>
            </div>
          </label>
          <div className="import-rows">
            {importPreview.actions.map((a) => {
              const old = snapshot.actions.find((b) => b.id === a.id);
              return (
                <div key={a.id}>
                  <strong>{a.name}</strong>
                  <span>{a.category || "Uncategorized"}</span>
                  <p>{a.template}</p>
                  {importUpdate && old && (
                    <details>
                      <summary>Before / after</summary>
                      <h4>Before</h4>
                      <pre>{old.template}</pre>
                      <h4>After</h4>
                      <pre>{a.template}</pre>
                    </details>
                  )}
                </div>
              );
            })}
          </div>
          <p className="notice">
            Imported actions use Copy and get no shortcuts.
            {api.native ? " A backup is made first." : ""}
          </p>
        </Modal>
      )}
      <input
        ref={fileInput}
        type="file"
        hidden
        accept="application/json,.json"
        onChange={(e) => {
          const f = e.target.files?.[0];
          if (f) void beginImport(f);
          e.target.value = "";
        }}
      />
    </main>
  );
}
