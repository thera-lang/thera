//! The runtime `Map` object: an **insertion-ordered** key/value store that stays
//! O(1) per operation as it grows.
//!
//! Layout is a `Vec` of entries (the source of insertion order and the equality
//! basis) plus two pieces of derived acceleration:
//!
//! - `hashes` — a per-entry key hash, parallel to `entries`. Maintained always,
//!   so even the small-map linear scan compares a cheap `u64` before re-entering
//!   the heap for a full `values_eq`.
//! - `index` — an open-addressing `hash → entry index` table, built **only once a
//!   map reaches [`HASH_THRESHOLD`] entries** (small maps — the front-end's own —
//!   stay a linear scan, where a table would only add overhead).
//!
//! Key hashing ([`hash_value`]) is content-based and consistent with
//! [`crate::heap::values_eq`]: equal values hash equal, so a hash mismatch proves
//! inequality and only a hash *match* pays for the structural compare. Order is
//! never touched by hashing, so the byte-identical fixpoint is unaffected.
//!
//! The heap is a single thread-local cell, so a mutation that compares keys can't
//! hold a borrow across `values_eq`; the map natives therefore *take* the object
//! out of its slot (see [`crate::heap::take_obj`]) and operate on it owned, which
//! also makes mutation O(1) rather than the old clone-out-and-write-back O(n).

use crate::heap;
use crate::value::{Obj, Value};

/// Entry count at/above which a map maintains its hash `index`. Below it a linear
/// scan of `entries` (hash-compare-first) is cheaper than a probe table.
pub const HASH_THRESHOLD: usize = 16;

/// Empty slot sentinel in the open-addressing `index` (entry indices are ≥ 0).
const EMPTY: i32 = -1;

/// An insertion-ordered key/value store. See the module docs for the layout.
#[derive(Clone, Debug, Default)]
pub struct MapObj {
    /// Entries in insertion order — the source of truth for order and equality.
    entries: Vec<(Value, Value)>,
    /// Key hash for each entry, parallel to `entries`.
    hashes: Vec<u64>,
    /// Open-addressing table `hash & (len-1) → entry index` (linear probing),
    /// or empty below [`HASH_THRESHOLD`]. Power-of-two length when present.
    index: Vec<i32>,
}

/// Two maps are equal iff they hold the same entries in the same order — the
/// `index`/`hashes` are derived state and play no part (a hand-written impl is
/// required so the derive doesn't compare them).
impl PartialEq for MapObj {
    fn eq(&self, other: &Self) -> bool {
        self.entries == other.entries
    }
}

impl MapObj {
    /// Build a map from key/value pairs, in order, later keys overwriting earlier
    /// (a map literal's semantics). Keys are hashed as they are inserted.
    pub fn from_pairs(pairs: Vec<(Value, Value)>) -> MapObj {
        let mut m = MapObj::default();
        for (k, v) in pairs {
            let h = hash_value(k);
            m.insert(k, h, v);
        }
        m
    }

    /// Number of entries.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// The entries, in insertion order — for iteration (`keys`/`values`/`Debug`,
    /// GC child tracing).
    pub fn entries(&self) -> &[(Value, Value)] {
        &self.entries
    }

    /// The value for `key` (whose precomputed hash is `hash`), or `None`. The
    /// caller hashes the key *before* borrowing the map so this never re-hashes
    /// under the borrow; the structural `values_eq` it may call only *reads* the
    /// heap (a nested shared borrow, which is fine).
    pub fn get(&self, key: Value, hash: u64) -> Option<Value> {
        self.find(key, hash).map(|i| self.entries[i].1)
    }

    /// Whether `key` (with precomputed `hash`) is present.
    pub fn contains(&self, key: Value, hash: u64) -> bool {
        self.find(key, hash).is_some()
    }

    /// Insert or update `key` (with precomputed `hash`) → `val`. Insertion order
    /// is preserved; updating an existing key keeps its position.
    pub fn insert(&mut self, key: Value, hash: u64, val: Value) {
        if let Some(i) = self.find(key, hash) {
            self.entries[i].1 = val;
            return;
        }
        let ei = self.entries.len();
        self.entries.push((key, val));
        self.hashes.push(hash);
        if self.index.is_empty() {
            // Cross the threshold → switch from linear scan to a probe table.
            if self.entries.len() >= HASH_THRESHOLD {
                self.rebuild_index();
            }
        } else if self.load_exceeded() {
            self.rebuild_index(); // grows (see `index_capacity_for`)
        } else {
            self.index_insert(ei, hash);
        }
    }

    /// Remove `key` (with precomputed `hash`), returning its value if present.
    pub fn remove(&mut self, key: Value, hash: u64) -> Option<Value> {
        let i = self.find(key, hash)?;
        let (_, v) = self.entries.remove(i);
        self.hashes.remove(i);
        // The `remove` shifted every later entry's index, invalidating the table;
        // rebuild it (O(n), but removal is not the hot path a hashed map targets).
        if !self.index.is_empty() {
            self.rebuild_index();
        }
        Some(v)
    }

    /// Drop every entry (the map becomes empty; same object).
    pub fn clear(&mut self) {
        self.entries.clear();
        self.hashes.clear();
        self.index.clear();
    }

    /// Estimated heap payload for the GC byte budget (capacity, not length).
    pub fn heap_bytes(&self) -> usize {
        use std::mem::size_of;
        self.entries.capacity() * size_of::<(Value, Value)>()
            + self.hashes.capacity() * size_of::<u64>()
            + self.index.capacity() * size_of::<i32>()
    }

    /// The entry index of `key` (with precomputed `hash`), or `None`. Below the
    /// threshold this is a linear scan that rejects on the cheap `u64` hash before
    /// paying for `values_eq`; above it, an open-addressing probe.
    fn find(&self, key: Value, hash: u64) -> Option<usize> {
        if self.index.is_empty() {
            for i in 0..self.entries.len() {
                if self.hashes[i] == hash && heap::values_eq(self.entries[i].0, key) {
                    return Some(i);
                }
            }
            return None;
        }
        let mask = self.index.len() - 1;
        let mut slot = (hash as usize) & mask;
        loop {
            let e = self.index[slot];
            if e == EMPTY {
                return None;
            }
            let ei = e as usize;
            if self.hashes[ei] == hash && heap::values_eq(self.entries[ei].0, key) {
                return Some(ei);
            }
            slot = (slot + 1) & mask;
        }
    }

    /// Whether the probe table has passed its 0.75 load factor.
    fn load_exceeded(&self) -> bool {
        self.entries.len() * 4 >= self.index.len() * 3
    }

    /// Place `entry_index` into the (already sized) probe table at its hash slot,
    /// linear-probing to the first empty slot. Only correct for a key not already
    /// in the table (insert checks membership first).
    fn index_insert(&mut self, entry_index: usize, hash: u64) {
        let mask = self.index.len() - 1;
        let mut slot = (hash as usize) & mask;
        while self.index[slot] != EMPTY {
            slot = (slot + 1) & mask;
        }
        self.index[slot] = entry_index as i32;
    }

    /// (Re)build the probe table from `entries`/`hashes`, sizing it to keep the
    /// load factor under 0.75. Used both to cross the threshold and to grow.
    fn rebuild_index(&mut self) {
        let cap = index_capacity_for(self.entries.len());
        self.index = vec![EMPTY; cap];
        for i in 0..self.entries.len() {
            self.index_insert(i, self.hashes[i]);
        }
    }
}

/// A power-of-two table capacity giving `n` entries a load factor under ~0.75
/// (at least 2× `n`, floor 32).
fn index_capacity_for(n: usize) -> usize {
    let target = (n * 2).max(32);
    target.next_power_of_two()
}

/// A content hash of `v`, consistent with [`crate::heap::values_eq`]: equal
/// values hash equal. Heap objects are cloned out and hashed structurally (the
/// same clone-then-recurse discipline `values_eq` uses), so this must be called
/// with no heap borrow held for a mutation — it re-enters the heap for reads.
pub fn hash_value(v: Value) -> u64 {
    let mut h = FNV_OFFSET;
    hash_into(v, &mut h);
    h
}

const FNV_OFFSET: u64 = 0xcbf2_9ce4_8422_2325;
const FNV_PRIME: u64 = 0x0000_0100_0000_01b3;

fn mix_byte(h: &mut u64, b: u8) {
    *h = (*h ^ b as u64).wrapping_mul(FNV_PRIME);
}

fn mix_u64(h: &mut u64, v: u64) {
    for b in v.to_le_bytes() {
        mix_byte(h, b);
    }
}

fn hash_into(v: Value, h: &mut u64) {
    match v {
        // A per-kind tag byte keeps distinct kinds from colliding (e.g. `Int(1)`
        // and `Bool(true)`), matching `values_eq`'s variant check.
        Value::Int(n) => {
            mix_byte(h, 1);
            mix_u64(h, n as u64);
        }
        Value::Double(x) => {
            mix_byte(h, 2);
            // `values_eq` compares via `==`, under which `0.0 == -0.0`; canonicalize
            // so their bit patterns don't hash apart. (NaN never compares equal, so
            // its hash is immaterial.)
            let bits = if x == 0.0 { 0 } else { x.to_bits() };
            mix_u64(h, bits);
        }
        Value::Bool(b) => {
            mix_byte(h, 3);
            mix_byte(h, b as u8);
        }
        Value::Unit => mix_byte(h, 4),
        Value::Ref(handle) => hash_obj(&heap::clone_obj(handle), h),
    }
}

fn hash_obj(obj: &Obj, h: &mut u64) {
    match obj {
        Obj::Str(s) => {
            mix_byte(h, 5);
            for b in s.as_bytes() {
                mix_byte(h, *b);
            }
        }
        Obj::Bytes(b) | Obj::BytesBuilder(b) => {
            mix_byte(h, 6);
            for x in b {
                mix_byte(h, *x);
            }
        }
        Obj::List(items) => {
            mix_byte(h, 7);
            for &e in items {
                hash_into(e, h);
            }
        }
        Obj::Map(m) => {
            mix_byte(h, 8);
            for &(k, val) in m.entries() {
                hash_into(k, h);
                hash_into(val, h);
            }
        }
        Obj::Struct { ty, fields } => {
            mix_byte(h, 9);
            mix_u64(h, *ty as u64);
            for &e in fields {
                hash_into(e, h);
            }
        }
        Obj::Enum(e) => {
            mix_byte(h, 10);
            mix_u64(h, e.ty as u64);
            mix_u64(h, e.variant as u64);
            for &x in &e.fields {
                hash_into(x, h);
            }
        }
        // Closures as keys are exotic; hash the function id and let any collision
        // fall through to `values_eq` (which compares captures too).
        Obj::Closure { func, .. } => {
            mix_byte(h, 11);
            mix_u64(h, *func as u64);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn put(m: &mut MapObj, k: Value, v: Value) {
        let h = hash_value(k);
        m.insert(k, h, v);
    }
    fn got(m: &MapObj, k: Value) -> Option<Value> {
        m.get(k, hash_value(k))
    }
    fn int(n: i64) -> Value {
        Value::Int(n)
    }

    #[test]
    fn linear_below_threshold_then_hashed_above() {
        let mut m = MapObj::default();
        // Stay linear for a few, cross the threshold with many.
        let n = HASH_THRESHOLD as i64 * 4;
        for i in 0..n {
            put(&mut m, int(i), int(i * 10));
        }
        assert_eq!(m.len(), n as usize);
        assert!(!m.index.is_empty(), "index built past the threshold");
        for i in 0..n {
            assert_eq!(got(&m, int(i)), Some(int(i * 10)));
            assert!(m.contains(int(i), hash_value(int(i))));
        }
        assert_eq!(got(&m, int(n)), None);
        assert!(!m.contains(int(n), hash_value(int(n))));
    }

    #[test]
    fn update_keeps_position_and_count() {
        let mut m = MapObj::default();
        for i in 0..40 {
            put(&mut m, int(i), int(i));
        }
        put(&mut m, int(5), int(999));
        assert_eq!(m.len(), 40);
        assert_eq!(got(&m, int(5)), Some(int(999)));
        // Order is unchanged: entry 5 is still the 6th.
        assert_eq!(m.entries()[5], (int(5), int(999)));
    }

    #[test]
    fn insertion_order_preserved_across_threshold() {
        let mut m = MapObj::default();
        for i in 0..30 {
            put(&mut m, int(i), int(i));
        }
        let keys: Vec<i64> = m
            .entries()
            .iter()
            .map(|(k, _)| match k {
                Value::Int(n) => *n,
                _ => unreachable!(),
            })
            .collect();
        assert_eq!(keys, (0..30).collect::<Vec<_>>());
    }

    #[test]
    fn remove_rebuilds_and_stays_correct() {
        let mut m = MapObj::default();
        for i in 0..30 {
            put(&mut m, int(i), int(i));
        }
        assert_eq!(m.remove(int(10), hash_value(int(10))), Some(int(10)));
        assert_eq!(m.remove(int(0), hash_value(int(0))), Some(int(0)));
        assert_eq!(m.remove(int(999), hash_value(int(999))), None);
        assert_eq!(m.len(), 28);
        // Everything else is still findable through the rebuilt index.
        for i in 1..30 {
            if i == 10 {
                assert_eq!(got(&m, int(i)), None);
            } else {
                assert_eq!(got(&m, int(i)), Some(int(i)));
            }
        }
    }

    #[test]
    fn string_keys_match_by_content_not_handle() {
        let mut m = MapObj::default();
        for i in 0..30 {
            put(&mut m, Value::new_str(format!("k{i}")), int(i));
        }
        // A freshly-allocated, distinct-handle string with equal content resolves.
        for i in 0..30 {
            let probe = Value::new_str(format!("k{i}"));
            assert_eq!(got(&m, probe), Some(int(i)));
        }
        assert_eq!(got(&m, Value::new_str("absent".to_string())), None);
    }

    #[test]
    fn equal_values_hash_equal() {
        assert_eq!(
            hash_value(Value::new_str("hello".to_string())),
            hash_value(Value::new_str("hello".to_string()))
        );
        // 0.0 and -0.0 are `==`, so they must hash together.
        assert_eq!(
            hash_value(Value::Double(0.0)),
            hash_value(Value::Double(-0.0))
        );
    }

    #[test]
    fn from_pairs_dedups_last_wins() {
        let m = MapObj::from_pairs(vec![(int(1), int(1)), (int(2), int(2)), (int(1), int(100))]);
        assert_eq!(m.len(), 2);
        assert_eq!(got(&m, int(1)), Some(int(100)));
        // The updated key keeps its original (first) position.
        assert_eq!(m.entries()[0], (int(1), int(100)));
    }
}
