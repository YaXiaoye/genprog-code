(* Cheap Bug Isolation *)

open Printf
open Cil


let fprintf_va = makeVarinfo true "fprintf" (TVoid [])
let fopen_va = makeVarinfo true "fopen" (TVoid [])
let fflush_va = makeVarinfo true "fflush" (TVoid [])
let stderr_va = makeVarinfo true "_cbi_fout" (TPtr(TVoid [], []))
let fprintf = Lval((Var fprintf_va), NoOffset)
let fopen = Lval((Var fopen_va), NoOffset)
let fflush = Lval((Var fflush_va), NoOffset)
let stderr = Lval((Var stderr_va), NoOffset)

let site = ref 0

let label_count = ref 0

let variables : (Cil.varinfo, Cil.typsig) Hashtbl.t ref = ref (Hashtbl.create 10)
let global_variables = Hashtbl.create 10

(* maps counter numbers to a string describing the predicate *)

(* maps site numbers to location, scheme, and associated expression *)

let site_ht : (int, (Cil.location * string * Cil.exp)) Hashtbl.t = Hashtbl.create 10

let get_next_site scheme exp l = 
  let count = !site in
    incr site ;
	Hashtbl.add site_ht count (l,scheme,exp);
    count

(* predicates now mean "sites", more or less *)

let make_label () =
  let label = Printf.sprintf "claire_pred%d" !label_count in 
	incr label_count;
	Label(label,!currentLoc,false)

let print_str_stmt site_num condition = begin
  let str = Printf.sprintf "%d" site_num in 
  let str' = str^",%d\n" in 
  let str_exp = Const(CStr(str')) in 
  let instr = Call(None,fprintf,[stderr; str_exp;condition],!currentLoc) in
  let instr2 = Call(None,fflush,[stderr],!currentLoc) in
  let skind = Instr([instr;instr2]) in
  let ret_stmt = mkStmt skind in
	{ret_stmt with labels = [make_label()]}
end

let compare_value_zero exp bin_comp loc flush =
  let ret_typ = TInt(IInt,[]) in 
  let cond = BinOp(bin_comp,exp,zero,ret_typ) in
  let site = get_next_site "returns" cond loc in
  let str = Printf.sprintf "%d" site in 
  let str' = str^",%d\n" in 
  let str_exp = Const(CStr(str')) in 
  let instr = Call(None,fprintf,[stderr; str_exp;cond],!currentLoc) in
  let instr2 = Call(None,fflush,[stderr],!currentLoc) in
  let skind = if flush then Instr([instr;instr2]) else Instr([instr]) in
  let ret_stmt = mkStmt skind in
	{ret_stmt with labels = [make_label()]}


(*let conditionals_for_one_var myvarinfo mylval =
  let my_typ = typeSig myvarinfo.vtype in
  let to_compare : Cil.varinfo list = 
	Hashtbl.fold
	  (fun vi ->
		 fun vtypsig -> 
		   fun list_to_add ->
			 if (vtypsig = my_typ) && (not (vi.vname = myvarinfo.vname)) then
			   vi :: list_to_add
	   else list_to_add) !variables [] in
	List.map (* turns vars to add into a list of stmts. How convenient *)
	  (fun var_to_add -> if_else_if_else (Lval(Var(var_to_add),NoOffset)) mylval "scalar-pairs")
	  to_compare *)

(*let visit_instr (instr : instr) : stmt list = 
  match instr with
	  Set((Var(vi), off), e1, l) -> 
		conditionals_for_one_var vi (Lval(Var(vi),off))
	| Call(Some(Var(vi), off), e1, elist, l) ->
		conditionals_for_one_var vi (Lval(Var(vi), off))
	| _ -> []*)

class instrumentVisitor = object
  inherit nopCilVisitor

  method vstmt s = 
    ChangeDoChildrenPost
      (s, 
       fun s -> 
		 match s.skind with 
	    If(e1,b1,b2,l) -> 
	       let site_num = get_next_site "branches" e1 l in
	       let print_stmt = print_str_stmt site_num e1 in
	       let new_block = (Block(mkBlock [print_stmt;s])) in
			 mkStmt new_block
	   | Return(Some(e), l) -> 
		   let lt_stmt = compare_value_zero e Lt l false in
		   let gt_stmt = compare_value_zero e Gt l false in
		   let eq_stmt = compare_value_zero e Eq l true in
		   let new_block = (Block (mkBlock[lt_stmt;gt_stmt;eq_stmt;s])) in
		     mkStmt new_block 
	   | _ -> s)
		   (*  | Instr(ilist) -> (* Partial.callsEndBasicBlocks *should* (by its 
								own documentation?) put calls in their own blocks.
								If not, more hackery will be required. *)
			   let new_stmts : stmt list = 
				 List.fold_left
				   (fun (accum : stmt list) ->
					  fun (i : instr) ->
						(visit_instr i) @ accum
				   ) [] ilist 
			   in
			   let new_block = (Block(mkBlock (s::new_stmts))) in
				 mkStmt new_block*)
      

(*  method vfunc fdec =
	(* first, get a fresh version of the variables hash table *)
	variables := Hashtbl.copy global_variables;
	(* next, replace all variables in the hashtable with their name and type from here *)
	List.iter 
	  (fun v -> Hashtbl.replace !variables v (typeSig v.vtype))
	  (fdec.sformals @ fdec.slocals);
	DoChildren*)
end

let my_visitor = new instrumentVisitor

let main () = begin
  let usageMsg = "Prototype Cheap Bug Isolation Instrumentation\n" in
  let filenames = ref [] in
  let argDescr = [ ] in
  let handleArg str = filenames := str :: !filenames in
    Arg.parse (Arg.align argDescr) handleArg usageMsg ;

    Cil.initCIL();

	let files = List.map 
	  (fun filename -> 
		 let file = Frontc.parse filename () in
		   Partial.calls_end_basic_blocks file;
		   Cfg.computeFileCFG file;
		   file) !filenames in
	  List.iter
		(fun file ->
		   List.iter 
			 (fun g ->
				match g with 
				  | GVarDecl(vi, l) -> Hashtbl.add global_variables vi (typeSig vi.vtype)
				  | GVar(vi, ii, l) -> Hashtbl.add global_variables vi (typeSig vi.vtype)
				  | _ -> ()) 
			 file.globals) files;

    List.iter 
      (fun file -> 
		 begin
	       visitCilFileSameGlobals my_visitor file;
		   
		   let new_global = GVarDecl(stderr_va,!currentLoc) in 
			 file.globals <- new_global :: file.globals ;
			 
			 let fd = Cil.getGlobInit file in 
			 let lhs = (Var(stderr_va),NoOffset) in 
			 let data_str = file.fileName ^ ".preds" in 
			 let str_exp = Const(CStr(data_str)) in 
			 let str_exp2 = Const(CStr("wb")) in 
			 let instr = Call((Some(lhs)),fopen,[str_exp;str_exp2],!currentLoc) in 
			 let new_stmt = Cil.mkStmt (Instr[instr]) in 
			 let new_stmt = {new_stmt with labels = [make_label()]} in 
			   fd.sbody.bstmts <- new_stmt :: fd.sbody.bstmts ; 
			   iterGlobals file (fun glob ->
								   dumpGlobal defaultCilPrinter stdout glob ;
								) ; 
			   let sites = file.fileName ^ ".sites" in
			   let fout = open_out_bin sites in
				 Marshal.to_channel fout site_ht [] ;
				 close_out fout ;
		 end
      ) files;
end ;;

main () ;;
    
