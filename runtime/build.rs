//! Build script for the runtime.
//!
//! One job: **optionally embed the front-end.** If `THERA_FRONTEND_BC` points at a
//! `.thera-bc` file, copy it to `$OUT_DIR/frontend.thera-bc`; otherwise write a
//! 0-byte stub. The binary `include_bytes!`s that path: a non-empty blob means
//! "the front-end is baked in" (a self-contained single-binary release), an empty
//! blob means "bare runtime — load the front-end from a sibling file at runtime"
//! (the default `cargo build`, and how the assembled SDK ships it).
//!
//! Deliberately **not** stamped with the git SHA: the binary is a pure function of
//! its source (+ any embedded blob), so a rebuild is only needed when that source
//! changes — which lets CI cache it across commits. The build revision instead
//! lives in the SDK's `version` file (written by `bin/build_sdk.sh` from git) and
//! is read back by `--version`.

use std::env;
use std::path::PathBuf;

fn main() {
    let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());
    let dest = out_dir.join("frontend.thera-bc");

    println!("cargo:rerun-if-env-changed=THERA_FRONTEND_BC");
    match env::var("THERA_FRONTEND_BC") {
        Ok(src) if !src.is_empty() => {
            println!("cargo:rerun-if-changed={src}");
            let bytes = std::fs::read(&src)
                .unwrap_or_else(|e| panic!("THERA_FRONTEND_BC: cannot read {src}: {e}"));
            std::fs::write(&dest, bytes).unwrap();
        }
        _ => {
            // No front-end supplied: a bare runtime. Write an empty stub so the
            // `include_bytes!` in main.rs always resolves.
            std::fs::write(&dest, []).unwrap();
        }
    }
}
