(** The base type of the numeric abstract domains used in CacheAudit *)
open X86Types
open AD.DS

(** Module containing data structures common to numeric abstract domains *)
module DS = struct

  (** Type of variables *)
  type var = Int64.t
      
  (** Type for numeric operands, which can be either variables or numeric constant *)
  type cons_var = Cons of int64 | VarOp of var

  (** Converts cons_var to var *)
  let consvar_to_var = function (* TODO: Rename to operand_to_var? *)
    | VarOp x -> x
    | Cons _ -> failwith "consvar_to_var: can't convert constant"


  (** Types for masking operations *)
  type mask_t = HH | HL | LH | LL
  type mask = NoMask | Mask of mask_t

  let rem_to_mask = function
    | 0L -> HH
    | 1L -> HL
    | 2L -> LH
    | 3L -> LL
    | _ -> failwith "rem_to_mask: incorrect offset"

  let mask_to_intoff = function
    | HH -> (0xFF000000L, 24)
    | HL -> (0x00FF0000L, 16)
    | LH -> (0x0000FF00L, 8)
    | LL -> (0x000000FFL, 0)

  (**/**) (* Definitions below are not included in documentation *)

  module NumSet = Set.Make(Int64)
  module NumMap = Map.Make(Int64)
  module IntSet = Set.Make(struct type t = int let compare = compare end)
  module IntMap = Map.Make(struct type t = int let compare = compare end)
  module VarMap = Map.Make(struct type t=var let compare = compare end)
  
  
  type flags_t = { cf : bool; zf : bool; }
  let initial_flags = {cf = false; zf = false}
  (* Assumption: Initially no flag is set *)
  
  module FlagMap = Map.Make(struct 
      type t = flags_t 
      let compare = Pervasives.compare 
    end)
  
  (* combine two flag maps, *)
  (* for keys present in only one of them return the respective values, *)
  (* if keys are defined in both, apply function [fn] to values *)
  let fmap_combine fm1 fm2 fn = FlagMap.merge (fun _ a b -> 
  match a,b with None,None -> None
  | Some x, None -> Some x | None, Some y -> Some y
  | Some x, Some y -> Some (fn x y)) fm1 fm2
  
  (* for handling legacy functions *)
  
  let fmap_to_tupleold fmap =
    let get_values flgs = try( 
        Nb (FlagMap.find flgs fmap)
      ) with Not_found -> Bot in
     get_values {cf = true; zf = true},
     get_values {cf = true; zf = false},
     get_values {cf = false; zf = true},
     get_values {cf = false; zf = false}
     
  let tupleold_to_fmap old = let fmap = FlagMap.empty in
    let set_vals_nobot flgs vals fmap = match vals with 
    | Bot -> fmap
    | Nb x -> FlagMap.add flgs x fmap in
    let tt, tf, ft, ff = old in
    let fmap = set_vals_nobot {cf = true; zf = true} tt fmap in
    let fmap = set_vals_nobot {cf = true; zf = false} tf fmap in
    let fmap = set_vals_nobot {cf = false; zf = true} ft fmap in
    set_vals_nobot {cf = false; zf = false} ff fmap

end

