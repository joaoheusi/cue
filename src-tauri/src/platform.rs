use crate::domain::{error, Result};
use serde_json::{json, Value};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use tauri::AppHandle;

pub fn wayland() -> bool {
    cfg!(target_os = "linux") && std::env::var("XDG_SESSION_TYPE").is_ok_and(|s| s == "wayland")
}
async fn on_main<T: Send + 'static>(
    app: &AppHandle,
    f: impl FnOnce() -> T + Send + 'static,
) -> Result<T> {
    let (tx, rx) = tokio::sync::oneshot::channel();
    app.run_on_main_thread(move || {
        let _ = tx.send(f());
    })
    .map_err(crate::domain::storage)?;
    rx.await.map_err(crate::domain::storage)
}
#[cfg(target_os = "macos")]
unsafe extern "C" {
    fn cue_paste_permissions() -> i32;
    fn cue_request_paste_permission();
    fn cue_capture_target(status: *mut i32) -> usize;
    fn cue_release_target(handle: usize);
    fn cue_check_target(handle: usize) -> i32;
    fn cue_activate_target(handle: usize) -> i32;
    fn cue_clipboard_generation() -> std::ffi::c_long;
    fn cue_write_paste_text(
        text: *const std::ffi::c_char,
        expected: std::ffi::c_long,
    ) -> std::ffi::c_long;
    fn cue_send_paste(handle: usize, generation: std::ffi::c_long) -> i32;
}
// The opaque retained native target never crosses IPC. AppKit calls run on the main thread.
struct NativeTarget(usize);
#[derive(Clone)]
pub struct Target(Arc<NativeTarget>);
impl Drop for NativeTarget {
    fn drop(&mut self) {
        #[cfg(target_os = "macos")]
        unsafe {
            cue_release_target(self.0);
        }
    }
}
fn native_error(status: i32) -> crate::domain::Error {
    let (code, message) = match status {
        1 => ("PERMISSION_REQUIRED", "Cue cannot access your text field. Enable Cue in System Settings → Privacy & Security → Accessibility. If it is already on, turn it off and on, then quit and reopen Cue."),
        2 => ("TARGET_UNAVAILABLE", "Focus a text field in another app, then open Cue with your shortcut."),
        3 => ("TARGET_CHANGED", "The target window or text field changed. Reopen Cue from the field you want to paste into."),
        4 => ("PROTECTED_INPUT", "Automatic paste is unavailable in protected text fields."),
        5 => ("PASTE_UNSUPPORTED", "Terminal apps use Copy. Paste manually in your terminal."),
        6 => ("CLIPBOARD_CHANGED", "The clipboard changed. Reopen Cue to prepare the action again."),
        7 => ("MODIFIERS_HELD", "Release the shortcut keys and try again."),
        9 => ("FOCUS_TIMEOUT", "Could not return to the target window. Paste manually."),
        10 => ("CANCELLED", "Paste cancelled."),
        11 => ("PASTE_PERMISSION_REQUIRED", "macOS allows Cue to read the target but is blocking the paste shortcut. Refresh Cue’s Accessibility access, then quit and reopen Cue."),
        _ => ("PASTE_UNSUPPORTED", "Automatic paste is available in the macOS app. Use Copy here."),
    };
    error(code, message)
}
pub async fn capabilities(app: &AppHandle, tray: bool) -> Result<Value> {
    let permissions = on_main(app, || {
        #[cfg(target_os = "macos")]
        unsafe {
            cue_paste_permissions()
        }
        #[cfg(not(target_os = "macos"))]
        {
            0
        }
    })
    .await?;
    let status = |allowed| {
        if cfg!(target_os = "macos") {
            if allowed {
                "available"
            } else {
                "permission required"
            }
        } else {
            "unsupported"
        }
    };
    let target = status(permissions & 1 != 0);
    let paste = status(permissions & 2 != 0);
    Ok(
        json!({"session":if cfg!(target_os="macos"){"macOS"}else if cfg!(target_os="windows"){"Windows"}else if wayland(){"Wayland"}else{"X11"},"clipboard":"available","globalShortcut":if wayland(){"unavailable"}else{"available"},"targetCapture":target,"focusRestoration":target,"pasteInjection":paste,"tray":if tray{"available"}else{"unavailable"},"native":true}),
    )
}
pub async fn request_permission(app: &AppHandle) -> Result<()> {
    on_main(app, || {
        #[cfg(target_os = "macos")]
        unsafe {
            cue_request_paste_permission();
        }
    })
    .await
}
pub async fn capture(app: &AppHandle) -> Result<Target> {
    on_main(app, || {
        #[cfg(target_os = "macos")]
        unsafe {
            let mut status = 0;
            let handle = cue_capture_target(&mut status);
            if handle != 0 {
                return Ok(Target(Arc::new(NativeTarget(handle))));
            }
            Err(native_error(status))
        }
        #[cfg(not(target_os = "macos"))]
        {
            Err(native_error(8))
        }
    })
    .await?
}
impl Target {
    pub async fn check(&self, app: &AppHandle) -> Result<()> {
        self.call(app, false).await
    }
    pub async fn activate(&self, app: &AppHandle) -> Result<()> {
        self.call(app, true).await
    }
    async fn call(&self, app: &AppHandle, activate: bool) -> Result<()> {
        let retained = self.0.clone();
        let status = on_main(app, move || {
            #[cfg(target_os = "macos")]
            unsafe {
                if activate {
                    cue_activate_target(retained.0)
                } else {
                    cue_check_target(retained.0)
                }
            }
            #[cfg(not(target_os = "macos"))]
            {
                let _ = (retained.0, activate);
                8
            }
        })
        .await?;
        if status == 0 {
            Ok(())
        } else {
            Err(native_error(status))
        }
    }
    pub async fn paste(
        &self,
        app: &AppHandle,
        generation: i64,
        cancelled: Arc<AtomicBool>,
    ) -> Result<()> {
        let retained = self.0.clone();
        let deadline = std::time::Instant::now() + std::time::Duration::from_millis(800);
        loop {
            let retained = retained.clone();
            let cancelled = cancelled.clone();
            let status = on_main(app, move || {
                if cancelled.load(Ordering::SeqCst) {
                    return 10;
                }
                #[cfg(target_os = "macos")]
                unsafe {
                    cue_send_paste(retained.0, generation as std::ffi::c_long)
                }
                #[cfg(not(target_os = "macos"))]
                {
                    let _ = (retained.0, generation);
                    8
                }
            })
            .await?;
            if status == 0 {
                return Ok(());
            }
            // Wait only for activation or released modifiers. Never retry a sent chord.
            if !matches!(status, 7 | 9) || std::time::Instant::now() >= deadline {
                return Err(native_error(status));
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
    }
}
pub async fn clipboard_generation(app: &AppHandle) -> Result<i64> {
    on_main(app, || {
        #[cfg(target_os = "macos")]
        unsafe {
            cue_clipboard_generation() as i64
        }
        #[cfg(not(target_os = "macos"))]
        {
            -1
        }
    })
    .await
}
pub async fn write_paste(app: &AppHandle, text: String, expected: i64) -> Result<i64> {
    let value = std::ffi::CString::new(text).map_err(|_| error("VALIDATION", "Invalid text."))?;
    let generation = on_main(app, move || {
        #[cfg(target_os = "macos")]
        unsafe {
            cue_write_paste_text(value.as_ptr(), expected as std::ffi::c_long) as i64
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = (value, expected);
            -1
        }
    })
    .await?;
    match generation {
        -2 => Err(native_error(6)),
        -1 => Err(error(
            "CLIPBOARD_UNAVAILABLE",
            "Could not write text to the clipboard.",
        )),
        _ => Ok(generation),
    }
}
