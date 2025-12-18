
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

    Vertex :: struct { pos: [3]f32 }

    arena := gpu.arena_init(1024 * 1024)
    defer gpu.arena_destroy(&arena)

    verts := gpu.arena_alloc(&arena, Vertex, 3)
    verts.cpu[0].pos = { -0.5, -0.5, 0.0 }
    verts.cpu[1].pos = {  0.0,  0.5, 0.0 }
    verts.cpu[2].pos = {  0.5, -0.5, 0.0 }

    verts_local := gpu.mem_alloc_typed_gpu(Vertex, 3)

    queue := gpu.get_queue()

    upload_cmd_buf := gpu.commands_begin(queue)
    gpu.cmd_mem_copy(upload_cmd_buf, verts.gpu, verts_local, 3 * size_of(Vertex))
    gpu.queue_submit(queue, { upload_cmd_buf })
}
