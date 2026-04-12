(lang dune 3.17)

(name capslock)
(version 0.1.0~alpha)

(generate_opam_files true)

(package
 (name capslock)
 (synopsis "Deadlock-free leveled locking for OxCaml capsules")
 (depends
  (ocaml (>= 5.2.0))
  capsule
  await))
