(** Parsing functions. *)

open Console
open Files
open Pos

#define LOCATE locate

(** Parser-level representation of a qualified identifier. *)
type qident = (module_path * string) loc

(** Parser-level representation of a metavariable identifier. *)
type p_meta =
  | M_User of string (** With given name. *)
  | M_Sys  of int    (** With given key.  *)
  | M_Bad  of int    (** Undefined key.   *)

(** Parser-level representation of terms (and patterns). *)
type p_term = p_term_aux loc
 and p_term_aux =
  | P_Vari of qident
  | P_Type
  | P_Prod of strloc * p_term option * p_term
  | P_Abst of strloc * p_term option * p_term
  | P_Appl of p_term * p_term
  | P_Wild
  | P_Meta of p_meta * p_term array

(* NOTE: the [P_Vari] constructor is used for variables (with an empty  module
   path), and for symbols. The [P_Wild] constructor corresponds to a  wildcard
   pattern ['_']. *)

(** [build_prod xs a] build a product by abstracting away the arguments of the
    list [xs] on the body [a]. *)
let build_prod : (strloc * p_term option) list -> p_term -> p_term = fun xs a ->
   List.fold_right (fun (x,a) b -> Pos.none (P_Prod(x,a,b))) xs a

(** [ident] is an atomic parser for an identifier (for example variable name).
    It accepts (and returns as semantic value) any non-empty strings formed of
    letters, decimal digits, and the ['_'] and ['''] characters. Note that the
    special identifiers ["Type"] and ["_"] are rejected (since reserved). *)
let parser ident = id:''[_'a-zA-Z0-9]+'' ->
  if List.mem id ["Type"; "_"] then Earley.give_up (); in_pos _loc id

(** [qident] is an atomic parser for a qualified identifier, or in other words
    an identifier preceded by an optional module path. Its different parts are
    formed of the same characters as [ident], and are separated with the ['.']
    character. *)
let parser qident = id:''\([_'a-zA-Z0-9]+[.]\)*[_'a-zA-Z0-9]+'' ->
  let fs = List.rev (String.split_on_char '.' id) in
  let (fs,x) = (List.rev (List.tl fs), List.hd fs) in
  if List.mem id ["Type"; "_"] then Earley.give_up (); in_pos _loc (fs,x)

(* NOTE we use an [Earley] regular expression to parse “qualified identifiers”
   for efficiency reasons. Indeed, there is an ambiguity in the parser (due to
   the final dot), and this is one way to resolve it by being “greedy”. *)

(** [_wild_] is an atomic parser for the special ["_"] identifier. *)
let parser _wild_ = s:''[_][_'a-zA-Z0-9]*'' ->
  if s <> "_" then Earley.give_up ()

(** [_Type_] is an atomic parser for the special ["Type"] identifier. *)
let parser _Type_ = s:''[T][y][p][e][_'a-zA-Z0-9]*'' ->
  if s <> "Type" then Earley.give_up ()

(** [_def_] is an atomic parser for the ["def"] keyword. *)
let parser _def_ = s:''[d][e][f][_'a-zA-Z0-9]*'' ->
  if s <> "def" then Earley.give_up ()

(** [_thm_] is an atomic parser for the ["thm"] keyword. *)
let parser _thm_ = s:''[t][h][m][_'a-zA-Z0-9]*'' ->
  if s <> "thm" then Earley.give_up ()

(** [meta] is an atomic parser for a metavariable identifier. *)
let parser meta =
  (* Internal meta-variable by key. *)
  | "?" - s:''[1-9][0-9]*''             ->
      let k = int_of_string s in
      if Terms.(exists_meta (Internal(k))) then M_Sys(k) else M_Bad(k)
  (* User-defined meta-variable by name. *)
  | "?" - s:''[a-zA-Z][_'a-zA-Z0-9]*'' -> M_User(s)

(** [expr p] is a parser for an expression at priority [p]. *)
let parser expr (p : [`Func | `Appl | `Atom]) =
  (* Variable *)
  | qid:qident
      when p = `Atom -> in_pos _loc (P_Vari(qid))
  (* Type constant *)
  | _Type_
      when p = `Atom -> in_pos _loc P_Type
  (* Product *)
  | x:{ident ":"}?[Pos.none "_"] a:(expr `Appl) "->" b:(expr `Func)
      when p = `Func -> in_pos _loc (P_Prod(x,Some(a),b))
  | "!" x:ident a:{":" (expr `Appl)}? "," b:(expr `Func)
      when p = `Func -> in_pos _loc (P_Prod(x,a,b))
  (* Wildcard *)
  | _wild_
      when p = `Atom -> in_pos _loc P_Wild
  (* Abstraction *)
  | x:ident a:{":" (expr `Func)}? "=>" t:(expr `Func)
      when p = `Func -> in_pos _loc (P_Abst(x,a,t))
  (* Application *)
  | t:(expr `Appl) u:(expr `Atom)
      when p = `Appl -> in_pos _loc (P_Appl(t,u))
  (* Metavariable *)
  | m:meta e:env?[[]]
      when p = `Atom -> in_pos _loc (P_Meta(m, Array.of_list e))
  (* Parentheses *)
  | "(" t:(expr `Func) ")"
      when p = `Atom
  (* Coercions *)
  | t:(expr `Appl)
      when p = `Func
  | t:(expr `Atom)
      when p = `Appl

(** [env] is a parser for a metavariable environment. *)
and parser env = "[" t:(expr `Appl) ts:{"," (expr `Appl)}* "]" -> t::ts

(** [expr] is the entry point of the parser for expressions, which include all
    terms, types and patterns. *)
let expr = expr `Func

(** Representation of a reduction rule, with its context. *)
type old_p_rule = (strloc * p_term option) list * p_term * p_term
type p_rule = p_term * p_term

(** Representation of a toplevel command. *)
type p_cmd =
  (** Symbol declaration (definable when the boolean is [true]). *)
  | P_SymDecl  of bool * strloc * p_term
  (** Quick definition (opaque when the boolean is [true]). *)
  | P_SymDef   of bool * strloc * p_term option * p_term
  (** Rewriting rules declaration. *)
  | P_Rules    of p_rule list
  | P_OldRules of old_p_rule list
  (** Import an external signature. *)
  | P_Import   of module_path
  (** Set debugging flags. *)
  | P_Debug    of bool * string
  (** Set the verbosity level. *)
  | P_Verb     of int
  (** Type inference command. *)
  | P_Infer    of p_term * Eval.config
  (** Normalisation command. *)
  | P_Eval     of p_term * Eval.config
  (** Type-checking command. *)
  | P_TestType of bool * bool * p_term * p_term
  (** Convertibility command. *)
  | P_TestConv of bool * bool * p_term * p_term
  (** Unimplemented command. *)
  | P_Other    of strloc

(** [ty_ident] is a parser for an (optionally) typed identifier. *)
let parser ty_ident = id:ident a:{":" expr}?

(** [rule] is a parser for a single rewriting rule. *)
let parser rule = t:expr "-->" u:expr

(** [context] is a parser for a rewriting rule context. *)
let parser context = {x:ty_ident xs:{"," ty_ident}* -> x::xs}?[[]]

(** [old_rule] is a parser for a single rewriting rule (old syntax). *)
let parser old_rule =
  _:{"{" ident "}"}? "[" xs:context "]" t:expr "-->" u:expr

let parser arg =
  | "(" x:ident ":" a:expr ")" -> (x, Some(a))
  | x:ident                    -> (x, None   )

(** [def_def] is a parser for one specifc syntax of symbol definition. *)
let parser def_def = xs:arg* ao:{":" expr}? ":=" t:expr ->
  let fn (x,a) t = Pos.none (P_Abst(x,a,t)) in
    let t = List.fold_right fn xs t in
    let ao =
      match ao with
      | None    -> None
      | Some(a) -> Some(build_prod xs a)
    in
    (ao, t)

(** [mod_path] is a parser for a module path. *)
let parser mod_path = path:''\([-_'a-zA-Z0-9]+[.]\)*[-_'a-zA-Z0-9]+'' ->
  String.split_on_char '.' path

(** [strategy] is a parser for an evaluation strategy name. *)
let parser strategy =
  | "WHNF" -> Eval.WHNF
  | "HNF"  -> Eval.HNF
  | "SNF"  -> Eval.SNF

(** [steps] is a parser for an integer, used in evaluation configuration. *)
let parser steps = n:''[0-9]+'' -> int_of_string n

(** [eval_config] is a parser for an evaluation configuration. *)
let parser eval_config =
  | EMPTY                             -> Eval.{strategy = SNF; steps = None}
  | "[" s:strategy n:{"," steps}? "]" -> Eval.{strategy = s  ; steps = n   }
  | "[" n:steps s:{"," strategy}? "]" ->
      let strategy = match s with None -> Eval.SNF | Some(s) -> s in
      Eval.{strategy; steps = Some(n)}

let parser check =
  | "#CHECKNOT"  -> (false, true )
  | "#CHECK"     -> (false, false)
  | "#ASSERTNOT" -> (true , true )
  | "#ASSERT"    -> (true , false)

(** [cmd_aux] parses a single toplevel command. *)
let parser cmd_aux =
  | x:ident ":" a:expr               -> P_SymDecl(false,x,a)
  | _def_ x:ident ":" a:expr         -> P_SymDecl(true ,x,a)
  | _def_ x:ident (ao,t):def_def     -> P_SymDef(false,x,ao,t)
  | _thm_ x:ident (ao,t):def_def     -> P_SymDef(true ,x,ao,t)
  | r:rule rs:{"," rule}*            -> P_Rules(r::rs)
  | rs:old_rule+                     -> P_OldRules(rs)
  | "#REQUIRE" path:mod_path         -> P_Import(path)
  | "#DEBUG" f:''[+-]'' s:''[a-z]+'' -> P_Debug(f = "+", s)
  | "#VERBOSE" n:''[-+]?[0-9]+''     -> P_Verb(int_of_string n)
  | (ia,mf):check t:expr "::" a:expr -> P_TestType(ia,mf,t,a)
  | (ia,mf):check t:expr "==" u:expr -> P_TestConv(ia,mf,t,u)
  | "#INFER" c:eval_config t:expr    -> P_Infer(t,c)
  | "#EVAL" c:eval_config t:expr     -> P_Eval(t,c)
  | c:"#NAME" _:ident                -> P_Other(in_pos _loc_c c)

(** [cmd] parses a single toplevel command with its position. *)
let parser cmd = c:cmd_aux -> in_pos _loc c

(** Blank function for basic blank characters (' ', '\t', '\r' and '\n')
    and line comments starting with "//". *)
let blank buf pos =
  let rec fn state prev ((buf0, pos0) as curr) =
    let open Input in
    let (c, buf1, pos1) = read buf0 pos0 in
    let next = (buf1, pos1) in
    match (state, c) with
    (* Basic blancs. *)
    | (`Ini, ' '   )
    | (`Ini, '\t'  )
    | (`Ini, '\r'  )
    | (`Ini, '\n'  ) -> fn `Ini curr next
    (* Opening comment. *)
    | (`Ini, '('   ) -> fn `Opn curr next
    | (`Opn, ';'   ) -> fn `Com curr next
    (* Closing comment. *)
    | (`Com, ';'   ) -> fn `Cls curr next
    | (`Cls, ')'   ) -> fn `Ini curr next
    | (`Cls, _     ) -> fn `Com curr next
    (* Other. *)
    | (`Com, '\255') -> fatal "Unclosed comment...\n"
    | (`Com, _     ) -> fn `Com curr next
    | (`Opn, _     ) -> prev
    | (`Ini, _     ) -> curr
  in
  fn `Ini (buf, pos) (buf, pos)

(** [parse_file fname] attempts to parse the file [fname], to obtain a list of
    toplevel commands. In case of failure, a graceful error message containing
    the error position is displayerd and the program fails. *)
let parse_file : string -> p_cmd loc list =
  Earley.(handle_exception (parse_file (parser {l:cmd "."}*) blank))
