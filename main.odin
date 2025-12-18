
package main

import log "core:log"
import "core:c"
// import "core:fmt"

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

    window_flags :: sdl.WindowFlags {
        .HIGH_PIXEL_DENSITY,
        .VULKAN,
        .FULLSCREEN,
    }
    window := sdl.CreateWindow("Lightmapper RT Example", 1920, 1080, window_flags)
    win_width, win_height: c.int
    assert(sdl.GetWindowSize(window, &win_width, &win_height))
    WINDOW_SIZE_X = auto_cast max(0, win_width)
    WINDOW_SIZE_Y = auto_cast max(0, win_height)
    ensure(window != nil)

    gpu.init(window)
    defer gpu.cleanup()

    swapchain := gpu.swapchain_acquire_next()

    vert_shader := gpu.shader_create(#load("shaders/test.vert.spv", []u32), .Vertex)
    frag_shader := gpu.shader_create(#load("shaders/test.frag.spv", []u32), .Fragment)

    Vertex :: struct { pos: [3]f32 }

    arena := gpu.arena_init(1024 * 1024)
    defer gpu.arena_destroy(&arena)

    verts := gpu.arena_alloc_array(&arena, Vertex, 3)
    verts.cpu[0].pos = { -0.5, -0.5, 0.0 }
    verts.cpu[1].pos = {  0.0,  0.5, 0.0 }
    verts.cpu[2].pos = {  0.5, -0.5, 0.0 }

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
    gpu.queue_submit(queue, { upload_cmd_buf })

    cmd_buf := gpu.commands_begin(queue)
    gpu.cmd_begin_render_pass(cmd_buf, {
        color_attachments = {
            { view = swapchain }
        }
    })
    gpu.cmd_set_shaders(cmd_buf, vert_shader, frag_shader)
    gpu.cmd_set_depth_state(cmd_buf, {})
    gpu.cmd_set_blend_state(cmd_buf, {})
    gpu.cmd_draw_indexed_instanced(cmd_buf, verts_local, nil, indices_local, 3, 1)
    gpu.cmd_end_render_pass(cmd_buf)
    gpu.queue_submit(queue, { cmd_buf })

    gpu.swapchain_acquire_next()
}
