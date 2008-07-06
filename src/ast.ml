open Array;;
open Hashtbl;;

(* 
 * There are two kinds of rust files:
 * 
 * .rc files, containing crates.
 * .rs files, containing source.
 *
 *)


type filename = string
;;

type pos = (filename * int * int) 
type span = {lo: pos; hi: pos}
type 'a spanned = { node: 'a; span: span }
;;


(* 
 * Slot names are given by a dot-separated path within the current
 * module namespace. 
 *)

type ident = string
;;

type nonce = int
;;


(* "names" are statically computable references to particular slots;
   they never involve vector indexing. They are formed by a
   dot-separated sequence of identifier and/or index components,
   the latter representing tuple/call/ctor components (foo.#0, foo.#1, etc). 
   
   Each component of a name may also be type-parametric; you must 
   supply type parameters to reference through a type-parametric name
   component. So for example if foo is parametric in 2 types, you can
   write foo[int,int].bar but not foo.bar.
   
 *)

type ty_mach = 
    TY_unsigned
  | TY_signed
  | TY_ieee_bfp
  | TY_ieee_dfp
;;

type proto = 
    PROTO_ques  (* fn? foo(...): may yield 1 value or return w/o yielding. Never resumes. *)
  | PROTO_bang  (* fn! foo(...): yields 1 value. Never resumes.                           *)
  | PROTO_star  (* fn* foo(...): may yield N >= 0 values, then returns.                   *)
  | PROTO_plus  (* fn+ foo(...): yields N > 0 values then returns.                        *)
;;

type name_component =
    COMP_ident of ident
  | COMP_idx of int
  | COMP_app of (ty array)

and name = 
    {
     name_base: ident;
     name_rest: name_component array;
   }

(* 
 * Type expressions are transparent to type names, their equality is structural.
 * (after normalization)
 *)
and ty = 

    TY_any
  | TY_nil
  | TY_bool
  | TY_mach of (ty_mach * int)
  | TY_int
  | TY_char
  | TY_str

  | TY_tup of ty_tup
  | TY_vec of ty
  | TY_rec of ty_rec

  (* 
   * Note that ty_idx is only valid inside a slot of a ty_iso group, not 
   * in a general type term. 
   *)
  | TY_tag of ty_tag
  | TY_iso of ty_iso
  | TY_idx of int

  | TY_fn of ty_fn
  | TY_chan of ty
  | TY_port of ty

  | TY_named of name
  | TY_opaque of nonce
      
  | TY_constrained of (ty * constrs)
  | TY_mod of (mod_type_items)
  | TY_prog of ty_prog
  | TY_lim of ty
      
and slot = 
    SLOT_exterior of ty
  | SLOT_interior of ty
  | SLOT_read_alias of ty
  | SLOT_write_alias of ty


(* In closed type terms a constraint may refer to components of the
 * term by anchoring off the "formal symbol" '*', which represents "the
 * term this constraint is attached to".
 * 
 * 
 * For example, if I have a tuple type (int,int), I may wish to enforce
 * the lt predicate on it; I can write this as a constrained type term
 * like:
 * 
 * (int,int) : lt( *.(0), *.(1) )
 * 
 * In fact all tuple types are converted to this form for purpose of
 * type-compatibility testing; the argument tuple in a function
 * 
 * fn (int x, int y) : lt(x, y) -> int
 * 
 * desugars to
 * 
 * fn ((int, int) : lt( *.(0), *.(1) )) -> int
 * 
 *)

and carg_base = 
    BASE_formal 
  | BASE_named of ident
      
and carg =
    {
      carg_base: carg_base;
      carg_rest: name_component array;
    }

and constr = 
    { 
      constr_name: name;
      constr_args: carg array;
    }
      
and constrs = constr array
    
and prog = 
    {
      prog_init: init option;
      prog_main: stmt option;
      prog_fini: stmt option;
      prog_mod: mod_items;
    } 
      
and ty_rec = (ident, slot) Hashtbl.t
      
(* ty_tag is a sum type.
 * 
 * a tag type expression either normalizes to a TY_tag or a TY_iso,
 * which (like in ocaml) is an indexed projection from an iso-recursive
 * group of TY_tags.
 *)

and ty_tag = (ident, ty) Hashtbl.t

and ty_iso = 
    {
      iso_index: int;
      iso_group: ty_tag array
    }

      
and ty_tup = slot array

and tup_lvals = lval array

and tup_expr = expr array
           
and ty_sig = 
    { 
      sig_input_slot: slot;      
      sig_output_slot: slot;
    }

and ty_fn = 
    {
      fn_pure: bool;
      fn_lim: ty_limit;
      fn_sig: ty_sig;
      fn_proto: proto option;
    }


and ty_prog = 
    {
      prog_mod_ty: mod_type_items;
      prog_init_ty: ty;
    }
      
(* put+ f(a,b) means to call f with current put addr and self as ret
 * addr. this is a 'tail yield' that bypasses us during f execution.
 * 
 * ret+ f(a,b) means to call f with current pur addr and current ret
 * addr. this is a 'tail call' that destroys us.
 *)
and stmt' =
    STMT_while of stmt_while
  | STMT_do_while of stmt_while
  | STMT_foreach of stmt_foreach
  | STMT_for of stmt_for
  | STMT_if of stmt_if
  | STMT_try of stmt_try
  | STMT_put of (proto option * expr option)
  | STMT_ret of (proto option * expr option)
  | STMT_alt_tag of (ident, (slot * stmt)) Hashtbl.t
  | STMT_alt_type of stmt_alt_type
  | STMT_alt_port of stmt_alt_port
  | STMT_prove of (constrs)
  | STMT_check of (constrs)
  | STMT_checkif of (constrs * stmt)
  | STMT_block of ((stmt array))
  | STMT_copy of stmt_copy
  | STMT_call of (lval * (expr array))
  | STMT_send of (lval * expr)
  | STMT_recv of (lval * lval)
  | STMT_decl of stmt_decl 
  | STMT_use of (ty * ident * lval)
      
and stmt = stmt' spanned

and stmt_alt_type = 
    { 
      alt_type_arms: (ident * slot * stmt) array;
      alt_type_else: stmt option;
    }

and stmt_decl = 
    DECL_mod_item of (ident * mod_item)
  | DECL_slot_tup of (ty_tup * (ident array) * (expr option))

and stmt_copy = 
    COPY_to_lval of lval * expr
  | COPY_to_tup of tup_lvals * expr
      
and stmt_alt_port = 
    { 
      (* else expr is a timeout value, a b64 count of seconds. *)
      alt_port_arms: (lval * lval) array;
      alt_port_else: (expr * stmt) option;
    }

and stmt_while = 
    {
      while_expr: expr;
      while_body: stmt;
    }
      
and stmt_foreach = 
    {
      foreach_proto: proto;
      foreach_slot: (ident * slot);
      foreach_call: (lval * expr array);
      foreach_body: stmt;
    }
      
and stmt_for = 
    {
      for_init: stmt;
      for_test: expr;
      for_step: stmt;
      for_body: stmt;
    }

and stmt_if = 
    {
      if_test: expr;
      if_then: stmt;
      if_else: stmt option;
    }

and stmt_try = 
    {
      try_body: stmt;
      try_fail: stmt option;
      try_fini: stmt option;
    }

and rec_input = 
    REC_from_copy of (ident * expr)
  | REC_from_move of (ident * lval)

and expr' =
    EXPR_literal of lit
  | EXPR_binary of (binop * expr * expr)
  | EXPR_unary of (unop * expr)
  | EXPR_lval of lval
  | EXPR_call of (lval * (expr array))
  | EXPR_fn of fn
  | EXPR_prog of prog
  | EXPR_mod of  (ty * mod_items)
  | EXPR_rec of (ty * (rec_input array))

and expr = expr' spanned
    
and lit = 
  | LIT_nil
  | LIT_bool of bool
  | LIT_unsigned of (int * string)
  | LIT_signed of (int * string)
  | LIT_ieee_bfp of (float * string)
  | LIT_ieee_dfp of ((int * int) * string)
  | LIT_int of (Big_int.big_int * string)
  | LIT_char of char
  | LIT_str of string
  | LIT_custom of lit_custom


and lit_custom = 
    {
      lit_expander: lval;
      lit_arg: expr;
      lit_text: string;
    }

and lidx =
    LIDX_named of name_component
  | LIDX_index of expr
      
and lval' = 
    {
      lval_base: ident;
      lval_rest: lidx array;
    }

and lval = lval' spanned

and binop =    
    BINOP_or
  | BINOP_and

  | BINOP_eq
  | BINOP_ne

  | BINOP_lt
  | BINOP_le
  | BINOP_ge
  | BINOP_gt

  | BINOP_lsl
  | BINOP_lsr
  | BINOP_asr

  | BINOP_add
  | BINOP_sub
  | BINOP_mul
  | BINOP_div
  | BINOP_mod
  | BINOP_send

and unop =
    UNOP_not
  | UNOP_neg


and fn = 
    {
      fn_ty: ty_fn;
      fn_bind: ident array;
      fn_body: stmt;
    }

and pred = 
    {
      pred_ty: ty_sig;
      pred_bind: ident array;
      pred_body: stmt;
    }
      
and init = 
    {
      init_sig: ty_sig;
      init_bind: ident array;
      init_body: stmt;
    }

(* 
 * An 'a decl is a sort-of-thing that represents a parametric (generative)
 * declaration. Every reference to one of these involves applying 0 or more 
 * type arguments, as part of *name resolution*.
 * 
 * Slots are *not* parametric declarations. A slot has a specific type 
 * even if it's a type that's bound by a quantifier in its environment.
 *)


and ty_limit = 
    LIMITED
  | UNLIMITED

and 'a decl = 
    {
      decl_params: (ty_limit * ident) array;
      decl_item: 'a;
    }

(* 
 * We have module types and module expressions. A module expression is 
 * a table of module items. A module type is a table of module-type items.
 * 
 * The latter describe the former, despite the fact that modules can 
 * contain types: module types are not *equivalent* to module expressions,
 * and every module expression gives rise to a module value that conforms to
 * a possibly-existential module type.
 * 
 * Module values of particular module types are 'opened' by a 'use' statement.
 * This converts a module with opaque existential types into a module with
 * a corresponding set of concrete, disjoint opaque (skolem) types. These can
 * be projected out of the module bound by the 'use' statement in subsequent
 * declarations and statements, without risk of collision with other types.
 * 
 * For this reason, the MOD_TYPE_ITEM_opaque_type constructor takes no 
 * arguments -- it simply describes the presence of *some* existential type
 * in a module -- but whatever that existential may be, it is converted  
 * in the bound module to a MOD_ITEM_type (TY_opaque i) for some fresh i, 
 * when 'use'd.
 * 
 * This technique is explained in some depth in section 4.2 of the 
 * paper "first class modules for haskell", by Mark Shields and Simon 
 * Peyton Jones. Hopefully I'm doing it right. It's a little near the 
 * limit of tricks I understand.
 *)

and mod_item' = 
    MOD_ITEM_opaque_type of ty decl
  | MOD_ITEM_public_type of ty decl
  | MOD_ITEM_pred of pred decl
  | MOD_ITEM_mod of mod_items decl
  | MOD_ITEM_fn of fn decl
  | MOD_ITEM_prog of prog decl
  | MOD_ITEM_slot of (slot * expr option)

and mod_item = mod_item' spanned   
      
and mod_type_item' = 
    MOD_TYPE_ITEM_opaque_type of ty_limit decl
  | MOD_TYPE_ITEM_public_type of ty decl
  | MOD_TYPE_ITEM_pred of ty decl
  | MOD_TYPE_ITEM_mod of mod_type_items decl
  | MOD_TYPE_ITEM_fn of ty_fn decl
  | MOD_TYPE_ITEM_prog of ty_prog decl
  | MOD_TYPE_ITEM_slot of ty decl

and mod_type_item = mod_type_item' spanned

and mod_type_items = (ident, mod_type_item) Hashtbl.t


and mod_items = (ident, mod_item) Hashtbl.t
;;
