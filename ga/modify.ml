(* 
 * Weimer's Genetic Programming Prototype 
 *
 * Given a C program and a path through that program, modify the program
 * using genetic programming to produce variants. Test each variant against
 * some testcases to determine fitness. 
 *)
open Printf
open Cil
open Str

let version = "WRW: Wed Aug 27 17:29:50 EDT 2008"

let comma_regexp = regexp_string ","
let whitespace_regexp= regexp "[ \t\n]+"

(* We'll use integers to map to 'statements' in the C program/AST. *) 
type stmt_id = int 

(* We'll maintain mappings from stmt_id's to real CIL statements. *) 
type stmt_map = (stmt_id, Cil.stmtkind) Hashtbl.t 

(* We'll keep a 'weighted' violating path *) 
type weighted_path = (float * stmt_id) list 

(* Performance counting information *) 
type counters = {
  mutable ins  : int ; (* insertions *) 
  mutable del  : int ; (* deletions *) 
  mutable swap : int ; (* swaps *) 
  mutable xover : int ; (* crossover count *) 
  mutable mut   : int ; (* mutation count *) 
} 

type tracking = {
  mutable current : counters ; 
  mutable at_last_fitness : counters ; 
  mutable was_cached : bool ;
} 

(* Our key data type: a single 'individual' in our GP population. 
 * Each individual is a four-tuple with
 * 1. A Cil.file -- the abstract syntax tree
 * 2. A Hashtable -- mapping integers to statements in the AST 
 * 3. A number -- the number of statements in the *whole AST*
 *                (_not_ the length of the path)
 * 4. A list of numbers -- the violating path as a list of statement IDs 
 *) 
type individual = 
   Cil.file *
   stmt_map *
   stmt_id *
     (weighted_path) *
   tracking

(***********************************************************************
 * Utility Functions 
 ***********************************************************************)
let new_counters () = 
  { ins = 0; del = 0; swap = 0; xover = 0; mut = 0; }
let new_tracking () = 
  { current = new_counters () ; at_last_fitness = new_counters (); was_cached = false } 

let print_best_output = ref (fun () -> ()) 

let favor_uncached = ref false

(* we copy all debugging output to a file and to stdout *)
let debug_out = ref stdout 
let debug fmt = 
  let k result = begin
    output_string !debug_out result ; 
    output_string stdout result ; 
    flush stdout ; 
  end in
  Printf.kprintf k fmt 

let uniq lst = (* return a copy of 'lst' where each element occurs once *) 
  let ht = Hashtbl.create 255 in 
  let lst = List.filter (fun elt ->
    if Hashtbl.mem ht elt then false
    else begin
      Hashtbl.add ht elt () ;
      true 
    end 
  ) lst in
  lst 

(* Returns the elements of 'lst' in a random order. *) 
let random_order lst = 
  let a = List.map (fun x -> (Random.float 1.0), x) lst in
  let b = List.sort (fun (a,_) (b,_) -> compare a b) a in 
  List.map (fun (_,a) -> a) b 

let rec first_nth lst size =  
  if size < 1 then [] 
  else match lst with
  | [] -> []
  | hd :: tl -> hd :: (first_nth tl (pred size))

let file_size name = (* return the size of the given file on the disk *) 
  try 
    let stats = Unix.stat name in
    stats.Unix.st_size 
  with _ -> 0 

(* This makes a deep copy of an arbitrary Ocaml data structure *) 
let copy (x : 'a) = 
  let str = Marshal.to_string x [] in
  (Marshal.from_string str 0 : 'a) 
  (* Cil.copyFunction does not preserve stmt ids! Don't use it! *) 

(* Counts the number of lines in a simple text file -- used by
 * our fitness function. Returns the integer number as a float. *) 
let count_lines_in_file (file : string) 
                        (* returns: *) : float =
  try 
    let fin = open_in file in 
    let count = ref 0 in
    (try while true do
      let line = input_line fin in
      ignore line ;
      incr count 
    done ; 0. with _ -> begin close_in fin ; float_of_int !count end) 
  with _ -> 0.


let probability p = 
  if p <= 0.0 then false
  else if p >= 1.0 then true
  else Random.float 1.0 <= p 

let my_int_of_string str =
  try 
    let res = ref 0 in 
    Scanf.sscanf str " %i" (fun i -> res := i) ;
    !res
  with _ -> begin 
    if String.lowercase str = "true" then 1
    else if String.lowercase str = "false" then 0 
    else failwith ("cannot convert to an integer: " ^ str)
  end 

(*v_ Vu's stuffs*)
let v_avg_fit_l:float list ref = ref []  (*avg_fit list*)
let v_bc_fit_l:float list ref = ref []	 (*best chrome fit list*)

let v_debug:int ref = ref 0

let v_writeFile (f_src:string) (f_ast:Cil.file) = (
  let f_out = open_out f_src in
    Cil.dumpFile Cil.defaultCilPrinter f_out f_src f_ast;
    close_out f_out
)


let v_getDigestName (filecontent:Cil.file):string=(
  let filename = "temp_digest" in
  v_writeFile filename filecontent;
  let digest = Digest.file filename in
  (try (Unix.unlink filename) with _ -> ());
  let res = Digest.to_hex(digest) in
  res
	)
	
let v_get_stmt (b:stmt):string= (
   let doc_of_stmt = d_stmt () b in
  let string_of_stmt = Pretty.sprint ~width:80 doc_of_stmt in
  string_of_stmt
)
	

(*v_ Vu's stuffs*)


(***********************************************************************
 * Genetic Programming Functions - Sampling
 ***********************************************************************)
let use_tournament = ref false 

(* 
 * Stochastic universal sampling. 
 *
 * Stephanie suggests that we replace this with tournament selection at
 * some point. 
 *
 * Input: a list of individual,fitness pairs
 *        a desired number of individuals
 *
 * Output: a list of individuals
 *) 
let sample (population : (individual * float) list) 
           (desired : int) 
           (* returns *) : individual list = 
  let total = List.fold_left (fun acc (_,fitness) ->  
								acc +. fitness) 0. population in 

  (*v_ analysis*)
  v_avg_fit_l := (total /. float_of_int (List.length population) )::!v_avg_fit_l;
  
  let sort_pop = List.rev (List.sort (fun (_,a)(_,b) -> compare a b)population) in 
  let best_chrome_fit:float = snd(List.hd sort_pop) in
  v_bc_fit_l :=  best_chrome_fit::!v_bc_fit_l ;
  (*v_ analysis*)


  (if total <= 0. then failwith "selection: total <= 0") ; 
  let normalized = List.map (fun (a,fitness) ->
							   a, fitness /. total
							) population in 
  let sofar = ref 0.0 in 
  let accumulated = List.map (fun (a,normalized) ->
								let res = normalized +. !sofar in
								  sofar := !sofar +. normalized ;
								  (a,res)
							 ) normalized in 
  let distance_between_pointers = 1.0 /. (float_of_int desired) in 
  let offset = Random.float distance_between_pointers in 
  let result = ref [] in 
	for i = 0 to pred desired do
      let marker = offset +. ((float_of_int i) *. distance_between_pointers) in 
      let rec walk lst = match lst with
		| [] -> (* error! should never happen! *) 
			debug "desired = %d\n" desired ; 
			debug "distance_between_pointers = %g\n" distance_between_pointers ;
			debug "offset = %g\n" offset ;
			debug "i = %d\n" i ; 
			debug "marker = %g\n" marker ;
			failwith "selection problem" 
		| (elt, acc) :: rest -> 
			if acc > marker then result := elt :: !result 
			else walk rest 
      in
		walk accumulated
	done ;
	!result 

(***********************************************************************
 * Genetic Programming Functions - Tournament Selection
 ***********************************************************************)
let tournament_k = ref 2 
let tournament_p = ref 1.00 

let tournament_selection (population : (individual * float) list) 
           (desired : int) 
           (* returns *) : individual list = 
  let p = !tournament_p in 
  assert ( desired >= 0 ) ; 
  assert ( !tournament_k >= 1 ) ; 
  assert ( p >= 0.0 ) ; 
  assert ( p <= 1.0 ) ; 
  assert ( List.length population > 0 ) ; 
  let rec select_one () = 
    (* choose k individuals at random *) 
    let lst = random_order population in 
    (* sort them *) 
    let pool = first_nth lst !tournament_k in 
    let sorted = List.sort (fun (_,f) (_,f') -> compare f' f) pool in 
    let rec walk lst step = match lst with
    | [] -> select_one () 
    | (indiv,fit) :: rest -> 
        let taken = 
          if p >= 1.0 then true
          else begin 
            let required_prob = p *. ((1.0 -. p)**(step)) in 
            Random.float 1.0 <= required_prob 
          end 
        in
        if taken then (indiv) else walk rest (step +. 1.0)
    in
    walk sorted 0.0
  in 
  let answer = ref [] in 
  for i = 1 to desired do
    answer := (select_one ()) :: !answer
  done ;
  !answer

(***********************************************************************
 * Genetic Programming Functions - AST-Changing Visitors
 ***********************************************************************)

(*
 * Three AST visitors used in crossover and mutation. 
 *)

class swapVisitor (file : Cil.file) 
                  (counters : counters) 
                  (to_swap : stmt_map) 
                  = object
  (* If (x,y) is in the to_swap mapping, we replace statement x 
   * with statement y. Presumably (y,x) is also in the mapping. *) 
  inherit nopCilVisitor
  method vstmt s = ChangeDoChildrenPost(s, fun s ->
      if Hashtbl.mem to_swap s.sid then begin
        let swap_with = Hashtbl.find to_swap s.sid in 
        let copy = copy swap_with in
        counters.swap <- counters.swap + 1 ; 
        { s with skind = copy } 
      end else s 
    ) 
end 


class appVisitor (file : Cil.file) 
                 (counters : counters) 
                 (to_append : stmt_map) 
                 = object
  (* If (x,y) is in the to_append mapping, we replace x with
   * the block { x; y; } -- that is, we append y after x. *) 
  inherit nopCilVisitor
  method vstmt s = ChangeDoChildrenPost(s, fun s ->
      if Hashtbl.mem to_append s.sid then begin
        let swap_with = Hashtbl.find to_append s.sid in 
        let copy = copy swap_with in
        let block = {
          battrs = [] ;
          bstmts = [ s ; { s with skind = copy ; } ];
        } in
        counters.ins <- counters.ins + 1 ; 
        { s with skind = Block(block) } 
      end else s 
    ) 
end 

class delVisitor (file : Cil.file) 
                 (counters : counters) 
                 (to_del : stmt_map) 
                 = object
  inherit nopCilVisitor
  (* If (x,_) is in the to_del mapping, we replace x with { } -- an
   * empty statement. *) 
  method vstmt s = ChangeDoChildrenPost(s, fun s ->
      if Hashtbl.mem to_del s.sid then begin
        let block = {
          battrs = [] ;
          bstmts = [] ; 
        } in
        counters.del <- counters.del + 1 ; 
        { s with skind = Block(block) } 
      end else begin 
        s 
      end 
    ) 
end 

(***********************************************************************
 * Genetic Programming Functions - Mutation
 ***********************************************************************)

let mutation_chance = ref 0.2 
let ins_chance = ref 1.0 
let del_chance = ref 1.0 
let swap_chance = ref 1.0 

(* This function randomly mutates an individual 'i'. 
 * Each statement in i's critical path has a 'prob' % chance of being
 * randomly changed. Does not change 'i' -- instead, it returns a new copy
 * for the mutated result. *) 
let rec mutation ?(force=false) (* require a mutation? *) 
             (i : individual) 
             (prob : float) 
             (* returns *) : individual =
  let (file,ht,count,path,track) = i in
  let new_track = copy track in 
  new_track.current.mut <- new_track.current.mut + 1 ;
  Stats2.time "mutation" (fun () -> 
  let any = ref false in (* any mutations made? *) 
  let to_swap = Hashtbl.create 255 in 
  let must_modify_step = ref None in 
  if force then begin
    match random_order path with
    | [] -> ()
    | (step_prob,path_step) :: tl -> must_modify_step := Some(path_step )
  end ; 
  List.iter (fun (step_prob,path_step) ->
    let forced = Some(path_step) = !must_modify_step in 
    if (probability step_prob && probability prob) || forced then begin
      (* Change this path element by replacing/appending/deleting it
       * with respect to a random element elsewhere anywhere in *the entire
       * file* (not just on the path). 
       *
       * Note that in each mutation run, each statement will only be 
       * considered once. If we're already swapping (55,33) and we later
       * come to 66 and decide to swap it with 33 as well, we instead do
       * nothing (since 33 is already being used). *)
      let replace_with_id = 1 + (Random.int (pred count)) 
      in 
      if (Hashtbl.mem to_swap replace_with_id || 
         Hashtbl.mem to_swap path_step) && not forced then
        ()
      else begin
        try 
          if not (Hashtbl.mem ht path_step) then begin
            debug "cannot find path_step %d in ht\n" path_step 
          end ; 
          if not (Hashtbl.mem ht replace_with_id) then begin
            debug "cannot find replace_with_id %d in ht\n" replace_with_id 
          end  ;
          let ss = Hashtbl.find ht path_step in 
          let rs = Hashtbl.find ht replace_with_id in 
          Hashtbl.add to_swap path_step rs ;
          Hashtbl.add to_swap replace_with_id ss ;
          (*
          debug "\t\tAdding path_Step = %d, replace_With_id = %d\n" 
            path_step replace_with_id ; 
            *)
          any := true ; 
        with _ -> ()
      end ;
    end 
  ) path ; 
  if !any then begin
    (* Actually apply the mutation to some number of elements of the path. 
     * The mutation is either a swap, an append or a delete. *) 
    let file = copy file in (* don't destroy the original *) 
    let r = Random.float (!ins_chance +. !del_chance +. !swap_chance) in 
    let v = 
      if r < !swap_chance then new swapVisitor
      else if r < !swap_chance +. !del_chance then new delVisitor
      else new appVisitor
    in 
    let my_visitor = v file new_track.current to_swap in 
    visitCilFileSameGlobals my_visitor file ; 
    file, ht, count, path, new_track
  end else begin
    if force then begin
      (match !must_modify_step with
      | None -> ()
      | Some(x) -> debug "must modify %d, did not\n" x
      ) ; 
      assert(not force);
    end ;
    (* unchanged: return original *) 
    file, ht, count, path, new_track 
  end 
  ) () 

(***********************************************************************
 * Genetic Programming Functions - Crossover 
 ***********************************************************************)

(* Our crossover function takes in two parents i1 and i2 and returns 
 * two children. It is a single-point crossover that uses the critical
 * paths of the parents. Currently we keep the paths of the parents equal
 * in length -- if a statement would be deleted from one parent, it is
 * actually replaced by a special null statement to keep the path lengths
 * the same. 
 *
 * Does not change the parents at all -- makes new copies for the 
 * children. *) 
let crossover (i1 : individual) 
              (i2: individual) 
              (* returns *) : (individual * individual) =
  let (file1,ht1,count1,path1,track1) = i1 in 
  let (file2,ht2,count2,path2,track2) = i2 in 
  let new_track1 = copy track1 in 
  let new_track2 = copy track2 in 
  track1.current.xover <- track1.current.xover + 1 ; 
  track2.current.xover <- track2.current.xover + 1 ; 
  Stats2.time "crossover" (fun () -> 
  let len1 = List.length path1 in 
  let len2 = List.length path2 in 
  assert(len1 = len2); 
  if (pred len1) == 0 then (* paths are 1! *)
	(i1, i2) 
  else
  let cutoff = 1 + (Random.int (pred len1)) in 
  (* 'cutoff' is our single crossover point *) 
  let where = ref 0 in  (* where are we in the path? *)
  let to_swap1 = Hashtbl.create 255 in 
  let to_swap2 = Hashtbl.create 255 in 
  (* we just implement crossover in terms of swapping, which we already
   * have for mutation *) 
  List.iter2 (fun (pr1,ps1) (pr2,ps2) ->
    begin 
    assert(pr1 = pr2); (* WRW, Mon Aug 18 17:27:57 EDT 2008 *) 
    if !where < cutoff then
      ()
    else begin
      try 
        if probability pr1 (* || probability pr2 *) then begin 
          let s1 = Hashtbl.find ht1 ps1 in 
          let s2 = Hashtbl.find ht2 ps2 in 
          Hashtbl.add to_swap1 ps1 s2 ;
          Hashtbl.add to_swap2 ps2 s1 ;
        end 
      with _ -> ()
    end 
    end ;
    incr where (* good catch, Vu *) 
  ) path1 path2 ; 
  let file1 = copy file1 in 
  let my_visitor1 = new swapVisitor file1 new_track1.current to_swap1 in 
  visitCilFileSameGlobals my_visitor1 file1 ; 
  let file2 = copy file2 in 
  let my_visitor2 = new swapVisitor file2 new_track2.current to_swap2 in 
  visitCilFileSameGlobals my_visitor2 file2 ; 
  (file1,ht1,count1,path1,new_track1) ,
  (file2,ht2,count2,path2,new_track2) 
  ) () 

(***********************************************************************
 * Genetic Programming Functions - Fitness 
 ***********************************************************************)

let gcc_cmd = ref "gcc" 
let ldflags = ref "" 
let good_cmd = ref "./test-good.sh" 
let bad_cmd = ref  "./test-bad.sh" 
let compile_counter = ref 0 (* how many _attempted_ compiles so far? *) 
let compile_fail = ref 0
let continue = ref false 
let input_params = ref ""
let max_fitness = ref 15 
let most_fit = ref None 
let baseline_file = ref "" 
let first_solution_at = ref 0. 
let first_solution_count = ref 0 
let fitness_count = ref 0 
let bad_factor = ref 10.0 

(* For web-based applications we need to pass a 'probably unused' port
 * number to the fitness-function shell scripts. This is a unix
 * implementation detail -- once you've started a server on port 8080, 
 * even if you kill your server another user program cannot bind to
 * that port for a few seconds. So if we want to run a thousand copies
 * of a webserver rapidly, we need to assign each one a new local port
 * number. *) 
let port = ref 808

(* Because fitness evaluation is so expensive, we cache (or memoize)
 * results. We cache not based on the internal AST data structure, but
 * on the serialized program text -- because two prorgrams with
 * different ASTs (say, different statement numbers) might actually print
 * the same way and thus yield the same results for the compiler. Instead,
 * we get the MD5 sum of the printed program text and use that as a cache
 * key. *) 
let fitness_ht : (Digest.t, float) Hashtbl.t = Hashtbl.create 255  

(* There is a fairly complicated interface between this function, which
 * calculates the fitness of a given individual, and ./test-good.sh and
 * ./test-bad.sh.
 *
 * You must write test-good.sh so that it takes 3 arguments
 *  1. the executable name (e.g., ./program-1.exe)
 *  2. a new text file to write each success to (e.g., ./good-1.txt) 
 *      -- for each successful testcase, write a line to this file.
 *         it doesn't matter what the line says, but by convention
 *         I write the name of the testcase there. 
 *  3. a port prefix (e.g., 808)
 *      -- if you are a webserver, you can safely uses 8080 to 8089 
 *         for yourself
 *
 * test-bad.sh works similarly. 
 *)
let total_avg = ref {ins = 0; del = 0; swap = 0; xover=0; mut = 0}
let total_fitness_evals = ref 0
let fitness (i : individual) 
            (* returns *) : float = 
  incr total_fitness_evals;
  let (file,ht,count,path,tracking) = i in 
  Stats2.time "fitness" (fun () -> 
  try 
    total_avg := {ins = !total_avg.ins + tracking.at_last_fitness.ins;
		      del = !total_avg.del + tracking.at_last_fitness.del;
		      swap = !total_avg.swap + tracking.at_last_fitness.swap;
		      xover = !total_avg.xover + tracking.at_last_fitness.xover;
		      mut = !total_avg.mut + tracking.at_last_fitness.mut;};
    debug "\t\t\ti=%d d=%d s=%d c=%d m=%d (delta i=%d d=%d s=%d c=%d m=%d)\n" 
      tracking.current.ins 
      tracking.current.del 
      tracking.current.swap 
      tracking.current.xover 
      tracking.current.mut 

    ( tracking.current.ins    -   tracking.at_last_fitness.ins   )
    ( tracking.current.del    -   tracking.at_last_fitness.del   )
    ( tracking.current.swap   -   tracking.at_last_fitness.swap  )
    ( tracking.current.xover  -   tracking.at_last_fitness.xover )
    ( tracking.current.mut    -   tracking.at_last_fitness.mut   ) ;
    tracking.at_last_fitness <- copy tracking.current ; 

    (**********
     * Fitness Step 1. Write out the C file from the in-memory AST. 
     *)
    let c = !compile_counter in
    incr compile_counter ; 
    let source_out = Printf.sprintf "%05d-file.c" c in 
    let fout = open_out source_out in 
    dumpFile defaultCilPrinter fout source_out file ;
    close_out fout ; 

    (**********
     * Fitness Step 2. Do we have it cached? 
     *)
    let digest = Digest.file source_out in 
    if Hashtbl.mem fitness_ht digest then begin
      let fitness = Hashtbl.find fitness_ht digest in 
		tracking.was_cached <- true;
      debug "\tfitness %g (cached)\n" fitness ; flush stdout ; 
      fitness 
    end else begin 
	  tracking.was_cached <- false;
    (**********
     * Fitness Step 3. Try to compile it. 
     *)
    let exe_name = Printf.sprintf "./%05d-prog" c in 
    let cmd = Printf.sprintf "%s -o %s %s %s >& /dev/null" !gcc_cmd exe_name source_out !ldflags in 
    (match Stats2.time "compile" Unix.system cmd with
    | Unix.WEXITED(0) -> ()
    | _ -> begin 
      (**********
       * Fitness Step 3b. It failed to compile! fitness = 0 
       *)
      (* printf "%s: does not compile\n" source_out ;  *)
	incr compile_fail;
      failwith "gcc failed"
    end ) ; 

    (**********
     * Fitness Step 4. Run the good and bad testcases. 
     *
     * We use 'good testcase' to represent the legitimate requirements 
     * testcases (e.g., "GET index.html should work") and 'bad testcase'
     * to represent the anomaly that we're trying to avoid. You 'pass' the
     * bad testcase if you aren't vulnerable to the exploit (or whatever). 
     *)
    let good_name = Printf.sprintf "%05d-good" c in 
    let bad_name  = Printf.sprintf "%05d-bad" c in 

    let port_arg = Printf.sprintf "%d" !port in
    incr port ; 
    (try Unix.unlink good_name with _ -> () ) ; 
    (try Unix.unlink bad_name with _ -> () ) ; 

    let cmd = Printf.sprintf "%s %s %s %s >& /dev/null" !good_cmd exe_name good_name port_arg in  
    (match Stats2.time "good test" Unix.system cmd with
    | Unix.WEXITED(0) -> ()
    | _ -> begin 
      (**********
       * Fitness Step 4b. The good testcase script failed to run.
       * 
       * This is different than 'you failed all the good testcases'. If you
       * fail all of the good testcases the test script terminates
       * successfully, but you get a 0-line good.txt file. This means that
       * that something went really really wrong, and it basically never
       * happens. 
       *) 
      debug "FAILED: %s\n" cmd ; failwith "good failed"
    end ) ; 

    let cmd = Printf.sprintf "%s %s %s %s >& /dev/null" !bad_cmd exe_name bad_name port_arg in 
    (match Stats2.time "bad test" Unix.system cmd with
    | Unix.WEXITED(0) -> ()
    | _ -> begin 
      (**********
       * Fitness Step 4c. The bad testcase script failed to run.
       *
       * See above. This never happens. 
       *) 
      debug "FAILED: %s\n" cmd ; failwith "bad failed"
    end ) ; 

    incr fitness_count ; (* total number of programs tested *) 

    (**********
     * Fitness Step 5. Read in the testcase script results. 
     *)
    let good = count_lines_in_file good_name in 
    let bad  = count_lines_in_file bad_name  in 
    let fitness = good +. (!bad_factor *. bad) in 
    (* We write a copy of the fitness results to a file in the directory
     * for easy debugging. *) 
    let fname = Printf.sprintf "%05d-fitness" c in 
    let fout = open_out fname in 
    Printf.fprintf fout "%g\n" fitness ;
    close_out fout ;
    debug "\tfitness %g\n" fitness ; flush stdout ; 

    (**********
     * Fitness Step 6. Is this a good-enough variant? 
     *)
    if fitness >= (float_of_int !max_fitness) then begin
      let size_str = Printf.sprintf "%05d-size" c in 
      (* we break ties in favor of the smallest 'diff' size *) 
      let cmd = Printf.sprintf "diff -e %s %s | wc -c > %s" 
        source_out !baseline_file size_str in 
      let our_size = (match Stats2.time "size diff" Unix.system cmd with
      | Unix.WEXITED(0) -> begin 
        try 
          let fin = open_in size_str in
          let line = input_line fin in
          close_in fin ;
          my_int_of_string line 
        with _ -> max_int 
      end 
      | _ -> max_int 
      ) in
      (* note when we got this variant for debugging purposes *) 
      let now = Unix.gettimeofday () in 
      let better = 
        match !most_fit with
        | None -> 
          first_solution_at := now ; 
          first_solution_count := !fitness_count ; 
          true
        | Some(best_size,best_fitness,_,_,_) -> 
          (our_size <= best_size) && 
          (fitness >= best_fitness) 
      in
      if better then begin 
        debug "\t\tbest so far (size delta %d)\n" our_size ; 
        flush stdout ; 
        most_fit := Some(our_size, fitness, file, now, !fitness_count) ;
        if not !continue then begin
          (* stop early now that we've found one *) 
          !print_best_output () ;
          Stats2.print stdout "Genetic Programming Prototype" ; 
          Stats2.print !debug_out "Genetic Programming Prototype" ; 
          exit 1 
        end 
      end 
    end ; 
    (* cache this result to save time later *) 
    Hashtbl.replace fitness_ht digest fitness ; 
    (* TODO: we can also cache non-compiling files as 0 *) 
    fitness 
    end 

  with _ -> 
    debug "\tfitness failure\n" ; flush stdout ; 0.
  ) () 

(***********************************************************************
 * Genetic Programming Functions - Initial Population 
 ***********************************************************************)

(* Return an initial population based on 'indiv'. This is currently just
 * that many mutations of indiv, each of which gets twice the normal
 * mutation chance. *)
let initial_population (indiv : individual) 
                       (num : int) 
                       (* returns *) : individual list= 
  let res = ref [indiv] in 
  for i = 2 to num do
    let (file,ht,count,path,track) = mutation ~force:true indiv (!mutation_chance *. 2.0) in 
    res := (file,ht,count,path,track) :: !res 
  done ;
  !res

(***********************************************************************
 * Genetic Programming Functions - One GP Generation  
 ***********************************************************************)

(* Do one GP generation, including selection, crossover and mutation. 
 * Actually produces desired_number * 2 new individuals. If the input
 * is two individuals X Y and the desired_number is 4, the output will be
 * (roughly):
 *
 * X
 * Y 
 * XY crossover child 1
 * XY crossover child 2
 * X mutated
 * Y mutated
 * XY crossover child 1 mutated
 * XY crossover child 2 mutated
 *) 
let gen_num = ref 0

let ga_step (original : individual) 
            (incoming_population : individual list) 
            (desired_number : int) 
	    (generation : int )
            (* returns *) : (individual list) 
            = 
  incr gen_num;
  assert(desired_number mod 2 = 0) ; 

  (**********
   * Generation Step 1. Determine Fitness. 
   *) 
  let pop_with_fitness = List.map (fun member ->
    let f = fitness member in
    (member,f)
  ) incoming_population in 

  (**********
   * Generation Step 2. Drop out 0-fitness individuals. 
   *) 
  let no_zeroes = ref (
    List.filter (fun (member,f) -> f > 0.) pop_with_fitness  
  ) in 
  assert(List.length !no_zeroes > 0) ; 

  (**********
   * Generation Step 3. If we're low, bring the population back up. 
   *) 

(* 
 * Old code for adding in default members. 
  while List.length !no_zeroes < desired_number do 
    let needed = desired_number - (List.length !no_zeroes) in
    if needed > 0 then  begin
      let more = initial_population original needed in
      let more = List.map (fun member ->
        let f = fitness member in
        (member,f)
      ) more in 
      let more = List.filter (fun (m,f) -> f > 0.) more in 
      no_zeroes := more @ !no_zeroes ; 
    end ; 
  done ;
  *)

  (* Currently we just duplicate the members that are left until we
   * have enough. Note that we may have more than enough when this is done.
   *)
    let to_double = 
      ref (if !favor_uncached then begin
	     List.filter
	       (fun (i, f) ->
		  let (file,ht,count,path,tracking) = i in
		    not (tracking.was_cached)
	       ) !no_zeroes
	   end
	   else !no_zeroes) in
      printf "Uncached individuals %d total individuals: %d\n" (List.length !to_double) (List.length !no_zeroes); flush stdout;
      to_double := if (List.length !to_double) > 0 then !to_double else !no_zeroes;
      let diff = (List.length !no_zeroes) - (List.length !to_double) in 
	while (List.length !to_double) + diff < desired_number do 
	  debug "\tViable Size %d; doubling\n" (List.length !to_double ) ; 
	  flush stdout ;
	  to_double := !to_double @ !to_double
	done ; 
	no_zeroes := !no_zeroes @ !to_double;
	
	printf "nozeroes is length %d\n" (List.length !no_zeroes);
  (**********
   * Generation Step 4. Sampling down to the best X/2
   *) 

  let counter = ref 0 in
  no_zeroes :=
    if !favor_uncached then begin
      List.map (fun (i,f) ->
		  let (file,ht,count,path,tracking) = i in
		    if(tracking.was_cached) then (i, f) else ((incr counter); (i,f+.5.0))) !no_zeroes;
      printf "incremented %d\n" !counter; !no_zeroes
    end else !no_zeroes;

    let breeding_population = 
      if !use_tournament then tournament_selection !no_zeroes (desired_number/2)
      else sample !no_zeroes (desired_number/2) 
    in 
      printf "Breeding population now %d\n" (List.length breeding_population); flush stdout;
	
      assert(List.length breeding_population = desired_number / 2) ; 

  let order = random_order breeding_population in

  (**********
   * Generation Step 5. Sampling down to X/2 
   *
   * The top half get to reproduce. 
   *) 
  let rec walk lst = match lst with
  | mom :: dad :: rest ->
	  let (file1,ht1,count1,path1,track1) = mom in
	  let (file2,ht2,count3,path2,track2) = dad in
		if ((pred (List.length path1)) > 4) then
		  let kid1,kid2 = crossover mom dad in 
			[ mom; dad; kid1 ; kid2 ] :: (walk rest)
		else 
		  [mom; dad;] :: (walk rest)
  | [] -> [] 
  | singleton -> [ singleton ; singleton ] 
  in 
  let result = walk order in
  let result : individual list = List.flatten result in
  let ref_result : individual list ref = ref result in

  (**********
   * Generation Step 6. Mutation
   *
   * For every current individual we consider it and a mutant of it.
   *)
    while (not ((List.length !ref_result) >= desired_number * 2)) do (* we do this instead of what we used to do for when
								      * we don't do crossover because the path is too short! *)
	  let temp_result = 
	    List.map (fun element ->  
			[element ; mutation element !mutation_chance ]
				     ) !ref_result in
	    ref_result := (List.flatten temp_result)
    done;
    Printf.printf "We have %d; we want %d\n" (List.length !ref_result) (desired_number * 2); flush stdout;
    assert(List.length !ref_result = desired_number * 2); 
  !ref_result 

(***********************************************************************
 * Genetic Programming Functions - Genetic Programming Main Loop
 ***********************************************************************)
let ga (indiv : individual) 
       (generations : int)    (* do this many generations *) 
       (num : int)            (* desired population size *) 
       (* returns *) : unit = 

  let population = ref (initial_population indiv num) in 

  for i = 1 to generations do
    debug "*** Generation %d (size %d)\n" i (List.length !population); 
    flush stdout ; 
    population := ga_step indiv !population num i
  done 

(***********************************************************************
 * Sanity Checking
 ***********************************************************************)
class sanityVisitor (file : Cil.file) 
                    (visited) 
                  = object
  (* If (x,y) is in the to_swap mapping, we replace statement x 
   * with statement y. Presumably (y,x) is also in the mapping. *) 
  inherit nopCilVisitor
  method vstmt s = ChangeDoChildrenPost(s, fun s ->
      Hashtbl.add visited s.sid true ; s
    ) 
end 


(* CBI functions. 
 * build_importance_table takes a file that contains the "importance" 
 * calculations produced by ./predicates -mi (short for modify-input). The 
 * format is filename,lineno,importance\n and the loc_ht that maps stmt ids
 * to locations and returns a hashtable mapping stmt ids to importance.
 *)

let build_importance_table cbi_file loc_ht : ('a, float) Hashtbl.t = 
  let retval_ht : ('a, float) Hashtbl.t = Hashtbl.create 10 in
  let fin = open_in cbi_file in
  let loc_to_imp = Hashtbl.create 10 in
  let _ =
    try 
      while true do
	let (filename::lineno::importance::rest) = 
	  (split comma_regexp (input_line fin)) in
	let lineno = int_of_string lineno in
	let importance = float_of_string importance in
	let loc = {file = filename; line = lineno; byte = 0} in
	  if Hashtbl.mem loc_to_imp loc then begin
	    if Hashtbl.find loc_to_imp loc < importance then
	      Hashtbl.replace loc_to_imp loc importance
	  end else
	    Hashtbl.add loc_to_imp loc importance
      done
    with _ -> ()
  in
    Hashtbl.iter 
      (fun stmt ->
	 fun loc1 ->
	   let loc2 = {file=loc1.file; line=loc1.line+1;byte=loc1.byte} in
	   let loc3 = {file=loc1.file; line=loc1.line-1;byte=loc1.byte} in
	   let (imp1, imp2, imp3) =
	     let one = 
	       try 
		 Hashtbl.find loc_to_imp loc1 
	       with Not_found -> 0.0 in
	     let two = 
	       try 
		 Hashtbl.find loc_to_imp loc2
	       with Not_found -> 0.0 in
	     let three = 
		 try 
		   Hashtbl.find loc_to_imp loc3
		 with Not_found -> 0.0 in
	       (one, two, three)
	   in
	   let add =
	     if imp1 > imp2 then
	       if imp1 > imp3 then imp1 else imp3
	     else if imp2 > imp3 then imp2 else imp3
	   in
	     if add > 0.0 then
	       Hashtbl.add retval_ht stmt add
      ) loc_ht;
    retval_ht
	  

(***********************************************************************
 * Genetic Programming Functions - Parse Command Line Arguments, etc. 
 ***********************************************************************)
let main () = begin
  let good_path_factor = ref 0.0 in 
  let generations = ref 10 in 
  let pop = ref 40 in 
  let proportional_mutation = ref 0.0 in
  let filename = ref "" in 
  let cbi_importance = ref "" in
  let use_cbi = ref false in
	Random.self_init () ; 
  (* By default we use and note a new random seed each time, but the user
   * can override that if desired for reproducibility. *) 
  let seed = ref (Random.bits ()) in  
  port := 800 + (Random.int 800) ; 

  let usageMsg = "Prototype No-Specification Bug-Fixer\n" in 

  let argDescr = [
    "--seed", Arg.Set_int seed, "X use X as random seed";
    "--gcc", Arg.Set_string gcc_cmd, "X use X to compile C files (def: 'gcc')";
    "--ldflags", Arg.Set_string ldflags, "X use X as LDFLAGS when compiling (def: '')";
    "--continue", Arg.Set continue, " continue after a repair is found (def: false)"; 
    "--good", Arg.Set_string good_cmd, "X use X as good-test command (def: './test-good.sh')"; 
    "--bad", Arg.Set_string bad_cmd, "X use X as bad-test command (def: './test-bad.sh')"; 
    "--gen", Arg.Set_int generations, "X use X genetic algorithm generations (def: 10)";
    "--bad_factor", Arg.Set_float bad_factor, "X multiply 'bad' testcases by X for utility (def: 10)";
    "--good_path_factor", Arg.Set_float good_path_factor, "X multiply probabilities for statements in good path";
    "--mut", Arg.Set_float mutation_chance,"X use X mutation chance (def: 0.2)"; 
    "--promut", Arg.Set_float proportional_mutation, " use proportional mutation with X expected changes (def: 0)";
    "--pop", Arg.Set_int pop,"X use population size of X (def: 40)"; 
    "--max", Arg.Set_int max_fitness,"X best fitness possible is X (def: 15)"; 

    "--ins", Arg.Set_float ins_chance,"X relative chance of mutation insertion (def: 1.0)"; 
    "--del", Arg.Set_float del_chance,"X relative chance of mutation deletion (def: 1.0)"; 
    "--swap", Arg.Set_float swap_chance,"X relative chance of mutation swap (def: 1.0)"; 
    "--uniqifier", Arg.Set_string input_params, "String to uniqify output best file";
    "--tour", Arg.Set use_tournament, " use tournament selection for sampling (def: false)"; 
    "--vn", Arg.Set_int v_debug, " X Vu's debug mode (def:" ^ (string_of_int !v_debug)^ ")"; (*v_*)
    "--cbi-path", Arg.Set_string cbi_importance, "X file containing CBI 'importance' ranks to weight path.";
	"--fcache", Arg.Set favor_uncached, "Favor uncached individuals when selecting for next generation.";
  ] in 
  (try
    let fin = open_in "ldflags" in
    ldflags := input_line fin ;
    close_in fin ;
  with _ -> () 
  ) ; 
  let handleArg str = filename := str in 
  Arg.parse (Arg.align argDescr) handleArg usageMsg ; 
  Cil.initCIL () ; 
  Random.init !seed ; 
  let start = Unix.gettimeofday () in 
  if !filename <> "" then begin
    (**********
     * Main Step 1. Read in all of the data files. 
     *) 
    debug "modify %s\n" !filename ; 
    let path_str = !filename ^ ".path" in 
    let goodpath_str = !filename ^ ".goodpath" in 
    let ht_str = !filename ^ ".ht" in 
    let ast_str = !filename ^ ".ast" in 

    (* using CBI "importance" ranks to weight the path *)
    let imp_ht = 
      if (not (!cbi_importance = "")) then begin
	let ht_loc_str = !filename ^ "_loc.ht" in
	let ht_fin = open_in_bin ht_loc_str in
	  use_cbi := true;
	  let loc_ht = Marshal.from_channel ht_fin in
	    build_importance_table !cbi_importance loc_ht
      end else Hashtbl.create 10 in
    let debug_str = !filename ^ "-" ^ !input_params ^ ".debug" in 
    debug_out := open_out debug_str ; 
    at_exit (fun () -> close_out !debug_out) ; 



    let file_fin = open_in_bin ast_str in 
    let (file : Cil.file) = Marshal.from_channel file_fin in
    close_in file_fin ; 
    debug "%s loaded\n" ast_str ; 
    let ht_fin = open_in_bin ht_str in 
    let count, ht = Marshal.from_channel ht_fin in
    close_in ht_fin ; 
    debug "%s loaded\n" ht_str ; 

    let gpath_ht = Hashtbl.create 255 in 
    let gpath_any = ref false in 

     (try
      let gpath_fin = open_in goodpath_str in 
      while true do
        let line = input_line gpath_fin in
        let i = my_int_of_string line in 
        gpath_any := true ;
        Hashtbl.add gpath_ht i () 
      done ;
      with _ -> ()
     ) ; 

    let path_fin = open_in path_str in 
    let path = ref [] in 
    let path_count = ref 0.0 in 
    (try
      while true do
        let line = input_line path_fin in
        let i = my_int_of_string line in 
        let prob = 
	  if !use_cbi then begin
	    if Hashtbl.mem imp_ht i then (* FIXME: do we want factors to be zero 
					  * or super-low if it's not not in the
					  * imp_ht? *)
	      Hashtbl.find imp_ht i
	    else 
	      
		  if Hashtbl.mem gpath_ht i
		  then !good_path_factor
		  else 0.3 
	  end
	  else begin
            if Hashtbl.mem gpath_ht i then
              !good_path_factor
            else
              1.0
	  end
        in 
        path_count := !path_count +. prob ; 
        path := (prob, (my_int_of_string line)) :: !path 
      done 
     with _ -> close_in path_fin) ; 

    let path = uniq( List.rev !path) in 
    debug "sanity checking\n" ; 

    let sanity_ht = Hashtbl.create 255 in
    let sanity = new sanityVisitor file sanity_ht in 
    visitCilFileSameGlobals sanity file ; 
    let any = ref false in 
    List.iter (fun (_,sid) ->
      if not (Hashtbl.mem sanity_ht sid) then begin
        any := true ;
        debug "\tStatment %d in path but not in AST\n" sid 
      end 
    ) path ;
    if !any then begin
      exit 1 ;
    end ; 



    let source_out = (!filename ^ "-baseline.c") in 
    baseline_file := source_out ; 
    let fout = open_out source_out in 
    dumpFile defaultCilPrinter fout source_out file ;
    close_out fout ; 
    debug "%s written\n" source_out ; 

    if !proportional_mutation > 0.0 then begin
      mutation_chance := !proportional_mutation /. !path_count
    end ; 

    (**********
     * Main Step 2. Write out the output. 
     *) 
    debug "version %s\n" version ; 
    debug "seed %d\n" !seed ; 
    debug "gcc %s\n" !gcc_cmd ; 
    debug "ldflags %s\n" !ldflags ; 
    debug "good %s\n" !good_cmd ; 
    debug "bad %s\n" !bad_cmd ; 
    debug "gen %d\n" !generations ; 
    debug "mut %g\n" !mutation_chance ; 
    debug "promut %g\n" !proportional_mutation ; 
    debug "pop %d\n" !pop ; 
    debug "max %d\n" !max_fitness ; 
    debug "ins %g\n" !ins_chance ; 
    debug "del %g\n" !del_chance ; 
    debug "swap %g\n" !swap_chance ; 
    debug "compile_counter %d\n" !compile_counter ; 
    debug "fitness_count %d\n" !fitness_count ; 
    debug "bad_factor %g\n" !bad_factor ; 
    debug "good_path_factor %g\n" !good_path_factor ; 
    debug "gpath_any %b\n" !gpath_any ; 
    debug "path_count %g\n" !path_count ; 
    debug "use_tournament %b\n" !use_tournament ; 
    debug "tournament_k %d\n" !tournament_k ; 
    debug "tournament_p %g\n" !tournament_p ; 

    (**********
     * Main Step 3. Do the genetic programming. 
     *) 
    let to_print_best_output () =



      (match !most_fit with
      | None -> debug "\n\nNo adequate program found.\n" 
      | Some(best_size, best_fitness, best_file, tau, best_count) -> begin
		  (*v_*)
		  debug "v_gen %d\n" (List.length !v_avg_fit_l);
		  debug "avgfit : "; List.iter(fun e -> debug "%g " e)(List.rev !v_avg_fit_l);debug "\n";
		  debug "bcfit : "; List.iter(fun e -> debug "%g " e)(List.rev !v_bc_fit_l);debug "\n";
		  flush !debug_out ;
		  (*v_*)

        let source_out = (!filename ^ "-" ^ !input_params ^ "-best.c") in 
        let fout = open_out source_out in 
        dumpFile defaultCilPrinter fout source_out best_file ;
        close_out fout ; 
        debug "\n\nBest result written to %s\n" source_out ; 
        debug "\tFirst Solution in %g (%d fitness evals)\n" 
          (!first_solution_at -. start) 
          !first_solution_count ; 
        debug "\tBest  Solution in %g (%d fitness evals)\n" (tau -. start) 
          best_count; 
	end) ;
      let ins_avg = float(!total_avg.ins) /. float(!total_fitness_evals) in
      let del_avg = float(!total_avg.del) /. float(!total_fitness_evals) in
      let swap_avg = float(!total_avg.swap) /. float(!total_fitness_evals) in
      let xover_avg = float(!total_avg.xover) /. float(!total_fitness_evals) in
      let mut_avg = float(!total_avg.mut) /. float(!total_fitness_evals) in
      let comp_fail = float(!fitness_count) /. float(!compile_counter) in
      debug "Generations to solution: %d\n" !gen_num;
      debug "Avg ins: %d/%d = %g\n" !total_avg.ins !total_fitness_evals ins_avg;
      debug "Avg del: %d/.. = %g\n" !total_avg.del del_avg;
      debug "Avg swap: %d/.. = %g\n" !total_avg.swap swap_avg; 
      debug "Avg xover: %d/.. = %g\n" !total_avg.xover xover_avg;
      debug "Avg mut: %d/.. = %g\n" !total_avg.mut mut_avg;
      debug "Percent failed to compile: %d/%d = %g\n" 
        !fitness_count !compile_counter comp_fail;
      flush !debug_out ;
    in 
    print_best_output := to_print_best_output ;

    ga (file,ht,count,path,new_tracking ()) !generations !pop;
    (* WRW: ga *does not return* *) 
    !print_best_output () ; 

  end ;
  Stats2.print stdout "Genetic Programming Prototype" ; 
  Stats2.print !debug_out "Genetic Programming Prototype" ; 
end ;;

main () ;; 
