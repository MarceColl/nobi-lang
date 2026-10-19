;; The `Nobi.Wasm` ABI, by hand: `alloc(len) -> ptr`, then
;; `export(ptr, len) -> i64` packing `ptr << 32 | len`, then `free(ptr, len)`.
;; No imports. A bump allocator that grows memory as it needs to.
(module
  (memory (export "memory") 1)
  (global $next (mut i32) (i32.const 1024))

  (func $alloc (export "alloc") (param $len i32) (result i32)
    (local $ptr i32)
    (local $end i32)
    (local $have i32)
    (local.set $ptr (global.get $next))
    (local.set $end (i32.add (local.get $ptr) (local.get $len)))
    (local.set $have (i32.mul (memory.size) (i32.const 65536)))
    (if (i32.gt_u (local.get $end) (local.get $have))
      (then
        (if (i32.eq
              (memory.grow
                (i32.add
                  (i32.div_u (i32.sub (local.get $end) (local.get $have)) (i32.const 65536))
                  (i32.const 1)))
              (i32.const -1))
          (then unreachable))))
    (global.set $next (local.get $end))
    (local.get $ptr))

  (func (export "free") (param i32 i32))

  (func $pack (param $ptr i32) (param $len i32) (result i64)
    (i64.or
      (i64.shl (i64.extend_i32_u (local.get $ptr)) (i64.const 32))
      (i64.extend_i32_u (local.get $len))))

  ;; The input, as it came.
  (func (export "echo") (param $ptr i32) (param $len i32) (result i64)
    (call $pack (local.get $ptr) (local.get $len)))

  ;; The input with ASCII a-z upper-cased, in a fresh allocation.
  (func (export "upper") (param $ptr i32) (param $len i32) (result i64)
    (local $i i32)
    (local $c i32)
    (local $out i32)
    (local.set $out (call $alloc (local.get $len)))
    (block $done
      (loop $next
        (br_if $done (i32.ge_u (local.get $i) (local.get $len)))
        (local.set $c (i32.load8_u (i32.add (local.get $ptr) (local.get $i))))
        (if (i32.and
              (i32.ge_u (local.get $c) (i32.const 97))
              (i32.le_u (local.get $c) (i32.const 122)))
          (then (local.set $c (i32.sub (local.get $c) (i32.const 32)))))
        (i32.store8 (i32.add (local.get $out) (local.get $i)) (local.get $c))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $next)))
    (call $pack (local.get $out) (local.get $len)))

  ;; Never returns: ends out of fuel or past the deadline.
  (func (export "spin") (param i32 i32) (result i64)
    (loop $forever (br $forever))
    (unreachable))

  (func (export "trap") (param i32 i32) (result i64)
    (unreachable))

  ;; Grows memory until the store refuses, then aborts as an allocator
  ;; that cannot allocate does.
  (func (export "grow") (param i32 i32) (result i64)
    (loop $more
      (br_if $more (i32.ne (memory.grow (i32.const 16)) (i32.const -1))))
    (unreachable))

  ;; Claims an output of 2 GiB - 1 bytes.
  (func (export "big") (param i32 i32) (result i64)
    (call $pack (i32.const 0) (i32.const 2147483647)))

  ;; The input's bytes with the first one replaced by 0xFF: not UTF-8.
  (func (export "garble") (param $ptr i32) (param $len i32) (result i64)
    (i32.store8 (local.get $ptr) (i32.const 255))
    (call $pack (local.get $ptr) (local.get $len))))
