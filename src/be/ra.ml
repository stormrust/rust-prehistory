open Il;;
open Common;;

type ctxt = 
	{ 
      ctxt_sess: Session.sess; 
      ctxt_n_vregs: int;
      ctxt_n_hardregs: int;
      mutable ctxt_quads: Il.quads;
	  mutable ctxt_next_spill: int;      
      (* More state as necessary. *)
    }
;;

let	new_ctxt sess quads vregs hardregs = 
  { 
    ctxt_sess = sess;
    ctxt_quads = quads;
    ctxt_n_vregs = vregs;
    ctxt_n_hardregs = hardregs;
    ctxt_next_spill = 0
  }
;;

let log cx = Session.log "ra" 
  cx.ctxt_sess.Session.sess_log_ra
  cx.ctxt_sess.Session.sess_log_out
;;

let next_spill cx = 
  let i = cx.ctxt_next_spill in
    cx.ctxt_next_spill <- i + 1;
    i
;;

exception Ra_error of string ;;

(* Poletto and Sarkar's linear-scan algorithm. *)

type live_interval = { live_vreg: int;
					   live_operand: operand;
					   live_startpoint: int;
					   live_endpoint: int; }

let string_of_live_interval li = 
  Printf.sprintf "vreg %d = %s : [%d,%d]" 
    li.live_vreg 
    (string_of_operand li.live_operand)
    li.live_startpoint
    li.live_endpoint
;;


module StartOrderedIntervals = 
struct
  type t = live_interval
  let compare x y = 
    if x.live_startpoint = y.live_startpoint
    then compare x.live_vreg y.live_vreg
    else compare x.live_startpoint y.live_startpoint
end
;;

module EndOrderedIntervals = 
struct
  type t = live_interval
  let compare x y = 
    if x.live_endpoint = y.live_endpoint
    then compare x.live_vreg y.live_vreg
    else compare x.live_endpoint y.live_endpoint
end
;;

module OrderedInts = 
struct
  type t = int
  let compare x y = compare x y
end
;;

(* Live Intervals *)
module LI = Set.Make(StartOrderedIntervals);;

(* Active Intervals *)
module AI = Set.Make(EndOrderedIntervals);;

(* Hard Registers *)
module HR = Set.Make(OrderedInts);;

let log_live_intervals cx is = 
  LI.iter (fun i -> log cx "%s" (string_of_live_interval i)) is
;;

let convert_labels cx = 
  let new_labels = ref [] in 
  let convert_operand s = 
    match s with 
        Label lab -> 
          let fix = (match cx.ctxt_quads.(lab).quad_fixup with 
                         None -> ( let fix = new_fixup ("quad#" ^ (string_of_int lab)) in
                                     new_labels := (lab, fix) :: (!new_labels);
                                     fix)
                       | Some f -> f)
          in
            Pcrel fix
      | x -> x
  in
  let convert_quad q = 
    { q with 
		quad_dst = convert_operand q.quad_dst;
		quad_lhs = convert_operand q.quad_lhs;
		quad_rhs = convert_operand q.quad_rhs }
  in
    cx.ctxt_quads <- Array.map convert_quad cx.ctxt_quads;
    List.iter (fun (i, fix) -> 
                 cx.ctxt_quads.(i) <- { cx.ctxt_quads.(i) 
                                       with quad_fixup = Some fix })
      (!new_labels)
;;

let kill_quad i cx =
  cx.ctxt_quads.(i) <- 
    { deadq with Il.quad_fixup = cx.ctxt_quads.(i).Il.quad_fixup }
;;

let convert_vregs intervals cx =
  let vreg_operands = Array.create cx.ctxt_n_vregs Nil in
  let spill_reg_1 = (HWreg X86.edx) in
  let spill_reg_2 = (HWreg X86.edi) in
  let spill_slot i = Mem (M32, Some (HWreg X86.ebp), (Asm.IMM (Int64.of_int (i*4)))) in
  let mov a b = { quad_op = MOV; 
                  quad_dst = a;
                  quad_lhs = b;
                  quad_rhs = Nil;
                  quad_fixup = None }
  in
    (* 
  let nop = { quad_op = NOP; 
              quad_dst = Nil;
              quad_lhs = Nil;
              quad_rhs = Nil;
              quad_fixup = None }
  in
    *)
  let convert_operand s spill_reg = 
    match s with 
		Reg (Vreg i) -> 
          (match vreg_operands.(i) with 
               Reg (HWreg r) -> (None, Reg (HWreg r))
             | Spill i -> (Some i, Reg spill_reg)
             | x -> raise (Ra_error ("Ra.convert_vregs 1: vreg:" 
                                             ^ (string_of_int i) ^ " = " 
                                             ^ (Il.string_of_operand x))))
	  | Mem (m, Some (Vreg i), off) -> 
          (match vreg_operands.(i) with 
               Reg (HWreg r) -> (None, Mem (m, Some (HWreg r), off))
             | Spill i -> 
                 (Some i, Mem (m, Some spill_reg, off))
             | x -> raise (Ra_error ("Ra.convert_vregs 2: " ^ (Il.string_of_operand x))))
      | _ -> (None, s)
  in
  let quads = ref [] in 
  let prepend q = quads := q :: (!quads) in
  let convert_quad q = 

    (* 
     * Some notes on spills (x86-specific):
     * 
     *   #1 A quad has at most 2 distinct operands (x86, fact)
     *   #2 A quad has at most 1 distinct *memory* operand (x86, fact)
     *   #3 A spill reg might be used as a base reg in a memory operand
     *   #4 The RA might have assigned a spill slot to both distinct operands
     * 
     *  So: we need 2 spill regs. Oh well. I guess other IRs get around this by
     *  not permitting memory ops in most non-load / non-store quads?
    *)
    (* prepend nop; *)
    let prepend_any_load spill = 
      match spill with 
          None -> ()
        | Some i -> prepend (mov (Reg (spill_reg_1)) (spill_slot i))
    in
    let prepend_any_store spill = 
      match spill with 
          None -> ()
        | Some i -> prepend (mov (spill_slot i) (Reg (spill_reg_1)))
    in
    let (spilled_dst, dst) = convert_operand q.quad_dst spill_reg_1 in
    let (spilled_lhs, lhs) = convert_operand q.quad_lhs spill_reg_1 in
    let (spilled_rhs, rhs) = convert_operand q.quad_rhs spill_reg_2 in
    let q' = { q with quad_dst = dst; quad_lhs = lhs; quad_rhs = rhs } in
      prepend_any_load spilled_lhs;
      prepend_any_load spilled_rhs;
      prepend q';
      prepend_any_store spilled_dst
  in
  let convert_dead_quad i q = 
    match q.quad_dst with 
		Reg (Vreg j) -> 
          (match vreg_operands.(j) with 
               Il.Nil -> kill_quad i cx
             | _ -> ())
      | _ -> ()
  in
    LI.iter (fun i -> vreg_operands.(i.live_vreg) <- i.live_operand) intervals;
    Array.iteri convert_dead_quad cx.ctxt_quads;
    Array.iter convert_quad cx.ctxt_quads;
    cx.ctxt_quads <- Array.of_list (List.rev (!quads));
;;


let kill_redundant_moves cx =
  for i = 0 to (Array.length cx.ctxt_quads) -1
  do
	let q = cx.ctxt_quads.(i) in
      match q.quad_op with 
          MOV -> 
            if q.quad_dst = q.quad_lhs
            then kill_quad i cx
        | _ -> ()
  done
;;


(* 
 * On some ISAs we have hard register constraints. An example of this is 
 * on x86, where we have MUL placing its result in (EDX,EAX) no matter
 * what. 
 * 
 * In this case, when we have a quad of the form 
 * 
 *   i: (MUL,vreg dst, vreg a, vreg b) 
 * 
 * we have an ISA-specific "constraint" rule that replaces it with the following, 
 * pushing our quad numbers down by 1:
 * 
 *   i  : (MUL, [vreg x, vreg y], vreg a, vreg b)
 *   i+1: (MOV, [vreg dst], vreg x)
 *   i+2: (MOV, [vreg dst], vreg y)
 * 
 * and we insert a 2 fresh live intervals for fresh vregs x and y
 * 
 *    { live_vreg: x; 
 *      live_operand: Fixed (HWreg EDX); 
 *      live_startpoint: i;
 *      live_endpoint: i+1; }
 * 
 *    { live_vreg: y; 
 *      live_operand: Fixed (HWreg EAX); 
 *      live_startpoint: i;
 *      live_endpoint: i+2; }
 * 
 * Constraint rules must be careful not to insert unsatisfiable quads. This 
 * example will cause any live interval allocated to EAX or EDX to be 
 * reassigned to a spill operand; if any of those spilled intervals happened to 
 * be Fixed() to some other HWregs, the spill be unsatisfiable.
 * 
 * 
 *)

let quad_jump_target_labels q = 
  let operand_jump_target_labels s = 
    match s with 
		Label i -> [i]
      | _ -> []
  in
    List.concat (List.map operand_jump_target_labels [q.quad_dst; q.quad_lhs; q.quad_rhs])
;;

let quad_used_vregs q = 
  let operand_directly_used_vregs s = 
    match s with 
		Reg (Vreg i) -> [i]
      | _ -> []
  in
  let operand_mem_used_vregs s = 
    match s with 
        Mem (_, Some (Vreg i), _) -> [i]
      | _ -> []
  in
    List.concat ((List.map operand_mem_used_vregs [q.quad_dst; q.quad_lhs; q.quad_rhs])
                 @ (List.map operand_directly_used_vregs [q.quad_lhs; q.quad_rhs]))
;;

let quad_defined_vregs q = 
  let operand_defined_vregs s = 
    match s with 
		Reg (Vreg i) -> [i]
      | _ -> []
  in
    List.concat (List.map operand_defined_vregs [q.quad_dst])
;;

let quad_is_unconditional_jump q =
  match q.quad_op with 
      JMP -> true
    | _ -> false
;;
 
let calculate_live_bitvectors cx = 

  let quads = cx.ctxt_quads in 
  let n_quads = Array.length quads in
  let n_vregs = cx.ctxt_n_vregs in
  let new_bitv _ = Bitv.create n_vregs false in
  let (live_in_vregs:Bitv.t array) = Array.init n_quads new_bitv in
  let (live_out_vregs:Bitv.t array) = Array.init n_quads new_bitv in
  let bitvs_equal a b = ((Bitv.to_list a) = (Bitv.to_list b)) in
	
  let changed = ref true in
    while !changed do
      changed := false;
      log cx "iterating live bitvector calculation";
      for i = n_quads - 1 downto 0 do
		let quad = quads.(i) in
		let live_in = live_in_vregs.(i) in
		let live_in_saved = Bitv.copy live_in in 
		let live_out = live_out_vregs.(i) in
		let live_out_saved = Bitv.copy live_out in 

		let union bv1 bv2 = Bitv.iteri_true (fun i -> Bitv.set bv1 i true) bv2 in

        let defined = new_bitv() in 
          
          List.iter (fun i -> Bitv.set live_in i true) (quad_used_vregs quad);
          List.iter (fun i -> Bitv.set defined i true) (quad_defined_vregs quad);

          for i = 0 to (n_vregs - 1)
          do
            if Bitv.get live_out i && not (Bitv.get defined i)
            then Bitv.set live_in i true
            else ()
          done;

		  (* Union in all our jump targets. *)
		  List.iter (fun i -> union live_out live_in_vregs.(i)) (quad_jump_target_labels quad);

		  (* Union in our block successor if we have one *)
		  if i < (n_quads - 1) && (not (quad_is_unconditional_jump quad))
		  then union live_out live_in_vregs.(i+1) 
		  else ();
		  
		  (* Possibly update matters. *)
		  if bitvs_equal live_in live_in_saved &&
            bitvs_equal live_out live_out_saved
		  then ()
		  else 
			begin 
			  live_in_vregs.(i) <- live_in;
			  live_out_vregs.(i) <- live_out;
			  changed := true
			end
      done
    done;
    log cx "finished calculating live bitvectors";
    log cx "=========================";
    for q = 0 to n_quads - 1 do
      let buf = Buffer.create 128 in
      let live_vregs = (Bitv.bw_or 
                          live_in_vregs.(q) 
                          live_out_vregs.(q)) 
      in
        for v = 0 to (Bitv.length live_vregs) - 1
        do
          if Bitv.get live_vregs v
          then Printf.bprintf buf " %-2d" v
          else Buffer.add_string buf "   "
        done;
        log cx "[%6d] live vregs: %s" q (Buffer.contents buf)
    done;
    log cx "=========================";
    (live_in_vregs, live_out_vregs)
;;

let calculate_live_intervals cx = 
  let (live_in_bitvs, live_out_bitvs) = calculate_live_bitvectors cx in
  let n_vregs = cx.ctxt_n_vregs in
  let vreg_lo = Array.create n_vregs (Array.length live_in_bitvs) in
  let vreg_hi = Array.create n_vregs (-1) in
  let note_vreg i v = 
    vreg_lo.(v) <- min vreg_lo.(v) i;
    vreg_hi.(v) <- max vreg_hi.(v) i
  in
  let note_bitv i b = Bitv.iteri_true (note_vreg i) b in
    (* 
     * FIXME: this is a poor approximation of liveness; really we should 
     * run the interval-based algorithm over inter-instruction *points* 
     * the same way we run the typestate algorithm on stmts.
     *)
    Array.iteri note_bitv live_in_bitvs;
    Array.iteri note_bitv live_out_bitvs;
    let intervals = ref LI.empty in
      for v = 0 to n_vregs - 1 do
        if vreg_hi.(v) = (-1)
        then ()
        else 
		  let interval = { live_vreg = v;
						   live_operand = Reg (Vreg v);
						   live_startpoint = vreg_lo.(v);
						   live_endpoint = vreg_hi.(v) }
		  in
		    intervals := LI.add interval (!intervals)
      done;
      (!intervals)
;;


(* Core 3 functions of Poletto and Sarkar's algorithm. *)

let expire_old_intervals intervals active curr : (LI.t * AI.t * HR.t) =
  let should_expire interval = 
    interval.live_endpoint < curr.live_startpoint
  in
  let (expired, kept) = AI.partition should_expire active in
  let free interval hardregs = 
    match interval.live_operand with
		Reg (HWreg i) -> HR.add i hardregs
      | _ -> failwith "expiring non-hardreg interval"
  in
  let freed = AI.fold free expired HR.empty in
    (intervals, kept, freed)
;;


let spill_at_interval spill_num active curr : (live_interval * live_interval * AI.t) =
  let spill = AI.max_elt active in
    if spill.live_endpoint > curr.live_endpoint 
    then
      let active = AI.remove spill active in
      let curr = { curr with live_operand = spill.live_operand } in
      let active = AI.add curr active in
      let spill = { spill with live_operand = Spill spill_num } in
		(curr, spill, active)
    else
      let curr = { curr with live_operand = Spill spill_num } in
		(curr, curr, active)
;;


let reg_alloc (sess:Session.sess) (quads:Il.quads) (vregs:int) (abi:Abi.abi) =
  try 
    let cx = new_ctxt sess quads vregs abi.Abi.abi_n_hardregs in 
    let _ = 
      begin
        log cx "un-allocated quads:";
        for i = 0 to (Array.length cx.ctxt_quads) - 1
        do 
          log cx "[%6d]\t%s" i (Il.string_of_quad cx.ctxt_quads.(i))
        done
      end
    in
    let process interval (intervals, active, free) 
        : (LI.t * AI.t * HR.t) = 
      let (intervals, active, freed) = expire_old_intervals intervals active interval in
      let free = HR.union free freed in
      let n_active = AI.cardinal active in
        if n_active > cx.ctxt_n_hardregs
        then failwith "more active hardregs than available"
        else 
		  if n_active = cx.ctxt_n_hardregs
		  then 
		    let spill_num = next_spill cx in
		    let (curr, spilled,active) = spill_at_interval spill_num active interval in
		    let intervals = LI.remove curr intervals in
		    let intervals = LI.remove spilled intervals in
		    let intervals = LI.add curr intervals in
		    let intervals = LI.add spilled intervals in
			  (intervals, active, free)
		  else
		    let hr = HR.min_elt free in
		    let free = HR.remove hr free in
		    let interval = { interval with live_operand = Reg (HWreg hr) } in
		    let intervals = LI.add interval intervals in
		    let active = AI.add interval active in
			  (intervals, active, free)
    in
    let initial_intervals = LI.empty in
    let initial_active = AI.empty in
    let initial_free = (let x = ref HR.empty in 
						  for i = 0 to cx.ctxt_n_hardregs - 1 do
						    x := HR.add i (!x)
						  done;
						  !x)
    in
    let initials = (initial_intervals, initial_active, initial_free) in
    let unallocated_intervals:LI.t = calculate_live_intervals cx in

    let _ = log cx "unallocated live intervals:" in
    let _ = log_live_intervals cx unallocated_intervals in

    let (allocated_intervals, _, _) = 
      LI.fold process unallocated_intervals initials 
    in

    let _ = log cx "allocated live intervals:" in
    let _ = log_live_intervals cx allocated_intervals in

      convert_labels cx;
      convert_vregs allocated_intervals cx;
      kill_redundant_moves cx;
      
      log cx "register-allocated quads:";
      for i = 0 to (Array.length cx.ctxt_quads) - 1
      do 
        log cx "[%6d]\t%s" i (Il.string_of_quad cx.ctxt_quads.(i))
      done;

      cx.ctxt_quads

  with 
      Ra_error s -> 
        Session.fail sess "RA Error: %s" s;
        quads
        
;;


(* 
 * Local Variables:
 * fill-column: 70; 
 * indent-tabs-mode: nil
 * compile-command: "make -k -C .. 2>&1 | sed -e 's/\\/x\\//x:\\//g'"; 
 * End:
 *)
