(* Copyright (c) 2013-2015, IMDEA Software Institute.          *)
(* See ../LICENSE for authorship and licensing information     *)

open X86Types
open AbstrInstr
open AD.DS

(** Stack abstract domain: keeps track of stack operations, 
    such as push and pop operations and function calls.  *)

module type S = 
sig
  include AD.S
    
    (** Creates a StackAD with the following parameters
	More specifically, in 
	[init cm sv dcp]     
       - [cm] is the executable,
       - [sv] are initial values of memory locations and registers, and
       - [dcp] is the configuration of the data caches
    *)

  val init : X86Headers.t -> Config.mem_param -> CacheAD.cache_param -> t

  (** For an op32 expression, returns a finite list of possible
      values, each value associated with an approximation of the
      corresponding memory states leading to that particular value. In
      case no finite list can be determied, returns Top.  *)
  val get_vals : t -> op32 -> (int, t) finite_set

  (** Returns an overapproximation of the environments in which the condition holds,
      followed by an overapproximation of the environments in which it doesn't. *)
  val test : t -> condition -> t add_bottom * t add_bottom

  (** Records a call and its effects on the stack. The first argument is the 
      address of the call, the second one is the return address. *)
  val call : t -> op32 -> int -> (int, t) finite_set

  (** Records a return (and its effect on the stack). *)
  val return : t -> (int, t) finite_set
  
  (** Interpret an instruction, if the particular instruction cannot be handled 
    here, pass it to the next module *)
  val interpret_instruction : t -> X86Types.instr -> t

    
  (** Signal to the cache that a memory location has been accessed *)  
  val touch : t -> int64 -> NumAD.DS.rw_t -> t
      
  (** Signal from the iterator to the cache the
      time consumed by an instruction *)
  val elapse : t -> int -> t
end
  
(** Creates a StackAD from a MemAD *)
module Make :
  functor (M : MemAD.S) -> S
