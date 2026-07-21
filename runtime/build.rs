//! Build script for the runtime.
//!
//! Two jobs, both feeding `main.rs`:
//!
//! 1. **Embed the front-end.** If `HAWK_FRONTEND_BC` points at a `.thera-bc` file,
//!    copy it to `$OUT_DIR/frontend.thera-bc`; otherwise write a 0-byte stub. The
//!    binary `include_bytes!`s that path: a non-empty blob means "this is the
//!    full `hawk` launcher (runtime + embedded front-end)", an empty blob means
//!    "this is the bare `hawkrt` runtime" (a plain `cargo build`).
//! 2. **Stamp the build.** Capture the short git SHA into `HAWK_BUILD_SHA` so
//!    `--version` can report which revision the binary was built from.

use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());
    let dest = out_dir.join("frontend.thera-bc");

    println!("cargo:rerun-if-env-changed=HAWK_FRONTEND_BC");
    match env::var("HAWK_FRONTEND_BC") {
        Ok(src) if !src.is_empty() => {
            println!("cargo:rerun-if-changed={src}");
            let bytes = std::fs::read(&src)
                .unwrap_or_else(|e| panic!("HAWK_FRONTEND_BC: cannot read {src}: {e}"));
            std::fs::write(&dest, bytes).unwrap();
        }
        _ => {
            // No front-end supplied: a bare runtime. Write an empty stub so the
            // `include_bytes!` in main.rs always resolves.
            std::fs::write(&dest, []).unwrap();
        }
    }

    // The short git SHA (best-effort; "unknown" outside a checkout).
    let sha = Command::new("git")
        .args(["rev-parse", "--short", "HEAD"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "unknown".to_string());
    println!("cargo:rustc-env=HAWK_BUILD_SHA={sha}");
    println!("cargo:rerun-if-changed=.git/HEAD");
}
