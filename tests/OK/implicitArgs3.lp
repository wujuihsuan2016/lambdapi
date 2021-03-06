symbol const U : TYPE

// Mini bool
symbol const Bool : U
symbol const B : TYPE
symbol true : B
symbol false : B

// Mini nat
symbol const Nat  : U
symbol const N : TYPE
symbol const zero : N
symbol const s : N ⇒ N
symbol add : N ⇒ N ⇒ N
set infix left 6 "+" ≔ add

rule zero   + &n     → &n
rule (s &m) + &n     → s (&m + &n)
rule &m     + zero   → &m
rule &m     + (s &n) → s (&m + &n)

// Mini interpretation function from code of types to real types
symbol injective T : U ⇒ TYPE
rule T Nat     → N
rule T Bool    → B

// Mini vectors of booleans
symbol const Vect : T Nat ⇒ U

symbol nil : T (Vect zero)

// The nat is declared to be implicit
symbol const cons : ∀{n:T Nat}, T Bool ⇒ T (Vect n) ⇒ T (Vect (s n))

// TEST IMPLICIT ARGUMENTS FOR A DEFINITION, WITHOUT THE @ MARKER
// [true]
definition l1  : T (Vect (s zero)) ≔ cons true nil
// It works.

// TEST NESTED IMPLICIT ARGUMENTS FOR A DEFINITION, WITHOUT THE @ MARKER
definition l2 : T (Vect (s (s zero))) ≔ cons true (cons false nil)
// It works

// TEST IMPLICIT ARGUMENTS FOR A DEFINITION, WITH THE @ MARKER
// Same as l1 but fully explicit
definition l3 : T (Vect (s zero)) ≔ @cons zero true nil
// It works.

// TEST NESTED IMPLICIT ARGUMENTS FOR A DEFINITION, WITH THE @ MARKER
// Same as l2 but fully explicit
definition l4 : T (Vect (s (s zero))) ≔ @cons (s zero) true (@cons zero false nil)
// It works.

symbol append : ∀ (n:T Nat) (m:T Nat), T (Vect n) ⇒ T (Vect m) ⇒ T (Vect (n+m))
// Works, but unfortunately, we can't use implicits in RHS of rewrite rules at the moment
rule append zero    &m nil           &v2  → &v2
rule append (s &pn) &m (cons &h &t)  &v2  → @cons (&pn+&m) &h (append &pn &m &t &v2)

rule append (s &pn) &m (cons &h &t)  &v2  → cons {&pn+&m} &h (append &pn &m &t &v2)
