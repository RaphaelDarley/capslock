# Glossary

## Concept mapping

| Concept | OxCaml | Surelock (Rust) | Capslock |
|---------|--------|-----------------|----------|
| Lock | `'k Mutex.t` | `Mutex<T, Level<N>>` | `('k, 'n) Mutex.t` |
| Lock + data bundle | `'a With_mutex.t` | `Mutex<T>` | `('a, 'n) With_mutex.t` |
| Lock level | — | `Level<N>` | `'n` (Peano type) |
| Floor tracker | — | `MutexKey<N>` | `'n guard` |
| Level definition | — | Trait / macro | `Level.Next` functor |
| Ordering proof | — | Trait bounds | `('lo, 'hi) lt` GADT |
| Same-level group | — | `LockSet` | — (not yet) |
| Key distribution | — | `Locksmith` / `KeyVoucher` | `parallel` / `fork_join2` |

## OxCaml modes used

| Mode | Meaning |
|------|---------|
| `@ unique` | Single reference, no aliasing |
| `@ local` | Cannot escape current region |
| `@ once` | Closure called at most once |
| `@ portable` | Can cross domain boundaries |
| `@ contended` | May be accessed from multiple domains |
| `#(a * b)` | Unboxed tuple (no heap allocation) |
| `('a : value_or_null)` | Layout: boxed value or null |
