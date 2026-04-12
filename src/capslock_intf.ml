open! Base

module Capsule := Capsule.Expert

module type Capslock = sig @@ portable
  (** Deadlock-free leveled locking for OxCaml capsules.

      Capslock extends OxCaml's capsule system with level-ordered mutexes. Each mutex has a
      type-level Peano number, and a linear {!guard} tracks the current floor. Acquiring a
      lock requires the mutex's level to exceed the guard's floor -- enforced by the type
      checker. Out-of-order acquisition is a compile error, eliminating deadlocks.

      Guards are only obtainable through capslock's concurrency entry points ({!parallel},
      {!fork_join2}), ensuring exactly one guard per sequential execution context. The guard
      does not cross portability, so it cannot be captured by forked tasks.

      {1 Type-level Peano naturals} *)

  (** The zero level. *)
  type z

  (** The successor of level ['n]. *)
  type 'n s

  (** {2 Named levels}

      Use these functors to give meaningful names to levels. Inserting a new level between
      two existing ones only requires changing one parent reference.

      {[
        module L_db    = Level.Next (Level.Base)   (* level 1 *)
        module L_cache = Level.Next (L_db)          (* level 2 *)
      ]} *)

  module type LEVEL = sig
    type t
  end

  module Level : sig
    module Base : LEVEL with type t = z
    module Next (L : sig type t end) : LEVEL with type t = L.t s
  end

  (** {1 Ordering proofs}

      A [('lo, 'hi) lt] is a compile-time witness that level ['lo] is strictly less than
      level ['hi]. The GADT is uninhabitable for reversed orderings -- attempting to
      construct a proof of [(n3, n1) lt] is a type error.

      For successor levels, use {!Mutex.with_lock} which needs no proof. For arbitrary
      jumps, construct a proof manually:
      - [Base] proves [n < n+1]
      - [Step proof] extends: if [m < n] then [m < n+1]

      Example: [Step (Step Base) : (z, z s s s) lt] proves [0 < 3]. *)

  type ('lo, 'hi) lt = Base : ('n, 'n s) lt | Step : ('m, 'n) lt -> ('m, 'n s) lt

  (** {2 Pre-built proofs} *)

  type n0 = z
  type n1 = n0 s
  type n2 = n1 s
  type n3 = n2 s
  type n4 = n3 s
  type n5 = n4 s

  val lt_0_1 : (n0, n1) lt
  val lt_0_2 : (n0, n2) lt
  val lt_0_3 : (n0, n3) lt
  val lt_0_4 : (n0, n4) lt
  val lt_0_5 : (n0, n5) lt
  val lt_1_2 : (n1, n2) lt
  val lt_1_3 : (n1, n3) lt
  val lt_1_4 : (n1, n4) lt
  val lt_1_5 : (n1, n5) lt
  val lt_2_3 : (n2, n3) lt
  val lt_2_4 : (n2, n4) lt
  val lt_2_5 : (n2, n5) lt
  val lt_3_4 : (n3, n4) lt
  val lt_3_5 : (n3, n5) lt
  val lt_4_5 : (n4, n5) lt

  (** {1 Guard}

      A ['n guard] is a linear token tracking the current floor level. It is consumed when
      acquiring a lock and returned (at the original level) when the lock is released.

      Guards are abstract (cannot be forged), unique (cannot be duplicated), and do not
      cross portability (cannot be captured by forked tasks). The only way to obtain a guard
      is through {!parallel} or {!fork_join2}. *)

  type 'n guard

  (** {1 Concurrency entry points}

      These are the only way to obtain a {!guard}. Each spawned task receives its own fresh
      guard at level {!z}. The guard cannot escape into other tasks because it does not
      cross portability. *)

  (** [parallel scheduler ~f] runs [f] on the scheduler with a fresh guard. This is the
      top-level entry point for capslock-guarded computation.

      Wraps {!Parallel_scheduler.parallel}. *)
  val parallel
    :  Parallel_scheduler.t
    -> f:(Parallel.t @ local -> z guard @ unique -> 'a) @ once
    -> 'a

  (** [fork_join2 par f1 f2] forks two tasks, each receiving its own fresh guard. The
      caller's guard is unaffected (it does not cross portability so cannot be captured by
      [f1] or [f2]).

      Wraps {!Parallel.fork_join2}. *)
  val fork_join2
    :  Parallel.t @ local
    -> (Parallel.t @ local -> z guard @ unique -> 'a) @ local once
    -> (Parallel.t @ local -> z guard @ unique -> 'b) @ once portable
    -> #('a * 'b)

  (** {1 Leveled mutex}

      Mirrors {!Await_sync.Mutex}, adding a level parameter and guard threading. *)

  module Mutex : sig

    (** [('k, 'n) t] is a mutex protecting the contents of the ['k] capsule at level
        ['n]. *)
    type ('k, 'n) t

    (** [create key] creates a new leveled mutex for the capsule ['k] associated with
        [key], consuming the key. The level ['n] is determined by type annotation or
        inference.

        {[
          module L = Level.Next (Level.Base)
          let mutex : (_, L.t) Mutex.t = Mutex.create key
        ]} *)
    val create : 'k Capsule.Key.t @ unique -> ('k, 'n) t

    (** {2 Successor acquisition (no proof needed)}

        These functions acquire a mutex at level ['n s] given a guard at level ['n]. The
        successor relationship is enforced by type unification -- no explicit proof
        required. *)

    (** [with_lock w mutex guard ~f] acquires [mutex] at the next level, runs [f] with a
        password for the associated capsule and an elevated guard, then releases the mutex.

        The guard is consumed on entry and restored (at its original level) on exit. Inside
        [f], the elevated guard may be used to acquire further locks at even higher levels.

        @raise Poisoned if [mutex] cannot be acquired because it is poisoned.
        @raise Terminated if [w] is terminated before the mutex is acquired. *)
    val with_lock
      : ('a : value_or_null) 'k 'n.
      Await.t @ local
      -> ('k, 'n s) t @ local
      -> 'n guard @ unique
      -> f:('k Capsule.Password.t @ local -> 'n s guard @ unique -> 'a @ unique)
         @ local once
      -> #('a * 'n guard) @ unique

    (** {2 Arbitrary acquisition (with proof)}

        These functions acquire a mutex at any level ['level] given a guard at level
        ['floor], provided you supply a [('floor, 'level) lt] proof. *)

    (** [with_lock_at w mutex guard proof ~f] is like {!with_lock}, but acquires at an
        arbitrary higher level using an explicit ordering proof.

        {[
          Mutex.with_lock_at w mutex guard (Step (Step Base)) ~f:(fun pw _guard -> 42)
        ]}

        @raise Poisoned if [mutex] cannot be acquired because it is poisoned.
        @raise Terminated if [w] is terminated before the mutex is acquired. *)
    val with_lock_at
      : ('a : value_or_null) 'k 'floor 'level.
      Await.t @ local
      -> ('k, 'level) t @ local
      -> 'floor guard @ unique
      -> ('floor, 'level) lt
      -> f:('k Capsule.Password.t @ local -> 'level guard @ unique -> 'a @ unique)
         @ local once
      -> #('a * 'floor guard) @ unique
  end

  (** {1 Bundled data + leveled mutex}

      Mirrors {!Await_capsule.With_mutex}, adding a level parameter and guard
      threading. *)

  module With_mutex : sig

    (** [('a, 'n) t] is a value of type ['a] in its own capsule, protected by a leveled
        mutex at level ['n]. *)
    type ('a, 'n) t

    (** [create f] runs [f] within a fresh capsule and creates a {!With_mutex.t}
        containing the result. The level ['n] is determined by type annotation or
        inference.

        {[
          module L = Level.Next (Level.Base)
          let counter : (int ref, L.t) With_mutex.t =
            With_mutex.create (fun () -> ref 0)
        ]} *)
    val create : (unit -> 'a) @ local once portable -> ('a, 'n) t

    (** {2 Successor acquisition} *)

    (** [with_lock w t guard ~f] acquires the mutex in [t] at the next level, runs [f]
        with the protected data and an elevated guard, then releases the mutex. *)
    val with_lock
      : 'a ('b : value_or_null) 'n.
      Await.t @ local
      -> ('a, 'n s) t
      -> 'n guard @ unique
      -> f:('a -> 'n s guard @ unique -> 'b @ contended portable unique)
         @ local once portable
      -> #('b * 'n guard) @ contended portable unique

    (** {2 Arbitrary acquisition} *)

    (** [with_lock_at w t guard proof ~f] is like {!with_lock}, but acquires at an
        arbitrary higher level using an explicit ordering proof. *)
    val with_lock_at
      : 'a ('b : value_or_null) 'floor 'level.
      Await.t @ local
      -> ('a, 'level) t
      -> 'floor guard @ unique
      -> ('floor, 'level) lt
      -> f:('a -> 'level guard @ unique -> 'b @ contended portable unique)
         @ local once portable
      -> #('b * 'floor guard) @ contended portable unique
  end

  (** {1 Shadowed modules}

      The following modules shadow their unguarded counterparts from {!Capsule} to prevent
      accidental use of unordered mutexes. If you [open Capslock], references to
      [Capsule.Mutex] and [Capsule.With_mutex] will resolve to these empty modules,
      producing a compile error. Use {!Capslock.Mutex} and {!Capslock.With_mutex}
      instead.

      This follows the same pattern as [Base] shadowing [Stdlib]. *)

  module Capsule : sig
    include module type of struct
      include Capsule
    end

    (** @closed *)
    module Mutex : sig end

    (** @closed *)
    module With_mutex : sig end
  end
end
