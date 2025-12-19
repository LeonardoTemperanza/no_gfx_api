
package main

import log "core:log"
import "core:c"
import "core:math"
import "core:math/linalg"

import "gpu"

import sdl "vendor:sdl3"

WINDOW_SIZE_X: u32
WINDOW_SIZE_Y: u32

main :: proc()
{
    ok_i := sdl.Init({ .VIDEO })
    assert(ok_i)

    console_logger := log.create_console_logger()
    defer log.destroy_console_logger(console_logger)
    context.logger = console_logger

    ts_freq := sdl.GetPerformanceFrequency()
    max_delta_time: f32 = 1.0 / 10.0  // 10fps

    window_flags :: sdl.WindowFlags {
        .HIGH_PIXEL_DENSITY,
        .VULKAN,
    }
    window := sdl.CreateWindow("Lightmapper RT Example", 1900, 1900, window_flags)
    win_width, win_height: c.int
    assert(sdl.GetWindowSize(window, &win_width, &win_height))
    WINDOW_SIZE_X = auto_cast max(0, win_width)
    WINDOW_SIZE_Y = auto_cast max(0, win_height)
    ensure(window != nil)

    gpu.init(window)
    defer gpu.cleanup()

    vert_shader := gpu.shader_create(#load("shaders/test.vert.spv", []u32), .Vertex)
    frag_shader := gpu.shader_create(#load("shaders/test.frag.spv", []u32), .Fragment)

    Vertex :: struct { pos: [4]f32, color: [4]f32 }

    arena := gpu.arena_init(1024 * 1024)
    defer gpu.arena_destroy(&arena)

    verts := gpu.arena_alloc_array(&arena, Vertex, 3)
    verts.cpu[0].pos = { -0.5,  0.5, 0.0, 0.0 }
    verts.cpu[1].pos = {  0.0, -0.5, 0.0, 0.0 }
    verts.cpu[2].pos = {  0.5,  0.5, 0.0, 0.0 }
    verts.cpu[0].color = { 1.0, 0.0, 0.0, 0.0 }
    verts.cpu[1].color = { 0.0, 1.0, 0.0, 0.0 }
    verts.cpu[2].color = { 0.0, 0.0, 1.0, 0.0 }

    indices := gpu.arena_alloc_array(&arena, u32, 3)
    indices.cpu[0] = 0
    indices.cpu[1] = 1
    indices.cpu[2] = 2

    verts_local := gpu.mem_alloc_typed_gpu(Vertex, 3)
    indices_local := gpu.mem_alloc_typed_gpu(u32, 3)

    queue := gpu.get_queue()

    upload_cmd_buf := gpu.commands_begin(queue)
    gpu.cmd_mem_copy(upload_cmd_buf, verts.gpu, verts_local, 3 * size_of(Vertex))
    gpu.cmd_mem_copy(upload_cmd_buf, indices.gpu, indices_local, 3 * size_of(u32))
    gpu.cmd_barrier(upload_cmd_buf, .Transfer, .All, {})
    gpu.queue_submit(queue, { upload_cmd_buf })

    sdl.Delay(30)

    frame_arena := gpu.arena_init(1024 * 1024)
    defer gpu.arena_destroy(&frame_arena)
    now_ts := sdl.GetPerformanceCounter()
    for true
    {
        proceed := handle_window_events(window)
        if !proceed do break

        last_ts := now_ts
        now_ts = sdl.GetPerformanceCounter()
        delta_time := min(max_delta_time, f32(f64((now_ts - last_ts)*1000) / f64(ts_freq)) / 1000.0)

        swapchain := gpu.swapchain_acquire_next()

        cmd_buf := gpu.commands_begin(queue)
        gpu.cmd_begin_render_pass(cmd_buf, {
            color_attachments = {
                { view = swapchain, clear_color = changing_color(delta_time) }
            }
        })
        gpu.cmd_set_shaders(cmd_buf, vert_shader, frag_shader)
        gpu.cmd_set_depth_state(cmd_buf, {})
        gpu.cmd_set_blend_state(cmd_buf, {})
        Vert_Data :: struct {
            verts: rawptr,
        }
        verts_data := gpu.arena_alloc(&frame_arena, Vert_Data)
        verts_data.cpu.verts = verts_local

        gpu.cmd_draw_indexed_instanced(cmd_buf, verts_data.gpu, nil, indices_local, 3, 1)
        gpu.cmd_end_render_pass(cmd_buf)
        gpu.queue_submit(queue, { cmd_buf })

        gpu.swapchain_present()

        gpu.arena_free_all(&frame_arena)
    }
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
