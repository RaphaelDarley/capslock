# Capslock

> [!NOTE]
> LLM tools have been used in the writing of this project.\
> However, all design decisions, for better or worse, have been made by me, and all code has either been written by hand or carefully reviewed. Though documentation and examples have had a less throurough going over.\
> I am also a Rustacean at heart, as is probably obvious, so any advice on improving APIs, or making the code more idiomatic would be most appreciated.

Deadlock-free leveled locking for OxCaml capsules. Requires [OxCaml](https://oxcaml.org).

Capslock extends OxCaml's capsule system with **level-ordered mutexes**.
Each mutex has a type-level Peano number, and a linear **guard** tracks
the current floor. Acquiring a lock requires the mutex's level to
exceed the guard's floor -- enforced by the type checker. Out-of-order
acquisition is a compile error, eliminating deadlocks.

Inspired by [surelock](https://notes.brooklynzelenka.com/Blog/Surelock) (Rust).

## The problem

With plain `Capsule.Mutex`, nothing prevents two domains from acquiring
mutex A then B, and B then A:

```ocaml
(* Domain 1 *)
Capsule.Mutex.with_lock mutex_a ~f:(fun pw_a ->
  Capsule.Mutex.with_lock mutex_b ~f:(fun pw_b -> (* ... *)))

(* Domain 2 -- opposite order => DEADLOCK *)
Capsule.Mutex.with_lock mutex_b ~f:(fun pw_b ->
  Capsule.Mutex.with_lock mutex_a ~f:(fun pw_a -> (* ... *)))
```

Both compile. Both can deadlock at runtime.

## The solution

Capslock assigns each mutex a type-level **level** and threads a linear
**guard** through lock acquisitions. The type system enforces strictly
ascending order.

```ocaml
type level_a = Capslock.z Capslock.s               (* level 1 *)
type level_b = level_a Capslock.s                   (* level 2 *)

let mutex_a : (_, level_a) Capslock.Mutex.t = Capslock.Mutex.create key_a
let mutex_b : (_, level_b) Capslock.Mutex.t = Capslock.Mutex.create key_b

(* Correct: A then B -- compiles *)
Capslock.parallel scheduler ~f:(fun par guard ->
  let #(result, _guard) =
    Capslock.Mutex.with_access w mutex_a guard ~f:(fun access_a guard ->
      let #(work, _guard) =
        Capslock.Mutex.with_access w mutex_b guard ~f:(fun access_b _guard ->
          do_work access_a access_b)
      in
      work)
  in
  result)

(* Wrong: B then A -- TYPE ERROR *)
```

## Key concepts

**Levels** are type-level Peano naturals (`z`, `z s`, `z s s`, ...). Use type
aliases to give meaningful names and chain levels:

```ocaml
type level_db    = Capslock.z Capslock.s
type level_cache = level_db Capslock.s
```

**Guard** (`'n guard`) tracks the floor level. Abstract, unique, and non-portable
(can't leak into forked tasks). Only obtainable via `Capslock.parallel` or
`Capslock.fork_join2`.

**`with_access`** acquires the next level -- no proof needed, types do the work.

**`with_access_at`** acquires an arbitrary higher level with an explicit `lt` proof:

```ocaml
Capslock.Mutex.with_access_at w mutex guard (Step (Step Base)) ~f:...
```

**No shadowing**: `Capsule.Mutex` stays accessible as an escape hatch.
`Capslock.Mutex.create` consumes the key, so the two can't protect the same
capsule.

## Examples

### With_mutex (bundled data + lock)

**Before:**
```ocaml
let counter = Capsule.With_mutex.create (fun () -> ref 0)

let increment w =
  Capsule.With_mutex.with_lock w counter ~f:(fun r -> r := !r + 1)
```

**After:**
```ocaml
let counter = Capslock.With_mutex.create (fun () -> ref 0)

let increment w guard =
  Capslock.With_mutex.with_lock w counter guard ~f:(fun r _guard ->
    r := !r + 1)
```

### Forking

Each forked task gets its own guard. The parent's guard is non-portable
so it can't be captured by the children:

```ocaml
Capslock.parallel scheduler ~f:(fun par _guard ->
  let #(result_a, result_b) =
    Capslock.fork_join2 par
      (fun par guard ->
        let #(work, _guard) =
          Capslock.Mutex.with_access w mutex_a guard ~f:(fun access _guard ->
            work_a access)
        in
        work)
      (fun par guard ->
        let #(work, _guard) =
          Capslock.Mutex.with_access w mutex_a guard ~f:(fun access _guard ->
            work_b access)
        in
        work)
  in
  result_a + result_b)
```

## Glossary

| Concept          | OxCaml            | Surelock (Rust)            | Capslock                  |
| ---------------- | ----------------- | -------------------------- | ------------------------- |
| Lock             | `'k Mutex.t`      | `Mutex<T, Level<N>>`       | `('k, 'n) Mutex.t`        |
| Lock + data      | `'a With_mutex.t` | `Mutex<T>`                 | `('a, 'n) With_mutex.t`   |
| Lock level       | --                | `Level<N>`                 | `'n` (Peano type)         |
| Floor tracker    | --                | `MutexKey<N>`              | `'n guard`                |
| Level definition | --                | Trait / macro              | Type alias with `s`       |
| Ordering proof   | --                | Trait bounds               | `('lo, 'hi) lt` GADT      |
| Same-level group | --                | `LockSet`                  | -- (not yet)              |
| Key distribution | --                | `Locksmith` / `KeyVoucher` | `parallel` / `fork_join2` |

## OxCaml modes used

| Mode          | Meaning                               |
| ------------- | ------------------------------------- |
| `@ unique`    | Single reference, no aliasing         |
| `@ local`     | Cannot escape current region          |
| `@ once`      | Closure called at most once           |
| `@ portable`  | Can cross domain boundaries           |
| `@ contended` | May be accessed from multiple domains |
| `#(a * b)`    | Unboxed tuple (no heap allocation)    |

## TODO

- Add cancellation support
- Add poisoning variants
- Add `Password.t` / `Key.t` expert variants (current API uses `Access.t` only)
- Add a `Sync`-based module (currently only `Await`)
- Completely replicate the capsule API (all `Capsule.Mutex` and `Capsule.With_mutex` operations)
- Biased `fork_join2` variant (wraps `Parallel_kernel.Biased.fork_join2`). Left task
  stays on the caller's domain, so to preserve deadlock-freedom the left closure
  would inherit the parent's guard via lexical capture rather than receiving a fresh
  one. Right still forks and gets a fresh guard.

## Notes

Capslock uses `with_access` / `with_access_at` rather than `with_lock`: it mirrors
`Await.Mutex` and makes the credential type explicit. `Capsule.Mutex.with_lock`
gives a `Password.t` but `Await_capsule.Mutex.with_lock` gives an `Access.t` — same
name, different credentials.
