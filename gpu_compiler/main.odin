
package main

import "core:fmt"
import "core:os"
import "core:mem"
import vmem "core:mem/virtual"
import "base:runtime"
import fp "core:path/filepath"
import "core:slice"
import "core:math"
import "core:flags"
import "core:strings"

import "core:sys/windows"

import glslang "glslang_odin"

Options :: struct
{
    file: ^os.File `args:"pos=0,required,file=r" usage:"Input file."`,
    out: string `args:"pos=1" usage:"Output file. Default: 'output(.entry_name)'. Can omit '.spv' extension."`,
    print_glsl: bool `usage:"Print transpiled GLSL output."`,
}

MAX_FILES :: 100

main :: proc()
{
    opt: Options
    flags.parse_or_exit(&opt, os.args, .Odin)

    if opt.out == "" do opt.out = "./output"

    when ODIN_OS == .Windows
    {
        handle := windows.GetStdHandle(windows.STD_OUTPUT_HANDLE)
        mode: windows.DWORD
        windows.GetConsoleMode(handle, &mode)
        windows.SetConsoleMode(handle, mode | windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING)
    }

    init_scratch_arenas()

    perm_arena_backing: vmem.Arena
    ok_a := vmem.arena_init_growing(&perm_arena_backing)
    assert(ok_a == nil)
    perm_arena := vmem.arena_allocator(&perm_arena_backing)
    defer free_all(perm_arena)

    input_path := os.args[1]
    shader_stage_str := fp.ext(fp.stem(input_path))
    shader_stage_hint: Shader_Stage
    if shader_stage_str == ".vert" {
        shader_stage_hint = .Vertex
    } else if shader_stage_str == ".frag" {
        shader_stage_hint = .Fragment
    } else if shader_stage_str == ".comp" {
        shader_stage_hint = .Compute
    }

    output_prefix := strings.concatenate({ fp.dir(opt.out), "/", fp.short_stem(opt.out) }, allocator = perm_arena)

    parse_tasks: [dynamic; MAX_FILES]Parse_Task
    append(&parse_tasks, Parse_Task { file = { filename = input_path }, is_main = true})

    ok_parse := true
    for true
    {
        all_done := true
        for &task in parse_tasks
        {
            if !task.parsed
            {
                if !task.loaded
                {
                    file_content, ok := load_file_and_null_terminate(task.file.filename, allocator = perm_arena)
                    if !ok
                    {
                        fmt.printfln("Error: Failed to read file '%v'.", task.file.filename)
                        os.exit(1)
                    }
                    task.file.content = file_content
                    task.loaded = true
                }

                tokens := lex_file(task.file, allocator = perm_arena)
                ast, ok_p := parse_file(task.file, tokens, shader_stage_hint, &parse_tasks, allocator = perm_arena)
                if !ok_p do ok_parse = false

                task.parsed = true
                task.ast = ast
                all_done = false
            }
        }

        if all_done do break
    }
    if !ok_parse do os.exit(1)

    if !typecheck_files(&parse_tasks, allocator = perm_arena) {
        os.exit(1)
    }

    glsl_source := codegen_files(&parse_tasks)

    ok_c := output_all_spirv_files(glsl_source, input_path, output_prefix, parse_tasks[0].ast, shader_stage_hint)
    if !ok_c do os.exit(1)

    if opt.print_glsl {
        print_file_with_line_nums(glsl_source)
    }
}

Parse_Task :: struct
{
    file: File,
    loaded: bool,
    parsed: bool,
    ast: Ast,
    is_main: bool,
    module_name: string,
}

load_file_and_null_terminate :: proc(path: string, allocator: runtime.Allocator) -> ([]u8, bool)
{
    file_content, err := os.read_entire_file_from_path(path, allocator = context.allocator)
    if err != nil do return {}, false
    defer delete(file_content)

    file_content_null_term := make([]u8, len(file_content) + 1, allocator = allocator)
    copy(file_content_null_term[:], file_content[:])
    file_content_null_term[len(file_content)] = 0
    return file_content_null_term, true
}

// Scratch arenas

scratch_arenas: [4]vmem.Arena

init_scratch_arenas :: proc()
{
    for &scratch in scratch_arenas
    {
        error := vmem.arena_init_growing(&scratch)
        assert(error == nil)
    }
}

@(deferred_out = release_scratch)
acquire_scratch :: proc(used_allocators: ..mem.Allocator) -> (mem.Allocator, vmem.Arena_Temp)
{
    available_arena: ^vmem.Arena
    if len(used_allocators) < 1
    {
        available_arena = &scratch_arenas[0]
    }
    else
    {
        for &scratch in scratch_arenas
        {
            for used_alloc in used_allocators
            {
                // NOTE: We assume that if the data points to the same exact address,
                // it's an arena allocator and it's the same arena
                if used_alloc.data != &scratch
                {
                    available_arena = &scratch
                    break
                }

                if available_arena != nil do break
            }
        }
    }

    assert(available_arena != nil, "Available scratch arena not found.")

    return vmem.arena_allocator(available_arena), vmem.arena_temp_begin(available_arena)
}

release_scratch :: #force_inline proc(allocator: mem.Allocator, temp: vmem.Arena_Temp)
{
    vmem.arena_temp_end(temp)
}

output_all_spirv_files :: proc(glsl_source: string, input_path: string, output_prefix: string, ast: Ast, stage_hint: Shader_Stage) -> bool
{
    scratch, _ := acquire_scratch()
    for proc_def in ast.procs
    {
        decl := proc_def.decl
        if decl.is_entrypoint
        {
            sb := strings.builder_make_none(allocator = scratch)
            strings.write_string(&sb, output_prefix)
            strings.write_string(&sb, ".")
            switch stage_hint
            {
                case .None:     strings.write_string(&sb, decl.name);
                case .Vertex:   strings.write_string(&sb, "vert");
                case .Fragment: strings.write_string(&sb, "frag");
                case .Compute:  strings.write_string(&sb, "comp");
            }
            strings.write_string(&sb, ".spv")
            output_path := strings.to_string(sb)

            stage := stage_hint if stage_hint != nil else decl.entrypoint_stage
            compile_glsl_to_spirv(stage, glsl_source, input_path, output_path, decl.name) or_return
        }
    }

    return true
}

compile_glsl_to_spirv :: proc(shader_type: Shader_Stage, glsl_source: string, input_path: string, output_path: string, entrypoint: string) -> bool
{
    stage: glslang.Stage
    switch shader_type
    {
        case .None:     panic("Unreachable")
        case .Vertex:   stage = .VERTEX
        case .Fragment: stage = .FRAGMENT
        case .Compute:  stage = .COMPUTE
    }

    scratch, _ := acquire_scratch()

    sb := strings.builder_make_none(allocator = scratch)
    strings.write_string(&sb, "#define _res_entry_")
    strings.write_string(&sb, entrypoint)
    strings.write_string(&sb, "\n")
    switch shader_type
    {
        case .None:     panic("Unreachable")
        case .Vertex:   strings.write_string(&sb, "#define _res_type_graphics_\n")
        case .Fragment: strings.write_string(&sb, "#define _res_type_graphics_\n")
        case .Compute:  strings.write_string(&sb, "#define _res_type_compute_\n")
    }
    strings.write_string(&sb, glsl_source)

    glsl_source_processed := strings.to_cstring(&sb)

    input := glslang.input_t {
        language = .GLSL,
        stage = stage,
        client = .VULKAN,
        client_version = .VULKAN_1_3,
        target_language = .SPV,
        target_language_version = .SPV_1_5,
        code = glsl_source_processed,
        default_version = 460,
        default_profile = .NO_PROFILE,
        force_default_version_and_profile = false,
        forward_compatible = false,
        messages = .DEFAULT_BIT,
        resource = glslang.default_resource(),
    }

    shader := glslang.shader_create(&input)
    defer glslang.shader_delete(shader)

    if glslang.shader_preprocess(shader, &input) == 0
    {
        fmt.printf("%s: GLSL preprocessing failed. This is a bug, please report.\n", input_path)
        fmt.printf("%s\n", glslang.shader_get_info_log(shader))
        fmt.printf("%s\n", glslang.shader_get_info_debug_log(shader))
        fmt.printf("GLSL source:\n")
        print_file_with_line_nums(string(glsl_source_processed))
        return false
    }

    if glslang.shader_parse(shader, &input) == 0
    {
        fmt.printf("%s: GLSL parsing failed. This is a bug, please report.\n", input_path)
        fmt.printf("%s\n", glslang.shader_get_info_log(shader))
        fmt.printf("%s\n", glslang.shader_get_info_debug_log(shader))
        fmt.printf("GLSL source:\n")
        print_file_with_line_nums(string(glsl_source_processed))
        return false
    }

    program := glslang.program_create()
    defer glslang.program_delete(program)
    glslang.program_add_shader(program, shader)

    if glslang.program_link(program, .SPV_RULES_BIT | .VULKAN_RULES_BIT) == 0
    {
        fmt.printf("%s: GLSL linking failed. This is a bug, please report.\n", input_path)
        fmt.printf("%s\n", glslang.program_get_info_log(program))
        fmt.printf("%s\n", glslang.program_get_info_debug_log(program))
        fmt.printf("GLSL source:\n")
        print_file_with_line_nums(string(glsl_source_processed))
        return false
    }

    glslang.program_SPIRV_generate(program, stage)

    spirv_binary := make([]u32, glslang.program_SPIRV_get_size(program))
    defer delete(spirv_binary)
    glslang.program_SPIRV_get(program, raw_data(spirv_binary))

    spirv_messages := glslang.program_SPIRV_get_messages(program)
    if spirv_messages != nil {
        fmt.printf("(%s) %s\b", input_path, spirv_messages)
    }

    err := os.write_entire_file_from_bytes(output_path, slice.to_bytes(spirv_binary))
    if err != nil {
        fmt.printfln("Could not write file %v: %v", output_path, err)
    }

    return true
}

// NOTE: Only used for debugging of compiler bugs, speed doesn't matter here.
print_file_with_line_nums :: proc(content: string)
{
    if content == "" do return

    line_count := 1
    for c in content {
        if c == '\n' do line_count += 1
    }

    cur_line := 1
    print_line_num(cur_line, line_count)
    for c in content
    {
        if c == '\n'
        {
            fmt.print("\n")
            cur_line += 1
            print_line_num(cur_line, line_count)
        }
        else
        {
            fmt.print(c)
        }
    }

    fmt.println("")

    print_line_num :: proc(line_num: int, total_line_count: int)
    {
        total_digit_count := math.count_digits_of_base(total_line_count, 10)
        line_num_digit_count := math.count_digits_of_base(line_num, 10)
        fmt.print(line_num)
        for _ in 0..<total_digit_count - line_num_digit_count + 4 {
            fmt.print(" ")
        }
    }
}
