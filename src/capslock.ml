open! Base

type z
type !'n s

type ('lo, 'hi) lt =
  | Base : ('n, 'n s) lt
  | Step : 'm 'n. ('m, 'n) lt -> ('m, 'n s) lt

type l0 = z
type l1 = l0 s
type l2 = l1 s
type l3 = l2 s
type l4 = l3 s
type l5 = l4 s

let lt_0_1 : (l0, l1) lt = Base
let lt_0_2 : (l0, l2) lt = Step Base
let lt_0_3 : (l0, l3) lt = Step (Step Base)
let lt_0_4 : (l0, l4) lt = Step (Step (Step Base))
let lt_0_5 : (l0, l5) lt = Step (Step (Step (Step Base)))
let lt_1_2 : (l1, l2) lt = Base
let lt_1_3 : (l1, l3) lt = Step Base
let lt_1_4 : (l1, l4) lt = Step (Step Base)
let lt_1_5 : (l1, l5) lt = Step (Step (Step Base))
let lt_2_3 : (l2, l3) lt = Base
let lt_2_4 : (l2, l4) lt = Step Base
let lt_2_5 : (l2, l5) lt = Step (Step Base)
let lt_3_4 : (l3, l4) lt = Base
let lt_3_5 : (l3, l5) lt = Step Base
let lt_4_5 : (l4, l5) lt = Base

type 'n guard = unit

let mint_guard () : _ @ unique = ()

let parallel scheduler ~f =
  Parallel_scheduler.parallel scheduler ~f:(fun (par @ local) -> f par (mint_guard ()))

let fork_join2
      (par @ local)
      (f1 : (Parallel_kernel.t @ local -> unit @ unique -> 'a)
             @ forkable local once shareable)
      (f2 : (Parallel_kernel.t @ local -> unit @ unique -> 'b) @ once shareable)
  = exclave_
  Parallel_kernel.fork_join2 par
    (fun (par @ local) -> f1 par (mint_guard ()))
    (fun (par @ local) -> f2 par (mint_guard ()))

module Mutex = struct
  type ('k, 'n) t = 'k Await_sync.Mutex.t

  let create ?padded key = Await_sync.Mutex.create ?padded key

  let[@inline] with_access await t g ~f =
    let result =
      Await_sync.Mutex.with_access await t ~f:(fun access -> f access ())
    in
    #(result, g)

  let[@inline] with_access_at await t g _proof ~f =
    let result =
      Await_sync.Mutex.with_access await t ~f:(fun access -> f access ())
    in
    #(result, g)
end

module With_mutex = struct
  type ('a, 'n) t = 'a Await_capsule.With_mutex.t

  let create f = Await_capsule.With_mutex.create f

  let[@inline] with_lock await t g ~f =
    let result =
      Await_capsule.With_mutex.with_lock await t ~f:(fun a -> f a ())
    in
    #(result, g)

  let[@inline] with_lock_at await t g _proof ~f =
    let result =
      Await_capsule.With_mutex.with_lock await t ~f:(fun a -> f a ())
    in
    #(result, g)
end
