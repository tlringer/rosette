#lang racket
 
(require rosette/lib/util/roseunit)

(run-all-tests 
 "base/effects.rkt" 
 "base/type.rkt" 
 "base/term.rkt"
 "base/bool.rkt"
 "base/bitvector.rkt"
 "base/real.rkt"
 "base/equality.rkt"
 "base/merge.rkt"
 "base/finitize.rkt"
 "base/list.rkt"
 "base/vector.rkt"
 "query/solve.rkt"
 "query/verify.rkt"
 "query/synthesize.rkt"
 )

#|
(require rosette)
(term-cache)
(asserts)
(current-oracle)
(current-bitwidth)
(current-solver)
|#