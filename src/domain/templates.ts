export const bytes = (text: string) => new TextEncoder().encode(text).length;
function parseTemplate(
  template: string,
  clipboard: string,
  instant = new Date(),
  onClipboard?: () => void,
): string {
  let output = "";
  let i = 0;
  const values: Record<string, string> = {
    clipboard,
    date: `${instant.getFullYear()}-${String(instant.getMonth() + 1).padStart(2, "0")}-${String(instant.getDate()).padStart(2, "0")}`,
    time: `${String(instant.getHours()).padStart(2, "0")}:${String(instant.getMinutes()).padStart(2, "0")}`,
  };
  while (i < template.length) {
    if (template[i] === "\\") {
      let end = i;
      while (template[end] === "\\") end++;
      if (
        ["{{clipboard}}", "{{date}}", "{{time}}"].some((token) =>
          template.startsWith(token, end),
        )
      ) {
        output += "\\".repeat(Math.floor((end - i) / 2));
        if ((end - i) % 2) {
          output += "{{";
          i = end + 2;
          continue;
        }
        i = end;
      } else {
        output += template.slice(i, end);
        i = end;
        continue;
      }
    }
    if (template.slice(i, i + 2) === "{{") {
      const end = template.indexOf("}}", i + 2);
      if (end < 0) {
        output += template.slice(i);
        break;
      }
      const key = template.slice(i + 2, end);
      if (Object.hasOwn(values, key)) {
        if (key === "clipboard") onClipboard?.();
        output += values[key];
      } else {
        output += template.slice(i, end + 2);
      }
      i = end + 2;
    } else {
      output += template[i];
      i++;
    }
  }
  validateText(output, 1048576, true);
  return output;
}
export function renderTemplate(
  template: string,
  clipboard: string,
  instant = new Date(),
): string {
  return parseTemplate(template, clipboard, instant);
}
export function needsClipboard(template: string): boolean {
  let used = false;
  parseTemplate(template, "sample", new Date(), () => {
    used = true;
  });
  return used;
}
export function validateText(text: string, limit = 65536, allowBlank = false) {
  if (!allowBlank && !text.trim()) throw new Error("Text cannot be empty.");
  if (bytes(text) > limit)
    throw new Error(
      `Text is too large (${bytes(text).toLocaleString()} bytes). Maximum: ${limit.toLocaleString()} bytes.`,
    );
  const invalid = /[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/.exec(text);
  if (invalid)
    throw new Error(
      `Invalid control character at position ${[...text.slice(0, invalid.index)].length + 1}.`,
    );
}
