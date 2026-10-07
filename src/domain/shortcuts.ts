type KeyEvent = Pick<
  KeyboardEvent,
  "code" | "key" | "metaKey" | "ctrlKey" | "altKey" | "shiftKey"
>;
export function shortcutKey(event: KeyEvent) {
  return event.code.startsWith("Key")
    ? event.code.slice(3)
    : event.code.startsWith("Digit")
      ? event.code.slice(5)
      : event.code || event.key;
}
export function matchesShortcut(event: KeyEvent, chord: string) {
  const parts = chord.toLowerCase().split("+");
  if (!chord) return false;
  return (
    parts.includes("super") === event.metaKey &&
    parts.includes("control") === event.ctrlKey &&
    parts.includes("alt") === event.altKey &&
    parts.includes("shift") === event.shiftKey &&
    parts.at(-1) === shortcutKey(event).toLowerCase()
  );
}
