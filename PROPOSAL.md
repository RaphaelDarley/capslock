# Capslock: Deadlock-Free Leveled Locking for OxCaml

Capslock extends OxCaml's capsule system with **level-ordered mutexes**.
Each mutex has a type-level Peano number, and a linear **guard** tracks
the current floor.  Acquiring a lock requires the mutex's level to
exceed the guard's floor -- enforced by the type checker.  Out-of-order
acquisition is a compile error, eliminating deadlocks.

---

## The problem

With plain `Capsule.Mutex`, nothing prevents two domains from acquiring
mutex A then B, and B then A:

```ocaml
(* Domain 1 *)
Capsule.Mutex.with_lock mutex_a ~f:(fun pw_a ->
  Capsule.Mutex.with_lock mutex_b ~f:(fun pw_b ->
    (* ... *)))

(* Domain 2 -- opposite order => DEADLOCK *)
Capsule.Mutex.with_lock mutex_b ~f:(fun pw_b ->
  Capsule.Mutex.with_lock mutex_a ~f:(fun pw_a ->
    (* ... *)))
```

Both compile.  Both can deadlock at runtime.

---

## Capslock's solution

Capslock adds a **level** (Peano-encoded type) to each mutex, and
threads a **guard** through lock acquisitions.  The type system
enforces strictly ascending order.

### Types

```ocaml
(* Type-level Peano naturals *)
type z                    (* zero *)
type 'n s                 (* successor *)

(* Named levels -- use these for cross-module consistency *)
module type LEVEL = sig type t end
module Level : sig
  module Base : LEVEL with type t = z
  module Next (L : sig type t end) : LEVEL with type t = L.t s
end

(* Ordering proof *)
type ('lo, 'hi) lt =
  | Base : ('n, 'n s) lt              (* n < n+1 *)
  | Step : ('m, 'n) lt -> ('m, 'n s) lt   (* m < n => m < n+1 *)

(* Guard -- tracks the floor level; abstract, unique *)
type 'n guard
val create_guard : unit -> z guard

(* Leveled mutex *)
module Mutex : sig
  type ('k, 'n) t

  val create : 'k Capsule.Key.t @ unique -> ('k, 'n) t

  (* Acquire at successor level -- no proof needed *)
  val with_lock
    :  Await.t @ local -> ('k, 'n s) t @ local -> 'n guard @ unique
    -> f:('k Capsule.Password.t @ local -> 'n s guard @ unique
          -> 'a * 'n s guard) @ local once
    -> 'a * 'n guard

  (* Acquire at arbitrary level -- requires lt proof *)
  val with_lock_at
    :  Await.t @ local -> ('k, 'level) t @ local -> 'floor guard @ unique
    -> ('floor, 'level) lt
    -> f:('k Capsule.Password.t @ local -> 'level guard @ unique
          -> 'a * 'level guard) @ local once
    -> 'a * 'floor guard
end

(* Bundled data + leveled mutex *)
module With_mutex : sig
  type ('a, 'n) t

  val create : (unit -> 'a) @ local once portable -> ('a, 'n) t

  val with_lock
    :  Await.t @ local -> ('a, 'n s) t -> 'n guard @ unique
    -> f:('a -> 'n s guard @ unique -> 'b * 'n s guard) @ local once portable
    -> 'b * 'n guard

  val with_lock_at
    :  Await.t @ local -> ('a, 'level) t -> 'floor guard @ unique
    -> ('floor, 'level) lt
    -> f:('a -> 'level guard @ unique -> 'b * 'level guard) @ local once portable
    -> 'b * 'floor guard
end
```

---

## Examples

### Basic: single mutex (unchanged from capsule API)

**Before (Capsule.Mutex):**
```ocaml
let (P key) = Capsule.create () in
let mutex = Capsule.Mutex.create key in
let capsule_ref = Capsule.Data.create (fun () -> ref 0) in
Capsule.Mutex.with_lock mutex ~f:(fun password ->
  Capsule.Data.iter capsule_ref ~password ~f:(fun ref ->
    ref := !ref + 1))
```

**After (Capslock):**
```ocaml
let (P key) = Capsule.create () in
let mutex = Capslock.Mutex.create key in
let capsule_ref = Capsule.Data.create (fun () -> ref 0) in
let guard = Capslock.create_guard () in
let (), guard =
  Capslock.Mutex.with_lock w mutex guard ~f:(fun password guard ->
    Capsule.Data.iter capsule_ref ~password ~f:(fun ref ->
      ref := !ref + 1);
    (), guard)
```

The guard is threaded through: consumed on entry, returned on exit.

---

### Two mutexes: ordering enforced

**Before (Capsule.Mutex) -- compiles but can deadlock:**
```ocaml
(* Domain 1: A then B *)
Capsule.Mutex.with_lock mutex_a ~f:(fun pw_a ->
  Capsule.Mutex.with_lock mutex_b ~f:(fun pw_b ->
    do_work pw_a pw_b))

(* Domain 2: B then A -- compiles! deadlock! *)
Capsule.Mutex.with_lock mutex_b ~f:(fun pw_b ->
  Capsule.Mutex.with_lock mutex_a ~f:(fun pw_a ->
    do_work pw_a pw_b))
```

**After (Capslock) -- wrong order is a type error:**
```ocaml
(* Declare an ordering *)
module L_a = Capslock.Level.Next (Capslock.Level.Base)  (* level 1 *)
module L_b = Capslock.Level.Next (L_a)                  (* level 2 *)

let mutex_a : (_, L_a.t) Capslock.Mutex.t = Capslock.Mutex.create key_a
let mutex_b : (_, L_b.t) Capslock.Mutex.t = Capslock.Mutex.create key_b

(* Correct: A (level 1) then B (level 2) *)
let guard = Capslock.create_guard () in
let result, guard =
  Capslock.Mutex.with_lock w mutex_a guard ~f:(fun pw_a guard ->
    let inner, guard =
      Capslock.Mutex.with_lock w mutex_b guard ~f:(fun pw_b guard ->
        do_work pw_a pw_b, guard)
    in
    inner, guard)

(* WRONG: B then A -- TYPE ERROR *)
(* Capslock.Mutex.with_lock w mutex_b guard ~f:(fun pw_b guard ->
     Capslock.Mutex.with_lock w mutex_a guard ~f:...
     (* Error: mutex_a is at L_a.t = z s
        but guard is at L_b.t = z s s
        z s s s ≠ z s -- type mismatch! *)
   ) *)
```

---

### Quicksort with capslock

**Before (Capsule.Mutex):**
```ocaml
let quicksort ~scheduler ~mutex array =
  let monitor = Parallel.Monitor.create_root () in
  Parallel_scheduler_work_stealing.schedule scheduler ~monitor
    ~f:(fun parallel ->
      Capsule.Mutex.with_lock mutex ~f:(fun password ->
        Capsule.Data.iter array ~password ~f:(fun array ->
          let array = Par_array.of_array array in
          quicksort parallel (Slice.slice array))))
```

**After (Capslock):**
```ocaml
let quicksort ~scheduler ~mutex ~guard array =
  let monitor = Parallel.Monitor.create_root () in
  Parallel_scheduler_work_stealing.schedule scheduler ~monitor
    ~f:(fun parallel ->
      let (), guard =
        Capslock.Mutex.with_lock w mutex guard ~f:(fun password guard ->
          Capsule.Data.iter array ~password ~f:(fun array ->
            let array = Par_array.of_array array in
            quicksort parallel (Slice.slice array));
          (), guard)
      in
      ignore guard)
```

The guard ensures that if quicksort acquires any other mutexes
internally, they must be at a higher level.

---

### Image processing with capslock

**Before (Capsule.Mutex):**
```ocaml
let filter ~scheduler ~mutex image =
  let monitor = Parallel.Monitor.create_root () in
  Parallel_scheduler_work_stealing.schedule scheduler ~monitor
    ~f:(fun parallel ->
      let width = Image.width (Capsule.Data.project image) in
      let height = Image.height (Capsule.Data.project image) in
      let data =
        Par_array.init parallel (width * height) ~f:(fun i ->
          let x = i % width in
          let y = i / width in
          Capsule.Mutex.with_lock mutex ~f:(fun password ->
            Capsule.access ~password ~f:(fun access ->
              let image = Capsule.Data.unwrap image ~access in
              blur_at image ~x ~y)))
      in
      Image.of_array (Par_array.to_array data) ~width ~height)
```

**After (Capslock):**
```ocaml
let filter ~scheduler ~mutex ~guard image =
  let monitor = Parallel.Monitor.create_root () in
  Parallel_scheduler_work_stealing.schedule scheduler ~monitor
    ~f:(fun parallel ->
      let width = Image.width (Capsule.Data.project image) in
      let height = Image.height (Capsule.Data.project image) in
      let data =
        Par_array.init parallel (width * height) ~f:(fun i ->
          let x = i % width in
          let y = i / width in
          let pixel, guard =
            Capslock.Mutex.with_lock w mutex guard ~f:(fun password guard ->
              Capsule.access ~password ~f:(fun access ->
                let image = Capsule.Data.unwrap image ~access in
                blur_at image ~x ~y),
              guard)
          in
          ignore guard;
          pixel)
      in
      Image.of_array (Par_array.to_array data) ~width ~height)
```

---

### Using With_mutex (bundled data + lock)

**Before (Capsule.With_mutex):**
```ocaml
let counter = Capsule.With_mutex.create (fun () -> ref 0)

let increment w =
  Capsule.With_mutex.with_lock w counter ~f:(fun r -> r := !r + 1)

let get w =
  Capsule.With_mutex.with_lock w counter ~f:(fun r -> !r)
```

**After (Capslock.With_mutex):**
```ocaml
let counter = Capslock.With_mutex.create (fun () -> ref 0)

let increment w guard =
  Capslock.With_mutex.with_lock w counter guard ~f:(fun r guard ->
    r := !r + 1;
    (), guard)

let get w guard =
  Capslock.With_mutex.with_lock w counter guard ~f:(fun r guard ->
    !r, guard)
```

---

### Using with_lock_at to skip levels

When you need to jump past intermediate levels (e.g. acquire level 3
from floor 0), use `with_lock_at` with an explicit proof:

```ocaml
module L1 = Capslock.Level.Next (Capslock.Level.Base)
module L2 = Capslock.Level.Next (L1)
module L3 = Capslock.Level.Next (L2)

let mutex_c : (_, L3.t) Capslock.Mutex.t = Capslock.Mutex.create key_c

(* Jump from floor 0 to level 3 *)
let guard = Capslock.create_guard () in
let result, guard =
  Capslock.Mutex.with_lock_at w mutex_c guard
    (Step (Step Base))   (* proof: z < z s s s *)
    ~f:(fun pw guard -> 42, guard)
```

The proof `Step (Step Base)` is checked by the compiler:
- `Base : (z s s, z s s s) lt` -- level 2 < level 3
- `Step Base : (z s, z s s s) lt` -- level 1 < level 3
- `Step (Step Base) : (z, z s s s) lt` -- level 0 < level 3

No valid proof of `(z s s s, z s) lt` can be constructed --
the GADT is uninhabitable for wrong orderings.

---

## Summary of API differences

| Capsule API | Capslock API | Change |
|---|---|---|
| `'k Capsule.Mutex.t` | `('k, 'n) Capslock.Mutex.t` | adds level `'n` |
| `'a Capsule.With_mutex.t` | `('a, 'n) Capslock.With_mutex.t` | adds level `'n` |
| `with_lock mutex ~f` | `with_lock w mutex guard ~f` | adds guard |
| `f:(password -> 'a)` | `f:(password -> guard -> 'a * guard)` | threads guard |
| (no ordering) | levels + guard | deadlock prevention |
| (no `with_lock_at`) | `with_lock_at ... proof ~f` | arbitrary jumps |
