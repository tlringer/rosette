#lang racket

(require "term.rkt" "union.rkt" "bool.rkt" "polymorphic.rkt" "safe.rkt"
         "string.rkt" "real.rkt")

(provide @regexp? @regexp @regexp-quote @regexp-match-exact? @string->regexp
         @regexp-all @regexp-none @regexp-concat @regexp-range
         @regexp-star @regexp-plus @regexp-opt @regexp-loop
         @regexp-union @regexp-inter)

; TODO: There is a weird bug wherein consecutively calling Z3 with different constraints
; that both include regexes results in the second being UNSAT. Not sure if it's my code or
; Z3, but need to investigate before merging this.

(define (regexp/equal? x y)
  (match* (x y)
    [((? regexp?) (? regexp?)) (equal? x y)]
    [(_ _) (=? x y)]))

(define-lifted-type @regexp?
  #:base regexp?
  #:is-a? (instance-of? regexp? @regexp?)
  #:methods
  [(define (solvable-default self) #rx"$.^")
   (define (type-eq? self u v) (regexp/equal? u v)) 
   (define (type-equal? self u v) (regexp/equal? u v))
   (define (type-cast self v [caller 'type-cast])
     (match v
       [(? regexp?) v]
       [(term _ (== self)) v]
       [(union : [g (and (app type-of (== @regexp?)) u)] _ ...) (assert #f)] ;TODO don't know what to do here
       [_ (assert #f (thunk (raise-argument-error caller "expected a regexp?" v)))])) 
   (define (type-compress self force? ps) regexp/compress)])     

; TODO not sure what I need here, for now just using generic
(define (regexp/compress force? ps)
  (generic-merge* ps))

;; ----------------- Lifting utilities ----------------- ;;

; TODO duplicate logic in string.rkt, consolidate at some point

(define (safe-apply-n op xs @ts?)
  (define caller (object-name op)) 
  (cond
    [(empty? @ts?) (apply op (for/list ([x xs]) (type-cast @regexp? x caller)))]
    [else (apply op (for/list ([x xs] [@t? @ts?]) (type-cast @t? x caller)))]))

(define (safe-apply-1 op x @ts?)
  (safe-apply-n op (list x) @ts?))

(define (safe-apply-2 op x y @ts?)
  (safe-apply-n op (list x y) @ts?))

(define (lift-op op . ts)
  (case (procedure-arity op)
    [(1)  (lambda (x) (safe-apply-1 op x ts))]
    [(2)  (lambda (x y) (safe-apply-2 op x y ts))]
    [else
     (case-lambda
       [() (op)]
       [(x) (safe-apply-1 op x ts)]
       [(x y) (safe-apply-2 op x y ts)]
       [xs (safe-apply-n op xs ts)])]))

(define T*->regexp? (const @regexp?))

;; ----------------- Regexp Operators ----------------- ;;

; Current comments are temporary, for development purposes
; Will remove and replace with more informative ones later (TODO)

; Things people may want that we don't need directly for Z3:
; regexp-match
; regexp-match*
; regexp-try-match
; regexp-match?
; regexp-split
; regexp-replace
; regexp-replace*
; regexp-replaces
; regexp-replace-quote

(define @regexp-all #rx".*")
(define @regexp-none #rx"$.^")

(define ($regexp str)
  (if (string? str)
      (regexp str)
      (expression @regexp str)))

(define-operator @regexp
  #:identifier 'regexp
  #:range T*->regexp?
  #:unsafe regexp
  #:safe (lift-op $regexp @string?))

(define ($regexp-quote str [case-sensitive? #t])
  (if (string? str)
      (regexp-quote str case-sensitive?)
      (expression @regexp-quote str case-sensitive?)))

(define-operator @regexp-quote
  #:identifier 'regexp-quote
  #:range T*->string?
  #:unsafe $regexp-quote
  #:safe
  (lambda (str [case-sensitive? #t]) 
    (define caller 'regexp-quote)
    ($regexp-quote
     (type-cast @string? str caller)
     case-sensitive?)))

(define ($string->regexp str)
  (@regexp (@regexp-quote str)))

(define-operator @string->regexp
  #:identifier 'string->regexp
  #:range T*->regexp?
  #:unsafe $string->regexp
  #:safe (lift-op $string->regexp @string?))

(define ($regexp-match-exact? pattern input)
  (if (and ((or/c string? regexp?) pattern) (string? input)) 
      (regexp-match-exact? pattern input)
      (expression @regexp-match-exact? pattern input)))

; TODO need (or/c @string? regexp?) for 1st arg eventually
(define-operator @regexp-match-exact?
  #:identifier 'regexp-match-exact?
  #:range T*->boolean?
  #:unsafe $regexp-match-exact?
  #:safe (lift-op $regexp-match-exact? @regexp? @string?))

(define (assert-string-char ch)
  (cond
    [(and (string? ch) (not (= (string-length ch) 1)))
     (assert #f (thunk (raise-argument-error 'regexp-range
                                              "expected string? of length 1"
                                              ch)))]))
    
(define ($regexp-range ch1 ch2)
  (if (and (string? ch1) (string? ch2))
      (regexp (@string-append "[" ch1 "-" ch2 "]"))
      (expression @regexp-range ch1 ch2)))

(define ($guarded-regexp-range ch1 ch2)
  (assert-string-char ch1)
  (assert-string-char ch2)
  ($regexp-range ch1 ch2))

(define-operator @regexp-range
  #:identifier 'regexp-range
  #:range T*->regexp?
  #:unsafe $regexp-range
  #:safe (lift-op $guarded-regexp-range @string? @string?))

;(re.++ r1 r2 r3) 	Concatenation of regular expressions.
; Not sure why string-append was so complex to begin with, but using what's already done anyways
; TODO revisit to simplify later
(define ($regexp-concat-simplify rs)
  (match rs
    [(list) rs]
    [(list _) rs]
    [(list-rest (? regexp? r) ..2 rest)
     (list* (regexp (apply string-append (map object-name r))) ($regexp-concat-simplify rest))]
    [(list r rest ...) (list* r ($regexp-concat-simplify rest))]))

(define ($regexp-concat . rs)
  (match rs
    [`() @regexp-none]
    [(list r1) r1]
    [(list r1 r2)
     (match* (r1 r2)
       [((? regexp?) (? regexp?))
        (regexp (string-append (object-name r1) (object-name r2)))]
       [(_ _) (expression @regexp-concat r1 r2)])]
    [_
     (match ($regexp-concat-simplify rs)
       [(list r) r]
       [rs (apply expression @regexp-concat rs)])])) 

(define-operator @regexp-concat
  #:identifier 'regexp-concat
  #:range T*->T
  #:unsafe $regexp-concat
  #:safe (lift-op $regexp-concat))

(define ($regexp-star r)
  (if (regexp? r)
      (regexp (@string-append "(" (object-name r) ")*"))
      (expression @regexp-star r)))

(define-operator @regexp-star
  #:identifier 'regexp-star
  #:range T*->regexp?
  #:unsafe $regexp-star
  #:safe (lift-op $regexp-star))

(define ($regexp-plus r)
  (if (regexp? r)
      (regexp (@string-append "(" (object-name r) ")+"))
      (expression @regexp-plus r))) 

(define-operator @regexp-plus
  #:identifier 'regexp-plus
  #:range T*->regexp?
  #:unsafe $regexp-plus
  #:safe (lift-op $regexp-plus))

(define ($regexp-opt r) 
  (if (regexp? r)
      (regexp (@string-append "(" (object-name r) ")?"))
      (expression @regexp-opt r))) 

(define-operator @regexp-opt
  #:identifier 'regexp-opt
  #:range T*->regexp?
  #:unsafe $regexp-opt
  #:safe (lift-op $regexp-opt))

;((_ re.loop lo hi) r) 	from lo to hi number of repetitions of r.

(define ($regexp-loop lo hi r) ; TODO ? need pregexp for this, revisit later
  (assert "#f")) 

(define-operator @regexp-loop
  #:identifier 'regexp-loop
  #:range T*->regexp?
  #:unsafe $regexp-loop
  #:safe (lift-op $regexp-loop @integer? @integer? @regexp?))

(define ($regexp-union r1 r2) 
  (if (and (regexp? r1) (regexp? r2))
      (regexp (@string-append (object-name r1) "|" (object-name r2)))
      (expression @regexp-union r1 r2))) 

(define-operator @regexp-union
  #:identifier 'regexp-union
  #:range T*->regexp?
  #:unsafe $regexp-union
  #:safe (lift-op $regexp-union))

;(re.inter r1 r2) 	The intersection of regular languages.
; TODO how do I even do this? using union + negation?
; Or move into a struct for literals?
; Then modify the match operator/other operators to check for intersection case?
; Will revisit later
(define ($regexp-inter r1 r2) 
  (assert "#f")) 

(define-operator @regexp-inter
  #:identifier 'regexp-inter
  #:range T*->regexp?
  #:unsafe $regexp-inter
  #:safe (lift-op $regexp-inter))