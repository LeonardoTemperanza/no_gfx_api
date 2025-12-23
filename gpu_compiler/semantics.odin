
package main

import "core:fmt"
import "base:runtime"

typecheck_ast :: proc(ast: Ast, allocator: runtime.Allocator) -> bool
{
    context.allocator = allocator

    c := Checker {
        ast = ast
    }

    for declaration in ast.scope.decls
    {
        switch decl in declaration.derived_decl
        {
            case ^Ast_Struct_Decl: {}
            case ^Ast_Proc_Decl:
            {
                c.proc_def = decl
                for statement in decl.statements
                {
                    typecheck_statement(&c, statement)
                }
            }
        }
    }

    return !c.error
}

Checker :: struct
{
    ast: Ast,
    proc_def: ^Ast_Proc_Decl,
    input_path: string,
    error: bool,
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
            typecheck_expr(c, stmt.rhs)

            /*if !same_type(stmt.lhs.type, stmt.rhs.type) {
                typecheck_error(c, expr.token, "Mismatching types.")
            }*/
        }
        case ^Ast_Var_Decl:
        {
            
        }
        case ^Ast_Return:
        {
            typecheck_expr(c, stmt.expr)
        }
    }
}

typecheck_expr :: proc(using c: ^Checker, expression: ^Ast_Expr)
{
    switch expr in expression.derived_expr
    {
        case ^Ast_Binary_Expr:
        {
            typecheck_expr(c, expr.lhs)
            typecheck_expr(c, expr.rhs)

            if !same_type(expr.lhs.type, expr.rhs.type) {
                typecheck_error(c, expr.token, "Mismatching types.")
            }

            expr.type = expr.lhs.type
        }
        case ^Ast_Ident_Expr:
        {
            info, ok := var_name_resolve(c, expr.token.text, expr.token)
            if !ok {
                typecheck_error(c, expr.token, "Couldn't find declaration of this identifier.")
            }
            expr.type = new(Ast_Type)
            expr.type^ = {
                name = info.name,
                struct_decl = info.struct_decl
            }
        }
        case ^Ast_Lit_Expr:
        {
            //new(Ast_Type)
        }
        case ^Ast_Member_Access:
        {
            typecheck_expr(c, expr.target)

            if expr.member_name == "xyz" {
                type := new(Ast_Type)
                type.name = "vec3"
                expr.type = type
                break
            }

            if expr.target.type.struct_decl == nil {
                typecheck_error(c, expr.token, "Can't access members on this type.")
            }

            struct_decl := expr.target.type.struct_decl
            found_field := false
            type := new(Ast_Type)
            for field in struct_decl.fields
            {
                if field.name == expr.member_name
                {
                    found_field = true
                    type^ = field.type^
                    break
                }
            }

            if !found_field {
                typecheck_error(c, expr.token, "Member not found.")
            }

            type_resolved, ok := search_type(c, type.name)
            if !ok {
                typecheck_error(c, expr.token, "Type not found.")
            }
            expr.type = type
            expr.type.struct_decl = type_resolved.struct_decl
        }
        case ^Ast_Array_Access:
        {
            typecheck_expr(c, expr.target)
            typecheck_expr(c, expr.idx_expr)
            expr.type = new(Ast_Type)
            expr.type^ = expr.target.type^
            expr.type.is_slice = false
            expr.type.is_ptr = false
        }
        case ^Ast_Call:
        {
            // TODO: Only constructors work at the moment
            target, is_ident := expr.target.derived_expr.(^Ast_Ident_Expr)
            if !is_ident do panic("Not implemented!")
            if !is_primitive_type(target.token.text) do panic("Not implemented!")

            for arg in expr.args {
                typecheck_expr(c, arg)
            }

            expr.type = new(Ast_Type)
            expr.type^ = {
                name = target.token.text,
            }
        }
    }
}

same_type :: proc(type1: ^Ast_Type, type2: ^Ast_Type) -> bool
{
    return (type1^) == (type2^)
}

// Only goes back to the declaration
search_type_of_name :: proc(proc_def: ^Ast_Proc_Decl, name: string, pos: Token) -> (^Ast_Type, bool)
{
    for arg in proc_def.args
    {
        if arg.name == name {
            return arg.type, true
        }
    }

    for statement in proc_def.statements
    {
        if raw_data(statement.token.text) > raw_data(pos.text) {
            break
        }

        decl, ok := statement.derived_statement.(^Ast_Var_Decl)
        if ok && decl.name == name {
            return decl.type, true
        }
    }

    return {}, false
}

var_name_resolve :: proc(using c: ^Checker, name: string, pos: Token) -> (res: ^Ast_Type, ok: bool)
{
    type, ok_s := search_type_of_name(proc_def, name, pos)
    if !ok_s
    {
        fmt.printfln("Error: Could not find variable '%v'.", name)
        return {}, false
    }

    if is_primitive_type(type.name) do return type, true

    for decl in ast.scope.decls
    {
        #partial switch d in decl.derived_decl
        {
            case ^Ast_Struct_Decl:
            {
                if decl.name == type.name
                {
                    type.struct_decl = d
                    return type, true
                }
            }
        }
    }

    return {}, false
}

// type name -> struct declaration
search_type :: proc(using c: ^Checker, type_name: string) -> (res: ^Ast_Type, ok: bool)
{
    if is_primitive_type(type_name)
    {
        new_type := new(Ast_Type)
        new_type.name = type_name
        return new_type, true
    }

    type := new(Ast_Type)
    type.name = type_name
    for decl in ast.scope.decls
    {
        #partial switch d in decl.derived_decl
        {
            case ^Ast_Struct_Decl:
            {
                type.struct_decl = d
                return type, true
            }
        }
    }

    return {}, false
}

is_primitive_type :: proc(str: string) -> bool
{
    switch str
    {
        case "float": return true
        case "uint":  return true
        case "vec2":  return true
        case "vec3":  return true
        case "vec4":  return true
    }

    return false
}

typecheck_error :: proc(using c: ^Checker, token: Token, fmt_str: string, args: ..any)
{
    if error do return

    error_msg(input_path, token, fmt_str, ..args)
    error = true
}
