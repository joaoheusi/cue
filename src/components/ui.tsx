import { useState, useEffect, useRef } from "react";
import { X, Command, Plus } from "lucide-react";
import type { ReactNode, KeyboardEvent } from "react";
import { shortcutKey } from "../domain/shortcuts";
import { containTab } from "./focus";
export const mac = navigator.platform.includes("Mac");
export function Mark({ size = 26 }: { size?: number }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 32 32"
      fill="none"
      aria-hidden="true"
    >
      <path
        d="M24.5 9a11 11 0 1 0 0 14"
        stroke="currentColor"
        strokeWidth="4.4"
        strokeLinecap="round"
      />
      <path
        d="M25 12v8"
        stroke="var(--accent)"
        strokeWidth="3.5"
        strokeLinecap="round"
      />
    </svg>
  );
}
export function Keys({ value }: { value: string }) {
  const keys = value.split("+").map(
    (k) =>
      ({
        Super: mac ? "⌘" : "Win",
        Command: "⌘",
        Control: mac ? "⌃" : "Ctrl",
        Alt: mac ? "⌥" : "Alt",
        Shift: mac ? "⇧" : "Shift",
        Space: "Space",
        Enter: "↵",
      })[k] || k,
  );
  return (
    <span className="keys">
      {keys.map((key, i) => (
        <kbd key={i}>{key}</kbd>
      ))}
    </span>
  );
}
export function IconButton({
  label,
  children,
  onClick,
  disabled,
  active,
}: {
  label: string;
  children: ReactNode;
  onClick: () => void;
  disabled?: boolean;
  active?: boolean;
}) {
  return (
    <button
      className={`icon-button ${active ? "active" : ""}`}
      title={label}
      aria-label={label}
      onClick={onClick}
      disabled={disabled}
    >
      {children}
    </button>
  );
}
export function Toggle({
  checked,
  onChange,
  label,
  disabled,
}: {
  checked: boolean;
  onChange: (v: boolean) => void;
  label: string;
  disabled?: boolean;
}) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      aria-label={label}
      disabled={disabled}
      className={`toggle ${checked ? "checked" : ""}`}
      onClick={() => onChange(!checked)}
    >
      <span />
    </button>
  );
}
export function Modal({
  title,
  children,
  onClose,
  footer,
}: {
  title: string;
  children: ReactNode;
  onClose: () => void;
  footer?: ReactNode;
}) {
  const previous = useRef(document.activeElement as HTMLElement | null);
  useEffect(
    () => () => {
      if (previous.current?.isConnected) previous.current.focus();
    },
    [],
  );
  return (
    <div
      className="scrim"
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <section
        className="modal"
        role="dialog"
        aria-modal="true"
        aria-label={title}
        onKeyDown={(e) => {
          if (e.key === "Escape") {
            e.stopPropagation();
            onClose();
          }
          containTab(e);
        }}
      >
        <header>
          <h2>{title}</h2>
          <IconButton label="Close dialog" onClick={onClose}>
            <X size={18} />
          </IconButton>
        </header>
        <div className="modal-content">{children}</div>
        {footer && <footer>{footer}</footer>}
      </section>
    </div>
  );
}
export function ShortcutRecorder({
  value,
  onChange,
}: {
  value: string;
  onChange: (value: string) => void;
}) {
  const [recording, setRecording] = useState(false);
  function record(e: KeyboardEvent<HTMLButtonElement>) {
    if (!recording) return;
    e.preventDefault();
    e.stopPropagation();
    if (e.key === "Escape") {
      setRecording(false);
      return;
    }
    if (["Meta", "Shift", "Control", "Alt"].includes(e.key)) return;
    const parts = [
      e.metaKey ? "Super" : "",
      e.ctrlKey ? "Control" : "",
      e.altKey ? "Alt" : "",
      e.shiftKey ? "Shift" : "",
      shortcutKey(e),
    ].filter(Boolean);
    if (parts.length < 2) return;
    onChange(parts.join("+"));
    setRecording(false);
  }
  return (
    <div className="shortcut-input">
      <button
        type="button"
        className={recording ? "recording" : ""}
        onClick={() => setRecording(true)}
        onKeyDown={record}
        onBlur={() => setRecording(false)}
        aria-label="Record shortcut"
      >
        {recording ? (
          <span>Press a shortcut…</span>
        ) : value ? (
          <Keys value={value} />
        ) : (
          <span className="muted">
            <Command size={13} /> Record shortcut
          </span>
        )}
      </button>
      {value && (
        <button className="text-button" onClick={() => onChange("")}>
          Clear
        </button>
      )}
    </div>
  );
}
export function Tags({
  value,
  onChange,
  label,
}: {
  value: string[];
  onChange: (v: string[]) => void;
  label: string;
}) {
  const [input, setInput] = useState("");
  function add() {
    if (input.trim()) {
      onChange([...value, input.trim()]);
      setInput("");
    }
  }
  return (
    <div className="tags-input">
      {value.map((v, i) => (
        <span className="tag" key={i}>
          {v}
          <button
            aria-label={`Remove ${v}`}
            onClick={() => onChange(value.filter((_, j) => j !== i))}
          >
            <X size={10} />
          </button>
        </span>
      ))}
      <input
        aria-label={label}
        value={input}
        placeholder={value.length ? "Add…" : label}
        onChange={(e) => setInput(e.target.value)}
        onBlur={add}
        onKeyDown={(e) => {
          if (e.key === "Enter" || e.key === ",") {
            e.preventDefault();
            add();
          }
          if (e.key === "Backspace" && !input) onChange(value.slice(0, -1));
        }}
      />
      <Plus size={12} />
    </div>
  );
}
