open Big_int
open AD.DS
open NumAD.DS
open AbstrInstr
open Logger

type replacement_strategy = 
  | LRU  (** least-recently used *)
  | FIFO (** first in, first out *)
  | PLRU (** tree-based pseudo LRU *)

(* This flag can disable an optimization (for precision) *)
(* which checks whether ages of elements are achievable by the *)
(* corresponding replacement strategy.*)
(* If disabled, holes will be counted as possible, if enabled, only the holes*)
(* achievable by the strategy will be counted *)
let exclude_impossible = ref true

module type S = sig
  include AD.S
  val init : int -> (var -> int) -> (var->string) -> replacement_strategy -> t
  val inc_var : t -> var -> t
  val set_var : t -> var -> int -> t
  val delete_var : t -> var -> t
  val permute : t -> (int -> int) -> var -> t
  val get_values : t -> var -> int list
  val exact_val : t -> var -> int -> (t add_bottom)
  val comp : t -> var -> var -> (t add_bottom)*(t add_bottom)
  val comp_with_val : t -> var -> int -> (t add_bottom)*(t add_bottom)
  val get_strategy : t -> replacement_strategy
  val get_permutation: replacement_strategy -> int -> int -> int -> int
  val count_cstates: t -> big_int * big_int
end


module Make (V: ValAD.S) = struct
  
  type t = {
    value: V.t;
    max_age : int; (* max_age = the cache associativity 
                      and is interpreted as "outside of the cache" *)
    pfn : var -> int;
    strategy : replacement_strategy
  }
    
  
  let init max_age pfn v2s str = {
    value = V.init v2s; 
    max_age = max_age;
    pfn = pfn;
    strategy = str
  }
  
  let get_strategy env = env.strategy
  
  (* Permutation to apply when touching an element of age a in PLRU *)
  (* We assume an ordering correspond to the boolean encoding of the tree from *)
  (* leaf to root (0 is the most recent, corresponding to all 0 bits is the path *)
  
  let plru_permut assoc a n = if n=assoc then n else
    let rec f a n =  
      if a=0 then n 
      else 
        if a land 1 = 1 then 
  	if n land 1 = 1 then 2*(f (a/2) (n/2)) 
  	else n+1
        else (* a even*) 
  	if n land 1 = 1 then n 
  	else 2*(f (a/2) (n/2))
    in f a n
  
  
  let lru_permut assoc a n = 
    if n = a then 0
    else if n < a then n+1
    else n
  
  let fifo_permut assoc a n = n
  
  let get_permutation strategy = match strategy with
    | LRU -> lru_permut
    | FIFO -> fifo_permut
    | PLRU -> plru_permut
  
  
  let join e1 e2 = 
    assert (e1.max_age = e2.max_age);
    {e1 with value = (V.join e1.value e2.value)}
  
  let flatten fmap = 
    assert (FlagMap.cardinal fmap = 1);
    FlagMap.find initial_flags fmap

  let fmap_to_tuple fmap =
    let get_values flgs = try( 
        Nb (FlagMap.find flgs fmap)
      ) with Not_found -> Bot in
     get_values {cf = true; zf = true},
     get_values {cf = true; zf = false},
     get_values {cf = false; zf = true},
     get_values {cf = false; zf = false}
  
  (* computes comparison of x1 and x2, see vguard below *)
  (* the first result is x1<x2, the second one x1=x2 and the last one x1>x2 *)
  let vcomp venv x1 x2 = 
    let _,tf,ft,ff= fmap_to_tuple (V.update_val venv initial_flags x1 NoMask x2 NoMask (Aflag Acmp) None) in
    (* Since we only have positive values, when the carry flag is set, it means venv is strictly smaller than x2 *)
    (* The case where there is a carry and the result is zero should not be 
possible, so it approximates Bottom *)
   tf,ft,ff

  (* Compute x<c in V, where x is a variable and c an int. Should be extended to the case where c is a var *)
  (* the first result is x<c, the second one x=c and the last one x>c *)
  let vguard venv x c = vcomp venv x (Cons(Int64.of_int c))

  let inc_var env v = 
    let young,nyoung,bigger = vguard env.value v env.max_age in
(* we assume the cases bigger than max_age are irrelevent and we never increase values above max_age *)
    assert (bigger = Bot);
    let new_valad = 
      match young with
      | Bot -> env.value
      | Nb yenv ->
        let yenv = flatten (V.update_val yenv initial_flags v NoMask (Cons 1L) NoMask (Aarith X86Types.Add) None) in
        match nyoung with
        | Bot -> yenv
        | Nb nyenv -> V.join yenv nyenv
    in {env with value = new_valad}
                       
  let is_var env a = V.is_var env.value a

  let set_var env v a = 
      (* set_var cannot set to values greater than the maximal value *)
      assert (a <= env.max_age);
      let value = if not (is_var env v) then 
                  V.new_var env.value v
                else env.value
      in let value = flatten(V.update_val value initial_flags v NoMask (Cons(Int64.of_int a)) NoMask Amov None) in
      {env with value = value}
  
  
  let list_max l = List.fold_left (fun m x -> if x > m then x else m ) 0L l
 
  (* updates an env according to the value env *)
  let vNewEnv env = function
    Bot -> Bot
  | Nb venv -> Nb{env with value = venv}

  (* the first result is approximates the cases when x1 < x2 and
     the second one when x1 > x2 *)
  let comp env x1 x2 = 
    let smaller, _, bigger = vcomp env.value x1 (VarOp x2) in
    vNewEnv env smaller, vNewEnv env bigger

  let comp_with_val env x v =
    let smaller, eq, bigger = vguard env.value x v in
    vNewEnv env smaller, lift_combine join (vNewEnv env eq) (vNewEnv env bigger)

  let exact_val env x c =
    let smaller, eq, bigger = vguard env.value x c in vNewEnv env eq

  (* apply the permutation perm to the age of variable x *)
  let permute env perm x = 
    let perm64 a = Int64.of_int (perm (Int64.to_int a)) in
    match V.get_var env.value x with
    | Tp -> env
    | Nt vm -> 
      let v1,_ = NumMap.min_binding vm in
      let value1 = let nv1 = perm64 v1 in V.set_var env.value x nv1 nv1 in 
      {env with value = 
           NumMap.fold (fun c _ value -> let nc = perm64 c in
                        V.join value (V.set_var value x nc nc))
                     (NumMap.remove v1 vm) value1
      }
  

  let print_delta env1 fmt env2 = V.print_delta env1.value fmt env2.value
  let print fmt env = 
    V.print fmt env.value

  let subseteq env1 env2= 
    assert (env1.max_age = env2.max_age);
    (V.subseteq env1.value env2.value)
  let widen env1 env2 = 
    assert (env1.max_age = env2.max_age);
    {env1 with value = (V.widen env1.value env2.value)}

  let get_values env v = let l = match V.get_var env.value v with
     Tp -> []  | Nt x -> NumMap.bindings x in
     List.map (fun (k,_) -> Int64.to_int k) l
  
  let delete_var env v = {env with value = V.delete_var env.value v}
    
  
  (*** Counting valid states ***)
  
  module IntSetSet = Set.Make(IntSet)
  
  let intset_map f iset = 
    IntSet.fold (fun x st -> IntSet.add (f x) st) iset IntSet.empty
  
  (* Return a set containing sets of possible age allocations within a cache set *)
  (* depending on the replacement strategy *)
  let get_poss_ages strategy assoc = 
    let permut = get_permutation strategy in
    let rec loop ready todo = 
      if IntSetSet.is_empty todo then ready
      else 
        let elt = IntSetSet.choose todo in
        let ready = IntSetSet.add elt ready in
        let todo = IntSetSet.remove elt todo in
        (* hit successors *)
        let successors = IntSet.fold (fun i succ ->
          IntSetSet.add (int_set_map (permut assoc i) elt) succ
          ) elt IntSetSet.empty in
        (* miss successor *)
        let miss_elt = IntSet.remove assoc (IntSet.add 0 (int_set_map succ elt)) in
        let successors = IntSetSet.add miss_elt successors in
        let todo = IntSetSet.diff (IntSetSet.union todo successors) ready in
        loop ready todo in
    loop IntSetSet.empty (IntSetSet.singleton IntSet.empty) 
  
  (* check whether cstate is a possible concretization for a cache set,*)
  (* according to the list poss_ages containing the possible ages in the cache set*)
  let is_poss poss_ages cstate = 
    let state_ages,_ = List.fold_left (fun (st,ctr) x -> 
        match x with
        | None -> (st,succ ctr)
        | Some _ -> (IntSet.add ctr st, succ ctr)
      ) (IntSet.empty,0) cstate in
    IntSetSet.mem state_ages poss_ages
    
  
  (* Checks if the given cache state is valid *)
  (* with respect to the ages (which are stored in [env])*)
  (*  of the elements of the same cache set [addr_set]*)
  let is_valid_cstate env addr_set cache_state poss_ages = 
    assert (List.for_all (function Some a -> NumSet.mem a addr_set | None -> true) cache_state);
    if !exclude_impossible && (not (is_poss poss_ages cache_state)) then false
    else
      (* get the position of [addr] in cache state [cstate], starting from [i];*)
      (* if the addres is not in cstate, then it should be max_age *)
      let rec pos addr cstate i = match cstate with 
         [] -> env.max_age
      | hd::tl -> if hd = Some addr then i else pos addr tl (i+1) in
      NumSet.for_all (fun addr -> 
        List.mem (pos addr cache_state 0) (get_values env addr)) addr_set 
  
  
  (* create a uniform list containing n times the element x *)
  let create_ulist n x =
    let rec loop n x s = 
      if n <= 0 then s else loop (n-1) x (x::s)
    in loop n x []
  
  (* create a list with the elements [a;a+1;...;b-1] (not including b) *)
  let create_range a b = 
    let rec loop x s = 
      if x < a then s else loop (x-1) (x::s)
    in loop (b-1) []
  
  module NumSetSet = Set.Make(NumSet)
  let numset_from_list l =
    List.fold_left (fun set elt -> 
      match elt with None -> set
      | Some i -> NumSet.add i set) NumSet.empty l
  
  (* Count the number of n-permutations of the address set addr_set*)
  (* which are also a valid cache state *)
  let num_tuples env n addr_set = 
    (* Preprocessing step for counting: set of all possible sets of ages*)
    (* of the blocks within a cache set *)
    let poss_ages = get_poss_ages env.strategy env.max_age in
    if NumSet.cardinal addr_set >= n then begin
      (* the loop creates all n-permutations and tests each for validity *)
      let rec loop n elements tuple num = 
        if n = 0 then 
          (* if env.strategy <> PLRU then                            *)
          (*   if is_valid_cstate env addr_set tuple poss_ages then  *)
          (*     Int64.add num 1L else num                           *)
          (* else                                                    *)
            (* In PLRU "holes" are possible, i.e., there may be a with age i, *)
            (* and there is no b with age i-1. *)
            let rec loop_holes cstate rem_elts num = 
              if (List.length rem_elts) = 0 then 
                (* no rem_elts -> this is a possible cache state;*)
                (* check it for validity *)
                if is_valid_cstate env addr_set cstate poss_ages then Int64.add num 1L else num
              else
                let elt = List.hd rem_elts in
                let rem_elts = List.tl rem_elts in
                (* a list containing the possible number of holes before elt *)
                let poss_num_holes = create_range 0 (env.max_age - 
                  (List.length cstate) - (List.length rem_elts)) in
                
                List.fold_left (fun num nholes -> 
                  (* add the nholes holes and elt to the state *)
                  (* and continue scanning the remaining elements *)
                  loop_holes (cstate @ (create_ulist nholes None) @ [elt]) rem_elts num
                  ) num poss_num_holes
            in loop_holes [] tuple num
        else
          (* add next element to tuple and continue looping *)
          (* (will go on until n elements have been picked) *)
          NumSet.fold (fun addr s1 -> 
            loop (n-1) (NumSet.remove addr elements) ((Some addr)::tuple) s1
            ) elements num in 
      loop n addr_set [] 0L
    end else 0L
    
  (* Computes two lists where each item i is the number of possible *)
  (* cache states of cache set i for a shared-memory *)
  (* and the disjoint-memory (blurred) adversary *)
  let cache_states_per_set env =
    let cache_sets = Utils.partition (V.var_names env.value) env.pfn in
    IntMap.fold (fun _ addr_set (nums,bl_nums) ->
        let num_tpls,num_bl =
          let rec loop i (num,num_blurred) =
            if i > env.max_age then (num,num_blurred)
            else
              let this_num = 
                num_tuples env i addr_set in
              let this_bl = if this_num = 0L then 0L else 1L in
              loop (i+1) (Int64.add num this_num, Int64.add num_blurred this_bl) in 
          loop 0 (0L,0L) in 
        (num_tpls::nums,num_bl::bl_nums)
      ) cache_sets ([],[])
      
  let count_cstates env = 
    let nums_cstates,bl_nums_cstates = cache_states_per_set env in
      (Utils.prod nums_cstates,Utils.prod bl_nums_cstates)
  
end

