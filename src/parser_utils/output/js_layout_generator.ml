(**
 * Copyright (c) 2013-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Layout


(* There are some cases where expressions must be wrapped in parens to eliminate
   ambiguity. We pass whether we're in one of these special cases down through
   the tree as we generate the layout. Note that these are only necessary as
   long as the ambiguity can exist, so emitting any wrapper (like a paren or
   bracket) is enough to reset the context back to Normal. *)
type expression_context = {
  left: expression_context_left;
  group: expression_context_group;
}
and expression_context_left =
  | Normal_left
  | In_expression_statement (* `(function x(){});` would become a declaration *)
  | In_tagged_template (* `(new a)``` would become `new (a``)` *)
  | In_plus_op (* `x+(+y)` would become `(x++)y` *)
  | In_minus_op (* `x-(-y)` would become `(x--)y` *)
and expression_context_group =
  | Normal_group
  | In_arrow_func (* `() => ({a: b})` would become `() => {a: b}` *)
  | In_for_init (* `for ((x in y);;);` would become a for-in *)

let normal_context = { left = Normal_left; group = Normal_group; }

(* Some contexts only matter to the left-most token. If we output some other
   token, like an `=`, then we can reset the context. Note that all contexts
   reset when wrapped in parens, brackets, braces, etc, so we don't need to call
   this in those cases, we can just set it back to Normal. *)
let context_after_token ctxt = { ctxt with left = Normal_left }

(* JS layout helpers *)
let not_supported loc message = failwith (message ^ " at " ^ Loc.to_string loc)
let with_semicolon node = fuse [node; Atom ";"]
let with_pretty_semicolon node = fuse [node; IfPretty (Atom ";", Empty)]
let wrap_in_parens item = list ~wrap:(Atom "(", Atom ")") [item]
let wrap_in_parens_on_break item = list
  ~wrap:(IfBreak (Atom "(", Empty), IfBreak (Atom ")", Empty))
  [item]
let statement_with_test name test body = fuse [
    Atom name;
    pretty_space;
    wrap_in_parens test;
    pretty_space;
    body;
  ]

let append_newline ~always node =
  let break = if always then Break_always else Break_if_pretty in
  Sequence ({ break; inline=(true, false); indent=0; }, [node])
let prepend_newline node =
  Sequence ({ break=Break_if_pretty; inline=(false, true); indent=0; }, [node])

let option f = function
  | Some v -> f v
  | None -> Empty

let deoptionalize l =
  List.rev (List.fold_left (fun acc -> function None -> acc | Some x -> x::acc) [] l)

(* See https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Operators/Operator_Precedence *)
let max_precedence = 20
let min_precedence = 1 (* 0 means always parenthesize, which is not a precedence decision *)
let precedence_of_assignment = 3
let precedence_of_expression expr =
  let module E = Ast.Expression in
  match expr with
  (* Expressions that don't involve operators have the highest priority *)
  | (_, E.Array _)
  | (_, E.Class _)
  | (_, E.Function _)
  | (_, E.Identifier _)
  | (_, E.JSXElement _)
  | (_, E.JSXFragment _)
  | (_, E.Literal _)
  | (_, E.Object _)
  | (_, E.Super)
  | (_, E.TemplateLiteral _)
  | (_, E.This) -> max_precedence

  (* Expressions involving operators *)
  | (_, E.Member _)
  | (_, E.MetaProperty _)
  | (_, E.New _) -> 19
  | (_, E.Call _)
  | (_, E.TaggedTemplate _)
  | (_, E.Import _) -> 18
  | (_, E.Update { E.Update.prefix = false; _ }) -> 17
  | (_, E.Update { E.Update.prefix = true; _ }) -> 16
  | (_, E.Unary _) -> 16
  | (_, E.Binary { E.Binary.operator; _ }) ->
    begin match operator with
    | E.Binary.Exp -> 15
    | E.Binary.Mult -> 14
    | E.Binary.Div -> 14
    | E.Binary.Mod -> 14
    | E.Binary.Plus -> 13
    | E.Binary.Minus -> 13
    | E.Binary.LShift -> 12
    | E.Binary.RShift -> 12
    | E.Binary.RShift3 -> 12
    | E.Binary.LessThan -> 11
    | E.Binary.LessThanEqual -> 11
    | E.Binary.GreaterThan -> 11
    | E.Binary.GreaterThanEqual -> 11
    | E.Binary.In -> 11
    | E.Binary.Instanceof -> 11
    | E.Binary.Equal -> 10
    | E.Binary.NotEqual -> 10
    | E.Binary.StrictEqual -> 10
    | E.Binary.StrictNotEqual -> 10
    | E.Binary.BitAnd -> 9
    | E.Binary.Xor -> 8
    | E.Binary.BitOr -> 7
    end
  | (_, E.Logical { E.Logical.operator = E.Logical.And; _ }) -> 6
  | (_, E.Logical { E.Logical.operator = E.Logical.Or; _ }) -> 5
  | (_, E.Conditional _) -> 4
  | (_, E.Assignment _) -> precedence_of_assignment
  | (_, E.Yield _) -> 2

  (* not sure how low this _needs_ to be, but it can at least be higher than 0
     because it binds tighter than a sequence expression. it must be lower than
     a member expression, though, because `()=>{}.x` is invalid. *)
  | (_, E.ArrowFunction _) -> 1

  | (_, E.Sequence _) -> 0

  (* Expressions that always need parens (probably) *)
  | (_, E.Comprehension _)
  | (_, E.Generator _)
  | (_, E.TypeCast _) -> 0

let definitely_needs_parens =
  let module E = Ast.Expression in

  let context_needs_parens ctxt expr =
    match ctxt with
    | { group = In_arrow_func; _ } ->
      (* an object body expression in an arrow function needs parens to not
         make it become a block with label statement. *)
      begin match expr with
      | (_, E.Object _) -> true
      | _ -> false
      end

    | { group = In_for_init; _ } ->
      (* an `in` binary expression in the init of a for loop needs parens to not
         make the for loop become a for-in loop. *)
      begin match expr with
      | (_, E.Binary { E.Binary.operator = E.Binary.In; _ }) -> true
      | _ -> false
      end

    | { left = In_expression_statement; _ } ->
      (* functions (including async functions, but not arrow functions) and
         classes must be wrapped in parens to avoid ambiguity with function and
         class declarations. objects must be also, to not be confused with
         blocks.

         https://tc39.github.io/ecma262/#prod-ExpressionStatement *)
      begin match expr with
      | _, E.Class _
      | _, E.Function _
      | _, E.Object _
      | _, E.Assignment { E.Assignment.
          left=(_, Ast.Pattern.Object _); _
        } -> true
      | _ -> false
      end

    | { left = In_tagged_template; _ } ->
      begin match expr with
      | _, E.Class _
      | _, E.Function _
      | _, E.New _
      | _, E.Import _
      | _, E.Object _ -> true
      | _ -> false
      end

    | { left = In_minus_op; _ } ->
      begin match expr with
      | _, E.Unary { E.Unary.operator = E.Unary.Minus; _ }
      | _, E.Update { E.Update.operator = E.Update.Decrement; prefix = true; _ }
        -> true
      | _ -> false
      end

    | { left = In_plus_op; _ } ->
      begin match expr with
      | _, E.Unary { E.Unary.operator = E.Unary.Plus; _ }
      | _, E.Update { E.Update.operator = E.Update.Increment; prefix = true; _ }
        -> true
      | _ -> false
      end

    | { left = Normal_left; group = Normal_group } -> false
  in

  fun ~precedence ctxt expr ->
    precedence_of_expression expr < precedence || context_needs_parens ctxt expr

(* TODO: this only needs to be shallow; we don't need to walk into function
   or class bodies, for example. *)
class contains_call_mapper result_ref = object
  inherit Flow_ast_mapper.mapper
  method! call _loc expr = result_ref := true; expr
end

let contains_call_expression expr =
  (* TODO: use a fold *)
  let result = ref false in
  let _ = (new contains_call_mapper result)#expression expr in
  !result

(* returns all of the comments that start before `loc`, and discards the rest *)
let comments_before_loc loc comments =
  let rec helper loc acc = function
  | ((c_loc, _) as comment)::rest when Loc.compare c_loc loc < 0 -> helper loc (comment::acc) rest
  | _ -> List.rev acc
  in
  helper loc [] comments

type statement_or_comment =
| Statement of Loc.t Ast.Statement.t
| Comment of Loc.t Ast.Comment.t

let better_quote =
  let rec count (double, single) str i =
    if i < 0 then (double, single) else
    let acc = match str.[i] with
    | '"' -> succ double, single
    | '\'' -> double, succ single
    | _ -> double, single
    in
    count acc str (pred i)
  in
  fun str ->
    let double, single = count (0, 0) str (String.length str - 1) in
    if double > single then "'" else "\""

let utf8_escape =
  let f ~quote buf _i = function
  | Wtf8.Malformed -> buf
  | Wtf8.Point cp ->
    begin match cp with
    (* SingleEscapeCharacter: http://www.ecma-international.org/ecma-262/6.0/#table-34 *)
    | 0x0 -> Buffer.add_string buf "\\0"; buf
    | 0x8 -> Buffer.add_string buf "\\b"; buf
    | 0x9 -> Buffer.add_string buf "\\t"; buf
    | 0xA -> Buffer.add_string buf "\\n"; buf
    | 0xB -> Buffer.add_string buf "\\v"; buf
    | 0xC -> Buffer.add_string buf "\\f"; buf
    | 0xD -> Buffer.add_string buf "\\r"; buf
    | 0x22 when quote = "\"" -> Buffer.add_string buf "\\\""; buf
    | 0x27 when quote = "'" -> Buffer.add_string buf "\\'"; buf
    | 0x5C -> Buffer.add_string buf "\\\\"; buf

    (* printable ascii *)
    | n when 0x1F < n && n < 0x7F ->
      Buffer.add_char buf (Char.unsafe_chr cp); buf

    (* basic multilingual plane, 2 digits *)
    | n when n < 0x100 ->
      Printf.bprintf buf "\\x%02x" n; buf

    (* basic multilingual plane, 4 digits *)
    | n when n < 0x10000 ->
      Printf.bprintf buf "\\u%04x" n; buf

    (* supplemental planes *)
    | n ->
      (* ES5 does not support the \u{} syntax, so print surrogate pairs
         "\ud83d\udca9" instead of "\u{1f4A9}". if we add a flag to target
         ES6, we should change this. *)
      let n' = n - 0x10000 in
      let hi = (0xD800 lor (n' lsr 10)) in
      let lo = (0xDC00 lor (n' land 0x3FF)) in
      Printf.bprintf buf "\\u%4x" hi;
      Printf.bprintf buf "\\u%4x" lo;
      buf
    end
  in
  fun ~quote str ->
    str
    |> Wtf8.fold_wtf_8 (f ~quote) (Buffer.create (String.length str))
    |> Buffer.contents

(* Generate JS layouts *)
let rec program ~preserve_docblock ~checksum (loc, statements, comments) =
  let nodes =
    if preserve_docblock && comments <> [] then
      let directives, statements = Ast_utils.partition_directives statements in
      let comments = match statements with
      | [] -> comments
      | (loc, _)::_ -> comments_before_loc loc comments
      in
      fuse_vertically ~inline:(true, true) (
        (combine_directives_and_comments directives comments)::
        (statements_list_with_newlines statements)
      )
    else
      fuse_vertically ~inline:(true, true) (
        statements_list_with_newlines statements
      )
  in
  let nodes = maybe_embed_checksum nodes checksum in
  let loc = { loc with Loc.start = { Loc.line = 1; column = 0; offset = 0; }} in
  SourceLocation (loc, nodes)

and combine_directives_and_comments directives comments : Layout.layout_node =
  let directives = List.map (fun ((loc, _) as x) -> loc, Statement x) directives in
  let comments = List.map (fun ((loc, _) as x) -> loc, Comment x) comments in
  let merged = List.merge (fun (a, _) (b, _) -> Loc.compare a b) directives comments in
  let nodes = List.map (function
    | loc, Statement s -> loc, statement ~allow_empty:true s
    | loc, Comment c -> loc, comment c
  ) merged in
  fuse_vertically ~inline:(true, true) (list_with_newlines nodes)

and maybe_embed_checksum nodes checksum = match checksum with
  | Some checksum ->
    let comment = Printf.sprintf "/* %s */" checksum in
    let fmt = { break=Break_always; inline=(false, true); indent=0; } in
    Sequence(fmt, [nodes; Atom comment])
  | None -> nodes

and comment (loc, comment) =
  let module C = Ast.Comment in
  SourceLocation (loc, match comment with
  | C.Block txt -> fuse [
      Atom "/*";
      prepend_newline (Atom txt);
      prepend_newline (Atom "*/");
    ]
  | C.Line txt -> fuse [
      Atom "//";
      append_newline ~always:true (Atom txt)
    ]
  )

and statement_list_with_locs ?allow_empty ?(pretty_semicolon=false) (stmts: Loc.t Ast.Statement.t list) =
  let rec mapper acc = function
  | [] -> List.rev acc
  | ((loc, _) as stmt)::rest ->
    let pretty_semicolon = pretty_semicolon && rest = [] in
    let acc = (loc, statement ?allow_empty ~pretty_semicolon stmt)::acc in
    (mapper [@tailcall]) acc rest
  in
  mapper [] stmts

and statement_list ?allow_empty ?pretty_semicolon (stmts: Loc.t Ast.Statement.t list) =
  stmts
  |> statement_list_with_locs ?allow_empty ?pretty_semicolon
  |> List.map (fun (_loc, layout) -> layout)

(**
 * Renders a statement
 *
 * Set `pretty_semicolon` when a semicolon is only required in pretty mode. For example,
 * a semicolon is never required on the last statement of a statement list, so we can set
 * `~pretty_semicolon:true` to only print the unnecessary semicolon in pretty mode.
 *)
and statement ?(allow_empty=false) ?(pretty_semicolon=false) ((loc, stmt): Loc.t Ast.Statement.t) =
  let module E = Ast.Expression in
  let module S = Ast.Statement in
  let with_semicolon = if pretty_semicolon then with_pretty_semicolon else with_semicolon in
  SourceLocation (
    loc,
    match stmt with
    | S.Empty -> if allow_empty then Atom ";" else IfPretty(Atom "{}", Atom ";")
    | S.Debugger -> with_semicolon (Atom "debugger")
    | S.Block b -> block (loc, b)
    | S.Expression { S.Expression.expression = expr; _ } ->
      let ctxt = { normal_context with left = In_expression_statement } in
      with_semicolon (expression_with_parens ~precedence:0 ~ctxt expr)
    | S.If { S.If.test; consequent; alternate; } ->
      begin match alternate with
      | Some alt ->
        fuse [
          statement_with_test "if" (expression test) (statement consequent);
          pretty_space;
          fuse_with_space [
            Atom "else";
            statement ~pretty_semicolon alt;
          ]
        ]
      | None ->
        statement_with_test "if" (expression test) (statement ~pretty_semicolon consequent)
      end
    | S.Labeled { S.Labeled.label; body } ->
      fuse [
        identifier label;
        Atom ":";
        pretty_space;
        statement body
      ]
    | S.Break { S.Break.label } ->
      let s_break = Atom "break" in
      with_semicolon (
        match label with
        | Some l -> fuse [s_break; space; identifier l]
        | None -> s_break;
      )
    | S.Continue { S.Continue.label } ->
      let s_continue = Atom "continue" in
      with_semicolon (
        match label with
        | Some l -> fuse [s_continue; space; identifier l]
        | None -> s_continue;
      )
    | S.With { S.With._object; body } ->
      statement_with_test "with" (expression _object) (statement body)
    | S.Switch { S.Switch.discriminant; cases } ->
      let case_nodes = match cases with
      | [] -> []
      | hd::[] -> [switch_case ~last:true hd]
      | hd::rest ->
        let rev_rest = List.rev rest in
        let last = List.hd rev_rest |> switch_case ~last:true in
        let middle = List.tl rev_rest |> List.map (switch_case ~last:false) in
        (switch_case ~last:false hd)::(List.rev (last::middle))
      in
      statement_with_test
        "switch"
        (expression discriminant)
        (list ~wrap:(Atom "{", Atom "}") ~break:Break_if_pretty case_nodes)
    | S.Return { S.Return.argument } ->
      let s_return = Atom "return" in
      with_semicolon (
        match argument with
        | Some arg ->
          let arg = match arg with
          | _, E.Logical _
          | _, E.Binary _
          | _, E.Sequence _
          | _, E.JSXElement _ ->
            wrap_in_parens_on_break (expression arg)
          | _ ->
            expression arg
          in
          fuse_with_space [s_return; arg]
        | None -> s_return;
      )
    | S.Throw { S.Throw.argument } ->
      with_semicolon (fuse_with_space [
        Atom "throw";
        wrap_in_parens_on_break (expression argument);
      ])
    | S.Try { S.Try.block=b; handler; finalizer } ->
      fuse [
        Atom "try";
        pretty_space;
        block b;
        (match handler with
        | Some (loc, { S.Try.CatchClause.param; body }) ->
          SourceLocation (loc, fuse [
            pretty_space;
            statement_with_test "catch"
              (pattern ~ctxt:normal_context param)
              (block body)
          ])
        | None -> Empty);
        match finalizer with
        | Some b ->
          fuse [
            pretty_space;
            Atom "finally";
            pretty_space;
            block b
          ]
        | None -> Empty
      ]
    | S.While { S.While.test; body } ->
      statement_with_test "while" (expression test) (statement ~pretty_semicolon body);
    | S.DoWhile { S.DoWhile.body; test } ->
      with_semicolon (fuse [
        fuse_with_space [
          Atom "do";
          statement body;
        ];
        pretty_space;
        Atom "while";
        pretty_space;
        wrap_in_parens (expression test)
      ])
    | S.For { S.For.init; test; update; body } ->
      fuse [
        Atom "for";
        pretty_space;
        list
          ~wrap:(Atom "(", Atom ")")
          ~sep:(Atom ";")
          ~trailing:false
          [
            begin match init with
            | Some (S.For.InitDeclaration decl) ->
              let ctxt = { normal_context with group = In_for_init } in
              variable_declaration ~ctxt decl
            | Some (S.For.InitExpression expr) ->
              let ctxt = { normal_context with group = In_for_init } in
              expression_with_parens ~precedence:0 ~ctxt expr
            | None -> Empty
            end;
            begin match test with
            | Some expr -> expression expr
            | None -> Empty
            end;
            begin match update with
            | Some expr -> expression expr
            | None -> Empty
            end;
          ];
        pretty_space;
        statement ~pretty_semicolon body;
      ]
    | S.ForIn { S.ForIn.left; right; body; each } ->
      fuse [
        Atom "for";
        if each then fuse [space; Atom "each"] else Empty;
        pretty_space;
        wrap_in_parens (fuse_with_space [
          begin match left with
          | S.ForIn.LeftDeclaration decl -> variable_declaration decl
          | S.ForIn.LeftPattern patt -> pattern patt
          end;
          Atom "in";
          expression right;
        ]);
        pretty_space;
        statement ~pretty_semicolon body;
      ]
    | S.FunctionDeclaration func -> function_ ~precedence:max_precedence func
    | S.VariableDeclaration decl ->
      with_semicolon (variable_declaration (loc, decl))
    | S.ClassDeclaration class_ -> class_base class_
    | S.ForOf { S.ForOf.left; right; body; async } ->
      fuse [
        Atom "for";
        if async then fuse [space; Atom "await"] else Empty;
        pretty_space;
        wrap_in_parens (fuse [
          begin match left with
          | S.ForOf.LeftDeclaration decl -> variable_declaration decl
          | S.ForOf.LeftPattern patt -> pattern patt
          end;
          space; Atom "of"; space;
          expression right;
        ]);
        pretty_space;
        statement ~pretty_semicolon body;
      ]
    | S.ImportDeclaration import -> import_declaration import
    | S.ExportNamedDeclaration export -> export_declaration export
    | S.ExportDefaultDeclaration export -> export_default_declaration export
    | S.TypeAlias typeAlias -> type_alias ~declare:false typeAlias
    | S.OpaqueType opaqueType -> opaque_type ~declare:false opaqueType
    | S.InterfaceDeclaration interface -> interface_declaration interface
    | S.DeclareClass interface -> declare_class interface
    | S.DeclareFunction func -> declare_function func
    | S.DeclareInterface interface -> declare_interface interface
    | S.DeclareVariable var -> declare_variable var
    | S.DeclareModuleExports typeAnnotation ->
      declare_module_exports typeAnnotation
    | S.DeclareModule m -> declare_module m
    | S.DeclareTypeAlias typeAlias -> type_alias ~declare:true typeAlias
    | S.DeclareOpaqueType opaqueType -> opaque_type ~declare:true opaqueType
    | S.DeclareExportDeclaration export -> declare_export_declaration export
  )

and expression ?(ctxt=normal_context) ((loc, expr): Loc.t Ast.Expression.t) =
  let module E = Ast.Expression in
  let precedence = precedence_of_expression (loc, expr) in
  SourceLocation (
    loc,
    match expr with
    | E.This -> Atom "this"
    | E.Super -> Atom "super"
    | E.Array { E.Array.elements } ->
      let last_element = (List.length elements) - 1 in
      list
        ~wrap:(Atom "[", Atom "]")
        ~sep:(Atom ",")
        (List.mapi
          (fun i e -> match e with
            | Some expr -> expression_or_spread ~ctxt:normal_context expr
            (* If the last item is empty it needs a trailing comma forced so to
               retain the same AST output. *)
            | None when i = last_element -> IfBreak (Empty, Atom ",")
            | None -> Empty
          )
          elements
        )
    | E.Object { E.Object.properties } ->
      list
        ~wrap:(Atom "{", Atom "}")
        ~sep:(Atom ",")
        (object_properties_with_newlines properties)
    | E.Sequence { E.Sequence.expressions } ->
      (* to get an AST like `x, (y, z)`, then there must've been parens
         around the right side. we can force that by bumping the minimum
         precedence. *)
      let precedence = precedence + 1 in
      list
        ~inline:(true, true)
        ~sep:(Atom ",")
        ~indent:0
        ~trailing:false
        (List.map (expression_with_parens ~precedence ~ctxt) expressions)
    | E.Identifier ident -> identifier ident
    | E.Literal lit -> literal (loc, lit)
    | E.Function func -> function_ ~precedence func
    | E.ArrowFunction func -> function_base ~ctxt ~precedence ~arrow:true func
    | E.Assignment { E.Assignment.operator; left; right } ->
      fuse [
        pattern ~ctxt left;
        pretty_space;
        E.Assignment.(match operator with
        | Assign -> Atom "="
        | PlusAssign -> Atom "+="
        | MinusAssign -> Atom "-="
        | MultAssign -> Atom "*="
        | ExpAssign -> Atom "**="
        | DivAssign -> Atom "/="
        | ModAssign -> Atom "%="
        | LShiftAssign -> Atom "<<="
        | RShiftAssign -> Atom ">>="
        | RShift3Assign -> Atom ">>>="
        | BitOrAssign -> Atom "|="
        | BitXorAssign -> Atom "^="
        | BitAndAssign -> Atom "&="
        );
        pretty_space;
        begin
          let ctxt = context_after_token ctxt in
          expression_with_parens ~precedence ~ctxt right
        end;
      ]
    | E.Binary { E.Binary.operator; left; right; } ->
      let module B = E.Binary in
      fuse_with_space [
        expression_with_parens ~precedence ~ctxt left;
        begin match operator with
        | B.Equal -> Atom "=="
        | B.NotEqual -> Atom "!="
        | B.StrictEqual -> Atom "==="
        | B.StrictNotEqual -> Atom "!=="
        | B.LessThan -> Atom "<"
        | B.LessThanEqual -> Atom "<="
        | B.GreaterThan -> Atom ">"
        | B.GreaterThanEqual -> Atom ">="
        | B.LShift -> Atom "<<"
        | B.RShift -> Atom ">>"
        | B.RShift3 -> Atom ">>>"
        | B.Plus -> Atom "+"
        | B.Minus -> Atom "-"
        | B.Mult -> Atom "*"
        | B.Exp -> Atom "**"
        | B.Div -> Atom "/"
        | B.Mod -> Atom "%"
        | B.BitOr -> Atom "|"
        | B.Xor -> Atom "^"
        | B.BitAnd -> Atom "&"
        | B.In -> Atom "in"
        | B.Instanceof -> Atom "instanceof"
        end;
        begin match operator, right with
        | E.Binary.Plus,
          (_, E.Unary { E.Unary.operator=E.Unary.Plus; _ })
        | E.Binary.Minus,
          (_, E.Unary { E.Unary.operator=E.Unary.Minus; _ })
          ->
          let ctxt = context_after_token ctxt in
          fuse [ugly_space; expression ~ctxt right]
        | E.Binary.Plus,
          (_, E.Unary { E.Unary.operator=E.Unary.Minus; _ })
        | E.Binary.Minus,
          (_, E.Unary { E.Unary.operator=E.Unary.Plus; _ })
          ->
          let ctxt = context_after_token ctxt in
          fuse [expression ~ctxt right]
        | (E.Binary.Plus | E.Binary.Minus),
          (_, E.Update { E.Update.prefix = true; _ })
          ->
          let ctxt = context_after_token ctxt in
          fuse [ugly_space; expression ~ctxt right]
        | _ ->
          (* to get an AST like `x + (y - z)`, then there must've been parens
             around the right side. we can force that by bumping the minimum
             precedence to not have parens. *)
          let precedence = precedence + 1 in
          let ctxt = { ctxt with left =
            match operator with
            | E.Binary.Minus -> In_minus_op
            | E.Binary.Plus -> In_plus_op
            | _ -> Normal_left
          } in
          expression_with_parens ~precedence ~ctxt right
        end;
      ]
    | E.Call { E.Call.callee; arguments } ->
      begin match callee, arguments with
      (* __d hack, force parens around factory function.
        More details at: https://fburl.com/b1wv51vj
        TODO: This is FB only, find generic way to add logic *)
      | (_, E.Identifier (_, "__d")), [a; b; c; d] ->
        fuse [
          Atom "__d";
          list
            ~wrap:(Atom "(", Atom ")")
            ~sep:(Atom ",")
            [
              expression_or_spread a;
              expression_or_spread b;
              wrap_in_parens (expression_or_spread c);
              expression_or_spread d;
            ]
        ]
      (* Standard call expression printing *)
      | _ ->
        fuse [
          expression_with_parens ~precedence ~ctxt callee;
          list
            ~wrap:(Atom "(", Atom ")")
            ~sep:(Atom ",")
            (List.map expression_or_spread arguments)
        ]
      end
    | E.Conditional { E.Conditional.test; consequent; alternate } ->
      let test_layout =
        (* conditionals are right-associative *)
        let precedence = precedence + 1 in
        expression_with_parens ~precedence ~ctxt test in
      list
        ~wrap:(fuse [test_layout; pretty_space], Empty)
        ~inline:(false, true)
        [
          fuse [
            Atom "?"; pretty_space;
            expression_with_parens ~precedence:min_precedence ~ctxt consequent
          ];
          fuse [
            Atom ":"; pretty_space;
            expression_with_parens ~precedence:min_precedence ~ctxt alternate
          ];
        ]
    | E.Logical { E.Logical.operator; left; right } ->
      let left = expression_with_parens ~precedence ~ctxt left in
      let operator = match operator with
        | E.Logical.Or -> Atom "||"
        | E.Logical.And -> Atom "&&"
      in
      let right = expression_with_parens ~precedence:(precedence + 1) ~ctxt right in

      (* if we need to wrap, the op stays on the first line, with the RHS on a
         new line and indented by 2 spaces *)
      fuse [
        left;
        pretty_space;
        operator;
        Sequence ({ break = Break_if_needed; inline = (false, true); indent = 2 }, [
          fuse [flat_pretty_space; right];
        ])
      ]
    | E.Member { E.Member._object; property; computed } ->
      fuse [
        begin match _object with
        | (_, E.Call _) -> expression ~ctxt _object
        | (_, E.Literal { Ast.Literal.value = Ast.Literal.Number num; raw }) when not computed ->
          (* 1.foo would be confused with a decimal point, so it needs parens *)
          number_literal ~in_member_object:true raw num
        | _ -> expression_with_parens ~precedence ~ctxt _object
        end;
        if computed then Atom "[" else Atom ".";
        begin match property with
        | E.Member.PropertyIdentifier (loc, id) -> SourceLocation (loc, Atom id)
        | E.Member.PropertyPrivateName (loc, (_, id)) -> SourceLocation (loc, Atom ("#" ^id))
        | E.Member.PropertyExpression expr -> expression ~ctxt expr
        end;
        if computed then Atom "]" else Empty;
      ]
    | E.New { E.New.callee; arguments } ->
      let callee_layout =
        if definitely_needs_parens ~precedence ctxt callee ||
           contains_call_expression callee
        then wrap_in_parens (expression ~ctxt callee)
        else expression ~ctxt callee
      in
      fuse [
        fuse_with_space [
          Atom "new";
          callee_layout;
        ];
        list
          ~wrap:(Atom "(", Atom ")")
          ~sep:(Atom ",")
          (List.map expression_or_spread arguments);
      ];
    | E.Unary { E.Unary.operator; prefix = _; argument } ->
      let s_operator, needs_space = begin match operator with
      | E.Unary.Minus -> Atom "-", false
      | E.Unary.Plus -> Atom "+", false
      | E.Unary.Not -> Atom "!", false
      | E.Unary.BitNot -> Atom "~", false
      | E.Unary.Typeof -> Atom "typeof", true
      | E.Unary.Void -> Atom "void", true
      | E.Unary.Delete -> Atom "delete", true
      | E.Unary.Await -> Atom "await", true
      end in
      let expr =
        let ctxt = { ctxt with left =
          match operator with
          | E.Unary.Minus -> In_minus_op
          | E.Unary.Plus -> In_plus_op
          | _ -> Normal_left
        } in
        expression_with_parens ~precedence ~ctxt argument
      in
      fuse [
        s_operator;
        if needs_space then begin match argument with
        | (_, E.Sequence _) -> Empty
        | _ -> space
        end else Empty;
        expr;
      ]
    | E.Update { E.Update.operator; prefix; argument } ->
      let s_operator = match operator with
      | E.Update.Increment -> Atom "++"
      | E.Update.Decrement -> Atom "--"
      in
      (* we never need to wrap `argument` in parens because it must be a valid
         left-hand side expression *)
      if prefix then fuse [s_operator; expression ~ctxt argument]
      else fuse [expression ~ctxt argument; s_operator]
    | E.Class class_ -> class_base class_
    | E.Yield { E.Yield.argument; delegate } ->
      fuse [
        Atom "yield";
        if delegate then Atom "*" else Empty;
        match argument with
        | Some arg -> fuse [space; expression ~ctxt arg]
        | None -> Empty
      ]
    | E.MetaProperty { E.MetaProperty.meta; property } ->
      fuse [
        identifier meta;
        Atom ".";
        identifier property;
      ]
    | E.TaggedTemplate { E.TaggedTemplate.tag; quasi=(loc, template) } ->
      let ctxt = { normal_context with left = In_tagged_template } in
      fuse [
        expression_with_parens ~precedence ~ctxt tag;
        SourceLocation (loc, template_literal template)
      ]
    | E.TemplateLiteral template -> template_literal template
    | E.JSXElement el -> jsx_element el
    | E.JSXFragment fr -> jsx_fragment fr
    | E.TypeCast { E.TypeCast.expression=expr; typeAnnotation } ->
      wrap_in_parens (fuse [
        expression expr;
        type_annotation typeAnnotation;
      ])
    | E.Import expr -> fuse [
        Atom "import";
        wrap_in_parens (expression expr);
      ]

    (* Not supported *)
    | E.Comprehension _
    | E.Generator _ -> not_supported loc "Comprehension not supported"
  )

and expression_with_parens ~precedence ~(ctxt:expression_context) expr =
  if definitely_needs_parens ~precedence ctxt expr
  then wrap_in_parens (expression ~ctxt:normal_context expr)
  else expression ~ctxt expr

and expression_or_spread ?(ctxt=normal_context) expr_or_spread =
  (* min_precedence causes operators that should always be parenthesized
     (they have precedence = 0) to be parenthesized. one notable example is
     the comma operator, which would be confused with additional arguments if
     not parenthesized. *)
  let precedence = min_precedence in
  match expr_or_spread with
  | Ast.Expression.Expression expr ->
    expression_with_parens ~precedence ~ctxt expr
  | Ast.Expression.Spread (loc, { Ast.Expression.SpreadElement.argument }) ->
    SourceLocation (loc, fuse [
      Atom "..."; expression_with_parens ~precedence ~ctxt argument
    ])

and identifier (loc, name) = Identifier (loc, name)

and number_literal ~in_member_object raw num =
  let str = Dtoa.shortest_string_of_float num in
  let if_pretty, if_ugly =
    if in_member_object then
      (* `1.foo` is a syntax error, but `1.0.foo`, `1e0.foo` and even `1..foo` are all ok. *)
      let is_int x = not (String.contains x '.' || String.contains x 'e') in
      let if_pretty = if is_int raw then wrap_in_parens (Atom raw) else Atom raw in
      let if_ugly = if is_int str then fuse [Atom str; Atom "."] else Atom str in
      if_pretty, if_ugly
    else
      Atom raw, Atom str
  in
  IfPretty (if_pretty, if_ugly)

and literal (loc, { Ast.Literal.raw; value; }) =
  let open Ast.Literal in
  SourceLocation (
    loc,
    match value with
    | Number num ->
      number_literal ~in_member_object:false raw num
    | String str ->
      let quote = better_quote str in
      fuse [Atom quote; Atom (utf8_escape ~quote str); Atom quote]
    | RegExp { RegExp.pattern; flags; } ->
      let flags = flags |> String_utils.to_list |> List.sort Char.compare |> String_utils.of_list in
      fuse [Atom "/"; Atom pattern; Atom "/"; Atom flags]
    | _ -> Atom raw
  )

and string_literal (loc, { Ast.StringLiteral.value; _ }) =
  let quote = better_quote value in
  SourceLocation (
    loc,
    fuse [Atom quote; Atom (utf8_escape ~quote value); Atom quote]
  )

and pattern_object_property_key = Ast.Pattern.Object.(function
  | Property.Literal lit -> literal lit
  | Property.Identifier ident -> identifier ident
  | Property.Computed expr ->
    list ~wrap:(Atom "[", Atom "]") [expression expr]
  )

and pattern ?(ctxt=normal_context) ((loc, pat): Loc.t Ast.Pattern.t) =
  let module P = Ast.Pattern in
  SourceLocation (
    loc,
    match pat with
    | P.Object { P.Object.properties; typeAnnotation } ->
      fuse [
        list
          ~wrap:(Atom "{", Atom "}")
          ~sep:(Atom ",")
          (List.map
            (function
            | P.Object.Property (loc, { P.Object.Property.
                key; pattern=pat; shorthand
              }) ->
              SourceLocation (loc,
                begin match pat, shorthand with
                (* Special case shorthand assignments *)
                | (_, P.Assignment _), true -> pattern pat
                (* Shorthand property *)
                | _, true -> pattern_object_property_key key
                (*  *)
                | _, false -> fuse [
                  pattern_object_property_key key;
                  Atom ":"; pretty_space;
                  pattern pat
                ]
                end;
              )
            | P.Object.RestProperty (loc, { P.Object.RestProperty.argument }) ->
              SourceLocation (loc, fuse [Atom "..."; pattern argument])
            )
            properties
          );
        option type_annotation typeAnnotation;
      ]
    | P.Array { P.Array.elements; typeAnnotation } ->
      fuse [
        list
          ~wrap:(Atom "[", Atom "]")
          ~sep:(Atom ",")
          (List.map
            (function
            | None -> Empty
            | Some P.Array.Element pat -> pattern pat
            | Some P.Array.RestElement (loc, { P.Array.RestElement.
                argument
              }) ->
              SourceLocation (loc, fuse [Atom "..."; pattern argument])
            )
            elements);
        option type_annotation typeAnnotation;
      ]
    | P.Assignment { P.Assignment.left; right } ->
      fuse [
        pattern left;
        pretty_space; Atom "="; pretty_space;
        begin
          let ctxt = context_after_token ctxt in
          expression_with_parens
            ~precedence:precedence_of_assignment
            ~ctxt right
        end;
      ]
    | P.Identifier { P.Identifier.name; typeAnnotation; optional } ->
      fuse [
        identifier name;
        if optional then Atom "?" else Empty;
        option type_annotation typeAnnotation;
      ]
    | P.Expression expr -> expression ~ctxt expr
  )

and template_literal { Ast.Expression.TemplateLiteral.quasis; expressions } =
  let module T = Ast.Expression.TemplateLiteral in
  let template_element i (loc, { T.Element.value={ T.Element.raw; _ }; tail }) =
    fuse [
      SourceLocation (loc, fuse [
        if i > 0 then Atom "}" else Empty;
        Atom raw;
        if not tail then Atom "${" else Empty;
      ]);
      if not tail then expression (List.nth expressions i) else Empty;
    ] in
  fuse [
    Atom "`";
    fuse (List.mapi template_element quasis);
    Atom "`";
  ]

and variable_declaration ?(ctxt=normal_context) (loc, {
  Ast.Statement.VariableDeclaration.declarations;
  kind;
}) =
  SourceLocation (loc, fuse [
    begin match kind with
    | Ast.Statement.VariableDeclaration.Var -> Atom "var"
    | Ast.Statement.VariableDeclaration.Let -> Atom "let"
    | Ast.Statement.VariableDeclaration.Const -> Atom "const"
    end;
    space;
    begin match declarations with
      | [single_decl] -> variable_declarator ~ctxt single_decl
      | _ ->
        list
          ~sep:(Atom ",")
          ~inline:(false, true)
          ~trailing:false
          (List.map (variable_declarator ~ctxt) declarations)
    end
  ]);

and variable_declarator ~ctxt (loc, {
  Ast.Statement.VariableDeclaration.Declarator.id;
  init;
}) =
  SourceLocation (
    loc,
    match init with
    | Some expr ->
      fuse [
        pattern ~ctxt id; pretty_space; Atom "="; pretty_space;
        expression_with_parens ~precedence:precedence_of_assignment ~ctxt expr;
      ];
    | None -> pattern ~ctxt id
  )

and function_ ?(ctxt=normal_context) ~precedence func =
  let { Ast.Function.id; generator; _ } = func in
  let s_func = fuse [
    Atom "function";
    if generator then Atom "*" else Empty;
  ] in
  function_base
    ~ctxt
    ~precedence
    ~id:(match id with
    | Some id -> fuse [s_func; space; identifier id]
    | None -> s_func
    )
    func

and function_base
  ~ctxt
  ~precedence
  ?(arrow=false)
  ?(id=Empty)
  { Ast.Function.
    params; body; async; predicate; returnType; typeParameters;
    expression=_; generator=_; id=_ (* Handled via `function_` *)
  } =
  fuse [
    if async then fuse [Atom "async"; space; id] else id;
    option type_parameter typeParameters;
    begin match arrow, params, returnType, predicate, typeParameters with
    | true, (_, { Ast.Function.Params.params = [(
      _,
      Ast.Pattern.Identifier {
        Ast.Pattern.Identifier.optional=false; typeAnnotation=None; _;
      }
    )]; rest = None}), None, None, None -> List.hd (function_params ~ctxt params)
    | _, _, _, _, _ ->
      list
        ~wrap:(Atom "(", Atom ")")
        ~sep:(Atom ",")
        (function_params ~ctxt:normal_context params)
    end;
    begin match returnType, predicate with
    | None, None -> Empty
    | None, Some pred -> fuse [Atom ":"; pretty_space; type_predicate pred]
    | Some ret, Some pred -> fuse [
        type_annotation ret;
        pretty_space;
        type_predicate pred;
      ]
    | Some ret, None -> type_annotation ret;
    end;
    if arrow then fuse [
        (* Babylon does not parse ():*=>{}` because it thinks the `*=` is an
           unexpected multiply-and-assign operator. Thus, we format this with a
           space e.g. `():* =>{}`. *)
        begin match returnType with
        | Some (_, (_, Ast.Type.Exists)) -> space
        | _ -> pretty_space
        end;
        Atom "=>";
    ] else Empty;
    pretty_space;
    begin match body with
    | Ast.Function.BodyBlock b -> block b
    | Ast.Function.BodyExpression expr ->
      let ctxt = if arrow then { normal_context with group=In_arrow_func }
      else normal_context in
      expression_with_parens ~precedence ~ctxt expr
    end;
  ]

and function_params ~ctxt (_, { Ast.Function.Params.params; rest }) =
  let s_params = List.map (pattern ~ctxt) params in
  match rest with
  | Some (loc, {Ast.Function.RestElement.argument}) ->
      let s_rest = SourceLocation (loc, fuse [
        Atom "..."; pattern ~ctxt argument
      ]) in
      List.append s_params [s_rest]
  | None -> s_params

and block (loc, { Ast.Statement.Block.body }) =
  SourceLocation (
    loc,
    if List.length body > 0 then
      body
      |> statement_list_with_locs ~allow_empty:true ~pretty_semicolon:true
      |> list_with_newlines
      |> list ~wrap:(Atom "{", Atom "}") ~break:Break_if_pretty
    else Atom "{}"
  )

and decorators_list decorators =
  if List.length decorators > 0 then
    list
      ~wrap:(Empty, flat_ugly_space)
      ~inline:(true, false)
      ~break:Break_if_pretty
      ~indent:0
      (List.map
        (fun expr -> fuse [
          Atom "@";
          begin
            (* Magic number, after `Call` but before `Update` *)
            let precedence = 18 in
            expression_with_parens ~precedence ~ctxt:normal_context expr;
          end;
        ])
        decorators
      )
  else Empty

and class_method (
  loc,
  { Ast.Class.Method.kind; key; value=(func_loc, func); static; decorators }
) =
  let module M = Ast.Class.Method in
  SourceLocation (loc, begin
    let s_key = object_property_key key in
    let s_key =
      let { Ast.Function.generator; _ } = func in
      fuse [if generator then Atom "*" else Empty; s_key;]
    in
    let s_key = match kind with
    | M.Constructor
    | M.Method -> s_key
    | M.Get -> fuse [Atom "get"; space; s_key]
    | M.Set -> fuse [Atom "set"; space; s_key]
    in
    fuse [
      decorators_list decorators;
      if static then fuse [Atom "static"; space] else Empty;
      SourceLocation (
        func_loc,
        function_base
          ~ctxt:normal_context
          ~precedence:max_precedence
          ~id:s_key
          func
      )
    ]
    end
  )

and class_property_helper loc key value static typeAnnotation variance =
  SourceLocation (loc, with_semicolon (fuse [
    if static then fuse [Atom "static"; space] else Empty;
    option variance_ variance;
    key;
    option type_annotation typeAnnotation;
    begin match value with
      | Some v -> fuse [
        pretty_space; Atom "="; pretty_space;
        expression_with_parens ~precedence:min_precedence ~ctxt:normal_context v;
      ]
      | None -> Empty
    end;
  ]))

and class_property (loc, { Ast.Class.Property.
  key; value; static; typeAnnotation; variance
}) =
  class_property_helper loc (object_property_key key) value static typeAnnotation variance

and class_private_field (loc, { Ast.Class.PrivateField.
  key = (ident_loc, ident); value; static; typeAnnotation; variance
}) =
  class_property_helper loc (identifier (ident_loc, "#" ^ (snd ident))) value static typeAnnotation
    variance

and class_body (loc, { Ast.Class.Body.body }) =
  if List.length body > 0 then
    SourceLocation (
      loc,
      list
        ~wrap:(Atom "{", Atom "}")
        ~break:Break_if_pretty
        (List.map
          (function
          | Ast.Class.Body.Method meth -> class_method meth
          | Ast.Class.Body.Property prop -> class_property prop
          | Ast.Class.Body.PrivateField field -> class_private_field field
          )
          body
        )
    )
  else Atom "{}"

and class_base { Ast.Class.
  id; body; superClass; typeParameters; superTypeParameters;
  implements; classDecorators
} =
  fuse [
    decorators_list classDecorators;
    Atom "class";
    begin match id with
    | Some ident -> fuse [
        space; identifier ident;
        option type_parameter typeParameters;
      ]
    | None -> Empty
    end;
    begin
      let class_extends = [
        begin match superClass with
        | Some super -> Some (fuse [
            Atom "extends"; space;
            expression super;
            option type_parameter_instantiation superTypeParameters;
          ])
        | None -> None
        end;
        begin match implements with
        | [] -> None
        | _ -> Some (fuse [
            Atom "implements"; space;
            fuse_list
              ~sep:(Atom ",")
              (List.map
                (fun (loc, { Ast.Class.Implements.id; typeParameters }) ->
                  SourceLocation (loc, fuse [
                    identifier id;
                    option type_parameter_instantiation typeParameters;
                  ])
                )
                implements
              )
          ])
        end;
      ] in
      match deoptionalize class_extends with
      | [] -> Empty
      | items ->
        list
          ~wrap:(flat_space, Empty)
          (* Ensure items are space separated when flat *)
          ~sep:flat_ugly_space
          ~trailing:false
          ~inline:(false, true)
          items
    end;
    pretty_space;
    class_body body;
  ]

(* given a list of (loc * layout node) pairs, insert newlines between the nodes when necessary *)
and list_with_newlines (nodes: (Loc.t * Layout.layout_node) list) =
  let (nodes, _) = List.fold_left (fun (acc, last_loc) (loc, node) ->
    let open Loc in
    let acc = match last_loc, node with
    (* empty line, don't add anything *)
    | _, Empty -> acc

    (* Lines are offset by more than one, let's add a line break *)
    | Some { Loc._end; _ }, node when _end.line + 1 < loc.start.line ->
      (prepend_newline node)::acc

    (* Hasn't matched, just add the node *)
    | _, node -> node::acc
    in
    acc, Some loc
  ) ([], None) nodes in
  List.rev nodes

and statements_list_with_newlines statements =
  statements
  |> List.map (fun (loc, s) -> loc, statement ~allow_empty:true (loc, s))
  |> list_with_newlines

and object_properties_with_newlines properties =
  let module E = Ast.Expression in
  let module O = E.Object in
  let rec has_function_decl = function
    | O.Property (_, O.Property.Init { value = v; _ }) ->
        begin match v with
        | (_, E.Function _)
        | (_, E.ArrowFunction _) -> true
        | (_, E.Object { O.properties }) ->
          List.exists has_function_decl properties
        | _ -> false
        end
    | O.Property (_, O.Property.Get _)
    | O.Property (_, O.Property.Set _) -> true
    | _ -> false
  in
  let (property_labels, _) =
    List.fold_left
      (
        fun (acc, last_p) p ->
          match (last_p, p) with
          | (None, _) -> (* Never on first line *)
            ((object_property p)::acc, Some (has_function_decl p))
          | (Some true, p) ->
            (
              (prepend_newline (object_property p))::acc,
              Some (has_function_decl p)
            )
          | (_, p) when has_function_decl p ->
            ((prepend_newline (object_property p))::acc, Some true)
          | _ -> ((object_property p)::acc, Some false)
      )
      ([], None)
      properties in
  List.rev property_labels

and object_property_key key =
  let module O = Ast.Expression.Object in
  match key with
  | O.Property.Literal lit -> literal lit
  | O.Property.Identifier ident -> identifier ident
  | O.Property.Computed expr ->
    list ~wrap:(Atom "[", Atom "]") [expression expr]
  | O.Property.PrivateName _ ->
     failwith "Internal Error: Found object prop with private name"

and object_property property =
  let module O = Ast.Expression.Object in
  match property with
  | O.Property (loc, O.Property.Init { key; value; shorthand }) ->
    SourceLocation (loc,
      let s_key = object_property_key key in
      if shorthand then s_key
      else fuse [
        s_key; Atom ":"; pretty_space;
        expression_with_parens ~precedence:min_precedence ~ctxt:normal_context value;
      ]
    )
  | O.Property (loc, O.Property.Method { key; value = (fn_loc, func) }) ->
    let s_key = object_property_key key in
    let { Ast.Function.generator; _ } = func in
    let precedence = max_precedence in
    let ctxt = normal_context in
    let g_key = fuse [
      if generator then Atom "*" else Empty;
      s_key;
    ] in
    SourceLocation (loc,
      SourceLocation (fn_loc, function_base ~ctxt ~precedence ~id:g_key func)
    )
  | O.Property (loc, O.Property.Get { key; value = (fn_loc, func) }) ->
    let s_key = object_property_key key in
    let precedence = max_precedence in
    let ctxt = normal_context in
    SourceLocation (loc,
      SourceLocation (fn_loc, fuse [
        Atom "get"; space;
        function_base ~ctxt ~precedence ~id:s_key func
      ])
    )
  | O.Property (loc, O.Property.Set { key; value = (fn_loc, func) }) ->
    let s_key = object_property_key key in
    let precedence = max_precedence in
    let ctxt = normal_context in
    SourceLocation (loc,
      SourceLocation (fn_loc, fuse [
        Atom "set"; space;
        function_base ~ctxt ~precedence ~id:s_key func
      ])
    )
  | O.SpreadProperty (loc, { O.SpreadProperty.argument }) ->
    SourceLocation (loc, fuse [Atom "..."; expression argument])

and jsx_element { Ast.JSX.openingElement; closingElement; children } =
  let processed_children = deoptionalize (List.map jsx_child children) in
  fuse [
    begin match openingElement with
    | (_, { Ast.JSX.Opening.selfClosing=false; _ }) ->
      jsx_opening openingElement;
    | (_, { Ast.JSX.Opening.selfClosing=true; _ }) ->
      jsx_self_closing openingElement;
    end;
    if List.length processed_children > 0 then
      Sequence ({ seq with break=Break_if_needed }, processed_children)
    else Empty;
    begin match closingElement with
    | Some closing -> jsx_closing closing
    | _ -> Empty
    end;
  ]

and jsx_fragment { Ast.JSX.frag_openingElement; frag_closingElement; frag_children } =
  let processed_children = deoptionalize (List.map jsx_child frag_children) in
  fuse [
    jsx_fragment_opening frag_openingElement;
    if List.length processed_children > 0 then
      Sequence ({ seq with break=Break_if_needed }, processed_children)
    else Empty;
    begin match frag_closingElement with
    | Some closing -> jsx_closing_fragment closing
    | _ -> Empty
    end;
  ]

and jsx_identifier (loc, { Ast.JSX.Identifier.name }) = Identifier (loc, name)

and jsx_namespaced_name (loc, { Ast.JSX.NamespacedName.namespace; name }) =
  SourceLocation (loc, fuse [
    jsx_identifier namespace;
    Atom ":";
    jsx_identifier name;
  ])

and jsx_member_expression (loc, { Ast.JSX.MemberExpression._object; property }) =
  SourceLocation (loc, fuse [
    begin match _object with
    | Ast.JSX.MemberExpression.Identifier ident -> jsx_identifier ident
    | Ast.JSX.MemberExpression.MemberExpression member ->
      jsx_member_expression member
    end;
    Atom ".";
    jsx_identifier property;
  ])

and jsx_expression_container { Ast.JSX.ExpressionContainer.expression=expr } =
  fuse [
    Atom "{";
    begin match expr with
    | Ast.JSX.ExpressionContainer.Expression expr -> expression expr
    | Ast.JSX.ExpressionContainer.EmptyExpression loc ->
      (* Potentally we will need to inject comments here *)
      SourceLocation (loc, Empty)
    end;
    Atom "}";
  ]

and jsx_attribute (loc, { Ast.JSX.Attribute.name; value }) =
  let module A = Ast.JSX.Attribute in
  SourceLocation (loc, fuse [
    begin match name with
    | A.Identifier ident -> jsx_identifier ident
    | A.NamespacedName name -> jsx_namespaced_name name
    end;
    begin match value with
    | Some v -> fuse [
      Atom "=";
      begin match v with
      | A.Literal (loc, lit) -> literal (loc, lit)
      | A.ExpressionContainer (loc, express) ->
        SourceLocation (loc, jsx_expression_container express)
      end;
    ]
    | None -> flat_ugly_space (* TODO we shouldn't do this for the last attr *)
    end;
  ])

and jsx_spread_attribute (loc, { Ast.JSX.SpreadAttribute.argument }) =
  SourceLocation (loc, fuse [
    Atom "{";
    Atom "...";
    expression argument;
    Atom "}";
  ])

and jsx_element_name = function
  | Ast.JSX.Identifier ident -> jsx_identifier ident
  | Ast.JSX.NamespacedName name -> jsx_namespaced_name name
  | Ast.JSX.MemberExpression member -> jsx_member_expression member

and jsx_opening_attr = function
  | Ast.JSX.Opening.Attribute attr -> jsx_attribute attr
  | Ast.JSX.Opening.SpreadAttribute attr -> jsx_spread_attribute attr

and jsx_opening (loc, { Ast.JSX.Opening.name; attributes; selfClosing=_ }) =
  jsx_opening_helper loc (Some name) attributes

and jsx_fragment_opening loc =
  jsx_opening_helper loc None []

and jsx_opening_helper loc nameOpt attributes =
  SourceLocation (loc, fuse [
    Atom "<";
    (match nameOpt with
    | Some name -> jsx_element_name name
    | None -> Empty);
    if List.length attributes > 0 then
      list
        ~wrap:(flat_space, Empty)
        ~inline:(false, true) (* put `>` on end of last attr *)
        (List.map jsx_opening_attr attributes)
    else Empty;
    Atom ">";
  ])

and jsx_self_closing (loc, { Ast.JSX.Opening.
  name; attributes; selfClosing=_
}) =
  SourceLocation (loc, fuse [
    Atom "<";
    jsx_element_name name;
    if List.length attributes > 0 then
      list
        ~wrap:(flat_space, flat_pretty_space)
        (List.map jsx_opening_attr attributes)
    else pretty_space;
    Atom "/>";
  ])

and jsx_closing (loc, { Ast.JSX.Closing.name }) =
  SourceLocation (loc, fuse [
    Atom "</";
    jsx_element_name name;
    Atom ">";
  ])

and jsx_closing_fragment loc =
  SourceLocation (loc, fuse [
    Atom "</>";
  ])

and jsx_child (loc, child) =
  match child with
  | Ast.JSX.Element elem -> Some (SourceLocation (loc, jsx_element elem))
  | Ast.JSX.Fragment frag -> Some (SourceLocation (loc, jsx_fragment frag))
  | Ast.JSX.ExpressionContainer express ->
    Some (SourceLocation (loc, jsx_expression_container express))
  | Ast.JSX.SpreadChild expr -> Some (SourceLocation (loc, fuse [
    Atom "{...";
    expression expr;
    Atom "}"
  ]))
  | Ast.JSX.Text { Ast.JSX.Text.raw; _ } ->
    begin match Utils_jsx.trim_jsx_text loc raw with
    | Some (loc, txt) -> Some (SourceLocation (loc, Atom txt))
    | None -> None
    end

and partition_specifiers default specifiers =
  let open Ast.Statement.ImportDeclaration in
  let special, named = match specifiers with
  | Some (ImportNamespaceSpecifier (loc, id)) ->
    [import_namespace_specifier (loc, id)], None
  | Some (ImportNamedSpecifiers named_specifiers) ->
    [], Some (import_named_specifiers named_specifiers)
  | None ->
    [], None
  in
  match default with
  | Some default -> (identifier default)::special, named
  | None -> special, named

and import_namespace_specifier (loc, id) =
  SourceLocation (loc, fuse [
    Atom "*"; pretty_space; Atom "as"; space; identifier id
  ])

and import_named_specifier { Ast.Statement.ImportDeclaration.
  kind; local; remote
} =
  fuse [
    Ast.Statement.ImportDeclaration.(match kind with
    | Some ImportType -> fuse [Atom "type"; space]
    | Some ImportTypeof -> fuse [Atom "typeof"; space]
    | Some ImportValue
    | None -> Empty
    );
    identifier remote;
    match local with
    | Some id -> fuse [
      space;
      Atom "as";
      space;
      identifier id;
    ]
    | None -> Empty
  ]

and import_named_specifiers named_specifiers =
  list
    ~wrap:(Atom "{", Atom "}")
    ~sep:(Atom ",")
    (List.map import_named_specifier named_specifiers)

and import_declaration { Ast.Statement.ImportDeclaration.
  importKind; source; specifiers; default
} =
  let s_from = fuse [Atom "from"; pretty_space;] in
  let module I = Ast.Statement.ImportDeclaration in
  with_semicolon (fuse [
    Atom "import";
    begin match importKind with
    | I.ImportType -> fuse [space; Atom "type"]
    | I.ImportTypeof -> fuse [space; Atom "typeof"]
    | I.ImportValue -> Empty
    end;
    begin match partition_specifiers default specifiers, importKind with
    (* No export specifiers *)
    (* `import 'module-name';` *)
    | ([], None), I.ImportValue -> pretty_space
    (* `import type {} from 'module-name';` *)
    | ([], None), (I.ImportType | I.ImportTypeof) ->
      fuse [pretty_space; Atom "{}"; pretty_space; s_from]
    (* Only has named specifiers *)
    | ([], Some named), _ -> fuse [
      pretty_space; named; pretty_space; s_from;
    ]
    (* Only has default or namedspaced specifiers *)
    | (special, None), _ -> fuse [
      space;
      fuse_list ~sep:(Atom ",") special;
      space;
      s_from;
    ]
    (* Has both default or namedspaced specifiers and named specifiers *)
    | (special, Some named), _ -> fuse [
      space;
      fuse_list ~sep:(Atom ",") (special@[named]);
      pretty_space;
      s_from;
    ]
    end;
    string_literal source;
  ])

and export_source ~prefix = function
  | Some lit -> fuse [
      prefix;
      Atom "from";
      pretty_space;
      string_literal lit;
    ]
  | None -> Empty

and export_specifier source = Ast.Statement.ExportNamedDeclaration.(function
  | ExportSpecifiers specifiers -> fuse [
      list
        ~wrap:(Atom "{", Atom "}")
        ~sep:(Atom ",")
        (List.map
          (fun (loc, { ExportSpecifier.local; exported }) -> SourceLocation (
            loc,
            fuse [
              identifier local;
              begin match exported with
              | Some export -> fuse [
                  space;
                  Atom "as";
                  space;
                  identifier export;
                ]
              | None -> Empty
              end;
            ]
          ))
          specifiers
        );
      export_source ~prefix:pretty_space source;
    ]
  | ExportBatchSpecifier (loc, Some ident) -> fuse [
      SourceLocation (loc, fuse [
        Atom "*";
        pretty_space;
        Atom "as";
        space;
        identifier ident;
       ]);
       export_source ~prefix:space source;
     ]
  | ExportBatchSpecifier (loc, None) -> fuse [
      SourceLocation (loc, Atom "*");
      export_source ~prefix:pretty_space source;
    ]
  )

and export_declaration { Ast.Statement.ExportNamedDeclaration.
  declaration; specifiers; source; exportKind
} =
  fuse [
    Atom "export";
    begin match declaration, specifiers with
    | Some decl, None -> fuse [space; statement decl]
    | None, Some specifier -> with_semicolon (fuse [
        begin match exportKind with
        | Ast.Statement.ExportType -> fuse [
            space;
            Atom "type";
          ]
        | Ast.Statement.ExportValue -> Empty
        end;
        pretty_space;
        export_specifier source specifier;
      ])
    | _, _ -> failwith "Invalid export declaration"
    end;
  ]

and export_default_declaration { Ast.Statement.ExportDefaultDeclaration.
 default=_; declaration
} =
  fuse [
    Atom "export"; space; Atom "default"; space;
    Ast.Statement.ExportDefaultDeclaration.(match declaration with
    | Declaration stat -> statement stat
    | Expression expr -> with_semicolon (expression expr)
    );
  ]

and variance_ (loc, var) =
  SourceLocation (
    loc,
    match var with
    | Ast.Variance.Plus -> Atom "+"
    | Ast.Variance.Minus -> Atom "-"
  )

and switch_case ~last (loc, { Ast.Statement.Switch.Case.test; consequent }) =
  let case_left = match test with
  | Some expr ->
    fuse_with_space [
      Atom "case";
      fuse [expression expr; Atom ":"]
    ]
  | None -> Atom "default:" in
  SourceLocation (
    loc,
    match consequent with
    | [] -> case_left
    | _ ->
      list
        ~wrap:(case_left, Empty)
        ~break:Break_if_pretty
        (statement_list ~pretty_semicolon:last consequent)
  )

and type_param (_, { Ast.Type.ParameterDeclaration.TypeParam.
  name = (loc, name); bound; variance; default
}) =
  fuse [
    option variance_ variance;
    SourceLocation (loc, Atom name);
    option type_annotation bound;
    begin match default with
    | Some t -> fuse [
        pretty_space;
        Atom "=";
        pretty_space;
        type_ t;
      ]
    | None -> Empty
    end;
  ]

and type_parameter (loc, { Ast.Type.ParameterDeclaration.params }) =
  SourceLocation (
    loc,
    list
      ~wrap:(Atom "<", Atom ">")
      ~sep:(Atom ",")
      (List.map type_param params)
  )

and type_parameter_instantiation (loc, { Ast.Type.ParameterInstantiation.
  params
}) =
  SourceLocation (
    loc,
    list
      ~wrap:(Atom "<", Atom ">")
      ~sep:(Atom ",")
      (List.map type_ params)
  )

and type_alias ~declare { Ast.Statement.TypeAlias.id; typeParameters; right } =
  with_semicolon (fuse [
    if declare then fuse [Atom "declare"; space;] else Empty;
    Atom "type"; space;
    identifier id;
    option type_parameter typeParameters;
    pretty_space; Atom "="; pretty_space;
    type_ right;
  ])

and opaque_type ~declare { Ast.Statement.OpaqueType.id; typeParameters; impltype; supertype} =
  with_semicolon (fuse ([
    if declare then fuse [Atom "declare"; space;] else Empty;
    Atom "opaque type"; space;
    identifier id;
    option type_parameter typeParameters]
    @ (match supertype with
    | Some t -> [Atom ":"; pretty_space; type_ t]
    | None -> [])
    @ (match impltype with
    | Some impltype -> [pretty_space; Atom "="; pretty_space; type_ impltype]
    | None -> [])))

and type_annotation (loc, t) =
  SourceLocation (loc, fuse [
    Atom ":";
    pretty_space;
    type_ t;
  ])

and type_predicate (loc, pred) =
  SourceLocation (loc, fuse [
    Atom "%checks";
    Ast.Type.Predicate.(match pred with
    | Declared expr -> wrap_in_parens (expression expr)
    | Inferred -> Empty
    );
  ])

and type_union_or_intersection ~sep ts =
  let sep = fuse [sep; pretty_space] in
  list
    ~inline:(false, true)
    (List.mapi
      (fun i t -> fuse [
        if i = 0 then IfBreak (sep, Empty) else sep;
        type_with_parens t;
      ])
      ts
    )

and type_function_param (loc, { Ast.Type.Function.Param.
  name; typeAnnotation; optional
}) =
  SourceLocation (loc, fuse [
    begin match name with
    | Some id -> fuse [
        identifier id;
        if optional then Atom "?" else Empty;
        Atom ":";
        pretty_space;
      ]
    | None -> Empty
    end;
    type_ typeAnnotation;
  ])

and type_function ~sep { Ast.Type.Function.
  params = (_, { Ast.Type.Function.Params.params; rest = restParams});
  returnType;
  typeParameters;
} =
  let params = List.map type_function_param params in
  let params = match restParams with
  | Some (loc, { Ast.Type.Function.RestParam.argument }) -> params@[
      SourceLocation (loc, fuse [Atom "..."; type_function_param argument]);
    ]
  | None -> params
  in
  fuse [
    option type_parameter typeParameters;
    list
      ~wrap:(Atom "(", Atom ")")
      ~sep:(Atom ",")
      params;
    sep;
    pretty_space;
    type_ returnType;
  ]

and type_object_property = Ast.Type.Object.(function
  | Property (loc, { Property.
      key; value; optional; static; variance; _method=_
    }) ->
    let s_static = if static then fuse [Atom "static"; space] else Empty in
    SourceLocation (
      loc,
      match value, variance, optional with
        (* Functions with no special properties can be rendered as methods *)
      | Property.Init (loc, Ast.Type.Function func), None, false ->
        SourceLocation (loc, fuse [
          s_static;
          object_property_key key;
          type_function ~sep:(Atom ":") func;
        ])
        (* Normal properties *)
      | Property.Init t, _, _ -> fuse [
          s_static;
          option variance_ variance;
          object_property_key key;
          if optional then Atom "?" else Empty;
          Atom ":";
          pretty_space;
          type_ t
        ]
        (* Getters/Setters *)
      | Property.Get (loc, func), _, _ -> SourceLocation (loc, fuse [
          Atom "get"; space;
          object_property_key key;
          type_function ~sep:(Atom ":") func;
        ])
      | Property.Set (loc, func), _, _ -> SourceLocation (loc, fuse [
          Atom "set"; space;
          object_property_key key;
          type_function ~sep:(Atom ":") func;
        ])
    )
  | SpreadProperty (loc, { SpreadProperty.argument }) ->
    SourceLocation (loc, fuse [
      Atom "...";
      type_ argument;
    ])
  | Indexer (loc, { Indexer.id; key; value; static; variance }) ->
    SourceLocation (loc, fuse [
      if static then fuse [Atom "static"; space] else Empty;
      option variance_ variance;
      Atom "[";
      begin match id with
      | Some id -> fuse [
          identifier id; Atom ":"; pretty_space;
        ]
      | None -> Empty
      end;
      type_ key;
      Atom "]"; Atom ":"; pretty_space;
      type_ value;
    ])
  | CallProperty (loc, { CallProperty.value=(call_loc, func); static }) ->
    SourceLocation (loc, fuse [
      if static then fuse [Atom "static"; space] else Empty;
      SourceLocation (call_loc, type_function ~sep:(Atom ":") func);
    ])
  )

and type_object ?(sep=(Atom ",")) { Ast.Type.Object.exact; properties } =
  let s_exact = if exact then Atom "|" else Empty in
  list
    ~wrap:(fuse [Atom "{"; s_exact], fuse [s_exact; Atom "}"])
    ~sep
    (List.map type_object_property properties)

and type_generic { Ast.Type.Generic.id; typeParameters } =
  let rec generic_identifier = Ast.Type.Generic.Identifier.(function
  | Unqualified id -> identifier id
  | Qualified (loc, { qualification; id }) ->
    SourceLocation (loc, fuse [
      generic_identifier qualification;
      Atom ".";
      identifier id;
    ])
  ) in
  fuse [
    generic_identifier id;
    option type_parameter_instantiation typeParameters;
  ]

and type_with_parens t =
  let module T = Ast.Type in
  match t with
  | (_, T.Function _)
  | (_, T.Union _)
  | (_, T.Intersection _) -> wrap_in_parens (type_ t)
  | _ -> type_ t

and type_ ((loc, t): Loc.t Ast.Type.t) =
  let module T = Ast.Type in
  SourceLocation (
    loc,
    match t with
    | T.Any -> Atom "any"
    | T.Mixed -> Atom "mixed"
    | T.Empty -> Atom "empty"
    | T.Void -> Atom "void"
    | T.Null -> Atom "null"
    | T.Number -> Atom "number"
    | T.String -> Atom "string"
    | T.Boolean -> Atom "boolean"
    | T.Nullable t ->
      fuse [
        Atom "?";
        type_with_parens t;
      ]
    | T.Function func ->
      type_function
        ~sep:(fuse [pretty_space; Atom "=>"])
        func
    | T.Object obj -> type_object obj
    | T.Array t -> fuse [type_ t; Atom "[]"]
    | T.Generic generic -> type_generic generic
    | T.Union (t1, t2, ts) ->
      type_union_or_intersection ~sep:(Atom "|") (t1::t2::ts)
    | T.Intersection (t1, t2, ts) ->
      type_union_or_intersection ~sep:(Atom "&") (t1::t2::ts)
    | T.Typeof t -> fuse [Atom "typeof"; space; type_ t]
    | T.Tuple ts ->
      list
        ~wrap:(Atom "[", Atom "]")
        ~sep:(Atom ",")
        (List.map type_ ts)
    | T.StringLiteral { Ast.StringLiteral.raw; _ }
    | T.NumberLiteral { Ast.NumberLiteral.raw; _ } -> Atom raw
    | T.BooleanLiteral value -> Atom (if value then "true" else "false")
    | T.Exists -> Atom "*"
  )

and interface_declaration_base ~def { Ast.Statement.Interface.
  id; typeParameters; body=(loc, obj); extends
} =
  fuse [
    def;
    identifier id;
    option type_parameter typeParameters;
    begin match extends with
    | [] -> Empty
    | _ -> fuse [
        space; Atom "extends"; space;
        fuse_list
          ~sep:(Atom ",")
          (List.map
            (fun (loc, generic) -> SourceLocation (loc, type_generic generic))
            extends
          )
      ]
    end;
    pretty_space;
    SourceLocation (loc, type_object ~sep:(Atom ",") obj)
  ]

and interface_declaration interface =
  interface_declaration_base ~def:(fuse [Atom "interface"; space]) interface

and declare_interface interface =
  interface_declaration_base ~def:(fuse [
    Atom "declare"; space;
    Atom "interface"; space;
  ]) interface

and declare_class ?(s_type=Empty) { Ast.Statement.DeclareClass.
  id; typeParameters; body=(loc, obj); extends; mixins=_; implements=_;
} =
  (* TODO: What are mixins? *)
  (* TODO: Print implements *)
  fuse [
    Atom "declare"; space;
    s_type;
    Atom "class"; space;
    identifier id;
    option type_parameter typeParameters;
    begin match extends with
    | None -> Empty
    | Some (loc, generic) -> fuse [
        space; Atom "extends"; space;
        SourceLocation (loc, type_generic generic)
      ]
    end;
    pretty_space;
    SourceLocation (loc, type_object ~sep:(Atom ",") obj)
  ]

and declare_function ?(s_type=Empty) { Ast.Statement.DeclareFunction.
  id; typeAnnotation=(loc, t); predicate
} =
  with_semicolon (fuse [
    Atom "declare"; space;
    s_type;
    Atom "function"; space;
    identifier id;
    SourceLocation (loc, match t with
    | loc, Ast.Type.Function func ->
      SourceLocation (loc, type_function ~sep:(Atom ":") func)
    | _ -> failwith "Invalid DeclareFunction"
    );
    begin match predicate with
    | Some pred -> fuse [pretty_space; type_predicate pred]
    | None -> Empty;
    end;
  ])

and declare_variable ?(s_type=Empty) { Ast.Statement.DeclareVariable.
  id; typeAnnotation
} =
  with_semicolon (fuse [
    Atom "declare"; space;
    s_type;
    Atom "var"; space;
    identifier id;
    option type_annotation typeAnnotation;
  ])

and declare_module_exports typeAnnotation =
  with_semicolon (fuse [
    Atom "declare"; space;
    Atom "module.exports";
    type_annotation typeAnnotation;
  ])

and declare_module { Ast.Statement.DeclareModule.id; body; kind=_ } =
  fuse [
    Atom "declare"; space;
    Atom "module"; space;
    begin match id with
    | Ast.Statement.DeclareModule.Identifier id -> identifier id
    | Ast.Statement.DeclareModule.Literal lit -> string_literal lit
    end;
    pretty_space;
    block body;
  ]

and declare_export_declaration { Ast.Statement.DeclareExportDeclaration.
  default; declaration; specifiers; source
} =
  let s_export = fuse [
    Atom "export"; space;
    if Option.is_some default then fuse [Atom "default"; space] else Empty;
  ] in
  match declaration, specifiers with
  | Some decl, None -> Ast.Statement.DeclareExportDeclaration.(match decl with
    (* declare export var *)
    | Variable (loc, var) ->
      SourceLocation (loc, declare_variable ~s_type:s_export var)
    (* declare export function *)
    | Function (loc, func) ->
      SourceLocation (loc, declare_function ~s_type:s_export func)
    (* declare export class *)
    | Class (loc, c) ->
      SourceLocation (loc, declare_class ~s_type:s_export c)
    (* declare export default [type]
     * this corresponds to things like
     * export default 1+1; *)
    | DefaultType t ->
      with_semicolon (fuse [
        Atom "declare"; space; s_export;
        type_ t;
      ])
    (* declare export type *)
    | NamedType (loc, typeAlias) ->
      SourceLocation (loc, fuse [
        Atom "declare"; space; s_export;
        type_alias ~declare:false typeAlias;
      ])
    (* declare export opaque type *)
    | NamedOpaqueType (loc, opaqueType) ->
      SourceLocation (loc, fuse [
        Atom "declare"; space; s_export;
        opaque_type ~declare:false opaqueType;
      ])
    (* declare export interface *)
    | Interface (loc, interface) ->
      SourceLocation (loc, fuse [
        Atom "declare"; space; s_export;
        interface_declaration interface;
      ])
    );
  | None, Some specifier -> fuse [
      Atom "declare"; space;
      Atom "export"; pretty_space;
      export_specifier source specifier;
    ]
  | _, _ -> failwith "Invalid declare export declaration"