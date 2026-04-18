open! Base

(** Deadlock-free leveled locking for OxCaml capsules.

  Deadlock requires circular wait (Coffman, 1971); a strict order on lock acquisition
  breaks cycles by construction. Capslock lifts that order into the type system: each
  mutex carries a type-level level, a linear {!guard} tracks the current floor, and
  acquiring requires the mutex's level to exceed the guard's. Out-of-order acquisition
  is a compile error.

  Inspired by {{:https://notes.brooklynzelenka.com/Blog/Surelock} surelock} (Rust). *)
module type Capslock = sig
  module Capsule := Capsule.Expert
  module Await := Await_kernel.Await

  (** {1 Type-level Peano naturals} *)

  (** The zero level. *)
  type z

  (** The successor of level ['n]. *)
  type !'n s

  (** {2 Named levels}

      Use type aliases to give meaningful names to levels. Inserting a new level between
      two existing ones only requires changing one parent reference.

      {[
        type level_db    = z s
        type level_cache = level_db s
      ]} *)

  (** {1 Ordering proofs}

      A [('lo, 'hi) lt] is a compile-time witness that level ['lo] is strictly less than
      level ['hi]. The GADT is uninhabitable for reversed orderings -- attempting to
      construct a proof of [(l3, l1) lt] is a type error.

      For successor levels, use {!Mutex.with_access} which needs no proof. For arbitrary
      jumps, construct a proof manually:
      - [Base] proves [n < n+1]
      - [Step proof] extends: if [m < n] then [m < n+1]

      Example: [Step (Step Base) : (l0, l3) lt] proves [0 < 3]. *)

  type ('lo, 'hi) lt =
    | Base : ('n, 'n s) lt
    | Step : 'm 'n. ('m, 'n) lt -> ('m, 'n s) lt

  (** {2 Pre-built proofs} *)

  type l0 = z
  type l1 = l0 s
  type l2 = l1 s
  type l3 = l2 s
  type l4 = l3 s
  type l5 = l4 s

  val lt_0_1 : (l0, l1) lt
  val lt_0_2 : (l0, l2) lt
  val lt_0_3 : (l0, l3) lt
  val lt_0_4 : (l0, l4) lt
  val lt_0_5 : (l0, l5) lt
  val lt_1_2 : (l1, l2) lt
  val lt_1_3 : (l1, l3) lt
  val lt_1_4 : (l1, l4) lt
  val lt_1_5 : (l1, l5) lt
  val lt_2_3 : (l2, l3) lt
  val lt_2_4 : (l2, l4) lt
  val lt_2_5 : (l2, l5) lt
  val lt_3_4 : (l3, l4) lt
  val lt_3_5 : (l3, l5) lt
  val lt_4_5 : (l4, l5) lt

  (** {1 Guard}

      A ['n guard] is a linear token tracking the current floor level. Consumed on lock
      acquisition, restored at the original level on release. Abstract, unique, and
      non-portable (cannot cross into forked tasks). Only obtainable via {!parallel} or
      {!fork_join2}.

      The [: value] kind withholds [portable] from callers even though the concrete
      impl is [unit] -- otherwise a [@ portable] child could capture the parent's
      guard. *)

  type 'n guard : value

  (** {1 Concurrency entry points}

      Each spawned task gets a fresh guard at level {!z}. *)

  (** [parallel scheduler ~f] runs [f] on the scheduler with a fresh guard. Top-level
      entry point; not portable. Wraps {!Parallel_scheduler.parallel}. *)
  val parallel
    :  Parallel_scheduler.t
    -> f:(Parallel_kernel.t @ local -> z guard @ unique -> 'a) @ once shareable
    -> 'a

  (** [fork_join2 par f1 f2] forks two tasks with fresh guards. Both callbacks are
      [@ shareable] so cannot capture the parent's guard. Wraps
      {!Parallel_kernel.fork_join2}. *)
  val fork_join2
    :  Parallel_kernel.t @ local
    -> (Parallel_kernel.t @ local -> z guard @ unique -> 'a)
         @ forkable local once shareable
    -> (Parallel_kernel.t @ local -> z guard @ unique -> 'b) @ once shareable
    -> #('a * 'b) @ local
    @@ portable

  (** {1 Leveled mutex}

      Mirrors {!Await.Mutex}, adding a level parameter and guard threading. *)

  module Mutex : sig
    (** [('k, 'n) t] is a mutex protecting the contents of the ['k] capsule at level
        ['n]. *)
    type ('k, 'n) t : value mod contended portable

    (** [create ?padded key] creates a leveled mutex for capsule ['k], consuming [key].
        Level ['n] comes from annotation or inference. [padded] adds cache-line padding
        to avoid false sharing.

        {[
          type level_db = z s
          let mutex : (_, level_db) Mutex.t = Mutex.create key
        ]} *)
    val create
      :  ?padded:bool @ local
      -> 'k Capsule.Key.t @ unique
      -> ('k, 'n) t
      @@ portable

    (** {2 Successor acquisition (no proof needed)}

        Acquires at level ['n s] given a guard at ['n]. Successor relation enforced by
        type unification. *)

    (** [with_access w mutex guard ~f] acquires [mutex] at the next level, runs [f] with
        an {!Access.t} and the elevated guard (usable for deeper locks), then releases.

        @raise Poisoned if [mutex] is poisoned.
        @raise Terminated if [w] is terminated before acquisition. *)
    val with_access
      : ('a : value_or_null) 'k 'n.
      Await.t @ local
      -> ('k, 'n s) t @ local
      -> 'n guard @ unique
      -> f:
           ('k Capsule.Access.t -> 'n s guard @ unique
            -> 'a @ contended once portable unique)
           @ local once portable
      -> #('a * 'n guard) @ contended once portable unique
      @@ portable

    (** {2 Arbitrary acquisition (with proof)}

        Acquires at any ['level] given a guard at ['floor] and a [('floor, 'level) lt]
        proof. *)

    (** Like {!with_access} but jumps to an arbitrary higher level via an explicit
        [('floor, 'level) lt] proof.

        {[
          Mutex.with_access_at w mutex guard (Step (Step Base))
            ~f:(fun access _g -> 42)
        ]}

        @raise Poisoned if [mutex] is poisoned.
        @raise Terminated if [w] is terminated before acquisition. *)
    val with_access_at
      : ('a : value_or_null) 'k 'floor 'level.
      Await.t @ local
      -> ('k, 'level) t @ local
      -> 'floor guard @ unique
      -> ('floor, 'level) lt
      -> f:
           ('k Capsule.Access.t -> 'level guard @ unique
            -> 'a @ contended once portable unique)
           @ local once portable
      -> #('a * 'floor guard) @ contended once portable unique
      @@ portable
  end

  (** {1 Bundled data + leveled mutex}

      Mirrors {!Await_capsule.With_mutex}. Callback return is [@ contended portable]
      (no [unique] / [once]) -- weaker than {!Mutex.with_access}, inherited from the
      underlying. Use {!Mutex} with a manual capsule key for full mode precision. *)

  module With_mutex : sig
    (** [('a, 'n) t] is a value of type ['a] in its own capsule, protected by a leveled
        mutex at level ['n]. *)
    type ('a, 'n) t : value mod contended portable

    (** [create f] runs [f] in a fresh capsule and bundles the result with a new mutex.
        Level ['n] comes from annotation or inference.

        {[
          type level_db = z s
          let counter : (int ref, level_db) With_mutex.t =
            With_mutex.create (fun () -> ref 0)
        ]} *)
    val create : (unit -> 'a) @ local once portable -> ('a, 'n) t @@ portable

    (** {2 Successor acquisition} *)

    (** [with_lock w t guard ~f] acquires [t] at the next level, runs [f] with the
        protected data and the elevated guard, then releases. *)
    val with_lock
      : 'a ('b : value_or_null) 'n.
      Await.t @ local
      -> ('a, 'n s) t
      -> 'n guard @ unique
      -> f:('a -> 'n s guard @ unique -> 'b @ contended portable)
           @ local once portable
      -> #('b * 'n guard) @ contended portable
      @@ portable

    (** {2 Arbitrary acquisition} *)

    (** Like {!with_lock} but jumps to an arbitrary higher level via an explicit
        [('floor, 'level) lt] proof. *)
    val with_lock_at
      : 'a ('b : value_or_null) 'floor 'level.
      Await.t @ local
      -> ('a, 'level) t
      -> 'floor guard @ unique
      -> ('floor, 'level) lt
      -> f:('a -> 'level guard @ unique -> 'b @ contended portable)
           @ local once portable
      -> #('b * 'floor guard) @ contended portable
      @@ portable
  end
end
