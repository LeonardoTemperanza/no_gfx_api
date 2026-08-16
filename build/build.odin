
#+vet !unused-imports

package build

import "core:fmt"
import "core:os"
import "core:log"
import "core:mem"
import "core:strings"
import "core:thread"
import "core:sync"
import intr "base:intrinsics"
import fp "core:path/filepath"

Command :: struct
{
    name: string,
    code: proc() -> bool,
}

COMMANDS := []Command {
    { "default",   cmd_default   },  // Not specifying any command runs this.
    { "build_all_with_slang", cmd_build_all_with_slang },
    { "vercheck",  cmd_vercheck  },
    { "check_gpu", cmd_check_gpu },
    { "compiler",  cmd_compiler  },
    { "shaders_nosl", cmd_shaders_nosl },
    { "shaders_slang", cmd_shaders_slang },
    { "run_compiler_tests", cmd_run_compiler_tests },
    { "tests_gen_local_goldens", cmd_tests_gen_local_goldens },
    { "tests_compare_local_goldens", cmd_tests_compare_local_goldens },
    { "tests_compare_global_goldens", cmd_tests_compare_global_goldens }
}

Example :: struct
{
    shaders_nosl: [dynamic]string,
    shaders_slang: [dynamic]string,
    input_path: string,
    output_path: string,
}

EXAMPLES: [dynamic]Example

cmd_default :: proc() -> bool
{
    cmd_check_gpu() or_return
    cmd_check_tests() or_return
    res := true
    res &= cmd_compiler()
    res &= cmd_build_examples_parallel()
    return res
}

cmd_build_all_with_slang :: proc() -> bool
{
    cmd_check_gpu() or_return
    cmd_check_tests() or_return
    res := true
    res &= cmd_build_examples_parallel(build_shaders_nosl = false, build_shaders_slang = true)
    return res
}

cmd_build_example :: proc(example: Example) -> bool
{
    res := true
    res &= run_task("odin", "build", example.input_path, "-debug", with_exe_ext(fmt.tprintf("-out=build/%v", example.output_path)))
    return res
}

cmd_build_example_shaders_nosl :: proc(example: Example) -> bool
{
    res := true
    for shader in example.shaders_nosl
    {
        dir, _ := os.split_path(shader)
        out_flag := fmt.tprintf("-out:%v/%v.spv",  dir, os.stem(shader))
        res &= run_task(with_exe_ext("./build/gpu_compiler"), shader, out_flag)
    }
    return res
}

Shader_Stage :: enum { Vertex, Fragment, Compute }
Shader_Stages :: distinct bit_set[Shader_Stage]

cmd_build_example_shaders_slang :: proc(example: Example) -> bool
{
    res := true
    for shader in example.shaders_slang
    {
        dir, _ := os.split_path(shader)

        stages := get_slang_stages(shader)
        if .Vertex in stages
        {
            spv_path := fmt.tprintf("%v/%v.vert.spv", dir, os.stem(shader))
            res &= run_task("slangc",
                            "-target", "spirv",
                            "-fvk-use-c-layout", "-fvk-use-scalar-layout", "-force-glsl-scalar-layout",
                            "-validate-ir", "-no-mangle", "-entry", "vertexMain",
                            "-stage", "vertex", shader, "-o", spv_path)
        }
        if .Fragment in stages
        {
            spv_path := fmt.tprintf("%v/%v.frag.spv", dir, os.stem(shader))
            res &= run_task("slangc",
                            "-target", "spirv",
                            "-fvk-use-c-layout", "-fvk-use-scalar-layout", "-force-glsl-scalar-layout",
                            "-validate-ir", "-no-mangle", "-entry", "fragmentMain",
                            "-stage", "fragment", shader, "-o", spv_path)
        }
        if .Compute in stages
        {
            spv_path := fmt.tprintf("%v/%v.comp.spv", dir, os.stem(shader))
            res &= run_task("slangc",
                            "-target", "spirv",
                            "-fvk-use-c-layout", "-fvk-use-scalar-layout", "-force-glsl-scalar-layout",
                            "-validate-ir", "-no-mangle", "-entry", "computeMain",
                            "-stage", "compute", shader, "-o", spv_path)
        }
    }

    return res
}

cmd_vercheck :: proc() -> bool
{
    res := true
    res &= run_task("odin", "version")
    res &= run_task("glslangValidator", "--version")
    res &= run_task("slangc", "-v")
    res &= run_task("vulkaninfo", "--summary")
    return res
}

cmd_check_gpu :: proc() -> bool
{
    res := true
    res &= run_task("odin", "check", "gpu", "-no-entry-point", "-vet")
    return res
}

cmd_check_tests :: proc() -> bool
{
    res := true
    res &= run_task("odin", "check", "tests")
    return res
}

cmd_compiler :: proc() -> bool
{
    res := true
    res &= run_task("odin", "build", "gpu_compiler", "-debug", with_exe_ext("-out=build/gpu_compiler"))
    return res
}

cmd_shaders_nosl :: proc() -> bool
{
    cmd_compiler() or_return
    res := true
    res &= cmd_build_examples_parallel(build_odin = false)
    return res
}

cmd_shaders_slang :: proc() -> bool
{
    cmd_compiler() or_return
    res := true
    res &= cmd_build_examples_parallel(build_odin = false, build_shaders_nosl = false, build_shaders_slang = true)
    return res
}

cmd_run_compiler_tests :: proc() -> bool
{
    cmd_compiler() or_return
    res := true

    dir := "tests"
    shaders_nosl, shaders_slang := get_shaders_in_dir(dir)
    for shader in shaders_nosl
    {
        dir, _ := os.split_path(shader)
        out_flag := fmt.tprintf("-out:%v/%v.spv",  dir, os.stem(shader))
        compile_success := run_task(with_exe_ext("./build/gpu_compiler"), shader, out_flag, silent = true)
        if compile_success {
            fmt.printfln("%v - Ok.", shader)
        } else {
            fmt.printfln("%v - Fail!", shader)
        }
        res &= compile_success
    }

    return res
}

cmd_tests_gen_local_goldens :: proc() -> bool
{
    cmd_run_compiler_tests() or_return
    res := true
    res &= run_task("odin", "run", "tests", "--", "gen_local_goldens")
    return res
}

cmd_tests_compare_local_goldens :: proc() -> bool
{
    cmd_run_compiler_tests() or_return
    res := true
    res &= run_task("odin", "run", "tests", "--", "compare_to_local")
    return res
}

cmd_tests_compare_global_goldens :: proc() -> bool
{
    cmd_run_compiler_tests() or_return
    res := true
    res &= run_task("odin", "run", "tests", "--", "compare_to_global")
    return res
}

main :: proc()
{
    console_logger := log.create_console_logger()
    // defer log.destroy_console_logger(console_logger)
    context.logger = console_logger

    cmd_args := os.args
    if len(cmd_args) <= 0 do exit_with_error("No arguments found.")

    change_working_dir_to_project_root()

    default_arg := []string { "default" }
    args := cmd_args[1:]
    if len(args) == 0 {
        args = default_arg
    }

    // Retrieve example names
    add_examples("examples")
    add_examples("examples/third_party", output_prefix = "third_party_")

    res := true
    for arg in args
    {
        for cmd in COMMANDS
        {
            if cmd.name == arg {
                res &= cmd.code()
                break
            }

            mem.free_all(context.temp_allocator)
        }
    }

    os.exit(int(!res))
}

// Adds examples found in dir to the EXAMPLES global variable
add_examples :: proc(dir: string, output_prefix := "")
{
    examples_dir, err_o := os.open(dir)
    defer os.close(examples_dir)
    ensure(err_o == nil)
    it := os.read_directory_iterator_create(examples_dir)
    defer os.read_directory_iterator_destroy(&it)

    for info in os.read_directory_iterator(&it)
    {
        if info.type == .Directory && info.name != "shared" && info.name != "third_party"
        {
            // NOTE: Check if directory contains .odin files. If not, skip it.
            // This can happen because when/if an example is renamed or removed,
            // git will leave an empty directory for the old name.
            if !contains_odin_files(info.fullpath) do continue

            // Look for shaders
            shaders_nosl, shaders_slang := get_shaders_in_dir(info.fullpath)

            example := Example {
                input_path = strings.clone(fmt.tprintf("%v/%v", dir, strings.clone(info.name))),
                output_path = strings.concatenate({ output_prefix, strings.clone(info.name) }),
                shaders_nosl = shaders_nosl,
                shaders_slang = shaders_slang,
            }
            append(&EXAMPLES, example)
        }
    }

    if path, err := os.read_directory_iterator_error(&it); err != nil
    {
        log.errorf("Read directory failed at %v: %v", path, err)
        return
    }
}

contains_odin_files :: proc(path: string) -> bool
{
    dir, err_o := os.open(path)
    defer os.close(dir)
    ensure(err_o == nil)
    it := os.read_directory_iterator_create(dir)
    defer os.read_directory_iterator_destroy(&it)

    for info in os.read_directory_iterator(&it)
    {
        if info.type != .Directory && fp.ext(info.name) == ".odin" {
            return true
        }
    }

    if path, err := os.read_directory_iterator_error(&it); err != nil
    {
        log.errorf("Read directory failed at %v: %v", path, err)
        return false
    }

    return false
}

get_shaders_in_dir :: proc(path: string) -> (shaders_nosl: [dynamic]string, shaders_slang: [dynamic]string)
{
    cur_example_dir, cur_example_err_o := os.open(path)
    defer os.close(cur_example_dir)
    ensure(cur_example_err_o == nil)
    cur_example_it := os.read_directory_iterator_create(cur_example_dir)
    defer os.read_directory_iterator_destroy(&cur_example_it)

    for example_info in os.read_directory_iterator(&cur_example_it)
    {
        if example_info.type == .Directory && example_info.name == "shaders"
        {
            shaders_dir, shaders_err_o := os.open(example_info.fullpath)
            defer os.close(shaders_dir)
            ensure(shaders_err_o == nil)
            shaders_it := os.read_directory_iterator_create(shaders_dir)
            defer os.read_directory_iterator_destroy(&shaders_it)
            for shader_info in os.read_directory_iterator(&shaders_it)
            {
                ext := os.ext(shader_info.name)
                if ext == ".nosl"
                {
                    append(&shaders_nosl, strings.clone(shader_info.fullpath))
                }
                else if ext == ".slang"
                {
                    append(&shaders_slang, strings.clone(shader_info.fullpath))
                }
            }
        }
    }

    return shaders_nosl, shaders_slang
}

cmd_build_examples_parallel :: proc(build_odin := true, build_shaders_nosl := true, build_shaders_slang := false) -> bool
{
    PARALLEL :: true

    res := true

    Info :: struct {
        build_odin: bool,
        build_shaders_nosl: bool,
        build_shaders_slang: bool,
    }
    info := Info { build_odin, build_shaders_nosl, build_shaders_slang }

    Task :: struct {
        example: Example,
        success: ^bool,
    }

    tasks   := make([]Task,           len(EXAMPLES))
    threads := make([]^thread.Thread, len(EXAMPLES))
    defer delete(tasks)
    defer delete(threads)
    for example, i in EXAMPLES
    {
        tasks[i] = { example, &res }
        if PARALLEL {
            threads[i] = thread.create_and_start_with_poly_data2(&tasks[i], &info, worker)
        } else {
            worker(&tasks[i], &info)
        }
    }

    if PARALLEL {
        for t in threads { thread.join(t); thread.destroy(t) }
    }

    worker :: proc(task: ^Task, info: ^Info)
    {
        res := true
        if res && info.build_shaders_nosl {
            res &= cmd_build_example_shaders_nosl(task.example)
        }
        if res && info.build_shaders_slang {
            res &= cmd_build_example_shaders_slang(task.example)
        }
        if res && info.build_odin {
            res &= cmd_build_example(task.example)
        }
        if !res {
            intr.atomic_store(task.success, false)
        }
    }
    return res
}

exit_with_error :: proc(fmt: string, args: ..any)
{
    log.errorf(fmt, ..args)
    os.exit(1)
}

MUTEX: sync.Mutex

run_task :: proc(args: ..string, silent := false) -> bool
{
    if !silent do print_cmd(args)

    state, stdout, stderr, err := os.process_exec({ command = args }, allocator = context.temp_allocator)
    if err != nil {
        log.errorf("Failed to run command %v: %v.", args, err)
    }
    if sync.mutex_guard(&MUTEX)
    {
        fmt.print(string(stdout))
        fmt.eprint(string(stderr))
        os.flush(os.stdout)
        os.flush(os.stderr)
    }

    return state.exit_code == 0
}

print_cmd :: proc(args: []string)
{
    if sync.mutex_guard(&MUTEX)
    {
        for arg, i in args {
            fmt.printf("%v", arg)
            if i < len(args)-1 do fmt.print(" ")
        }
        fmt.println("")
    }
}

with_exe_ext :: proc(str: string) -> string
{
    when ODIN_OS == .Windows {
        return fmt.tprintf("%v.exe", str)
    } else {
        return str
    }
}

change_working_dir_to_project_root :: proc()
{
    process_info, err := os.current_process_info({.Executable_Path}, allocator = context.temp_allocator)
    ensure(err == nil, "Could not get current process info")

    exe_path := process_info.executable_path

    exe_path_abs, err_a := os.get_absolute_path(exe_path, allocator = context.temp_allocator)
    ensure(err_a == nil)

    // "odin run" creates an .exe at the current working directory, so support that case as well.
    exe_dir := fp.dir(exe_path_abs)
    if os.stem(exe_dir) == "build"
    {
        root_dir := fp.dir(exe_dir)
        os.chdir(root_dir)
    }
    else if os.stem(exe_dir) == "no_gfx_api"
    {
        os.chdir(exe_dir)
    }
    else
    {
        exit_with_error("Incorrect executable directory '%v', must be either 'no_gfx_api' or 'build'.", os.stem(exe_dir))
    }
}

get_slang_stages :: proc(path: string) -> Shader_Stages
{
    content, err := os.read_entire_file(path, allocator = context.allocator)
    defer delete(content)
    ensure(err == nil)

    content_str := string(content)
    res: Shader_Stages
    if strings.contains(content_str, "[shader(\"vertex\")]")   do res += { .Vertex }
    if strings.contains(content_str, "[shader(\"fragment\")]") do res += { .Fragment }
    if strings.contains(content_str, "[shader(\"compute\")]")  do res += { .Compute }
    return res
}
