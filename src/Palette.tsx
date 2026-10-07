import { useEffect, useMemo, useRef, useState } from "react";
import {
  Search,
  CornerDownLeft,
  Star,
  Code2,
  AlignLeft,
  ChevronDown,
  ChevronRight,
  MoreHorizontal,
  Copy,
  PenLine,
  Plus,
  Settings,
  Clipboard,
  X,
} from "lucide-react";
import type { Snapshot } from "./domain/types";
import { searchActions } from "./domain/search";
import * as api from "./ipc/client";
import { containTab } from "./components/focus";
import { IconButton, Keys, mac } from "./components/ui";
export default function Palette({
  snapshot,
  onClose,
  onNavigate,
  onRefresh,
}: {
  snapshot: Snapshot;
  onClose: (copied?: boolean) => void;
  onNavigate: (page: string, id?: string) => void;
  onRefresh: () => void;
}) {
  const [query, setQuery] = useState(""),
    [selected, setSelected] = useState<string>(),
    [preview, setPreview] = useState(snapshot.settings.preview),
    [menu, setMenu] = useState(false),
    [busy, setBusy] = useState(false),
    [error, setError] = useState(""),
    [blocked, setBlocked] = useState(false),
    [invocation, setInvocation] = useState<string>("");
  const input = useRef<HTMLInputElement>(null);
  const list = useRef<HTMLDivElement>(null);
  const latest = useRef(snapshot);
  latest.current = snapshot;
  const usage = useRef(
    new Map(snapshot.actions.map((a) => [a.id, a.lastUsedAt])),
  );
  const ranked = useMemo(
    () =>
      searchActions(
        snapshot.actions.map((a) => ({
          ...a,
          lastUsedAt: usage.current.has(a.id)
            ? usage.current.get(a.id)!
            : a.lastUsedAt,
        })),
        query,
      ),
    [snapshot.actions, query, invocation],
  );
  const current = ranked.find((a) => a.id === selected) || ranked[0];
  const delivery =
    current?.deliveryMode === "inherit"
      ? snapshot.settings.defaultDelivery
      : current?.deliveryMode || snapshot.settings.defaultDelivery;
  useEffect(() => {
    input.current?.focus();
    let clean = () => {};
    let disposed = false;
    if (api.native) {
      api
        .paletteContext()
        .then(setInvocation)
        .catch((e) => setError(api.message(e)));
      api
        .onEvent<string>("palette_opened", (id) => {
          setInvocation(id);
          setQuery("");
          setSelected(undefined);
          setError("");
          setBlocked(false);
          setBusy(false);
          setMenu(false);
          usage.current = new Map(
            latest.current.actions.map((a) => [a.id, a.lastUsedAt]),
          );
          input.current?.focus();
          onRefresh();
        })
        .then((fn) => {
          if (disposed) fn();
          else clean = fn;
        });
    } else {
      setInvocation(crypto.randomUUID());
    }
    return () => {
      disposed = true;
      clean();
    };
  }, []);
  useEffect(() => {
    if (current) {
      setSelected(current.id);
      list.current
        ?.querySelector(`[data-id="${current.id}"]`)
        ?.scrollIntoView({ block: "nearest" });
    }
  }, [current?.id]);
  useEffect(() => {
    if (!menu) input.current?.focus();
  }, [menu]);
  async function run(copy = false) {
    if (!current || busy) return;
    setBusy(true);
    setError("");
    setMenu(false);
    try {
      const result = await api.execute(current, { invocation, copy });
      if (result.status === "blocked") {
        setBlocked(true);
        setError(result.message);
      } else if (result.status === "copied" || result.status === "pasted") {
        onRefresh();
        onClose(true);
      } else setError(result.message);
    } catch (e) {
      setError(api.message(e));
    } finally {
      setBusy(false);
    }
  }
  function key(e: React.KeyboardEvent) {
    if (e.nativeEvent.isComposing || e.keyCode === 229) return;
    containTab(e);
    if (menu && (e.key === "ArrowUp" || e.key === "ArrowDown")) return;
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      const i = Math.max(
        0,
        ranked.findIndex((a) => a.id === current?.id),
      );
      setSelected(
        ranked[
          (i + (e.key === "ArrowDown" ? 1 : -1) + ranked.length) % ranked.length
        ]?.id,
      );
      setMenu(false);
    } else if (e.key === "Enter" && !menu && e.target === input.current) {
      e.preventDefault();
      void run(e.shiftKey);
    } else if (e.key === "Escape") {
      e.preventDefault();
      if (menu) setMenu(false);
      else onClose();
    } else if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
      e.preventDefault();
      setMenu((v) => !v);
    } else if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "n") {
      e.preventDefault();
      onNavigate("new");
    } else if ((e.metaKey || e.ctrlKey) && e.key === ",") {
      e.preventDefault();
      onNavigate("settings");
    }
  }
  return (
    <section
      className={`palette ${api.native ? "native-palette" : ""}`}
      role="dialog"
      aria-modal="true"
      aria-label="Cue action palette"
      onKeyDown={key}
    >
      <div className="palette-search">
        <Search size={20} />
        <input
          ref={input}
          placeholder="What do you need to do?"
          aria-label="Search actions"
          role="combobox"
          aria-expanded="true"
          aria-controls="palette-results"
          aria-activedescendant={current ? `result-${current.id}` : undefined}
          autoComplete="off"
          value={query}
          onChange={(e) => {
            setQuery(e.target.value);
            setBlocked(false);
            setError("");
          }}
        />
        <Keys value="Escape" />
      </div>
      <div className="palette-body">
        <div className="section-label">
          {query ? "RESULTS" : "YOUR ACTIONS"}
          <span>
            {ranked.length} {ranked.length === 1 ? "action" : "actions"}
          </span>
        </div>
        <div
          ref={list}
          id="palette-results"
          role="listbox"
          aria-label="Actions"
          className="palette-results"
        >
          {ranked.map((a) => (
            <div
              id={`result-${a.id}`}
              data-id={a.id}
              role="option"
              aria-selected={a.id === current?.id}
              key={a.id}
              className={`palette-row ${a.id === current?.id ? "selected" : ""}`}
              onMouseMove={() => setSelected(a.id)}
              onClick={() => {
                setSelected(a.id);
              }}
              onDoubleClick={() => void run()}
            >
              <span className="action-icon">
                {a.category === "Writing" ? (
                  <AlignLeft size={18} />
                ) : (
                  <Code2 size={18} />
                )}
              </span>
              <div>
                <div className="row-name">
                  {a.name}
                  {a.favorite && (
                    <Star
                      size={11}
                      className="favorite-star"
                      fill="currentColor"
                    />
                  )}
                </div>
                <p>{a.description || a.category || "Text action"}</p>
              </div>
              <span className="row-end">
                {a.id === current?.id ? (
                  <CornerDownLeft size={16} />
                ) : a.template.includes("{{clipboard}}") ? (
                  <Clipboard size={13} />
                ) : null}
              </span>
            </div>
          ))}
        </div>
        {!ranked.length && (
          <div className="empty-state">
            <Search size={25} />
            <h3>
              {snapshot.actions.some((a) => a.enabled)
                ? "No matching actions"
                : "No actions yet"}
            </h3>
            <p>
              {query
                ? `Try another name or alias.`
                : "Create an action to call it up here."}
            </p>
            <button onClick={() => onNavigate("new")}>
              <Plus size={14} /> New action
            </button>
          </div>
        )}
      </div>
      {current && (
        <div className="palette-preview">
          <div className="preview-heading">
            <button
              className="preview-toggle"
              aria-expanded={preview}
              aria-controls="action-preview"
              onClick={() => setPreview((v) => !v)}
            >
              {preview ? <ChevronDown size={13} /> : <ChevronRight size={13} />}
              Preview text
            </button>
            {current.category && (
              <span className="preview-category">{current.category}</span>
            )}
          </div>
          {preview && <pre id="action-preview">{current.template}</pre>}
        </div>
      )}
      {error && (
        <div className="palette-error" role="alert">
          <span>{error}</span>
          {blocked && (
            <button disabled={busy} onClick={() => void run(true)}>
              <Copy size={14} /> Copy instead
            </button>
          )}
          <IconButton label="Dismiss error" onClick={() => setError("")}>
            <X size={14} />
          </IconButton>
        </div>
      )}
      <footer className="palette-footer">
        <span className="copy-mode">
          <span className="status-dot" />{" "}
          {delivery === "paste" ? "Paste" : "Copy"} mode
        </span>
        <div>
          <button disabled={busy || !current} onClick={() => void run()}>
            <Keys value="Enter" />{" "}
            {busy ? "Preparing…" : delivery === "paste" ? "Paste" : "Copy"}
          </button>
          <button disabled={busy || !current} onClick={() => void run(true)}>
            <Keys value="Shift+Enter" /> Copy
          </button>
          <button onClick={() => setMenu((v) => !v)} aria-label="Action menu">
            <MoreHorizontal size={16} />
            <Keys value={`${mac ? "Super" : "Control"}+K`} />
          </button>
        </div>
      </footer>
      {menu && current && (
        <div
          className="action-menu"
          role="menu"
          onKeyDown={(e) => {
            if (e.key === "ArrowDown" || e.key === "ArrowUp") {
              e.preventDefault();
              const nodes = [
                ...e.currentTarget.querySelectorAll<HTMLElement>("button"),
              ];
              const i = nodes.indexOf(document.activeElement as HTMLElement);
              nodes[
                (i + (e.key === "ArrowDown" ? 1 : -1) + nodes.length) %
                  nodes.length
              ]?.focus();
            }
          }}
        >
          <button autoFocus role="menuitem" onClick={() => void run(true)}>
            <Copy size={15} /> Copy action
          </button>
          <button role="menuitem" onClick={() => void run()}>
            <CornerDownLeft size={15} />{" "}
            {delivery === "paste" ? "Paste action" : "Copy action"}
          </button>
          <button
            role="menuitem"
            onClick={() => onNavigate("library", current.id)}
          >
            <PenLine size={15} /> Edit action
          </button>
          <button
            role="menuitem"
            onClick={() => onNavigate("favorite", current.id)}
          >
            <Star size={15} />{" "}
            {current.favorite ? "Remove from favorites" : "Add to favorites"}
          </button>
          <button
            role="menuitem"
            onClick={() => onNavigate("disable", current.id)}
          >
            Disable action
          </button>
          <hr />
          <button role="menuitem" onClick={() => onNavigate("new")}>
            <Plus size={15} /> New action
          </button>
          <button role="menuitem" onClick={() => onNavigate("settings")}>
            <Settings size={15} /> Settings
          </button>
        </div>
      )}
      <span className="sr-only" aria-live="polite">
        {ranked.length} results. {current?.name}
      </span>
    </section>
  );
}
