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
module L_a = Capslock.Level.Next (Capslock.Level.Base)  (* level 1 *)
module L_b = Capslock.Level.Next (L_a)                  (* level 2 *)

let mutex_a : (_, L_a.t) Capslock.Mutex.t = Capslock.Mutex.create key_a
let mutex_b : (_, L_b.t) Capslock.Mutex.t = Capslock.Mutex.create key_b

(* Correct: A then B -- compiles *)
Capslock.parallel scheduler ~f:(fun par guard ->
  let #(result, guard) =
    Capslock.Mutex.with_lock w mutex_a guard ~f:(fun pw_a guard ->
      Capslock.Mutex.with_lock w mutex_b guard ~f:(fun pw_b guard ->
        #(do_work pw_a pw_b, guard)))
  in
  ignore guard;
  result)

(* Wrong: B then A -- TYPE ERROR *)
```

## Key concepts

**Levels** are type-level Peano naturals (`z`, `z s`, `z s s`, ...). Named
via functors for cross-module stability:

```ocaml
module L_db    = Capslock.Level.Next (Capslock.Level.Base)
module L_cache = Capslock.Level.Next (L_db)
```

**Guard** (`'n guard`) tracks the floor level. Non-portable (can't leak into
forked tasks), unique (can't be duplicated), abstract (can't be forged). Only
obtainable through `Capslock.parallel` or `Capslock.fork_join2`.

**`with_lock`** acquires the next level -- no proof needed, types do the work.

**`with_lock_at`** acquires an arbitrary higher level with an explicit `lt` proof:

```ocaml
Capslock.Mutex.with_lock_at w mutex guard (Step (Step Base)) ~f:...
```

**Shadowing**: `open Capslock` shadows `Capsule.Mutex` and `Capsule.With_mutex`
to prevent accidental use of unordered locks (like `Base` shadows `Stdlib`).

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
  Capslock.With_mutex.with_lock w counter guard ~f:(fun r guard ->
    r := !r + 1;
    #((), guard))
```

### Forking

Each forked task gets its own guard. The parent's guard is non-portable
so it can't be captured by the children:

```ocaml
Capslock.parallel scheduler ~f:(fun par guard ->
  let #(result_a, result_b) =
    Capslock.fork_join2 par
      (fun par guard ->
        Capslock.Mutex.with_lock w mutex_a guard ~f:(fun pw guard ->
          #(work_a pw, guard)))
      (fun par guard ->
        Capslock.Mutex.with_lock w mutex_a guard ~f:(fun pw guard ->
          #(work_b pw, guard)))
  in
  ignore guard;
  result_a + result_b)
```

## Glossary

| Concept          | OxCaml            | Surelock (Rust)            | Capslock                  |
| ---------------- | ----------------- | -------------------------- | ------------------------- |
| Lock             | `'k Mutex.t`      | `Mutex<T, Level<N>>`       | `('k, 'n) Mutex.t`        |
| Lock + data      | `'a With_mutex.t` | `Mutex<T>`                 | `('a, 'n) With_mutex.t`   |
| Lock level       | --                | `Level<N>`                 | `'n` (Peano type)         |
| Floor tracker    | --                | `MutexKey<N>`              | `'n guard`                |
| Level definition | --                | Trait / macro              | `Level.Next` functor      |
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
