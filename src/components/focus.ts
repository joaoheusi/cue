import type { KeyboardEvent } from "react";
export function containTab(event: KeyboardEvent<Element>) {
  if (event.key !== "Tab") return;
  const nodes = [
    ...event.currentTarget.querySelectorAll<HTMLElement>(
      'button:not(:disabled),input:not(:disabled),textarea:not(:disabled),select:not(:disabled),[tabindex="0"]',
    ),
  ].filter((node) => node.getClientRects().length > 0);
  const first = nodes[0],
    last = nodes.at(-1);
  if (event.shiftKey && document.activeElement === first) {
    event.preventDefault();
    last?.focus();
  }
  if (!event.shiftKey && document.activeElement === last) {
    event.preventDefault();
    first?.focus();
  }
}
