
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

    //ts_freq := sdl.GetPerformanceFrequency()

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

    verts_local := gpu.mem_alloc_typed(u8, 1024)
    gpu.mem_free_typed(verts_local)

    /*
    for _ in 1..=1024
    {
        verts_local := gpu.mem_alloc_typed(u8, 1024)
        fmt.println(verts_local[0])
        gpu.mem_free_typed(verts_local)
    }
    for _ in 1..=1024
    {
        verts_local := gpu.mem_alloc(1024, mem_type = .GPU)
        //fmt.println((cast(^u32) verts_local)^)
        gpu.mem_free(verts_local)
    }
    for _ in 1..=1024
    {
        verts_local := gpu.mem_alloc(1024, mem_type = .Readback)
        fmt.println((cast(^u32) verts_local)^)
        gpu.mem_free(verts_local)
    }
    */

    // gpu.cmd
}
