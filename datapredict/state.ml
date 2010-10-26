open List
open Cil
open Utils
open Globals
open DPGlobs
open Invariant
open Memory

module type PredictState =
sig
  type t    (* type of state *)

  (* create a state *)
  val new_state : int -> t 
	
  (* add info to the state *)
  val add_run : t -> int -> t
  val add_predicate : t -> int -> (int * predicate) -> bool -> int -> t
  val add_layout : t -> int -> int -> t

  (* get basic info about the state *)
  val state_id : t -> int
  val runs : t -> int list
  val predicates : t -> (predicate * int) list
  val is_ever_executed : t -> bool

  (* more complex info about the state *)

  val fault_localize : t -> strategy -> float
  val observed_on_run : t -> int ->  bool

  (* evaluate/generate new predicates on this state *)

  val is_pred_ever_true : t -> predicate -> bool
  val overall_pred_on_run : t -> int -> predicate -> int * int

  (* rank computation *)
  val set_and_compute_rank : t -> predicate -> int -> int -> int -> int -> int -> (t * rank)

  (* for state sets *)
  val compare : t -> t -> int

  (* debug *)
  val print_vars : t -> unit
  val print_preds : t -> unit 

end 

module DynamicState =
struct
  (* need some kind of decision about whether to do int/float distinction. Do
     I need the tags? *)

  (* a dynamic state is actually a statement that was executed at least once *)

  type t =  {
    stmt_id : int ;
    memory : Memory.t;
	(* memory maps run, count to memory layout id. *)
    (* maps run numbers to the number of times this run visits this state. I
       think but am not entirely sure that this is a good idea/will work *)
    runs : int IntMap.t ;
    (* predicates: map predicate -> int -> num true, num false *)
    predicates : (predicate, int * (int, (int * int)) Hashtbl.t) Hashtbl.t;
    rank : (predicate, rank) Hashtbl.t ;
  }

  let empty_state () = {
    stmt_id = (-1) ;
    memory = Memory.new_state_mem ();
    runs = IntMap.empty ;
    predicates = hcreate 100;
    rank = hcreate 100 ;
  }
	
  (******************************************************************)

  let new_state site_num = 
    let news = empty_state () in
      {news with stmt_id=site_num}

  (******************************************************************)

  let add_run state run = 
    let old_val = 
      if IntMap.mem run state.runs then IntMap.find run state.runs else 0 in
    let new_map = IntMap.add run (old_val + 1) state.runs in
      {state with runs=new_map}

  let add_predicate state run (num,pred) torf count = 
    let (_,predT) = ht_find state.predicates pred 
      (fun x -> 0, (hcreate 100)) in
    let (numT, numF) = ht_find predT run (fun x -> (0,0)) in
    let (numT',numF') = if torf then (numT + count, numF) else (numT, numF + count) in
      hrep predT run (numT',numF');
      hrep state.predicates pred (num,predT);
      state

  (* add a memory layout to this run for this count, which should be the
   * current number for this run in state.runs *)

  let add_layout state run layout_id =
	let count = IntMap.find run state.runs in
	  (* do we care about the order? Can we just track total count instead of
	   * actual iterations? *)
	  {state with memory = (Memory.add_layout state.memory run count layout_id)}

  (******************************************************************)

  let state_id state = state.stmt_id

  let runs state = 
    IntMap.fold (fun key -> fun count -> fun accum -> key :: accum)
      state.runs []

  let predicates state = 
    (* fixme: maybe distinguish between the default, site-specific
     * predicates and the ones we add as we go? At least for the
     * purposes of standard SBI stuff? *)
    hfold (fun k -> fun (n,v) -> fun accum -> (k,n) :: accum) state.predicates []

  let is_ever_executed state = hmem state.predicates (Executed)

  (******************************************************************)

  let observed_on_run state run = IntMap.mem run state.runs

  let fault_localize state strat = 
	(* fault localize assumes that the state.rank hashtable has been
	   computed! *)
	(* for some of these, it doesn't make sense to consider the "IsExecuted"
	   predicate - things that rely on obs and is_true to be different, for
	   example. Hence the addition of "filt" to highest_rank - it filters the
	   list of ranked predicates whose values we consider when finding the
	   highest rank. *)
    let highest_rank compfun valfun filt =
      let ranks = lmap (fun (pred,rank) -> rank) (lfilt filt (ht_pairs state.rank)) in
      let sorted_ranks = sort compfun ranks in
		try valfun (hd sorted_ranks) with _ -> 0.0
    in
      match strat with
		Intersect(w) -> 
		  let (_,execT) = hfind state.predicates (Executed) in
		  let on_failed_run, on_passed_run =
			hfold
			  (fun run ->
				 fun (numT,numF) ->
				   fun (on_failed, on_passed) ->
					 let fname,good = hfind !run_num_to_fname_and_good run in
					   if numT > 0 then begin
						 if good == 1 then (* FAIL is 1! I should change that...*)
						   (true,on_passed)
						 else 
						   (on_failed,true)
					   end else (on_failed,on_passed)) execT (false,false)
		  in
			if not on_failed_run then 0.0 else 
			  if on_passed_run then w else 1.0
      | FailureP ->
		  highest_rank 
			(fun rank1 -> fun rank2 ->
			   Pervasives.compare rank2.failure_P rank1.failure_P)
			(fun rank -> rank.failure_P)
			(fun (pred,rank) -> match pred with Executed -> false | _ -> true)
      | Increase -> 
		  highest_rank 
			(fun rank1 -> fun rank2 ->
			   Pervasives.compare rank2.increase rank1.increase)
			(fun rank -> rank.increase)
			(fun (pred,rank) -> match pred with Executed -> false | _ -> true)
      | Context ->
		  highest_rank 
			(fun rank1 -> fun rank2 ->
			   Pervasives.compare rank2.context rank1.context)
			(fun rank -> rank.context)
			(fun (pred,rank) -> true) 
      | Importance -> 
		  highest_rank 
			(fun rank1 -> fun rank2 ->
			   Pervasives.compare rank2.importance rank1.importance)
			(fun rank -> rank.importance)
			(fun (pred,rank) -> match pred with Executed -> false | _ -> true)
      | Random -> Random.float 1.0
      | Uniform -> 1.0 

  let eval_new_pred state pred = 
    let newPredT = hcreate 10 in
      (* all_layouts may be empty: state may be a cfg state, 
       * or this state may not be observed on this run *)
      liter 
		(fun run ->
		   let (numT,numF) = 
			 Memory.eval_pred_on_run state.memory run pred
		   in
			 hadd newPredT run (numT, numF);
		) (runs state);
	  (* check this: can I just add the stmt_id as the checked thing
		 or should I take in a num here instead? *)
      hrep state.predicates pred (state.stmt_id,newPredT)
	
  let is_pred_ever_true state pred = 
    if not (hmem state.predicates pred) then eval_new_pred state pred;
    let (_,predT) = hfind state.predicates pred in
      hfold
		(fun run ->
		   fun (t,f) ->
			 fun accum ->
			   if t > 0 then true else accum) predT false

  let overall_pred_on_run state run pred = 
    if not (hmem state.predicates pred) then eval_new_pred state pred;
    let (n,predT) = hfind state.predicates pred in
      try 
		hfind predT run
      with Not_found ->
		begin
		  hadd predT run (0,0);
		  hrep state.predicates pred (n,predT);
		  (0,0)
		end

  (******************************************************************)

  let set_and_compute_rank state pred numF f_P f_P_obs s_P s_P_obs = 
    let failure_P =
      float(f_P) /. 
		(float(f_P) +. 
		   float(s_P)) in
    let context = float(f_P_obs) /. (float(f_P_obs) +. float(s_P_obs)) in
    let increase = failure_P -. context in
    let importance = 2.0 /.  ((1.0 /. increase) +. (float(numF) /. failure_P))
    in
    let rank = 
      {f_P=f_P; 
       s_P=s_P; 
       f_P_obs=f_P_obs; 
       s_P_obs=s_P_obs;
       numF=numF; 
       failure_P=failure_P; 
       context=context;
       increase=increase; 
       importance=importance} in
      hrep state.rank pred rank;
      (state, rank)

  (******************************************************************)

  let compare state1 state2 = state1.stmt_id - state2.stmt_id

  (******************************************************************)

  let print_vars state = 
	Memory.print_in_scope state.memory

  let print_preds state = 
    liter 
      (fun (pred,_) ->
		 pprintf "%s:\n" (d_pred pred);
		 let (n,innerT) = hfind state.predicates pred in 
		   hiter 
			 (fun run -> 
				fun (t,f) -> 
				  pprintf "run %d, t: %d, f: %d\n" run t f) innerT
      ) (predicates state)
      
end

(*type node_type = Uninitialized | Cfg | Ast | Site_node | Abstract

module BPState =
sig
  type t    (* type of state *)
  val state_id : t -> int
  val new_state : int -> t
  val convert : PredictState.t -> t

  val fault_prob : t -> float
  val fix_prob : t -> t -> float
end

module BPState =
  functor (S : PredictState) ->
struct
  type t  =
      {
	(* id is related to the AST/CFG number, right? *)
	id : int ;
	fault_prob : float ;
	fix_prob : (t, float) Hashtbl.t ;
	node_type : node_type ;
	pD : (t, float) Hashtbl.t ;
      }

  let empty_state () = {
    id = -1; 
    fault_prob = 0.0; 
    fix_prob = Hashtbl.create 100;
    node_type = Uninitialized ;
  }

  let state_id state = state.id

  let new_state id = 
    let news = empty_state () in 
      {news with id = id}

  let convert ps = failwith "Not implemented"

  let fault_prob state = state.fault_prob 

  let fix_prob state1 state2 = failwith "Not implemented"

end
*)