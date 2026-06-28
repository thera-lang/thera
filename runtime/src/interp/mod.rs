//! The Tier-0 evaluator.
//!
//! [`Vm::run_loop`] drives an **explicit call-frame stack**: each [`Frame`] owns
//! its operand stack, locals, and program counter, and one loop dispatches the
//! instruction stream until the frame stack empties. A `pc` (program counter)
//! indexes the running frame's instruction vec; the `jump` family redirects it.
//!
//! `Instr::Call` pushes a new frame and `Instr::Return` pops one — calls do
//! **not** recurse through the Rust stack, so deep Hawk recursion is bounded by
//! the heap (the frame `Vec`), not the host stack. Keeping every active frame in
//! one `Vec` is also what lets a precise GC enumerate the roots, and it is the
//! structure fibers will pause/resume.

use std::cell::{Cell, RefCell};
use std::collections::VecDeque;
use std::io::Write;

use crate::heap;
use crate::instr::Instr;
use crate::module::{ENUM_DISPATCH_BASE, Function, Module};
use crate::value::{Obj, TAG_OK, TAG_SOME, TY_OPTION, TY_RESULT, Value};

/// A runtime fault that aborts execution (see docs/language.md, "Runtime
/// faults"). Variants that describe malformed bytecode ([`Trap::Bug`]) indicate
/// a producer error rather than a program-level fault; valid bytecode never
/// raises them.
#[derive(Clone, Debug, PartialEq)]
pub enum Trap {
    /// Integer or float division/modulo by zero.
    DivByZero,
    /// List index outside `0..len` (the faulting case of `list[i]`).
    IndexOutOfBounds { index: i64, len: usize },
    /// Map indexed with `map[key]` where `key` is absent. `key` is a short,
    /// human-readable rendering of the key (strings quoted), for the message.
    MissingKey { key: String },
    /// `channel.send` on a channel that has been closed (a program contract
    /// violation, like sending on a closed Go channel).
    ClosedChannel,
    /// The bytecode was malformed (stack underflow, type mismatch, bad slot).
    /// Valid bytecode from a correct producer never triggers this.
    Bug(String),
}

/// The human-readable fault message shown to the user (`hawk: trap: <this>`).
/// The format is specified in docs/language.md, "Runtime faults". This is
/// distinct from the `Debug` form, which the runtime's own tests still use.
impl std::fmt::Display for Trap {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Trap::DivByZero => write!(f, "division by zero"),
            Trap::IndexOutOfBounds { index, len } => {
                write!(
                    f,
                    "index out of range: the index is {index} but the length is {len}"
                )
            }
            Trap::MissingKey { key } => write!(f, "key not found: {key}"),
            Trap::ClosedChannel => write!(f, "send on a closed channel"),
            Trap::Bug(msg) => write!(f, "internal error (malformed bytecode): {msg}"),
        }
    }
}

pub(crate) fn bug(msg: impl Into<String>) -> Trap {
    Trap::Bug(msg.into())
}

mod natives;
pub use natives::{
    NATIVE_EQ, NATIVE_INT_TO_STRING, NATIVE_LIST_GET, NATIVE_LIST_INDEX, NATIVE_LIST_LEN,
    NATIVE_LIST_SET, NATIVE_MAP_GET, NATIVE_MAP_HAS, NATIVE_MAP_INDEX, NATIVE_MAP_LEN,
    NATIVE_MAP_NEW, NATIVE_MAP_SET, NATIVE_PRINT, NATIVE_PRINTLN, NATIVE_STR_CONCAT, NativeFn,
    default_natives, native_index, native_name, set_program_args,
};

/// The interpreter's execution context: where output goes and what native
/// functions are available. Later increments grow this with the heap/GC and the
/// fiber scheduler.
pub struct Vm<'a> {
    out: &'a mut dyn Write,
    natives: Vec<NativeFn>,
    /// The explicit call-frame stack, shared across (re-entrant) interpreter
    /// calls so a precise GC can enumerate *every* active frame's values as
    /// roots from one place. A nested `run_loop` (e.g. structural `debug`
    /// invoking a user impl) pushes onto and pops back from this same stack.
    /// Each [`Frame`] holds only metadata (`func`/`pc`/`base`); the values live
    /// in `vstack`.
    frames: Vec<Frame>,
    /// The single value stack shared by every active frame of the running fiber:
    /// each frame's locals followed by its operands, laid end to end (see
    /// [`Frame`]). One contiguous `Vec` means a call passes its arguments in
    /// place — no per-call allocation — and the precise GC roots the whole fiber
    /// by scanning this one slice. Every slot is a live value (locals are
    /// `Unit`-initialised, operands are always valid), so the entire `vstack` is
    /// the fiber's root set.
    vstack: Vec<Value>,
}

/// One activation record on the call-frame stack: the running function, its
/// program counter, and the base index of its slot region in the shared value
/// stack ([`Vm::vstack`]). The frame's locals occupy `vstack[base .. base +
/// local_count]`; its operand stack is everything above that — up to the next
/// frame's `base`, or the stack top for the active frame. Locals and operands
/// thus share one contiguous `Vec` across every active frame, so a call neither
/// allocates nor copies its arguments: they are already on top of the stack and
/// become the callee's leading locals in place.
struct Frame {
    func: usize,
    pc: usize,
    base: usize,
}

/// An RAII guard that suspends garbage collection for its lifetime (see
/// [`heap::pause_gc`]). Pausing nests; the guard resumes on drop, so it is safe
/// across `?` and early returns.
struct GcPause;

impl GcPause {
    fn new() -> Self {
        heap::pause_gc();
        GcPause
    }
}

impl Drop for GcPause {
    fn drop(&mut self) {
        heap::resume_gc();
    }
}

/// Run `module`'s function at index `func` with `args`, writing output to
/// stdout. Convenience over [`Vm`].
pub fn run(module: &Module, func: usize, args: &[Value]) -> Result<Value, Trap> {
    let mut out = std::io::stdout();
    let result = Vm::new(&mut out).run(module, func, args);
    dump_native_stats();
    crate::profile::dump(module);
    result
}

/// The result of running a fiber to a suspension point. `Done` carries the entry
/// frame's value; `Parked` means a native suspended the fiber — its whole frame
/// stack is left on `self.frames` for the scheduler — tagged with how to resume.
enum RunOutcome {
    Done(Value),
    Parked(ParkRequest),
}

/// How a parked fiber resumes — set by the native that suspended it.
#[derive(Clone, Copy)]
enum ParkRequest {
    /// The op could not complete (its resource isn't ready): the fiber blocks
    /// until woken, and the `call.native` re-executes on resume — by which point
    /// the resource is ready (`join`; later `receive`/`sleep`). The native is
    /// written to be idempotent across that retry.
    BlockRetry,
    /// The op completed; the fiber merely cedes the thread, stays runnable, and
    /// resumes right after the call (`yield`).
    YieldReady,
}

// A native suspends the running fiber by setting `PARK` — the same
// flag-then-check-at-a-safepoint shape as the GC's `GC_PENDING`. `run_loop`
// reads it immediately after a native returns.
thread_local! {
    static PARK: Cell<Option<ParkRequest>> = const { Cell::new(None) };
}

/// Block the running fiber until woken, re-running this native on resume. A
/// blocking native (`join`) calls this when its resource isn't ready.
pub(super) fn park_block_retry() {
    PARK.set(Some(ParkRequest::BlockRetry));
}

/// Yield the running fiber cooperatively — it stays runnable. Called by `yield`.
pub(super) fn park_yield_ready() {
    PARK.set(Some(ParkRequest::YieldReady));
}

fn take_park() -> Option<ParkRequest> {
    PARK.take()
}

// --- the cooperative fiber scheduler ---

/// A cooperative fiber: its saved state. The running fiber's frames live in the
/// `Vm` (`self.frames` + the active frame); a fiber that is not running keeps its
/// call stack here.
struct Fiber {
    state: FiberState,
}

enum FiberState {
    /// Spawned but not yet started: the `() -> T` closure to invoke. The initial
    /// frame is built lazily on first run (the scheduler has the `Module`).
    NotStarted(Value),
    /// A started fiber's saved state: its value stack and its frame stack
    /// (bottom-first; the top frame is the active one while it runs). Each fiber
    /// owns an independent `vstack` whose frame bases start at 0.
    Suspended {
        vstack: Vec<Value>,
        frames: Vec<Frame>,
    },
    /// Currently executing — its frames are in the `Vm`, not here.
    Running,
    /// Finished, with its return value (awaited by `join`).
    Done(Value),
}

/// The single-threaded cooperative scheduler: one fiber runs at a time; a
/// blocking native parks the running fiber and the driver picks the next ready
/// one. The ready queue is FIFO, so scheduling is deterministic.
struct Scheduler {
    fibers: Vec<Fiber>,     // indexed by fiber id; never compacted, so ids stay stable
    ready: VecDeque<usize>, // runnable fiber ids
    blocked: Vec<usize>,    // parked on a resource; woken en masse on any progress
    channels: Vec<Chan>,    // indexed by channel id
}

/// A bounded channel: a FIFO buffer of values plus a closed flag. A `send` blocks
/// (parks) when the buffer is full; a `receive` blocks when it is empty, and
/// yields `None` once the channel is closed and drained.
struct Chan {
    buffer: VecDeque<Value>,
    capacity: usize,
    closed: bool,
}

/// Outcome of a non-blocking `chan_send` attempt.
pub(super) enum SendOutcome {
    Sent,
    Full,
    Closed,
}

/// Outcome of a non-blocking `chan_receive` attempt.
pub(super) enum RecvOutcome {
    Got(Value),
    Empty,
    Drained,
}

const MAIN_FIBER: usize = 0;

impl Scheduler {
    fn new() -> Self {
        Scheduler {
            fibers: Vec::new(),
            ready: VecDeque::new(),
            blocked: Vec::new(),
            channels: Vec::new(),
        }
    }

    /// Move every blocked fiber back to the ready queue, so each re-checks its
    /// resource on resume. Coarse (no per-resource waiter lists), but correct.
    fn wake_all(&mut self) {
        self.ready.extend(self.blocked.drain(..));
    }

    /// Create a channel buffering up to `capacity` (clamped to ≥ 1 — true
    /// 0-capacity rendezvous is a later refinement), returning its id.
    fn channel_new(&mut self, capacity: usize) -> usize {
        let id = self.channels.len();
        self.channels.push(Chan {
            buffer: VecDeque::new(),
            capacity: capacity.max(1),
            closed: false,
        });
        id
    }

    /// Try to send `value` into channel `id` without blocking; wakes blocked
    /// fibers on success so a waiting receiver re-checks.
    fn chan_send(&mut self, id: usize, value: Value) -> SendOutcome {
        let ch = &mut self.channels[id];
        let outcome = if ch.closed {
            SendOutcome::Closed
        } else if ch.buffer.len() < ch.capacity {
            ch.buffer.push_back(value);
            SendOutcome::Sent
        } else {
            SendOutcome::Full
        };
        if matches!(outcome, SendOutcome::Sent) {
            self.wake_all();
        }
        outcome
    }

    /// Try to receive from channel `id` without blocking; wakes blocked fibers on
    /// success so a waiting sender re-checks.
    fn chan_receive(&mut self, id: usize) -> RecvOutcome {
        let ch = &mut self.channels[id];
        let outcome = if let Some(v) = ch.buffer.pop_front() {
            RecvOutcome::Got(v)
        } else if ch.closed {
            RecvOutcome::Drained
        } else {
            RecvOutcome::Empty
        };
        if matches!(outcome, RecvOutcome::Got(_)) {
            self.wake_all();
        }
        outcome
    }

    /// Close channel `id`; receivers drain the buffer then get `None`.
    fn chan_close(&mut self, id: usize) {
        self.channels[id].closed = true;
        self.wake_all();
    }

    /// Spawn a fiber to run `closure`, returning its id. Enqueued runnable.
    fn spawn(&mut self, closure: Value) -> usize {
        let id = self.fibers.len();
        self.fibers.push(Fiber {
            state: FiberState::NotStarted(closure),
        });
        self.ready.push_back(id);
        id
    }

    /// The result of fiber `id`, if it has finished.
    fn result(&self, id: usize) -> Option<Value> {
        match self.fibers.get(id).map(|f| &f.state) {
            Some(FiberState::Done(v)) => Some(*v),
            _ => None,
        }
    }

    /// Record that `id` finished with `value`, and wake everyone blocked (coarse
    /// but correct — a completion is the only thing a blocked `join` waits on;
    /// per-resource waiter lists arrive with channels).
    fn complete(&mut self, id: usize, value: Value) {
        self.fibers[id].state = FiberState::Done(value);
        self.wake_all();
    }

    /// Save a suspended fiber's stack and route it per its park request.
    fn park(&mut self, id: usize, vstack: Vec<Value>, frames: Vec<Frame>, req: ParkRequest) {
        self.fibers[id].state = FiberState::Suspended { vstack, frames };
        match req {
            ParkRequest::YieldReady => self.ready.push_back(id),
            ParkRequest::BlockRetry => self.blocked.push(id),
        }
    }
}

thread_local! {
    static SCHEDULER: RefCell<Scheduler> = RefCell::new(Scheduler::new());
}

/// Spawn a fiber running `closure`; returns its id. Called by the `fiber_spawn`
/// native.
pub(super) fn sched_spawn(closure: Value) -> usize {
    SCHEDULER.with(|s| s.borrow_mut().spawn(closure))
}

/// The result of fiber `id` if finished, else `None`. Called by the `fiber_join`
/// native.
pub(super) fn sched_result(id: usize) -> Option<Value> {
    SCHEDULER.with(|s| s.borrow().result(id))
}

/// Create a channel buffering up to `capacity`; returns its id. (`channel_new`.)
pub(super) fn sched_channel_new(capacity: usize) -> usize {
    SCHEDULER.with(|s| s.borrow_mut().channel_new(capacity))
}

/// Non-blocking send into channel `id`. (`channel_send`.)
pub(super) fn sched_chan_send(id: usize, value: Value) -> SendOutcome {
    SCHEDULER.with(|s| s.borrow_mut().chan_send(id, value))
}

/// Non-blocking receive from channel `id`. (`channel_receive`.)
pub(super) fn sched_chan_receive(id: usize) -> RecvOutcome {
    SCHEDULER.with(|s| s.borrow_mut().chan_receive(id))
}

/// Close channel `id`. (`channel_close`.)
pub(super) fn sched_chan_close(id: usize) {
    SCHEDULER.with(|s| s.borrow_mut().chan_close(id));
}

/// Add every non-running fiber's live values to `roots` (GC), plus the values
/// buffered in channels. The running fiber's frames are rooted separately, from
/// the `Vm`.
fn gather_scheduler_roots(roots: &mut Vec<Value>) {
    SCHEDULER.with(|s| {
        let s = s.borrow();
        for fiber in &s.fibers {
            match &fiber.state {
                FiberState::NotStarted(c) => roots.push(*c),
                FiberState::Done(v) => roots.push(*v),
                FiberState::Suspended { vstack, .. } => {
                    // Every slot of a suspended fiber's value stack is a live root.
                    roots.extend(vstack.iter().copied());
                }
                FiberState::Running => {}
            }
        }
        for ch in &s.channels {
            roots.extend(ch.buffer.iter().copied());
        }
    });
}

// --- native-call profiling probe (the `native-stats` feature) ---
//
// A coarse per-native call counter, to see which natives dominate a workload
// without a sampling profiler. Compiled out entirely unless the `native-stats`
// feature is on, so the shipping interpreter pays nothing; when on, it prints
// the counts (descending) to stderr at the end of a run if HAWK_NATIVE_STATS is
// set in the environment.

#[cfg(feature = "native-stats")]
mod native_stats {
    use super::natives;

    static ON: std::sync::LazyLock<bool> =
        std::sync::LazyLock::new(|| std::env::var_os("HAWK_NATIVE_STATS").is_some());

    thread_local! {
        static CALLS: std::cell::RefCell<Vec<u64>> = const { std::cell::RefCell::new(Vec::new()) };
    }

    pub(super) fn count(index: u32) {
        if *ON {
            CALLS.with(|c| {
                let mut v = c.borrow_mut();
                let i = index as usize;
                if i >= v.len() {
                    v.resize(i + 1, 0);
                }
                v[i] += 1;
            });
        }
    }

    pub(super) fn dump() {
        if !*ON {
            return;
        }
        CALLS.with(|c| {
            let v = c.borrow();
            let mut rows: Vec<(u64, &str)> = v
                .iter()
                .enumerate()
                .filter(|&(_, &n)| n > 0)
                .map(|(i, &n)| (n, natives::native_name(i as u32).unwrap_or("?")))
                .collect();
            rows.sort_by(|a, b| b.0.cmp(&a.0));
            let total: u64 = rows.iter().map(|(n, _)| n).sum();
            eprintln!("--- native call counts (total {total}) ---");
            for (n, name) in rows.iter().take(30) {
                eprintln!("{n:>12}  {name}");
            }
        });
    }
}

#[inline(always)]
fn count_native(_index: u32) {
    #[cfg(feature = "native-stats")]
    native_stats::count(_index);
}

#[inline(always)]
fn dump_native_stats() {
    #[cfg(feature = "native-stats")]
    native_stats::dump();
}

/// Evaluate a bare instruction stream in a synthetic single-function module
/// (so `call` is unavailable) and discard output. `locals` seeds the frame's
/// leading slots. A convenience for testing snippets.
pub fn eval(code: &[Instr], locals: &[Value]) -> Result<Value, Trap> {
    let n = locals.len() as u16;
    let module = Module::new(vec![Function::new("<eval>", n, n, code.to_vec())]);
    let mut sink = std::io::sink();
    Vm::new(&mut sink).call(&module, 0, locals.to_vec())
}

impl<'a> Vm<'a> {
    /// Create a VM that writes output to `out`, with the default native table.
    pub fn new(out: &'a mut dyn Write) -> Self {
        Self {
            out,
            natives: default_natives(),
            frames: Vec::new(),
            // Reserve a generous slab so the value stack rarely reallocates mid-run.
            // Growth is safe regardless (no `Value` holds an interior pointer into
            // it), but pre-reserving keeps the hot path allocation-free.
            vstack: Vec::with_capacity(4096),
        }
    }

    /// Run `module`'s function at index `func` with `args` as the **main fiber**,
    /// driving the cooperative scheduler until it returns. The program ends when
    /// the main fiber returns (Go semantics); any fibers it spawned and left
    /// running are abandoned. The thread-local scheduler is reset around the run,
    /// so nothing leaks into a later `eval`/`call`.
    pub fn run(&mut self, module: &Module, func: usize, args: &[Value]) -> Result<Value, Trap> {
        SCHEDULER.with(|s| {
            let mut s = s.borrow_mut();
            *s = Scheduler::new();
            // The main fiber is id 0, currently running (its frames are in the Vm).
            s.fibers.push(Fiber {
                state: FiberState::Running,
            });
        });
        let result = self.drive(module, func, args);
        SCHEDULER.with(|s| *s.borrow_mut() = Scheduler::new());
        result
    }

    /// The scheduler loop. Runs the current fiber to its next suspension; on a
    /// park, saves its stack and switches to the next ready fiber; on completion,
    /// records the result (waking blocked joiners) and — for the main fiber —
    /// returns. A blocking park with no runnable fiber is a deadlock.
    fn drive(&mut self, module: &Module, func: usize, args: &[Value]) -> Result<Value, Trap> {
        let mut current = MAIN_FIBER;
        let mut active = Self::push_frame(&mut self.vstack, module, func, args)?;
        loop {
            // `base_depth` is 0: run the fiber until its *whole* stack unwinds.
            match self.run_loop(module, active, 0)? {
                RunOutcome::Done(value) => {
                    SCHEDULER.with(|s| s.borrow_mut().complete(current, value));
                    if current == MAIN_FIBER {
                        return Ok(value);
                    }
                }
                RunOutcome::Parked(req) => {
                    // The whole fiber state — its frame stack (the active frame was
                    // pushed onto `self.frames` before parking) and its value stack
                    // — is handed to the scheduler to hold until resumed.
                    let frames = std::mem::take(&mut self.frames);
                    let vstack = std::mem::take(&mut self.vstack);
                    SCHEDULER.with(|s| s.borrow_mut().park(current, vstack, frames, req));
                }
            }
            // Pick the next runnable fiber (self.frames is empty here).
            match self.next_ready(module)? {
                Some((id, frame)) => {
                    current = id;
                    active = frame;
                }
                None => {
                    // Nothing runnable. If fibers are still blocked, it's a
                    // deadlock; otherwise everything finished (main already
                    // returned above, so this is a spawned-only tail).
                    let blocked = SCHEDULER.with(|s| !s.borrow().blocked.is_empty());
                    return if blocked {
                        Err(bug("all fibers blocked (deadlock)"))
                    } else {
                        Ok(Value::Unit)
                    };
                }
            }
        }
    }

    /// Dequeue the next ready fiber and load it: build its initial frame from the
    /// spawned closure, or restore its saved stack (the top becomes the active
    /// frame, the rest go to `self.frames`). `self.frames` must be empty on entry.
    fn next_ready(&mut self, module: &Module) -> Result<Option<(usize, Frame)>, Trap> {
        let Some(id) = SCHEDULER.with(|s| s.borrow_mut().ready.pop_front()) else {
            return Ok(None);
        };
        let state = SCHEDULER
            .with(|s| std::mem::replace(&mut s.borrow_mut().fibers[id].state, FiberState::Running));
        // `self.vstack` is empty here: the previous fiber's was taken on park, or
        // unwound to empty on completion.
        let active = match state {
            FiberState::NotStarted(closure) => {
                let (func, locals) = closure_parts(&closure)?;
                Self::push_frame(&mut self.vstack, module, func as usize, &locals)?
            }
            FiberState::Suspended { vstack, mut frames } => {
                self.vstack = vstack;
                let active = frames
                    .pop()
                    .ok_or_else(|| bug("resumed a fiber with an empty stack"))?;
                self.frames = frames;
                active
            }
            FiberState::Running | FiberState::Done(_) => {
                return Err(bug("scheduled a running or finished fiber"));
            }
        };
        Ok(Some((id, active)))
    }

    /// Enter `func` whose `argc` arguments are **already** the top `argc` slots of
    /// `vstack` (the in-loop call path: a caller leaves its args on the operand
    /// stack and they become the callee's leading locals in place), padding the
    /// remaining locals with `Unit`. Takes no `self` — so a `run_loop` arm can
    /// build a frame while `self.frames`/`self.vstack` are borrowed.
    fn enter_frame(
        vstack: &mut Vec<Value>,
        module: &Module,
        func: usize,
        argc: usize,
    ) -> Result<Frame, Trap> {
        let f = module
            .functions
            .get(func)
            .ok_or_else(|| bug(format!("call: no function at index {func}")))?;
        if argc != f.param_count as usize {
            return Err(bug(format!(
                "call: function '{}' expects {} args, got {}",
                f.name, f.param_count, argc
            )));
        }
        let base = vstack
            .len()
            .checked_sub(argc)
            .ok_or_else(|| bug("call: operand stack underflow"))?;
        vstack.resize(base + f.local_count as usize, Value::Unit);
        Ok(Frame { func, pc: 0, base })
    }

    /// Push `args` onto `vstack` and enter `func` over them — the entry path
    /// (fiber start, re-entrant `call`, top-level `drive`), where the arguments
    /// come from a Rust slice rather than already sitting on the stack.
    fn push_frame(
        vstack: &mut Vec<Value>,
        module: &Module,
        func: usize,
        args: &[Value],
    ) -> Result<Frame, Trap> {
        vstack.extend_from_slice(args);
        Self::enter_frame(vstack, module, func, args.len())
    }

    /// Build a frame for `func` and run it to completion. For re-entrant
    /// (nested) and `eval` use, where suspension is not allowed: a park here is a
    /// bug, since only the top-level scheduler driver can resume a fiber. This is
    /// the "park only at the top of `run_loop`" guard — a blocking native must
    /// never be reached from inside a nested interpreter re-entry (e.g. the
    /// structural `debug`/`display` fallback).
    fn call(&mut self, module: &Module, func: usize, args: Vec<Value>) -> Result<Value, Trap> {
        let frame = Self::push_frame(&mut self.vstack, module, func, &args)?;
        // Run just this frame's subtree: stop when it returns past the current
        // depth (rather than unwinding the whole fiber, as the scheduler does).
        let base_depth = self.frames.len();
        match self.run_loop(module, frame, base_depth)? {
            RunOutcome::Done(value) => Ok(value),
            RunOutcome::Parked(_) => Err(bug("fiber parked in a non-schedulable context")),
        }
    }

    /// The interpreter loop over the **explicit call-frame stack** (`self.frames`,
    /// shared across re-entrant calls). Each [`Frame`] owns its operand stack and
    /// locals, so every active frame's values stay reachable as precise-GC roots,
    /// and calls no longer recurse through the Rust stack — `Instr::Call`/`Return`
    /// push and pop frames here. Runs until the `initial` frame returns (the
    /// stack drops back to the depth it was pushed at), so a nested invocation
    /// resumes its caller's loop. Returns [`RunOutcome::Done`] with the entry
    /// frame's value, or [`RunOutcome::Parked`] when a native suspended the fiber
    /// (the frame stack is left on `self.frames` for the driver to resume).
    fn run_loop(
        &mut self,
        module: &Module,
        initial: Frame,
        base_depth: usize,
    ) -> Result<RunOutcome, Trap> {
        let mut frame = initial;
        let mut code = &module.functions[frame.func].code;
        // Hoist the value stack and frame stack into owned locals for the loop, so
        // the hot per-instruction accesses (operand push/pop, local load/store) hit
        // a local `Vec` directly instead of indirecting through the `&mut self`
        // pointer every time. They are handed back to `self` only at the rare exit
        // and re-entry points (return/park, and the structural-fallback call below).
        let mut vstack = std::mem::take(&mut self.vstack);
        let mut frames = std::mem::take(&mut self.frames);

        // Profiling is read once here; every per-instruction/frame hook below is
        // gated on this local, so a non-profiled run pays one predictable branch.
        let profiling = crate::profile::enabled();
        if profiling {
            crate::profile::set_current(frame.func);
        }

        macro_rules! poll_gc {
            () => {
                // Gather roots only when a collection will actually run. Every slot
                // of this fiber's value stack is a live root (locals + operands of
                // every active frame); the roots also include every *other* fiber's
                // value stack, held in the scheduler — so a value live only in a
                // parked fiber survives.
                if heap::should_collect() {
                    let mut roots: Vec<Value> = vstack.clone();
                    gather_scheduler_roots(&mut roots);
                    heap::collect(roots.into_iter());
                }
            };
        }

        // Hand the hoisted stacks back to `self` and return — at every `run_loop`
        // exit, so the caller (the scheduler driver, or a re-entrant `call`) sees
        // the final fiber state in `self`.
        macro_rules! exit {
            ($outcome:expr) => {{
                self.vstack = vstack;
                self.frames = frames;
                return Ok($outcome);
            }};
        }

        loop {
            // Instruction-budget sampling: at each interval, record the live
            // frame stack (running frame -> self, every frame -> inclusive).
            if profiling && crate::profile::on_instr() {
                crate::profile::sample(
                    frame.func,
                    frames
                        .iter()
                        .map(|f| f.func)
                        .chain(std::iter::once(frame.func)),
                );
            }
            let instr = code
                .get(frame.pc)
                .ok_or_else(|| bug("pc ran off the end of the instruction stream"))?;
            frame.pc += 1; // advance; jumps overwrite below

            match instr {
                // --- constants ---
                Instr::ConstInt(n) => vstack.push(Value::Int(*n)),
                Instr::ConstDouble(x) => vstack.push(Value::Double(*x)),
                Instr::ConstBool(b) => vstack.push(Value::Bool(*b)),
                Instr::ConstUnit => vstack.push(Value::Unit),
                Instr::ConstStr(s) => {
                    poll_gc!();
                    // A string literal is interned: allocated once, then reused
                    // allocation-free on every later execution (a `match` over the
                    // 24 keyword literals, say, no longer allocates per call).
                    vstack.push(heap::intern_str(s));
                }

                // --- locals (slots `[base, base + local_count)` of the vstack) ---
                Instr::Load(slot) => {
                    let v = *vstack
                        .get(frame.base + *slot as usize)
                        .ok_or_else(|| bug(format!("load: slot {slot} out of range")))?;
                    vstack.push(v);
                }
                Instr::Store(slot) => {
                    let v = pop(&mut vstack)?;
                    *vstack
                        .get_mut(frame.base + *slot as usize)
                        .ok_or_else(|| bug(format!("store: slot {slot} out of range")))? = v;
                }

                // --- integer arithmetic (wrapping) ---
                Instr::AddI64 => {
                    let (a, b) = pop_two_int(&mut vstack)?;
                    vstack.push(Value::Int(a.wrapping_add(b)));
                }
                Instr::SubI64 => {
                    let (a, b) = pop_two_int(&mut vstack)?;
                    vstack.push(Value::Int(a.wrapping_sub(b)));
                }
                Instr::MulI64 => {
                    let (a, b) = pop_two_int(&mut vstack)?;
                    vstack.push(Value::Int(a.wrapping_mul(b)));
                }
                Instr::DivI64 => {
                    let (a, b) = pop_two_int(&mut vstack)?;
                    if b == 0 {
                        return Err(Trap::DivByZero);
                    }
                    vstack.push(Value::Int(a.wrapping_div(b)));
                }
                Instr::ModI64 => {
                    let (a, b) = pop_two_int(&mut vstack)?;
                    if b == 0 {
                        return Err(Trap::DivByZero);
                    }
                    vstack.push(Value::Int(a.wrapping_rem(b)));
                }
                Instr::NegI64 => {
                    let a = pop_int(&mut vstack)?;
                    vstack.push(Value::Int(a.wrapping_neg()));
                }

                // --- integer bitwise ---
                Instr::AndI64 => {
                    let (a, b) = pop_two_int(&mut vstack)?;
                    vstack.push(Value::Int(a & b));
                }
                Instr::OrI64 => {
                    let (a, b) = pop_two_int(&mut vstack)?;
                    vstack.push(Value::Int(a | b));
                }
                Instr::XorI64 => {
                    let (a, b) = pop_two_int(&mut vstack)?;
                    vstack.push(Value::Int(a ^ b));
                }
                Instr::BNotI64 => {
                    let a = pop_int(&mut vstack)?;
                    vstack.push(Value::Int(!a));
                }
                // Shift amount is masked to 0..=63 (the low 6 bits), so a shift is
                // always well-defined (matches Java/JS/Dart).
                Instr::ShlI64 => {
                    let (a, b) = pop_two_int(&mut vstack)?;
                    vstack.push(Value::Int(a.wrapping_shl((b & 63) as u32)));
                }
                Instr::ShrI64 => {
                    let (a, b) = pop_two_int(&mut vstack)?;
                    vstack.push(Value::Int(a.wrapping_shr((b & 63) as u32)));
                }
                Instr::UShrI64 => {
                    let (a, b) = pop_two_int(&mut vstack)?;
                    vstack.push(Value::Int(((a as u64) >> ((b & 63) as u32)) as i64));
                }

                // --- float arithmetic ---
                Instr::AddF64 => {
                    let (a, b) = pop_two_double(&mut vstack)?;
                    vstack.push(Value::Double(a + b));
                }
                Instr::SubF64 => {
                    let (a, b) = pop_two_double(&mut vstack)?;
                    vstack.push(Value::Double(a - b));
                }
                Instr::MulF64 => {
                    let (a, b) = pop_two_double(&mut vstack)?;
                    vstack.push(Value::Double(a * b));
                }
                Instr::DivF64 => {
                    let (a, b) = pop_two_double(&mut vstack)?;
                    vstack.push(Value::Double(a / b));
                }
                Instr::NegF64 => {
                    let a = pop_double(&mut vstack)?;
                    vstack.push(Value::Double(-a));
                }

                // --- integer comparison ---
                Instr::EqI64 => cmp_int(&mut vstack, |a, b| a == b)?,
                Instr::NeI64 => cmp_int(&mut vstack, |a, b| a != b)?,
                Instr::LtI64 => cmp_int(&mut vstack, |a, b| a < b)?,
                Instr::LeI64 => cmp_int(&mut vstack, |a, b| a <= b)?,
                Instr::GtI64 => cmp_int(&mut vstack, |a, b| a > b)?,
                Instr::GeI64 => cmp_int(&mut vstack, |a, b| a >= b)?,

                // --- float comparison ---
                Instr::EqF64 => cmp_double(&mut vstack, |a, b| a == b)?,
                Instr::NeF64 => cmp_double(&mut vstack, |a, b| a != b)?,
                Instr::LtF64 => cmp_double(&mut vstack, |a, b| a < b)?,
                Instr::LeF64 => cmp_double(&mut vstack, |a, b| a <= b)?,
                Instr::GtF64 => cmp_double(&mut vstack, |a, b| a > b)?,
                Instr::GeF64 => cmp_double(&mut vstack, |a, b| a >= b)?,

                // --- boolean ---
                Instr::Not => {
                    let b = pop_bool(&mut vstack)?;
                    vstack.push(Value::Bool(!b));
                }

                // --- conversions ---
                Instr::I64ToF64 => {
                    let a = pop_int(&mut vstack)?;
                    vstack.push(Value::Double(a as f64));
                }
                Instr::F64ToI64 => {
                    let a = pop_double(&mut vstack)?;
                    vstack.push(Value::Int(a as i64));
                }

                // --- stack manipulation ---
                Instr::Pop => {
                    pop(&mut vstack)?;
                }
                Instr::Dup => {
                    let v = *vstack.last().ok_or_else(|| bug("dup: empty stack"))?;
                    vstack.push(v);
                }

                // --- calls ---
                Instr::Call { func, argc } => {
                    poll_gc!();
                    // The `argc` arguments already sit on top of the operand stack;
                    // they become the callee's leading locals in place — no split,
                    // no allocation.
                    let callee =
                        Self::enter_frame(&mut vstack, module, *func as usize, *argc as usize)?;
                    frames.push(std::mem::replace(&mut frame, callee));
                    code = &module.functions[frame.func].code;
                    if profiling {
                        crate::profile::on_call(frame.func);
                    }
                }
                Instr::CallNative { native, argc } => {
                    poll_gc!();
                    let argc = *argc as usize;
                    let base = vstack
                        .len()
                        .checked_sub(argc)
                        .ok_or_else(|| bug("call.native: operand stack underflow"))?;
                    let f = *self
                        .natives
                        .get(*native as usize)
                        .ok_or_else(|| bug(format!("call.native: no native at index {native}")))?;
                    count_native(*native);
                    // Pass the arguments as a slice of the operand stack rather
                    // than splitting them into a fresh Vec: with millions of
                    // tiny native calls (`len`, `eq`), that per-call allocation
                    // dominated. Natives never touch `vstack`, and leaving
                    // the args in place keeps them GC-rooted across the call.
                    let ret = f(&mut *self.out, &vstack[base..])?;
                    match take_park() {
                        None => {
                            vstack.truncate(base);
                            vstack.push(ret);
                        }
                        Some(req @ ParkRequest::BlockRetry) => {
                            // The op's resource isn't ready. Rewind to re-execute
                            // this `call.native` on resume — the args are still on
                            // the operand stack, the placeholder return is
                            // discarded, and the native runs again (ready by then).
                            // The whole frame stack stays on `frames` as the
                            // parked fiber's saved state.
                            frame.pc -= 1;
                            frames.push(frame);
                            exit!(RunOutcome::Parked(req));
                        }
                        Some(req @ ParkRequest::YieldReady) => {
                            // The op completed; resume right after the call.
                            vstack.truncate(base);
                            vstack.push(ret);
                            frames.push(frame);
                            exit!(RunOutcome::Parked(req));
                        }
                    }
                }
                Instr::CallIndirect { argc } => {
                    poll_gc!();
                    let argc = *argc as usize;
                    // Beneath the `argc` arguments sits the closure value. The
                    // callee's locals are `[captures..., args...]`: replace the
                    // closure slot in place with its captures, shifting the args up.
                    let closure_slot = vstack
                        .len()
                        .checked_sub(argc + 1)
                        .ok_or_else(|| bug("call.indirect: operand stack underflow"))?;
                    let (func, captures) = closure_parts(&vstack[closure_slot])?;
                    let total = captures.len() + argc;
                    vstack.splice(closure_slot..closure_slot + 1, captures);
                    let callee = Self::enter_frame(&mut vstack, module, func as usize, total)?;
                    frames.push(std::mem::replace(&mut frame, callee));
                    code = &module.functions[frame.func].code;
                    if profiling {
                        crate::profile::on_call(frame.func);
                    }
                }
                Instr::CallVirtual { selector, argc } => {
                    poll_gc!();
                    let argc = *argc as usize;
                    let base = vstack
                        .len()
                        .checked_sub(argc)
                        .ok_or_else(|| bug("call.virtual: operand stack underflow"))?;
                    // The receiver is the first argument; its concrete type id
                    // selects the implementation. A miss (no row, or a receiver
                    // with no dispatch id — primitives, strings, collections)
                    // falls back to the built-in interfaces' structural forms.
                    let recv = vstack[base];
                    let target =
                        dispatch_type_id(&recv).and_then(|ty| module.dispatch_target(ty, selector));
                    match target {
                        Some(func) => {
                            // Args in place become the callee's locals.
                            let callee =
                                Self::enter_frame(&mut vstack, module, func as usize, argc)?;
                            frames.push(std::mem::replace(&mut frame, callee));
                            code = &module.functions[frame.func].code;
                            if profiling {
                                crate::profile::on_call(frame.func);
                            }
                        }
                        // The fallback may re-enter the interpreter (a nested
                        // `debug`), which takes `self.vstack`/`self.frames` again —
                        // so hand the hoisted stacks back to `self` first, run the
                        // (GC-paused) fallback over a copy of the args, then take the
                        // stacks back. The active frame's values stay rooted in the
                        // stack throughout; the copied args are covered by the pause.
                        None => {
                            let args: Vec<Value> = vstack[base..].to_vec();
                            vstack.truncate(base);
                            self.vstack = std::mem::take(&mut vstack);
                            self.frames = std::mem::take(&mut frames);
                            let ret = self.virtual_fallback(module, selector, &args)?;
                            vstack = std::mem::take(&mut self.vstack);
                            frames = std::mem::take(&mut self.frames);
                            vstack.push(ret);
                        }
                    }
                }

                // --- enums ---
                Instr::EnumNew {
                    ty,
                    variant,
                    field_count,
                } => {
                    poll_gc!();
                    let fc = *field_count as usize;
                    let base = vstack
                        .len()
                        .checked_sub(fc)
                        .ok_or_else(|| bug("enum.new: operand stack underflow"))?;
                    let fields = vstack.split_off(base);
                    vstack.push(Value::new_enum(*ty, *variant, fields));
                }
                Instr::EnumTag => {
                    let variant = pop_enum_variant(&mut vstack)?;
                    vstack.push(Value::Int(variant as i64));
                }
                Instr::EnumGet(idx) => {
                    let v = pop(&mut vstack)?;
                    vstack.push(enum_field(&v, *idx as usize)?);
                }

                // --- structs ---
                Instr::StructNew { ty } => {
                    poll_gc!();
                    let field_count = module
                        .types
                        .get(*ty as usize)
                        .ok_or_else(|| bug(format!("struct.new: no type at index {ty}")))?
                        .field_count as usize;
                    let base = vstack
                        .len()
                        .checked_sub(field_count)
                        .ok_or_else(|| bug("struct.new: operand stack underflow"))?;
                    let fields = vstack.split_off(base);
                    vstack.push(Value::new_struct(*ty, fields));
                }
                Instr::FieldGet(idx) => {
                    let v = pop(&mut vstack)?;
                    vstack.push(struct_field(&v, *idx as usize)?);
                }
                Instr::FieldSet(idx) => {
                    let value = pop(&mut vstack)?;
                    let obj = pop(&mut vstack)?;
                    set_struct_field(&obj, *idx as usize, value)?;
                }

                // --- collections ---
                Instr::ListNew { count } => {
                    poll_gc!();
                    let n = *count as usize;
                    let base = vstack
                        .len()
                        .checked_sub(n)
                        .ok_or_else(|| bug("list.new: operand stack underflow"))?;
                    let items = vstack.split_off(base);
                    vstack.push(Value::new_list(items));
                }
                Instr::ListGet => {
                    let idx = pop_int(&mut vstack)?;
                    let list = pop(&mut vstack)?;
                    let elem = match list {
                        Value::Ref(h) => heap::with_obj(h, |obj| match obj {
                            Obj::List(items) => Ok(items[checked_list_index(idx, items.len())?]),
                            _ => Err(bug("list.get: expected a list")),
                        })?,
                        _ => return Err(bug("list.get: expected a list")),
                    };
                    vstack.push(elem);
                }
                Instr::ListSet => {
                    let value = pop(&mut vstack)?;
                    let idx = pop_int(&mut vstack)?;
                    let list = pop(&mut vstack)?;
                    match list {
                        Value::Ref(h) => heap::with_obj_mut(h, |obj| match obj {
                            Obj::List(items) => {
                                let i = checked_list_index(idx, items.len())?;
                                items[i] = value;
                                Ok(())
                            }
                            _ => Err(bug("list.set: expected a list")),
                        })?,
                        _ => return Err(bug("list.set: expected a list")),
                    }
                }
                Instr::ListLen => {
                    let list = pop(&mut vstack)?;
                    let len = match list {
                        Value::Ref(h) => heap::with_obj(h, |obj| match obj {
                            Obj::List(items) => Ok(items.len() as i64),
                            _ => Err(bug("list.len: expected a list")),
                        })?,
                        _ => return Err(bug("list.len: expected a list")),
                    };
                    vstack.push(Value::Int(len));
                }

                // --- closures ---
                Instr::ClosureNew { func, captures } => {
                    poll_gc!();
                    let n = *captures as usize;
                    let base = vstack
                        .len()
                        .checked_sub(n)
                        .ok_or_else(|| bug("closure.new: operand stack underflow"))?;
                    let captured = vstack.split_off(base);
                    vstack.push(Value::new_closure(*func, captured));
                }

                // --- control ---
                Instr::Jump(target) => {
                    if *target < frame.pc {
                        poll_gc!();
                    }
                    frame.pc = *target;
                }
                Instr::JumpIfTrue(target) => {
                    if pop_bool(&mut vstack)? {
                        if *target < frame.pc {
                            poll_gc!();
                        }
                        frame.pc = *target;
                    }
                }
                Instr::JumpIfFalse(target) => {
                    if !pop_bool(&mut vstack)? {
                        if *target < frame.pc {
                            poll_gc!();
                        }
                        frame.pc = *target;
                    }
                }
                Instr::Return => {
                    // The result is the callee's top operand, or `Unit` if its
                    // operand stack is empty (a `Void` return) — distinguished by
                    // the operand floor `base + local_count`, since locals sit below
                    // the operands in the shared stack. Then discard the callee's
                    // whole slot region.
                    let floor = frame.base + module.functions[frame.func].local_count as usize;
                    let value = if vstack.len() > floor {
                        vstack[vstack.len() - 1]
                    } else {
                        Value::Unit
                    };
                    vstack.truncate(frame.base);
                    if frames.len() == base_depth {
                        // The entry frame for this `run_loop` has returned (for the
                        // scheduler, base_depth 0 means the whole fiber unwound); the
                        // result goes back to the Rust caller.
                        exit!(RunOutcome::Done(value));
                    }
                    frame = frames.pop().unwrap();
                    code = &module.functions[frame.func].code;
                    vstack.push(value);
                    if profiling {
                        crate::profile::set_current(frame.func);
                    }
                }
            }
        }
    }

    /// A `call.virtual` with no dispatch row: the built-in interfaces'
    /// structural implementations. This is what makes the auto-derives real —
    /// primitives (and strings/collections) carry built-in `Display`/`Eq`/
    /// `Debug`, and structs/enums without an explicit impl get structural
    /// `eq`/`debug` (an explicit impl, when present, won via the table).
    fn virtual_fallback(
        &mut self,
        module: &Module,
        selector: &str,
        args: &[Value],
    ) -> Result<Value, Trap> {
        // The structural `debug` path re-enters the interpreter (a nested
        // `run_loop`) while the values it is traversing — `args`, and the
        // objects cloned out during rendering — sit in Rust locals, not in a
        // rooted frame. Pause collection so a nested safepoint can't sweep them;
        // the fallback is bounded Rust work, atomic with respect to the GC.
        let _gc = GcPause::new();
        let recv = args.first().expect("call.virtual receiver present");
        match selector {
            // Total rendering (Display-preferred, Debug-fallback). A value reaches
            // here only when its type has no `display` impl in the vtable: a
            // primitive/`String` renders via the built-in `display_string`;
            // everything else falls back to the auto-derived `Debug` (which never
            // traps), so `${x}` / `println(x)` work for any value.
            "display" => {
                if natives::has_builtin_display(recv) {
                    Ok(Value::new_str(natives::display_string(recv)?))
                } else {
                    let s = self.debug_value(module, recv)?;
                    Ok(Value::new_str(s))
                }
            }
            "debug" => {
                let s = self.debug_value(module, recv)?;
                Ok(Value::new_str(s))
            }
            "eq" => match args {
                [a, b] => Ok(Value::Bool(a == b)),
                _ => Err(bug("call.virtual eq: expected 2 args")),
            },
            // `Ord.compare` on a primitive reached through a generic `<T: Ord>` /
            // interface-typed context (static `impl Ord for Int/...` calls go
            // direct). The four primitives carry a built-in ordering; anything
            // else here is a compile-time-prevented missing-`Ord` bug.
            "compare" => match args {
                [a, b] => primitive_ordering(a, b),
                _ => Err(bug("call.virtual compare: expected 2 args")),
            },
            _ => Err(bug(format!(
                "call.virtual: no impl of '{selector}' for the receiver's type"
            ))),
        }
    }

    /// The structural `Debug` rendering of [v] — the auto-derived `debug`.
    /// Strings are quoted; collections recurse; a struct renders as
    /// `Name { field, ... }` (positionally — field names aren't in the type
    /// table); an enum as `Variant(field, ...)` with the reserved Result/Option
    /// variants named (other enums' variant names aren't in the runtime yet).
    /// A nested value with an explicit `impl Debug` renders through it.
    fn debug_value(&mut self, module: &Module, v: &Value) -> Result<String, Trap> {
        // An explicit `impl Debug` overrides the structural rendering.
        if let Some(ty) = dispatch_type_id(v)
            && let Some(func) = module.dispatch_target(ty, "debug")
        {
            let ret = self.call(module, func as usize, vec![*v])?;
            return match ret {
                Value::Ref(h) => heap::with_obj(h, |obj| match obj {
                    Obj::Str(s) => Ok(s.clone()),
                    _ => Err(bug("debug impl did not return a String")),
                }),
                _ => Err(bug("debug impl did not return a String")),
            };
        }
        Ok(match v {
            Value::Int(n) => n.to_string(),
            Value::Double(x) => crate::value::format_double(*x),
            Value::Bool(b) => b.to_string(),
            Value::Unit => "()".to_string(),
            // Clone the object out so the recursion into nested handles below
            // doesn't hold a heap borrow.
            Value::Ref(h) => match heap::clone_obj(*h) {
                Obj::Str(s) => format!("'{}'", s.replace('\\', r"\\").replace('\'', r"\'")),
                Obj::Bytes(b) => format!("Bytes[{}]", hex_join(&b)),
                Obj::BytesBuilder(b) => format!("BytesBuilder[{}]", hex_join(&b)),
                Obj::List(items) => format!("[{}]", self.debug_list(module, &items)?),
                Obj::Map(entries) => {
                    let mut parts = Vec::with_capacity(entries.len());
                    for (k, val) in &entries {
                        parts.push(format!(
                            "{}: {}",
                            self.debug_value(module, k)?,
                            self.debug_value(module, val)?
                        ));
                    }
                    format!("{{{}}}", parts.join(", "))
                }
                Obj::Struct { ty, fields } => {
                    let name = module
                        .types
                        .get(ty as usize)
                        .map_or("<struct>", |t| t.name.as_str());
                    if fields.is_empty() {
                        format!("{name} {{}}")
                    } else {
                        format!("{name} {{ {} }}", self.debug_list(module, &fields)?)
                    }
                }
                Obj::Enum(e) => {
                    let variant = match (e.ty, e.variant) {
                        (TY_RESULT, TAG_OK) => "Ok".to_string(),
                        (TY_RESULT, _) => "Err".to_string(),
                        (TY_OPTION, TAG_SOME) => "Some".to_string(),
                        (TY_OPTION, _) => "None".to_string(),
                        (_, tag) => format!("variant{tag}"),
                    };
                    if e.fields.is_empty() {
                        variant
                    } else {
                        format!("{variant}({})", self.debug_list(module, &e.fields)?)
                    }
                }
                Obj::Closure { .. } => "<fn>".to_string(),
            },
        })
    }

    /// Comma-joined [debug_value]s of [items].
    fn debug_list(&mut self, module: &Module, items: &[Value]) -> Result<String, Trap> {
        let mut parts = Vec::with_capacity(items.len());
        for item in items {
            parts.push(self.debug_value(module, item)?);
        }
        Ok(parts.join(", "))
    }
}

// --- operand-stack helpers ---

#[inline(always)]
fn pop(stack: &mut Vec<Value>) -> Result<Value, Trap> {
    stack.pop().ok_or_else(|| bug("stack underflow"))
}

#[inline(always)]
fn pop_int(stack: &mut Vec<Value>) -> Result<i64, Trap> {
    match pop(stack)? {
        Value::Int(n) => Ok(n),
        v => Err(bug(format!("expected Int, found {v:?}"))),
    }
}

/// Resolve a (possibly out-of-range) list index, trapping if outside `0..len`.
/// The bounds check behind the `list.get` / `list.set` opcodes.
fn checked_list_index(i: i64, len: usize) -> Result<usize, Trap> {
    if i < 0 || i as u64 >= len as u64 {
        Err(Trap::IndexOutOfBounds { index: i, len })
    } else {
        Ok(i as usize)
    }
}

#[inline(always)]
fn pop_double(stack: &mut Vec<Value>) -> Result<f64, Trap> {
    match pop(stack)? {
        Value::Double(x) => Ok(x),
        v => Err(bug(format!("expected Double, found {v:?}"))),
    }
}

#[inline(always)]
fn pop_bool(stack: &mut Vec<Value>) -> Result<bool, Trap> {
    match pop(stack)? {
        Value::Bool(b) => Ok(b),
        v => Err(bug(format!("expected Bool, found {v:?}"))),
    }
}

/// Pop two ints `a` (pushed first) and `b` (pushed second / on top).
#[inline(always)]
fn pop_two_int(stack: &mut Vec<Value>) -> Result<(i64, i64), Trap> {
    let b = pop_int(stack)?;
    let a = pop_int(stack)?;
    Ok((a, b))
}

#[inline(always)]
fn pop_two_double(stack: &mut Vec<Value>) -> Result<(f64, f64), Trap> {
    let b = pop_double(stack)?;
    let a = pop_double(stack)?;
    Ok((a, b))
}

/// Space-separated two-digit hex of `bytes` — the debug rendering of a byte
/// buffer (`Bytes`/`BytesBuilder`).
fn hex_join(bytes: &[u8]) -> String {
    bytes
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<Vec<_>>()
        .join(" ")
}

/// Pop an enum value and return its variant tag.
#[inline(always)]
fn pop_enum_variant(stack: &mut Vec<Value>) -> Result<u16, Trap> {
    match pop(stack)? {
        Value::Ref(h) => heap::with_obj(h, |obj| match obj {
            Obj::Enum(e) => Ok(e.variant),
            Obj::Str(_)
            | Obj::Bytes(_)
            | Obj::BytesBuilder(_)
            | Obj::List(_)
            | Obj::Map(_)
            | Obj::Struct { .. }
            | Obj::Closure { .. } => Err(bug("enum.tag: expected enum")),
        }),
        v => Err(bug(format!("expected enum, found {v:?}"))),
    }
}

/// Unpack a closure value into its function index and a fresh copy of its
/// captured environment (which becomes the callee's leading local slots).
fn closure_parts(v: &Value) -> Result<(u32, Vec<Value>), Trap> {
    match v {
        Value::Ref(h) => heap::with_obj(*h, |obj| match obj {
            Obj::Closure { func, captures } => Ok((*func, captures.clone())),
            _ => Err(bug("call.indirect: expected a closure")),
        }),
        v => Err(bug(format!(
            "call.indirect: expected a closure, found {v:?}"
        ))),
    }
}

/// Order two primitives for the built-in `Ord` fallback. Strings compare
/// lexicographically; doubles use a total order (so NaN sorts consistently);
/// `false < true`. A non-primitive — or two different primitive kinds — reaching
/// here is a missing-`Ord` impl, which the checker prevents.
fn primitive_ordering(a: &Value, b: &Value) -> Result<Value, Trap> {
    let ord = match (a, b) {
        (Value::Int(x), Value::Int(y)) => x.cmp(y),
        (Value::Double(x), Value::Double(y)) => x.total_cmp(y),
        (Value::Bool(x), Value::Bool(y)) => x.cmp(y),
        (Value::Ref(_), Value::Ref(_)) => natives::str_contents(a)?.cmp(&natives::str_contents(b)?),
        _ => {
            return Err(bug(
                "call.virtual compare: no Ord impl for the receiver's type",
            ));
        }
    };
    Ok(crate::value::ordering(ord))
}

/// The dispatch-table type id of a `call.virtual` receiver — a struct's `ty`
/// (an index into `Module::types`), or an enum's `ty` offset by
/// [`ENUM_DISPATCH_BASE`] (the two id spaces overlap numerically). None for
/// receivers that can't carry an impl row (primitives, strings, collections,
/// closures) — those dispatch through the built-in fallback.
fn dispatch_type_id(v: &Value) -> Option<u32> {
    match v {
        Value::Ref(h) => heap::with_obj(*h, |obj| match obj {
            Obj::Struct { ty, .. } => Some(*ty),
            Obj::Enum(e) => Some(ENUM_DISPATCH_BASE | e.ty),
            Obj::Str(_)
            | Obj::Bytes(_)
            | Obj::BytesBuilder(_)
            | Obj::List(_)
            | Obj::Map(_)
            | Obj::Closure { .. } => None,
        }),
        _ => None,
    }
}

/// Read payload field `idx` of an enum value.
fn enum_field(v: &Value, idx: usize) -> Result<Value, Trap> {
    match v {
        Value::Ref(h) => heap::with_obj(*h, |obj| match obj {
            Obj::Enum(e) => e
                .fields
                .get(idx)
                .copied()
                .ok_or_else(|| bug(format!("enum.get: field {idx} out of range"))),
            Obj::Str(_)
            | Obj::Bytes(_)
            | Obj::BytesBuilder(_)
            | Obj::List(_)
            | Obj::Map(_)
            | Obj::Struct { .. }
            | Obj::Closure { .. } => Err(bug("enum.get: expected enum")),
        }),
        v => Err(bug(format!("enum.get: expected enum, found {v:?}"))),
    }
}

/// Read field `idx` of a struct value.
pub(super) fn struct_field(v: &Value, idx: usize) -> Result<Value, Trap> {
    match v {
        Value::Ref(h) => heap::with_obj(*h, |obj| match obj {
            Obj::Struct { fields, .. } => fields
                .get(idx)
                .copied()
                .ok_or_else(|| bug(format!("field.get: field {idx} out of range"))),
            Obj::Str(_)
            | Obj::Bytes(_)
            | Obj::BytesBuilder(_)
            | Obj::List(_)
            | Obj::Map(_)
            | Obj::Enum(_)
            | Obj::Closure { .. } => Err(bug("field.get: expected struct")),
        }),
        v => Err(bug(format!("field.get: expected struct, found {v:?}"))),
    }
}

/// Store `value` into field `idx` of a struct value (in place).
fn set_struct_field(v: &Value, idx: usize, value: Value) -> Result<(), Trap> {
    match v {
        Value::Ref(h) => heap::with_obj_mut(*h, |obj| match obj {
            Obj::Struct { fields, .. } => {
                let slot = fields
                    .get_mut(idx)
                    .ok_or_else(|| bug(format!("field.set: field {idx} out of range")))?;
                *slot = value;
                Ok(())
            }
            Obj::Str(_)
            | Obj::Bytes(_)
            | Obj::BytesBuilder(_)
            | Obj::List(_)
            | Obj::Map(_)
            | Obj::Enum(_)
            | Obj::Closure { .. } => Err(bug("field.set: expected struct")),
        }),
        v => Err(bug(format!("field.set: expected struct, found {v:?}"))),
    }
}

fn cmp_int(stack: &mut Vec<Value>, f: impl Fn(i64, i64) -> bool) -> Result<(), Trap> {
    let (a, b) = pop_two_int(stack)?;
    stack.push(Value::Bool(f(a, b)));
    Ok(())
}

fn cmp_double(stack: &mut Vec<Value>, f: impl Fn(f64, f64) -> bool) -> Result<(), Trap> {
    let (a, b) = pop_two_double(stack)?;
    stack.push(Value::Bool(f(a, b)));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::builder::FnBuilder;
    use crate::module::{Function, Module, TypeDef};
    use crate::value::{TAG_ERR, TAG_NONE, TAG_OK, TAG_SOME};

    // Opaque type ids for the draft (no type table yet).
    const RESULT: u32 = 0;
    const OPTION: u32 = 1;

    /// Evaluate a bare snippet with no locals. (Shadows the module-level `run`
    /// for the earlier increments' tests; increment-3 tests use `super::run`.)
    fn run(code: &[Instr]) -> Result<Value, Trap> {
        eval(code, &[])
    }

    #[test]
    fn returns_constant() {
        assert_eq!(run(&[Instr::ConstInt(7), Instr::Return]), Ok(Value::Int(7)));
    }

    #[test]
    fn empty_return_is_unit() {
        assert_eq!(run(&[Instr::Return]), Ok(Value::Unit));
    }

    #[test]
    fn integer_arithmetic() {
        // (2 + 3) * 4 = 20
        let code = [
            Instr::ConstInt(2),
            Instr::ConstInt(3),
            Instr::AddI64,
            Instr::ConstInt(4),
            Instr::MulI64,
            Instr::Return,
        ];
        assert_eq!(run(&code), Ok(Value::Int(20)));
    }

    #[test]
    fn bitwise_and_or_xor_not() {
        // 0b1100 & 0b1010 = 0b1000 (8); | = 0b1110 (14); ^ = 0b0110 (6).
        assert_eq!(
            run(&[
                Instr::ConstInt(12),
                Instr::ConstInt(10),
                Instr::AndI64,
                Instr::Return
            ]),
            Ok(Value::Int(8))
        );
        assert_eq!(
            run(&[
                Instr::ConstInt(12),
                Instr::ConstInt(10),
                Instr::OrI64,
                Instr::Return
            ]),
            Ok(Value::Int(14))
        );
        assert_eq!(
            run(&[
                Instr::ConstInt(12),
                Instr::ConstInt(10),
                Instr::XorI64,
                Instr::Return
            ]),
            Ok(Value::Int(6))
        );
        // ~0 = -1 (two's complement).
        assert_eq!(
            run(&[Instr::ConstInt(0), Instr::BNotI64, Instr::Return]),
            Ok(Value::Int(-1))
        );
    }

    #[test]
    fn shifts_arithmetic_vs_logical() {
        // 1 << 4 = 16.
        assert_eq!(
            run(&[
                Instr::ConstInt(1),
                Instr::ConstInt(4),
                Instr::ShlI64,
                Instr::Return
            ]),
            Ok(Value::Int(16))
        );
        // -8 >> 1 = -4 (arithmetic: sign-preserving).
        assert_eq!(
            run(&[
                Instr::ConstInt(-8),
                Instr::ConstInt(1),
                Instr::ShrI64,
                Instr::Return
            ]),
            Ok(Value::Int(-4))
        );
        // -1 >>> 1 = i64::MAX (logical: zero-fill over the 64-bit pattern).
        assert_eq!(
            run(&[
                Instr::ConstInt(-1),
                Instr::ConstInt(1),
                Instr::UShrI64,
                Instr::Return
            ]),
            Ok(Value::Int(i64::MAX))
        );
        // Shift amount is masked to 0..=63: `1 << 64` == `1 << 0` == 1.
        assert_eq!(
            run(&[
                Instr::ConstInt(1),
                Instr::ConstInt(64),
                Instr::ShlI64,
                Instr::Return
            ]),
            Ok(Value::Int(1))
        );
    }

    #[test]
    fn subtraction_is_ordered() {
        // 10 - 3 = 7 (operand order matters)
        let code = [
            Instr::ConstInt(10),
            Instr::ConstInt(3),
            Instr::SubI64,
            Instr::Return,
        ];
        assert_eq!(run(&code), Ok(Value::Int(7)));
    }

    #[test]
    fn division_truncates_toward_zero() {
        let code = [
            Instr::ConstInt(7),
            Instr::ConstInt(2),
            Instr::DivI64,
            Instr::Return,
        ];
        assert_eq!(run(&code), Ok(Value::Int(3)));
    }

    #[test]
    fn modulo() {
        let code = [
            Instr::ConstInt(7),
            Instr::ConstInt(3),
            Instr::ModI64,
            Instr::Return,
        ];
        assert_eq!(run(&code), Ok(Value::Int(1)));
    }

    #[test]
    fn integer_overflow_wraps() {
        let code = [
            Instr::ConstInt(i64::MAX),
            Instr::ConstInt(1),
            Instr::AddI64,
            Instr::Return,
        ];
        assert_eq!(run(&code), Ok(Value::Int(i64::MIN)));
    }

    #[test]
    fn division_by_zero_traps() {
        let code = [
            Instr::ConstInt(1),
            Instr::ConstInt(0),
            Instr::DivI64,
            Instr::Return,
        ];
        assert_eq!(run(&code), Err(Trap::DivByZero));
    }

    #[test]
    fn modulo_by_zero_traps() {
        let code = [
            Instr::ConstInt(1),
            Instr::ConstInt(0),
            Instr::ModI64,
            Instr::Return,
        ];
        assert_eq!(run(&code), Err(Trap::DivByZero));
    }

    #[test]
    fn comparison() {
        let code = [
            Instr::ConstInt(2),
            Instr::ConstInt(3),
            Instr::LtI64,
            Instr::Return,
        ];
        assert_eq!(run(&code), Ok(Value::Bool(true)));
    }

    #[test]
    fn float_arithmetic_and_compare() {
        let code = [
            Instr::ConstDouble(1.5),
            Instr::ConstDouble(2.0),
            Instr::AddF64,
            Instr::Return,
        ];
        assert_eq!(run(&code), Ok(Value::Double(3.5)));
    }

    #[test]
    fn conversions() {
        assert_eq!(
            run(&[Instr::ConstInt(3), Instr::I64ToF64, Instr::Return]),
            Ok(Value::Double(3.0))
        );
        assert_eq!(
            run(&[Instr::ConstDouble(3.9), Instr::F64ToI64, Instr::Return]),
            Ok(Value::Int(3))
        );
    }

    #[test]
    fn boolean_not() {
        assert_eq!(
            run(&[Instr::ConstBool(true), Instr::Not, Instr::Return]),
            Ok(Value::Bool(false))
        );
    }

    #[test]
    fn dup_and_pop() {
        // dup: 5 5 +  = 10
        assert_eq!(
            run(&[Instr::ConstInt(5), Instr::Dup, Instr::AddI64, Instr::Return]),
            Ok(Value::Int(10))
        );
        // pop: leaves the first value
        assert_eq!(
            run(&[
                Instr::ConstInt(1),
                Instr::ConstInt(2),
                Instr::Pop,
                Instr::Return
            ]),
            Ok(Value::Int(1))
        );
    }

    #[test]
    fn locals_store_and_load() {
        let locals = vec![Value::Unit];
        let code = [
            Instr::ConstInt(42),
            Instr::Store(0),
            Instr::Load(0),
            Instr::Return,
        ];
        assert_eq!(eval(&code, &locals), Ok(Value::Int(42)));
    }

    #[test]
    fn unconditional_jump_skips_instructions() {
        // Jump over a ConstInt(999) that would otherwise overwrite the result.
        let code = [
            Instr::ConstInt(42),
            Instr::Jump(4),
            Instr::ConstInt(999), // skipped
            Instr::Return,        // skipped
            Instr::Return,        // target
        ];
        assert_eq!(run(&code), Ok(Value::Int(42)));
    }

    /// `if a < b { 100 } else { 200 }`.
    fn branch(a: i64, b: i64) -> Result<Value, Trap> {
        let code = [
            Instr::ConstInt(a),
            Instr::ConstInt(b),
            Instr::LtI64,
            Instr::JumpIfFalse(6), // false → else branch
            Instr::ConstInt(100),  // then
            Instr::Return,
            Instr::ConstInt(200), // else (index 6)
            Instr::Return,
        ];
        run(&code)
    }

    #[test]
    fn conditional_branch_taken_and_not_taken() {
        assert_eq!(branch(2, 3), Ok(Value::Int(100))); // 2 < 3 → then
        assert_eq!(branch(3, 2), Ok(Value::Int(200))); // 3 < 2 → else
    }

    #[test]
    fn jump_if_true() {
        // if true, jump to return 1; else fall through to return 0.
        let code = [
            Instr::ConstBool(true),
            Instr::JumpIfTrue(4),
            Instr::ConstInt(0),
            Instr::Return,
            Instr::ConstInt(1), // target
            Instr::Return,
        ];
        assert_eq!(run(&code), Ok(Value::Int(1)));
    }

    #[test]
    fn counted_loop_sums_range() {
        // sum = 0; i = 0; while i < 5 { sum += i; i += 1 }; return sum  // = 10
        let code = [
            Instr::ConstInt(0),
            Instr::Store(1), // sum = 0
            Instr::ConstInt(0),
            Instr::Store(0), // i = 0
            // loop head (index 4):
            Instr::Load(0),
            Instr::ConstInt(5),
            Instr::LtI64,
            Instr::JumpIfFalse(17), // exit
            Instr::Load(1),
            Instr::Load(0),
            Instr::AddI64,
            Instr::Store(1), // sum += i
            Instr::Load(0),
            Instr::ConstInt(1),
            Instr::AddI64,
            Instr::Store(0), // i += 1
            Instr::Jump(4),
            // after loop (index 17):
            Instr::Load(1),
            Instr::Return,
        ];
        let locals = vec![Value::Unit; 2];
        assert_eq!(eval(&code, &locals), Ok(Value::Int(10)));
    }

    #[test]
    fn type_mismatch_is_a_bug() {
        // AddI64 on a Bool is malformed bytecode.
        let code = [
            Instr::ConstBool(true),
            Instr::ConstInt(1),
            Instr::AddI64,
            Instr::Return,
        ];
        assert!(matches!(run(&code), Err(Trap::Bug(_))));
    }

    // --- increment 3: functions & calls ---

    #[test]
    fn simple_call() {
        // double(x) = x * 2;  main() = double(21)
        let main = Function::new(
            "main",
            0,
            0,
            vec![
                Instr::ConstInt(21),
                Instr::Call { func: 1, argc: 1 },
                Instr::Return,
            ],
        );
        let double = Function::new(
            "double",
            1,
            1,
            vec![
                Instr::Load(0),
                Instr::ConstInt(2),
                Instr::MulI64,
                Instr::Return,
            ],
        );
        let module = Module::new(vec![main, double]);
        assert_eq!(super::run(&module, 0, &[]), Ok(Value::Int(42)));
    }

    #[test]
    fn deep_recursion_does_not_overflow_the_host_stack() {
        // countdown(n) = if n == 0 { 0 } else { countdown(n - 1) }
        // Not tail-call optimized, so all N frames are live at peak depth. With
        // the explicit frame stack that depth is bounded by the heap, not the
        // Rust call stack — a depth that would blow the host stack runs fine.
        let countdown = Function::new(
            "countdown",
            1,
            1,
            vec![
                Instr::Load(0),                   // 0: n
                Instr::ConstInt(0),               // 1
                Instr::EqI64,                     // 2: n == 0
                Instr::JumpIfFalse(6),            // 3: nonzero → recurse at 6
                Instr::ConstInt(0),               // 4
                Instr::Return,                    // 5: base case → 0
                Instr::Load(0),                   // 6: n
                Instr::ConstInt(1),               // 7
                Instr::SubI64,                    // 8: n - 1
                Instr::Call { func: 0, argc: 1 }, // 9: countdown(n - 1)
                Instr::Return,                    // 10
            ],
        );
        let module = Module::new(vec![countdown]);
        // 250k frames deep — well past what the native stack could hold.
        assert_eq!(
            super::run(&module, 0, &[Value::Int(250_000)]),
            Ok(Value::Int(0)),
        );
    }

    #[test]
    fn argument_order_is_preserved() {
        // sub(a, b) = a - b;  sub(10, 3) = 7  (args land in locals[0], locals[1])
        let sub = Function::new(
            "sub",
            2,
            2,
            vec![Instr::Load(0), Instr::Load(1), Instr::SubI64, Instr::Return],
        );
        let module = Module::new(vec![sub]);
        assert_eq!(
            super::run(&module, 0, &[Value::Int(10), Value::Int(3)]),
            Ok(Value::Int(7))
        );
    }

    #[test]
    fn recursive_factorial() {
        // fact(n) = if n <= 1 { 1 } else { n * fact(n - 1) }  (built via FnBuilder)
        let mut b = FnBuilder::new("fact", 1);
        let recurse = b.label();
        b.load(0);
        b.const_int(1);
        b.le_i64();
        b.jump_if_false(recurse);
        b.const_int(1); // base case
        b.ret();
        b.bind(recurse);
        b.load(0);
        b.load(0);
        b.const_int(1);
        b.sub_i64();
        b.call(0, 1); // fact(n - 1)
        b.mul_i64();
        b.ret();
        let module = Module::new(vec![b.finish()]);
        assert_eq!(
            super::run(&module, 0, &[Value::Int(5)]),
            Ok(Value::Int(120))
        );
        assert_eq!(super::run(&module, 0, &[Value::Int(0)]), Ok(Value::Int(1)));
    }

    #[test]
    fn recursive_fibonacci() {
        // fib(n) = if n < 2 { n } else { fib(n - 1) + fib(n - 2) }
        let fib = Function::new(
            "fib",
            1,
            1,
            vec![
                Instr::Load(0),
                Instr::ConstInt(2),
                Instr::LtI64,
                Instr::JumpIfFalse(6),
                Instr::Load(0), // base case: return n
                Instr::Return,
                Instr::Load(0), // index 6
                Instr::ConstInt(1),
                Instr::SubI64,
                Instr::Call { func: 0, argc: 1 }, // fib(n - 1)
                Instr::Load(0),
                Instr::ConstInt(2),
                Instr::SubI64,
                Instr::Call { func: 0, argc: 1 }, // fib(n - 2)
                Instr::AddI64,
                Instr::Return,
            ],
        );
        let module = Module::new(vec![fib]);
        assert_eq!(
            super::run(&module, 0, &[Value::Int(10)]),
            Ok(Value::Int(55))
        );
    }

    #[test]
    fn void_function_returns_unit() {
        // f() returns nothing; main() = f()
        let main = Function::new(
            "main",
            0,
            0,
            vec![Instr::Call { func: 1, argc: 0 }, Instr::Return],
        );
        let f = Function::new("f", 0, 0, vec![Instr::Return]);
        let module = Module::new(vec![main, f]);
        assert_eq!(super::run(&module, 0, &[]), Ok(Value::Unit));
    }

    #[test]
    fn unknown_function_is_a_bug() {
        let module = Module::default();
        assert!(matches!(super::run(&module, 0, &[]), Err(Trap::Bug(_))));
    }

    #[test]
    fn arity_mismatch_is_a_bug() {
        // Call passes 0 args to a function expecting 1.
        let main = Function::new(
            "main",
            0,
            0,
            vec![Instr::Call { func: 1, argc: 0 }, Instr::Return],
        );
        let g = Function::new("g", 1, 1, vec![Instr::Load(0), Instr::Return]);
        let module = Module::new(vec![main, g]);
        assert!(matches!(super::run(&module, 0, &[]), Err(Trap::Bug(_))));
    }

    // --- increment 4: enums & the heap ---

    #[test]
    fn enum_tag() {
        let ok = [
            Instr::ConstInt(42),
            Instr::EnumNew {
                ty: RESULT,
                variant: TAG_OK,
                field_count: 1,
            },
            Instr::EnumTag,
            Instr::Return,
        ];
        assert_eq!(run(&ok), Ok(Value::Int(0)));

        let none = [
            Instr::EnumNew {
                ty: OPTION,
                variant: TAG_NONE,
                field_count: 0,
            },
            Instr::EnumTag,
            Instr::Return,
        ];
        assert_eq!(run(&none), Ok(Value::Int(1)));
    }

    #[test]
    fn enum_get_payload() {
        let code = [
            Instr::ConstInt(42),
            Instr::EnumNew {
                ty: RESULT,
                variant: TAG_OK,
                field_count: 1,
            },
            Instr::EnumGet(0),
            Instr::Return,
        ];
        assert_eq!(run(&code), Ok(Value::Int(42)));
    }

    #[test]
    fn enum_value_is_constructed() {
        let code = [
            Instr::ConstInt(7),
            Instr::EnumNew {
                ty: OPTION,
                variant: TAG_SOME,
                field_count: 1,
            },
            Instr::Return,
        ];
        assert_eq!(
            run(&code),
            Ok(Value::new_enum(OPTION, TAG_SOME, vec![Value::Int(7)]))
        );
    }

    #[test]
    fn structural_equality() {
        assert_eq!(
            Value::new_enum(RESULT, TAG_OK, vec![Value::Int(1)]),
            Value::new_enum(RESULT, TAG_OK, vec![Value::Int(1)]),
        );
        // different variant
        assert_ne!(
            Value::new_enum(RESULT, TAG_OK, vec![Value::Int(1)]),
            Value::new_enum(RESULT, TAG_ERR, vec![Value::Int(1)]),
        );
        // different payload
        assert_ne!(
            Value::new_enum(RESULT, TAG_OK, vec![Value::Int(1)]),
            Value::new_enum(RESULT, TAG_OK, vec![Value::Int(2)]),
        );
        // different type id (same variant/payload)
        assert_ne!(
            Value::new_enum(RESULT, TAG_OK, vec![Value::Int(1)]),
            Value::new_enum(OPTION, TAG_SOME, vec![Value::Int(1)]),
        );
    }

    #[test]
    fn question_mark_propagation() {
        // f(r) = { let x = r?; return Ok(x + 10); }  (built via FnBuilder)
        let mut b = FnBuilder::new("f", 1);
        let ok = b.label();
        b.load(0);
        b.dup();
        b.enum_tag();
        b.const_int(TAG_ERR as i64);
        b.eq_i64();
        b.jump_if_false(ok);
        b.ret(); // Err: propagate the Result unchanged
        b.bind(ok);
        b.enum_get(0); // unwrap Ok payload
        b.store(1); // x  (bumps local_count to 2)
        b.load(1);
        b.const_int(10);
        b.add_i64();
        b.enum_new(RESULT, TAG_OK, 1);
        b.ret();
        let module = Module::new(vec![b.finish()]);

        // Ok(5) → Ok(15)
        assert_eq!(
            super::run(
                &module,
                0,
                &[Value::new_enum(RESULT, TAG_OK, vec![Value::Int(5)])]
            ),
            Ok(Value::new_enum(RESULT, TAG_OK, vec![Value::Int(15)]))
        );
        // Err(99) → Err(99), propagated unchanged
        assert_eq!(
            super::run(
                &module,
                0,
                &[Value::new_enum(RESULT, TAG_ERR, vec![Value::Int(99)])]
            ),
            Ok(Value::new_enum(RESULT, TAG_ERR, vec![Value::Int(99)]))
        );
    }

    #[test]
    fn match_on_option() {
        // match opt { Some(n) => n, None => -1 }
        let f = Function::new(
            "f",
            1,
            1,
            vec![
                Instr::Load(0),
                Instr::EnumTag,
                Instr::ConstInt(TAG_SOME as i64),
                Instr::EqI64,
                Instr::JumpIfFalse(8), // None arm
                Instr::Load(0),
                Instr::EnumGet(0), // n
                Instr::Return,
                Instr::ConstInt(-1), // index 8: None arm
                Instr::Return,
            ],
        );
        let module = Module::new(vec![f]);
        assert_eq!(
            super::run(
                &module,
                0,
                &[Value::new_enum(OPTION, TAG_SOME, vec![Value::Int(7)])]
            ),
            Ok(Value::Int(7))
        );
        assert_eq!(
            super::run(&module, 0, &[Value::new_enum(OPTION, TAG_NONE, vec![])]),
            Ok(Value::Int(-1))
        );
    }

    #[test]
    fn enum_tag_on_non_enum_is_a_bug() {
        let code = [Instr::ConstInt(1), Instr::EnumTag, Instr::Return];
        assert!(matches!(run(&code), Err(Trap::Bug(_))));
    }

    // --- increment 5: intrinsics & observable output ---

    /// Run a bare snippet, returning its result and any captured output.
    fn run_capturing(code: &[Instr]) -> (Result<Value, Trap>, String) {
        let module = Module::new(vec![Function::new("<eval>", 0, 0, code.to_vec())]);
        let mut buf: Vec<u8> = Vec::new();
        let result = Vm::new(&mut buf).call(&module, 0, vec![]);
        (result, String::from_utf8(buf).unwrap())
    }

    #[test]
    fn int_to_string_primitive() {
        let code = [
            Instr::ConstInt(42),
            Instr::CallNative {
                native: NATIVE_INT_TO_STRING,
                argc: 1,
            },
            Instr::Return,
        ];
        assert_eq!(run(&code), Ok(Value::new_str("42")));
    }

    #[test]
    fn str_concat_joins_strings() {
        let code = [
            Instr::ConstStr("foo".into()),
            Instr::ConstStr("bar".into()),
            Instr::CallNative {
                native: NATIVE_STR_CONCAT,
                argc: 2,
            },
            Instr::Return,
        ];
        assert_eq!(run(&code), Ok(Value::new_str("foobar")));
    }

    #[test]
    fn println_writes_to_output() {
        let code = [
            Instr::ConstStr("hello".into()),
            Instr::CallNative {
                native: NATIVE_PRINTLN,
                argc: 1,
            },
            Instr::Return,
        ];
        let (result, output) = run_capturing(&code);
        assert_eq!(result, Ok(Value::Unit));
        assert_eq!(output, "hello\n");
    }

    #[test]
    fn interpolation_pipeline() {
        // 'x = ${x}' with x = 7  →  "x = 7\n"
        let code = [
            Instr::ConstStr("x = ".into()),
            Instr::ConstInt(7),
            Instr::CallNative {
                native: NATIVE_INT_TO_STRING,
                argc: 1,
            },
            Instr::CallNative {
                native: NATIVE_STR_CONCAT,
                argc: 2,
            },
            Instr::CallNative {
                native: NATIVE_PRINTLN,
                argc: 1,
            },
            Instr::Return,
        ];
        let (result, output) = run_capturing(&code);
        assert_eq!(result, Ok(Value::Unit));
        assert_eq!(output, "x = 7\n");
    }

    #[test]
    fn unknown_native_is_a_bug() {
        let code = [Instr::CallNative {
            native: 999,
            argc: 0,
        }];
        assert!(matches!(run(&code), Err(Trap::Bug(_))));
    }

    #[test]
    fn str_concat_on_non_string_is_a_bug() {
        let code = [
            Instr::ConstInt(1),
            Instr::ConstInt(2),
            Instr::CallNative {
                native: NATIVE_STR_CONCAT,
                argc: 2,
            },
            Instr::Return,
        ];
        assert!(matches!(run(&code), Err(Trap::Bug(_))));
    }

    // --- increment 6: collections ---

    /// Build and run a parameterless function via the builder.
    fn run_fn(build: impl FnOnce(&mut FnBuilder)) -> Result<Value, Trap> {
        let mut b = FnBuilder::new("test", 0);
        build(&mut b);
        let module = Module::new(vec![b.finish()]);
        super::run(&module, 0, &[])
    }

    /// Emit `[a, b, c, ...]` as a list literal.
    fn push_int_list(b: &mut FnBuilder, items: &[i64]) {
        for &n in items {
            b.const_int(n);
        }
        b.list_new(items.len() as u32);
    }

    #[test]
    fn list_literal_and_len() {
        let r = run_fn(|b| {
            push_int_list(b, &[10, 20, 30]);
            b.call_native(NATIVE_LIST_LEN, 1);
            b.ret();
        });
        assert_eq!(r, Ok(Value::Int(3)));
    }

    #[test]
    fn list_index_reads_element() {
        let r = run_fn(|b| {
            push_int_list(b, &[10, 20, 30]);
            b.const_int(1);
            b.list_get();
            b.ret();
        });
        assert_eq!(r, Ok(Value::Int(20)));
    }

    #[test]
    fn list_index_out_of_bounds_traps() {
        let r = run_fn(|b| {
            push_int_list(b, &[10]);
            b.const_int(5);
            b.list_get();
            b.ret();
        });
        assert_eq!(r, Err(Trap::IndexOutOfBounds { index: 5, len: 1 }));
    }

    #[test]
    fn list_push_appends_in_place() {
        // l = [1, 2]; l.push(3); return l.len()  → 3
        let push = native_index("list_push").unwrap();
        let r = run_fn(|b| {
            push_int_list(b, &[1, 2]);
            b.store(0);
            b.load(0);
            b.const_int(3);
            b.call_native(push, 2);
            b.pop(); // discard the Unit return
            b.load(0);
            b.call_native(NATIVE_LIST_LEN, 1);
            b.ret();
        });
        assert_eq!(r, Ok(Value::Int(3)));
    }

    #[test]
    fn list_get_returns_option() {
        // get(1) → Some(20)
        let some = run_fn(|b| {
            push_int_list(b, &[10, 20]);
            b.const_int(1);
            b.call_native(NATIVE_LIST_GET, 2);
            b.ret();
        });
        assert_eq!(some, Ok(Value::some(Value::Int(20))));
        // get(9) → None
        let none = run_fn(|b| {
            push_int_list(b, &[10, 20]);
            b.const_int(9);
            b.call_native(NATIVE_LIST_GET, 2);
            b.ret();
        });
        assert_eq!(none, Ok(Value::none()));
    }

    #[test]
    fn list_set_mutates_in_place() {
        // l = [10, 20]; l[0] = 99; return l[0]
        let r = run_fn(|b| {
            push_int_list(b, &[10, 20]);
            b.store(0);
            b.load(0);
            b.const_int(0);
            b.const_int(99);
            b.list_set();
            b.load(0);
            b.const_int(0);
            b.list_get();
            b.ret();
        });
        assert_eq!(r, Ok(Value::Int(99)));
    }

    #[test]
    fn reference_semantics_aliasing() {
        // l = [1]; a = l; l[0] = 42; return a[0]  → 42 (shared heap object)
        let r = run_fn(|b| {
            push_int_list(b, &[1]);
            b.store(0); // l
            b.load(0);
            b.store(1); // a = l  (copies the reference)
            b.load(0);
            b.const_int(0);
            b.const_int(42);
            b.list_set();
            b.load(1); // read via a
            b.const_int(0);
            b.list_get();
            b.ret();
        });
        assert_eq!(r, Ok(Value::Int(42)));
    }

    /// Emit the literal `{'a': 1, 'b': 2}`.
    fn push_ab_map(b: &mut FnBuilder) {
        b.const_str("a");
        b.const_int(1);
        b.const_str("b");
        b.const_int(2);
        b.call_native(NATIVE_MAP_NEW, 4);
    }

    #[test]
    fn map_literal_index_and_len() {
        let len = run_fn(|b| {
            push_ab_map(b);
            b.call_native(NATIVE_MAP_LEN, 1);
            b.ret();
        });
        assert_eq!(len, Ok(Value::Int(2)));

        let idx = run_fn(|b| {
            push_ab_map(b);
            b.const_str("b");
            b.call_native(NATIVE_MAP_INDEX, 2);
            b.ret();
        });
        assert_eq!(idx, Ok(Value::Int(2)));
    }

    #[test]
    fn map_index_missing_key_traps() {
        let r = run_fn(|b| {
            push_ab_map(b);
            b.const_str("zzz");
            b.call_native(NATIVE_MAP_INDEX, 2);
            b.ret();
        });
        assert_eq!(
            r,
            Err(Trap::MissingKey {
                key: "'zzz'".to_string()
            })
        );
    }

    #[test]
    fn map_get_and_has() {
        let got = run_fn(|b| {
            push_ab_map(b);
            b.const_str("a");
            b.call_native(NATIVE_MAP_GET, 2);
            b.ret();
        });
        assert_eq!(got, Ok(Value::some(Value::Int(1))));

        let missing = run_fn(|b| {
            push_ab_map(b);
            b.const_str("x");
            b.call_native(NATIVE_MAP_GET, 2);
            b.ret();
        });
        assert_eq!(missing, Ok(Value::none()));

        let has = run_fn(|b| {
            push_ab_map(b);
            b.const_str("a");
            b.call_native(NATIVE_MAP_HAS, 2);
            b.ret();
        });
        assert_eq!(has, Ok(Value::Bool(true)));
    }

    #[test]
    fn map_set_updates_and_inserts() {
        // m = {'a':1}; m['a'] = 9 (update); m['c'] = 3 (insert);
        // return m['a'] + m['c'] + m.len()   → 9 + 3 + 2 = 14
        let r = run_fn(|b| {
            b.const_str("a");
            b.const_int(1);
            b.call_native(NATIVE_MAP_NEW, 2);
            b.store(0); // m
            // m['a'] = 9
            b.load(0);
            b.const_str("a");
            b.const_int(9);
            b.call_native(NATIVE_MAP_SET, 3);
            b.pop();
            // m['c'] = 3
            b.load(0);
            b.const_str("c");
            b.const_int(3);
            b.call_native(NATIVE_MAP_SET, 3);
            b.pop();
            // m['a'] + m['c']
            b.load(0);
            b.const_str("a");
            b.call_native(NATIVE_MAP_INDEX, 2);
            b.load(0);
            b.const_str("c");
            b.call_native(NATIVE_MAP_INDEX, 2);
            b.add_i64();
            // + m.len()
            b.load(0);
            b.call_native(NATIVE_MAP_LEN, 1);
            b.add_i64();
            b.ret();
        });
        assert_eq!(r, Ok(Value::Int(14)));
    }

    #[test]
    fn list_index_on_non_list_is_a_bug() {
        let r = run_fn(|b| {
            b.const_int(1); // not a list
            b.const_int(0);
            b.list_get();
            b.ret();
        });
        assert!(matches!(r, Err(Trap::Bug(_))));
    }

    // --- structs & the type table ---

    /// Run a parameterless function against a module with the given types.
    fn run_with_types(
        types: Vec<TypeDef>,
        build: impl FnOnce(&mut FnBuilder),
    ) -> Result<Value, Trap> {
        let mut b = FnBuilder::new("test", 0);
        build(&mut b);
        let module = Module::with_types(vec![b.finish()], types);
        super::run(&module, 0, &[])
    }

    #[test]
    fn struct_construction_and_field_access() {
        // type Point = { x, y };  Point { 1, 2 }.y  → 2
        let r = run_with_types(vec![TypeDef::new("Point", 2)], |b| {
            b.const_int(1);
            b.const_int(2);
            b.struct_new(0);
            b.field_get(1); // y
            b.ret();
        });
        assert_eq!(r, Ok(Value::Int(2)));
    }

    #[test]
    fn struct_field_set_and_reference_semantics() {
        // p = Point{1, 2}; q = p; p.x = 9; return q.x  → 9 (shared heap object)
        let r = run_with_types(vec![TypeDef::new("Point", 2)], |b| {
            b.const_int(1);
            b.const_int(2);
            b.struct_new(0);
            b.store(0); // p
            b.load(0);
            b.store(1); // q = p
            b.load(0);
            b.const_int(9);
            b.field_set(0); // p.x = 9  (stack: struct value →)
            b.load(1);
            b.field_get(0); // q.x
            b.ret();
        });
        assert_eq!(r, Ok(Value::Int(9)));
    }

    #[test]
    fn struct_equality_is_structural() {
        assert_eq!(
            Value::new_struct(0, vec![Value::Int(1)]),
            Value::new_struct(0, vec![Value::Int(1)])
        );
        assert_ne!(
            Value::new_struct(0, vec![Value::Int(1)]),
            Value::new_struct(0, vec![Value::Int(2)])
        );
        // different type id, same fields
        assert_ne!(
            Value::new_struct(0, vec![Value::Int(1)]),
            Value::new_struct(1, vec![Value::Int(1)])
        );
    }

    #[test]
    fn struct_new_unknown_type_is_a_bug() {
        // No types registered, so type index 0 is invalid.
        let r = run_with_types(vec![], |b| {
            b.struct_new(0);
            b.ret();
        });
        assert!(matches!(r, Err(Trap::Bug(_))));
    }

    #[test]
    fn field_get_on_non_struct_is_a_bug() {
        let code = [Instr::ConstInt(1), Instr::FieldGet(0), Instr::Return];
        assert!(matches!(run(&code), Err(Trap::Bug(_))));
    }

    // --- closures ---

    /// `adder(captured, x) = captured + x`: a lifted lambda whose first slot is
    /// a captured value and whose second is the call argument.
    fn adder() -> Function {
        Function::new(
            "adder",
            2,
            2,
            vec![Instr::Load(0), Instr::Load(1), Instr::AddI64, Instr::Return],
        )
    }

    #[test]
    fn closure_captures_and_calls_indirect() {
        // main() = { let g = closure(adder, [10]); g(5) }  → 15
        let main = Function::new(
            "main",
            0,
            0,
            vec![
                Instr::ConstInt(10),
                Instr::ClosureNew {
                    func: 1,
                    captures: 1,
                },
                Instr::ConstInt(5),
                Instr::CallIndirect { argc: 1 },
                Instr::Return,
            ],
        );
        let module = Module::new(vec![main, adder()]);
        assert_eq!(super::run(&module, 0, &[]), Ok(Value::Int(15)));
    }

    #[test]
    fn closure_with_no_captures() {
        // inc(x) = x + 1, captured as a zero-capture closure and called with 41.
        let inc = Function::new(
            "inc",
            1,
            1,
            vec![
                Instr::Load(0),
                Instr::ConstInt(1),
                Instr::AddI64,
                Instr::Return,
            ],
        );
        let main = Function::new(
            "main",
            0,
            0,
            vec![
                Instr::ClosureNew {
                    func: 1,
                    captures: 0,
                },
                Instr::ConstInt(41),
                Instr::CallIndirect { argc: 1 },
                Instr::Return,
            ],
        );
        let module = Module::new(vec![main, inc]);
        assert_eq!(super::run(&module, 0, &[]), Ok(Value::Int(42)));
    }

    #[test]
    fn closure_new_builds_the_expected_value() {
        let r = run_fn(|b| {
            b.const_int(7);
            b.const_int(8);
            b.closure_new(3, 2);
            b.ret();
        });
        assert_eq!(
            r,
            Ok(Value::new_closure(3, vec![Value::Int(7), Value::Int(8)]))
        );
    }

    #[test]
    fn call_indirect_arity_mismatch_is_a_bug() {
        // The closure captures one value and is called with one argument, but
        // `adder` only declares two locals — wait, that is correct; instead call
        // a zero-capture closure of `adder` with one arg (frame of 1 ≠ 2 params).
        let main = Function::new(
            "main",
            0,
            0,
            vec![
                Instr::ClosureNew {
                    func: 1,
                    captures: 0,
                },
                Instr::ConstInt(5),
                Instr::CallIndirect { argc: 1 },
                Instr::Return,
            ],
        );
        let module = Module::new(vec![main, adder()]);
        assert!(matches!(super::run(&module, 0, &[]), Err(Trap::Bug(_))));
    }

    #[test]
    fn call_indirect_on_non_closure_is_a_bug() {
        let r = run_fn(|b| {
            b.const_int(1); // not a closure
            b.call_indirect(0);
            b.ret();
        });
        assert!(matches!(r, Err(Trap::Bug(_))));
    }

    // --- dynamic dispatch (call.virtual) ---

    /// A module with two struct types, a `display` impl for each, and a
    /// `describe(x)` that dispatches `x.display()` virtually.
    fn dispatch_module() -> Module {
        use crate::module::DispatchEntry;
        // Dog (ty 0) and Cat (ty 1); their displays return distinct strings.
        let dog_display = Function::new(
            "Dog.display",
            1,
            1,
            vec![Instr::ConstStr("woof".into()), Instr::Return],
        );
        let cat_display = Function::new(
            "Cat.display",
            1,
            1,
            vec![Instr::ConstStr("meow".into()), Instr::Return],
        );
        // describe(x) = x.display()   (the concrete type isn't known here)
        let describe = Function::new(
            "describe",
            1,
            1,
            vec![
                Instr::Load(0),
                Instr::CallVirtual {
                    selector: "display".into(),
                    argc: 1,
                },
                Instr::Return,
            ],
        );
        let mut m = Module::with_types(
            vec![dog_display, cat_display, describe],
            vec![TypeDef::new("Dog", 0), TypeDef::new("Cat", 0)],
        );
        m.dispatch = vec![
            DispatchEntry::new(0, "display", 0),
            DispatchEntry::new(1, "display", 1),
        ];
        m
    }

    #[test]
    fn call_virtual_dispatches_on_receiver_type() {
        let m = dispatch_module();
        // describe is function index 2.
        let dog = Value::new_struct(0, vec![]);
        let cat = Value::new_struct(1, vec![]);
        assert_eq!(super::run(&m, 2, &[dog]), Ok(Value::new_str("woof")));
        assert_eq!(super::run(&m, 2, &[cat]), Ok(Value::new_str("meow")));
    }

    #[test]
    fn call_virtual_display_without_an_impl_falls_back_to_debug() {
        // Total rendering: a struct that reaches the display fallback without an
        // impl row renders via its auto-derived `Debug` (Debug-fallback), not a
        // trap — so `${x}` works for any value.
        let mut m = dispatch_module();
        m.dispatch.clear(); // no display rows → fall back to structural Debug
        let dog = Value::new_struct(0, vec![]);
        assert_eq!(super::run(&m, 2, &[dog]), Ok(Value::new_str("Dog {}")));
    }

    #[test]
    fn call_virtual_display_on_a_primitive_uses_the_builtin_fallback() {
        // Primitives carry built-in Display: no impl row, rendered natively.
        let m = dispatch_module();
        assert_eq!(super::run(&m, 2, &[Value::Int(5)]), Ok(Value::new_str("5")));
    }

    #[test]
    fn struct_and_enum_dispatch_ids_do_not_collide() {
        // A struct with type-table index 0 and an enum with ty 0 (Result's
        // reserved id) both impl 'display'; each receiver must reach its own.
        use crate::module::{DispatchEntry, ENUM_DISPATCH_BASE};
        let struct_display = Function::new(
            "S.display",
            1,
            1,
            vec![Instr::ConstStr("struct".into()), Instr::Return],
        );
        let enum_display = Function::new(
            "E.display",
            1,
            1,
            vec![Instr::ConstStr("enum".into()), Instr::Return],
        );
        let describe = Function::new(
            "describe",
            1,
            1,
            vec![
                Instr::Load(0),
                Instr::CallVirtual {
                    selector: "display".into(),
                    argc: 1,
                },
                Instr::Return,
            ],
        );
        let mut m = Module::with_types(
            vec![struct_display, enum_display, describe],
            vec![TypeDef::new("S", 0)],
        );
        m.dispatch = vec![
            DispatchEntry::new(0, "display", 0),
            DispatchEntry::new(ENUM_DISPATCH_BASE, "display", 1),
        ];
        let s = Value::new_struct(0, vec![]);
        let e = Value::new_enum(0, 0, vec![]);
        assert_eq!(super::run(&m, 2, &[s]), Ok(Value::new_str("struct")));
        assert_eq!(super::run(&m, 2, &[e]), Ok(Value::new_str("enum")));
    }

    // --- the structural debug / eq fallbacks ---

    /// `dbg(x) = x.debug()` over a module with one struct type `Dog` (2 fields)
    /// — no explicit `impl Debug`, so the structural fallback renders.
    fn debug_module() -> Module {
        let dbg = Function::new(
            "dbg",
            1,
            1,
            vec![
                Instr::Load(0),
                Instr::CallVirtual {
                    selector: "debug".into(),
                    argc: 1,
                },
                Instr::Return,
            ],
        );
        Module::with_types(vec![dbg], vec![TypeDef::new("Dog", 2)])
    }

    #[test]
    fn structural_debug_renders_primitives_and_strings() {
        let m = debug_module();
        assert_eq!(super::run(&m, 0, &[Value::Int(5)]), Ok(Value::new_str("5")));
        assert_eq!(
            super::run(&m, 0, &[Value::Bool(true)]),
            Ok(Value::new_str("true"))
        );
        // Strings are quoted (debug, not display).
        assert_eq!(
            super::run(&m, 0, &[Value::new_str("hi")]),
            Ok(Value::new_str("'hi'"))
        );
    }

    #[test]
    fn structural_debug_recurses_into_collections_and_structs() {
        let m = debug_module();
        let list = Value::new_list(vec![Value::Int(1), Value::new_str("a")]);
        assert_eq!(super::run(&m, 0, &[list]), Ok(Value::new_str("[1, 'a']")));
        // A struct renders by name with positional fields.
        let dog = Value::new_struct(0, vec![Value::new_str("Rex"), Value::Int(3)]);
        assert_eq!(
            super::run(&m, 0, &[dog]),
            Ok(Value::new_str("Dog { 'Rex', 3 }"))
        );
        // The reserved Result/Option enums render their variant names.
        assert_eq!(
            super::run(&m, 0, &[Value::some(Value::Int(7))]),
            Ok(Value::new_str("Some(7)"))
        );
        assert_eq!(
            super::run(&m, 0, &[Value::none()]),
            Ok(Value::new_str("None"))
        );
    }

    #[test]
    fn an_explicit_debug_impl_overrides_the_structural_rendering() {
        use crate::module::DispatchEntry;
        let mut m = debug_module();
        m.functions.push(Function::new(
            "Dog.debug",
            1,
            1,
            vec![Instr::ConstStr("custom".into()), Instr::Return],
        ));
        m.dispatch = vec![DispatchEntry::new(0, "debug", 1)];
        let dog = Value::new_struct(0, vec![Value::new_str("Rex"), Value::Int(3)]);
        // Direct receiver and nested (inside a list) both use the impl.
        assert_eq!(
            super::run(&m, 0, &[dog.clone()]),
            Ok(Value::new_str("custom"))
        );
        assert_eq!(
            super::run(&m, 0, &[Value::new_list(vec![dog])]),
            Ok(Value::new_str("[custom]"))
        );
    }

    #[test]
    fn call_virtual_eq_falls_back_to_structural_equality() {
        let eq = Function::new(
            "eq2",
            2,
            2,
            vec![
                Instr::Load(0),
                Instr::Load(1),
                Instr::CallVirtual {
                    selector: "eq".into(),
                    argc: 2,
                },
                Instr::Return,
            ],
        );
        let m = Module::with_types(vec![eq], vec![TypeDef::new("P", 1)]);
        let a = Value::new_struct(0, vec![Value::Int(1)]);
        let b = Value::new_struct(0, vec![Value::Int(1)]);
        let c = Value::new_struct(0, vec![Value::Int(2)]);
        assert_eq!(super::run(&m, 0, &[a.clone(), b]), Ok(Value::Bool(true)));
        assert_eq!(super::run(&m, 0, &[a, c]), Ok(Value::Bool(false)));
    }
}
