
package main

import log "core:log"
import "core:math"
import "core:math/linalg"

import "../../gpu"

import shared "../shared"

import sdl "vendor:sdl3"

Start_Window_Size_X :: 1000
Start_Window_Size_Y :: 1000
Frames_In_Flight :: 3
Example_Name :: "Indirect Triangles"
Num_Triangles :: 32

Use_Indirect_Multi :: true

main :: proc()
{
    shared.sdl_init(moltenvk_working_status = .Partially_Works)

    console_logger := log.create_console_logger()
    defer log.destroy_console_logger(console_logger)
    context.logger = console_logger

    ts_freq := sdl.GetPerformanceFrequency()
    max_delta_time: f32 = 1.0 / 10.0  // 10fps

    window_flags :: sdl.WindowFlags {
        .HIGH_PIXEL_DENSITY,
        .VULKAN,
        .RESIZABLE,
    }
    window := sdl.CreateWindow(Example_Name, Start_Window_Size_X, Start_Window_Size_Y, window_flags)
    ensure(window != nil)

    display_scale: f32 = sdl.GetWindowDisplayScale(window)

    window_size_x := i32(Start_Window_Size_X * display_scale)
    window_size_y := i32(Start_Window_Size_Y * display_scale)

    ok := gpu.init()
    ensure(ok)
    defer gpu.cleanup()

    gpu.swapchain_create_from_sdl(window, Frames_In_Flight)

    vert_shader := gpu.shader_create(#load("shaders/shader.vert.spv", []u32), .Vertex)
    frag_shader := gpu.shader_create(#load("shaders/shader.frag.spv", []u32), .Fragment)
    defer {
        gpu.shader_destroy(vert_shader)
        gpu.shader_destroy(frag_shader)
    }

    Vertex :: struct { pos: [3]f32 }

    arena := gpu.arena_create()
    defer gpu.arena_destroy(&arena)

    verts := gpu.arena_alloc(&arena, Vertex, 3)
    verts.cpu[0].pos = { -0.5,  0.5, 0.0 }
    verts.cpu[1].pos = {  0.0, -0.5, 0.0 }
    verts.cpu[2].pos = {  0.5,  0.5, 0.0 }

    indices := gpu.arena_alloc(&arena, u32, 3)
    indices.cpu[0] = 0
    indices.cpu[1] = 2
    indices.cpu[2] = 1

    verts_local := gpu.mem_alloc(Vertex, 3, gpu.Memory.GPU)
    indices_local := gpu.mem_alloc(u32, 3, gpu.Memory.GPU)

    // Unified indirect data struct that extends Draw_Indexed_Indirect_Command
    Indirect_Data :: struct {
        using cmd: gpu.Draw_Indexed_Indirect_Command,
        color: [3]f32,
        pos: [3]f32,
        size: f32,
    }

    indirect_data := gpu.mem_alloc(Indirect_Data, Num_Triangles)
    defer gpu.mem_free(indirect_data)

    count := gpu.arena_alloc(&arena, u32)
    count.cpu^ = Num_Triangles

    count_local := gpu.mem_alloc(u32, mem_type = gpu.Memory.GPU)

    // Arrange triangles in a circle
    circle_radius: f32 = 0.6
    for i in 0..<Num_Triangles {
        angle := f32(i) / f32(Num_Triangles) * math.PI * 2.0

        // Position on circle
        x := math.cos(angle) * circle_radius
        y := math.sin(angle) * circle_radius

        // HSL color: hue varies around the circle (0-360 degrees), saturation and lightness fixed
        hue := angle / (math.PI * 2.0)  // 0.0 to 1.0
        saturation: f32 = 1.0
        lightness: f32 = 0.5

        // Convert HSL to RGB
        rgb := hsl_to_rgb(hue, saturation, lightness)

        // Fill unified indirect data struct with both command and user data
        indirect_data.cpu[i] = Indirect_Data {
            cmd = gpu.Draw_Indexed_Indirect_Command {
                index_count = 3,
                instance_count = 1,
                first_index = 0,
                vertex_offset = 0,
                first_instance = 0,
            },
            color = { rgb.x, rgb.y, rgb.z },
            pos = { x, y, 0.0 },
            size = 0.1,
        }
    }

    indirect_data_local := gpu.mem_alloc(Indirect_Data, Num_Triangles, gpu.Memory.GPU)

    defer {
        gpu.mem_free(verts_local)
        gpu.mem_free(indices_local)
        gpu.mem_free(count_local)
        gpu.mem_free(indirect_data_local)
    }

    upload_cmd_buf := gpu.commands_begin(.Main)
    gpu.cmd_mem_copy(upload_cmd_buf, verts_local, verts)
    gpu.cmd_mem_copy(upload_cmd_buf, indices_local, indices)
    gpu.cmd_mem_copy(upload_cmd_buf, count_local, count)
    gpu.cmd_mem_copy(upload_cmd_buf, indirect_data_local, indirect_data)
    gpu.cmd_barrier(upload_cmd_buf, .Transfer, .All, {})
    gpu.queue_submit(.Main, { upload_cmd_buf })

    now_ts := sdl.GetPerformanceCounter()

    frame_arenas: [Frames_In_Flight]gpu.Arena
    for &frame_arena in frame_arenas do frame_arena = gpu.arena_create()
    defer for &frame_arena in frame_arenas do gpu.arena_destroy(&frame_arena)
    next_frame := u64(1)
    frame_sem := gpu.semaphore_create(0)
    defer gpu.semaphore_destroy(frame_sem)
    for true
    {
        proceed := handle_window_events(window)
        if !proceed do break

        old_window_size_x := window_size_x
        old_window_size_y := window_size_y
        sdl.GetWindowSizeInPixels(window, &window_size_x, &window_size_y)
        if .MINIMIZED in sdl.GetWindowFlags(window) || window_size_x <= 0 || window_size_y <= 0
        {
            sdl.Delay(16)
            continue
        }

        if next_frame > Frames_In_Flight {
            gpu.semaphore_wait(frame_sem, next_frame - Frames_In_Flight)
        }
        if old_window_size_x != window_size_x || old_window_size_y != window_size_y {
            gpu.swapchain_resize({ u32(max(0, window_size_x)), u32(max(0, window_size_y)) })
        }
        swapchain := gpu.swapchain_acquire_next()  // Blocks CPU until at least one frame is available.

        last_ts := now_ts
        now_ts = sdl.GetPerformanceCounter()
        delta_time := min(max_delta_time, f32(f64((now_ts - last_ts)*1000) / f64(ts_freq)) / 1000.0)

        frame_arena := &frame_arenas[next_frame % Frames_In_Flight]
        gpu.arena_free_all(frame_arena)

        cmd_buf := gpu.commands_begin(.Main)
        gpu.cmd_begin_render_pass(cmd_buf, {
            color_attachments = {
                { texture = swapchain, clear_color = changing_color(delta_time) }
            }
        })
        gpu.cmd_set_shaders(cmd_buf, vert_shader, frag_shader)
        Vert_Data :: struct {
            verts: rawptr,
        }
        shared_vert_data := gpu.arena_alloc(frame_arena, Vert_Data)
        shared_vert_data.cpu.verts = verts_local.gpu.ptr

        when Use_Indirect_Multi {
            // Draw multiple indexed triangles using indirect rendering
            // Arguments:
            //   cmd_buf: Command buffer to record the draw command
            //   shared_vert_data.gpu: GPU pointer to shared vertex data (used by all draws - the triangle vertices)
            //   nil: GPU pointer to shared fragment shader data (not used in this example)
            //   indices_local: GPU pointer to index buffer (u32 array)
            //   indirect_data_local: GPU pointer to array of IndirectData (contains both draw command and per-draw data)
            //   stride: Byte stride between elements in the indirect data array (size of IndirectData struct)
            //   count_local: GPU pointer to u32 containing the number of draws to execute
            gpu.cmd_draw_indexed_indirect_multi(cmd_buf, shared_vert_data, {}, indices_local, indirect_data_local, count_local)
        } else {
            // Renders only the first draw from the indirect data buffer
            gpu.cmd_draw_indexed_indirect(cmd_buf, shared_vert_data, {}, indices_local, gpu.slice_to_ptr(indirect_data_local))
        }

        gpu.cmd_end_render_pass(cmd_buf)
        gpu.cmd_add_signal_semaphore(cmd_buf, frame_sem, next_frame)
        gpu.queue_submit(.Main, { cmd_buf })

        gpu.swapchain_present(.Main, frame_sem, next_frame)
        next_frame += 1
    }

    gpu.wait_idle()
}

handle_window_events :: proc(window: ^sdl.Window) -> (proceed: bool)
{
    event: sdl.Event
    proceed = true
    for sdl.PollEvent(&event)
    {
        #partial switch event.type
        {
            case .QUIT:
                proceed = false
            case .WINDOW_CLOSE_REQUESTED:
            {
                if event.window.windowID == sdl.GetWindowID(window) {
                    proceed = false
                }
            }
        }
    }

    return
}

changing_color :: proc(delta_time: f32) -> [4]f32
{
    @(static) t: f32
    t = math.mod(t + delta_time * 1.7, math.PI * 2)

    color_a := [4]f32 { 0.2, 0.2, 0.2, 1.0 }
    color_b := [4]f32 { 0.4, 0.4, 0.4, 1.0 }
    return linalg.lerp(color_a, color_b, math.sin(t) * 0.5 + 0.5)
}

// Convert HSL to RGB (hue: 0-1, saturation: 0-1, lightness: 0-1)
hsl_to_rgb :: proc(h: f32, s: f32, l: f32) -> linalg.Vector3f32
{
    c := (1.0 - abs(2.0 * l - 1.0)) * s
    x := c * (1.0 - abs(math.mod(h * 6.0, 2.0) - 1.0))
    m := l - c / 2.0

    r, g, b: f32

    if h < 1.0/6.0 {
        r, g, b = c, x, 0.0
    } else if h < 2.0/6.0 {
        r, g, b = x, c, 0.0
    } else if h < 3.0/6.0 {
        r, g, b = 0.0, c, x
    } else if h < 4.0/6.0 {
        r, g, b = 0.0, x, c
    } else if h < 5.0/6.0 {
        r, g, b = x, 0.0, c
    } else {
        r, g, b = c, 0.0, x
    }

    return { r + m, g + m, b + m }
}
