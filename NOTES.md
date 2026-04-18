# Notes

## Source files

All from opam switch `5.2.0+ox` (package versions `v0.18~preview.130.83+317`):

- Capsule Expert: `~/.opam/5.2.0+ox/.opam-switch/sources/capsule0.v0.18~preview.130.83+317/expert/capsule_expert.mli`
- Capsule Blocking Sync (deprecated): `~/.opam/5.2.0+ox/.opam-switch/sources/capsule0.v0.18~preview.130.83+317/blocking_sync/capsule_blocking_sync.mli`
- Await Mutex (base, takes Key): `~/.opam/5.2.0+ox/.opam-switch/sources/await.v0.18~preview.130.83+317/sync/mutex.mli`
- Await Capsule (convenience wrapper): `~/.opam/5.2.0+ox/.opam-switch/sources/await.v0.18~preview.130.83+317/capsule/await_capsule_intf.ml`
- Parallel Kernel (portable, has `fork_join2`, `Biased.fork_join2`): `~/.opam/5.2.0+ox/.opam-switch/sources/parallel.v0.18~preview.130.83+317/kernel/parallel_kernel.mli`
- Parallel Scheduler (nonportable, has `parallel`, `create`, `stop`): `~/.opam/5.2.0+ox/.opam-switch/sources/parallel.v0.18~preview.130.83+317/scheduler/parallel_scheduler.mli`

## API layers

There are three layers of mutex API:

### 1. `Capsule_blocking_sync.Mutex` (deprecated base layer)

No scheduler token. Blocks the OS thread. Marked `[@@@alert deprecated]` — use
`Await` instead.

```ocaml
val with_lock
  : ('a : value_or_null) 'k.
  'k t
  -> f:('k Capsule.Password.t @ local -> 'a @ once unique) @ local once
  -> 'a @ once unique
```

Gives `Password.t`. This is what the oxcaml.org docs show.

### 2. `Await.Mutex` (the layer capslock should build on)

Scheduler-aware. Takes `Await.t` to yield instead of blocking.
Three credential levels, each with different mode constraints:

#### `with_access` -> `Access.t` (standard)

```ocaml
val with_access
  : ('a : value_or_null) 'k.
  Await.t @ local
  -> 'k t @ local
  -> f:('k Capsule.Access.t -> 'a @ contended once portable unique)
     @ local once portable
  -> 'a @ contended once portable unique
```

- Callback must be `portable`
- Return must be `contended portable`

#### `with_password` -> `Password.t` (expert)

```ocaml
val with_password
  : ('a : value_or_null) 'k.
  Await.t @ local
  -> 'k t @ local
  -> f:('k Capsule.Password.t @ local -> 'a @ unique) @ local once
  -> 'a @ unique
```

- Callback does NOT need to be `portable`
- Return only needs `unique`

#### `with_key` -> `Key.t @ unique` (expert)

```ocaml
val with_key
  : ('a : value_or_null) 'k.
  Await.t @ local
  -> 'k t @ local
  -> f:('k Capsule.Key.t @ unique -> #('a * 'k Capsule.Key.t) @ l once unique)
     @ local once
  -> 'a @ l once unique
```

- Most powerful: receives the unique Key
- Must return the Key back in a pair

#### Poisoning variants

Each of the above has a `_poisoning` variant that poisons the mutex if `f` raises.

#### Cancellation variants

Each has an `_or_cancel` variant taking `Cancellation.t` and returning
`'a Or_canceled.t`.

#### Other operations

```ocaml
(* Guard-based API — acquire/release with arbitrary dynamic scope *)
val acquire : Await.t @ local -> 'k t -> 'k Guard.t @ unique
module Guard : sig
  val with_key : ...
  val with_password : ...
  val access : ...
  val release : 'k t @ unique -> unit
  val poison : 'k t @ unique -> 'k Capsule.Key.t @ unique
end

(* Release temporarily (for condition variable patterns) *)
val release_temporarily : Await.t @ local -> 'k t @ local
  -> 'k Capsule.Key.t @ unique
  -> f:(unit -> 'a @ unique) @ local once
  -> #('a * 'k Capsule.Key.t) @ unique

(* Poison without acquiring *)
val acquire_and_poison : Await.t @ local -> 'k t @ local -> 'k Capsule.Key.t @ unique
val poison_unacquired : 'k t @ local -> unit
val is_poisoned : 'k t @ local -> bool

(* Condition variables *)
module Condition : ...
```

### 3. `Await_capsule.Mutex` (convenience wrapper, packed)

Wraps layer 2. Key differences from the old version:

- `create : unit -> packed` — takes no key. Internally calls `Capsule.Expert.create ()`
  to mint a fresh capsule, then uses the resulting key to build an
  `Await_sync.Mutex.t`. The `'k` is existentially packed.
- `type 'k t = 'k Await_sync.Mutex.t` — same underlying type as layer 2, just the
  `'k` is hidden by the packed wrapper.
- `with_lock` wraps `with_access` (gives `Access.t`), using the
  `{ global; aliased; many }` trick to escape the `@ once unique` return.

Why we don't use it: the packed existential makes `'k` awkward to thread for
multi-mutex-per-capsule scenarios, and `with_lock`'s weaker return modes lose
precision. Capslock builds on layer 2 (`Await_sync.Mutex`) for `Mutex` and on
`Await_capsule.With_mutex` for bundled use.

### 4. `Await_capsule.With_mutex` (bundled data + lock)

- `create : (unit -> 'a) @ local once portable -> 'a t` — runs `f` in a fresh
  capsule, bundles data + mutex.
- `with_lock : Await.t @ local -> 'a t -> f:('a -> 'b @ contended portable) -> ...`
- Return mode is `@ contended portable` (no `unique`, `once`), weaker than the
  layer-2 `with_access`.

### Summary

| API              | Credential     | `f` portable | Return `contended portable` |
|------------------|----------------|--------------|----------------------------|
| `with_access`    | `Access.t`     | Yes          | Yes                        |
| `with_password`  | `Password.t`   | No           | No                         |
| `with_key`       | `Key.t`        | No           | No                         |

### Naming inconsistency

- Base `Capsule.Mutex.with_lock` gives `Password.t`
- `Await_capsule.Mutex.with_lock` gives `Access.t` (wraps `with_access`)
- Same name, different credential

Capslock uses `with_access` / `with_access_at` (not `with_lock`) to match the
underlying `Await.Mutex` naming and make the credential type explicit. This avoids
the ambiguity where `with_lock` means different things at different layers.
`Password.t`/`Key.t` expert variants are a TODO.

## Credential types (`Capsule.Expert`)

### `Access.t`

```ocaml
type 'k t : void mod aliased external_ global many portable
```

Token for wrapping/unwrapping `Data.t`. Used with `Data.wrap ~access`,
`Data.unwrap ~access`. The "safe" API — forces `portable` callback and
`contended portable` return.

### `Password.t`

```ocaml
type 'k t : void mod contended external_ portable unyielding
```

Permission to access capsule `'k`. Always `@ local` (can't escape callback).
More flexible than `Access.t` — no `portable` requirement on callback.
Has `Password.Shared` submodule for read-only access.

Can convert: `Password.t` -> `Access.t` via `Capsule.access ~password ~f`
(runs `f` with `Access.t` derived from the password).

### `Key.t`

```ocaml
type 'k t : void mod contended external_ forkable many portable unyielding
```

Ownership of capsule `'k`. `@ unique` means exclusive. `@ aliased` means
permanently shared (read-only). Can derive `Password.t` via `Key.with_password`.

## Functor approach (removed)

An earlier version used functors (`Level.Next`, `Level.Base`) to define named
levels, with the idea that they could also improve ergonomics around ordering
proofs. In practice they added module-level machinery for what plain type aliases
already handle, so they were removed in favour of simple `type level_foo = z s`
definitions.

## Mode / kind annotations

Every annotation in the interface falls into one of three buckets:

- **Mirror of underlying** — inherited from `Await_sync.Mutex`, `Await_capsule.With_mutex`,
  `Parallel_scheduler.parallel`, or `Parallel_kernel.fork_join2`. Changing these would
  mean Capslock silently differs from what it wraps.
- **Guard discipline** — what makes the deadlock-free guarantee actually enforceable
  (uniqueness, non-portability, level threading).
- **OxCaml mechanics** — purely to coax the type checker (e.g. injectivity markers,
  `exclave_`, explicit lambda-parameter mode annotations in the impl).

### Type kinds

| Declaration | Annotation | Purpose | Underlying |
|---|---|---|---|
| `type !'n s` | `!` (injectivity) | GADT `Step` needs `'n` recoverable from `'n s`. | — |
| `type 'n guard : value` | kind `value`, *no* `mod portable` | Withholds `portable` from callers so the parent's guard can't be captured by a `@ shareable` child. | — (guard discipline) |
| `('k, 'n) Mutex.t : value mod contended portable` | kind | Mirror. | `Await_sync.Mutex.t` |
| `('a, 'n) With_mutex.t : value mod contended portable` | kind | Mirror. | `Await_capsule.With_mutex.t` |

### `parallel`

Wraps `Parallel_scheduler.parallel : t -> f:(parallel @ local -> 'a) @ once shareable -> 'a`.

| Position | Mode | Purpose |
|---|---|---|
| `Parallel_kernel.t @ local` | `@ local` | Mirror. |
| `z guard @ unique` | `@ unique` | Guard discipline (linear). |
| `f ... @ once shareable` | `@ once shareable` | Mirror. `once` = called exactly once; `shareable` = safe to pass to the scheduler. |

No `@@ portable` on `parallel` itself — `Parallel_scheduler` is a nonportable
entry point (called from the main domain to set up parallelism).

### `fork_join2`

Wraps `Parallel_kernel.fork_join2 : t @ local -> (t @ local -> 'a) @ forkable local once shareable -> (t @ local -> 'b) @ once shareable -> #('a * 'b)`.

| Position | Mode | Purpose |
|---|---|---|
| `Parallel_kernel.t @ local` | `@ local` | Mirror. |
| `z guard @ unique` (callback arg) | `@ unique` | Guard discipline. |
| First callback `@ forkable local once shareable` | Mirror | |
| Second callback `@ once shareable` | Mirror | Note: `@ shareable` is what blocks capture of the non-portable parent guard. |
| `#('a * 'b) @ local` | `@ local` | Falls out of `exclave_` in the impl. |
| `@@ portable` | portable | Mirror — `Parallel_kernel` is `@@ portable`. |

### `Mutex.create`

Wraps `Await_sync.Mutex.create : ?padded:bool @ local -> 'k Capsule.Key.t @ unique -> 'k t`.

| Position | Mode | Purpose |
|---|---|---|
| `?padded:bool @ local` | `@ local` | Mirror. |
| `'k Capsule.Key.t @ unique` | `@ unique` | Mirror (key is consumed). |
| `@@ portable` | portable | Mirror. |

### `Mutex.with_access` / `with_access_at`

Wraps `Await_sync.Mutex.with_access : Await.t @ local -> 'k t @ local -> f:('k Access.t -> 'a @ contended once portable unique) @ local once portable -> 'a @ contended once portable unique`.

| Position | Mode | Purpose |
|---|---|---|
| `Await.t @ local`, `('k, 'n s) t @ local` | `@ local` | Mirror. |
| `'n guard @ unique` (floor), `'n s guard @ unique` (elevated) | `@ unique` | Guard discipline. |
| Callback return `'a @ contended once portable unique` | Mirror | Strongest precision from the underlying. |
| Callback `@ local once portable` | Mirror | |
| Outer return `#('a * 'n guard) @ contended once portable unique` | Mirror | Preserved on the tuple. |
| `@@ portable` | portable | Mirror. |

`with_access_at` adds a `('floor, 'level) lt` proof (no mode — inert data).

### `With_mutex.create`

Wraps `Await_capsule.With_mutex.create : (unit -> 'a) @ local once portable -> 'a t`.

| Position | Mode | Purpose |
|---|---|---|
| Thunk `@ local once portable` | Mirror | Runs once in a fresh capsule. |
| `@@ portable` | portable | Mirror. |

### `With_mutex.with_lock` / `with_lock_at`

Wraps `Await_capsule.With_mutex.with_lock : Await.t @ local -> 'a t -> f:('a -> 'b @ contended portable) @ local once portable -> 'b @ contended portable`.

**Key difference from `Mutex.with_access`:** return is only `@ contended portable` —
no `unique` / `once`. `Await_capsule.With_mutex` uses the `{ global; aliased; many }`
wrapper trick internally, which drops those stricter modes. Capslock inherits this.

| Position | Mode | Purpose |
|---|---|---|
| `Await.t @ local` | `@ local` | Mirror. |
| `('a, 'n s) t` | — | Mirror (no `@ local`: contains a packed existential; needs to be global). |
| `'n guard @ unique`, `'n s guard @ unique` | `@ unique` | Guard discipline. |
| Callback return `'b @ contended portable` | Mirror | Weaker than the underlying `Mutex`. |
| Callback `@ local once portable`, outer return `#('b * 'n guard) @ contended portable`, `@@ portable` | Mirror | |

### Implementation-side

| Construct | Purpose |
|---|---|
| `let mint_guard () : _ @ unique = ()` | Produces a `@ unique` unit so we can pass the abstract `guard @ unique` argument the intf declares. |
| `fun (par @ local) -> ...` in lambda params | Matches the underlying's `par @ local` callback argument — required for the lambda to type-check against the underlying's signature. |
| Explicit `(f1 : (... -> unit @ unique -> 'a) @ forkable local once shareable)` type ascription | Forces inference to pick up `@ unique` on the middle arg and the full callback mode — would otherwise default to something laxer. |
| `exclave_` on the `fork_join2` body | Puts allocations in the caller's region so the closures can capture the local `f1` / `f2`. Side effect: the return tuple becomes `@ local`. |
