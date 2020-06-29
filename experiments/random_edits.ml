open D1a
open Import
open Ast

module Make (Dom : Abstract.Dom) = struct
  (* Inline tests require a fixed random seed *)

  ;;
  Random.init 8675309

  module D = Daig.Make (Dom)
  module E = D.G.Edge
  module N = D.G.Node
  module Nm = Daig.Name

  let gen_expr () = failwith "todo"

  let gen_bool_expr () = failwith "todo"

  let gen_arith_expr () = failwith "todo"

  let gen_stmt () = failwith "todo"

  (** add an if-then-else construct to [daig] at location [l] *)
  let add_ite_at l ~cond ~if_stmt ~else_stmt daig =
    let l_ref, iter =
      match (D.ref_by_name (Nm.Loc l) daig, D.ref_by_name Nm.(Iterate (Loc l, 0)) daig) with
      | Some r, _ -> (r, fun n -> n)
      | _, Some r -> (r, fun n -> Nm.(Iterate (n, 0)))
      | None, None -> failwith "location does not exist"
    in
    let post_loc = Cfg.Loc.fresh () in
    let if_loc = Cfg.Loc.fresh () in
    let else_loc = Cfg.Loc.fresh () in
    let post_ref = D.Ref.AState { state = None; name = iter @@ Nm.Loc post_loc } in
    let if_ref = D.Ref.AState { state = None; name = iter @@ Nm.Loc if_loc } in
    let else_ref = D.Ref.AState { state = None; name = iter @@ Nm.Loc else_loc } in
    let if_post_ref = D.Ref.AState { state = None; name = iter @@ Nm.Prod (Idx 0, Loc post_loc) } in
    let else_post_ref =
      D.Ref.AState { state = None; name = iter @@ Nm.Prod (Idx 1, Loc post_loc) }
    in
    let assume_ref = D.Ref.Stmt { stmt = Stmt.Assume cond; name = Nm.Prod (Loc l, Loc if_loc) } in
    let assume_neg_ref =
      D.Ref.Stmt
        {
          stmt = Stmt.Assume (Expr.Unop { op = Unop.Not; e = cond });
          name = Nm.Prod (Loc l, Loc else_loc);
        }
    in
    let if_body_ref = D.Ref.Stmt { stmt = if_stmt; name = Nm.Prod (Loc if_loc, Loc post_loc) } in
    let else_body_ref =
      D.Ref.Stmt { stmt = else_stmt; name = Nm.Prod (Loc else_loc, Loc post_loc) }
    in
    (* first, shift outgoing edges from l to instead go from new location [post_loc] *)
    Seq.fold (N.outputs l_ref daig) ~init:daig ~f:(fun daig edge ->
        E.remove edge daig |> E.insert (E.create post_ref (E.dst edge) (E.label edge)))
    (* add "l -[assume cond]-> if_loc", "l -[assume !cond]-> else_loc" edges and refs *)
    |> N.insert assume_ref
    |> N.insert assume_neg_ref |> N.insert if_ref |> N.insert else_ref
    |> E.insert (E.create l_ref if_ref `Transfer)
    |> E.insert (E.create assume_ref if_ref `Transfer)
    |> E.insert (E.create l_ref else_ref `Transfer)
    |> E.insert (E.create assume_neg_ref else_ref `Transfer)
    (* add "if_loc -[if_stmt]-> 0*post_loc", "else_loc -[else_stmt]-> 1*post_loc", "post_loc <- 0*post_loc |_| 1*post_loc" *)
    |> N.insert if_post_ref
    |> N.insert else_post_ref |> N.insert if_body_ref |> N.insert else_body_ref
    |> E.insert (E.create if_body_ref if_post_ref `Transfer)
    |> E.insert (E.create if_ref if_post_ref `Transfer)
    |> E.insert (E.create else_body_ref else_post_ref `Transfer)
    |> E.insert (E.create else_ref else_post_ref `Transfer)
    |> E.insert (E.create if_post_ref post_ref `Join)
    |> E.insert (E.create else_post_ref post_ref `Join)

  let add_loop_at l ~cond ~body daig =
    let l_ref, contents =
      match (D.ref_by_name (Nm.Loc l) daig, D.ref_by_name Nm.(Iterate (Loc l, 0)) daig) with
      | Some (AState { state; name = _ } as r), None -> (r, state)
      | _ -> failwith "Can only insert loops in straightline code"
    in
    let body_loc = Cfg.Loc.fresh () in
    let exit_loc = Cfg.Loc.fresh () in
    let body_ref = D.Ref.AState { state = None; name = Nm.(Iterate (Loc body_loc, 0)) } in
    let exit_ref = D.Ref.AState { state = None; name = Nm.Loc exit_loc } in
    let l_zero_ref = D.Ref.AState { state = contents; name = Nm.(Iterate (Loc l, 0)) } in
    let l_one_ref = D.Ref.AState { state = None; name = Nm.(Iterate (Loc l, 1)) } in
    let prewiden_ref =
      D.Ref.AState { state = None; name = Nm.(Prod (Iterate (Loc l, 0), Iterate (Loc l, 1))) }
    in
    let assume_stmt_ref =
      D.Ref.Stmt { stmt = Stmt.Assume cond; name = Nm.Prod (Loc l, Loc body_loc) }
    in
    let assume_neg_stmt_ref =
      D.Ref.Stmt { stmt = Stmt.Assume (Expr.Unop {op = Unop.Not; e = cond}); name = Nm.Prod (Loc l, Loc exit_loc) }
    in
    let backedge_stmt_ref = D.Ref.Stmt { stmt = body; name = Nm.Prod (Loc body_loc, Loc l) } in
    (* first, shift incoming edges to l to instead go to its 0th iterate [l^(0)],
       and outgoing edges from l to instead go from the new [exit_loc] *)
    Seq.fold (N.inputs l_ref daig) ~init:daig ~f:(fun daig edge ->
        E.remove edge daig |> E.insert (E.create (E.src edge) l_zero_ref (E.label edge)))
    |> fun daig ->
    Seq.fold (N.outputs l_ref daig) ~init:daig ~f:(fun daig edge ->
        E.remove edge daig |> E.insert (E.create exit_ref (E.dst edge) (E.label edge)))
    (* next, add transfers for loop body and backedge *)
    |> N.insert assume_stmt_ref
    |> N.insert backedge_stmt_ref
    |> E.insert (E.create assume_stmt_ref body_ref `Transfer)
    |> E.insert (E.create l_zero_ref body_ref `Transfer)
    |> E.insert (E.create backedge_stmt_ref prewiden_ref `Transfer)
    |> E.insert (E.create body_ref prewiden_ref `Transfer)
    (* finally, widen l0 and prewiden to l1, fix l1 and l0 to l, and assume !cond to loop exit *)
    |> E.insert (E.create l_zero_ref l_one_ref `Widen)
    |> E.insert (E.create prewiden_ref l_one_ref `Widen)
    |> E.insert (E.create l_zero_ref l_ref `Fix)
    |> E.insert (E.create l_one_ref l_ref `Fix)
    |> N.insert assume_neg_stmt_ref
    |> E.insert (E.create l_ref exit_ref `Transfer)
    |> E.insert (E.create assume_neg_stmt_ref exit_ref `Transfer)
end

module RE = Make (Array_bounds)

let cond = Expr.Var "cond"

let stmt1 = Stmt.Assign { lhs = "lorem"; rhs = Expr.Lit (Lit.String "ipsum") }

let stmt2 = Stmt.Assign { lhs = "foo"; rhs = Expr.Lit (Lit.String "bar") }

let%test "add an ite before a while loop" =
  let cfg =
    Cfg_parser.(json_of_file >> cfg_of_json)
      "/Users/benno/Documents/CU/code/d1a/test_cases/while_syntax.js"
  in
  let daig = RE.D.of_cfg cfg in
  let edited_daig = RE.add_ite_at Cfg.Loc.entry ~cond ~if_stmt:stmt1 ~else_stmt:stmt2 daig in
  RE.D.dump_dot edited_daig ~filename:"/Users/benno/Documents/CU/code/d1a/edit_test1.dot";
  true

let%test "add an ite inside of a while loop" =
  let cfg =
    Cfg_parser.(json_of_file >> cfg_of_json)
      "/Users/benno/Documents/CU/code/d1a/test_cases/while_syntax.js"
  in
  let daig = RE.D.of_cfg cfg in
  let edited_daig =
    RE.add_ite_at Cfg.Loc.(of_int_unsafe 2) ~cond ~if_stmt:stmt1 ~else_stmt:stmt2 daig
  in
  RE.D.dump_dot edited_daig ~filename:"/Users/benno/Documents/CU/code/d1a/edit_test2.dot";
  true

let%test "add an ite inside of an ite" =
  let cfg =
    Cfg_parser.(json_of_file >> cfg_of_json)
      "/Users/benno/Documents/CU/code/d1a/test_cases/arith_syntax.js"
  in
  let daig = RE.D.of_cfg cfg in
  let edited_daig =
    RE.add_ite_at Cfg.Loc.(of_int_unsafe 3) ~cond ~if_stmt:stmt1 ~else_stmt:stmt2 daig
  in
  RE.D.dump_dot edited_daig ~filename:"/Users/benno/Documents/CU/code/d1a/edit_test3.dot";
  true

let%test "add a while inside of an ite" =
  let cfg =
    Cfg_parser.(json_of_file >> cfg_of_json)
      "/Users/benno/Documents/CU/code/d1a/test_cases/arith_syntax.js"
  in
  let daig = RE.D.of_cfg cfg in
  let edited_daig = RE.add_loop_at Cfg.Loc.(of_int_unsafe 3) ~cond ~body:stmt1 daig in
  RE.D.dump_dot edited_daig ~filename:"/Users/benno/Documents/CU/code/d1a/edit_test4.dot";
  true

let%test "add a while in straightline code" =
  let cfg =
    Cfg_parser.(json_of_file >> cfg_of_json)
      "/Users/benno/Documents/CU/code/d1a/test_cases/arith_syntax.js"
  in
  let daig = RE.D.of_cfg cfg in
  let edited_daig = RE.add_loop_at Cfg.Loc.(of_int_unsafe 1) ~cond ~body:stmt1 daig in
  RE.D.dump_dot edited_daig ~filename:"/Users/benno/Documents/CU/code/d1a/edit_test5.dot";
  true
