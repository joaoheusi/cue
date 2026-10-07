mod domain;
mod execution;
mod lifecycle;
mod platform;
mod storage;
use domain::*;
use execution::Engine;
use lifecycle::LaunchIntent;
use serde_json::{json, Value};
use std::{
    collections::{HashMap, HashSet},
    str::FromStr,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
};
use storage::{check_revision, Store};
use tauri::{AppHandle, Emitter, Manager, State, WebviewWindow};
use tauri_plugin_autostart::ManagerExt as AutostartExt;
use tauri_plugin_clipboard_manager::ClipboardExt;
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_global_shortcut::{GlobalShortcutExt, Shortcut, ShortcutState};
struct Runtime {
    store: Store,
    engine: tokio::sync::Mutex<Engine>,
    statuses: Mutex<HashMap<String, ShortcutStatus>>,
    paused: Mutex<bool>,
    pressed: Mutex<HashSet<String>>,
    shortcut_changes: tokio::sync::Mutex<()>,
    tray: bool,
    cancelled: Arc<AtomicBool>,
}
fn library(window: &WebviewWindow) -> Result<()> {
    if window.label() != "library" {
        return Err(error(
            "FORBIDDEN",
            "Only the library can perform this operation.",
        ));
    }
    Ok(())
}
fn surface(window: &WebviewWindow) -> Result<()> {
    if !["palette", "library"].contains(&window.label()) {
        return Err(error("FORBIDDEN", "Unknown application surface."));
    }
    Ok(())
}
fn reveal(window: &WebviewWindow) -> Result<()> {
    window.unminimize().map_err(storage)?;
    window.show().map_err(storage)?;
    window.set_focus().map_err(storage)
}
fn changed(app: &AppHandle) {
    let _ = app.emit("actions_changed", ());
}
async fn snapshot(runtime: &Runtime) -> Result<Value> {
    let mut s = runtime.store.call(|db| db.snapshot()).await?;
    let statuses = runtime.statuses.lock().map_err(storage)?;
    for shortcut in &mut s.shortcuts {
        if let Some(status) = statuses.get(&shortcut.owner) {
            *shortcut = status.clone();
        }
    }
    serde_json::to_value(s).map_err(storage)
}
#[tauri::command]
async fn get_snapshot(window: WebviewWindow, state: State<'_, Runtime>) -> Result<Value> {
    surface(&window)?;
    snapshot(&state).await
}
#[tauri::command]
async fn get_capabilities(
    window: WebviewWindow,
    app: AppHandle,
    state: State<'_, Runtime>,
) -> Result<Value> {
    surface(&window)?;
    platform::capabilities(&app, state.tray).await
}
#[tauri::command]
async fn library_operation(
    window: WebviewWindow,
    app: AppHandle,
    state: State<'_, Runtime>,
    op: String,
    args: Value,
) -> Result<Value> {
    library(&window)?;
    if op == "settings" {
        let s: Settings = serde_json::from_value(args["settings"].clone())
            .map_err(|_| error("VALIDATION", "Invalid settings."))?;
        let old = state.store.call(|db| db.settings()).await?;
        if s.keep_running && !state.tray {
            return Err(error(
                "TRAY_UNAVAILABLE",
                "Keep the library open when menu bar access is unavailable.",
            ));
        }
        if s.launch_at_login != old.launch_at_login {
            if s.launch_at_login {
                app.autolaunch().enable()
            } else {
                app.autolaunch().disable()
            }
            .map_err(|_| error("AUTOSTART_FAILED", "Could not change launch at login."))?;
        }
        let result = state
            .store
            .call(move |db| db.handle("settings", args))
            .await;
        if result.is_err() {
            let _ = if old.launch_at_login {
                app.autolaunch().enable()
            } else {
                app.autolaunch().disable()
            };
        }
        changed(&app);
        return result;
    }
    let _shortcut_guard = if op == "delete" {
        Some(state.shortcut_changes.lock().await)
    } else {
        None
    };
    let delete_owner = if op == "delete" {
        args["id"].as_str().map(|id| format!("action:{id}"))
    } else {
        None
    };
    let saving_action = op == "save";
    let value = state.store.call(move |db| db.handle(&op, args)).await?;
    if saving_action {
        let action: Action = serde_json::from_value(value.clone()).map_err(storage)?;
        sync_action_shortcut(&app, &state, &action).await?;
    }
    if let Some(owner) = delete_owner {
        if let Some(s) = state.statuses.lock().map_err(storage)?.remove(&owner) {
            if let Some(chord) = s.active {
                let _ = app.global_shortcut().unregister(chord.as_str());
            }
        }
    }
    changed(&app);
    Ok(value)
}
async fn sync_action_shortcut(app: &AppHandle, state: &Runtime, action: &Action) -> Result<()> {
    let _guard = state.shortcut_changes.lock().await;
    let owner = format!("action:{}", action.id);
    let saved = state.statuses.lock().map_err(storage)?.get(&owner).cloned();
    if let Some(mut status) = saved {
        if !action.enabled {
            if let Some(active) = &status.active {
                let _ = app.global_shortcut().unregister(active.as_str());
            }
            status.active = None;
            status.error = Some("Action disabled".into());
        } else if status.active.is_none()
            && !status.requested.is_empty()
            && !*state.paused.lock().map_err(storage)?
        {
            match activate_binding(app, &owner, &status.requested) {
                Ok(()) => {
                    status.active = Some(status.requested.clone());
                    status.error = None;
                }
                Err(e) => {
                    status.error = Some(e.message);
                }
            }
        }
        state
            .statuses
            .lock()
            .map_err(storage)?
            .insert(owner.clone(), status);
        state.pressed.lock().map_err(storage)?.remove(&owner);
    }
    Ok(())
}
async fn register_requested(app: &AppHandle, owner: &str, chord: &str) -> Result<()> {
    let state = app.state::<Runtime>();
    if platform::wayland() {
        return Err(error(
            "SHORTCUT_UNSUPPORTED",
            "Global shortcuts unavailable on Wayland.",
        ));
    }
    if let Some(id) = owner.strip_prefix("action:") {
        let id = id.to_string();
        if !state.store.call(move |db| db.get(&id)).await?.enabled {
            return Err(error("ACTION_DISABLED", "Action disabled"));
        }
    }
    activate_binding(app, owner, chord)
}
async fn show_palette(app: &AppHandle) -> Result<String> {
    let state = app.state::<Runtime>();
    let mut engine = state
        .engine
        .try_lock()
        .map_err(|_| error("EXECUTION_BUSY", "An action is being prepared."))?;
    let w = app
        .get_webview_window("palette")
        .ok_or_else(|| error("WINDOW_UNAVAILABLE", "The palette is unavailable."))?;
    if w.is_visible().unwrap_or(false) {
        engine.cancel();
        w.hide().map_err(storage)?;
        return Ok(String::new());
    }
    let target = platform::capture(app).await;
    let id = engine.begin();
    if let Some(invocation) = &mut engine.invocation {
        match target {
            Ok(target) => invocation.target = Some(target),
            Err(reason) => invocation.target_error = Some(reason),
        }
    }
    state.cancelled.store(false, Ordering::SeqCst);
    let monitor = app
        .cursor_position()
        .ok()
        .and_then(|p| app.monitor_from_point(p.x, p.y).ok().flatten())
        .or_else(|| w.primary_monitor().ok().flatten());
    if let Some(monitor) = monitor {
        let scale = monitor.scale_factor();
        let area = monitor.work_area();
        let width = (area.size.width as f64 / scale * 0.9).min(680.0);
        let height = (area.size.height as f64 / scale * 0.9).min(480.0);
        w.set_size(tauri::LogicalSize::new(width, height))
            .map_err(storage)?;
        w.set_position(tauri::PhysicalPosition::new(
            area.position.x + ((area.size.width as f64 - width * scale) / 2.0) as i32,
            area.position.y + ((area.size.height as f64 - height * scale) / 2.0) as i32,
        ))
        .map_err(storage)?;
    } else {
        w.center().map_err(storage)?;
    }
    w.set_always_on_top(true).map_err(storage)?;
    reveal(&w)?;
    w.emit_to("palette", "palette_opened", &id)
        .map_err(storage)?;
    Ok(id)
}
#[tauri::command]
async fn open_palette(window: WebviewWindow, app: AppHandle) -> Result<String> {
    surface(&window)?;
    show_palette(&app).await
}
#[tauri::command]
async fn palette_context(window: WebviewWindow, state: State<'_, Runtime>) -> Result<String> {
    if window.label() != "palette" {
        return Err(error("FORBIDDEN", "Palette only."));
    }
    let mut e = state
        .engine
        .try_lock()
        .map_err(|_| error("EXECUTION_BUSY", "An action is being prepared."))?;
    Ok(e.invocation
        .as_ref()
        .map(|i| i.id.clone())
        .unwrap_or_else(|| e.begin()))
}
#[tauri::command]
async fn close_palette(
    window: WebviewWindow,
    app: AppHandle,
    state: State<'_, Runtime>,
) -> Result<()> {
    surface(&window)?;
    state.cancelled.store(true, Ordering::SeqCst);
    if let Ok(mut e) = state.engine.try_lock() {
        e.cancel();
    }
    if let Some(w) = app.get_webview_window("palette") {
        let _ = w.hide();
        let _ = w.set_always_on_top(false);
    }
    Ok(())
}
#[tauri::command]
async fn show_library(
    window: WebviewWindow,
    app: AppHandle,
    state: State<'_, Runtime>,
    page: String,
    action_id: Option<String>,
) -> Result<()> {
    surface(&window)?;
    if ![
        "library",
        "settings",
        "new",
        "favorite",
        "disable",
        "duplicate",
    ]
    .contains(&page.as_str())
    {
        return Err(error("VALIDATION", "Unknown page."));
    }
    let mut e = state
        .engine
        .try_lock()
        .map_err(|_| error("EXECUTION_BUSY", "Wait for the current copy to complete."))?;
    e.cancel();
    if let Some(w) = app.get_webview_window("palette") {
        let _ = w.hide();
    }
    if let Some(w) = app.get_webview_window("library") {
        reveal(&w)?;
        w.emit_to(
            "library",
            "navigate",
            json!({"page":page,"actionId":action_id}),
        )
        .map_err(storage)?;
    }
    Ok(())
}
async fn deliver(
    app: &AppHandle,
    id: String,
    revision: i64,
    invocation: Option<String>,
    override_copy: bool,
    key: String,
) -> Result<Value> {
    let state = app.state::<Runtime>();
    let mut engine = state
        .engine
        .try_lock()
        .map_err(|_| error("EXECUTION_BUSY", "An action is being prepared."))?;
    let library_request = invocation.is_none();
    let identity = format!("{id}:{revision}");
    if library_request {
        if let Some(result) = engine.prior_library(&key, &identity)? {
            return Ok(result);
        }
    }
    let invocation = invocation.unwrap_or_else(|| {
        state.cancelled.store(false, Ordering::SeqCst);
        engine.begin()
    });
    if let Some(result) = engine.prior(&invocation, &key)? {
        return Ok(result);
    }
    let aid = id.clone();
    let action = state.store.call(move |db| db.get(&aid)).await?;
    check_revision(&action, &json!({"revision":revision}))?;
    if !action.enabled {
        return Err(error(
            "ACTION_DISABLED",
            "Enable this action before using it.",
        ));
    }
    let settings = state.store.call(|db| db.settings()).await?;
    let paste = !override_copy
        && (action.delivery_mode == "paste"
            || (action.delivery_mode == "inherit" && settings.default_delivery == "paste"));
    if paste && library_request {
        let target = platform::capture(app).await;
        if let Some(invocation) = &mut engine.invocation {
            match target {
                Ok(target) => invocation.target = Some(target),
                Err(reason) => invocation.target_error = Some(reason),
            }
        }
    }
    if paste {
        let active = engine
            .invocation
            .as_ref()
            .ok_or_else(|| error("INVOCATION_EXPIRED", "Reopen Cue."))?;
        let preflight = match &active.target {
            Some(target) => target.check(app).await,
            None => Err(active.target_error.clone().unwrap_or_else(|| {
                error(
                    "TARGET_UNAVAILABLE",
                    "Open Cue from a text field using your shortcut.",
                )
            })),
        };
        if let Err(reason) = preflight {
            return Ok(json!({"status":"blocked","message":reason.message}));
        }
    }
    let source_generation = if paste {
        platform::clipboard_generation(app).await?
    } else {
        -1
    };
    let clipboard = if needs_clipboard(&action.template)? {
        let text = app.clipboard().read_text().map_err(|_| {
            error(
                "CLIPBOARD_UNAVAILABLE",
                "Could not read plain text from the clipboard.",
            )
        })?;
        if text.is_empty() {
            return Err(error(
                "CLIPBOARD_EMPTY",
                "Copy source text before using this action.",
            ));
        }
        validate_text(&text, 1_048_576)?;
        text
    } else {
        String::new()
    };
    let output = render_local(&action.template, &clipboard)?;
    if state.cancelled.load(Ordering::SeqCst) {
        engine.cancel();
        return Ok(json!({"status":"cancelled","message":"Cancelled."}));
    }
    engine.claim(&invocation)?;
    let write = if paste {
        platform::write_paste(app, output, source_generation).await
    } else {
        app.clipboard()
            .write_text(output)
            .map(|_| -1)
            .map_err(|_| error("CLIPBOARD_UNAVAILABLE", "Could not write to the clipboard."))
    };
    let result = match write {
        Err(reason) => json!({"status":"failed_before_copy","message":reason.message}),
        Ok(generation) => {
            if let Some(w) = app.get_webview_window("palette") {
                let _ = w.hide();
                let _ = w.set_always_on_top(false);
            }
            let delivery = if paste {
                let target = engine
                    .invocation
                    .as_ref()
                    .and_then(|i| i.target.as_ref())
                    .expect("preflight checked target");
                if state.cancelled.load(Ordering::SeqCst) {
                    Err(error("CANCELLED", "Paste cancelled."))
                } else {
                    match target.activate(app).await {
                        Ok(()) => {
                            // Let AppKit complete activation before verifying the exact window and field.
                            tokio::time::sleep(std::time::Duration::from_millis(80)).await;
                            if state.cancelled.load(Ordering::SeqCst) {
                                Err(error("CANCELLED", "Paste cancelled."))
                            } else {
                                target.paste(app, generation, state.cancelled.clone()).await
                            }
                        }
                        Err(reason) => Err(reason),
                    }
                }
            } else {
                Ok(())
            };
            let usage = state.store.call(move |db| db.usage(&id)).await.is_ok();
            match delivery {
                Ok(()) if paste => {
                    json!({"status":"pasted","message":"Paste sent.","usageSaved":usage})
                }
                Ok(()) => execution::copied(usage),
                Err(reason) => {
                    json!({"status":"copied_not_pasted","message":format!("Text copied, but not pasted. {}", reason.message),"usageSaved":usage})
                }
            }
        }
    };
    engine.finish(&key, result.clone());
    if library_request {
        engine.finish_library(&key, identity, result.clone());
    }
    if result["status"] == "copied_not_pasted" {
        if let Some(w) = app.get_webview_window("palette") {
            // Show recovery without taking focus from the target app.
            let _ = w.show();
        }
    }
    changed(app);
    Ok(result)
}
#[tauri::command]
async fn copy_action(
    window: WebviewWindow,
    app: AppHandle,
    id: String,
    revision: i64,
    key: String,
) -> Result<Value> {
    library(&window)?;
    deliver(&app, id, revision, None, true, key).await
}
#[tauri::command]
async fn execute_action(
    window: WebviewWindow,
    app: AppHandle,
    id: String,
    revision: i64,
    invocation: String,
    override_copy: bool,
    key: String,
) -> Result<Value> {
    if window.label() != "palette" {
        return Err(error(
            "FORBIDDEN",
            "Delivery is only available from the palette.",
        ));
    }
    deliver(&app, id, revision, Some(invocation), override_copy, key).await
}
fn activate_binding(app: &AppHandle, owner: &str, chord: &str) -> Result<()> {
    let shortcut = Shortcut::from_str(chord).map_err(|_| {
        error(
            "SHORTCUT_CONFLICT",
            "Invalid shortcut. Use a modifier and a key.",
        )
    })?;
    let owner = owner.to_string();
    app.global_shortcut()
        .on_shortcut(shortcut, move |app, _, event| {
            let state = app.state::<Runtime>();
            if let Ok(mut pressed) = state.pressed.lock() {
                if event.state() == ShortcutState::Released {
                    pressed.remove(&owner);
                    return;
                }
                if !pressed.insert(owner.clone()) {
                    return;
                }
            } else {
                return;
            }
            let app = app.clone();
            let owner = owner.clone();
            tauri::async_runtime::spawn(async move {
                if owner == "palette" {
                    let _ = show_palette(&app).await;
                } else if let Some(id) = owner.strip_prefix("action:") {
                    let id = id.to_string();
                    let aid = id.clone();
                    let state = app.state::<Runtime>();
                    if let Ok(a) = state.store.call(move |db| db.get(&aid)).await {
                        if a.enabled {
                            let result = deliver(
                                &app,
                                id,
                                a.revision,
                                None,
                                false,
                                uuid::Uuid::new_v4().to_string(),
                            )
                            .await;
                            if let Some(w) = app.get_webview_window("library") {
                                let result = match result {
                                    Ok(r) => r,
                                    Err(e) => {
                                        json!({"status":"failed_before_copy","message":e.message})
                                    }
                                };
                                let _ = w.emit_to("library", "execution_result", &result);
                                if result["status"] != "copied" && result["status"] != "pasted" {
                                    let _ = reveal(&w);
                                }
                            }
                        }
                    }
                }
            });
        })
        .map_err(|_| {
            error(
                "SHORTCUT_CONFLICT",
                "The system could not register this shortcut. Choose another.",
            )
        })
}
#[tauri::command]
async fn configure_shortcut(
    window: WebviewWindow,
    app: AppHandle,
    state: State<'_, Runtime>,
    owner: String,
    chord: String,
) -> Result<Value> {
    library(&window)?;
    let _guard = state.shortcut_changes.lock().await;
    if platform::wayland() {
        return Err(error(
            "SHORTCUT_UNSUPPORTED",
            "Global shortcuts are unavailable on Wayland. Open Cue from your launcher.",
        ));
    }
    let action_enabled = if owner != "palette" {
        let id = owner
            .strip_prefix("action:")
            .ok_or_else(|| error("VALIDATION", "Invalid shortcut owner."))?
            .to_string();
        state.store.call(move |db| db.get(&id)).await?.enabled
    } else {
        true
    };
    let normalized = if chord.is_empty() {
        String::new()
    } else {
        Shortcut::from_str(&chord)
            .map_err(|_| error("SHORTCUT_CONFLICT", "Choose a valid shortcut."))?
            .to_string()
    };
    let old = {
        let statuses = state.statuses.lock().map_err(storage)?;
        if statuses.values().any(|s| {
            s.owner != owner
                && !s.requested.is_empty()
                && Shortcut::from_str(&s.requested).ok().map(|s| s.to_string())
                    == Some(normalized.clone())
        }) {
            return Err(error(
                "SHORTCUT_CONFLICT",
                "This shortcut is already used by another action.",
            ));
        }
        statuses.get(&owner).cloned()
    };
    if old
        .as_ref()
        .is_some_and(|s| s.requested == chord && s.active.is_some())
    {
        return serde_json::to_value(old).map_err(storage);
    }
    let paused = *state.paused.lock().map_err(storage)?;
    if !chord.is_empty() && !paused && action_enabled {
        activate_binding(&app, &owner, &chord)?;
    }
    let o = owner.clone();
    let c = chord.clone();
    if let Err(e) = state.store.call(move |db| db.save_binding(&o, &c)).await {
        if !chord.is_empty() {
            let _ = app.global_shortcut().unregister(chord.as_str());
        }
        return Err(e);
    }
    if let Some(old) = old {
        if let Some(active) = old.active {
            let _ = app.global_shortcut().unregister(active.as_str());
        }
    }
    let status = ShortcutStatus {
        owner: owner.clone(),
        requested: chord.clone(),
        active: if chord.is_empty() || paused || !action_enabled {
            None
        } else {
            Some(chord)
        },
        error: if !action_enabled {
            Some("Action disabled".into())
        } else if paused {
            Some("Shortcuts paused".into())
        } else {
            None
        },
    };
    state
        .statuses
        .lock()
        .map_err(storage)?
        .insert(owner, status.clone());
    changed(&app);
    serde_json::to_value(status).map_err(storage)
}
async fn restore_shortcuts(app: &AppHandle, state: &Runtime, paused: bool) -> Result<()> {
    app.global_shortcut().unregister_all().map_err(|_| {
        error(
            "SHORTCUT_CONFLICT",
            "Could not refresh shortcuts. Try pause and resume again.",
        )
    })?;
    state.pressed.lock().map_err(storage)?.clear();
    *state.paused.lock().map_err(storage)? = paused;
    let bindings = state.store.call(|db| db.bindings()).await?;
    let mut statuses = HashMap::new();
    for (owner, chord) in bindings {
        let result = if paused {
            Err(error("SHORTCUT_PAUSED", "Shortcuts paused"))
        } else {
            register_requested(app, &owner, &chord).await
        };
        statuses.insert(
            owner.clone(),
            ShortcutStatus {
                owner,
                requested: chord.clone(),
                active: result.as_ref().ok().map(|_| chord),
                error: result.err().map(|e| e.message),
            },
        );
    }
    *state.statuses.lock().map_err(storage)? = statuses;
    Ok(())
}
async fn pause_shortcuts(app: &AppHandle) -> Result<()> {
    let state = app.state::<Runtime>();
    let _guard = state.shortcut_changes.lock().await;
    let paused = !*state.paused.lock().map_err(storage)?;
    restore_shortcuts(app, &state, paused).await?;
    changed(app);
    Ok(())
}
#[tauri::command]
async fn toggle_shortcuts(window: WebviewWindow, app: AppHandle) -> Result<()> {
    library(&window)?;
    pause_shortcuts(&app).await
}
#[tauri::command]
async fn preview_import(
    window: WebviewWindow,
    app: AppHandle,
    state: State<'_, Runtime>,
) -> Result<Value> {
    library(&window)?;
    let file = tauri::async_runtime::spawn_blocking(move || {
        app.dialog()
            .file()
            .add_filter("Cue actions", &["json"])
            .blocking_pick_file()
    })
    .await
    .map_err(storage)?;
    let Some(file) = file else {
        return Ok(Value::Null);
    };
    let path = file.into_path().map_err(storage)?;
    let text = tauri::async_runtime::spawn_blocking(move || {
        use std::io::Read;
        let mut data = Vec::new();
        std::fs::File::open(path)
            .map_err(storage)?
            .take(10 * 1024 * 1024 + 1)
            .read_to_end(&mut data)
            .map_err(storage)?;
        if data.len() > 10 * 1024 * 1024 {
            return Err(error("OUTPUT_TOO_LARGE", "Import file exceeds 10 MiB."));
        }
        String::from_utf8(data).map_err(|_| error("VALIDATION", "Import is not UTF-8 text."))
    })
    .await
    .map_err(storage)??;
    state.store.call(move |db| db.preview(&text)).await
}
#[tauri::command]
async fn commit_import(
    window: WebviewWindow,
    app: AppHandle,
    state: State<'_, Runtime>,
    token: String,
    update: bool,
) -> Result<()> {
    library(&window)?;
    let _guard = state.shortcut_changes.lock().await;
    state
        .store
        .call(move |db| db.commit_import(&token, update))
        .await?;
    let paused = *state.paused.lock().map_err(storage)?;
    let result = restore_shortcuts(&app, &state, paused).await;
    changed(&app);
    result.map_err(|_| {
        error(
            "SHORTCUT_CONFLICT",
            "Actions imported. Could not refresh shortcuts; pause and resume them in Settings.",
        )
    })
}

#[tauri::command]
async fn export_actions(
    window: WebviewWindow,
    app: AppHandle,
    state: State<'_, Runtime>,
) -> Result<bool> {
    library(&window)?;
    let data = state
        .store
        .call(|db| {
            Ok(Export {
                schema_version: 1,
                exported_at: now(),
                actions: db.snapshot()?.actions.into_iter().map(Into::into).collect(),
            })
        })
        .await?;
    let file = tauri::async_runtime::spawn_blocking(move || {
        app.dialog()
            .file()
            .add_filter("Cue actions", &["json"])
            .set_file_name("cue-actions.json")
            .blocking_save_file()
    })
    .await
    .map_err(storage)?;
    let Some(file) = file else {
        return Ok(false);
    };
    let path = file.into_path().map_err(storage)?;
    let text = serde_json::to_vec_pretty(&data).map_err(storage)?;
    tauri::async_runtime::spawn_blocking(move || {
        use std::io::Write;
        let temp = path.with_file_name(format!(".cue-export-{}.tmp", uuid::Uuid::new_v4()));
        let result = (|| -> Result<()> {
            let mut f = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&temp)
                .map_err(storage)?;
            f.write_all(&text).map_err(storage)?;
            f.sync_all().map_err(storage)?;
            std::fs::rename(&temp, &path).map_err(storage)?;
            Ok(())
        })();
        if result.is_err() {
            let _ = std::fs::remove_file(temp);
        }
        result
    })
    .await
    .map_err(storage)??;
    Ok(true)
}
#[tauri::command]
async fn request_paste_permission(window: WebviewWindow, app: AppHandle) -> Result<()> {
    library(&window)?;
    platform::request_permission(&app).await
}
#[tauri::command]
async fn close_library(
    window: WebviewWindow,
    app: AppHandle,
    state: State<'_, Runtime>,
) -> Result<()> {
    library(&window)?;
    let settings = state.store.call(|db| db.settings()).await?;
    if !settings.keep_running || !state.tray {
        return quit_app(window, app, state).await;
    }
    if let Some(palette) = app.get_webview_window("palette") {
        let _ = palette.hide();
    }
    window.hide().map_err(storage)?;
    Ok(())
}
#[tauri::command]
async fn quit_app(window: WebviewWindow, app: AppHandle, state: State<'_, Runtime>) -> Result<()> {
    library(&window)?;
    state.cancelled.store(true, Ordering::SeqCst);
    let mut engine = state.engine.lock().await;
    engine.cancel();
    let _ = state
        .store
        .call(|db| {
            db.conn
                .execute_batch("PRAGMA wal_checkpoint(TRUNCATE)")
                .map_err(storage)
        })
        .await;
    let _ = app.global_shortcut().unregister_all();
    app.exit(0);
    Ok(())
}
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, args, _| {
            let app = app.clone();
            tauri::async_runtime::spawn(async move {
                match LaunchIntent::from_args(&args) {
                    LaunchIntent::Background => {}
                    LaunchIntent::Palette => {
                        let _ = show_palette(&app).await;
                    }
                    LaunchIntent::Library => {
                        if let Some(w) = app.get_webview_window("library") {
                            let _ = reveal(&w);
                        }
                    }
                }
            });
        }))
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .plugin(tauri_plugin_dialog::init())
        .plugin(
            tauri_plugin_autostart::Builder::new()
                .args(["--autostart"])
                .build(),
        )
        .setup(|app| {
            let mut dir = app.path().app_data_dir()?;
            if cfg!(debug_assertions) {
                dir = dir.with_file_name("app.cue.launcher.dev");
            }
            let store = Store::start(dir).unwrap_or_else(Store::unavailable);
            for config in &app.config().app.windows {
                tauri::WebviewWindowBuilder::from_config(app, config)?
                    .devtools(cfg!(debug_assertions))
                    .on_navigation(|url| {
                        url.scheme() == "tauri"
                            || url.host_str() == Some("tauri.localhost")
                            || (cfg!(debug_assertions)
                                && matches!(url.host_str(), Some("localhost" | "127.0.0.1"))
                                && url.port() == Some(1420))
                    })
                    .build()?;
            }

            use tauri::menu::{Menu, MenuItem};
            use tauri::tray::TrayIconBuilder;
            let items = [
                ("palette", "Open Palette"),
                ("library", "Manage Actions"),
                ("settings", "Settings"),
                ("pause", "Pause / Resume Shortcuts"),
                ("quit", "Quit Cue"),
            ]
            .map(|(id, label)| MenuItem::with_id(app, id, label, true, None::<&str>))
            .into_iter()
            .collect::<std::result::Result<Vec<_>, _>>()?;
            let refs: Vec<&dyn tauri::menu::IsMenuItem<_>> = items
                .iter()
                .map(|i| i as &dyn tauri::menu::IsMenuItem<_>)
                .collect();
            let menu = Menu::with_items(app, &refs)?;
            let mut tray = TrayIconBuilder::new()
                .menu(&menu)
                .tooltip("Cue — Your prompts, on cue.")
                .on_menu_event(|app, event| {
                    let app = app.clone();
                    tauri::async_runtime::spawn(async move {
                        match event.id.as_ref() {
                            "palette" => {
                                let _ = show_palette(&app).await;
                            }
                            "pause" => {
                                let _ = pause_shortcuts(&app).await;
                            }
                            "quit" => {
                                if let Some(w) = app.get_webview_window("library") {
                                    let _ = reveal(&w);
                                    let _ = w.emit_to("library", "quit_requested", ());
                                }
                            }
                            page => {
                                if let Some(w) = app.get_webview_window("library") {
                                    let state = app.state::<Runtime>();
                                    if let Ok(mut e) = state.engine.try_lock() {
                                        e.cancel();
                                        let _ = reveal(&w);
                                        let _ = w.emit_to("library", "navigate", page);
                                    };
                                }
                            }
                        }
                    });
                });
            if let Some(icon) = app.default_window_icon() {
                tray = tray.icon(icon.clone());
            }
            let tray_available = tray.build(app).is_ok();
            app.manage(Runtime {
                store,
                engine: tokio::sync::Mutex::new(Engine::default()),
                statuses: Mutex::new(HashMap::new()),
                paused: Mutex::new(false),
                pressed: Mutex::new(HashSet::new()),
                shortcut_changes: tokio::sync::Mutex::new(()),
                tray: tray_available,
                cancelled: Arc::new(AtomicBool::new(false)),
            });
            let app = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                let state = app.state::<Runtime>();
                {
                    let _guard = state.shortcut_changes.lock().await;
                    let _ = restore_shortcuts(&app, &state, false).await;
                }
                let settings = state.store.call(|db| db.settings()).await;
                let intent = LaunchIntent::from_args(std::env::args());
                if settings.as_ref().is_ok_and(|s| s.onboarded) && intent == LaunchIntent::Palette {
                    let _ = show_palette(&app).await;
                } else if intent != LaunchIntent::Background
                    || !settings.as_ref().is_ok_and(|s| s.onboarded)
                {
                    if let Some(w) = app.get_webview_window("library") {
                        let _ = reveal(&w);
                    }
                }
                changed(&app);
            });
            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                if window.label() == "palette" {
                    api.prevent_close();
                    let app = window.app_handle().clone();
                    tauri::async_runtime::spawn(async move {
                        let state = app.state::<Runtime>();
                        if let Ok(mut e) = state.engine.try_lock() {
                            e.cancel();
                        }
                        if let Some(w) = app.get_webview_window("palette") {
                            let _ = w.hide();
                        }
                    });
                } else {
                    api.prevent_close();
                    let _ = window.emit_to("library", "close_requested", ());
                }
            }
            if let tauri::WindowEvent::Focused(false) = event {
                if window.label() == "palette"
                    && window.is_visible().unwrap_or(false)
                    && window
                        .app_handle()
                        .state::<Runtime>()
                        .engine
                        .try_lock()
                        .is_ok()
                {
                    window
                        .app_handle()
                        .state::<Runtime>()
                        .cancelled
                        .store(true, Ordering::SeqCst);
                    let app = window.app_handle().clone();
                    tauri::async_runtime::spawn(async move {
                        let state = app.state::<Runtime>();
                        if let Ok(mut e) = state.engine.try_lock() {
                            e.cancel();
                            if let Some(w) = app.get_webview_window("palette") {
                                let _ = w.hide();
                                let _ = w.set_always_on_top(false);
                            }
                        };
                    });
                }
            }
        })
        .invoke_handler(tauri::generate_handler![
            get_snapshot,
            get_capabilities,
            request_paste_permission,
            close_library,
            library_operation,
            open_palette,
            palette_context,
            close_palette,
            show_library,
            copy_action,
            execute_action,
            configure_shortcut,
            toggle_shortcuts,
            preview_import,
            commit_import,
            export_actions,
            quit_app
        ])
        .build(tauri::generate_context!())
        .expect("Cue could not start")
        .run(|app, event| {
            #[cfg(target_os = "macos")]
            if let tauri::RunEvent::Reopen {
                has_visible_windows: false,
                ..
            } = event
            {
                if let Some(window) = app.get_webview_window("library") {
                    let _ = reveal(&window);
                }
            }
            if let tauri::RunEvent::ExitRequested { api, code, .. } = event {
                if code.is_none() {
                    api.prevent_exit();
                    if let Some(w) = app.get_webview_window("library") {
                        let _ = w.emit_to("library", "quit_requested", ());
                    }
                }
            }
        });
}
