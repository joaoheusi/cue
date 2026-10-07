use chrono::Local;
use serde::{Deserialize, Serialize};
use unicode_normalization::UnicodeNormalization;

#[derive(Debug, Clone, Serialize)]
pub struct Error {
    pub code: String,
    pub message: String,
}
pub type Result<T> = std::result::Result<T, Error>;
pub fn error(code: &str, message: &str) -> Error {
    Error {
        code: code.into(),
        message: message.into(),
    }
}
pub fn storage(_: impl std::fmt::Display) -> Error {
    error(
        "STORAGE_FAILURE",
        "Could not save or read local data. Your existing library has not been reset.",
    )
}
pub fn key(s: &str) -> String {
    s.trim().nfkc().flat_map(char::to_lowercase).collect()
}
pub fn now() -> String {
    chrono::Utc::now().to_rfc3339()
}
#[derive(Clone, Serialize, Deserialize, Debug)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Action {
    pub id: String,
    pub name: String,
    pub description: String,
    pub template: String,
    pub aliases: Vec<String>,
    pub tags: Vec<String>,
    pub category: Option<String>,
    pub delivery_mode: String,
    pub favorite: bool,
    pub enabled: bool,
    pub revision: i64,
    pub use_count: i64,
    pub last_used_at: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ExportAction {
    pub id: String,
    pub name: String,
    pub description: String,
    pub template: String,
    pub aliases: Vec<String>,
    pub tags: Vec<String>,
    pub category: Option<String>,
    pub delivery_mode: String,
    pub favorite: bool,
    pub enabled: bool,
}
impl From<Action> for ExportAction {
    fn from(a: Action) -> Self {
        Self {
            id: a.id,
            name: a.name,
            description: a.description,
            template: a.template,
            aliases: a.aliases,
            tags: a.tags,
            category: a.category,
            delivery_mode: a.delivery_mode,
            favorite: a.favorite,
            enabled: a.enabled,
        }
    }
}
impl ExportAction {
    pub fn into_action(self) -> Action {
        Action {
            id: self.id,
            name: self.name,
            description: self.description,
            template: self.template,
            aliases: self.aliases,
            tags: self.tags,
            category: self.category,
            delivery_mode: self.delivery_mode,
            favorite: self.favorite,
            enabled: self.enabled,
            revision: 0,
            use_count: 0,
            last_used_at: None,
            created_at: now(),
            updated_at: now(),
        }
    }
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Settings {
    pub theme: String,
    pub default_delivery: String,
    pub onboarded: bool,
    pub palette_shortcut: String,
    pub launch_at_login: bool,
    pub keep_running: bool,
    pub preview: bool,
}
impl Default for Settings {
    fn default() -> Self {
        Self {
            theme: "system".into(),
            default_delivery: "paste".into(),
            onboarded: false,
            palette_shortcut: if cfg!(target_os = "macos") {
                "Super+Shift+Space"
            } else {
                "Control+Shift+Space"
            }
            .into(),
            launch_at_login: false,
            keep_running: true,
            preview: false,
        }
    }
}
#[derive(Clone, Serialize, Deserialize)]
pub struct Export {
    #[serde(rename = "schemaVersion")]
    pub schema_version: u32,
    #[serde(rename = "exportedAt")]
    pub exported_at: String,
    pub actions: Vec<ExportAction>,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ShortcutStatus {
    pub owner: String,
    pub requested: String,
    pub active: Option<String>,
    pub error: Option<String>,
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub actions: Vec<Action>,
    pub categories: Vec<String>,
    pub settings: Settings,
    pub revision: i64,
    pub shortcuts: Vec<ShortcutStatus>,
}
fn limit(value: &str, max: usize, required: bool, field: &str) -> Result<()> {
    if value.chars().count() > max || (required && value.trim().is_empty()) {
        return Err(error(
            "VALIDATION",
            &format!(
                "{field} must contain {}–{max} characters.",
                if required { 1 } else { 0 }
            ),
        ));
    }
    Ok(())
}
pub fn validate_text(text: &str, max: usize) -> Result<()> {
    if text.len() > max {
        return Err(error(
            "OUTPUT_TOO_LARGE",
            "Text is too large. Reduce it before trying again.",
        ));
    }
    if let Some((i, _)) = text
        .chars()
        .enumerate()
        .find(|(_, c)| (*c < ' ' && !matches!(c, '\n' | '\r' | '\t')) || *c == '\u{7f}')
    {
        return Err(error(
            "TEMPLATE_INVALID",
            &format!("Invalid control character at position {}.", i + 1),
        ));
    }
    Ok(())
}
pub fn render(template: &str, clipboard: &str, date: &str, time: &str) -> Result<String> {
    render_inner(template, clipboard, date, time, &mut false)
}
fn render_inner(
    template: &str,
    clipboard: &str,
    date: &str,
    time: &str,
    clipboard_used: &mut bool,
) -> Result<String> {
    let chars: Vec<char> = template.chars().collect();
    let mut out = String::new();
    let mut i = 0;
    while i < chars.len() {
        if chars[i] == '\\' {
            let start = i;
            while i < chars.len() && chars[i] == '\\' {
                i += 1;
            }
            let count = i - start;
            if ["{{clipboard}}", "{{date}}", "{{time}}"]
                .iter()
                .any(|token| {
                    chars
                        .get(i..i + token.len())
                        .is_some_and(|slice| slice.iter().copied().eq(token.chars()))
                })
            {
                out.push_str(&"\\".repeat(count / 2));
                if count % 2 == 1 {
                    out.push_str("{{");
                    i += 2;
                    continue;
                }
            } else {
                out.push_str(&"\\".repeat(count));
                continue;
            }
        }
        if chars.get(i) == Some(&'{') && chars.get(i + 1) == Some(&'{') {
            let mut end = i + 2;
            while end + 1 < chars.len() && !(chars[end] == '}' && chars[end + 1] == '}') {
                end += 1;
            }
            if end + 1 >= chars.len() {
                out.extend(chars[i..].iter());
                break;
            }
            let token: String = chars[i + 2..end].iter().collect();
            let value = match token.as_str() {
                "clipboard" => {
                    *clipboard_used = true;
                    clipboard
                }
                "date" => date,
                "time" => time,
                _ => {
                    out.extend(chars[i..end + 2].iter());
                    i = end + 2;
                    continue;
                }
            };
            if out.len() + value.len() > 1_048_576 {
                return Err(error("OUTPUT_TOO_LARGE", "Rendered text exceeds 1 MiB."));
            }
            out.push_str(value);
            i = end + 2;
        } else {
            out.push(chars[i]);
            i += 1;
        }
    }
    validate_text(&out, 1_048_576)?;
    Ok(out)
}
pub fn render_local(template: &str, clipboard: &str) -> Result<String> {
    let instant = Local::now();
    render(
        template,
        clipboard,
        &instant.format("%Y-%m-%d").to_string(),
        &instant.format("%H:%M").to_string(),
    )
}
pub fn needs_clipboard(template: &str) -> Result<bool> {
    let mut used = false;
    render_inner(template, "sample", "2000-01-01", "00:00", &mut used)?;
    Ok(used)
}
pub fn validate(a: &mut Action) -> Result<()> {
    uuid::Uuid::parse_str(&a.id).map_err(|_| error("VALIDATION", "Action ID is invalid."))?;
    a.name = a.name.trim().into();
    limit(&a.name, 100, true, "Name")?;
    limit(&a.description, 300, false, "Description")?;
    a.template = a.template.replace("\r\n", "\n").replace('\r', "\n");
    if a.template.trim().is_empty() {
        return Err(error("TEMPLATE_INVALID", "Text cannot be empty."));
    }
    validate_text(&a.template, 65_536)?;
    render_local(&a.template, "sample clipboard")?;
    if !["inherit", "copy", "paste"].contains(&a.delivery_mode.as_str()) {
        return Err(error(
            "VALIDATION",
            "Delivery must be inherit, copy, or paste.",
        ));
    }
    for (items, max, field) in [(&mut a.aliases, 50, "Alias"), (&mut a.tags, 30, "Tag")] {
        if items.len() > 10 {
            return Err(error(
                "VALIDATION",
                "At most 10 tags or aliases are allowed.",
            ));
        }
        let mut seen = std::collections::HashSet::new();
        let mut normalized = vec![];
        for item in items.drain(..) {
            let item = item.trim().to_string();
            limit(&item, max, true, field)?;
            if seen.insert(key(&item)) {
                normalized.push(item);
            }
        }
        *items = normalized;
    }
    if let Some(c) = &mut a.category {
        *c = c.trim().into();
        limit(c, 50, true, "Category")?;
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn one_pass() {
        assert_eq!(
            render(
                "{{clipboard}} {{date}} {{time}}",
                "{{date}}",
                "2026-10-06",
                "13:05"
            )
            .unwrap(),
            "{{date}} 2026-10-06 13:05"
        );
    }
    #[test]
    fn escaping() {
        assert_eq!(
            render(r"\{{date}} \\{{date}} \\\{{date}}", "x", "DATE", "TIME").unwrap(),
            r"{{date}} \DATE \{{date}}"
        );
    }
    #[test]
    fn invalid() {
        for s in ["hello\u{1b}", "\0"] {
            assert!(render(s, "x", "date", "time").is_err());
        }
        assert_eq!(
            render(r#"{"ok":true}"#, "x", "d", "t").unwrap(),
            r#"{"ok":true}"#
        );
    }
    #[test]
    fn literal_placeholders() {
        let cases: Vec<String> = serde_json::from_str(include_str!(
            "../../tests/fixtures/literal-placeholders.json"
        ))
        .unwrap();
        for template in cases {
            assert_eq!(
                render(&template, "clipboard text", "DATE", "TIME").unwrap(),
                template
            );
            assert!(!needs_clipboard(&template).unwrap());
        }
        assert_eq!(
            render(
                "@{{upstream}} {{clipboard}} {{date}} {{time}}",
                "text",
                "DATE",
                "TIME"
            )
            .unwrap(),
            "@{{upstream}} text DATE TIME"
        );
    }
    #[test]
    fn clipboard_token() {
        assert!(needs_clipboard("{{clipboard}}").unwrap());
        assert!(!needs_clipboard(r"\{{clipboard}}").unwrap());
        assert!(!needs_clipboard("\u{e000}").unwrap());
        assert_eq!(
            render("{{clipboard}}", " \r\n ", "d", "t").unwrap(),
            " \r\n "
        );
    }
    #[test]
    fn output_limit() {
        assert!(render("{{clipboard}}{{clipboard}}", &"x".repeat(600_000), "d", "t").is_err());
    }
}
