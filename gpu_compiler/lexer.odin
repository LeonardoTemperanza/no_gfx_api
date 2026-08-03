
#+feature dynamic-literals
#+feature using-stmt

package main

import "core:fmt"
import "core:strconv"
import "base:runtime"

import "core:sys/windows"

Token_Type :: enum
{
    Unknown = 0,

    // Parens
    LParen,   // (
    RParen,   // )
    LBracket, // [
    RBracket, // ]
    LBrace,   // {
    RBrace,   // }

    // Operator types
    Plus,
    Minus,
    Mul,
    Div,
    Modulo,
    Greater,
    Less,
    Assign,
    Dot,
    Comma,
    Colon,
    Semi,
    Caret,

    Bitwise_And,
    Bitwise_Or,
    Bitwise_Xor,
    LShift,
    RShift,

    And,
    Or,
    Not,

    LE,
    GE,
    EQ,
    NEQ,
    Plus_Equals,
    Minus_Equals,
    Mul_Equals,
    Div_Equals,

    Ident,
    Attribute,  // Identifier with @ in front
    Directive,  // Identifier with # in front
    // Qualifiers
    Flat,
    Noperspective,
    Centroid,

    Arrow,  // For function return types

    // Keywords
    Struct,
    If,
    Else,
    For,
    Break,
    Continue,
    Return,
    Discard,
    Cast,
    Mut,
    Using,

    // Literals
    IntLit,
    FloatLit,
    StrLit,  // For printf.
    True,
    False,

    // Lexer message types
    EOS,  // End of stream
}

Keywords := map[string]Token_Type {
    "struct" = .Struct,
    "if"     = .If,
    "else"   = .Else,
    "for"    = .For,
    "break"  = .Break,
    "continue" = .Continue,
    "discard"  = .Discard,
    "return" = .Return,
    "true"   = .True,
    "false"  = .False,
    "cast"   = .Cast,
    "flat"   = .Flat,
    "no_perspective" = .Noperspective,
    "centroid" = .Centroid,
    "mut" = .Mut,
    "using" = .Using,
}
One_Char_Operators := map[u8]Token_Type {
    '(' = .LParen,
    ')' = .RParen,
    '[' = .LBracket,
    ']' = .RBracket,
    '{' = .LBrace,
    '}' = .RBrace,
    '+' = .Plus,
    '-' = .Minus,
    '*' = .Mul,
    '/' = .Div,
    '%' = .Modulo,
    '>' = .Greater,
    '<' = .Less,
    '=' = .Assign,
    '.' = .Dot,
    ',' = .Comma,
    ':' = .Colon,
    ';' = .Semi,
    '^' = .Caret,
    '&' = .Bitwise_And,
    '|' = .Bitwise_Or,
    '~' = .Bitwise_Xor,
    '!' = .Not,
}
Two_Char_Operators := map[string]Token_Type {
    "<=" = .LE,
    ">=" = .GE,
    "==" = .EQ,
    "!=" = .NEQ,
    "+=" = .Plus_Equals,
    "-=" = .Minus_Equals,
    "*=" = .Mul_Equals,
    "/=" = .Div_Equals,
    "->" = .Arrow,
    "&&" = .And,
    "||" = .Or,
    "<<" = .LShift,
    ">>" = .RShift,
}

Token :: struct
{
    type: Token_Type,
    text: string,

    line: u32,
    col_start: u32,
    offset: u32,  // Offset into file
}

lex_file :: proc(file: File, allocator: runtime.Allocator) -> []Token
{
    filename := file.filename
    file_content := file.content

    tokens := make([dynamic]Token, allocator = allocator)

    lexer := Lexer {
        filename = filename,
        buf = file_content
    }
    for true
    {
        token := next_token(&lexer)
        append(&tokens, token)
        if token.type == .EOS do break
    }

    return tokens[:]
}

Lexer :: struct
{
    filename: string,
    buf: []u8,
    offset: u32,
    line: u32,
    line_start: u32,
    comment_nest_level: bool
}

File :: struct
{
    filename: string,
    content: []u8,
}

next_token :: proc(using lexer: ^Lexer) -> Token
{
    eat_all_whitespace(lexer)

    token := Token {
        type = .EOS,
        text = "",
        line = line,
        col_start = offset - line_start,
        offset = offset,
    }

    if buf[offset] == 0
    {
        // Null terminator found
    }
    else if is_ident_begin(buf[offset]) || buf[offset] == '@' || buf[offset] == '#'
    {
        if buf[offset] == '@'
        {
            token.type = .Attribute
            offset += 1
        }
        else if buf[offset] == '#'
        {
            token.type = .Directive
            offset += 1
        }
        else
        {
            token.type = .Ident
        }

        old_offset := offset
        for ; is_ident_middle(buf[offset]); offset += 1 {}
        token.text = string(buf[old_offset:offset])

        if token.type == .Ident
        {
            token_type, is_keyword := Keywords[token.text]
            if is_keyword do token.type = token_type
        }
    }
    else if is_num(buf[offset])
    {
        old_offset := offset
        is_int := true
        for ; is_num_middle(buf[offset]); offset += 1 {
            if buf[offset] == '.' do is_int = false
        }

        num_str := string(buf[old_offset:offset])
        token.text = num_str

        if is_int
        {
            token.type = .IntLit
            _, ok := strconv.parse_u64_maybe_prefixed(num_str)
            if !ok do token.type = .Unknown
        }
        else
        {
            token.type = .FloatLit
            _, ok := strconv.parse_f32(num_str)
            if !ok do token.type = .Unknown
        }
    }
    else if buf[offset] == '"'
    {
        offset += 1
        begin_offset := offset
        for true
        {
            if offset >= u32(len(buf)) do break

            if is_newline(buf[offset])
            {
                offset += 1
                line_start = offset
                line += 1
            }
            else if buf[offset] != '"'
            {
                offset += 1
            }
            else do break
        }

        token.type = .StrLit
        token.text = string(buf[begin_offset:offset])
        if offset >= u32(len(buf)) do error_msg(File { filename, buf }, token, "String literal does not have an end.")

        offset += 1
    }
    else  // Operators, parentheses, etc.
    {
        two_chars := string(buf[offset:offset+2])
        twochar_op_type, is_twochar_op := Two_Char_Operators[two_chars]
        if is_twochar_op
        {
            offset += 2
            token.text = two_chars
            token.type = twochar_op_type
        }
        else
        {
            one_char := string(buf[offset:offset+1])
            onechar_op_type, is_onechar_op := One_Char_Operators[buf[offset]]
            token.type = onechar_op_type if is_onechar_op else .Unknown
            token.text = one_char
            offset += 1
        }
    }

    return token
}

eat_all_whitespace :: proc(using lexer: ^Lexer)
{
    for true
    {
        if is_newline(buf[offset])
        {
            offset += 1
            line_start = offset
            line += 1
        }
        else if is_whitespace(buf[offset])
        {
            offset += 1
        }
        else if buf[offset] == '/' && buf[offset+1] == '/'
        {
            offset += 2
            for !is_newline(buf[offset]) && buf[offset] != 0 {
                offset += 1
            }
        }
        else if buf[offset] == '/' && buf[offset+1] == '*'
        {
            offset += 2
            nest_level := 1
            for nest_level > 0
            {
                if buf[offset] == 0 do break

                if is_newline(buf[offset])
                {
                    offset += 1
                    line_start = offset
                    line += 1
                }
                else if buf[offset] == '*' && buf[offset+1] == '/'
                {
                    offset += 2
                    nest_level -= 1
                }
                else if buf[offset] == '/' && buf[offset+1] == '*'
                {
                    offset += 2
                    nest_level += 1
                }
                else
                {
                    offset += 1
                }
            }
        }
        else do break
    }
}

@(private="file")
MSG_AFTER: string
set_msg_after :: proc(after: string)
{
    MSG_AFTER = after
}

error_msg :: proc(file: File, token: Token, fmt_str: string, args: ..any)
{
    // Reset globals
    defer MSG_AFTER = ""

    if supports_ansi() {
        fmt.printf("%v(%v:%v): %vError%v: ", file.filename, token.line+1, token.col_start+1, "\033[31m", "\033[0m")
    } else {
        fmt.printf("%v(%v:%v): Error: ", file.filename, token.line+1, token.col_start+1)
    }
    fmt.printfln(fmt_str, ..args)
    fmt.print("\t")

    // Find and print line of code
    offset_begin := token.offset
    for
    {
        if offset_begin == 0 || is_newline(file.content[offset_begin - 1]) {
            break
        }

        offset_begin -= 1
    }
    // Go to first non blank char
    whitespace_count := 0
    for
    {
        if offset_begin >= u32(len(file.content)) || !is_whitespace(file.content[offset_begin]) {
            break
        }

        offset_begin += 1
        whitespace_count += 1
    }

    offset_end := token.offset
    for
    {
        if offset_end+1 >= u32(len(file.content)) || is_newline(file.content[offset_end + 1]) {
            break
        }

        offset_end += 1
    }

    if len(token.text) == 0 do return

    loc := string(file.content[offset_begin:offset_end+1])
    fmt.println(loc)

    // Print token underline
    {
        fmt.print("\t")
        for _ in 0..<int(token.col_start)-whitespace_count {
            fmt.print(" ")
        }

        assert(len(token.text) > 0)
        if len(token.text) == 1
        {
            fmt.print("^")
        }
        else
        {
            fmt.print("^")
            for _ in 0..<len(token.text)-2 {
                fmt.print("~")
            }
            fmt.print("^")
        }

        fmt.print("\n")
    }

    // Print "after message"
    {
        fmt.print(MSG_AFTER)
    }
}

// Utils

supports_ansi :: proc() -> bool
{
    when ODIN_OS == .Windows
    {
        // Check if stdout is being redirected (not a real terminal)
        handle := windows.GetStdHandle(windows.STD_OUTPUT_HANDLE)
        mode: windows.DWORD
        if !windows.GetConsoleMode(handle, &mode) {
            return false  // not a real console (redirected or unsupported terminal)
        }
        return true
    }
    else
    {
        return true
    }
}

is_alpha :: #force_inline proc(c: u8) -> bool
{
    return ((c >= 'a') && (c <= 'z')) || ((c >= 'A') && (c <= 'Z'));
}

is_num :: #force_inline proc(c: u8) -> bool
{
    return c >= '0' && c <= '9';
}

is_whitespace :: #force_inline proc(c: u8) -> bool
{
    return (c == ' ') ||
        (c == '\t') ||
        (c == '\v') ||
        (c == '\f') ||
        (c == '\r') ||
        is_newline(c);
}

is_ident_begin :: #force_inline proc(c: u8) -> bool
{
    return is_alpha(c) || c == '_'
}

is_ident_middle :: #force_inline proc(c: u8) -> bool
{
    return is_ident_begin(c) || is_num(c)
}

is_num_middle :: #force_inline proc(c: u8) -> bool
{
    return is_num(c) || c == '.' || c == 'e' || c == 'x' || is_alpha(c);
}

is_newline :: #force_inline proc(c: u8) -> bool
{
    return c == '\n'
}

token_type_to_string :: proc(type: Token_Type) -> string
{
    switch type
    {
        case .Unknown:      return "UNKNOWN"
        case .LParen:       return "("
        case .RParen:       return ")"
        case .LBracket:     return "["
        case .RBracket:     return "]"
        case .LBrace:       return "{"
        case .RBrace:       return "}"
        case .Plus:         return "+"
        case .Minus:        return "-"
        case .Mul:          return "*"
        case .Div:          return "/"
        case .Modulo:       return "%"
        case .Greater:      return ">"
        case .Less:         return "<"
        case .Assign:       return "="
        case .Dot:          return "."
        case .Comma:        return ","
        case .Colon:        return ":"
        case .Semi:         return ";"
        case .Caret:        return "^"
        case .Bitwise_And:  return "&"
        case .Bitwise_Or:   return "|"
        case .Bitwise_Xor:  return "~"
        case .LShift:       return "<<"
        case .RShift:       return ">>"
        case .And:          return "&&"
        case .Or:           return "||"
        case .Not:          return "!"
        case .LE:           return "<="
        case .GE:           return ">="
        case .EQ:           return "=="
        case .NEQ:          return "!="
        case .Plus_Equals:  return "+="
        case .Minus_Equals: return "-="
        case .Mul_Equals:   return "*="
        case .Div_Equals:   return "/="
        case .Ident:        return "identifier"
        case .Attribute:    return "attribute"
        case .Directive:    return "directive"
        case .Flat:         return "flat"
        case .Noperspective:return "no_perspective"
        case .Centroid:     return "centroid"
        case .Mut:          return "mut"
        case .Arrow:        return "->"
        case .Struct:       return "struct"
        case .If:           return "if"
        case .Else:         return "else"
        case .For:          return "for"
        case .Break:        return "break"
        case .Continue:     return "continue"
        case .Discard:      return "discard"
        case .Return:       return "return"
        case .Using:        return "using"
        case .IntLit:       return "integer literal"
        case .FloatLit:     return "floating point literal"
        case .StrLit:       return "string literal"
        case .True:         return "true"
        case .False:        return "false"
        case .Cast:         return "cast"
        case .EOS:          return "end of file"
    }
    return "UNKNOWN"
}

get_token_lit_int_value :: proc(token: Token) -> u64
{
    assert(token.type == .IntLit)

    value, ok := strconv.parse_u64_maybe_prefixed(token.text)
    assert(ok)

    return value
}

is_token_type_assign :: proc(type: Token_Type) -> bool
{
    #partial switch type
    {
        case .Assign:       return true
        case .Plus_Equals:  return true
        case .Minus_Equals: return true
        case .Mul_Equals:   return true
        case .Div_Equals:   return true
    }
    return false
}
