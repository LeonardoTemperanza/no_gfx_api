
#+feature using-stmt
#+vet !unused-imports

package main

import "base:runtime"
import "core:fmt"
import str "core:strings"

typecheck_files :: proc(parse_tasks: ^[dynamic; MAX_FILES]Parse_Task, allocator: runtime.Allocator) -> bool
{
    add_intrinsics()

    res := true
    for &task in parse_tasks {
        res &= typecheck_ast_decls(&task.ast, task.file, task.module_name, task.is_main, allocator)
    }
    for &task in parse_tasks {
        res &= typecheck_ast_defs(&task.ast, task.file, allocator)
    }

    return res
}

typecheck_ast_decls :: proc(ast: ^Ast, file: File, module_name: string, is_module_main: bool, allocator: runtime.Allocator) -> bool
{
    context.allocator = allocator

    c := Checker {
        ast = ast,
        file = file,
        scope = ast.scope,
        error = false,
        cur_proc = nil,
        proc_ret = nil,
    }

    for decl in ast.scope.decls
    {
        switch decl.type.kind
        {
            case .Poison: {}
            case .None: {}
            case .Unknown: {}
            case .Proc:
            {
                decl.glsl_name = global_ident_to_glsl(decl.name, module_name, is_module_main)

                for arg in decl.type.args
                {
                    resolve_type(&c, arg.type)
                }

                if decl.type.ret != nil {
                    resolve_type(&c, decl.type.ret)
                }
            }
            case .Struct:
            {
                decl.glsl_name = global_ident_to_glsl(decl.name, module_name, is_module_main)

                for member in decl.type.members
                {
                    member.glsl_name = ident_to_glsl(member.name)
                    resolve_type(&c, member.type)
                }

                if len(decl.type.members) == 0 {
                    typecheck_error(&c, decl.token, "Empty structs aren't allowed.")
                }
            }
            case .Label, .Primitive, .Pointer, .Slice, .Array:
            {
                decl.glsl_name = global_ident_to_glsl(decl.name, module_name, is_module_main)
                resolve_type(&c, decl.type)
            }
        }
    }

    return !c.error
}

typecheck_ast_defs :: proc(ast: ^Ast, file: File, allocator: runtime.Allocator) -> bool
{
    context.allocator = allocator

    c := Checker {
        ast = ast,
        file = file,
        scope = ast.scope,
        error = false,
        cur_proc = nil,
        proc_ret = nil,
    }

    for global_var in ast.global_vars {
        typecheck_statement(&c, global_var)
    }

    for proc_def in ast.procs
    {
        c.cur_proc = proc_def

        for decl in proc_def.scope.decls
        {
            resolve_type(&c, decl.type)
            if decl.name == "pi" do fmt.println("changing")
            decl.glsl_name = ident_to_glsl(decl.name)

            if decl.attr != nil && decl.attr.?.type == .Data
            {
                if decl.type.kind != .Pointer && decl.type.kind != .Slice {
                    typecheck_error(&c, decl.token, "Variable declared with '@data' attribute must be of pointer or slice type.")
                }
            }
            if decl.attr != nil && decl.attr.?.type == .Indirect_Data
            {
                if decl.type.kind != .Pointer && decl.type.kind != .Slice {
                    typecheck_error(&c, decl.token, "Variable declared with '@indirect_data' attribute must be of pointer or slice type.")
                }
            }

            for decl_2 in proc_def.scope.decls
            {
                if decl_2.name == decl.name && raw_data(decl_2.token.text) < raw_data(decl.token.text)
                {
                    typecheck_error_redeclaration(&c, decl_2, decl)
                    break
                }
            }
        }

        old_scope := c.scope
        c.scope = proc_def.scope
        defer c.scope = old_scope

        c.proc_ret = nil

        for stmt in proc_def.statements {
            typecheck_statement(&c, stmt)
        }

        if c.proc_ret == nil && proc_def.decl.type.ret.kind != .None {
            typecheck_error(&c, proc_def.decl.token, "Missing return statement.")
        }
    }

    return !c.error
}

Checker :: struct #all_or_none
{
    ast: ^Ast,
    cur_proc: ^Ast_Proc_Def,
    scope: ^Ast_Scope,
    file: File,
    error: bool,
    proc_ret: ^Ast_Return,
}

typecheck_statement :: proc(using c: ^Checker, statement: ^Ast_Statement)
{
    switch stmt in statement.derived_statement
    {
        case ^Ast_Stmt_Expr:
        {
            typecheck_expr(c, stmt.expr)
        }
        case ^Ast_Assign:
        {
            typecheck_expr(c, stmt.lhs)
            if stmt.lhs.type.kind == .Poison do break
            typecheck_expr(c, stmt.rhs)
            if stmt.rhs.type.kind == .Poison do break

            if !check_assign_lhs(c, stmt.lhs) do break

            if stmt.apply_op
            {
                bin_op_type, ok := bin_op_result_type(stmt.bin_op, stmt.lhs.type, stmt.rhs.type)
                if !ok {
                    typecheck_error_mismatching_types(c, stmt.token, stmt.lhs.type, stmt.rhs.type)
                    break
                } else {
                    stmt.rhs.type = bin_op_type
                }
            }

            if !type_implicit_convert(stmt.rhs.type, stmt.lhs.type) {
                typecheck_error_mismatching_types(c, stmt.token, stmt.lhs.type, stmt.rhs.type)
            }
        }
        case ^Ast_Define_Var:
        {
            typecheck_expr(c, stmt.expr)
            if stmt.decl.glsl_name == "" {
                stmt.decl.glsl_name = ident_to_glsl(stmt.decl.name)
            }

            if stmt.expr.type.kind == .None
            {
                typecheck_error(c, stmt.expr.token, "Expression does not return value.")
                stmt.decl.type = &POISON_TYPE
            }
            else if stmt.decl.type.kind == .Unknown
            {
                if stmt.expr.type.primitive_kind == .Untyped_Int {
                    stmt.decl.type = &INT_TYPE
                } else if stmt.expr.type.primitive_kind == .Untyped_Float {
                    stmt.decl.type = &FLOAT_TYPE
                } else {
                    stmt.decl.type = stmt.expr.type
                }
            }
            else
            {
                if !type_implicit_convert(stmt.expr.type, stmt.decl.type) {
                    typecheck_error_mismatching_types(c, stmt.token, stmt.decl.type, stmt.expr.type)
                }
            }
        }
        case ^Ast_If:
        {
            typecheck_expr(c, stmt.cond)
            if stmt.cond.type.kind == .Poison do break

            if !type_implicit_convert(stmt.cond.type, &BOOL_TYPE) {
                typecheck_error_mismatching_types(c, stmt.token, stmt.cond.type, &BOOL_TYPE)
            }

            // Then
            {
                old_scope := scope
                scope = stmt.scope
                defer scope = old_scope

                resolve_scope_decls(c)
                typecheck_statement_list(c, stmt.statements)
            }
            // Else
            if stmt.else_is_present
            {
                old_scope := scope
                scope = stmt.scope
                defer scope = old_scope
                resolve_scope_decls(c)

                if stmt.else_is_single {
                    typecheck_statement(c, stmt.else_single)
                } else {
                    typecheck_statement_list(c, stmt.else_multi_statements)
                }
            }
        }
        case ^Ast_For:
        {
            old_scope := scope
            scope = stmt.scope
            defer scope = old_scope
            resolve_scope_decls(c)

            if stmt.define != nil do typecheck_statement(c, stmt.define)
            if stmt.cond != nil   do typecheck_expr(c, stmt.cond)
            if stmt.iter != nil   do typecheck_statement(c, stmt.iter)
            typecheck_statement_list(c, stmt.statements)
        }
        case ^Ast_Block:
        {
            old_scope := scope
            scope = stmt.scope
            defer scope = old_scope
            resolve_scope_decls(c)
            typecheck_statement_list(c, stmt.statements)
        }
        case ^Ast_Break:
        {
        }
        case ^Ast_Continue:
        {
        }
        case ^Ast_Discard:
        {
        }
        case ^Ast_Return:
        {
            c.proc_ret = stmt

            if stmt.expr != nil
            {
                typecheck_expr(c, stmt.expr)
                if stmt.expr.type.kind == .Poison do break

                if !type_implicit_convert(stmt.expr.type, cur_proc.decl.type.ret) {
                    typecheck_error_mismatching_types(c, stmt.token, stmt.expr.type, cur_proc.decl.type.ret)
                }
            }
            else
            {
                if cur_proc.decl.type.ret.kind != .None {
                    scratch, _ := acquire_scratch()
                    typecheck_error(c, stmt.token, "Procedure has '%v' return type, nothing is being returned here.", type_to_string(cur_proc.decl.type.ret, scratch))
                }
            }
        }
    }
}

typecheck_statement_list :: proc(using c: ^Checker, stmts: []^Ast_Statement)
{
    for stmt in stmts {
        typecheck_statement(c, stmt)
    }
}

typecheck_expr :: proc(using c: ^Checker, expression: ^Ast_Expr)
{
    expression.type = &POISON_TYPE
    scratch, _ := acquire_scratch()

    expr_switch: switch expr in expression.derived_expr
    {
        case ^Ast_Binary_Expr:
        {
            typecheck_expr(c, expr.lhs)
            typecheck_expr(c, expr.rhs)

            ok: bool
            expr.type, ok = bin_op_result_type(expr.op, expr.lhs.type, expr.rhs.type)
            if !ok {
                typecheck_error_mismatching_types(c, expr.token, expr.lhs.type, expr.rhs.type)
            }
        }
        case ^Ast_Unary_Expr:
        {
            typecheck_expr(c, expr.expr)

            ok: bool
            expr.type, ok = unary_op_result_type(expr.op, expr.expr.type)
            if !ok {
                typecheck_error(c, expr.token, "Can't apply operator '%v' on type '%v'.", expr.token.text, type_to_string(expr.expr.type, arena = scratch))
            }
        }
        case ^Ast_Ident_Expr:
        {
            decl := decl_lookup(scope, ast.imports[:], expr.token)
            if decl == nil
            {
                typecheck_error(c, expr.token, "Undeclared identifier '%v'.", expr.token.text)
            }
            else
            {
                expr.type = decl.type
                expr.glsl_name = decl.glsl_name
                switch decl.constness
                {
                    case .Runtime:  {}
                    case .Spectime: expr.is_const = true
                }
            }
        }
        case ^Ast_Lit_Expr:
        {
            if expr.token.type == .IntLit {
                expr.type = &UNTYPED_INT_TYPE
            } else if expr.token.type == .FloatLit {
                expr.type = &UNTYPED_FLOAT_TYPE
            } else if expr.token.type == .StrLit {
                expr.type = &STRING_TYPE
            } else if expr.token.type == .True {
                expr.type = &BOOL_TYPE
            } else if expr.token.type == .False {
                expr.type = &BOOL_TYPE
            }
        }
        case ^Ast_If_Expr:
        {
            typecheck_expr(c, expr.cond_expr)
            if expr.cond_expr.type.kind == .Poison do break

            if !type_implicit_convert(expr.cond_expr.type, &BOOL_TYPE) {
                typecheck_error_mismatching_types(c, expr.token, expr.cond_expr.type, &BOOL_TYPE)
            }

            typecheck_expr(c, expr.then_expr)
            typecheck_expr(c, expr.else_expr)
            if expr.then_expr.type.kind == .Poison do break
            if expr.else_expr.type.kind == .Poison do break
            expr.type = if_expr_result_type(expr.then_expr.type, expr.else_expr.type)
            if expr.type == &POISON_TYPE {
                typecheck_error(c, expr.token, "Types for then and else expressions are incompatible: '%v' and '%v'.", type_to_string(expr.then_expr.type, arena = scratch), type_to_string(expr.else_expr.type, arena = scratch))
            }
        }
        case ^Ast_Cast:
        {
            typecheck_expr(c, expr.expr)
            if expr.expr.type.kind == .Poison do break

            if !type_cast_allowed(expr.expr.type, expr.cast_to) {
                typecheck_error(c, expr.token, "Cast not allowed for these types: from '%v' to '%v'.", type_to_string(expr.expr.type, arena = scratch), type_to_string(expr.cast_to, arena = scratch))
            }
            expr.type = expr.cast_to
        }
        case ^Ast_Member_Access:
        {
            // Check module access
            target_ident, is_ident := expr.target.derived_expr.(^Ast_Ident_Expr)
            if is_ident
            {
                module := find_module(c, target_ident.token.text)
                if module != nil
                {
                    decl := decl_lookup(module.info.ast.scope, {}, expr.member, false)
                    if decl == nil {
                        typecheck_error(c, expr.member, "Undeclared identifier '%v' in module '%v'.", expr.member.text, module.module_name)
                    } else {
                        expr.type = decl.type
                    }

                    expr.is_module_access = true
                    expr.module_name = module.info.module_name
                    break
                }
            }

            typecheck_expr(c, expr.target)
            if expr.target.type.kind == .Poison do break

            // Check swizzle
            if expr.target.type.kind == .Primitive
            {
                type, is_swizzle := handle_vector_swizzle(expr.target.type, expr.member.text)
                if is_swizzle
                {
                    expr.type = type
                    expr.is_swizzle = true
                    break
                }
            }

            base := type_get_base(expr.target.type)
            if base.kind == .Poison do break

            if base.kind != .Struct {
                typecheck_error(c, expr.token, "Can't access members on type '%v'.", type_to_string(expr.target.type, arena = scratch))
                break
            }

            field_type := &POISON_TYPE
            for field in base.members
            {
                if field.name == expr.member.text
                {
                    field_type = field.type
                    break
                }
            }

            if field_type == &POISON_TYPE {
                typecheck_error(c, expr.token, "Member '%v' not found.", expr.member.text)
            }

            expr.type = field_type
            inherit_constness := expr.target.type.kind != .Pointer && expr.target.is_const
            expr.is_const = inherit_constness || (expr.target.type.kind == .Pointer && !expr.target.type.is_mut)
        }
        case ^Ast_Array_Access:
        {
            typecheck_expr(c, expr.target)
            typecheck_expr(c, expr.idx_expr)
            if expr.target.type.kind == .Poison do break
            if expr.idx_expr.type.kind == .Poison do break

            if expr.target.type.kind != .Slice && expr.target.type.kind != .Array {
                typecheck_error(c, expr.token, "Can't access array element of this type, it must be an array or slice.")
                expr.target.type = &POISON_TYPE
            }

            expr.type = expr.target.type.base
            inherit_constness := expr.target.type.kind != .Slice && expr.target.is_const
            expr.is_const = inherit_constness || (expr.target.type.kind == .Slice && !expr.target.type.is_mut)
        }
        case ^Ast_Call:
        {
            for arg in expr.args {
                typecheck_expr(c, arg)
                if arg.type.kind == .Poison do break expr_switch
            }

            // Handle intrinsics
            target, is_ident := expr.target.derived_expr.(^Ast_Ident_Expr)
            if is_ident
            {
                found, ok_l := intrinsic_lookup(c, target.token, expr.args)
                if !ok_l do break

                if found != nil
                {
                    expr.target.type = found.type
                    expr.type = found.type.ret

                    if target.token.text == "rayquery_init" ||
                       target.token.text == "rayquery_proceed" ||
                       target.token.text == "rayquery_candidate" ||
                       target.token.text == "rayquery_accept" ||
                       target.token.text == "rayquery_result" {
                        ast.used_features += { .Raytracing }
                    }

                    if target.token.text == "printf"
                    {
                        if !check_printf(c, expr) {
                            return
                        }
                    }

                    expr.glsl_name = found.glsl_name
                    break
                }
            }

            // Regular procedure calls

            typecheck_expr(c, expr.target)
            if expr.target.type.kind == .Poison do break

            if expr.target.type.kind != .Proc {
                typecheck_error(c, expr.token, "Can't call this type, must be a procedure.")
            }

            if len(expr.target.type.args) != len(expr.args) {
                typecheck_error(c, expr.token, "Incorrect number of arguments, expecting '%v', got '%v'.", len(expr.target.type.args), len(expr.args))
                break
            }

            for arg, i in expr.args
            {
                proc_decl_arg_type := expr.target.type.args[i].type

                if !type_implicit_convert(arg.type, proc_decl_arg_type) {
                    typecheck_error_mismatching_types(c, arg.token, arg.type, proc_decl_arg_type)
                }
            }

            expr.type = expr.target.type.ret
        }
    }
}

find_module :: proc(using c: ^Checker, s: string) -> ^Ast_Import
{
    for &module in ast.imports
    {
        if module.module_name == s {
            return &module
        }
    }
    return nil
}

POISON_TYPE := Ast_Type { kind = .Poison }
FLOAT_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Float, name = { text = "float" } }
UINT_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Uint, name = { text = "uint" } }
INT_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Int, name = { text = "int" } }
UNTYPED_FLOAT_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Untyped_Float, name = { text = "untyped float" } }
UNTYPED_INT_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Untyped_Int, name = { text = "untyped int" } }
VEC2_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Vector, base = &FLOAT_TYPE, dimensions = { 2, 1 }, name = { text = "vec2" } }
VEC3_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Vector, base = &FLOAT_TYPE, dimensions = { 3, 1 }, name = { text = "vec3" } }
VEC4_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Vector, base = &FLOAT_TYPE, dimensions = { 4, 1 }, name = { text = "vec4" } }
IVEC2_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Vector, base = &INT_TYPE, dimensions = { 2, 1 }, name = { text = "ivec2" } }
IVEC3_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Vector, base = &INT_TYPE, dimensions = { 3, 1 }, name = { text = "ivec3" } }
IVEC4_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Vector, base = &INT_TYPE, dimensions = { 4, 1 }, name = { text = "ivec4" } }
UVEC2_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Vector, base = &UINT_TYPE, dimensions = { 2, 1 }, name = { text = "uvec2" } }
UVEC3_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Vector, base = &UINT_TYPE, dimensions = { 3, 1 }, name = { text = "uvec3" } }
UVEC4_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Vector, base = &UINT_TYPE, dimensions = { 4, 1 }, name = { text = "uvec4" } }
BVEC2_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Vector, base = &BOOL_TYPE, dimensions = { 2, 1 }, name = { text = "bvec2" } }
BVEC3_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Vector, base = &BOOL_TYPE, dimensions = { 3, 1 }, name = { text = "bvec3" } }
BVEC4_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Vector, base = &BOOL_TYPE, dimensions = { 4, 1 }, name = { text = "bvec4" } }
BOOL_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Bool, name = { text = "bool" } }
TEXTURE_ID_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Texture_ID, name = { text = "texture_id" } }
TEXTURE_RW_ID_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Texture_RW_ID, name = { text = "texture_rw_id" } }
SAMPLER_ID_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Sampler_ID, name = { text = "sampler_id" } }
BVH_ID_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .BVH_ID, name = { text = "bvh_id" } }
MAT4_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Matrix, base = &FLOAT_TYPE, dimensions = { 4, 4 }, name = { text = "mat4" } }
MAT4x2_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Matrix, base = &FLOAT_TYPE, dimensions = { 4, 2 }, name = { text = "mat4x2" } }
MAT4x3_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Matrix, base = &FLOAT_TYPE, dimensions = { 4, 3 }, name = { text = "mat4x3" } }
MAT3_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Matrix, base = &FLOAT_TYPE, dimensions = { 3, 3 }, name = { text = "mat3" } }
MAT3x2_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Matrix, base = &FLOAT_TYPE, dimensions = { 3, 2 }, name = { text = "mat3x2" } }
MAT3x4_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Matrix, base = &FLOAT_TYPE, dimensions = { 3, 4 }, name = { text = "mat3x4" } }
MAT2_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Matrix, base = &FLOAT_TYPE, dimensions = { 2, 2 }, name = { text = "mat2" } }
MAT2x3_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Matrix, base = &FLOAT_TYPE, dimensions = { 2, 3 }, name = { text = "mat2x3" } }
MAT2x4_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Matrix, base = &FLOAT_TYPE, dimensions = { 2, 4 }, name = { text = "mat2x4" } }
STRING_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .String, name = { text = "string" } }
RAYQUERY_TYPE := Ast_Type { kind = .Primitive, primitive_kind = .Ray_Query, name = { text = "Ray_Query" } }

same_type :: proc(type1: ^Ast_Type, type2: ^Ast_Type) -> bool
{
    if type1 == nil || type2 == nil do return false
    if type1.kind == .Poison || type2.kind == .Poison do return false
    if type1.kind != type2.kind do return false
    if type1.primitive_kind != type2.primitive_kind do return false
    if type1.name.text != type2.name.text do return false
    if type1.is_mut != type2.is_mut do return false
    if type1.dimensions != type2.dimensions do return false

    has_base := type1.kind != .Primitive && type1.kind != .Label
    if has_base && !same_type(type1.base, type2.base) do return false
    return true
}

type_get_base :: proc(type: ^Ast_Type) -> ^Ast_Type
{
    if type.kind == .Poison do return &POISON_TYPE
    if type.base == nil do return type
    if type.kind == .Primitive do return type
    return type_get_base(type.base)
}

decl_lookup :: proc(scope: ^Ast_Scope, imports: []Ast_Import, token: Token, allow_intrinsics := true) -> ^Ast_Decl
{
    cur_scope := scope
    for cur_scope != nil
    {
        is_global_scope := cur_scope.enclosing_scope == nil

        for decl in cur_scope.decls
        {
            ignore_order := is_global_scope || decl.type.kind == .Struct || decl.type.kind == .Proc
            if !ignore_order && raw_data(decl.token.text) > raw_data(token.text) {
                continue
            }
            if decl.name == token.text do return decl
        }

        cur_scope = cur_scope.enclosing_scope
    }

    if allow_intrinsics
    {
        for intr in INTRINSICS
        {
            ignore_order := intr.type.kind == .Struct || intr.type.kind == .Proc
            if !ignore_order && raw_data(intr.token.text) > raw_data(token.text) {
                continue
            }
            if intr.name == token.text do return intr
        }
    }

    for imported in imports
    {
        if !imported.using_active do continue
        found := decl_lookup(imported.info.ast.scope, {}, token, false)
        if found != nil do return found
    }

    return nil
}

// Try to resolve intrinsic overloads
intrinsic_lookup :: proc(using c: ^Checker, token: Token, args: []^Ast_Expr) -> (found: ^Ast_Decl, ok: bool)
{
    scratch, _ := acquire_scratch()
    name_is_intr := false

    // Check for possible implicit type conversions.
    overload_candidates := make([dynamic]^Ast_Decl, allocator = scratch)
    num_overloads := 0
    for intr in INTRINSICS
    {
        if intr.name == token.text && intr.type.kind == .Proc
        {
            name_is_intr = true
            num_overloads += 1

            arg_count_matches := len(intr.type.args) == len(args)
            arg_count_matches |= intr.type.is_variadic && len(args) >= len(intr.type.args)
            if arg_count_matches
            {
                match := true
                for i in 0..<len(intr.type.args)
                {
                    arg := args[i]
                    if !type_implicit_convert(arg.type, intr.type.args[i].type)
                    {
                        match = false
                        break
                    }
                }

                if match do append(&overload_candidates, intr)
            }
        }
    }

    if !name_is_intr do return nil, true
    if len(overload_candidates) == 1 do return overload_candidates[0], true

    // If there are multiple possible candidates and one isn't
    // an exact match that is an error (ambiguous overload).
    for candidate in overload_candidates
    {
        exact_match := true
        for i in 0..<len(candidate.type.args)
        {
            arg := args[i]
            if !same_type(arg.type, candidate.type.args[i].type)
            {
                exact_match = false
                break
            }
        }

        if exact_match do return candidate, true
    }

    // Failure!

    if num_overloads == 1
    {
        // If there are no overloads, use normal error messages instead.
        return nil, true
    }

    sb := str.builder_make_none()
    defer str.builder_destroy(&sb)

    str.write_string(&sb, "\tGiven argument types:\n")
    for arg in args {
        fmt.sbprintfln(&sb, "\t - %v", type_to_string(arg.type, arena = scratch))
    }

    str.write_string(&sb, "Did you mean one of the following overloads?\n")
    for intr in INTRINSICS
    {
        if intr.name == token.text && intr.type.kind == .Proc
        {
            fmt.sbprintf(&sb, "\t%v :: (", intr.name)
            for arg, i in intr.type.args {
                if i > 0 do str.write_string(&sb, ", ")
                fmt.sbprintf(&sb, "%v: %v", arg.name, type_to_string(arg.type, arena = scratch))
            }
            if intr.type.ret != nil {
                fmt.sbprintfln(&sb, ") -> %v", type_to_string(intr.type.ret, arena = scratch))
            } else {
                fmt.sbprintfln(&sb, ")")
            }
        }
    }

    if len(overload_candidates) == 0  // It matches the name of an intrinsic but there is no matching overload
    {
        set_msg_after(str.to_string(sb))
        typecheck_error(c, token, "No matching overload found for intrinsic '%v':", token.text)
        return nil, false
    }
    else  // No exact match was found, so there's ambiguity here.
    {
        set_msg_after(str.to_string(sb))
        typecheck_error(c, token, "Ambiguous call for intrinsic '%v' that match with the given arguments:", token.text)
        return nil, false
    }
}

resolve_type :: proc(using c: ^Checker, type: ^Ast_Type)
{
    base := type_get_base(type)
    if base.kind == .Label
    {
        type_decl := decl_lookup(scope, ast.imports[:], base.name)
        if type_decl == nil {
            typecheck_error(c, base.name, "Undeclared identifier '%v'.", base.name.text)
            base.kind = .Poison  // Turn the declaration into the poison type
            base.primitive_kind = {}
        } else {
            base.base = type_decl.type
            base.decl = type_decl
        }
    }
}

typecheck_error :: proc(using c: ^Checker, token: Token, fmt_str: string, args: ..any)
{
    error_msg(file, token, fmt_str, ..args)
    error = true
}

typecheck_error_mismatching_types :: proc(using c: ^Checker, token: Token, type1: ^Ast_Type, type2: ^Ast_Type)
{
    scratch, _ := acquire_scratch()
    type1_str := type_to_string(type1, arena = scratch)
    type2_str := type_to_string(type2, arena = scratch)
    error_msg(file, token, "Incompatible types: '%v' and '%v'", type1_str, type2_str)
    error = true
}

typecheck_error_redeclaration :: proc(using c: ^Checker, decl_before: ^Ast_Decl, decl_after: ^Ast_Decl)
{
    error_msg(file, decl_after.token, "Redeclaration of '%v' in this scope.", decl_after.name)
    error = true
}

INTRINSICS: [dynamic]^Ast_Decl

// TODO: These should all just be declared in a .nosl file.
add_intrinsics :: proc()
{
    // Resource access
    add_intrinsic("texture_sample", { &TEXTURE_ID_TYPE, &SAMPLER_ID_TYPE, &VEC2_TYPE }, { "tex_idx", "sampler_idx", "uv" }, &VEC4_TYPE)
    add_intrinsic("texture_sample_compare", { &TEXTURE_ID_TYPE, &SAMPLER_ID_TYPE, &VEC3_TYPE }, { "tex_idx", "sampler_idx", "uvw" }, &FLOAT_TYPE)
    add_intrinsic("texture_sample_cube", { &TEXTURE_ID_TYPE, &SAMPLER_ID_TYPE, &VEC3_TYPE }, { "tex_idx", "sampler_idx", "direction" }, &VEC4_TYPE)
    add_intrinsic("texture_sample_cube_compare", { &TEXTURE_ID_TYPE, &SAMPLER_ID_TYPE, &VEC4_TYPE }, { "tex_idx", "sampler_idx", "uvwd" }, &FLOAT_TYPE)
    add_intrinsic("texture_sample_array", { &TEXTURE_ID_TYPE, &SAMPLER_ID_TYPE, &VEC3_TYPE }, { "tex_idx", "sampler_idx", "uvw" }, &VEC4_TYPE)
    add_intrinsic("texture_sample_array_compare", { &TEXTURE_ID_TYPE, &SAMPLER_ID_TYPE, &VEC4_TYPE }, { "tex_idx", "sampler_idx", "uvwd" }, &FLOAT_TYPE)
    add_intrinsic("texture_sample_cube_array", { &TEXTURE_ID_TYPE, &SAMPLER_ID_TYPE, &VEC4_TYPE }, { "tex_idx", "sampler_idx", "direction_layer" }, &VEC4_TYPE);
    add_intrinsic("texture_sample_3d", { &TEXTURE_ID_TYPE, &SAMPLER_ID_TYPE, &VEC3_TYPE }, { "tex_idx", "sampler_idx", "uvw" }, &VEC4_TYPE);
    add_intrinsic("texture_store", { &TEXTURE_RW_ID_TYPE, &IVEC2_TYPE, &VEC4_TYPE }, { "tex_idx", "coord", "value" }, nil)
    add_intrinsic("texture_load", { &TEXTURE_RW_ID_TYPE, &IVEC2_TYPE }, { "tex_idx", "coord" }, &VEC4_TYPE)
    add_intrinsic("texture_size", { &TEXTURE_ID_TYPE, &SAMPLER_ID_TYPE, &INT_TYPE }, { "tex_idx", "sampler_idx", "lod" }, &IVEC2_TYPE)
    add_intrinsic("texture_size", { &TEXTURE_RW_ID_TYPE }, { "tex_idx" }, &IVEC2_TYPE, glsl_name = "image_size")

    // Raytracing
    ray_result_type := add_intrinsic_struct("Ray_Result", { &UINT_TYPE, &FLOAT_TYPE, &UINT_TYPE, &UINT_TYPE, &VEC2_TYPE, &BOOL_TYPE, &MAT4x3_TYPE, &MAT4x3_TYPE }, { "kind", "t", "instance_idx", "primitive_idx", "barycentrics", "front_face", "object_to_world", "world_to_object" })
    ray_desc_type := add_intrinsic_struct("Ray_Desc", { &UINT_TYPE, &UINT_TYPE, &FLOAT_TYPE, &FLOAT_TYPE, &VEC3_TYPE, &VEC3_TYPE }, { "flags", "cull_mask", "t_min", "t_max", "origin", "dir" })
    add_intrinsic("rayquery_init", { ray_desc_type, &BVH_ID_TYPE }, { "desc", "bvh" }, &RAYQUERY_TYPE)
    add_intrinsic("rayquery_proceed", { &RAYQUERY_TYPE }, { "rq" }, &BOOL_TYPE)
    add_intrinsic("rayquery_candidate", { &RAYQUERY_TYPE }, { "rq" }, ray_result_type)
    add_intrinsic("rayquery_accept", { &RAYQUERY_TYPE }, { "rq" }, nil)
    add_intrinsic("rayquery_result", { &RAYQUERY_TYPE }, { "rq" }, ray_result_type)

    // Conversion
    add_intrinsic("float_bits_to_int", { &FLOAT_TYPE }, { "x" }, &UINT_TYPE, glsl_name = "floatBitsToInt")

    // Boolean vector manipulation
    add_intrinsic("all", { &BVEC2_TYPE }, { "x" }, &BOOL_TYPE)
    add_intrinsic("all", { &BVEC3_TYPE }, { "x" }, &BOOL_TYPE)
    add_intrinsic("all", { &BVEC4_TYPE }, { "x" }, &BOOL_TYPE)
    add_intrinsic("any", { &BVEC2_TYPE }, { "x" }, &BOOL_TYPE)
    add_intrinsic("any", { &BVEC3_TYPE }, { "x" }, &BOOL_TYPE)
    add_intrinsic("any", { &BVEC4_TYPE }, { "x" }, &BOOL_TYPE)
    add_intrinsic("not", { &BVEC2_TYPE }, { "x" }, &BVEC2_TYPE)
    add_intrinsic("not", { &BVEC3_TYPE }, { "x" }, &BVEC3_TYPE)
    add_intrinsic("not", { &BVEC4_TYPE }, { "x" }, &BVEC4_TYPE)

    // Constructors
    add_intrinsic("vec2", { &FLOAT_TYPE, &FLOAT_TYPE }, { "x", "y" }, &VEC2_TYPE)
    add_intrinsic("vec3", { &FLOAT_TYPE, &FLOAT_TYPE, &FLOAT_TYPE }, { "x", "y", "z" }, &VEC3_TYPE)
    add_intrinsic("vec3", { &VEC2_TYPE, &FLOAT_TYPE }, { "x", "y" }, &VEC3_TYPE)
    add_intrinsic("vec3", { &FLOAT_TYPE, &VEC2_TYPE }, { "x", "y" }, &VEC3_TYPE)
    add_intrinsic("vec4", { &FLOAT_TYPE, &FLOAT_TYPE, &FLOAT_TYPE, &FLOAT_TYPE }, { "x", "y", "z", "w" }, &VEC4_TYPE)
    add_intrinsic("vec4", { &VEC3_TYPE, &FLOAT_TYPE }, { "x", "y" }, &VEC4_TYPE)
    add_intrinsic("vec4", { &FLOAT_TYPE, &VEC3_TYPE }, { "x", "y" }, &VEC4_TYPE)
    add_intrinsic("vec4", { &VEC2_TYPE, &VEC2_TYPE }, { "x", "y" }, &VEC4_TYPE)
    add_intrinsic("vec4", { &FLOAT_TYPE, &FLOAT_TYPE, &VEC2_TYPE }, { "x", "y", "z" }, &VEC4_TYPE)
    add_intrinsic("vec4", { &VEC2_TYPE, &FLOAT_TYPE, &FLOAT_TYPE }, { "x", "y", "z" }, &VEC4_TYPE)
    add_intrinsic("vec4", { &FLOAT_TYPE, &VEC2_TYPE, &FLOAT_TYPE }, { "x", "y", "z" }, &VEC4_TYPE)
    add_intrinsic("ivec2", { &INT_TYPE, &INT_TYPE }, { "x", "y" }, &IVEC2_TYPE)
    add_intrinsic("ivec3", { &INT_TYPE, &INT_TYPE, &INT_TYPE }, { "x", "y", "z" }, &IVEC3_TYPE)
    add_intrinsic("ivec3", { &IVEC2_TYPE, &INT_TYPE }, { "x", "y" }, &IVEC3_TYPE)
    add_intrinsic("ivec3", { &INT_TYPE, &IVEC2_TYPE }, { "x", "y" }, &IVEC3_TYPE)
    add_intrinsic("ivec4", { &INT_TYPE, &INT_TYPE, &INT_TYPE, &INT_TYPE }, { "x", "y", "z", "w" }, &IVEC4_TYPE)
    add_intrinsic("ivec4", { &IVEC3_TYPE, &INT_TYPE }, { "x", "y" }, &IVEC4_TYPE)
    add_intrinsic("ivec4", { &INT_TYPE, &IVEC3_TYPE }, { "x", "y" }, &IVEC4_TYPE)
    add_intrinsic("ivec4", { &IVEC2_TYPE, &IVEC2_TYPE }, { "x", "y" }, &IVEC4_TYPE)
    add_intrinsic("ivec4", { &INT_TYPE, &INT_TYPE, &IVEC2_TYPE }, { "x", "y", "z" }, &IVEC4_TYPE)
    add_intrinsic("ivec4", { &IVEC2_TYPE, &INT_TYPE, &INT_TYPE }, { "x", "y", "z" }, &IVEC4_TYPE)
    add_intrinsic("ivec4", { &INT_TYPE, &IVEC2_TYPE, &INT_TYPE }, { "x", "y", "z" }, &IVEC4_TYPE)
    add_intrinsic("uvec2", { &UINT_TYPE, &UINT_TYPE }, { "x", "y" }, &UVEC2_TYPE)
    add_intrinsic("uvec3", { &UINT_TYPE, &UINT_TYPE, &UINT_TYPE }, { "x", "y", "z" }, &UVEC3_TYPE)
    add_intrinsic("uvec3", { &UVEC2_TYPE, &UINT_TYPE }, { "x", "y" }, &UVEC3_TYPE)
    add_intrinsic("uvec3", { &UINT_TYPE, &UVEC2_TYPE }, { "x", "y" }, &UVEC3_TYPE)
    add_intrinsic("uvec4", { &UINT_TYPE, &UINT_TYPE, &UINT_TYPE, &UINT_TYPE }, { "x", "y", "z", "w" }, &UVEC4_TYPE)
    add_intrinsic("uvec4", { &UVEC3_TYPE, &UINT_TYPE }, { "x", "y" }, &UVEC4_TYPE)
    add_intrinsic("uvec4", { &UINT_TYPE, &UVEC3_TYPE }, { "x", "y" }, &UVEC4_TYPE)
    add_intrinsic("uvec4", { &UVEC2_TYPE, &UVEC2_TYPE }, { "x", "y" }, &UVEC4_TYPE)
    add_intrinsic("uvec4", { &UINT_TYPE, &UINT_TYPE, &UVEC2_TYPE }, { "x", "y", "z" }, &UVEC4_TYPE)
    add_intrinsic("uvec4", { &UVEC2_TYPE, &UINT_TYPE, &UINT_TYPE }, { "x", "y", "z" }, &UVEC4_TYPE)
    add_intrinsic("uvec4", { &UINT_TYPE, &UVEC2_TYPE, &UINT_TYPE }, { "x", "y", "z" }, &UVEC4_TYPE)
    add_intrinsic("mat4", { &VEC4_TYPE, &VEC4_TYPE, &VEC4_TYPE, &VEC4_TYPE }, { "x", "y", "z", "w" }, &MAT4_TYPE)

    // Math functions - these work on float, vec2, vec3, vec4 (component-wise)
    add_intrinsic("pow", { &FLOAT_TYPE, &FLOAT_TYPE }, { "x", "y" }, &FLOAT_TYPE)
    add_intrinsic("pow", { &VEC2_TYPE, &VEC2_TYPE }, { "x", "y" }, &VEC2_TYPE)
    add_intrinsic("pow", { &VEC3_TYPE, &VEC3_TYPE }, { "x", "y" }, &VEC3_TYPE)
    add_intrinsic("pow", { &VEC4_TYPE, &VEC4_TYPE }, { "x", "y" }, &VEC4_TYPE)
    add_intrinsic("sqrt", { &FLOAT_TYPE }, { "x" }, &FLOAT_TYPE)
    add_intrinsic("sqrt", { &VEC2_TYPE }, { "x" }, &VEC2_TYPE)
    add_intrinsic("sqrt", { &VEC3_TYPE }, { "x" }, &VEC3_TYPE)
    add_intrinsic("sqrt", { &VEC4_TYPE }, { "x" }, &VEC4_TYPE)
    add_intrinsic("sin", { &FLOAT_TYPE }, { "x" }, &FLOAT_TYPE)
    add_intrinsic("sin", { &VEC2_TYPE }, { "x" }, &VEC2_TYPE)
    add_intrinsic("sin", { &VEC3_TYPE }, { "x" }, &VEC3_TYPE)
    add_intrinsic("sin", { &VEC4_TYPE }, { "x" }, &VEC4_TYPE)
    add_intrinsic("cos", { &FLOAT_TYPE }, { "x" }, &FLOAT_TYPE)
    add_intrinsic("cos", { &VEC2_TYPE }, { "x" }, &VEC2_TYPE)
    add_intrinsic("cos", { &VEC3_TYPE }, { "x" }, &VEC3_TYPE)
    add_intrinsic("cos", { &VEC4_TYPE }, { "x" }, &VEC4_TYPE)
    add_intrinsic("acos", { &FLOAT_TYPE }, { "x" }, &FLOAT_TYPE)
    add_intrinsic("acos", { &VEC2_TYPE }, { "x" }, &VEC2_TYPE)
    add_intrinsic("acos", { &VEC3_TYPE }, { "x" }, &VEC3_TYPE)
    add_intrinsic("acos", { &VEC4_TYPE }, { "x" }, &VEC4_TYPE)
    add_intrinsic("tan", { &FLOAT_TYPE }, { "x" }, &FLOAT_TYPE)
    add_intrinsic("tan", { &VEC2_TYPE }, { "x" }, &VEC2_TYPE)
    add_intrinsic("tan", { &VEC3_TYPE }, { "x" }, &VEC3_TYPE)
    add_intrinsic("tan", { &VEC4_TYPE }, { "x" }, &VEC4_TYPE)
    add_intrinsic("atan", { &FLOAT_TYPE, &FLOAT_TYPE }, { "x", "y" }, &FLOAT_TYPE)
    add_intrinsic("atan", { &VEC2_TYPE, &VEC2_TYPE }, { "x", "y" }, &VEC2_TYPE)
    add_intrinsic("atan", { &VEC3_TYPE, &VEC3_TYPE }, { "x", "y" }, &VEC3_TYPE)
    add_intrinsic("atan", { &VEC4_TYPE, &VEC4_TYPE }, { "x", "y" }, &VEC4_TYPE)
    add_intrinsic("tanh", { &FLOAT_TYPE }, { "x" }, &FLOAT_TYPE)
    add_intrinsic("tanh", { &VEC2_TYPE }, { "x" }, &VEC2_TYPE)
    add_intrinsic("tanh", { &VEC3_TYPE }, { "x" }, &VEC3_TYPE)
    add_intrinsic("tanh", { &VEC4_TYPE }, { "x" }, &VEC4_TYPE)
    add_intrinsic("fract", { &FLOAT_TYPE }, { "x" }, &FLOAT_TYPE)
    add_intrinsic("fract", { &VEC2_TYPE }, { "x" }, &VEC2_TYPE)
    add_intrinsic("fract", { &VEC3_TYPE }, { "x" }, &VEC3_TYPE)
    add_intrinsic("fract", { &VEC4_TYPE }, { "x" }, &VEC4_TYPE)
    add_intrinsic("abs", { &FLOAT_TYPE }, { "x" }, &FLOAT_TYPE)
    add_intrinsic("abs", { &VEC2_TYPE }, { "x" }, &VEC2_TYPE)
    add_intrinsic("abs", { &VEC3_TYPE }, { "x" }, &VEC3_TYPE)
    add_intrinsic("abs", { &VEC4_TYPE }, { "x" }, &VEC4_TYPE)
    add_intrinsic("dot", { &VEC2_TYPE, &VEC2_TYPE }, { "a", "b" }, &FLOAT_TYPE)
    add_intrinsic("dot", { &VEC3_TYPE, &VEC3_TYPE }, { "a", "b" }, &FLOAT_TYPE)
    add_intrinsic("dot", { &VEC4_TYPE, &VEC4_TYPE }, { "a", "b" }, &FLOAT_TYPE)
    add_intrinsic("cross", { &VEC3_TYPE, &VEC3_TYPE }, { "a", "b" }, &VEC3_TYPE)
    add_intrinsic("length", { &VEC2_TYPE }, { "v" }, &FLOAT_TYPE)
    add_intrinsic("length", { &VEC3_TYPE }, { "v" }, &FLOAT_TYPE)
    add_intrinsic("length", { &VEC4_TYPE }, { "v" }, &FLOAT_TYPE)
    add_intrinsic("min", { &FLOAT_TYPE, &FLOAT_TYPE }, { "a", "b" }, &FLOAT_TYPE)
    add_intrinsic("min", { &VEC2_TYPE, &VEC2_TYPE }, { "a", "b" }, &VEC2_TYPE)
    add_intrinsic("min", { &VEC3_TYPE, &VEC3_TYPE }, { "a", "b" }, &VEC3_TYPE)
    add_intrinsic("min", { &VEC4_TYPE, &VEC4_TYPE }, { "a", "b" }, &VEC4_TYPE)
    add_intrinsic("max", { &FLOAT_TYPE, &FLOAT_TYPE }, { "a", "b" }, &FLOAT_TYPE)
    add_intrinsic("max", { &VEC2_TYPE, &VEC2_TYPE }, { "a", "b" }, &VEC2_TYPE)
    add_intrinsic("max", { &VEC3_TYPE, &VEC3_TYPE }, { "a", "b" }, &VEC3_TYPE)
    add_intrinsic("max", { &VEC4_TYPE, &VEC4_TYPE }, { "a", "b" }, &VEC4_TYPE)
    add_intrinsic("min", { &INT_TYPE, &INT_TYPE }, { "a", "b" }, &INT_TYPE)
    add_intrinsic("min", { &IVEC2_TYPE, &IVEC2_TYPE }, { "a", "b" }, &IVEC2_TYPE)
    add_intrinsic("min", { &IVEC3_TYPE, &IVEC3_TYPE }, { "a", "b" }, &IVEC3_TYPE)
    add_intrinsic("min", { &IVEC4_TYPE, &IVEC4_TYPE }, { "a", "b" }, &IVEC4_TYPE)
    add_intrinsic("max", { &UINT_TYPE, &UINT_TYPE }, { "a", "b" }, &UINT_TYPE)
    add_intrinsic("max", { &UVEC2_TYPE, &UVEC2_TYPE }, { "a", "b" }, &UVEC2_TYPE)
    add_intrinsic("max", { &UVEC3_TYPE, &UVEC3_TYPE }, { "a", "b" }, &UVEC3_TYPE)
    add_intrinsic("max", { &UVEC4_TYPE, &UVEC4_TYPE }, { "a", "b" }, &UVEC4_TYPE)
    add_intrinsic("normalize", { &VEC2_TYPE }, { "v" }, &VEC2_TYPE)
    add_intrinsic("normalize", { &VEC3_TYPE }, { "v" }, &VEC3_TYPE)
    add_intrinsic("normalize", { &VEC4_TYPE }, { "v" }, &VEC4_TYPE)
    add_intrinsic("mix", { &FLOAT_TYPE, &FLOAT_TYPE, &FLOAT_TYPE }, { "a", "b", "t" }, &FLOAT_TYPE)
    add_intrinsic("mix", { &VEC2_TYPE, &VEC2_TYPE, &VEC2_TYPE }, { "a", "b", "t" }, &VEC2_TYPE)
    add_intrinsic("mix", { &VEC3_TYPE, &VEC3_TYPE, &VEC3_TYPE }, { "a", "b", "t" }, &VEC3_TYPE)
    add_intrinsic("mix", { &VEC4_TYPE, &VEC4_TYPE, &VEC4_TYPE }, { "a", "b", "t" }, &VEC4_TYPE)
    add_intrinsic("clamp", { &FLOAT_TYPE, &FLOAT_TYPE, &FLOAT_TYPE }, { "a", "b", "t" }, &FLOAT_TYPE)
    add_intrinsic("clamp", { &VEC2_TYPE, &VEC2_TYPE, &VEC2_TYPE }, { "a", "b", "t" }, &VEC2_TYPE)
    add_intrinsic("clamp", { &VEC3_TYPE, &VEC3_TYPE, &VEC3_TYPE }, { "a", "b", "t" }, &VEC3_TYPE)
    add_intrinsic("clamp", { &VEC4_TYPE, &VEC4_TYPE, &VEC4_TYPE }, { "a", "b", "t" }, &VEC4_TYPE)
    add_intrinsic("clamp", { &INT_TYPE, &INT_TYPE, &INT_TYPE }, { "a", "b", "t" }, &INT_TYPE)
    add_intrinsic("clamp", { &IVEC2_TYPE, &IVEC2_TYPE, &IVEC2_TYPE }, { "a", "b", "t" }, &IVEC2_TYPE)
    add_intrinsic("clamp", { &IVEC3_TYPE, &IVEC3_TYPE, &IVEC3_TYPE }, { "a", "b", "t" }, &IVEC3_TYPE)
    add_intrinsic("clamp", { &IVEC4_TYPE, &IVEC4_TYPE, &IVEC4_TYPE }, { "a", "b", "t" }, &IVEC4_TYPE)
    add_intrinsic("clamp", { &UINT_TYPE, &UINT_TYPE, &UINT_TYPE }, { "a", "b", "t" }, &UINT_TYPE)
    add_intrinsic("clamp", { &UVEC2_TYPE, &UVEC2_TYPE, &UVEC2_TYPE }, { "a", "b", "t" }, &UVEC2_TYPE)
    add_intrinsic("clamp", { &UVEC3_TYPE, &UVEC3_TYPE, &UVEC3_TYPE }, { "a", "b", "t" }, &UVEC3_TYPE)
    add_intrinsic("clamp", { &UVEC4_TYPE, &UVEC4_TYPE, &UVEC4_TYPE }, { "a", "b", "t" }, &UVEC4_TYPE)
    add_intrinsic("dfdx_coarse", { &FLOAT_TYPE }, { "x" }, &FLOAT_TYPE, glsl_name = "dFdxCoarse")
    add_intrinsic("dfdx_coarse", { &VEC2_TYPE }, { "x" }, &VEC2_TYPE, glsl_name = "dFdxCoarse")
    add_intrinsic("dfdx_coarse", { &VEC3_TYPE }, { "x" }, &VEC3_TYPE, glsl_name = "dFdxCoarse")
    add_intrinsic("dfdx_coarse", { &VEC4_TYPE }, { "x" }, &VEC4_TYPE, glsl_name = "dFdxCoarse")
    add_intrinsic("dfdx_fine", { &FLOAT_TYPE }, { "x" }, &FLOAT_TYPE, glsl_name = "dFdxFine")
    add_intrinsic("dfdx_fine", { &VEC2_TYPE }, { "x" }, &VEC2_TYPE, glsl_name = "dFdxFine")
    add_intrinsic("dfdx_fine", { &VEC3_TYPE }, { "x" }, &VEC3_TYPE, glsl_name = "dFdxFine")
    add_intrinsic("dfdx_fine", { &VEC4_TYPE }, { "x" }, &VEC4_TYPE, glsl_name = "dFdxFine")
    add_intrinsic("dfdy_coarse", { &FLOAT_TYPE }, { "x" }, &FLOAT_TYPE, glsl_name = "dFdyCoarse")
    add_intrinsic("dfdy_coarse", { &VEC2_TYPE }, { "x" }, &VEC2_TYPE, glsl_name = "dFdyCoarse")
    add_intrinsic("dfdy_coarse", { &VEC3_TYPE }, { "x" }, &VEC3_TYPE, glsl_name = "dFdyCoarse")
    add_intrinsic("dfdy_coarse", { &VEC4_TYPE }, { "x" }, &VEC4_TYPE, glsl_name = "dFdyCoarse")
    add_intrinsic("dfdy_fine", { &FLOAT_TYPE }, { "x" }, &FLOAT_TYPE, glsl_name = "dFdyFine")
    add_intrinsic("dfdy_fine", { &VEC2_TYPE }, { "x" }, &VEC2_TYPE, glsl_name = "dFdyFine")
    add_intrinsic("dfdy_fine", { &VEC3_TYPE }, { "x" }, &VEC3_TYPE, glsl_name = "dFdyFine")
    add_intrinsic("dfdy_fine", { &VEC4_TYPE }, { "x" }, &VEC4_TYPE, glsl_name = "dFdyFine")
    add_intrinsic("smoothstep", { &FLOAT_TYPE, &FLOAT_TYPE, &FLOAT_TYPE }, { "edge0", "edge1", "x" }, &FLOAT_TYPE)
    add_intrinsic("smoothstep", { &VEC2_TYPE, &VEC2_TYPE, &VEC2_TYPE }, { "edge0", "edge1", "x" }, &VEC2_TYPE)
    add_intrinsic("smoothstep", { &VEC3_TYPE, &VEC3_TYPE, &VEC3_TYPE }, { "edge0", "edge1", "x" }, &VEC3_TYPE)
    add_intrinsic("smoothstep", { &VEC4_TYPE, &VEC4_TYPE, &VEC4_TYPE }, { "edge0", "edge1", "x" }, &VEC4_TYPE)
    add_intrinsic("smoothstep", { &FLOAT_TYPE, &FLOAT_TYPE, &VEC2_TYPE }, { "edge0", "edge1", "x" }, &VEC2_TYPE)
    add_intrinsic("smoothstep", { &FLOAT_TYPE, &FLOAT_TYPE, &VEC3_TYPE }, { "edge0", "edge1", "x" }, &VEC3_TYPE)
    add_intrinsic("smoothstep", { &FLOAT_TYPE, &FLOAT_TYPE, &VEC4_TYPE }, { "edge0", "edge1", "x" }, &VEC4_TYPE)

    // Matrix manipulation
    add_intrinsic("transpose", { &MAT2_TYPE }, { "m" }, &MAT2_TYPE)
    add_intrinsic("transpose", { &MAT2x3_TYPE }, { "m" }, &MAT3x2_TYPE)
    add_intrinsic("transpose", { &MAT2x4_TYPE }, { "m" }, &MAT4x2_TYPE)
    add_intrinsic("transpose", { &MAT3_TYPE }, { "m" }, &MAT3_TYPE)
    add_intrinsic("transpose", { &MAT3x2_TYPE }, { "m" }, &MAT2x3_TYPE)
    add_intrinsic("transpose", { &MAT3x4_TYPE }, { "m" }, &MAT4x3_TYPE)
    add_intrinsic("transpose", { &MAT4_TYPE }, { "m" }, &MAT4_TYPE)
    add_intrinsic("transpose", { &MAT4x2_TYPE }, { "m" }, &MAT2x4_TYPE)
    add_intrinsic("transpose", { &MAT4x3_TYPE }, { "m" }, &MAT3x4_TYPE)

    // Misc
    add_intrinsic("printf", { &STRING_TYPE }, { "fmt" }, is_variadic = true)
}

add_intrinsic :: proc(name: string, args: []^Ast_Type, names: []string, ret: ^Ast_Type = nil, glsl_name := "", is_variadic := false)
{
    assert(len(args) == len(names))

    arg_decls := make([]^Ast_Decl, len(args))
    for &arg, i in arg_decls
    {
        arg = new(Ast_Decl)
        arg.type = args[i]
        arg.name = names[i]
    }

    decl := new(Ast_Decl)
    decl.name = name
    decl.type = new(Ast_Type)
    decl.type.kind = .Proc
    decl.type.args = arg_decls
    decl.type.ret = ret
    decl.type.is_variadic = is_variadic
    decl.glsl_name = glsl_name if glsl_name != "" else decl.name
    append(&INTRINSICS, decl)
}

add_intrinsic_struct :: proc(name: string, members: []^Ast_Type, names: []string) -> ^Ast_Type
{
    assert(len(members) == len(names))

    member_decls := make([]^Ast_Decl, len(members))
    for &member, i in member_decls
    {
        member = new(Ast_Decl)
        member.type = members[i]
        member.name = names[i]
    }

    decl := new(Ast_Decl)
    decl.name = name
    decl.glsl_name = ident_to_glsl(name)
    decl.type = new(Ast_Type)
    decl.type.kind = .Struct
    decl.type.members = member_decls
    append(&INTRINSICS, decl)

    label_type := new(Ast_Type)
    label_type.kind = .Label
    label_type.name = { text = name, type = .Ident, col_start = 0, line = 0 }
    label_type.base = decl.type
    label_type.decl = decl
    return label_type
}

// Propagates &POISON_TYPE
bin_op_result_type :: proc(op: Ast_Binary_Op, type1: ^Ast_Type, type2: ^Ast_Type) -> (res: ^Ast_Type, ok: bool)
{
    if type1.kind == .Poison || type2.kind == .Poison {
        return &POISON_TYPE, true
    }

    if op == .Mul && type1.primitive_kind == .Matrix
    {
        match_dims := type1.dimensions.x == type2.dimensions.x
        if match_dims && same_type(type1.base, type2.base) do return make_vec_type(type1.base, type1.dimensions.y), true
    }
    else if op == .Mul && type1.primitive_kind == .Vector
    {
        match_dims := type1.dimensions.x == type2.dimensions.y
        if match_dims && same_type(type1.base, type2.base) do return make_vec_type(type2.base, type2.dimensions.x), true
    }

    is_bit_manip := op == .Bitwise_And ||
                  op == .Bitwise_Or ||
                  op == .Bitwise_Xor ||
                  op == .LShift ||
                  op == .RShift
    if is_bit_manip
    {
        if type_implicit_convert(type1, &UINT_TYPE) && type_implicit_convert(type2, &UINT_TYPE) do return &UINT_TYPE, true
        if type_implicit_convert(type1, &INT_TYPE) && type_implicit_convert(type2, &INT_TYPE) do return &INT_TYPE, true
        return &POISON_TYPE, false
    }

    is_compare := op == .Greater ||
                  op == .Less ||
                  op == .LE ||
                  op == .GE ||
                  op == .EQ ||
                  op == .NEQ
    if is_compare
    {
        if type1.primitive_kind == .Vector && type2.primitive_kind == .Vector
        {
            if type1.dimensions == type2.dimensions && same_type(type1.base, type2.base) {
                return make_vec_type(&BOOL_TYPE, type1.dimensions.x), true
            }

            return &POISON_TYPE, false
        }
        else
        {
            if type_implicit_convert(type1, type2) || type_implicit_convert(type2, type1) do return &BOOL_TYPE, true
            return &POISON_TYPE, false
        }
    }

    // Commutative properties here.
    for i in 0..<2
    {
        t1 := type1 if i == 0 else type2
        t2 := type2 if i == 0 else type1

        if (t1.primitive_kind == .Untyped_Float || t1.primitive_kind == .Untyped_Int) && t2.primitive_kind == .Float {
            return t2, true
        }
        if t1.primitive_kind == .Untyped_Int && (t2.primitive_kind == .Uint || t2.primitive_kind == .Int) {
            return t2, true
        }
        if (op == .Add || op == .Minus) && type_is_resource_id(t1) && (type_implicit_convert(t2, &UINT_TYPE) || type_implicit_convert(t2, &INT_TYPE)) {
            return t1, true
        }
        if t2.primitive_kind == .Vector && type_implicit_convert(t1, t2.base) {
            return t2, true
        }
    }

    if same_type(type1, type2) do return type1, true
    return &POISON_TYPE, false
}

unary_op_result_type :: proc(op: Ast_Unary_Op, type: ^Ast_Type) -> (res: ^Ast_Type, ok: bool)
{
    if type.kind == .Poison do return &POISON_TYPE, true

    is_boolean := op == .Not
    if is_boolean
    {
        if type_implicit_convert(type, &BOOL_TYPE) do return &BOOL_TYPE, true
    }

    is_arithmetic := op == .Minus || op == .Plus
    if is_arithmetic
    {
        if type_implicit_convert(type, &INT_TYPE) do return &INT_TYPE, true
        if type_implicit_convert(type, &UINT_TYPE) do return &UINT_TYPE, true
        if type_implicit_convert(type, &FLOAT_TYPE) do return &FLOAT_TYPE, true
        if type_implicit_convert(type, &VEC2_TYPE) do return &VEC2_TYPE, true
        if type_implicit_convert(type, &VEC3_TYPE) do return &VEC3_TYPE, true
        if type_implicit_convert(type, &VEC4_TYPE) do return &VEC4_TYPE, true
    }

    return &POISON_TYPE, false
}

// Returns &POISON_TYPE if the two types are not allowed
if_expr_result_type :: proc(then_type: ^Ast_Type, else_type: ^Ast_Type) -> ^Ast_Type
{
    // Commutative properties here.
    for i in 0..<2
    {
        t1 := then_type if i == 0 else else_type
        t2 := else_type if i == 0 else then_type

        if (t1.primitive_kind == .Untyped_Float || t1.primitive_kind == .Untyped_Int) && t2.primitive_kind == .Float {
            return t2
        }
        if t1.primitive_kind == .Untyped_Int && (t2.primitive_kind == .Uint || t2.primitive_kind == .Int) {
            return t2
        }
        if type_implicit_convert(t1, &FLOAT_TYPE) && t2.primitive_kind == .Vector {
            return t2
        }
    }

    if same_type(then_type, else_type) do return then_type
    return &POISON_TYPE
}

type_cast_allowed :: proc(from: ^Ast_Type, to: ^Ast_Type) -> bool
{
    if type_implicit_convert(from, to) do return true

    if type_implicit_convert(from, &BOOL_TYPE) && type_implicit_convert(to, &FLOAT_TYPE) {
        return true
    }
    if type_implicit_convert(from, &BOOL_TYPE) && type_implicit_convert(to, &INT_TYPE) {
        return true
    }
    if type_implicit_convert(from, &BOOL_TYPE) && type_implicit_convert(to, &UINT_TYPE) {
        return true
    }
    if to.primitive_kind == .Vector && type_implicit_convert(from, to.base) {
        return true
    }
    if from.primitive_kind == .Vector && to.primitive_kind == .Vector {
        return from.dimensions == to.dimensions && type_cast_allowed(from.base, to.base)
    }
    if from.primitive_kind == .Matrix && to.primitive_kind == .Matrix {
        return from.dimensions.x >= to.dimensions.x &&
               from.dimensions.y >= to.dimensions.y &&
               type_cast_allowed(from.base, to.base)
    }

    for i in 0..<2
    {
        t1 := from if i == 0 else to
        t2 := to if i == 0 else from

        if type_implicit_convert(t1, &FLOAT_TYPE) && type_implicit_convert(t2, &INT_TYPE) {
            return true
        }
        if type_implicit_convert(t1, &INT_TYPE) && type_implicit_convert(t2, &UINT_TYPE) {
            return true
        }
        if type_implicit_convert(t1, &FLOAT_TYPE) && type_implicit_convert(t2, &UINT_TYPE) {
            return true
        }
    }

    return false
}

// Returns true if "from" is implicitly convertible to "to"
type_implicit_convert :: proc(from: ^Ast_Type, to: ^Ast_Type) -> bool
{
    if (from.primitive_kind == .Untyped_Float || from.primitive_kind == .Untyped_Int) && to.primitive_kind == .Float {
        return true
    }
    if from.primitive_kind == .Untyped_Int && (to.primitive_kind == .Uint || to.primitive_kind == .Int) {
        return true
    }

    to_is_resource_id := to.primitive_kind == .Texture_ID || to.primitive_kind == .Sampler_ID || to.primitive_kind == .BVH_ID

    if from.primitive_kind == .Untyped_Int && to_is_resource_id {
        return true
    }

    return same_type(from, to)
}

resolve_scope_decls :: proc(using c: ^Checker)
{
    for decl in scope.decls
    {
        decl.glsl_name = ident_to_glsl(decl.name)
        resolve_type(c, decl.type)

        if decl.type.primitive_kind == .Ray_Query || decl.type.primitive_kind == .BVH_ID {
            ast.used_features += { .Raytracing }
        }

        for decl_2 in scope.decls
        {
            if decl_2.name == decl.name && raw_data(decl_2.token.text) < raw_data(decl.token.text)
            {
                typecheck_error_redeclaration(c, decl_2, decl)
                break
            }
        }
    }
}

check_printf :: proc(using c: ^Checker, call: ^Ast_Call) -> bool
{
    args := call.args
    fmt_str: string
    #partial switch arg in args[0].derived_expr
    {
        case ^Ast_Lit_Expr:
        {
            if args[0].type.primitive_kind != .String
            {
                typecheck_error(c, call.token, "First argument of printf must be a constant string.")
                return false
            }

            fmt_str = args[0].token.text
        }
        case:
        {
            typecheck_error(c, call.token, "First argument of printf must be a constant string.")
            return false
        }
    }

    fmt_arg_count := 0
    for c in fmt_str
    {
        // Add escape for '%'.
        if c == '%' {
            fmt_arg_count += 1
        }
    }

    if fmt_arg_count + 1 != len(call.args)
    {
        if fmt_arg_count == 1 {
            typecheck_error(c, call.token, "printf format string specifies %v argument, supplied %v.", fmt_arg_count, len(call.args) - 1)
        } else {
            typecheck_error(c, call.token, "printf format string specifies %v arguments, supplied %v.", fmt_arg_count, len(call.args) - 1)
        }
        return false
    }

    // TODO: Check for unallowed types in varargs.

    return true
}

handle_vector_swizzle :: proc(expr_type: ^Ast_Type, str: string) -> (res: ^Ast_Type, is_swizzle: bool)
{
    if str == "" do return &POISON_TYPE, false
    if len(str) > 4 do return &POISON_TYPE, false

    el_count: u32
    #partial switch expr_type.primitive_kind
    {
        case .Float: el_count = 1
        case .Vector: el_count = expr_type.dimensions.x
        case: return &POISON_TYPE, false
    }

    is_xyzw: bool
    is_rgba: bool
    switch str[0]
    {
        case 'x', 'y', 'z', 'w': is_xyzw = true
        case 'r', 'g', 'b', 'a': is_rgba = true
    }

    if !is_xyzw && !is_rgba do return &POISON_TYPE, false

    if is_xyzw
    {
        for c in str[1:]
        {
            switch c
            {
                case 'x', 'y', 'z', 'w': {
                    if c == 'y' && el_count < 2 { return &POISON_TYPE, false }
                    if c == 'z' && el_count < 3 { return &POISON_TYPE, false }
                    if c == 'w' && el_count < 4 { return &POISON_TYPE, false }
                }
                case: return &POISON_TYPE, false
            }
        }
    }
    if is_rgba
    {
        for c in str[1:]
        {
            switch c
            {
                case 'r', 'g', 'b', 'a': {
                    if c == 'g' && el_count < 2 { return &POISON_TYPE, false }
                    if c == 'b' && el_count < 3 { return &POISON_TYPE, false }
                    if c == 'a' && el_count < 4 { return &POISON_TYPE, false }
                }
                case: return &POISON_TYPE, false
            }
        }
    }

    if len(str) == 1 {
        return expr_type.base if expr_type.base != nil else expr_type, true
    } else {
        return make_vec_type(expr_type.base, u32(len(str))), true
    }
}

type_is_resource_id :: proc(type: ^Ast_Type) -> bool
{
    switch type.primitive_kind
    {
        case .None:          return false
        case .Untyped_Int:   return false
        case .Untyped_Float: return false
        case .Bool:          return false
        case .Float:         return false
        case .Uint:          return false
        case .Int:           return false
        case .Texture_ID:    return true
        case .Texture_RW_ID: return true
        case .Sampler_ID:    return true
        case .Vector:        return false
        case .Matrix:        return false
        case .String:        return false
        case .Ray_Query:     return false
        case .BVH_ID:        return true
    }
    return {}
}

check_assign_lhs :: proc(using c: ^Checker, expr: ^Ast_Expr) -> bool
{
    // Check expression kind first
    kind_ok: bool
    switch derived in expr.derived_expr
    {
        case ^Ast_Binary_Expr:   kind_ok = false
        case ^Ast_Unary_Expr:    kind_ok = false
        case ^Ast_Member_Access: kind_ok = true
        case ^Ast_Array_Access:  kind_ok = true
        case ^Ast_Ident_Expr:    kind_ok = true
        case ^Ast_Lit_Expr:      kind_ok = false
        case ^Ast_Call:          kind_ok = false
        case ^Ast_If_Expr:       kind_ok = false
        case ^Ast_Cast:          kind_ok = false
    }

    if !kind_ok {
        typecheck_error(c, expr.token, "This expression is not an l-value, therefore it can't be assigned to.")
        return false
    }

    // Check expression constness
    if expr.is_const
    {
        if expr.type.kind != .Primitive {
            typecheck_error(c, expr.token, "Pointers and slices are immutable by default, use 'mut^ T' and 'mut[] T' for mutability. Mutability affects performance.")
        } else if _, ok := expr.derived_expr.(^Ast_Ident_Expr); ok {  // TODO: @robustness Make this check better
            typecheck_error(c, expr.token, "This variable is a specialization constant, thus it is immutable (but it still behaves as a runtime variable).")
        } else {
            typecheck_error(c, expr.token, "This expression is immutable.")
        }
        return false
    }

    return true
}
