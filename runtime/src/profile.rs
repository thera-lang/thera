//! In-VM deterministic profiler, enabled by the `HAWK_PROFILE` environment
//! variable. Unlike the dev-only `native-stats` feature, this is **always
//! compiled** into the runtime — the engine behind `hawk run --profile` — and
//! costs a single predictable branch on the interpreter's hot path when off
//! (`run_loop` reads [`enabled`] once and gates every per-instruction hook).
//!
//! Per Hawk function it reports:
//!   - **call counts** (exact, counted at frame entry),
//!   - **self / inclusive time** via *instruction-budget* sampling: every
//!     `HAWK_PROFILE_INTERVAL` (default 1000) bytecode instructions the live
//!     frame stack is sampled — the running frame counts toward *self*, every
//!     distinct frame on the stack toward *inclusive*,
//!   - **allocations** attributed to the function executing at each `heap::alloc`.
//!
//! Sampling is keyed to instruction count, not wall-clock, so a profile is
//! **deterministic and reproducible** — what the primary audience (coding agents
//! doing before/after comparisons) needs. The flat table is written to stderr at
//! run end; numbers are exact counts, not times, so two runs of the same program
//! produce byte-identical profiles.

use crate::module::Module;
use std::cell::{Cell, RefCell};
use std::sync::LazyLock;

static ON: LazyLock<bool> = LazyLock::new(|| std::env::var_os("HAWK_PROFILE").is_some());

/// Instructions between samples (the budget). Lower = finer self-time
/// distribution at more overhead; fixed per run for reproducibility.
static INTERVAL: LazyLock<u64> = LazyLock::new(|| {
    std::env::var("HAWK_PROFILE_INTERVAL")
        .ok()
        .and_then(|s| s.parse::<u64>().ok())
        .filter(|&n| n > 0)
        .unwrap_or(1000)
});

/// Whether profiling is on. `run_loop` reads this once into a local and gates
/// every hook on it, so a non-profiled run pays one predictable branch.
#[inline(always)]
pub fn enabled() -> bool {
    *ON
}

struct Profile {
    calls: Vec<u64>,        // exact call count, indexed by function
    self_samples: Vec<u64>, // running-frame samples (self time)
    incl_samples: Vec<u64>, // on-stack samples (inclusive time)
    allocs: Vec<u64>,       // allocations attributed to the executing function
    samples: u64,           // total samples taken
}

impl Profile {
    const fn new() -> Self {
        Profile {
            calls: Vec::new(),
            self_samples: Vec::new(),
            incl_samples: Vec::new(),
            allocs: Vec::new(),
            samples: 0,
        }
    }
}

#[inline(always)]
fn bump(v: &mut Vec<u64>, i: usize) {
    if i >= v.len() {
        v.resize(i + 1, 0);
    }
    v[i] += 1;
}

thread_local! {
    static STATE: RefCell<Profile> = const { RefCell::new(Profile::new()) };
    // Hot per-instruction counters as plain Cells (no borrow tracking); the full
    // `STATE` is borrowed only at a sample point (every INTERVAL instructions).
    static INSTRS: Cell<u64> = const { Cell::new(0) };
    static NEXT_SAMPLE: Cell<u64> = const { Cell::new(0) };
    // The function currently executing, for attributing allocations.
    static CURRENT: Cell<usize> = const { Cell::new(0) };
}

/// Count one executed instruction; returns true when this instruction lands on a
/// sampling boundary (the caller then records the live frame stack via [`sample`]).
/// Cheap — two `Cell` updates, no `STATE` borrow — so it is fine per instruction.
#[inline(always)]
pub fn on_instr() -> bool {
    let n = INSTRS.with(|c| {
        let n = c.get() + 1;
        c.set(n);
        n
    });
    if n >= NEXT_SAMPLE.with(Cell::get) {
        NEXT_SAMPLE.with(|c| c.set(n + *INTERVAL));
        true
    } else {
        false
    }
}

/// Record a sample: `active` is the running frame's function (self time) and
/// `on_stack` yields every frame's function from caller to callee (inclusive
/// time, deduplicated so a recursive function counts once per sample).
pub fn sample(active: usize, on_stack: impl Iterator<Item = usize>) {
    STATE.with(|s| {
        let mut p = s.borrow_mut();
        p.samples += 1;
        bump(&mut p.self_samples, active);
        let mut seen: Vec<usize> = Vec::with_capacity(16);
        for f in on_stack {
            if !seen.contains(&f) {
                seen.push(f);
                bump(&mut p.incl_samples, f);
            }
        }
    });
}

/// Record a call to `func` (at frame entry) and make it the current function.
#[inline(always)]
pub fn on_call(func: usize) {
    CURRENT.with(|c| c.set(func));
    STATE.with(|s| bump(&mut s.borrow_mut().calls, func));
}

/// Note the function now executing (on return to a caller frame), for allocation
/// attribution. Does not count a call.
#[inline(always)]
pub fn set_current(func: usize) {
    CURRENT.with(|c| c.set(func));
}

/// Attribute one allocation to the executing function. Called from the single
/// `heap::alloc` chokepoint; returns immediately when profiling is off.
#[inline(always)]
pub fn on_alloc() {
    if !*ON {
        return;
    }
    let f = CURRENT.with(Cell::get);
    STATE.with(|s| bump(&mut s.borrow_mut().allocs, f));
}

/// Print the profile to stderr at run end (a no-op when profiling is off). Rows
/// are sorted by self time descending, then by name, so output is deterministic.
pub fn dump(module: &Module) {
    if !*ON {
        return;
    }
    STATE.with(|s| {
        let p = s.borrow();
        let total_instrs = INSTRS.with(Cell::get);
        let total_allocs: u64 = p.allocs.iter().sum();
        let n = module.functions.len();
        let get = |v: &[u64], i: usize| v.get(i).copied().unwrap_or(0);

        let mut rows: Vec<(u64, u64, u64, u64, &str)> = (0..n)
            .map(|i| {
                (
                    get(&p.self_samples, i),
                    get(&p.incl_samples, i),
                    get(&p.calls, i),
                    get(&p.allocs, i),
                    module.functions[i].name.as_str(),
                )
            })
            .filter(|&(self_s, _, calls, allocs, _)| self_s > 0 || calls > 0 || allocs > 0)
            .collect();
        // Self time desc, then inclusive desc, then name — fully deterministic.
        rows.sort_by(|a, b| b.0.cmp(&a.0).then(b.1.cmp(&a.1)).then(a.4.cmp(b.4)));

        let pct = |x: u64| {
            if p.samples == 0 {
                0.0
            } else {
                100.0 * x as f64 / p.samples as f64
            }
        };
        eprintln!("=== hawk profile (HAWK_PROFILE) ===");
        eprintln!(
            "{total_instrs} instructions, {} samples @ every {}, {total_allocs} allocations",
            p.samples, *INTERVAL,
        );
        eprintln!(
            "{:>7} {:>9} {:>9} {:>11} {:>11}  function",
            "self%", "self", "incl", "calls", "allocs",
        );
        for (self_s, incl_s, calls, allocs, name) in rows.iter().take(40) {
            eprintln!(
                "{:>6.1}% {self_s:>9} {incl_s:>9} {calls:>11} {allocs:>11}  {name}",
                pct(*self_s),
            );
        }
    });
}
