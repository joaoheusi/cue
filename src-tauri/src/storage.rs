use crate::domain::*;
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use std::{
    path::PathBuf,
    sync::mpsc,
    time::{Duration, Instant},
};
use tokio::sync::oneshot;
type Job = Box<dyn FnOnce(&mut Database) + Send>;
#[derive(Clone)]
pub struct Store(mpsc::Sender<Job>, Option<Error>);
impl Store {
    pub fn unavailable(reason: Error) -> Self {
        let (sender, _) = mpsc::channel();
        Self(sender, Some(reason))
    }
    pub fn start(path: PathBuf) -> Result<Self> {
        let (tx, rx) = mpsc::channel::<Job>();
        let (init_tx, init_rx) = mpsc::sync_channel(1);
        std::thread::spawn(move || match Database::open(path) {
            Ok(mut db) => {
                let _ = init_tx.send(Ok(()));
                for job in rx {
                    job(&mut db);
                }
            }
            Err(e) => {
                let _ = init_tx.send(Err(e));
            }
        });
        init_rx.recv().map_err(storage)??;
        Ok(Self(tx, None))
    }
    pub async fn call<T: Send + 'static>(
        &self,
        f: impl FnOnce(&mut Database) -> Result<T> + Send + 'static,
    ) -> Result<T> {
        if let Some(reason) = &self.1 {
            return Err(reason.clone());
        }
        let (tx, rx) = oneshot::channel();
        self.0
            .send(Box::new(move |db| {
                let _ = tx.send(f(db));
            }))
            .map_err(storage)?;
        rx.await.map_err(storage)?
    }
}
pub struct PendingImport {
    pub token: String,
    pub revision: i64,
    pub created: Instant,
    pub actions: Vec<ExportAction>,
}
pub struct Database {
    pub conn: Connection,
    pub dir: PathBuf,
    pub pending: Option<PendingImport>,
}
impl Database {
    pub fn open(path: PathBuf) -> Result<Self> {
        std::fs::create_dir_all(&path).map_err(storage)?;
        let conn = Connection::open(path.join("cue.sqlite3")).map_err(storage)?;
        conn.pragma_update(None, "foreign_keys", true)
            .map_err(storage)?;
        conn.busy_timeout(Duration::from_secs(3)).map_err(storage)?;
        let version: i64 = conn
            .pragma_query_value(None, "user_version", |r| r.get(0))
            .map_err(storage)?;
        if version > 2 {
            return Err(error(
                "STORAGE_FAILURE",
                "This library was created by a newer Cue. Update Cue to open it.",
            ));
        }
        let mut db = Self {
            conn,
            dir: path,
            pending: None,
        };
        if version == 0 {
            if db
                .conn
                .query_row(
                    "SELECT COUNT(*) FROM sqlite_master WHERE type='table'",
                    [],
                    |r| r.get::<_, i64>(0),
                )
                .map_err(storage)?
                > 0
            {
                db.backup()?;
            }
            let tx = db.conn.transaction().map_err(storage)?;
            tx.execute_batch(include_str!("../migrations/001-initial.sql"))
                .map_err(storage)?;
            tx.execute(
                "INSERT INTO settings VALUES(1,?1)",
                [serde_json::to_string(&Settings::default()).map_err(storage)?],
            )
            .map_err(storage)?;
            tx.commit().map_err(storage)?;
        }
        if version < 2 {
            if version == 1 {
                db.backup()?;
            }
            let tx = db.conn.transaction().map_err(storage)?;
            tx.execute_batch("UPDATE settings SET data=json_set(data, '$.defaultDelivery', 'paste', '$.keepRunning', json('true'));
INSERT INTO schema_migrations VALUES(2, strftime('%Y-%m-%dT%H:%M:%SZ','now'));
PRAGMA user_version=2;").map_err(storage)?;
            tx.commit().map_err(storage)?;
        }
        db.conn
            .pragma_update(None, "journal_mode", "WAL")
            .map_err(storage)?;
        Ok(db)
    }
    pub fn backup(&self) -> Result<()> {
        let dir = self.dir.join("backups");
        std::fs::create_dir_all(&dir).map_err(storage)?;
        let path = dir.join(format!(
            "cue-{}-{}.sqlite3",
            chrono::Utc::now().format("%Y%m%dT%H%M%S%.9f"),
            uuid::Uuid::new_v4()
        ));
        if let Err(reason) = self.conn.backup(rusqlite::MAIN_DB, &path, None) {
            let _ = std::fs::remove_file(&path);
            return Err(storage(reason));
        }
        let mut entries: Vec<_> = std::fs::read_dir(&dir)
            .map_err(storage)?
            .filter_map(|e| e.ok())
            .filter(|e| e.path().extension().is_some_and(|x| x == "sqlite3"))
            .collect();
        entries.sort_by_key(|e| e.file_name());
        let remove = entries.len().saturating_sub(5);
        for e in entries.into_iter().take(remove) {
            std::fs::remove_file(e.path()).map_err(storage)?;
        }
        Ok(())
    }
    pub fn revision(&self) -> Result<i64> {
        self.conn
            .query_row("SELECT revision FROM library_state WHERE id=1", [], |r| {
                r.get(0)
            })
            .map_err(storage)
    }
    pub fn get(&self, id: &str) -> Result<Action> {
        let value: Option<String> = self
            .conn
            .query_row("SELECT data FROM actions WHERE id=?1", [id], |r| r.get(0))
            .optional()
            .map_err(storage)?;
        serde_json::from_str(
            &value.ok_or_else(|| error("NOT_FOUND", "This action no longer exists."))?,
        )
        .map_err(storage)
    }
    pub fn settings(&self) -> Result<Settings> {
        let s: String = self
            .conn
            .query_row("SELECT data FROM settings WHERE id=1", [], |r| r.get(0))
            .map_err(storage)?;
        serde_json::from_str(&s).map_err(storage)
    }
    pub fn snapshot(&self) -> Result<Snapshot> {
        let mut stmt = self
            .conn
            .prepare("SELECT data FROM actions ORDER BY id")
            .map_err(storage)?;
        let actions = stmt
            .query_map([], |r| r.get::<_, String>(0))
            .map_err(storage)?
            .map(|r| serde_json::from_str(&r.map_err(storage)?).map_err(storage))
            .collect::<Result<Vec<Action>>>()?;
        let categories = self
            .conn
            .prepare("SELECT name FROM categories ORDER BY normalized")
            .map_err(storage)?
            .query_map([], |r| r.get(0))
            .map_err(storage)?
            .collect::<std::result::Result<Vec<String>, _>>()
            .map_err(storage)?;
        Ok(Snapshot {
            actions,
            categories,
            settings: self.settings()?,
            revision: self.revision()?,
            shortcuts: self
                .bindings()?
                .into_iter()
                .map(|(owner, requested)| ShortcutStatus {
                    owner,
                    requested,
                    active: None,
                    error: None,
                })
                .collect(),
        })
    }
    pub fn bindings(&self) -> Result<Vec<(String, String)>> {
        self.conn
            .prepare("SELECT owner,accelerator FROM shortcuts")
            .map_err(storage)?
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
            .map_err(storage)?
            .collect::<std::result::Result<Vec<_>, _>>()
            .map_err(storage)
    }
    pub fn save_binding(&self, owner: &str, chord: &str) -> Result<()> {
        if chord.is_empty() {
            self.conn
                .execute("DELETE FROM shortcuts WHERE owner=?1", [owner])
                .map_err(storage)?;
        } else {
            self.conn.execute("INSERT INTO shortcuts VALUES(?1,?2) ON CONFLICT(owner) DO UPDATE SET accelerator=excluded.accelerator",params![owner,chord]).map_err(storage)?;
        }
        Ok(())
    }
    pub fn save(&mut self, mut a: Action) -> Result<Action> {
        validate(&mut a)?;
        let existing = self
            .conn
            .query_row("SELECT revision FROM actions WHERE id=?1", [&a.id], |r| {
                r.get::<_, i64>(0)
            })
            .optional()
            .map_err(storage)?;
        if existing
            != if a.revision == 0 {
                None
            } else {
                Some(a.revision)
            }
        {
            return Err(error(
                "REVISION_CONFLICT",
                "This action changed in another window. Reload before saving.",
            ));
        }
        if existing.is_none() && self.snapshot()?.actions.len() >= 5000 {
            return Err(error(
                "VALIDATION",
                "The library is limited to 5,000 actions.",
            ));
        }
        if existing.is_some() {
            let old = self.get(&a.id)?;
            a.use_count = old.use_count;
            a.last_used_at = old.last_used_at;
            a.created_at = old.created_at;
        } else {
            a.use_count = 0;
            a.last_used_at = None;
            a.created_at = now();
        }
        a.revision += 1;
        a.updated_at = now();
        let tx = self.conn.transaction().map_err(storage)?;
        if let Some(c) = &a.category {
            let normalized = key(c);
            let canonical: Option<String> = tx
                .query_row(
                    "SELECT name FROM categories WHERE normalized=?1",
                    [&normalized],
                    |r| r.get(0),
                )
                .optional()
                .map_err(storage)?;
            if let Some(c) = canonical {
                a.category = Some(c);
            } else {
                tx.execute(
                    "INSERT INTO categories VALUES(?1,?2)",
                    params![c, normalized],
                )
                .map_err(storage)?;
            }
        }
        tx.execute("INSERT INTO actions VALUES(?1,?2,?3) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,data=excluded.data",params![a.id,a.revision,serde_json::to_string(&a).map_err(storage)?]).map_err(storage)?;
        tx.execute("UPDATE library_state SET revision=revision+1", [])
            .map_err(storage)?;
        tx.commit().map_err(storage)?;
        Ok(a)
    }
    pub fn usage(&mut self, id: &str) -> Result<()> {
        let mut a = self.get(id)?;
        a.use_count += 1;
        a.last_used_at = Some(now());
        let tx = self.conn.transaction().map_err(storage)?;
        tx.execute(
            "UPDATE actions SET data=?1 WHERE id=?2",
            params![serde_json::to_string(&a).map_err(storage)?, id],
        )
        .map_err(storage)?;
        tx.execute("UPDATE library_state SET revision=revision+1", [])
            .map_err(storage)?;
        tx.commit().map_err(storage)?;
        Ok(())
    }
    pub fn handle(&mut self, op: &str, args: Value) -> Result<Value> {
        match op {
            "onboard" => {
                if self.settings()?.onboarded {
                    return Ok(Value::Null);
                }
                if args["revision"].as_i64() != Some(self.revision()?) {
                    return Err(error(
                        "REVISION_CONFLICT",
                        "The library changed. Try setup again.",
                    ));
                }
                let mut actions: Vec<Action> = serde_json::from_value(args["actions"].clone())
                    .map_err(|_| error("VALIDATION", "Invalid starter actions."))?;
                let mut settings: Settings = serde_json::from_value(args["settings"].clone())
                    .map_err(|_| error("VALIDATION", "Invalid setup settings."))?;
                if !["system", "light", "dark"].contains(&settings.theme.as_str()) {
                    return Err(error("VALIDATION", "Invalid theme."));
                }
                settings.onboarded = true;
                settings.default_delivery = "paste".into();
                settings.launch_at_login = false;
                settings.keep_running = true;
                if self.snapshot()?.actions.len() + actions.len() > 5000 {
                    return Err(error(
                        "VALIDATION",
                        "The library is limited to 5,000 actions.",
                    ));
                }
                for action in &mut actions {
                    validate(action)?;
                }
                let tx = self.conn.transaction().map_err(storage)?;
                for mut a in actions {
                    a.revision = 1;
                    a.use_count = 0;
                    a.last_used_at = None;
                    a.created_at = now();
                    a.updated_at = a.created_at.clone();
                    if let Some(c) = &a.category {
                        tx.execute(
                            "INSERT OR IGNORE INTO categories VALUES(?1,?2)",
                            params![c, key(c)],
                        )
                        .map_err(storage)?;
                    }
                    tx.execute(
                        "INSERT INTO actions VALUES(?1,?2,?3)",
                        params![
                            a.id,
                            a.revision,
                            serde_json::to_string(&a).map_err(storage)?
                        ],
                    )
                    .map_err(storage)?;
                }
                tx.execute(
                    "UPDATE settings SET data=?1 WHERE id=1",
                    [serde_json::to_string(&settings).map_err(storage)?],
                )
                .map_err(storage)?;
                tx.execute("UPDATE library_state SET revision=revision+1", [])
                    .map_err(storage)?;
                tx.commit().map_err(storage)?;
                Ok(Value::Null)
            }
            "snapshot" => serde_json::to_value(self.snapshot()?).map_err(storage),
            "save" => {
                let a: Action = serde_json::from_value(args)
                    .map_err(|_| error("VALIDATION", "Invalid action fields."))?;
                Ok(serde_json::to_value(self.save(a)?).map_err(storage)?)
            }
            "duplicate" => {
                let mut a = self.get(args["id"].as_str().unwrap_or(""))?;
                check_revision(&a, &args)?;
                a.id = uuid::Uuid::new_v4().to_string();
                a.name = format!("{} copy", a.name.chars().take(95).collect::<String>());
                a.revision = 0;
                Ok(serde_json::to_value(self.save(a)?).map_err(storage)?)
            }
            "delete" => {
                let a = self.get(args["id"].as_str().unwrap_or(""))?;
                check_revision(&a, &args)?;
                let tx = self.conn.transaction().map_err(storage)?;
                tx.execute(
                    "DELETE FROM shortcuts WHERE owner=?1",
                    [format!("action:{}", a.id)],
                )
                .map_err(storage)?;
                tx.execute("DELETE FROM actions WHERE id=?1", [a.id])
                    .map_err(storage)?;
                tx.execute("UPDATE library_state SET revision=revision+1", [])
                    .map_err(storage)?;
                tx.commit().map_err(storage)?;
                Ok(Value::Null)
            }
            "settings" => {
                if args["revision"].as_i64() != Some(self.revision()?) {
                    return Err(error(
                        "REVISION_CONFLICT",
                        "Settings changed. Reload and try again.",
                    ));
                }
                let s: Settings = serde_json::from_value(args["settings"].clone())
                    .map_err(|_| error("VALIDATION", "Invalid settings."))?;
                if !["dark", "light", "system"].contains(&s.theme.as_str())
                    || !["copy", "paste"].contains(&s.default_delivery.as_str())
                {
                    return Err(error("VALIDATION", "Invalid theme or delivery setting."));
                }
                let tx = self.conn.transaction().map_err(storage)?;
                tx.execute(
                    "UPDATE settings SET data=?1 WHERE id=1",
                    [serde_json::to_string(&s).map_err(storage)?],
                )
                .map_err(storage)?;
                tx.execute("UPDATE library_state SET revision=revision+1", [])
                    .map_err(storage)?;
                tx.commit().map_err(storage)?;
                Ok(Value::Null)
            }
            "category" => {
                let name = args["name"].as_str().unwrap_or("").trim();
                limit_category(name)?;
                if args["revision"].as_i64() != Some(self.revision()?) {
                    return Err(error(
                        "REVISION_CONFLICT",
                        "The library changed. Reload and try again.",
                    ));
                }
                let old = args["old"].as_str();
                let records = self.snapshot()?.actions;
                let tx = self.conn.transaction().map_err(storage)?;
                if let Some(old) = old {
                    tx.execute("DELETE FROM categories WHERE normalized=?1", [key(old)])
                        .map_err(storage)?;
                    for mut a in records
                        .into_iter()
                        .filter(|a| a.category.as_deref() == Some(old))
                    {
                        a.category = if name.is_empty() {
                            None
                        } else {
                            Some(name.into())
                        };
                        a.revision += 1;
                        a.updated_at = now();
                        tx.execute(
                            "UPDATE actions SET revision=?1,data=?2 WHERE id=?3",
                            params![
                                a.revision,
                                serde_json::to_string(&a).map_err(storage)?,
                                a.id
                            ],
                        )
                        .map_err(storage)?;
                    }
                }
                if !name.is_empty() {
                    tx.execute(
                        "INSERT INTO categories VALUES(?1,?2)",
                        params![name, key(name)],
                    )
                    .map_err(|_| {
                        error("VALIDATION", "A category with this name already exists.")
                    })?;
                }
                tx.execute("UPDATE library_state SET revision=revision+1", [])
                    .map_err(storage)?;
                tx.commit().map_err(storage)?;
                Ok(Value::Null)
            }
            "clear_usage" => {
                let actions = self.snapshot()?.actions;
                let tx = self.conn.transaction().map_err(storage)?;
                for mut a in actions {
                    a.use_count = 0;
                    a.last_used_at = None;
                    tx.execute(
                        "UPDATE actions SET data=?1 WHERE id=?2",
                        params![serde_json::to_string(&a).map_err(storage)?, a.id],
                    )
                    .map_err(storage)?;
                }
                tx.execute("UPDATE library_state SET revision=revision+1", [])
                    .map_err(storage)?;
                tx.commit().map_err(storage)?;
                Ok(Value::Null)
            }
            _ => Err(error("VALIDATION", "Unknown library operation.")),
        }
    }
    pub fn preview(&mut self, text: &str) -> Result<Value> {
        if text.len() > 10 * 1024 * 1024 {
            return Err(error(
                "OUTPUT_TOO_LARGE",
                "Import files must be smaller than 10 MiB.",
            ));
        }
        let raw: Value = serde_json::from_str(text)
            .map_err(|_| error("VALIDATION", "The file is not valid UTF-8 JSON."))?;
        if raw.as_object().is_none_or(|o| {
            o.len() != 3
                || !o.contains_key("schemaVersion")
                || !o.contains_key("exportedAt")
                || !o.contains_key("actions")
        }) {
            return Err(error("VALIDATION", "Import contains unsupported fields."));
        }
        let export: Export = serde_json::from_value(raw)
            .map_err(|_| error("VALIDATION", "Import fields do not match schema version 1."))?;
        if export.schema_version != 1
            || chrono::DateTime::parse_from_rfc3339(&export.exported_at).is_err()
        {
            return Err(error(
                "VALIDATION",
                "Unsupported schema or invalid export timestamp.",
            ));
        }
        let mut ids = std::collections::HashSet::new();
        for a in &export.actions {
            if !ids.insert(&a.id) {
                return Err(error("VALIDATION", "Import contains duplicate IDs."));
            }
            let mut a = a.clone().into_action();
            validate(&mut a)?;
        }
        let snapshot = self.snapshot()?;
        if snapshot.actions.len() + export.actions.len() > 5000 {
            return Err(error(
                "VALIDATION",
                "Import would exceed the 5,000-action limit.",
            ));
        }
        let token = uuid::Uuid::new_v4().to_string();
        let duplicate_ids = export
            .actions
            .iter()
            .filter(|a| snapshot.actions.iter().any(|b| b.id == a.id))
            .count();
        let duplicate_names = export
            .actions
            .iter()
            .filter(|a| {
                snapshot
                    .actions
                    .iter()
                    .any(|b| key(&b.name) == key(&a.name))
            })
            .count();
        let mut categories = std::collections::BTreeMap::new();
        for c in export.actions.iter().filter_map(|a| a.category.as_ref()) {
            if !snapshot.categories.iter().any(|b| key(b) == key(c)) {
                categories.entry(key(c)).or_insert(c);
            }
        }
        let result = json!({"token":token,"revision":snapshot.revision,"actions":export.actions,"duplicateIds":duplicate_ids,"duplicateNames":duplicate_names,"newCategories":categories.into_values().collect::<Vec<_>>()});
        self.pending = Some(PendingImport {
            token,
            revision: snapshot.revision,
            created: Instant::now(),
            actions: export.actions,
        });
        Ok(result)
    }
    pub fn commit_import(&mut self, token: &str, update: bool) -> Result<()> {
        let p = self.pending.take().ok_or_else(|| {
            error(
                "REVISION_CONFLICT",
                "Import preview expired. Choose the file again.",
            )
        })?;
        if p.token != token
            || p.created.elapsed() > Duration::from_secs(300)
            || p.revision != self.revision()?
        {
            return Err(error(
                "REVISION_CONFLICT",
                "Library changed or preview expired. Choose the file again.",
            ));
        }
        self.backup()?;
        let existing = self.snapshot()?.actions;
        let tx = self.conn.transaction().map_err(storage)?;
        for a in p.actions {
            let mut a = a.into_action();
            validate(&mut a)?;
            let old = existing.iter().find(|b| b.id == a.id);
            if let Some(old) = old.filter(|_| update) {
                a.revision = old.revision + 1;
                a.created_at = old.created_at.clone();
                a.use_count = old.use_count;
                a.last_used_at = old.last_used_at.clone();
                tx.execute(
                    "DELETE FROM shortcuts WHERE owner=?1",
                    [format!("action:{}", a.id)],
                )
                .map_err(storage)?;
            } else {
                a.id = uuid::Uuid::new_v4().to_string();
                a.revision = 1;
            }
            a.delivery_mode = "copy".into();
            if let Some(c) = &a.category {
                let normalized = key(c);
                let canonical: Option<String> = tx
                    .query_row(
                        "SELECT name FROM categories WHERE normalized=?1",
                        [&normalized],
                        |r| r.get(0),
                    )
                    .optional()
                    .map_err(storage)?;
                if let Some(c) = canonical {
                    a.category = Some(c);
                } else {
                    tx.execute(
                        "INSERT INTO categories VALUES(?1,?2)",
                        params![c, normalized],
                    )
                    .map_err(storage)?;
                }
            }
            tx.execute("INSERT INTO actions VALUES(?1,?2,?3) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,data=excluded.data",params![a.id,a.revision,serde_json::to_string(&a).map_err(storage)?]).map_err(storage)?;
        }
        tx.execute("UPDATE library_state SET revision=revision+1", [])
            .map_err(storage)?;
        tx.commit().map_err(storage)?;
        Ok(())
    }
}
fn limit_category(name: &str) -> Result<()> {
    if name.chars().count() > 50 {
        return Err(error(
            "VALIDATION",
            "Category names are limited to 50 characters.",
        ));
    }
    Ok(())
}
pub fn check_revision(a: &Action, args: &Value) -> Result<()> {
    if args["revision"].as_i64() != Some(a.revision) {
        return Err(error(
            "REVISION_CONFLICT",
            "Action changed. Reload before continuing.",
        ));
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    fn action() -> Action {
        ExportAction {
            id: uuid::Uuid::new_v4().to_string(),
            name: "Test".into(),
            description: "".into(),
            template: "Hello {{date}}".into(),
            aliases: vec![],
            tags: vec![],
            category: Some("Coding".into()),
            delivery_mode: "inherit".into(),
            favorite: false,
            enabled: true,
        }
        .into_action()
    }
    #[test]
    fn paste_migration_preserves_actions_and_runs_once() {
        let dir = tempfile::tempdir().unwrap();
        let mut db = Database::open(dir.path().into()).unwrap();
        let mut action = action();
        action.delivery_mode = "copy".into();
        db.handle("save", serde_json::to_value(&action).unwrap())
            .unwrap();
        db.conn.execute_batch("UPDATE settings SET data=json_set(data, '$.defaultDelivery', 'copy', '$.keepRunning', json('false')); DELETE FROM schema_migrations WHERE version=2; PRAGMA user_version=1;").unwrap();
        drop(db);
        let db = Database::open(dir.path().into()).unwrap();
        assert_eq!(db.settings().unwrap().default_delivery, "paste");
        assert!(db.settings().unwrap().keep_running);
        assert_eq!(db.get(&action.id).unwrap().delivery_mode, "copy");
        assert_eq!(db.get(&action.id).unwrap().template, action.template);
        assert_eq!(
            std::fs::read_dir(dir.path().join("backups"))
                .unwrap()
                .count(),
            1
        );
        db.conn
            .execute(
                "UPDATE settings SET data=json_set(data, '$.defaultDelivery', 'copy')",
                [],
            )
            .unwrap();
        drop(db);
        assert_eq!(
            Database::open(dir.path().into())
                .unwrap()
                .settings()
                .unwrap()
                .default_delivery,
            "copy"
        );
    }
    #[test]
    fn persistence_and_revisions() {
        let dir = tempfile::tempdir().unwrap();
        let mut db = Database::open(dir.path().into()).unwrap();
        let a = db.save(action()).unwrap();
        assert_eq!(a.revision, 1);
        assert!(db
            .save(Action {
                revision: 0,
                ..a.clone()
            })
            .is_err());
        drop(db);
        let db = Database::open(dir.path().into()).unwrap();
        assert_eq!(db.get(&a.id).unwrap().template, a.template);
    }
    #[test]
    fn publishing_prompt_round_trip() {
        let dir = tempfile::tempdir().unwrap();
        let mut db = Database::open(dir.path().into()).unwrap();
        let mut a = action();
        a.name = "Create PR or Merge Request".into();
        a.template = include_str!("../../tests/fixtures/publishing-prompt.txt")
            .trim_end_matches('\n')
            .into();
        let saved = db.save(a).unwrap();
        let stored = db.get(&saved.id).unwrap();
        assert_eq!(stored.template, saved.template);
        assert_eq!(
            render_local(&stored.template, "unused clipboard").unwrap(),
            stored.template
        );
        assert!(!needs_clipboard(&stored.template).unwrap());
    }
    #[test]
    fn import_and_backup() {
        let dir = tempfile::tempdir().unwrap();
        let mut db = Database::open(dir.path().into()).unwrap();
        let a = db.save(action()).unwrap();
        let data = serde_json::to_string(&Export {
            schema_version: 1,
            exported_at: now(),
            actions: vec![a.clone().into()],
        })
        .unwrap();
        let p = db.preview(&data).unwrap();
        db.commit_import(p["token"].as_str().unwrap(), false)
            .unwrap();
        let s = db.snapshot().unwrap();
        assert_eq!(s.actions.len(), 2);
        assert_eq!(
            s.actions
                .iter()
                .filter(|a| a.delivery_mode == "copy")
                .count(),
            1
        );
        assert!(dir.path().join("backups").exists());
        let p = db.preview(&data).unwrap();
        db.save(action()).unwrap();
        assert!(db
            .commit_import(p["token"].as_str().unwrap(), true)
            .is_err());
    }
    #[test]
    fn invalid_import_is_atomic() {
        let dir = tempfile::tempdir().unwrap();
        let mut db = Database::open(dir.path().into()).unwrap();
        let a = action();
        let data = serde_json::to_string(&Export {
            schema_version: 1,
            exported_at: now(),
            actions: vec![a.clone().into(), a.into()],
        })
        .unwrap();
        assert!(db.preview(&data).is_err());
        assert!(db.snapshot().unwrap().actions.is_empty());
    }
    #[test]
    fn newer_schema_is_not_reset() {
        let dir = tempfile::tempdir().unwrap();
        let db = Database::open(dir.path().into()).unwrap();
        db.conn.pragma_update(None, "user_version", 99).unwrap();
        drop(db);
        assert!(Database::open(dir.path().into()).is_err());
        let c = Connection::open(dir.path().join("cue.sqlite3")).unwrap();
        assert_eq!(
            c.pragma_query_value(None, "user_version", |r| r.get::<_, i64>(0))
                .unwrap(),
            99
        );
    }
    #[test]
    fn onboarding_is_atomic_and_runs_once() {
        let dir = tempfile::tempdir().unwrap();
        let mut db = Database::open(dir.path().into()).unwrap();
        let mut invalid = action();
        invalid.template = "invalid\0text".into();
        let revision = db.revision().unwrap();
        let settings = Settings::default();
        assert!(db
            .handle(
                "onboard",
                json!({"revision":revision,"settings":settings,"actions":[action(),invalid]})
            )
            .is_err());
        assert!(db.snapshot().unwrap().actions.is_empty());
        assert!(!db.settings().unwrap().onboarded);
        db.handle(
            "onboard",
            json!({"revision":revision,"settings":settings,"actions":[action()]}),
        )
        .unwrap();
        db.handle(
            "onboard",
            json!({"revision":revision,"settings":settings,"actions":[action()]}),
        )
        .unwrap();
        assert_eq!(db.snapshot().unwrap().actions.len(), 1);
    }
    #[test]
    fn backups_retain_five_consistent_databases() {
        let dir = tempfile::tempdir().unwrap();
        let mut db = Database::open(dir.path().into()).unwrap();
        db.save(action()).unwrap();
        for _ in 0..7 {
            db.backup().unwrap();
        }
        let entries: Vec<_> = std::fs::read_dir(dir.path().join("backups"))
            .unwrap()
            .collect();
        assert_eq!(entries.len(), 5);
        for entry in entries {
            let backup = Connection::open(entry.unwrap().path()).unwrap();
            let count: i64 = backup
                .query_row("SELECT COUNT(*) FROM actions", [], |r| r.get(0))
                .unwrap();
            assert_eq!(count, 1);
        }
    }
    #[test]
    fn categories_update_actions_and_reject_stale_edits() {
        let dir = tempfile::tempdir().unwrap();
        let mut db = Database::open(dir.path().into()).unwrap();
        let a = db.save(action()).unwrap();
        let revision = db.revision().unwrap();
        db.handle(
            "category",
            json!({"old":"Coding","name":"Code","revision":revision}),
        )
        .unwrap();
        assert_eq!(db.get(&a.id).unwrap().category.as_deref(), Some("Code"));
        assert!(db.save(a).is_err());
        let revision = db.revision().unwrap();
        db.handle(
            "category",
            json!({"old":"Code","name":"","revision":revision}),
        )
        .unwrap();
        assert!(db.snapshot().unwrap().actions[0].category.is_none());
    }
}
