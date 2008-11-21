
(* 
 * The 'abi' structure is pretty much just a grab-bag of machine
 * dependencies.  Make some attempt to factor it as time goes by.  
 *)

(* 

 * It's also a place to make some notes and ascii-art about the actual
 * ABI. Because it needs a bunch of quite specific, yet somewhat
 * arbitrary choices made.

 * A frame needs a return PC and a yield PC. These have to be separate
 * because we can tail-yield, and want to skip intermediate live
 * non-tail-call frames.

 * How do you get two PCs when there's only a call instruction? There
 * are three cases: 

 * Case #1 is a "base call" in which we pass our PC using the call
 * insn and the static distance between the return-point and the
 * yield-point. Since we the caller have both these PCs in ourself, we
 * can statically work out the distance.

 * Case #2 is a "tail yield call": we are the return point, but our
 * caller (or one of its callers) is the yield point. Here we pass our
 * return PC and our caller's yield PC directly. We can't work out the
 * difference between the two because one is only knowable at
 * file-offset, compile-time terms, and one is dynamic.

 * Case #3 is a "full tail call": we are destroying our own frame
 * entirely and passing both our caller's return PC and yield PC to
 * the callee. Our PC is irrelevant so we just adjust the frame around
 * the existing (reused) two PCs and jump to our target.

 * The 2nd and 3rd case can, I think, be folded into a single case
 * with different frame adjustments. But we need to convey 1 bit of
 * information to differentiate 1st from 2nd. Easiest way is to use
 * the low bit of the yield address and make sure all yield addresses
 * are 2-byte aligned. This in turn requires that the assembler grow
 * the ability to insert nops, via a CODEALIGN alignment type. No
 * problem. If we actually need to differentiate case 3, possibly use
 * the two low bits, or possibly make multiple entry points in a fn.

 * 
 * 
 * 
 * frame layout:
 * 
 * [0] return PC
 * [0] link to process                         <-- frame pointer (x86:ebp) 
 * [1*ptr] link to type descriptor
 * [2*ptr] outgoing slot = N bytes             <-- start of 'args'
 * [N+2*ptr] link to parent closure
 * [N+3*ptr] arg tuple = K bytes
 * [N+K+3*ptr] link to our closure             <-- start of 'locals'
 * [N+K+4*ptr] spill0
 * ...         ...
 * ...         spillN
 * 
 * 
 * process layout:
 * 
 *  [0] link to runtime system
 *  [1*ptr] link to crate
 *  [2*ptr] link to parent closure
 *  [
 *)

type abi =
  {
    abi_ptrsz: int;
    abi_ptr_mem: Il.mem;

    abi_is_2addr_machine: bool;
    abi_has_pcrel_loads: bool;
    abi_has_pcrel_jumps: bool;
    abi_has_imm_loads: bool;
    abi_has_imm_jumps: bool;
    abi_n_hardregs: int;
    abi_str_of_hardreg: (int -> string);
    
    abi_fp_operand: Il.operand;
    abi_pp_operand: Il.operand;
    abi_cp_operand: Il.operand;
    abi_rp_operand: Il.operand;  
  }


(* 
 * Local Variables:
 * fill-column: 70; 
 * indent-tabs-mode: nil
 * compile-command: "make -k -C .. 2>&1 | sed -e 's/\\/x\\//x:\\//g'"; 
 * End:
 *)