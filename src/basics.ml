(** Basic operations on terms. *)

open Extra
open Timed
open Terms

(** Sets and maps of variables. *)
module Var =
  struct
    type t = term Bindlib.var
    let compare = Bindlib.compare_vars
  end

module VarSet = Set.Make(Var)
module VarMap = Map.Make(Var)

(** [to_tvar t] returns [x] if [t] is of the form [Vari x] and fails
    otherwise. *)
let to_tvar : term -> tvar = fun t ->
  match t with Vari(x) -> x | _ -> assert false

(** {b NOTE} the {!val:Array.map to_tvar} function is useful when working
   with multiple binders. For example, this is the case when manipulating
   pattern variables ([Patt] constructor) or metatavariables ([Meta]
   constructor).  Remark that it is important for these constructors to hold
   an array of terms, rather than an array of variables: a variable can only
   be substituted when if it is injected in a term (using the [Vari]
   constructor). *)

(** {b NOTE} the result of {!val:to_tvar} can generally NOT be precomputed. A
    first reason is that we cannot know in advance what variable identifier is
    going to arise when working under binders,  for which fresh variables will
    often be generated. A second reason is that free variables should never be
    “marshaled” (e.g., by the {!module:Sign} module), as this would break the
    freshness invariant of new variables. *)

(** [count_products a] returns the number of consecutive products at the  head
    of the term [a]. *)
let rec count_products : term -> int = fun t ->
  match unfold t with
  | Prod(_,b) -> 1 + count_products (Bindlib.subst b Kind)
  | _         -> 0

(** [get_args t] decomposes the {!type:term} [t] into a pair [(h,args)], where
    [h] is the head term of [t] and [args] is the list of arguments applied to
    [h] in [t]. The returned [h] cannot be an [Appl] node. *)
let get_args : term -> term * term list = fun t ->
  let rec get_args acc t =
    match unfold t with
    | Appl(t,u) -> get_args (u::acc) t
    | t         -> (t, acc)
  in get_args [] t

(** [add_args t args] builds the application of the {!type:term} [t] to a list
    arguments [args]. When [args] is empty, the returned value is (physically)
    equal to [t]. *)
let add_args : term -> term list -> term = fun t args ->
  let rec add_args t args =
    match args with
    | []      -> t
    | u::args -> add_args (Appl(t,u)) args
  in add_args t args

(** [eq t u] tests the equality of [t] and [u] (up to α-equivalence). It fails
    if [t] or [u] contain terms of the form [Patt(i,s,e)] or [TEnv(te,e)].  In
    the process, subterms of the form [TRef(r)] in [t] and [u] may be set with
    the corresponding value to enforce equality. In other words,  [eq t u] can
    be used to implement non-linear matching (see {!module:Rewrite}). When the
    matching feature is used, one should make sure that [TRef] constructors do
    not appear both in [t] and in [u] at the same time. Indeed, the references
    are set naively, without checking occurence. *)
let eq : term -> term -> bool = fun a b -> a == b ||
  let exception Not_equal in
  let rec eq l =
    match l with
    | []       -> ()
    | (a,b)::l ->
    match (unfold a, unfold b) with
    | (a          , b          ) when a == b -> eq l
    | (Vari(x1)   , Vari(x2)   ) when Bindlib.eq_vars x1 x2 -> eq l
    | (Type       , Type       )
    | (Kind       , Kind       ) -> eq l
    | (Symb(s1,_) , Symb(s2,_) ) when s1 == s2 -> eq l
    | (Prod(a1,b1), Prod(a2,b2))
    | (Abst(a1,b1), Abst(a2,b2)) -> let (_, b1, b2) = Bindlib.unbind2 b1 b2 in
                                    eq ((a1,a2)::(b1,b2)::l)
    | (Appl(t1,u1), Appl(t2,u2)) -> eq ((t1,t2)::(u1,u2)::l)
    | (Meta(m1,e1), Meta(m2,e2)) when m1 == m2 ->
        eq (if e1 == e2 then l else List.add_array2 e1 e2 l)
    | (Wild       , _          )
    | (_          , Wild       ) -> eq l
    | (TRef(r)    , b          ) -> r := Some(b); eq l
    | (a          , TRef(r)    ) -> r := Some(a); eq l
    | (Patt(_,_,_), _          )
    | (_          , Patt(_,_,_))
    | (TEnv(_,_)  , _          )
    | (_          , TEnv(_,_)  ) -> assert false
    | (_          , _          ) -> raise Not_equal
  in
  try eq [(a,b)]; true with Not_equal -> false

(** [eq_vari t u] checks that [t] and [u] are both variables, and the they are
    pariwise equal. *)
let eq_vari : term -> term -> bool = fun t u ->
  match (unfold t, unfold u) with
  | (Vari(x), Vari(y)) -> Bindlib.eq_vars x y
  | (_      , _      ) -> false

(** [is_symb s t] tests whether [t] is of the form [Symb(s)]. *)
let is_symb : sym -> term -> bool = fun s t ->
  match unfold t with
  | Symb(r,_) -> r == s
  | _         -> false

(** [get_symb t] returns [Some s] if [t] is of the form [Symb (s , _)].
    Otherwise, it returns [None]. *)
let get_symb : term -> sym option = fun t ->
  match unfold t with
  | Symb (s, _) -> Some s
  | _           -> None

(** [iter_ctxt f t] applies the function [f] to every node of the term [t].
   At each call, the function is given the list of the free variables in the
   term, in the reverse order they were given. Free variables that were
   already in the term before the call are not included in the list. Note: [f]
   is called on already unfolded terms only. *)
let iter_ctxt : (tvar list -> term -> unit) -> term -> unit = fun action t ->
  let rec iter xs t =
    let t = unfold t in
    action xs t;
    match t with
    | Wild
    | TRef(_)
    | Vari(_)
    | Type
    | Kind
    | Symb(_)    -> ()
    | Patt(_,_,ts)
    | TEnv(_,ts)
    | Meta(_,ts) -> Array.iter (iter xs) ts
    | Prod(a,b)
    | Abst(a,b)  ->
       iter xs a;
       let (x,b') = Bindlib.unbind b in
       iter (if Bindlib.binder_occur b then x::xs else xs) b'
    | Appl(t,u)  -> iter xs t; iter xs u
  in
  iter [] (cleanup t)

(** [iter f t] applies the function [f] to every node of the term [t] with
   bound variables replaced by [Kind]. Note: [f] is called on already unfolded
   terms only. *)
let iter : (term -> unit) -> term -> unit = fun action ->
  let rec iter t =
    let t = unfold t in
    action t;
    match t with
    | Wild
    | TRef(_)
    | Vari(_)
    | Type
    | Kind
    | Symb(_)    -> ()
    | Patt(_,_,ts)
    | TEnv(_,ts)
    | Meta(_,ts) -> Array.iter iter ts
    | Prod(a,b)
    | Abst(a,b)  -> iter a; iter (Bindlib.subst b Kind)
    | Appl(t,u)  -> iter t; iter u
  in iter

(** [iter_meta f t] applies the function [f] to every metavariable of
   [t], as well as to every metavariable occurring in the type of an
   uninstantiated metavariable occurring in [t], and so on. *)
let rec iter_meta : (meta -> unit) -> term -> unit = fun f t ->
  match unfold t with
  | Patt(_,_,_)
  | TEnv(_,_)
  | Wild
  | TRef(_)
  | Vari(_)
  | Type
  | Kind
  | Symb(_)    -> ()
  | Prod(a,b)
  | Abst(a,b)  -> iter_meta f a; iter_meta f (Bindlib.subst b Kind)
  | Appl(t,u)  -> iter_meta f t; iter_meta f u
  | Meta(v,ts) -> f v; iter_meta f !(v.meta_type); Array.iter (iter_meta f) ts

(** {b NOTE} that {!val:iter_meta} is not implemented using {!val:iter} due to
    the fact this it is performance-critical. *)

(** [is_meta t] checks if [t] is a metavariable. *)
let is_meta : term -> bool = fun t ->
  match unfold t with
  | Meta _ -> true
  | _      -> false

let rec map_meta : (meta -> meta) -> term -> term = fun f t ->
  match unfold t with
  | Prod (a, b)  ->
      let x, b' = Bindlib.unbind b in
      let b =
        Bindlib.unbox (Bindlib.bind_var x (lift (map_meta f b'))) in
      Prod (map_meta f a, b)
  | Abst (a, b)  ->
      let x, b' = Bindlib.unbind b in
      let b =
        Bindlib.unbox (Bindlib.bind_var x (lift (map_meta f b'))) in
      Abst (map_meta f a, b)
  | Appl (t, u)  -> Appl (map_meta f t, map_meta f u)
  | Meta (m, ts) -> Meta (f m, Array.map (map_meta f) ts)
  | _            -> t

module IntMap = Map.Make(struct type t = int let compare = compare end)

let copy_rule : term * term -> term * term = fun (lhs, rhs) ->
  let metamap = IntMap.empty in
  let rec copy_term metamap t =
    match unfold t with
    | Prod (a, b)  ->
        let a, metamap = copy_term metamap a in
        let x, b' = Bindlib.unbind b in
        let b', metamap = copy_term metamap b' in
        let b =
          Bindlib.unbox (Bindlib.bind_var x (lift  b')) in
        Prod (a, b), metamap
    | Abst (a, b)  ->
        let a, metamap = copy_term metamap a in
        let x, b' = Bindlib.unbind b in
        let b', metamap = copy_term metamap b' in
        let b =
          Bindlib.unbox (Bindlib.bind_var x (lift b')) in
        Abst (a, b), metamap
    | Appl (t, u)  ->
        let t, metamap = copy_term metamap t in
        let u, metamap = copy_term metamap u in
        Appl (t, u), metamap
    | Meta (m, ts) ->
        begin try
          let new_m = IntMap.find m.meta_key metamap in
          let ts, metamap =
            List.fold_right
              (fun t (acc, metamap) ->
                let t, metamap = copy_term metamap t in
                t :: acc, metamap) (Array.to_list ts) ([], metamap) in
          Meta (new_m, Array.of_list ts), metamap
        with Not_found ->
          let new_m = fresh_meta !(m.meta_type) m.meta_arity in
          let ts, metamap =
            List.fold_right
              (fun t (acc, metamap) ->
                let t, metamap = copy_term metamap t in
                t :: acc, metamap)
              (Array.to_list ts) ([], IntMap.add m.meta_key new_m metamap) in
          Meta (new_m, Array.of_list ts), metamap
        end
    | _            -> t, metamap
  in
  let lhs, metamap = copy_term metamap lhs in
  lhs, map_meta (fun m -> IntMap.find m.meta_key metamap) rhs

(** [occurs m t] tests whether the metavariable [m] occurs in the term [t]. *)
let occurs : meta -> term -> bool =
  let exception Found in fun m t ->
  let fn p = if m == p then raise Found in
  try iter_meta fn t; false with Found -> true

(** [get_metas t] returns the list of all the metavariables in [t]. *)
let get_metas : term -> meta list = fun t ->
  let open Pervasives in
  let l = ref [] in
  iter_meta (fun m -> l := m :: !l) t;
  List.sort_uniq (fun m1 m2 -> m1.meta_key - m2.meta_key) !l

let get_metas' : term -> meta list = fun t ->
  let open Pervasives in
  let l = ref [] in
  let fn t = match t with
    | Meta (m, _) -> l := m :: !l
    | _           -> () in
  iter fn t;
  List.sort_uniq (fun m1 m2 -> m1.meta_key - m2.meta_key) !l

(** [has_metas t] checks that there are metavariables in [t]. *)
let has_metas : term -> bool =
  let exception Found in fun t ->
  try iter_meta (fun _ -> raise Found) t; false with Found -> true

(** [build_prod k] builds the type “∀(x₁:A₁) (x₂:A₂) ⋯ (xk:Ak), A(k+1)” where
    “x₁” through “xk” are fresh variables, “Ai = Mi[x₁,⋯,x(i-1)]”, “Mi” is a
    new metavariable of arity “i-1” and type “∀(x₁:A₂) ⋯ (x(i-1):A(i-1)), TYPE
    ”. *)
let build_prod : int -> term = fun k ->
  assert (k>=0);
  let vs = Bindlib.new_mvar mkfree (Array.make k "x") in
  let rec build_prod k p =
    if k = 0 then p
    else
      let k = k-1 in
      let mk_typ = Bindlib.unbox (build_prod k _Type) in
      let mk = fresh_meta mk_typ k in
      let tk = _Meta mk (Array.map _Vari (Array.sub vs 0 k)) in
      let b = Bindlib.bind_var vs.(k) p in
      let p = Bindlib.box_apply2 (fun a b -> Prod(a,b)) tk b in
      build_prod k p
  in
  let mk_typ = Bindlib.unbox (build_prod k _Type) (*FIXME?*) in
  let mk = fresh_meta mk_typ k in
  let tk = _Meta mk (Array.map _Vari vs) in
  Bindlib.unbox (build_prod k tk)

(** [new_symb name t] returns a new function symbol of name [name] and of
    type [t]. *)
let new_symb name t =
  { sym_name = name ; sym_type = ref t ; sym_path = [] ; sym_def = ref None
  ; sym_impl = [] ; sym_rules = ref [] ; sym_mode = Const }

(** [replace_patt_by_meta k metas t] computes a new (boxed) term by replacing
    every pattern variable in [t] by a fresh metavariable and store the latter
    in [metas], where [k] indicates the order of the term obtained *)
let rec replace_patt_by_meta : int -> meta option array -> term -> tbox
  = fun k metas t ->
  match unfold t with
  | Vari x         -> _Vari x
  | Symb (s, h)    -> _Symb s h
  | Abst (a, t)    ->
      let (x, t) = Bindlib.unbind t in
      _Abst (replace_patt_by_meta 0 metas a)
            (Bindlib.bind_var x (replace_patt_by_meta 0 metas t))
  | Appl (t, u)    ->
      _Appl (replace_patt_by_meta (k + 1) metas t)
            (replace_patt_by_meta 0 metas u)
  | Patt (i, n, a) ->
      begin
        let a = Array.map (replace_patt_by_meta 0 metas) a in
        let l = Array.length a in
        match i with
        | None   ->
            let m = fresh_meta ~name:n (build_prod (l + k)) l in
            _Meta m a
        | Some i ->
            match metas.(i) with
            | Some m -> _Meta m a
            | None   ->
                let m = fresh_meta ~name:n (build_prod (l + k)) l in
                metas.(i) <- Some m;
                _Meta m a
      end
  | _              -> assert false

(** Exception raised when a term contains non-nullary metavariables. *)
exception Non_nullary_meta

(** [replace_patt_by_symb symbs t] computes a new (boxed) term by replacing
    every pattern variable in [t] by a fresh symbol [c_n] of type [t_n]
    ([t_n] is another fresh symbol of type [Kind]) and store [c_n] the latter
    in [symbs]. *)
let rec replace_patt_by_symb : sym option array -> term -> tbox
  = fun symbs t ->
  match unfold t with
  | Vari x            -> _Vari x
  | Symb (s, h)       -> _Symb s h
  | Abst (a, t)       ->
      let (x, t) = Bindlib.unbind t in
      _Abst (replace_patt_by_symb symbs a)
            (Bindlib.bind_var x (replace_patt_by_symb symbs t))
  | Appl (t, u)       ->
      _Appl (replace_patt_by_symb symbs t) (replace_patt_by_symb symbs u)
  | Patt (i, n, [||]) ->
      begin
        match i with
        | None   ->
            let t_n = new_symb ("{t_" ^ n) Type in
            let term_t_n = symb t_n in
            let c_n = new_symb ("{c_" ^ n) term_t_n in
            _Symb c_n Nothing
        | Some i ->
            match symbs.(i) with
            | Some s -> _Symb s Nothing
            | None   ->
                let t_n = new_symb ("{t_" ^ n) Type in
                let term_t_n = symb t_n in
                let c_n = new_symb ("{c_" ^ n) term_t_n in
                symbs.(i) <- Some c_n;
                _Symb c_n Nothing
      end
  | Patt _            -> raise Non_nullary_meta
  | _                 -> assert false

(** [is_new_symb s] checks if [s] is a function symbol created for checking
    SR. *)
let is_new_symb s = s.sym_name.[0] = '{'

(** [distinct_vars_opt ts] checks that [ts] is made of distinct
   variables and returns these variables. *)
let distinct_vars_opt : term array -> tvar array option =
  let exception Not_unique_var in fun ts ->
  let open Pervasives in
  let vars = ref VarSet.empty in
  let to_var t =
    match unfold t with
    | Vari x when not (VarSet.mem x !vars) -> vars := VarSet.add x !vars; x
    | _ -> raise Not_unique_var
  in try Some (Array.map to_var ts) with Not_unique_var -> None

(** [distinct_vars ts] checks that [ts] is made of distinct variables. *)
let distinct_vars : term array -> bool =
  let exception Not_unique_var in fun ts ->
  let open Pervasives in
  let vars = ref VarSet.empty in
  let check t =
    match unfold t with
    | Vari x when not (VarSet.mem x !vars) -> vars := VarSet.add x !vars
    | _ -> raise Not_unique_var
  in try Array.iter check ts; true with Not_unique_var -> false

(** {3 Conversion of a rule into a "pair" of terms} *)

(** [terms_of_rule r] converts the RHS (right hand side) of the rewriting rule
    [r] into a term.  The bound higher-order variables of the original RHS are
    substituted using [Patt] constructors.  They are thus represented as their
    LHS counterparts. This is a more convenient way of representing terms when
    analysing confluence or termination. *)
let term_of_rhs : rule -> term = fun r ->
  let fn i (name, arity) =
    let make_var i = Bindlib.new_var mkfree (Printf.sprintf "x%i" i) in
    let vars = Array.init arity make_var in
    let p = _Patt (Some(i)) name (Array.map Bindlib.box_var vars) in
    TE_Some(Bindlib.unbox (Bindlib.bind_mvar vars p))
  in
  Bindlib.msubst r.rhs (Array.mapi fn r.vars)

(** [replace_patt_rule replace_patt to_term_env r] translates the
    rule [r] into a pair of terms. The pattern variables in the LHS are
    replaced by fresh metavariables (resp. fresh symbols) if [replace_patt] =
    [replace_patt_by_meta] (resp. [replace_patt_by_symb]). The terms with
    environment in the RHS are replaced by their corresponding metavariables
    (resp. symbols). *)
let replace_patt_rule :
  ('a option array -> term -> tbox) -> ('a option -> term_env) ->
  sym * rule -> term * term
  = fun replace_patt to_term_env (s, r) ->
  let arity = Bindlib.mbinder_arity r.rhs in
  let arr = Array.init arity (fun _ -> None) in
  let lhs =
    List.map (fun arg -> Bindlib.unbox (replace_patt arr arg)) r.lhs in
  let terms_env = Array.map to_term_env arr in
  let rhs = Bindlib.msubst r.rhs terms_env in
  add_args (symb s) lhs, rhs

let replace_patt_by_meta_rule =
  let to_term_env m =
    let m = match m with Some m -> m | None -> assert false in
    let xs = Array.init m.meta_arity (Printf.sprintf "x%i") in
    let xs = Bindlib.new_mvar mkfree xs in
    let ar = Array.map _Vari xs in
    TE_Some (Bindlib.unbox (Bindlib.bind_mvar xs (_Meta m ar))) in
  replace_patt_rule (replace_patt_by_meta 0) to_term_env

let replace_patt_by_symb_rule =
  let to_term_env s =
    let s = match s with Some s -> s | None -> assert false in
    TE_Some (Bindlib.unbox (Bindlib.bind_mvar [||] (_Symb s Nothing))) in
  replace_patt_rule replace_patt_by_symb to_term_env

(** [check_nullary_meta t] checks that all the metavariables in [t] are of
    arity 0. *)
let rec check_nullary_meta : term -> unit = fun t ->
  match t with
  | Type
  | Kind
  | Symb _
  | Wild
  | Patt _         -> ()
  | Meta (_, [||]) -> ()
  | Appl (u, v)    -> check_nullary_meta u; check_nullary_meta v
  | _              -> raise Non_nullary_meta
