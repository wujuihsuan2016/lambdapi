(** Generating constraints for type inference and type checking. *)

open Timed
open Console
open Terms
open Print

(** Logging function for typing. *)
let log_type = new_logger 't' "type" "debugging information for typing"
let log_type = log_type.logger

(** Accumulated constraints. *)
let constraints = Pervasives.ref []

(** Function adding a constraint. *)
let conv a b =
  let open Pervasives in
  if not (Basics.eq a b) then constraints := (a,b) :: !constraints

(** [make_meta_codomain ctx a] builds a metavariable intended as the  codomain
    type for a product of domain type [a].  It has access to the variables  of
    the context [ctx] and a fresh variables corresponding to the argument. *)
let make_meta_codomain : Ctxt.t -> term -> tbinder = fun ctx a ->
  let x = Bindlib.new_var mkfree "x" in
  let m = Meta(fresh_meta Kind 0, [||]) in
  (* [m] can be instantiated by Type or Kind only (the type of [m] is
     therefore incorrect when [m] is instantiated by Kind. *)
  let b = Ctxt.make_meta ((x,a)::ctx) m in
  Bindlib.unbox (Bindlib.bind_var x (lift b))

(** [infer ctx t] infers a type for the term [t] in context [ctx],
   possibly under some constraints recorded in [constraints] using
   [conv]. The returned type is well-sorted if recorded unification
   constraints are satisfied. [ctx] must be well-formed. This function
   never fails (but constraints may be unsatisfiable). *)
let rec infer : Ctxt.t -> term -> term = fun ctx t ->
  match unfold t with
  | Patt(_,_,_) -> assert false (* Forbidden case. *)
  | TEnv(_,_)   -> assert false (* Forbidden case. *)
  | Kind        -> assert false (* Forbidden case. *)
  | Wild        -> assert false (* Forbidden case. *)
  | TRef(_)     -> assert false (* Forbidden case. *)

  (* -------------------
      ctx ⊢ Type ⇒ Kind  *)
  | Type        -> Kind

  (* ---------------------------------
      ctx ⊢ Vari(x) ⇒ Ctxt.find x ctx  *)
  | Vari(x)     -> (try Ctxt.find x ctx with Not_found -> assert false)

  (* -------------------------------
      ctx ⊢ Symb(s) ⇒ !(s.sym_type)  *)
  | Symb(s,_)   -> Timed.(!(s.sym_type))

  (*  ctx ⊢ a ⇐ Type    ctx, x : a ⊢ b<x> ⇒ s
     -----------------------------------------
                ctx ⊢ Prod(a,b) ⇒ s            *)
  | Prod(a,b)   ->
      (* We ensure that [a] is of type [Type]. *)
      check ctx a Type;
      (* We infer the type of the body, first extending the context. *)
      let (_,b,ctx') = Ctxt.unbind ctx a b in
      let s = infer ctx' b in
      (* We check that [s] is a sort. *)
      begin
        let s = unfold s in
        match s with
        | Type | Kind -> s
        | _           -> conv s Type; Type
      (* We add the constraint [s = Type] because kinds cannot occur
         inside a term. So, [t] cannot be a kind. *)
      end

  (*  ctx ⊢ a ⇐ Type    ctx, x : a ⊢ t<x> ⇒ b<x>
     --------------------------------------------
             ctx ⊢ Abst(a,t) ⇒ Prod(a,b)          *)
  | Abst(a,t)   ->
      (* We ensure that [a] is of type [Type]. *)
      check ctx a Type;
      (* We infer the type of the body, first extending the context. *)
      let (x,t,ctx') = Ctxt.unbind ctx a t in
      let b = infer ctx' t in
      (* We build the product type by binding [x] in [b]. *)
      Prod(a, Bindlib.unbox (Bindlib.bind_var x (lift b)))

  (*  ctx ⊢ t ⇒ Prod(a,b)    ctx ⊢ u ⇐ a
     ------------------------------------
         ctx ⊢ Appl(t,u) ⇒ subst b u      *)
  | Appl(t,u)   ->
      (* We first infer a product type for [t]. *)
      let (a,b) =
        let c = Eval.whnf (infer ctx t) in
        match c with
        | Prod(a,b) -> (a,b)
        | _         ->
            let a = Ctxt.make_meta ctx Type in
            let b = make_meta_codomain ctx a in
            conv c (Prod(a,b)); (a,b)
      in
      (* We then check the type of [u] against the domain type. *)
      check ctx u a;
      (* We produce the returned type. *)
      Bindlib.subst b u

  (*  ctx ⊢ term_of_meta m e ⇒ a
     ----------------------------
         ctx ⊢ Meta(m,e) ⇒ a      *)
  | Meta(m,e)   -> infer ctx (term_of_meta m e)

(** [check ctx t c] checks that the term [t] has type [c] in context
   [ctx], possibly under some constraints recorded in [constraints]
   using [conv]. [ctx] must be well-formed and [c] well-sorted. This
   function never fails (but constraints may be unsatisfiable). *)

(* [check ctx t c] could be reduced to the default case [conv
   (infer ctx t) c]. We however provide some more efficient
   code when [t] is an abstraction, as witnessed by 'make holide':

   Finished in 3:57.79 at 99% with 3179880Kb of RAM

   Finished in 3:39.76 at 99% with 2720708Kb of RAM

   This avoids to build a product to destructure it just after. *)
and check : Ctxt.t -> term -> term -> unit = fun ctx t c ->
  match unfold t with
  | Abst(a,t)   ->
      (*  c → Prod(d,b)    a ~ d    ctx, x : A ⊢ t<x> ⇐ b<x>
         ----------------------------------------------------
                         ctx ⊢ Abst(a,t) ⇐ c                   *)
      begin
        (* We (hopefully) evaluate [c] to a product, and get its body. *)
        let b =
          let c = Eval.whnf c in
          match c with
          | Prod(d,b) -> conv d a; b (* Domains must be convertible. *)
          | _         -> (* Generate product type with codomain [a]. *)
              let b = make_meta_codomain ctx a in
              conv c (Prod(a,b)); b
        in
        (* We type-check the body with the codomain. *)
        let (x,t,ctx') = Ctxt.unbind ctx a t in
        check ctx' t (Bindlib.subst b (Vari(x)))
      end
  | t           ->
      (*  ctx ⊢ t ⇒ a
         -------------
          ctx ⊢ t ⇐ a  *)
      conv (infer ctx t) c

(** [infer ctx t] returns a pair [(a,cs)] where [a] is a type for the
   term [t] in the context [ctx], under unification constraints [cs].
   In other words, the constraints of [cs] must be satisfied for [t]
   to have type [a]. [ctx] must be well-formed. This function never
   fails (but constraints may be unsatisfiable). *)
let infer : Ctxt.t -> term -> term * unif_constrs = fun ctx t ->
  Pervasives.(constraints := []);
  let a = infer ctx t in
  let constrs = Pervasives.(!constraints) in
  if !log_enabled then
    begin
      log_type (gre "infer [%a] yields [%a]") pp t pp a;
      let fn (a,b) = log_type "  assuming [%a] ~ [%a]" pp a pp b in
      List.iter fn constrs;
    end;
  Pervasives.(constraints := []);
  (a, constrs)

(** [check ctx t c] checks returns a list [cs] of unification
   constraints for [t] to be of type [c] in the context [ctx]. The
   context [ctx] must be well-typed, and the type [c]
   well-sorted. This function never fails (but constraints may be
   unsatisfiable). *)
let check : Ctxt.t -> term -> term -> unif_constrs = fun ctx t c ->
  Pervasives.(constraints := []);
  check ctx t c;
  let constrs = Pervasives.(!constraints) in
  if !log_enabled then
    begin
      log_type (gre "check [%a] [%a]") pp t pp c;
      let fn (a,b) = log_type "  assuming [%a] ~ [%a]" pp a pp b in
      List.iter fn constrs;
    end;
  Pervasives.(constraints := []);
  constrs
