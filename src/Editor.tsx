import { useRef, useState } from "react";
import {
  Copy,
  Star,
  CopyPlus,
  Trash2,
  ChevronDown,
  Braces,
  ArrowLeft,
} from "lucide-react";
import type { Action, Snapshot } from "./domain/types";
import {
  IconButton,
  Keys,
  Toggle,
  Tags,
  ShortcutRecorder,
  mac,
} from "./components/ui";
import { bytes, renderTemplate, validateText } from "./domain/templates";
export default function Editor({
  onBack,
  draft,
  setDraft,
  snapshot,
  dirty,
  shortcut,
  setShortcut,
  onSave,
  onDiscard,
  onCopy,
  onDuplicate,
  onDelete,
  saving,
  error,
}: {
  onBack: () => void;
  draft: Action;
  setDraft: (a: Action) => void;
  snapshot: Snapshot;
  dirty: boolean;
  shortcut: string;
  setShortcut: (s: string) => void;
  onSave: () => void;
  onDiscard: () => void;
  onCopy: () => void;
  onDuplicate: () => void;
  onDelete: () => void;
  saving: boolean;
  error: string;
}) {
  const textarea = useRef<HTMLTextAreaElement>(null);
  const [preview, setPreview] = useState(false);
  const [insertionError, setInsertionError] = useState("");
  const set = <K extends keyof Action>(key: K, value: Action[K]) =>
    setDraft({ ...draft, [key]: value });
  let validation = "";
  let sample = "";
  try {
    if (draft.template) {
      validateText(draft.template);
      sample = renderTemplate(
        draft.template,
        "We should move the deploy to Thursday.",
      );
    }
  } catch (e) {
    validation = (e as Error).message;
  }
  function insert(token: string) {
    const node = textarea.current;
    if (!node) return;
    const start = node.selectionStart;
    const end = node.selectionEnd;
    node.blur();
    node.focus();
    node.setSelectionRange(start, end);
    // Native text insertion preserves the same undo history as typing and paste.
    const inserted = node.ownerDocument.execCommand("insertText", false, token);
    setInsertionError(
      inserted ? "" : `Could not insert text. Type ${token} in the text field.`,
    );
  }
  const status = snapshot.shortcuts.find(
    (s) => s.owner === `action:${draft.id}`,
  );
  return (
    <section className="editor" aria-label="Action editor">
      <header className="editor-toolbar">
        <button className="editor-back text-button" onClick={onBack}>
          <ArrowLeft size={13} /> Actions
        </button>
        <span>
          {draft.revision
            ? `Revision ${draft.revision}${dirty ? " · unsaved changes" : ""}`
            : "New action · not saved"}
        </span>
        <div>
          <IconButton
            label="Copy action"
            onClick={onCopy}
            disabled={!draft.revision || dirty}
          >
            <Copy size={15} />
          </IconButton>
          <IconButton
            label={draft.favorite ? "Remove favorite" : "Add favorite"}
            onClick={() => set("favorite", !draft.favorite)}
            active={draft.favorite}
          >
            <Star size={15} fill={draft.favorite ? "currentColor" : "none"} />
          </IconButton>
          <IconButton
            label="Duplicate action"
            onClick={onDuplicate}
            disabled={!draft.revision || dirty}
          >
            <CopyPlus size={15} />
          </IconButton>
          <IconButton
            label="Delete action"
            onClick={onDelete}
            disabled={!draft.revision}
          >
            <Trash2 size={15} />
          </IconButton>
          <span className="toolbar-divider" />
          <label className="enabled-label">
            Enabled
            <Toggle
              checked={draft.enabled}
              onChange={(v) => set("enabled", v)}
              label="Action enabled"
            />
          </label>
        </div>
      </header>
      <div className="editor-fields">
        <div className="field-grid">
          <label>
            Name
            <input
              autoFocus={!draft.revision}
              value={draft.name}
              onChange={(e) => set("name", e.target.value)}
              placeholder="What does this action do?"
              maxLength={200}
            />
          </label>
          <label>
            Description
            <input
              value={draft.description}
              onChange={(e) => set("description", e.target.value)}
              placeholder="A short explanation"
            />
          </label>
        </div>
        <div className="template-label">
          <label htmlFor="template">Text</label>
          <div>
            <span>Add variable</span>
            {[
              [
                "clipboard",
                "Clipboard text",
                "Use the clipboard text from when you run this action",
              ],
              ["date", "Date", "Use the date from when you run this action"],
              ["time", "Time", "Use the time from when you run this action"],
            ].map(([v, label, description]) => (
              <button
                key={v}
                type="button"
                title={description}
                onMouseDown={(e) => e.preventDefault()}
                onClick={() => insert(`{{${v}}}`)}
              >
                {label}
              </button>
            ))}
          </div>
        </div>
        <textarea
          id="template"
          ref={textarea}
          spellCheck={false}
          value={draft.template}
          onChange={(e) => {
            setInsertionError("");
            set("template", e.target.value);
          }}
          onKeyDown={(e) => {
            if (e.key === "Tab" && !e.shiftKey && !e.nativeEvent.isComposing) {
              e.preventDefault();
              insert("  ");
            }
          }}
          placeholder="Write the instruction you want to reuse…"
          className={validation ? "invalid" : ""}
          aria-describedby="template-help"
        />
        <p id="template-help" className="template-help">
          Clipboard text is filled in when you use the action. For example, copy
          a paragraph, then use Rewrite clearly.
        </p>
        <div className="text-count">
          {[...draft.template].length.toLocaleString()} chars ·{" "}
          {bytes(draft.template).toLocaleString()} B of 64 KiB
        </div>
        {validation && (
          <p className="inline-error" role="alert">
            {validation}
          </p>
        )}
        <button className="sample-toggle" onClick={() => setPreview((v) => !v)}>
          <Braces size={13} /> Preview with sample clipboard
          <ChevronDown size={12} className={preview ? "rotated" : ""} />
        </button>
        {preview && (
          <div className="sample-preview">
            <p>Your real clipboard is never read here.</p>
            <pre>{sample || "Add text to preview this action."}</pre>
          </div>
        )}
        <div className="field-grid metadata">
          <label>
            Category
            <select
              value={draft.category || ""}
              onChange={(e) => set("category", e.target.value || null)}
            >
              <option value="">No category</option>
              {snapshot.categories.map((c) => (
                <option key={c}>{c}</option>
              ))}
            </select>
          </label>
          <label>
            Aliases
            <Tags
              value={draft.aliases}
              onChange={(v) => set("aliases", v)}
              label="Add an alias"
            />
          </label>
          <fieldset>
            <legend>When used</legend>
            <div className="segmented" aria-label="Delivery preference">
              {(["inherit", "copy", "paste"] as const).map((mode) => (
                <button
                  type="button"
                  key={mode}
                  aria-pressed={draft.deliveryMode === mode}
                  className={draft.deliveryMode === mode ? "chosen" : ""}
                  onClick={() => set("deliveryMode", mode)}
                >
                  {mode === "inherit"
                    ? `Default · ${snapshot.settings.defaultDelivery === "copy" ? "Copy" : "Paste"}`
                    : mode === "copy"
                      ? "Copy"
                      : "Paste"}
                </button>
              ))}
            </div>
          </fieldset>
        </div>
        <label className="direct-shortcut-label">
          Direct shortcut
          <ShortcutRecorder value={shortcut} onChange={setShortcut} />
        </label>
        <p className="shortcut-status">
          {status?.active && status.requested === shortcut ? (
            <>
              <span className="status-dot" /> Active
            </>
          ) : status?.error ? (
            <span className="inline-error">{status.error}</span>
          ) : shortcut ? (
            "Registers when you save."
          ) : (
            "No shortcut assigned."
          )}
        </p>
        {draft.deliveryMode === "paste" && (
          <p className="notice-small">
            Open Cue from a text field with your shortcut. On macOS, enable
            Accessibility access in Settings to paste directly.
          </p>
        )}
        {(error || insertionError) && (
          <p className="inline-error" role="alert">
            {error || insertionError}
          </p>
        )}
      </div>
      <footer className="editor-footer">
        <span>
          {saving ? "Saving…" : dirty ? "Unsaved changes" : "All changes saved"}
        </span>
        <div>
          {dirty && (
            <button className="text-button" onClick={onDiscard}>
              Discard
            </button>
          )}
          <button
            className="primary subtle"
            disabled={!dirty || saving || !!validation}
            onClick={onSave}
          >
            Save <Keys value={`${mac ? "Super" : "Control"}+S`} />
          </button>
        </div>
      </footer>
    </section>
  );
}
