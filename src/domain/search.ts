import type { Action } from "./types";
export const normalize = (s: string) =>
  s.normalize("NFKD").replace(/\p{M}/gu, "").toLocaleLowerCase();
export const nameKey = (s: string) => s.trim().normalize("NFKC").toLowerCase();
function match(query: string, field: string): number {
  if (query.length > field.length) return Infinity;
  if (field === query) return 0;
  if (field.startsWith(query)) return 1;
  if (field.split(/\s+/).some((w) => w.startsWith(query))) return 2;
  if (field.includes(query)) return 3;
  const chars = [...query];
  let p = 0;
  for (const c of field) if (c === chars[p]) p++;
  return p === chars.length ? 4 : Infinity;
}
export function searchActions(
  actions: Action[],
  query: string,
  enabledOnly = true,
): Action[] {
  const q = normalize(query.trim());
  const tokens = q.split(/\s+/);
  const scored = actions
    .filter((a) => !enabledOnly || a.enabled)
    .map((action) => {
      if (!q) return { action, tier: 0, weight: 0 };
      if (normalize(action.name) === q) return { action, tier: -1, weight: 0 };
      const fields = [
        { value: action.name, weight: 0 },
        ...action.aliases.map((value) => ({ value, weight: 1 })),
        ...action.tags.map((value) => ({ value, weight: 2 })),
        { value: action.category || "", weight: 3 },
      ];
      let tier = 0,
        weight = 0;
      for (const token of tokens) {
        let best = Infinity;
        for (const f of fields)
          best = Math.min(
            best,
            match(token, normalize(f.value)) * 10 + f.weight,
          );
        tier = Math.max(tier, Math.floor(best / 10));
        weight += best % 10;
      }
      return { action, tier, weight };
    })
    .filter((x) => Number.isFinite(x.tier));
  return scored
    .sort(
      (a, b) =>
        a.tier - b.tier ||
        a.weight - b.weight ||
        Number(b.action.favorite) - Number(a.action.favorite) ||
        (b.action.lastUsedAt || "").localeCompare(a.action.lastUsedAt || "") ||
        normalize(a.action.name).localeCompare(normalize(b.action.name)) ||
        a.action.id.localeCompare(b.action.id),
    )
    .map((x) => x.action);
}
