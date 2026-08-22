
#+feature dynamic-literals
#+feature using-stmt
#+vet !unused-imports

package main

import "base:runtime"
import "core:slice"
import intr "base:intrinsics"
import str "core:strings"
import "core:fmt"
import fp "core:path/filepath"
import "core:os"

Lang_Feature :: enum { Raytracing }
Lang_Features :: bit_set[Lang_Feature; u32]

Any_Node :: union
{
    Any_Statement,
    Any_Expr,
    ^Ast_Decl,
}

Ast :: struct
{
    used_types: [dynamic]Ast_Type,
    used_indirect_data_type: ^Ast_Type,
    scope: ^Ast_Scope,
    procs: [dynamic]^Ast_Proc_Def,
    global_vars: [dynamic]^Ast_Define_Var,

    imports: [dynamic]Ast_Import,

    // Filled in by typechecker
    used_features: Lang_Features,
}

Ast_Import :: struct
{
    module_name: string,
    info: ^Parse_Task,
    using_active: bool,
}

Ast_Node :: struct
{
    token: Token,
    derived: Any_Node,
}

Ast_Scope :: struct
{
    enclosing_scope: ^Ast_Scope,  // Can be nil
    decls: [dynamic]^Ast_Decl,
}

// Declarations (global)

Ast_Decl_Constness :: enum
{
    Runtime = 0,
    // Comptime,
    Spectime,  // Specialization constants.
}

Ast_Decl :: struct
{
    using base: Ast_Node,
    name: string,
    glsl_name: string,
    type: ^Ast_Type,
    attr: Maybe(Ast_Attribute),
    has_init: bool,
    is_entrypoint: bool,
    entrypoint_stage: Shader_Stage,

    constness: Ast_Decl_Constness,
}

Ast_Proc_Def :: struct
{
    decl: ^Ast_Decl,
    statements: []^Ast_Statement,
    scope: ^Ast_Scope,
}

// Expressions

Any_Expr :: union
{
    ^Ast_Binary_Expr,
    ^Ast_Unary_Expr,
    ^Ast_Member_Access,
    ^Ast_Array_Access,
    ^Ast_Ident_Expr,
    ^Ast_Lit_Expr,
    ^Ast_Call,
    ^Ast_If_Expr,
    ^Ast_Cast,
}

Ast_Expr :: struct
{
    using base: Ast_Node,
    derived_expr: Any_Expr,
    type: ^Ast_Type,
    is_const: bool,
}

Ast_Attribute_Type :: enum
{
    Vert_ID,
    Position,
    Data,
    Instance_ID,
    Draw_ID,
    Indirect_Data,
    Workgroup_ID,
    Local_Invocation_ID,
    Global_Invocation_ID,
    Group_Size,

    // With args:
    IO,
    Spec,
}

Ast_Attribute_Specifier :: enum
{
    Flat,
    Centroid,
    No_Perspective,
}

Ast_Attribute_Specifiers :: bit_set[Ast_Attribute_Specifier]

Ast_Attribute :: struct
{
    type: Ast_Attribute_Type,
    specs: Ast_Attribute_Specifiers,
    id: u32
}

Ast_Binary_Op :: enum
{
    Add,
    Minus,
    Mul,
    Div,
    Modulo,

    // Bitwise
    Bitwise_And,
    Bitwise_Or,
    Bitwise_Xor,
    LShift,
    RShift,

    And,
    Or,

    // Comparison
    Greater,
    Less,
    LE,
    GE,
    EQ,
    NEQ,
}

Ast_Binary_Expr :: struct
{
    using base_expr: Ast_Expr,
    lhs: ^Ast_Expr,
    rhs: ^Ast_Expr,
    op: Ast_Binary_Op,
}

Ast_Unary_Op :: enum
{
    Not,
    Plus,
    Minus,
}

Ast_Unary_Expr :: struct
{
    using base_expr: Ast_Expr,
    op: Ast_Unary_Op,
    expr: ^Ast_Expr,
}

Ast_Member_Access :: struct
{
    using base_expr: Ast_Expr,
    target: ^Ast_Expr,
    member: Token,
    is_swizzle: bool,
    is_module_access: bool,
    module_name: string,  // This is its unique identifier. Locally defined module name can be obtained with target.token.text
}

Ast_Array_Access :: struct
{
    using base_expr: Ast_Expr,
    target: ^Ast_Expr,
    idx_expr: ^Ast_Expr,
}

Ast_Call :: struct
{
    using base_expr: Ast_Expr,
    target: ^Ast_Expr,
    args: []^Ast_Expr,

    glsl_name: string,  // If target is just an ident.
}

Ast_Ident_Expr :: struct
{
    using base_expr: Ast_Expr,

    // Filled in by typechecker.
    glsl_name: string,
}

Ast_Lit_Expr :: struct
{
    using base_expr: Ast_Expr
}

Ast_If_Expr :: struct
{
    using base_expr: Ast_Expr,
    cond_expr: ^Ast_Expr,
    then_expr: ^Ast_Expr,
    else_expr: ^Ast_Expr,
}

Ast_Cast :: struct
{
    using base_expr: Ast_Expr,
    expr: ^Ast_Expr,
    cast_to: ^Ast_Type,
}

// Statements

Any_Statement :: union
{
    ^Ast_Assign,
    ^Ast_Stmt_Expr,
    ^Ast_Define_Var,
    ^Ast_Return,
    ^Ast_If,
    ^Ast_For,
    ^Ast_Block,
    ^Ast_Break,
    ^Ast_Continue,
    ^Ast_Discard,
}

Ast_Statement :: struct
{
    using base: Ast_Node,
    derived_statement: Any_Statement,
}

Ast_Assign :: struct
{
    using base_statement: Ast_Statement,

    apply_op: bool,
    bin_op: Ast_Binary_Op,
    lhs: ^Ast_Expr,
    rhs: ^Ast_Expr
}

Ast_Define_Var :: struct
{
    using base_statement: Ast_Statement,
    decl: ^Ast_Decl,
    expr: ^Ast_Expr,
}

Ast_Stmt_Expr :: struct
{
    using base_statement: Ast_Statement,
    expr: ^Ast_Expr,
}

Ast_Return :: struct
{
    using base_statement: Ast_Statement,
    expr: ^Ast_Expr,
}

Ast_If :: struct
{
    using base_statement: Ast_Statement,
    cond: ^Ast_Expr,

    // Then
    statements: []^Ast_Statement,
    scope: ^Ast_Scope,

    // Else
    else_is_present: bool,
    else_is_single: bool,
    else_single: ^Ast_Statement,
    else_scope: ^Ast_Scope,
    else_multi_statements: []^Ast_Statement,
}

Ast_For :: struct
{
    using base_statement: Ast_Statement,
    define: ^Ast_Define_Var,
    cond: ^Ast_Expr,
    iter: ^Ast_Assign,

    statements: []^Ast_Statement,
    scope: ^Ast_Scope,
}

Ast_Block :: struct
{
    using base_statement: Ast_Statement,
    statements: []^Ast_Statement,
    scope: ^Ast_Scope,
}

Ast_Break :: struct { using base_statement: Ast_Statement }
Ast_Continue :: struct { using base_statement: Ast_Statement }
Ast_Discard :: struct { using base_statement: Ast_Statement }

// Types

Ast_Type_Kind :: enum
{
    Poison = 0,
    None,  // "void" for returnless functions
    Unknown,  // For typeless initialization
    Label,
    Pointer,
    Array,
    Slice,
    Proc,
    Primitive,
    Struct,
}

Ast_Type_Primitive_Kind :: enum
{
    None = 0,
    Untyped_Int,
    Untyped_Float,
    Bool,
    Float,
    Uint,
    Int,
    Texture_ID,
    Texture_RW_ID,
    Sampler_ID,
    Vector,
    Matrix,
    String,

    Ray_Query,
    BVH_ID,
}

Ast_Type :: struct
{
    kind: Ast_Type_Kind,
    primitive_kind: Ast_Type_Primitive_Kind,  // Only populated if kind == .Primitive
    base: ^Ast_Type,
    decl: ^Ast_Decl,  // For .Label kind

    name: Token,

    // Applicable to pointer and slice types
    is_mut: bool,

    // Proc
    args: []^Ast_Decl,
    ret: ^Ast_Type,
    ret_attr: Maybe(Ast_Attribute),
    is_variadic: bool,

    // Struct
    members: []^Ast_Decl,

    // Array/vector/matrix
    dimensions: [2]u32,
}

parse_file :: proc(file: File, tokens: []Token, stage_hint: Shader_Stage, parse_tasks: ^[dynamic; MAX_FILES]Parse_Task, allocator: runtime.Allocator) -> (Ast, bool)
{
    context.allocator = allocator

    parser := Parser {
        tokens = tokens,
        file = file,
        stage_hint = stage_hint,
        parse_tasks = parse_tasks,
    }
    ast := _parse_file(&parser)
    return ast, !parser.error
}

Parser :: struct
{
    tokens: []Token,
    file: File,
    at: u32,
    error: bool,
    stage_hint: Shader_Stage,
    parse_tasks: ^[dynamic; MAX_FILES]Parse_Task,

    scope: ^Ast_Scope,
    used_types: [dynamic]Ast_Type,
    used_indirect_data_type: ^Ast_Type,
}

_parse_file :: proc(using p: ^Parser) -> Ast
{
    ast := Ast {
        scope = new(Ast_Scope)
    }

    scope = ast.scope
    top_of_file := true

    loop: for true
    {
        #partial switch tokens[at].type
        {
            case .Directive:
            {
                if tokens[at].text != "import" {
                    parse_error(p, "Unexpected directive.")
                }

                if !top_of_file {
                    parse_error(p, "'#import' must be at the top of the file.")
                }

                at += 1

                custom_module_name := tokens[at]
                custom_module_name_exists := optional_token(p, .Ident)

                import_path := tokens[at]
                required_token(p, .StrLit)

                // Build import path
                import_fullpath := str.concatenate({ fp.dir(file.filename), "/", import_path.text }, allocator = context.allocator)
                cleaned, err := os.clean_path(import_fullpath, allocator = context.allocator)
                ensure(err == nil)

                if !os.exists(cleaned)
                {
                    parse_error_on_token(p, import_path, "'%v' file does not exist.", cleaned)
                }
                else
                {
                    found_module: ^Parse_Task
                    for &module in parse_tasks {
                        if module.file.filename == cleaned {
                            found_module = &module
                            break
                        }
                    }

                    if found_module == nil
                    {
                        new_module := Parse_Task {
                            file = { filename = cleaned },
                            module_name = os.short_stem(cleaned)  // TODO: Disambiguate the name in the case of a name collision
                        }
                        append(parse_tasks, new_module)
                        found_module = &parse_tasks[len(parse_tasks)-1]
                    }

                    import_name := custom_module_name.text if custom_module_name_exists else os.short_stem(cleaned)
                    to_append := Ast_Import {
                        module_name = import_name,
                        info = found_module,
                    }
                    append(&ast.imports, to_append)
                }
            }
            case .Using:
            {
                if !top_of_file {
                    parse_error(p, "'using' must be at the top of the file.")
                }

                at += 1

                if tokens[at].type == .Ident
                {
                    using_ident := tokens[at]
                    found_import := false
                    for &ast_import in ast.imports
                    {
                        if ast_import.module_name == using_ident.text
                        {
                            ast_import.using_active = true
                            found_import = true
                            break
                        }
                    }

                    if !found_import {
                        parse_error(p, "'%v' not found in modules which were imported so far.", using_ident.text)
                    }

                    at += 1
                }
                else
                {
                    required_token(p, .Ident)
                }

                required_token(p, .Semi)
            }
            case .Ident:
            {
                if tokens[at+1].type == .Colon &&
                   tokens[at+2].type == .Colon &&
                   tokens[at+3].type == .Struct
                {
                    parse_struct_def(p)
                    top_of_file = false
                }
                else if tokens[at+1].type == .Colon &&
                        tokens[at+2].type == .Colon &&
                        (tokens[at+3].type == .LParen || (tokens[at+3].type == .Directive &&
                                                          tokens[at+4].type == .LParen))
                {
                    append(&ast.procs, parse_proc_def(p))
                    top_of_file = false
                }
                else if tokens[at+1].type == .Colon
                {
                    ident := tokens[at].text
                    at += 2

                    decl := make_node(p, Ast_Decl)
                    decl.name = ident
                    append(&scope.decls, decl)

                    type: ^Ast_Type
                    if tokens[at].type == .Assign
                    {
                        type = new(Ast_Type)
                        type.kind = .Unknown
                    }
                    else
                    {
                        type = parse_type(p)
                    }
                    decl.type = type

                    if optional_token(p, .Assign)
                    {
                        def_var := make_statement(p, Ast_Define_Var)
                        def_var.decl = decl
                        def_var.expr = parse_expr(p)
                        append(&ast.global_vars, def_var)
                    }

                    if tokens[at].type == .Attribute
                    {
                        decl.attr = parse_attribute(p)
                        if decl.attr.?.type == .Spec {
                            decl.constness = .Spectime
                        }
                    }

                    required_token(p, .Semi)
                    top_of_file = false
                }
                else
                {
                    parse_error(p, "Expecting struct, global variable or procedure at top level.")
                    break loop
                }
            }
            case .EOS: break loop
            case:
            {
                parse_error(p, "Expecting an identifier or a directive at top level.")
                break loop
            }
        }
    }

    ast.used_types = used_types
    ast.used_indirect_data_type = used_indirect_data_type
    return ast
}

parse_struct_def :: proc(using p: ^Parser) -> ^Ast_Decl
{
    node := make_node(p, Ast_Decl)
    append(&scope.decls, node)

    struct_type := new(Ast_Type)
    struct_type.kind = .Struct
    node.type = struct_type

    ident := required_token(p, .Ident)
    node.name = ident.text

    required_token(p, .Colon)
    required_token(p, .Colon)
    required_token(p, .Struct)
    required_token(p, .LBrace)
    struct_type.members = parse_decl_list(p, false)
    required_token(p, .RBrace)
    return node
}

parse_proc_def :: proc(using p: ^Parser) -> ^Ast_Proc_Def
{
    decl := make_node(p, Ast_Decl)
    append(&scope.decls, decl)

    proc_type := new(Ast_Type)
    proc_type.kind = .Proc
    decl.type = proc_type

    old_scope := scope
    scope = new(Ast_Scope)
    scope.enclosing_scope = old_scope
    defer scope = old_scope

    proc_def := new(Ast_Proc_Def)
    proc_def.decl = decl
    proc_def.scope = scope

    ident := required_token(p, .Ident)
    decl.name = ident.text

    required_token(p, .Colon)
    required_token(p, .Colon)

    directive := tokens[at]
    if optional_token(p, .Directive)
    {
        decl.is_entrypoint = true
        switch directive.text
        {
            case "vertex":   decl.entrypoint_stage = .Vertex
            case "fragment": decl.entrypoint_stage = .Fragment
            case "compute":  decl.entrypoint_stage = .Compute
            case:
            {
                parse_error(p, "Unexpected directive '%v', directives preceding '(' should describe a shader stage (e.g. 'vertex')", directive.text)
            }
        }
    }
    else if stage_hint != nil && decl.name == "main"
    {
        decl.is_entrypoint = true
        decl.entrypoint_stage = stage_hint
    }

    required_token(p, .LParen)
    proc_type.args = parse_decl_list(p, true)
    required_token(p, .RParen)

    if optional_token(p, .Arrow)
    {
        proc_type.ret = parse_type(p)
        if tokens[at].type == .Attribute {
            proc_type.ret_attr = parse_attribute(p)
        }
    }
    else
    {
        proc_type.ret = new(Ast_Type)
        proc_type.ret.kind = .None
    }

    required_token(p, .LBrace)
    if tokens[at].type != .RBrace {
        proc_def.statements = parse_statement_list(p)
    }
    required_token(p, .RBrace)
    return proc_def
}

parse_statement_list :: proc(using p: ^Parser) -> []^Ast_Statement
{
    scratch, _ := acquire_scratch()
    tmp_list := make([dynamic]^Ast_Statement, allocator = scratch)
    for true
    {
        stmt := parse_statement(p)
        if stmt != nil do append(&tmp_list, stmt)
        if tokens[at].type == .RBrace || tokens[at].type == .EOS do break
        if error do break
    }
    return slice.clone(tmp_list[:])
}

parse_statement :: proc(using p: ^Parser) -> ^Ast_Statement
{
    for optional_token(p, .Semi) {}

    node: ^Ast_Statement
    if optional_token(p, .If)
    {
        if_stmt := make_statement(p, Ast_If)
        if_stmt.cond = parse_expr(p)

        {
            old_scope := scope
            scope = new(Ast_Scope)
            scope.enclosing_scope = old_scope
            defer scope = old_scope

            if_stmt.scope = scope
            required_token(p, .LBrace)
            if tokens[at].type != .RBrace {
                if_stmt.statements = parse_statement_list(p)
            }
            required_token(p, .RBrace)
        }

        if optional_token(p, .Else)
        {
            if_stmt.else_is_present = true
            old_scope := scope
            if_stmt.else_scope = new(Ast_Scope)
            if_stmt.else_scope.enclosing_scope = old_scope
            defer scope = old_scope

            if tokens[at].type == .If
            {
                if_stmt.else_is_single = true
                if_stmt.else_single = parse_statement(p)
            }
            else
            {
                required_token(p, .LBrace)
                if tokens[at].type != .RBrace {
                    if_stmt.else_multi_statements = parse_statement_list(p)
                }
                required_token(p, .RBrace)
            }
        }

        node = if_stmt
    }
    else if optional_token(p, .For)
    {
        old_scope := scope
        scope = new(Ast_Scope)
        scope.enclosing_scope = old_scope
        defer scope = old_scope

        for_stmt := make_statement(p, Ast_For)
        for_stmt.scope = scope

        if tokens[at].type != .LBrace
        {
            if tokens[at].type != .Semi {
                for_stmt.define = parse_var_def(p)
            }
            required_token(p, .Semi)
            if tokens[at].type != .Semi {
                for_stmt.cond = parse_expr(p)
            }
            required_token(p, .Semi)
            if tokens[at].type != .LBrace {
                for_stmt.iter = parse_assign(p)
            }
        }

        required_token(p, .LBrace)

        if tokens[at].type != .RBrace {
            for_stmt.statements = parse_statement_list(p)
        }
        required_token(p, .RBrace)

        node = for_stmt
    }
    else if tokens[at].type == .LBrace
    {
        old_scope := scope
        scope = new(Ast_Scope)
        scope.enclosing_scope = old_scope
        defer scope = old_scope

        block_stmt := make_statement(p, Ast_Block)
        block_stmt.scope = scope

        at += 1

        if tokens[at].type != .RBrace {
            block_stmt.statements = parse_statement_list(p)
        }

        required_token(p, .RBrace)
        node = block_stmt
    }
    else if tokens[at].type == .Continue
    {
        stmt := make_statement(p, Ast_Continue)
        node = stmt
        at += 1
        required_token(p, .Semi)
    }
    else if tokens[at].type == .Break
    {
        stmt := make_statement(p, Ast_Break)
        node = stmt
        at += 1
        required_token(p, .Semi)
    }
    else if tokens[at].type == .Discard
    {
        stmt := make_statement(p, Ast_Discard)
        node = stmt
        at += 1
        required_token(p, .Semi)
    }
    else if tokens[at].type == .Ident && tokens[at+1].type == .Colon
    {
        ident := tokens[at].text
        at += 2

        decl := make_node(p, Ast_Decl)
        decl.name = ident
        append(&scope.decls, decl)

        type: ^Ast_Type
        if tokens[at].type == .Assign
        {
            type = new(Ast_Type)
            type.kind = .Unknown

            decl.has_init = true
        }
        else
        {
            type = parse_type(p)
        }
        decl.type = type

        if optional_token(p, .Assign)
        {
            def_var := make_statement(p, Ast_Define_Var)
            def_var.decl = decl
            def_var.expr = parse_expr(p)
            node = def_var

            decl.has_init = true
        }

        required_token(p, .Semi)
    }
    else
    {
        cursor := at
        for ; tokens[cursor].type != .Semi && !is_token_type_assign(tokens[cursor].type) && tokens[cursor].type != .EOS; cursor += 1 { }

        found_assign := is_token_type_assign(tokens[cursor].type)
        if found_assign
        {
            node = parse_assign(p)
        }
        else if tokens[at].type == .Return
        {
            ret_stmt := make_statement(p, Ast_Return)
            at += 1
            ret_stmt.expr = parse_expr(p)
            node = ret_stmt
        }
        else
        {
            stmt_expr := make_statement(p, Ast_Stmt_Expr)
            stmt_expr.expr = parse_expr(p)
            node = stmt_expr
        }

        required_token(p, .Semi)
    }

    return node
}

parse_assign :: proc(using p: ^Parser) -> ^Ast_Assign
{
    node := make_statement(p, Ast_Assign)
    node.lhs = parse_expr(p)
    node.token = tokens[at]
    #partial switch tokens[at].type
    {
        case .Plus_Equals, .Minus_Equals, .Mul_Equals, .Div_Equals, .Assign:
        {
            if tokens[at].type != .Assign do node.apply_op = true
            #partial switch tokens[at].type
            {
                case .Plus_Equals:  node.bin_op = .Add
                case .Minus_Equals: node.bin_op = .Minus
                case .Mul_Equals:   node.bin_op = .Mul
                case .Div_Equals:   node.bin_op = .Div
            }
        }
        case: parse_error(p, "Unexpected token '%v': expecting assignment", tokens[at].text)
    }
    at += 1

    node.rhs = parse_expr(p)
    return node
}

parse_var_def :: proc(using p: ^Parser) -> ^Ast_Define_Var
{
    ident := required_token(p, .Ident).text
    required_token(p, .Colon)

    decl := make_node(p, Ast_Decl)
    decl.name = ident
    append(&scope.decls, decl)

    type: ^Ast_Type
    if tokens[at].type == .Assign
    {
        type = new(Ast_Type)
        type.kind = .Unknown
    }
    else
    {
        type = parse_type(p)
    }
    decl.type = type

    required_token(p, .Assign)

    def_var := make_statement(p, Ast_Define_Var)
    def_var.decl = decl
    def_var.expr = parse_expr(p)
    return def_var
}

parse_var_decl :: proc(using p: ^Parser) -> ^Ast_Decl
{
    node := make_node(p, Ast_Decl)
    append(&scope.decls, node)

    ident := required_token(p, .Ident)
    node.name = ident.text

    required_token(p, .Colon)
    node.type = parse_type(p)
    return node
}

parse_expr :: proc(using p: ^Parser, prec: int = max(int)) -> ^Ast_Expr
{
    lhs: ^Ast_Expr

    // Prefix operators
    prefix_expr: ^Ast_Expr
    base_expr := &prefix_expr
    for
    {
        // Typecast
        if tokens[at].type == .Cast
        {
            tmp := make_expr(p, Ast_Cast)
            p.at += 1

            required_token(p, .LParen)
            tmp.type = parse_type(p)
            tmp.cast_to = tmp.type
            required_token(p, .RParen)

            base_expr^ = tmp
            base_expr = &tmp.expr
        }
        else
        {
            prefix_op_info, is_prefix := Prefix_Ops[tokens[at].type]
            if !is_prefix do break

            // Other prefix operators
            {
                tmp := make_expr(p, Ast_Unary_Expr)
                tmp.op = prefix_op_info.op
                base_expr^ = tmp
                base_expr = &tmp.expr
                p.at += 1
            }
        }
    }

    // Postfix operators
    lhs = parse_postfix_expr(p)

    // Postfix ops have precedence over prefix ops
    if prefix_expr != nil
    {
        base_expr^ = lhs
        lhs = prefix_expr
    }

    // Binary operators
    for true
    {
        op, found := Op_Precedence[tokens[at].type]
        undo_recurse := false
        undo_recurse |= !found
        undo_recurse |= op.prec > prec  // If it's less important (=greater priority) don't recurse.
        undo_recurse |= op.prec == prec && op.is_left_to_right  // Handle left-to-right vs right-to-left operators
        if undo_recurse do return lhs

        // Recurse
        if tokens[at].type == .If
        {
            if_expr := make_expr(p, Ast_If_Expr)
            at += 1
            if_expr.then_expr = lhs
            if_expr.cond_expr = parse_expr(p)
            required_token(p, .Else)
            if_expr.else_expr = parse_expr(p)
            lhs = if_expr
        }
        else
        {
            bin_op := make_expr(p, Ast_Binary_Expr)
            bin_op.op = op.op
            bin_op.lhs = lhs
            at += 1
            bin_op.rhs = parse_expr(p, op.prec)
            lhs = bin_op
        }
    }

    return lhs
}

parse_primary_expr :: proc(using p: ^Parser) -> ^Ast_Expr
{
    expr: ^Ast_Expr
    if optional_token(p, .LParen)
    {
        internal := parse_expr(p)
        required_token(p, .RParen)
        expr = internal
    }
    else if tokens[at].type == .Ident
    {
        expr = make_expr(p, Ast_Ident_Expr)
        at += 1
    }
    else if tokens[at].type == .IntLit || tokens[at].type == .FloatLit || tokens[at].type == .StrLit
    {
        expr = make_expr(p, Ast_Lit_Expr)
        at += 1
    }
    else if tokens[at].type == .True || tokens[at].type == .False
    {
        expr = make_expr(p, Ast_Lit_Expr)
        at += 1
    }

    return expr
}

parse_postfix_expr :: proc(using p: ^Parser) -> ^Ast_Expr
{
    expr := parse_primary_expr(p)
    loop: for true
    {
        #partial switch tokens[at].type
        {
            case .Dot:
            {
                member_access := make_expr(p, Ast_Member_Access)
                at += 1

                ident := required_token(p, .Ident)
                member_access.member = ident
                member_access.target = expr
                expr = member_access
            }
            case .LParen:
            {
                call := make_expr(p, Ast_Call)
                call.target = expr
                cast_expr := make_expr(p, Ast_Cast)
                at += 1

                if tokens[at].type != .RParen
                {
                    scratch, _ := acquire_scratch()
                    tmp_list := make([dynamic]^Ast_Expr, allocator = scratch)
                    for true
                    {
                        append(&tmp_list, parse_expr(p))
                        comma_present := optional_token(p, .Comma)
                        if !comma_present do break
                        if comma_present && (tokens[at].type == .RParen || tokens[at].type == .RBrace) do break
                        if error do break
                    }

                    call.args = slice.clone(tmp_list[:])
                }

                required_token(p, .RParen)

                expr = call

                // Check if this call is actually a cast operation.
                if len(call.args) == 1
                {
                    target, is_ident := call.target.derived_expr.(^Ast_Ident_Expr)
                    if is_ident
                    {
                        cast_to := make_primitive_type_from_string(target.token)
                        if cast_to != nil
                        {
                            cast_expr.cast_to = cast_to
                            cast_expr.expr = call.args[0]
                            expr = cast_expr
                        }
                    }
                }
            }
            case .LBracket:
            {
                array_access := make_expr(p, Ast_Array_Access)
                at += 1

                array_access.idx_expr = parse_expr(p)
                array_access.target = expr
                expr = array_access

                required_token(p, .RBracket)
            }
            case: break loop
        }
    }

    return expr
}

parse_decl_list :: proc(using p: ^Parser, add_to_scope: bool) -> []^Ast_Decl
{
    scratch, _ := acquire_scratch()
    tmp_list := make([dynamic]^Ast_Decl, allocator = scratch)
    for true
    {
        if tokens[at].type == .RParen || tokens[at].type == .RBrace do break
        if error do break

        append(&tmp_list, parse_decl_list_elem(p, add_to_scope))
        comma_present := optional_token(p, .Comma)
        if !comma_present do break
    }
    return slice.clone(tmp_list[:])
}

parse_decl_list_elem :: proc(using p: ^Parser, add_to_scope: bool) -> ^Ast_Decl
{
    node := make_node(p, Ast_Decl)
    if add_to_scope {
        append(&scope.decls, node)
    }

    ident := required_token(p, .Ident)
    required_token(p, .Colon)

    node.name = ident.text

    node.type = parse_type(p)
    node.attr = parse_attribute(p)
    if node.attr != nil
    {
        if node.attr.?.type == .Indirect_Data {
            used_indirect_data_type = node.type
        }
    }

    return node
}

parse_type :: proc(using p: ^Parser) -> ^Ast_Type
{
    base: ^Ast_Type
    node: ^Ast_Type

    for true
    {
        mut_token := tokens[at]
        is_mut := optional_token(p, .Mut)

        if optional_token(p, .LBracket)
        {
            if tokens[at].type == .IntLit
            {
                if is_mut
                {
                    parse_error_on_token(p, mut_token, "Expecting '^' or '[]' after 'mut'.")
                    return {}
                }

                num_token := tokens[at]
                at += 1

                array_type := new(Ast_Type)
                array_type.kind = .Array
                array_type.dimensions.x = u32(get_token_lit_int_value(num_token))
                if node != nil do node.base = array_type
                node = array_type
                if base == nil do base = node

                required_token(p, .RBracket)
            }
            else
            {
                slice_type := new(Ast_Type)
                slice_type.kind = .Slice
                slice_type.is_mut = is_mut
                if node != nil do node.base = slice_type
                node = slice_type
                if base == nil do base = node

                required_token(p, .RBracket)
            }
        }
        else if optional_token(p, .Caret)
        {
            ptr_type := new(Ast_Type)
            ptr_type.kind = .Pointer
            ptr_type.is_mut = is_mut
            if node != nil do node.base = ptr_type
            node = ptr_type
            if base == nil do base = node
        }
        else
        {
            if is_mut
            {
                parse_error_on_token(p, mut_token, "Expecting '^' or '[]' after 'mut'.")
                return {}
            }
            break
        }
    }

    ident := required_token(p, .Ident)
    ident_node := make_type_from_string(ident)
    if node != nil do node.base = ident_node
    node = ident_node
    if base == nil do base = node

    add_type_if_not_present(p, base)
    return base
}

parse_attribute :: proc(using p: ^Parser) -> Maybe(Ast_Attribute)
{
    if tokens[at].type != .Attribute do return nil

    attr := Ast_Attribute {}

    token := required_token(p, .Attribute)

    switch token.text
    {
        case "vert_id":              attr.type = .Vert_ID
        case "position":             attr.type = .Position
        case "data":                 attr.type = .Data
        case "instance_id":          attr.type = .Instance_ID
        case "draw_id":              attr.type = .Draw_ID
        case "indirect_data":        attr.type = .Indirect_Data
        case "workgroup_id":         attr.type = .Workgroup_ID
        case "local_invocation_id":  attr.type = .Local_Invocation_ID
        case "group_size":           attr.type = .Group_Size
        case "global_invocation_id": attr.type = .Global_Invocation_ID
        case "io":
        {
            // ??? Why is the compiler making me do this?
            attr.type, _ = .IO,
            required_token(p, .LParen)
            num_token := required_token(p, .IntLit)
            attr.id = u32(get_token_lit_int_value(num_token))

            if optional_token(p, .Comma)
            {
                for true
                {
                    #partial switch tokens[at].type
                    {
                        case .Flat: attr.specs += { .Flat }
                        case .Centroid: attr.specs += { .Centroid }
                        case .Noperspective: attr.specs += { .No_Perspective }
                        case: parse_error(p, "Unexpected token '%v': expecting an attribute specifier", tokens[at].text)
                    }

                    at += 1

                    comma_present := optional_token(p, .Comma)
                    if !comma_present do break
                    if comma_present && (tokens[at].type == .RParen || tokens[at].type == .RBrace) do break
                    if error do break
                }
            }

            required_token(p, .RParen)
        }
        case "spec":
        {
            attr.type, _ = .Spec,
            required_token(p, .LParen)
            num_token := required_token(p, .IntLit)
            attr.id = u32(get_token_lit_int_value(num_token))
            required_token(p, .RParen)
        }
        case:
        {
            parse_error(p, "Unknown attribute '%v'.", token.text)
        }
    }

    return attr
}

make_node :: proc(using p: ^Parser, $T: typeid) -> ^T
{
    node := new(T)
    node.token = tokens[at]
    return node
}

make_expr :: proc(using p: ^Parser, $T: typeid) -> ^T
{
    node := new(T)
    node.token = tokens[at]
    node.derived_expr = node
    return node
}

make_statement :: proc(using p: ^Parser, $T: typeid) -> ^T
{
    node := new(T)
    node.token = tokens[at]
    node.derived_statement = node
    return node
}

parse_error :: proc(using p: ^Parser, fmt_str: string, args: ..any)
{
    parse_error_on_token(p, tokens[at], fmt_str, ..args)
}

parse_error_on_token :: proc(using p: ^Parser, token: Token, fmt_str: string, args: ..any)
{
    if error do return

    error_msg(file, token, fmt_str, ..args)
    error = true
}

required_token :: proc(using p: ^Parser, type: Token_Type) -> Token
{
    if tokens[at].type != type
    {
        parse_error(p, "Unexpected token '%v': expecting '%v'", tokens[at].text, token_type_to_string(type))
        return {}
    }

    at += 1
    return tokens[at-1]
}

optional_token :: proc(using p: ^Parser, type: Token_Type) -> bool
{
    if tokens[at].type == type
    {
        at += 1
        return true
    }

    return false
}

// Operator precedence
Op_Info :: struct #all_or_none
{
    prec: int,
    op: Ast_Binary_Op,
    is_left_to_right: bool,
}
Op_Precedence := map[Token_Type]Op_Info {
    .Mul = { 3, .Mul, true },
    .Div = { 3, .Div, true },
    .Modulo = { 3, .Modulo, true },

    .Plus  = { 4, .Add, true },
    .Minus = { 4, .Minus, true },

    .LShift = { 5, .LShift, true },
    .RShift = { 5, .RShift, true },

    .Greater = { 6, .Greater, true },
    .Less    = { 6, .Less, true },
    .GE      = { 6, .GE, true },
    .LE      = { 6, .LE, true },

    .EQ      = { 7, .EQ, true },
    .NEQ     = { 7, .NEQ, true },

    .Bitwise_And = { 8, .Bitwise_And, true },
    .Bitwise_Xor = { 9, .Bitwise_Xor, true },
    .Bitwise_Or  = { 10, .Bitwise_Or, true },

    .And = { 11, .And, true },
    .Or  = { 12, .Or, true },

    // Special operators (need special logic)
    .If = { 13, {}, false },
}
Unary_Op_Info :: struct #all_or_none
{
    op: Ast_Unary_Op,
}
Prefix_Ops := map[Token_Type]Unary_Op_Info {
    .Not = { .Not },
    .Minus = { .Minus },
    .Plus = { .Plus },
}

add_type_if_not_present :: proc(using p: ^Parser, type: ^Ast_Type)
{
    if type == nil do return

    for &used in used_types {
        if same_type(type, &used) do return
    }

    append(&used_types, type^)
}

type_to_string :: proc(type: ^Ast_Type, arena: runtime.Allocator) -> string
{
    scratch, _ := acquire_scratch(arena)
    if type == nil do return "NIL"

    res: string
    switch type.kind
    {
        case .Poison:    res = "POISON"
        case .None:      res = "none"
        case .Unknown:   res = "UNKNOWN"
        case .Label:     res = type.name.text
        case .Pointer:   res = str.concatenate({ "mut" if type.is_mut else "",  "^", type_to_string(type.base, scratch) }, allocator = scratch)
        case .Slice:     res = str.concatenate({ "mut" if type.is_mut else "", "[]", type_to_string(type.base, scratch) }, allocator = scratch)
        case .Array:
        {
            scratch2, _ := acquire_scratch(scratch, arena)
            sb := str.builder_make_none(allocator = scratch2)
            fmt.sbprintf(&sb, "[%v]", type.dimensions.x)
            str.write_string(&sb, type_to_string(type.base, arena = scratch))
            res = str.clone(str.to_string(sb), allocator = scratch)
        }
        case .Proc:
        {
            scratch2, _ := acquire_scratch(scratch, arena)
            sb := str.builder_make_none(allocator = scratch2)
            str.write_string(&sb, "(")
            for arg, i in type.args
            {
                str.write_string(&sb, type_to_string(arg.type, arena = scratch))
                if i < len(type.args) - 1 do str.write_string(&sb, ", ")
            }
            str.write_string(&sb, ")")
            if type.ret == nil
            {
                str.write_string(&sb, " -> ")
                str.write_string(&sb, type_to_string(type.ret, arena = scratch))
            }

            res = str.clone(str.to_string(sb), allocator = scratch)
        }
        case .Primitive:  res = type.name.text
        case .Struct:
        {
            scratch2, _ := acquire_scratch(scratch, arena)
            sb := str.builder_make_none(allocator = scratch2)
            str.write_string(&sb, "(")
            for member, i in type.members
            {
                str.write_string(&sb, type_to_string(member.type, arena = scratch))
                if i < len(type.members) - 1 do str.write_string(&sb, ", ")
            }
            str.write_string(&sb, ")")
            if type.ret == nil
            {
                str.write_string(&sb, " -> ")
                str.write_string(&sb, type_to_string(type.ret, arena = scratch))
            }

            res = str.clone(str.to_string(sb), allocator = scratch)
        }
    }

    return str.clone(res, allocator = arena)
}

make_vec_type :: proc(base_type: ^Ast_Type, dim: u32) -> ^Ast_Type
{
    assert(dim > 1)
    node := new(Ast_Type)

    prefix := ""
    if base_type.primitive_kind == .Float {
        prefix = ""
    } else if base_type.primitive_kind == .Int {
        prefix = "i"
    } else if base_type.primitive_kind == .Uint {
        prefix = "u"
    } else if base_type.primitive_kind == .Bool {
        prefix = "b"
    } else {
        panic("Not supported.")
    }
    node.name.text = str.clone(fmt.tprintf("%vvec%v", prefix, dim))

    node.kind = .Primitive
    node.primitive_kind = .Vector
    node.dimensions = { dim, 1 }
    node.base = base_type
    return node
}

make_type_from_string :: proc(name: Token) -> ^Ast_Type
{
    prim_type := make_primitive_type_from_string(name)
    if prim_type != nil do return prim_type

    node := new(Ast_Type)
    node.name = name
    node.kind = .Label
    return node
}

make_primitive_type_from_string :: proc(name: Token) -> ^Ast_Type
{
    prim_type: Ast_Type_Primitive_Kind
    dimensions: [2]u32
    base_type: ^Ast_Type
    switch name.text
    {
        case "float":         prim_type = .Float
        case "uint":          prim_type = .Uint
        case "int":           prim_type = .Int

        case "vec2":          prim_type = .Vector; dimensions = { 2, 1 }; base_type = &FLOAT_TYPE
        case "vec3":          prim_type = .Vector; dimensions = { 3, 1 }; base_type = &FLOAT_TYPE
        case "vec4":          prim_type = .Vector; dimensions = { 4, 1 }; base_type = &FLOAT_TYPE

        case "ivec2":         prim_type = .Vector; dimensions = { 2, 1 }; base_type = &INT_TYPE
        case "ivec3":         prim_type = .Vector; dimensions = { 3, 1 }; base_type = &INT_TYPE
        case "ivec4":         prim_type = .Vector; dimensions = { 4, 1 }; base_type = &INT_TYPE

        case "uvec2":         prim_type = .Vector; dimensions = { 2, 1 }; base_type = &UINT_TYPE
        case "uvec3":         prim_type = .Vector; dimensions = { 3, 1 }; base_type = &UINT_TYPE
        case "uvec4":         prim_type = .Vector; dimensions = { 4, 1 }; base_type = &UINT_TYPE

        case "bvec2":         prim_type = .Vector; dimensions = { 2, 1 }; base_type = &BOOL_TYPE
        case "bvec3":         prim_type = .Vector; dimensions = { 3, 1 }; base_type = &BOOL_TYPE
        case "bvec4":         prim_type = .Vector; dimensions = { 4, 1 }; base_type = &BOOL_TYPE

        case "bool":          prim_type = .Bool
        case "texture_id":    prim_type = .Texture_ID
        case "texture_rw_id": prim_type = .Texture_RW_ID
        case "sampler_id":    prim_type = .Sampler_ID

        case "mat2":          prim_type = .Matrix; dimensions = { 2, 2 }; base_type = &FLOAT_TYPE
        case "mat2x3":        prim_type = .Matrix; dimensions = { 2, 3 }; base_type = &FLOAT_TYPE
        case "mat2x4":        prim_type = .Matrix; dimensions = { 2, 4 }; base_type = &FLOAT_TYPE
        case "mat3":          prim_type = .Matrix; dimensions = { 3, 3 }; base_type = &FLOAT_TYPE
        case "mat3x2":        prim_type = .Matrix; dimensions = { 3, 2 }; base_type = &FLOAT_TYPE
        case "mat3x4":        prim_type = .Matrix; dimensions = { 3, 4 }; base_type = &FLOAT_TYPE
        case "mat4":          prim_type = .Matrix; dimensions = { 4, 4 }; base_type = &FLOAT_TYPE
        case "mat4x2":        prim_type = .Matrix; dimensions = { 4, 2 }; base_type = &FLOAT_TYPE
        case "mat4x3":        prim_type = .Matrix; dimensions = { 4, 3 }; base_type = &FLOAT_TYPE

        case "imat2":         prim_type = .Matrix; dimensions = { 2, 2 }; base_type = &INT_TYPE
        case "imat2x3":       prim_type = .Matrix; dimensions = { 2, 3 }; base_type = &INT_TYPE
        case "imat2x4":       prim_type = .Matrix; dimensions = { 2, 4 }; base_type = &INT_TYPE
        case "imat3":         prim_type = .Matrix; dimensions = { 3, 3 }; base_type = &INT_TYPE
        case "imat3x2":       prim_type = .Matrix; dimensions = { 3, 2 }; base_type = &INT_TYPE
        case "imat3x4":       prim_type = .Matrix; dimensions = { 3, 4 }; base_type = &INT_TYPE
        case "imat4":         prim_type = .Matrix; dimensions = { 4, 4 }; base_type = &INT_TYPE
        case "imat4x2":       prim_type = .Matrix; dimensions = { 4, 2 }; base_type = &INT_TYPE
        case "imat4x3":       prim_type = .Matrix; dimensions = { 4, 3 }; base_type = &INT_TYPE

        case "umat2":         prim_type = .Matrix; dimensions = { 2, 2 }; base_type = &UINT_TYPE
        case "umat2x3":       prim_type = .Matrix; dimensions = { 2, 3 }; base_type = &UINT_TYPE
        case "umat2x4":       prim_type = .Matrix; dimensions = { 2, 4 }; base_type = &UINT_TYPE
        case "umat3":         prim_type = .Matrix; dimensions = { 3, 3 }; base_type = &UINT_TYPE
        case "umat3x2":       prim_type = .Matrix; dimensions = { 3, 2 }; base_type = &UINT_TYPE
        case "umat3x4":       prim_type = .Matrix; dimensions = { 3, 4 }; base_type = &UINT_TYPE
        case "umat4":         prim_type = .Matrix; dimensions = { 4, 4 }; base_type = &UINT_TYPE
        case "umat4x2":       prim_type = .Matrix; dimensions = { 4, 2 }; base_type = &UINT_TYPE
        case "umat4x3":       prim_type = .Matrix; dimensions = { 4, 3 }; base_type = &UINT_TYPE

        case "Ray_Query":     prim_type = .Ray_Query
        case "bvh_id":        prim_type = .BVH_ID
        case:                 return nil
    }

    node := new(Ast_Type)
    node.name = name
    node.base = base_type
    node.kind = .Primitive
    node.primitive_kind = prim_type
    node.dimensions = dimensions
    return node
}

is_bin_op_comparison :: proc(op: Ast_Binary_Op) -> bool
{
    switch op
    {
        case .Add, .Minus, .Mul, .Div, .Modulo: return false
        case .Bitwise_And, .Bitwise_Or, .Bitwise_Xor, .LShift, .RShift: return false
        case .And, .Or: return false

        case .Greater: return true
        case .Less:    return true
        case .LE:      return true
        case .GE:      return true
        case .EQ:      return true
        case .NEQ:     return true
    }
    return false
}
