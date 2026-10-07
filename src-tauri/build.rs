fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        cc::Build::new()
            .file("native/paste.m")
            .flag("-fobjc-arc")
            .flag("-fblocks")
            .compile("cue_paste");
        for framework in ["AppKit", "ApplicationServices", "Carbon"] {
            println!("cargo:rustc-link-lib=framework={framework}");
        }
        println!("cargo:rerun-if-changed=native/paste.m");
    }
    tauri_build::try_build(tauri_build::Attributes::new().app_manifest(
        tauri_build::AppManifest::new().commands(&[
            "get_snapshot",
            "get_capabilities",
            "request_paste_permission",
            "close_library",
            "library_operation",
            "open_palette",
            "palette_context",
            "close_palette",
            "show_library",
            "copy_action",
            "execute_action",
            "configure_shortcut",
            "toggle_shortcuts",
            "preview_import",
            "commit_import",
            "export_actions",
            "quit_app",
        ]),
    ))
    .expect("Could not build Cue permissions");
}
