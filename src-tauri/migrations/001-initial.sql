CREATE TABLE actions(id TEXT PRIMARY KEY, revision INTEGER NOT NULL CHECK(revision>0), data TEXT NOT NULL CHECK(json_valid(data)));
CREATE TABLE categories(name TEXT NOT NULL, normalized TEXT PRIMARY KEY);
CREATE TABLE settings(id INTEGER PRIMARY KEY CHECK(id=1), data TEXT NOT NULL CHECK(json_valid(data)));
CREATE TABLE library_state(id INTEGER PRIMARY KEY CHECK(id=1),revision INTEGER NOT NULL);
INSERT INTO library_state VALUES(1,1);
CREATE TABLE shortcuts(owner TEXT PRIMARY KEY, accelerator TEXT NOT NULL);
CREATE TABLE schema_migrations(version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL);
INSERT INTO schema_migrations VALUES(1, strftime('%Y-%m-%dT%H:%M:%SZ','now'));
PRAGMA user_version=1;
