(* Translation *)

open Semant;;
open Common;;

let log cx = Session.log "trans"
  cx.ctxt_sess.Session.sess_log_trans
  cx.ctxt_sess.Session.sess_log_out
;;

let imm (i:int64) = Il.Imm (Asm.IMM i);;
let marker = imm 0xdeadbeefL;;
let one = imm 1L;;
let zero = imm 0L;;
let imm_true = one;;
let imm_false = zero;;

let arr_max a = (Array.length a) - 1;;

type intent =
    INTENT_init
  | INTENT_read
  | INTENT_write
  | INTENT_drop
;;

type quad_idx = int
;;

let trans_visitor
    (cx:ctxt)
    (inner:Walk.visitor)
    : Walk.visitor =

  let iflog thunk =
    if cx.ctxt_sess.Session.sess_log_trans
    then thunk ()
    else ()
  in

  let (path:Ast.ident Stack.t) = Stack.create () in
  let annotations = Hashtbl.create 0 in
  let block_layouts = Stack.create () in
  let curr_file = ref None in
  let curr_stmt = ref None in

  let (abi:Abi.abi) = cx.ctxt_abi in
  let (word_sz:int64) = abi.Abi.abi_word_sz in
  let (word_bits:Il.bits) = abi.Abi.abi_word_bits in
  let word_n (n:int) = Int64.mul word_sz (Int64.of_int n) in

  let (strings:(string,fixup) Hashtbl.t) = Hashtbl.create 0 in

  let emitters = Stack.create () in
  let push_new_emitter _ =
    Stack.push
      (Il.new_emitter
         abi.Abi.abi_prealloc_quad
         abi.Abi.abi_is_2addr_machine)
      emitters
  in
  let pop_emitter _ = ignore (Stack.pop emitters) in
  let emitter _ = Stack.top emitters in
  let name _ = Stack.top path in
  let emit q = Il.emit (emitter()) q in
  let next_vreg _ = Il.next_vreg (emitter()) in
  let mark _ : quad_idx = (emitter()).Il.emit_pc in
  let patch_existing (jmp:quad_idx) (targ:quad_idx) : unit =
    Il.patch_jump (emitter()) jmp targ
  in
  let patch (i:quad_idx) : unit =
    Il.patch_jump (emitter()) i (mark());
    (* Insert a dead quad to ensure there's an otherwise-unused patch target here. *)
    emit Il.Dead
  in

  let annotate (str:string) =
    Hashtbl.add annotations (emitter()).Il.emit_pc str
  in

  let epilogue_jumps = Stack.create() in

  let path_name (_:unit) : string =
    String.concat "." (stk_elts_from_bot path)
  in

  let based (reg:Il.reg) : Il.addr =
    Il.Based (reg, None)
  in

  let based_off (reg:Il.reg) (off:Asm.expr64) : Il.addr =
    Il.Based (reg, Some off)
  in

  let based_imm (reg:Il.reg) (imm:int64) : Il.addr =
    based_off reg (Asm.IMM imm)
  in

  let fp_imm (imm:int64) : Il.addr =
    based_imm abi.Abi.abi_fp_reg imm
  in

  let sp_imm (imm:int64) : Il.addr =
    based_imm abi.Abi.abi_sp_reg imm
  in

  let word_at (addr:Il.addr) : Il.cell =
    Il.Addr (addr, Il.ScalarTy (Il.ValTy word_bits))
  in

  let byte_at (addr:Il.addr) : Il.cell =
    Il.Addr (addr, Il.ScalarTy (Il.ValTy Il.Bits8))
  in

  let addr_add (addr:Il.addr) (off:Asm.expr64) : Il.addr =
    let addto e = Asm.ADD (off, e) in
      match addr with
          Il.Abs e -> Il.Abs (addto e)
        | Il.Based (r, None) -> Il.Based (r, Some off)
        | Il.Based (r, Some e) -> Il.Based (r, Some (addto e))
        | Il.Pcrel (f, None) -> Il.Pcrel (f, Some off)
        | Il.Pcrel (f, Some e) -> Il.Pcrel (f, Some (addto e))
        | Il.Spill _ -> err None "Adding offset to spill slot"
  in

  let addr_add_imm (addr:Il.addr) (imm:int64) : Il.addr =
    addr_add addr (Asm.IMM imm)
  in

  let mov (dst:Il.cell) (src:Il.operand) : unit =
    emit (Il.umov dst src)
  in

  let lea (dst:Il.cell) (src:Il.addr) : unit =
    emit (Il.lea dst src)
  in


  let alias (ta:Il.typed_addr) : Il.operand =
    let addr, ty = ta in
    let vreg_cell = Il.next_vreg_cell (emitter()) (Il.AddrTy ty) in
      lea vreg_cell addr;
      Il.Cell vreg_cell
  in

  let force_to_mem (src:Il.operand) : Il.typed_addr =
    let do_spill (t:Il.scalar_ty) =
      let s = (Il.next_spill (emitter())) in
      let spill_addr = Il.Spill s in
      let spill_ta = (spill_addr, Il.ScalarTy t) in
        mov (Il.Addr spill_ta) src;
        spill_ta
    in
    match src with
        Il.Cell (Il.Addr ta) -> ta
      | Il.Cell (Il.Reg (_, t)) -> do_spill t
      | Il.Imm _ -> do_spill (Il.ValTy word_bits)
  in

  let force_to_reg (op:Il.operand) : Il.typed_reg =
    let do_mov st =
      let tmp = next_vreg () in
      let regty = (tmp, st) in
        mov (Il.Reg regty) op;
        regty
    in
      match op with
          Il.Cell (Il.Reg rt) -> rt
        | Il.Cell (Il.Addr (_, refty)) -> do_mov (Il.AddrTy refty)
        | Il.Imm _ -> do_mov (Il.ValTy word_bits)
  in

  let deref (ptr:Il.operand) : Il.typed_addr =
    let (reg, ty) = force_to_reg ptr in
      match ty with
          Il.AddrTy t -> (based reg, t)
        | Il.ValTy _ -> err None "dereferencing value-typed operand"
  in

  let deref_off (ptr:Il.operand) (off:Asm.expr64) : Il.typed_addr =
    let (reg, ty) = force_to_reg ptr in
      match ty with
          Il.AddrTy t -> (based_off reg off, t)
        | Il.ValTy _ -> err None "dereferencing value-typed operand"
  in

  let deref_imm (ptr:Il.operand) (imm:int64) : Il.typed_addr =
    deref_off ptr (Asm.IMM imm)
  in

  let rec atom_type (at:Ast.atom) : Ast.ty =
    match at with
        Ast.ATOM_literal {node=(Ast.LIT_int _); id=_} -> Ast.TY_int
      | Ast.ATOM_literal {node=(Ast.LIT_bool _); id=_} -> Ast.TY_bool
      | Ast.ATOM_literal {node=(Ast.LIT_char _); id=_} -> Ast.TY_char
      | Ast.ATOM_literal {node=(Ast.LIT_nil); id=_} -> Ast.TY_nil
      | Ast.ATOM_literal _ -> err None "unhandled form of literal in atom_type"
      | Ast.ATOM_lval (Ast.LVAL_base nb) ->
          let slot = lval_to_slot cx nb.id in
            begin
              match slot.Ast.slot_ty with
                  None -> err (Some nb.id) "name refers to untyped slot, in atom_type"
                | Some t -> t
            end
      | Ast.ATOM_lval (Ast.LVAL_ext (base, comp)) ->
          let base_ty = atom_type (Ast.ATOM_lval base) in
          let need_ty topt =
            match topt with
                None -> err None "missing type in lval-ext"
              | Some s -> s
          in
            match (base_ty, comp) with
                (Ast.TY_rec elts, Ast.COMP_named (Ast.COMP_ident id)) ->
                  begin
                    match atab_search elts id with
                        Some slot -> need_ty slot.Ast.slot_ty
                      | None -> err None "unknown record-member '%s'" id
                  end

              | (Ast.TY_tup elts, Ast.COMP_named (Ast.COMP_idx i)) ->
                  if 0 <= i && i < (Array.length elts)
                  then need_ty elts.(i).Ast.slot_ty
                  else err None "out-of-range tuple index %d" i

              | (Ast.TY_vec ety, Ast.COMP_named (Ast.COMP_idx _)) ->
                  ety

              | (Ast.TY_vec ety, Ast.COMP_atom _) ->
                  ety

              | (_,_) -> err None "unhandled form of lval-ext"
  in

  let expr_type e =
    match e with
        Ast.EXPR_binary (op, a, _) ->
          begin
            match op with
                Ast.BINOP_eq | Ast.BINOP_ne | Ast.BINOP_lt  | Ast.BINOP_le
              | Ast.BINOP_ge | Ast.BINOP_gt -> Ast.TY_bool
              | _ -> atom_type a
          end
      | Ast.EXPR_unary (Ast.UNOP_not, _) -> Ast.TY_bool
      | Ast.EXPR_unary (_, a) -> atom_type a
      | Ast.EXPR_atom a -> atom_type a
  in

  let cell_vreg_num (vr:(int option) ref) : int =
    match !vr with
        None ->
          let v = (Il.next_vreg_num (emitter())) in
            vr := Some v;
            v
      | Some v -> v
  in

  let rec slot_referent_type (s:Ast.slot) : Il.referent_ty =
    let bw = Il.ScalarTy (Il.ValTy word_bits) in
    let ptr = Il.ScalarTy (Il.voidptr_t) in
    let op = Il.OpaqueTy in
    let rec referent_ty t =
      match t with
          Ast.TY_any -> Il.StructTy [| bw;  ptr |]
        | Ast.TY_nil -> bw
        | Ast.TY_int -> bw
        | Ast.TY_mach (TY_u8) -> Il.ScalarTy (Il.ValTy Il.Bits8)
        | Ast.TY_mach (TY_s8) -> Il.ScalarTy (Il.ValTy Il.Bits8)
        | Ast.TY_mach (TY_u16) -> Il.ScalarTy (Il.ValTy Il.Bits16)
        | Ast.TY_mach (TY_s16) -> Il.ScalarTy (Il.ValTy Il.Bits16)
        | Ast.TY_mach (TY_u32) -> Il.ScalarTy (Il.ValTy Il.Bits32)
        | Ast.TY_mach (TY_s32) -> Il.ScalarTy (Il.ValTy Il.Bits32)
        | Ast.TY_mach (TY_u64) -> Il.ScalarTy (Il.ValTy Il.Bits64)
        | Ast.TY_mach (TY_s64) -> Il.ScalarTy (Il.ValTy Il.Bits64)
        | Ast.TY_char -> Il.ScalarTy (Il.ValTy Il.Bits32)
        | Ast.TY_str -> Il.StructTy [| bw; bw; bw; ptr |]
        | Ast.TY_vec _ -> Il.StructTy [| bw; bw; bw; ptr |]
        | Ast.TY_tup tt ->
            Il.StructTy (Array.map slot_referent_type tt)
        | Ast.TY_rec tr ->
            Il.StructTy
              (Array.map (fun (ident, slot) ->
                            slot_referent_type slot) tr)
        | Ast.TY_tag _ -> op
        | Ast.TY_iso _ -> op
        | Ast.TY_idx _ -> op

        | Ast.TY_fn _ -> op
        | Ast.TY_pred _ -> op
        | Ast.TY_chan _ -> op
        | Ast.TY_port _ -> op

        | Ast.TY_mod _ -> op
        | Ast.TY_prog _ -> Il.StructTy [| ptr; ptr; ptr |]
        | Ast.TY_proc -> op
        | Ast.TY_opaque _ -> op
        | Ast.TY_named _ -> err None "named type"
        | Ast.TY_type -> op
        | Ast.TY_constrained (t, _) -> slot_referent_type t
        | Ast.TY_lim t -> referent_type t
    in
      referent_ty (slot_ty s)
  in

  let slot_id_referent_type (slotit:node_id) : Il.referent_ty =
    slot_referent_type (Hashtbl.find cx.ctxt_all_slots slotid)
  in

  let operand_of_block_slot
      (slotid:node_id)
      : Il.operand =
    match htab_search cx.ctxt_slot_vregs slotid with
        Some vr ->
          Il.Reg (Il.Vreg (cell_vreg_num vr, slot_id_referent_type slotid))
      | None ->
          begin
            match htab_search cx.ctxt_slot_layouts slotid with
                None -> err (Some slotid) "slot assigned to neither vreg nor layout"
              | Some layout ->
                  let disp = layout.layout_offset in
                    fp_imm disp
          end
  in

  let operand_of_proc_slot (lval_id:node_id) (slot_id:node_id)  =
    let pp_cell =
      if Hashtbl.mem cx.ctxt_lval_is_in_proc_init lval_id
      then
        let prog = get_prog_owning_slot cx slot_id in
        let init_proc_slot_layout = match prog.Ast.prog_init with
            None -> err (Some lval_id) "Lval in nonexistent prog init"
          | Some init -> Hashtbl.find cx.ctxt_slot_layouts init.node.Ast.init_proc_input.id
        in
          word_at (sp_imm init_proc_slot_layout.layout_offset)
      else
        abi.Abi.abi_pp_cell
    in
    let layout = Hashtbl.find cx.ctxt_slot_layouts slot_id in
    let disp = (Int64.add layout.layout_offset (word_n Abi.proc_field_data))
    in
      word_at (deref_imm (Il.Cell pp_cell) disp)
  in

  let rec trans_lval_ext
      (base_slot:Ast.slot)
      (base_reg:Il.reg option)
      (base_off:Asm.expr64)
      (comp:Ast.lval_component)
      : (Il.operand * Ast.slot) =

    match (base_slot.Ast.slot_ty, comp) with
        (Some (Ast.TY_rec entries),
         Ast.COMP_named (Ast.COMP_ident id)) ->
          let layouts = layout_rec abi entries in
          let (slot, layout) = atab_find layouts id in
          let disp = layout.layout_offset in
          let oper = (word_at_reg_off_imm
                        base_reg base_off disp)
          in
            (oper, slot)

      | (Some (Ast.TY_tup entries),
         Ast.COMP_named (Ast.COMP_idx i)) ->
          let layouts = layout_tup abi entries in
          let slot = entries.(i) in
          let disp = layouts.(i).layout_offset in
          let oper = (word_at_reg_off_imm
                        base_reg base_off disp)
          in
            (oper, slot)

      | (Some (Ast.TY_vec ety),
         Ast.COMP_named (Ast.COMP_idx i)) ->
          let unit_sz = ty_sz abi ety in
          let slot = interior_slot ety in
          let disp = Int64.mul unit_sz (Int64.of_int i) in
          let vec = word_at_reg_off base_reg base_off in
          let elt = trans_bounds_check vec (imm disp) in
            (elt, slot)

      | (Some (Ast.TY_vec ety),
         Ast.COMP_atom at) ->
          let atop = trans_atom at in
          let unit_sz = ty_sz abi ety in
          let slot = interior_slot ety in
          let reg = next_vreg () in
          let t = Il.Reg reg in
          let vec = word_at_reg_off base_reg base_off in
            emit Il.UMUL t atop (imm unit_sz);
            let elt = trans_bounds_check vec t in
              (elt, slot)

      | _ -> err None "unhandled form of lval_ext in trans_lval_ext"

  (* 
   * vec: operand holding ptr to vec.
   * mul_idx: index value * unit size.
   * return: ptr to element.
   *)
  and trans_bounds_check (vec:Il.operand) (mul_idx:Il.operand) : Il.operand =
    let len = deref_imm vec (word_n 2) in
    let base = Il.Reg (next_vreg()) in
    let elt = Il.Reg (next_vreg ()) in
    let diff = Il.Reg (next_vreg ()) in
      annotate "bounds check";
      lea base (deref_imm vec (word_n 3));
      emit Il.ADD elt base mul_idx;
      emit Il.SUB diff elt base;
      let jmp = trans_compare Il.JB diff len in
        trans_cond_fail "bounds check" jmp;
        deref elt

  and trans_lval_full
      (lv:Ast.lval)
      (pcrel_ok:bool)
      (imm_ok:bool)
      (intent:intent)
      : (Il.operand * Ast.slot) =

    let return_fixup (fix:fixup) (slot:Ast.slot)
        : (Il.operand * Ast.slot) =
      if pcrel_ok
      then (Il.Pcrel fix, slot)
      else
        let imm = (Il.Imm (Asm.M_POS fix)) in
          if imm_ok
          then (imm, slot)
          else (Il.Reg (force_to_reg imm), slot)
    in

    let return_item (item:Ast.mod_item') (referent:node_id)
        : (Il.operand * Ast.slot) =
      let ty = Hashtbl.find cx.ctxt_all_item_types referent in
      let slot = { Ast.slot_mode = Ast.MODE_interior;
                   Ast.slot_ty = Some ty }
      in
        match item with
            Ast.MOD_ITEM_fn _ ->
              return_fixup (get_fn_fixup cx referent) slot
          | Ast.MOD_ITEM_prog _ ->
              return_fixup (get_prog_fixup cx referent) slot
          | Ast.MOD_ITEM_tag t ->
              return_fixup (get_tag_fixup cx referent) slot
          | _ ->
              err (Some referent)
                "unhandled item type in trans_lval_full"
    in

    let return_native_item (item:Ast.native_mod_item') (referent:node_id)
        : (Il.operand * Ast.slot) =
      let ty = Hashtbl.find cx.ctxt_all_item_types referent in
      let slot = { Ast.slot_mode = Ast.MODE_interior;
                   Ast.slot_ty = Some ty }
      in
        match item with
            Ast.NATIVE_fn _ ->
              return_fixup (get_fn_fixup cx referent) slot
          | _ ->
              err (Some referent)
                "unhandled native item type in trans_lval_full"
    in

    let return_slot (lval_id:node_id) (slot:Ast.slot) (slot_id:node_id)
        : (Il.operand * Ast.slot) =
      let operand =
        if slot_is_owned_by_prog cx slot_id
        then operand_of_proc_slot lval_id slot_id
        else operand_of_block_slot slot_id
      in
        (operand, slot)
    in

      match lv with
          Ast.LVAL_ext (base, comp) ->
            let (base_operand, base_slot) = trans_lval_full base false true intent in
            let base_operand' = deref_slot base_operand base_slot intent in
            let (base_reg, base_off) = get_reg_off base_operand' in
              trans_lval_ext base_slot base_reg base_off comp

        | Ast.LVAL_base nb ->
            let referent = lval_to_referent cx nb.id in
              begin
                match htab_search cx.ctxt_all_items referent with
                    Some item -> return_item item referent
                  | None ->
                      match htab_search cx.ctxt_all_native_items referent with
                          Some item -> return_native_item item referent
                        | None ->
                            let slot = lval_to_slot cx nb.id in
                              return_slot nb.id slot referent
              end

  and trans_lval (lv:Ast.lval) (intent:intent) : (Il.operand * Ast.slot) =
    trans_lval_full lv false false intent

  and trans_static_string (s:string) : Il.operand =
    let fix =
      if Hashtbl.mem strings s
      then Hashtbl.find strings s
      else
        let strfix = new_fixup "string fixup" in
        let str = Asm.DEF (strfix, Asm.ZSTRING s) in
          htab_put strings s strfix;
          cx.ctxt_data_items <- str :: cx.ctxt_data_items;
          strfix
    in
      (Il.Imm (Asm.M_POS fix))

  and trans_init_str (dst:Ast.lval) (s:string) : unit =
    (* Include null byte. *)
    let init_sz = Int64.of_int ((String.length s) + 1) in
    let static = trans_static_string s in
    let (dstop, _) = trans_lval dst INTENT_init in
      trans_upcall Abi.UPCALL_new_str
        [|
          (alias dstop);
          static;
          imm init_sz
        |]

  and trans_atom (atom:Ast.atom) : Il.operand =
    iflog
      begin
        fun _ ->
          annotate (Ast.fmt_to_str Ast.fmt_atom atom)
      end;

    match atom with
        Ast.ATOM_lval lv ->
          let (operand, slot) = trans_lval lv INTENT_read in
            deref_slot operand slot INTENT_read

      | Ast.ATOM_literal lit ->
          begin
            match lit.node with
                Ast.LIT_nil -> Il.Nil
              | Ast.LIT_bool false -> imm_false
              | Ast.LIT_bool true -> imm_true
              | Ast.LIT_char c -> imm (Int64.of_int (Char.code c))
              | Ast.LIT_int (bi, s) ->
                  imm (Int64.of_int (Big_int.int_of_big_int bi))

              | _ -> marker
          end


  (* trans_compare returns a quad number of the cjmp, which the caller
     patches to the cjmp destination.  *)
  and trans_compare
      (cjmp:Il.op)
      (lhs:Il.operand)
      (rhs:Il.operand)
      : quad_idx list =
    emit Il.CMP Il.Nil (Il.Reg (force_to_reg lhs)) rhs;
    let jmp = mark() in
      emit cjmp Il.Nil badlab Il.Nil;
      [jmp]

  and trans_structural_compare
      (cjmp:Il.op)
      (lhs:Il.operand) (* read alias *)
      (rhs:Il.operand) (* read alias *)
      (ty:Ast.ty)
      : quad_idx list =
    let lhs_reg = force_to_reg lhs in
    let rhs_reg = force_to_reg rhs in
    let jmps = ref [] in
    let sub_compare slot off =
      let load x =
        (* FIXME: this is simply incorrect. Time for a typed IL? *)
        deref_slot (word_at_reg_off (Some x) (Asm.IMM off)) slot INTENT_read
      in
      let new_jmps =
        trans_structural_compare cjmp
          (load lhs_reg) (load rhs_reg) (slot_ty slot)
      in
        jmps := new_jmps :: (!jmps)
    in
    let trans_compare_tup (lhs:Il.operand) (rhs:Il.operand) (ttup:Ast.ty_tup) : unit =
      let offset = ref 0L in
      for i = 0 to arr_max ttup do
        sub_compare ttup.(i) (!offset)
      done
    in
      []

  and trans_cond (invert:bool) (expr:Ast.expr) : quad_idx list =

    let anno _ =
      iflog
        begin
          fun _ ->
            annotate ((Ast.fmt_to_str Ast.fmt_expr expr) ^
                        ": cond, finale")
        end
    in

    match expr with
        Ast.EXPR_binary (binop, a, b) ->
          let lhs = trans_atom a in
          let rhs = trans_atom b in
          let cjmp =
            match binop with
                Ast.BINOP_eq -> Il.JE
              | Ast.BINOP_ne -> Il.JNE
              | Ast.BINOP_lt -> Il.JL
              | Ast.BINOP_le -> Il.JLE
              | Ast.BINOP_ge -> Il.JGE
              | Ast.BINOP_gt -> Il.JG
              | _ -> err None "Unhandled binop of expr in trans_cond"
          in
          let cjmp' =
            if invert then
              match cjmp with
                  Il.JE -> Il.JNE
                | Il.JNE -> Il.JE
                | Il.JL -> Il.JGE
                | Il.JLE -> Il.JG
                | Il.JGE -> Il.JL
                | Il.JG -> Il.JLE
                | _ -> err None "Unhandled inverse binop in trans_cond"
            else
              cjmp
          in
            anno ();
            trans_compare cjmp' lhs rhs

      | _ ->
          let bool_operand = trans_expr expr in
            anno ();
            trans_compare Il.JNE bool_operand
              (if invert then imm_true else imm_false)

  and trans_expr (expr:Ast.expr) : Il.operand =

    let anno _ =
      iflog
        begin
          fun _ ->
            annotate ((Ast.fmt_to_str Ast.fmt_expr expr) ^
                        ": plain exit, finale")
        end
    in

    match expr with

        Ast.EXPR_binary (binop, a, b) ->
          let arith op =
            let dst = Il.Reg (Il.next_vreg (emitter())) in
            let lhs = trans_atom a in
            let rhs = trans_atom b in
              anno ();
              emit op dst lhs rhs;
              dst
          in
            begin
              match binop with
                  Ast.BINOP_or -> arith Il.OR
                | Ast.BINOP_and -> arith Il.AND

                | Ast.BINOP_lsl -> arith Il.LSL
                | Ast.BINOP_lsr -> arith Il.LSR
                | Ast.BINOP_asr -> arith Il.ASR

                | Ast.BINOP_add -> arith Il.ADD
                | Ast.BINOP_sub -> arith Il.SUB

                (* FIXME: switch on type of operands, IMUL/IDIV/IMOD etc. *)
                | Ast.BINOP_mul -> arith Il.UMUL
                | Ast.BINOP_div -> arith Il.UDIV
                | Ast.BINOP_mod -> arith Il.UMOD

                | _ ->
                    let dst = Il.Reg (Il.next_vreg (emitter())) in
                      begin
                        mov dst imm_true;
                        let jmps = trans_cond false expr in
                          mov dst imm_false;
                          List.iter patch jmps;
                          dst
                      end
            end

      | Ast.EXPR_unary (unop, a) ->
          let src = trans_atom a in
          let dst = Il.Reg (Il.next_vreg (emitter())) in
          let op = match unop with
              Ast.UNOP_not -> Il.NOT
            | Ast.UNOP_neg -> Il.NEG
          in
            anno ();
            emit op dst src Il.Nil;
            dst

      | Ast.EXPR_atom a ->
          trans_atom a

  and trans_block (block:Ast.block) : unit =
    Stack.push (get_block_layout cx block.id) block_layouts;
    Array.iter trans_stmt block.node;
    let block_slots = Hashtbl.find cx.ctxt_block_slots block.id in
      (* 
       * FIXME: this is not going to free things in the proper order; 
       * we need to analyze the decl order in an earlier phase and thread
       * it through to here. 
       *)
      Hashtbl.iter
        begin
          fun slotkey slotid ->
            iflog
              begin
                fun _ ->
                  annotate
                    ("drop slot: " ^
                       (Ast.fmt_to_str Ast.fmt_slot_key slotkey))
              end;
            let slot = Hashtbl.find cx.ctxt_all_slots slotid in
            let operand = operand_of_block_slot slotid in
              trans_drop_slot operand slot
        end
        block_slots;
      ignore (Stack.pop block_layouts)


  and trans_upcall (u:Abi.upcall) (args:Il.operand array) : unit =
    abi.Abi.abi_emit_upcall (emitter()) u args cx.ctxt_proc_to_c_fixup;

  and trans_log_int (a:Ast.atom) : unit =
    trans_upcall Abi.UPCALL_log_int [| (trans_atom a) |]

  and trans_log_str (a:Ast.atom) : unit =
    trans_upcall Abi.UPCALL_log_str [| (trans_atom a) |]

  and trans_spawn
      (dst:Ast.lval)
      (prog_lval:Ast.lval)
      (args:Ast.atom array)
      : unit =
    let (proc_operand, proc_slot) = trans_lval dst INTENT_init in
    let (prog_operand, prog_slot) = trans_lval prog_lval INTENT_read in
    let tsig =
      match prog_slot.Ast.slot_ty with
          Some (Ast.TY_prog tsig) -> tsig
        | _ -> err None "prog pseudo-slot has wrong type"
    in
      (* 
       * We're fudging here; the proc operand isn't really the dst operand, 
       * it's the 0th slot of the dst tuple though. 
       *)
      trans_upcall Abi.UPCALL_new_proc [| (alias proc_operand); prog_operand |];
      let in_slots = tsig.Ast.sig_input_slots in
        (* FIXME: this is a ghastly mess. *)
      let arg_layouts = layout_init_call_tup abi tsig in
      let init_operand = deref_imm prog_operand (word_n Abi.prog_field_init)
      in
        emit Il.CMP Il.Nil init_operand imm_false;
        let fwd_jmp = mark () in
          emit Il.JE Il.Nil badlab Il.Nil;
          trans_call (fun _ -> "spawn-init") proc_operand init_operand
            in_slots arg_layouts (Some proc_operand) args;
          patch fwd_jmp;
          iflog (fun _ -> annotate "sched proc");
          trans_upcall Abi.UPCALL_sched [| proc_operand |]

  and trans_cond_fail (str:string) (fwd_jmps:quad_idx list) : unit =
    let (filename, line, _) =
      match !curr_stmt with
          None -> ("<none>", 0, 0)
        | Some stmt_id ->
            match (Session.get_span cx.ctxt_sess stmt_id) with
                None -> ("<none>", 0, 0)
              | Some sp -> sp.lo
    in
      trans_upcall Abi.UPCALL_fail
        [|
          trans_static_string str;
          trans_static_string filename;
          imm (Int64.of_int line)
        |];
      List.iter patch fwd_jmps

  and trans_check_expr (e:Ast.expr) : unit =
    let fwd_jmps = trans_cond false e in
      trans_cond_fail (Ast.fmt_to_str Ast.fmt_expr e) fwd_jmps

  and trans_malloc (dst:Il.operand) (nbytes:int64) : unit =
    if Il.is_mem dst
    then
      trans_upcall Abi.UPCALL_malloc [| (alias dst); imm nbytes |]
    else
      let s = Il.next_spill (emitter()) in
        begin
          mov s zero;
          trans_upcall Abi.UPCALL_malloc [| (alias s); imm nbytes |];
          mov dst s
        end

  and trans_free (src:Il.operand) : unit =
    trans_upcall Abi.UPCALL_free [| src |]

  and refcount_cell (n:int) (operand:Il.operand) : Il.operand =
    word_at_reg_off (Some (force_to_reg operand)) (Asm.IMM (word_n n))

  and trans_send (chan:Ast.lval) (src:Ast.lval) : unit =
    let (srcop, _) = trans_lval src INTENT_read in
      trans_upcall Abi.UPCALL_send [| (trans_atom (Ast.ATOM_lval chan)); (alias srcop) |]

  and trans_recv (dst:Ast.lval) (chan:Ast.lval) : unit =
    let (dstop, _) = trans_lval dst INTENT_write in
      trans_upcall Abi.UPCALL_recv [| (alias dstop); (trans_atom (Ast.ATOM_lval chan)) |]

  and trans_init_port (dst:Ast.lval) : unit =
    let (dstop, dst_slot) = trans_lval dst INTENT_init in
    let unit_ty = match slot_ty dst_slot with
        Ast.TY_port t -> t
      | _ -> err None "init dst of port-init has non-port type"
    in
    let unit_sz = ty_sz abi unit_ty in
      trans_upcall Abi.UPCALL_new_port [| (alias dstop); imm unit_sz |]

  and trans_del_port (port:Il.operand) : unit =
    trans_upcall Abi.UPCALL_del_port [| port |]

  and trans_del_proc (proc:Il.operand) : unit =
    (* FIXME: this needs to run the fini block and all that. *)
    trans_upcall Abi.UPCALL_del_proc [| proc |]

(*
  and trans_inline_memcpy (dst_addr:Il.operand) (src_addr:Il.operand) (nbytes:int64) : unit =
    let dst_reg = force_to_reg dst_addr in
    let src_reg = force_to_reg src_addr in
    let dst = Il.Reg src_reg in
    let src = Il.Reg dst_reg in
    let src_end = Il.Reg (Il.next_vreg (emitter())) in
    let tmp = Il.Reg (Il.next_vreg (emitter())) in
      mov src_end src_addr;
      emit Il.ADD src_end src_end (imm nbytes);
      let fwd_jmp = mark() in
        emit Il.JMP Il.Nil badlab Il.Nil;
        let loop_begin = mark () in
          begin
            emit Il.UMOV tmp (byte_at_reg_off (Some src_reg) (Asm.IMM 0L)) Il.Nil;
            emit Il.UMOV (byte_at_reg_off (Some dst_reg) (Asm.IMM 0L)) tmp Il.Nil;
            emit Il.ADD src src one;
            emit Il.ADD dst dst one;
            emit Il.ADD dst dst one;
            patch fwd_jmp;
            emit Il.CMP Il.Nil src src_end;
            emit Il.JNE Il.Nil (Il.Label loop_begin) Il.Nil
          end
*)

  (*
   * A vec is implicitly exterior: every slot vec[T] is 1 word and
   * points to a refcounted structure. That structure has 3 words with
   * defined meaning at the beginning; data follows the header.
   *
   *   word 0: refcount
   *   word 1: allocated size of data
   *   word 2: initialized size of data
   *   word 3...N: data
   * 
   * This 3-word prefix is shared with strings, we factor the common
   * part out for reuse in string code.
   *)

  and trans_init_vec (dst:Ast.lval) (atoms:Ast.atom array) : unit =
    let (dstop, dst_slot) = trans_lval dst INTENT_init in
    let unit_ty = match slot_ty dst_slot with
        Ast.TY_vec t -> t
      | _ -> err None "init dst of vec-init has non-port type"
    in
    let unit_sz = ty_sz abi unit_ty in
    let n_inits = Array.length atoms in
    let init_sz = Int64.mul unit_sz (Int64.of_int n_inits) in
    let padded_sz = Int64.add init_sz (word_n 3) in
    let alloc_sz = next_power_of_two padded_sz in
      trans_malloc dstop alloc_sz;
      mov (deref_imm dstop (word_n 0)) one;
      mov (deref_imm dstop (word_n 1)) (imm alloc_sz);
      mov (deref_imm dstop (word_n 2)) (imm init_sz);
      Array.iteri
        begin
          fun i atom ->
            let lval = (Ast.LVAL_ext
                          (dst, (Ast.COMP_named (Ast.COMP_idx i))))
            in
            let expr = Ast.EXPR_atom atom in
              trans_copy true lval expr
        end
        atoms

  and next_power_of_two (x:int64) : int64 =
    let xr = ref (Int64.sub x 1L) in
      xr := Int64.logor (!xr) (Int64.shift_right_logical (!xr) 1);
      xr := Int64.logor (!xr) (Int64.shift_right_logical (!xr) 2);
      xr := Int64.logor (!xr) (Int64.shift_right_logical (!xr) 4);
      xr := Int64.logor (!xr) (Int64.shift_right_logical (!xr) 8);
      xr := Int64.logor (!xr) (Int64.shift_right_logical (!xr) 16);
      xr := Int64.logor (!xr) (Int64.shift_right_logical (!xr) 32);
      Int64.add 1L (!xr)

  and exterior_refcount_cell (operand:Il.operand) : Il.operand =
    refcount_cell Abi.exterior_slot_field_refcnt operand

  and exterior_body_off = word_n Abi.exterior_slot_field_body

  and exterior_allocation_size (slot:Ast.slot) : int64 =
    let layout = layout_slot abi 0L slot in
      (Int64.add layout.layout_size exterior_body_off)

  and slot_refcount_cell (operand:Il.operand) (slot:Ast.slot) : (Il.operand option) =
    match slot_ty slot with
        Ast.TY_port _ -> Some (refcount_cell Abi.port_field_refcnt operand)
      | Ast.TY_chan _ -> Some (refcount_cell Abi.chan_field_refcnt operand)
      | Ast.TY_proc -> Some (refcount_cell Abi.proc_field_refcnt operand)
      (* Vecs and strs are pseudo-exterior. *)
      | Ast.TY_vec _ -> Some (exterior_refcount_cell operand)
      | Ast.TY_str -> Some (exterior_refcount_cell operand)
      | _ ->
            if slot.Ast.slot_mode = Ast.MODE_exterior
            then Some (exterior_refcount_cell operand)
            else None

  and drop_rec_entries
      (reg:Il.reg option)
      (off:Asm.expr64)
      (entries:Ast.ty_rec)
      : unit =
    let layouts = layout_rec abi entries in
      Array.iteri
        begin
          fun i (_, (_, layout)) ->
            let (_, sub_slot) = entries.(i) in
            let disp = layout.layout_offset in
            let operand = word_at_reg_off_imm reg off disp in
              match slot_refcount_cell operand sub_slot with
                  None -> ()
                | Some rc ->
                    drop_refcount_and_maybe_free rc operand sub_slot
        end
        layouts

  and drop_tup_slots
      (reg:Il.reg option)
      (off:Asm.expr64)
      (slots:Ast.ty_tup)
      : unit =
    let layouts = layout_tup abi slots in
      Array.iteri
        begin
          fun i layout ->
            let sub_slot = slots.(i) in
            let disp = layout.layout_offset in
            let operand = word_at_reg_off_imm reg off disp in
              match slot_refcount_cell operand sub_slot with
                  None -> ()
                | Some rc ->
                    drop_refcount_and_maybe_free rc operand sub_slot
        end
        layouts


  and drop_refcount_and_maybe_free
      (rc:Il.operand)
      (operand:Il.operand)
      (slot:Ast.slot)
      : unit =
    (iflog (fun _ -> annotate ("drop refcount and maybe free " ^
                                 (Ast.fmt_to_str Ast.fmt_slot slot))));
      emit Il.SUB rc rc one;
      emit Il.CMP Il.Nil rc zero;
      let j = mark () in
        emit Il.JNE Il.Nil badlab Il.Nil;
        begin
            match slot_ty slot with
                Ast.TY_rec entries ->
                  let (reg, off) = get_reg_off operand in
                  let ext_body_off = Asm.ADD (Asm.IMM exterior_body_off, off) in
                    drop_rec_entries reg ext_body_off entries;
                    trans_free operand
              | Ast.TY_tup slots ->
                  let (reg, off) = get_reg_off operand in
                  let ext_body_off = Asm.ADD (Asm.IMM exterior_body_off, off) in
                    drop_tup_slots reg ext_body_off slots;
                    trans_free operand
              | Ast.TY_port _ -> trans_del_port operand;
              | Ast.TY_chan _ -> trans_del_port operand;
              | Ast.TY_proc -> trans_del_proc operand;
              | _ -> trans_free operand
        end;
        patch j;


  and trans_drop_slot
      (operand:Il.operand)
      (slot:Ast.slot)
      : unit =
    match slot_refcount_cell operand slot with
        Some rc ->
          drop_refcount_and_maybe_free rc operand slot
      | _ ->
          begin
            (* FIXME: this will require some reworking if we support
             * rec or tup slots that fit in a vreg. It forces to mem
             * presently. *)
            match slot_ty slot with
                Ast.TY_rec entries ->
                  let (reg, off) = get_reg_off operand in
                    drop_rec_entries reg off entries
              | Ast.TY_tup slots ->
                  let (reg, off) = get_reg_off operand in
                    drop_tup_slots reg off slots
                | _ -> ()
            end


  and init_exterior_slot operand slot =
    iflog (fun _ -> annotate "init exterior: malloc");
    let sz = exterior_allocation_size slot in
      trans_malloc operand sz;
      (* Reload rc; operand changed underfoot. *)
      iflog (fun _ -> annotate "init exterior: reload refcount");
      let rc = exterior_refcount_cell operand in
        mov rc one

  and intent_str i =
    match i with
        INTENT_init -> "init"
      | INTENT_write -> "write"
      | INTENT_read -> "read"
      | INTENT_drop -> "drop"

  and deref_exterior intent operand slot =
    iflog (fun _ -> annotate ("deref exterior: " ^
                                (intent_str intent) ^ ", " ^
                                (Il.string_of_operand
                                   abi.Abi.abi_str_of_hardreg operand)));
      match intent with
          INTENT_init ->
            init_exterior_slot operand slot;
            deref_imm operand exterior_body_off

        | INTENT_write ->
            let rc = exterior_refcount_cell operand in
              emit Il.CMP Il.Nil rc one;
              let j = mark () in
                emit Il.JE Il.Nil badlab Il.Nil;
                (* 
                 * Calling trans_copy_slot_heavy in 'initializing' mode 
                 * will init the slot for us. Don't double-init.
                 *)
                iflog (fun _ -> annotate ("deref exterior: write: heavy-copy referent"));
                let tmp = Il.Reg (Il.next_vreg (emitter())) in
                  trans_copy_slot_heavy true tmp slot operand slot;
                  drop_refcount_and_maybe_free rc operand slot;
                  mov operand tmp;
                  patch j;
                  deref_imm operand exterior_body_off

        | INTENT_read ->
            deref_imm operand exterior_body_off

        | INTENT_drop ->
            let rc = exterior_refcount_cell operand in
            drop_refcount_and_maybe_free rc operand slot;
            Il.Nil

  and deref_slot (operand:Il.operand) (slot:Ast.slot) (intent:intent) : Il.operand =
    match slot.Ast.slot_mode with
        Ast.MODE_interior -> operand
      | Ast.MODE_exterior -> deref_exterior intent operand slot
      | Ast.MODE_read_alias
      | Ast.MODE_write_alias ->
          match intent with
              INTENT_init -> operand
            | _ -> deref operand


  and trans_copy_rec
      (initializing:bool)
      (dst_reg:Il.reg option) (dst_off:Asm.expr64) (dst_entries:Ast.ty_rec)
      (src_reg:Il.reg option) (src_off:Asm.expr64) (src_entries:Ast.ty_rec)
      : unit =
    let layouts = layout_rec abi dst_entries in
      Array.iteri
        begin
          fun i (_, (_, layout)) ->
            let disp = layout.layout_offset in
            let sub_dst = word_at_reg_off_imm dst_reg dst_off disp in
            let sub_src = word_at_reg_off_imm src_reg src_off disp in
            let (_, sub_dst_slot) = dst_entries.(i) in
            let (_, sub_src_slot) = src_entries.(i) in
              trans_copy_slot
                initializing
                sub_dst sub_dst_slot
                sub_src sub_src_slot
        end
        layouts


  and trans_copy_tup
      (initializing:bool)
      (dst_reg:Il.reg option) (dst_off:Asm.expr64) (dst_slots:Ast.ty_tup)
      (src_reg:Il.reg option) (src_off:Asm.expr64) (src_slots:Ast.ty_tup)
      : unit =
    let layouts = layout_tup abi dst_slots in
      Array.iteri
        begin
          fun i layout ->
            let disp = layout.layout_offset in
            let sub_src = word_at_reg_off_imm src_reg src_off disp in
            let sub_dst = word_at_reg_off_imm dst_reg dst_off disp in
              trans_copy_slot
                initializing
                sub_dst dst_slots.(i)
                sub_src src_slots.(i)
        end
        layouts

  and trans_copy_slot
      (initializing:bool)
      (dst:Il.operand) (dst_slot:Ast.slot)
      (src:Il.operand) (src_slot:Ast.slot)
      : unit =
    let anno (weight:string) : unit =
      iflog
        begin
          fun _ ->
            annotate
              (Printf.sprintf "%sweight copy: %a <- %a"
                 weight
                 Ast.sprintf_slot dst_slot
                 Ast.sprintf_slot src_slot)
        end;
    in
    assert (slot_ty src_slot = slot_ty dst_slot);
    match (slot_refcount_cell src src_slot,
           slot_refcount_cell dst dst_slot) with
      | (Some src_rc, Some dst_rc)  ->
          (* Lightweight copy: twiddle refcounts, move pointer. *)
          anno "light";
          emit Il.ADD src_rc src_rc one;
          if not initializing
          then
            drop_refcount_and_maybe_free
              dst_rc dst dst_slot;
          mov dst src

      | _ ->
          (* Heavyweight copy: duplicate the referent. *)
          anno "heavy";
          trans_copy_slot_heavy initializing
            dst dst_slot src src_slot

  (* NB: heavyweight copying here does not mean "producing a deep
   * clone of the entire data tree rooted at the src operand". It means
   * "replicating a single level of the tree". You usually only need to
   * heavyweight copy if you're preparing to write to a sub-component
   * of an lval with refcount > 1.
   * 
   * If you're dereferencing a path x.y.z in order to write to the z
   * component, you may have to make 0..2 heavyweight copies:
   * 
   *   - let x' = if x.rc > 1 then heavy_copy(x) else x
   *   - let y' = if x'.y.rc > 1 then heavy_copy(x'.y) else x'.y
   *   - let z' = if y'.z.rc > 1 then heavy_copy(y'.z) else y'.z
   * 
   * There is no general-recursion entailed in performing a heavy
   * copy. There is only "one level" to each heavy copy call.
   * 
   * In other words, this is a lightweight copy:
   * 
   *    [dstptr]  <-copy-  [srcptr]
   *         \              |
   *          \             |
   *        [some record.rc++]
   *             |
   *           [some other record]
   * 
   * Whereas this is a heavyweight copy:
   * 
   *    [dstptr]  <-copy-  [srcptr]
   *       |                  |
   *       |                  |
   *  [some record]       [some record]
   *             |          |
   *           [some other record]
   * 
   *)

  and trans_copy_slot_heavy
      (initializing:bool)
      (dst:Il.operand) (dst_slot:Ast.slot)
      (src:Il.operand) (src_slot:Ast.slot)
      : unit =
    assert (slot_ty src_slot = slot_ty dst_slot);
    let dst_intent =
      if initializing
      then INTENT_init
      else INTENT_write
    in
    let dst = deref_slot dst dst_slot dst_intent in
    let src = deref_slot src src_slot INTENT_read in
      match (dst, dst_slot.Ast.slot_ty,
             src, src_slot.Ast.slot_ty) with
          (Il.Mem (_, dst_reg, dst_off), Some (Ast.TY_rec dst_entries),
           Il.Mem (_, src_reg, src_off), Some (Ast.TY_rec src_entries)) ->
            trans_copy_rec
              initializing
              dst_reg dst_off dst_entries
              src_reg src_off src_entries

        | (Il.Mem (_, dst_reg, dst_off), Some (Ast.TY_tup dst_slots),
           Il.Mem (_, src_reg, src_off), Some (Ast.TY_tup src_slots)) ->
            trans_copy_tup
              initializing
              dst_reg dst_off dst_slots
              src_reg src_off src_slots

        | _ ->
            mov dst src


  and trans_copy
      (initializing:bool)
      (dst:Ast.lval)
      (src:Ast.expr) : unit =
    let dst_intent =
      if initializing
      then INTENT_init
      else INTENT_write
    in
    match src with
        (Ast.EXPR_binary _)
      | (Ast.EXPR_unary _)
      | (Ast.EXPR_atom (Ast.ATOM_literal _)) ->
          (* 
           * Translations of these expr types yield vregs, 
           * so copy is just MOV into the lval. 
           *)
          let (dst_operand, dst_slot) = trans_lval dst dst_intent in
          let src_operand = trans_expr src in
            mov (deref_slot dst_operand dst_slot INTENT_read) src_operand

      | Ast.EXPR_atom (Ast.ATOM_lval src_lval) ->
          (* Possibly-large structure copying *)
          let (dst_operand, dst_slot) = trans_lval dst dst_intent in
          let (src_operand, src_slot) = trans_lval src_lval INTENT_read in
            trans_copy_slot
              initializing
              dst_operand dst_slot
              src_operand src_slot


  and trans_init_slot_from_atom
      (dst:Il.operand) (dst_slot:Ast.slot)
      (atom:Ast.atom)
      : unit =
    match atom with
      | (Ast.ATOM_literal _) ->
          let src = trans_atom atom in
            begin
              match dst_slot.Ast.slot_mode with
                  Ast.MODE_read_alias
                | Ast.MODE_write_alias -> mov dst (alias (force_to_mem src))
                | _ -> mov (deref_slot dst dst_slot INTENT_init) src
            end
      | Ast.ATOM_lval src_lval ->
          let (src, src_slot) = trans_lval src_lval INTENT_read in
            trans_init_slot dst dst_slot src src_slot


  and trans_init_slot
      (dst:Il.operand) (dst_slot:Ast.slot)
      (src:Il.operand) (src_slot:Ast.slot)
      : unit =
    assert (slot_ty src_slot = slot_ty dst_slot);
    match dst_slot.Ast.slot_mode with
        Ast.MODE_read_alias
      | Ast.MODE_write_alias -> mov dst (alias src)
      | _ ->
          trans_copy_slot
            true
            dst dst_slot
            src src_slot

  and trans_call_fn
        (dst:Ast.lval)
        (flv:Ast.lval)
        (args:Ast.atom array)
        : unit =
    let (dst_operand, _) = trans_lval dst INTENT_write in
    let (fn_operand, fn_slot) =
      trans_lval_full flv
        abi.Abi.abi_has_pcrel_jumps
        abi.Abi.abi_has_imm_jumps
        INTENT_read
    in
    let tfn =
      match slot_ty fn_slot with
          Ast.TY_fn fty -> fty
        | _ -> err None "Calling non-function."
    in
    let (tsig, _) = tfn in
    let in_slots = tsig.Ast.sig_input_slots in
    let arg_layouts = layout_fn_call_tup abi tsig in
      trans_call (fun _ -> Ast.sprintf_lval () flv)
        dst_operand fn_operand in_slots arg_layouts None args

  and trans_arg0 param_operand output_operand =
    (* Emit arg0 of any call: the output slot. *)
    trans_init_slot
      param_operand (word_write_alias_slot abi)
      output_operand (word_slot abi)

  and trans_arg1 param_operand =
    (* Emit arg1 or any call: the process pointer. *)
    trans_init_slot
      param_operand (word_slot abi)
      abi.Abi.abi_pp_operand (word_slot abi)

  and trans_argN n param_operand slots args =
    trans_init_slot_from_atom
      param_operand slots.(n)
      args.(n)

  and trans_call
      (logname:(unit -> string))
      (output_operand:Il.operand)
      (callee_operand:Il.operand)
      (in_slots:Ast.slot array)
      (arg_layouts:layout array)
      (arg2:Il.operand option)
      (args:Ast.atom array)
      : unit =
    (* FIXME: there's got to be a nicer factoring than this. *)
    let implicit_args =
      match arg2 with
          None ->
            begin
              let n_layouts = Array.length arg_layouts in
                assert (n_layouts == ((Array.length args) + 2));
                for i = 0 to n_layouts - 1 do
                  iflog (fun _ ->
                           annotate (Printf.sprintf "fn-call arg %d of %d"
                                       i n_layouts));
                  let param_operand = sp_imm arg_layouts.(i).layout_offset in
                    match i with
                        0 -> trans_arg0 param_operand output_operand
                      | 1 -> trans_arg1 param_operand
                      | _ -> trans_argN (i-2) param_operand in_slots args
                done;
                2;
            end
        | Some arg2_operand ->
            begin
              let n_layouts = Array.length arg_layouts in
                assert (n_layouts == ((Array.length args) + 3));
                for i = 0 to n_layouts - 1 do
                  iflog (fun _ ->
                           annotate (Printf.sprintf "init-call arg %d of %d"
                                       i n_layouts));
                  let param_operand = sp_imm arg_layouts.(i).layout_offset in
                    match i with
                        0 -> trans_arg0 param_operand output_operand
                      | 1 -> trans_arg1 param_operand
                      | 2 -> mov param_operand arg2_operand
                      | _ -> trans_argN (i-3) param_operand in_slots args
                done
            end;
            3
    in
      iflog (fun _ -> annotate (Printf.sprintf "call %s" (logname ())));
      let vr = Il.Reg (Il.next_vreg (emitter())) in
        emit Il.CCALL vr callee_operand Il.Nil;
        for i = implicit_args to arr_max arg_layouts do
          let operand = sp_imm arg_layouts.(i).layout_offset in
            iflog (fun _ -> annotate (Printf.sprintf "drop arg %d" i));
            trans_drop_slot operand in_slots.(i-implicit_args)
        done


  and trans_stmt (stmt:Ast.stmt) : unit =
    (* Helper to localize errors by stmt, at minimum. *)
    try
      iflog
        begin
          fun _ ->
            annotate (Ast.fmt_to_str Ast.fmt_stmt_body stmt)
        end;
      curr_stmt := Some stmt.id;
      trans_stmt_full stmt;
      curr_stmt := None
    with
        Semant_err (None, msg) -> raise (Semant_err ((Some stmt.id), msg))


  and trans_stmt_full (stmt:Ast.stmt) : unit =
    match stmt.node with

        Ast.STMT_log a ->
          begin
            match atom_type a with
                Ast.TY_str -> trans_log_str a
              | Ast.TY_int -> trans_log_int a
              | _ -> err (Some stmt.id) "unimplemented logging type"
          end

      | Ast.STMT_check_expr e ->
          begin
            match expr_type e with
                Ast.TY_bool -> trans_check_expr e
              | _ -> err (Some stmt.id) "check expr on non-bool"
          end

      | Ast.STMT_spawn (dst, plv, args) -> trans_spawn dst plv args
      | Ast.STMT_send (chan,src) -> trans_send chan src
      | Ast.STMT_recv (dst,chan) -> trans_recv dst chan

      | Ast.STMT_copy (lv_dst, e_src) ->
          if Hashtbl.mem cx.ctxt_copy_stmt_is_init stmt.id
          then
            begin
              iflog
                (fun _ ->
                   annotate
                     (Printf.sprintf "initializing-copy on dst lval %a"
                        Ast.sprintf_lval lv_dst));
              trans_copy true lv_dst e_src
            end
          else
              trans_copy false lv_dst e_src

      | Ast.STMT_init_rec (dst, atab) ->
          Array.iter
            begin
              fun (ident, atom) ->
                let lval = (Ast.LVAL_ext
                              (dst, (Ast.COMP_named
                                       (Ast.COMP_ident ident))))
                in
                let expr = Ast.EXPR_atom atom in
                  trans_copy true lval expr
            end
            atab

      | Ast.STMT_init_tup (dst, atoms) ->
          Array.iteri
            begin
              fun i atom ->
                let lval = (Ast.LVAL_ext
                              (dst, (Ast.COMP_named
                                       (Ast.COMP_idx i))))
                in
                let expr = Ast.EXPR_atom atom in
                  trans_copy true lval expr
            end
            atoms

      | Ast.STMT_init_str (dst, s) ->
          trans_init_str dst s

      | Ast.STMT_init_vec (dst, atoms) ->
          trans_init_vec dst atoms

      | Ast.STMT_init_port dst ->
          trans_init_port dst

      | Ast.STMT_init_chan (dst, port) ->
          let (dst_operand, dst_slot) =
            trans_lval dst INTENT_init
          in
          let src_operand =
            match port with
                None -> imm_false
              | Some p ->
                  let (oper, _) = trans_lval p INTENT_read in
                    oper
          in
          let src_slot = interior_slot (slot_ty dst_slot) in
            trans_copy_slot true
              dst_operand dst_slot
              src_operand src_slot

      | Ast.STMT_block block ->
          trans_block block

      | Ast.STMT_while sw ->
          let (head_stmts, head_expr) = sw.Ast.while_lval in
          let fwd_jmp = mark () in
            emit Il.JMP Il.Nil badlab Il.Nil;
            let block_begin = mark () in
              trans_block sw.Ast.while_body;
              patch fwd_jmp;
              Array.iter trans_stmt head_stmts;
              let back_jmps = trans_cond false head_expr in
                List.iter (fun j -> patch_existing j block_begin) back_jmps;

      | Ast.STMT_if si ->
          let skip_thn_jmps = trans_cond true si.Ast.if_test in
            trans_block si.Ast.if_then;
            begin
              match si.Ast.if_else with
                  None -> List.iter patch skip_thn_jmps
                | Some els ->
                    let skip_els_jmp = mark () in
                      begin
                        emit Il.JMP Il.Nil badlab Il.Nil;
                        List.iter patch skip_thn_jmps;
                        trans_block els;
                        patch skip_els_jmp
                      end
            end

      | Ast.STMT_check _ -> ()

      | Ast.STMT_call (dst, flv, args) -> trans_call_fn dst flv args

      | Ast.STMT_ret (proto_opt, atom_opt) ->
          begin
          match proto_opt with
              None ->
                begin
                  begin
                    match atom_opt with
                        None -> ()
                      | Some at ->
                          let disp = abi.Abi.abi_frame_base_sz in
                          let dst = deref (fp_imm disp) in
                          let src = trans_atom at in
                            mov dst src
                  end;
                  Stack.push (mark()) (Stack.top epilogue_jumps);
                end;
                emit Il.JMP Il.Nil badlab Il.Nil
            | Some _ -> ()
          end

      | Ast.STMT_decl _ -> ()

      | _ -> err (Some stmt.id) "unhandled form of statement in trans_stmt"
  in

  let capture_emitted_quads (node:node_id) : unit =
    let e = emitter() in
    let n_vregs = e.Il.emit_next_vreg in
    let quads = e.Il.emit_quads in
    let name = path_name () in
    let f = match !curr_file with
        None -> err (Some node) "Missing file scope when capturing quads."
      | Some f -> f
    in
    let file_list = Hashtbl.find cx.ctxt_texts f in
      begin
        iflog
          begin
            fun _ ->
              log cx "emitted quads for %s:" name;
              for i = 0 to arr_max quads
              do
                if Hashtbl.mem annotations i
                then
                  List.iter
                    (fun a -> log cx "// %s" a)
                    (List.rev (Hashtbl.find_all annotations i));
                log cx "[%6d]\t%s" i (Il.string_of_quad abi.Abi.abi_str_of_hardreg quads.(i));
                done;
          end;
        let text = { text_node = node;
                     text_quads = quads;
                     text_n_vregs = n_vregs }
        in
          file_list := text :: (!file_list)
      end;
      Hashtbl.clear annotations
  in

  let trans_frame_entry (fnid:node_id) : unit =
    let argsz = 0L in
    let framesz = get_framesz cx fnid in
    let callsz = get_callsz cx fnid in
    let spill_fixup = Hashtbl.find cx.ctxt_spill_fixups fnid in
      Stack.push (Stack.create()) epilogue_jumps;
      push_new_emitter ();
      abi.Abi.abi_emit_fn_prologue (emitter()) argsz framesz spill_fixup callsz;
  in

  let trans_frame_exit (fnid:node_id) : unit =
    Stack.iter patch (Stack.pop epilogue_jumps);
    abi.Abi.abi_emit_fn_epilogue (emitter());
    capture_emitted_quads fnid;
    pop_emitter ()
  in

  let trans_fn (fnid:node_id) (body:Ast.block) : unit =
    trans_frame_entry fnid;
    trans_block body;
    trans_frame_exit fnid;
  in

  let trans_tag
      (n:Ast.ident) 
      (tagid:node_id)
      (tag:(Ast.ty_tup * Ast.ty_tag))
      : unit =
    trans_frame_entry tagid;
    let (ttup, ttag) = tag in
    let tag_keys = Array.make (Hashtbl.length ttag) "" in
    let i = ref 0 in
      begin
        Hashtbl.iter (fun k _ -> tag_keys.(!i) <- k; incr i) ttag;
        i := -1;
        Array.sort compare tag_keys;
        for j = 0 to arr_max tag_keys do
          if tag_keys.(j) = n
          then i := j
        done;
        if (!i) = -1
        then err (Some tagid) "error sorting tag";
      end;
      let _ = log cx "tag variant: %s -> tag value #%d" n (!i) in
      let disp = abi.Abi.abi_frame_base_sz in
      let dst = deref (fp_imm disp) in
        (* A clever compiler will inline this. We are not clever. *)
        mov dst (imm (Int64.of_int (!i)));
        (* FIXME: tuple contents after tag number. *)
        trans_frame_exit tagid;
  in

  let trans_native_fn (fnid:node_id) (tsig:Ast.ty_sig) : unit =
    let ret_addr_disp = abi.Abi.abi_frame_base_sz in
    let arg0_disp = Int64.add abi.Abi.abi_frame_base_sz abi.Abi.abi_implicit_args_sz in

    trans_frame_entry fnid;
    (* 
     * Native upcall encoding:
     * 
     * arg0 = symbol name
     * arg1 = return pointer (dereferenced return-address slot)
     * arg2 = address of 0th non-implicit arg slot
     * arg3 = arg count
     *)
    trans_upcall Abi.UPCALL_native
      [|
        (trans_static_string (name()));
        (fp_imm ret_addr_disp);
        (alias (fp_imm arg0_disp));
        imm (Int64.of_int (Array.length tsig.Ast.sig_input_slots))
      |];
    trans_frame_exit fnid;
  in

  let trans_prog_block (b:Ast.block) (ncomp:string) : fixup =
    let _ = Stack.push ncomp path in
    let fix = new_fixup (path_name ()) in
    let framesz = get_framesz cx b.id in
    let callsz = get_callsz cx b.id in
    let spill_fixup = Hashtbl.find cx.ctxt_spill_fixups b.id in
      push_new_emitter ();
      let dst = Il.Reg (Il.next_vreg (emitter())) in
        Il.emit_full (emitter()) (Some fix) Il.DEAD Il.Nil Il.Nil Il.Nil;
        abi.Abi.abi_emit_main_prologue (emitter()) b framesz spill_fixup callsz;
        trans_block b;
        abi.Abi.abi_emit_proc_state_change (emitter()) Abi.STATE_blocked_exited;
        emit Il.CCALL dst (Il.Pcrel cx.ctxt_proc_to_c_fixup) Il.Nil;
        capture_emitted_quads b.id;
        pop_emitter ();
        ignore (Stack.pop path);
        fix
  in

  let trans_prog (progid:node_id) (p:Ast.prog) : unit =
    let _ = log cx "translating program: %s" (path_name()) in
    let init =
      match p.Ast.prog_init with
          None -> Asm.IMM 0L
        | Some init ->
            begin
              let _ = Stack.push "init" path in
                trans_fn init.id init.node.Ast.init_body;
                ignore (Stack.pop path);
                Asm.M_POS (get_fn_fixup cx init.id)
            end
    in
    let main =
      match p.Ast.prog_main with
          None -> Asm.IMM 0L
        | Some main -> Asm.M_POS (trans_prog_block main "main")
    in
    let fini =
      match p.Ast.prog_fini with
          None -> Asm.IMM 0L
        | Some fini -> Asm.M_POS (trans_prog_block fini "fini")
    in
    let prog =
      let fixup = get_prog_fixup cx progid in
      (* FIXME: extract prog layout from ABI. *)
      Asm.DEF (fixup,
               Asm.SEQ [| Asm.WORD (TY_u32, init);
                          Asm.WORD (TY_u32, main);
                          Asm.WORD (TY_u32, fini) |])
    in
      cx.ctxt_data_items <- prog :: cx.ctxt_data_items
  in

  let rec trans_mod_item
      (n:Ast.ident)
      (item:Ast.mod_item)
      : unit =
    begin
      match item.node with
          Ast.MOD_ITEM_fn f -> trans_fn item.id f.Ast.decl_item.Ast.fn_body
        | Ast.MOD_ITEM_prog p -> trans_prog item.id p.Ast.decl_item
        | Ast.MOD_ITEM_tag t -> trans_tag n item.id t.Ast.decl_item
        | _ -> ()
    end
  in

  let rec trans_native_mod_item
      (item:Ast.native_mod_item)
      : unit =
    begin
      match item.node with
          Ast.NATIVE_fn tsig -> trans_native_fn item.id tsig
        | _ -> ()
    end
  in

  let enter_file_for i =
    if Hashtbl.mem cx.ctxt_item_files i.id
    then begin
      match !curr_file with
          None -> curr_file := Some i.id
        | Some _ -> err (Some i.id) "Existing source file on file-scope entry."
    end
  in

  let leave_file_for i =
    if Hashtbl.mem cx.ctxt_item_files i.id
    then begin
      match !curr_file with
          None -> err (Some i.id) "Missing source file on file-scope exit."
        | Some _ -> curr_file := None
    end
  in

  let visit_mod_item_pre n p i =
    enter_file_for i;
    Stack.push n path;
    trans_mod_item n i;
    inner.Walk.visit_mod_item_pre n p i
  in
  let visit_mod_item_post n p i =
    inner.Walk.visit_mod_item_post n p i;
    ignore (Stack.pop path);
    leave_file_for i
  in

  let visit_native_mod_item_pre n i =
    enter_file_for i;
    Stack.push n path;
    trans_native_mod_item i;
    inner.Walk.visit_native_mod_item_pre n i
  in

  let visit_native_mod_item_post n i =
    inner.Walk.visit_native_mod_item_post n i;
    ignore (Stack.pop path);
    leave_file_for i
  in

    { inner with
        Walk.visit_mod_item_pre = visit_mod_item_pre;
        Walk.visit_mod_item_post = visit_mod_item_post;
        Walk.visit_native_mod_item_pre = visit_native_mod_item_pre;
        Walk.visit_native_mod_item_post = visit_native_mod_item_post
    }
;;


let fixup_assigning_visitor
    (cx:ctxt)
    (inner:Walk.visitor)
    : Walk.visitor =

  let path = Stack.create () in

  let path_name (_:unit) : string =
    String.concat "." (stk_elts_from_bot path)
  in

  let enter_file_for i =
    if Hashtbl.mem cx.ctxt_item_files i.id
    then
      begin
        htab_put cx.ctxt_file_fixups i.id (new_fixup (path_name()));
        if not (Hashtbl.mem cx.ctxt_texts i.id)
        then htab_put cx.ctxt_texts i.id (ref []);
      end
  in

  let visit_mod_item_pre n p i =
    Stack.push n path;
    enter_file_for i;
    begin
      match i.node with
          Ast.MOD_ITEM_fn _ ->
            htab_put cx.ctxt_fn_fixups i.id (new_fixup (path_name()))
        | Ast.MOD_ITEM_tag tag ->
            htab_put cx.ctxt_tag_fixups i.id (new_fixup (path_name()))
        | Ast.MOD_ITEM_prog prog ->
            begin
              let path = path_name() in
              let prog_fixup =
                if path = cx.ctxt_main_name
                then cx.ctxt_main_prog
                else (new_fixup path)
              in
                log cx "defining '%s' to mod item '%s'" prog_fixup.fixup_name (path_name());
                htab_put cx.ctxt_prog_fixups i.id prog_fixup;
                match prog.Ast.decl_item.Ast.prog_init with
                    None -> ()
                  | Some init ->
                      begin
                        (* Treat an init like a fn for purposes of code generation. *)
                        htab_put cx.ctxt_fn_fixups init.id
                          (new_fixup ((path_name()) ^ ".init"))
                      end
            end
        | _ -> ()
    end;
    inner.Walk.visit_mod_item_pre n p i
  in

  let visit_native_mod_item_pre n i =
    Stack.push n path;
    enter_file_for i;
    begin
      match i.node with
          Ast.NATIVE_fn _ ->
            htab_put cx.ctxt_fn_fixups i.id (new_fixup (path_name()))
        | _ -> ()
    end;
    inner.Walk.visit_native_mod_item_pre n i
  in

  let visit_mod_item_post n p i =
    inner.Walk.visit_mod_item_post n p i;
    ignore (Stack.pop path)
  in

  let visit_native_mod_item_post n i =
    inner.Walk.visit_native_mod_item_post n i;
    ignore (Stack.pop path)
  in
  { inner with
        Walk.visit_mod_item_pre = visit_mod_item_pre;
        Walk.visit_mod_item_post = visit_mod_item_post;
        Walk.visit_native_mod_item_pre = visit_native_mod_item_pre;
        Walk.visit_native_mod_item_post = visit_native_mod_item_post }

let emit_c_to_proc_glue cx =
  let e = Il.new_emitter
    cx.ctxt_abi.Abi.abi_prealloc_quad
    cx.ctxt_abi.Abi.abi_is_2addr_machine
  in
    cx.ctxt_abi.Abi.abi_c_to_proc e cx.ctxt_c_to_proc_fixup;
    if e.Il.emit_next_vreg != 0
    then err None "c-to-proc glue uses nonzero vregs"
    else cx.ctxt_anon_text_quads <-
      (e.Il.emit_quads) :: cx.ctxt_anon_text_quads
;;


let emit_proc_to_c_glue cx =
  let e = Il.new_emitter
    cx.ctxt_abi.Abi.abi_prealloc_quad
    cx.ctxt_abi.Abi.abi_is_2addr_machine
  in
    cx.ctxt_abi.Abi.abi_proc_to_c e cx.ctxt_proc_to_c_fixup;
    if e.Il.emit_next_vreg != 0
    then err None "proc-to-c glue uses nonzero vregs"
    else cx.ctxt_anon_text_quads <-
      (e.Il.emit_quads) :: cx.ctxt_anon_text_quads
;;

let trans_crate
    (cx:ctxt)
    (crate:Ast.crate)
    : (file_grouped_texts * Asm.item list * fixup) =
  let passes =
    [|
      (fixup_assigning_visitor cx
         Walk.empty_visitor);
      (trans_visitor cx
         Walk.empty_visitor)
    |];
  in
    log cx "translating crate with main program %s" cx.ctxt_main_name;
    run_passes cx passes (log cx "%s") crate;
    emit_c_to_proc_glue cx;
    emit_proc_to_c_glue cx;
    (cx.ctxt_texts, cx.ctxt_data_items, cx.ctxt_main_prog)
;;

(*
 * Local Variables:
 * fill-column: 70;
 * indent-tabs-mode: nil
 * buffer-file-coding-system: utf-8-unix
 * compile-command: "make -k -C ../.. 2>&1 | sed -e 's/\\/x\\//x:\\//g'";
 * End:
 *)
