
#+vet !unused-imports

package main

import log "core:log"
import "core:image"
import "core:image/png"
import "base:runtime"
import "core:math"

import "../../gpu"

import shared "../shared"

import sdl "vendor:sdl3"

Start_Window_Size_X :: 1000
Start_Window_Size_Y :: 1000
Frames_In_Flight :: 3
Example_Name :: "Textures"

Peach_Texture :: #load("textures/peach.png")
Bowser_Texture :: #load("textures/bowser.png")

main :: proc()
{
    shared.sdl_init()

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

    window_size_x := i32(Start_Window_Size_X)
    window_size_y := i32(Start_Window_Size_Y)

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

    desc_pool := gpu.desc_pool_create()
    defer gpu.desc_pool_destroy(&desc_pool)

    Vertex :: struct { pos: [3]f32, uv: [2]f32 }

    arena := gpu.arena_create()
    defer gpu.arena_destroy(&arena)

    verts := gpu.arena_alloc(&arena, Vertex, 4)
    verts.cpu[0].pos = { -0.5,  0.5, 0.0 }
    verts.cpu[1].pos = {  0.5, -0.5, 0.0 }
    verts.cpu[2].pos = {  0.5,  0.5, 0.0 }
    verts.cpu[3].pos = { -0.5, -0.5, 0.0 }
    verts.cpu[0].uv  = {  0.0,  1.0 }
    verts.cpu[1].uv  = {  1.0,  0.0 }
    verts.cpu[2].uv  = {  1.0,  1.0 }
    verts.cpu[3].uv  = {  0.0,  0.0 }

    indices := gpu.arena_alloc(&arena, u32, 6)
    indices.cpu[0] = 0
    indices.cpu[1] = 2
    indices.cpu[2] = 1
    indices.cpu[3] = 0
    indices.cpu[4] = 1
    indices.cpu[5] = 3

    verts_local := gpu.mem_alloc(Vertex, 4, gpu.Memory.GPU)
    indices_local := gpu.mem_alloc(u32, 6, gpu.Memory.GPU)
    defer {
        gpu.mem_free(verts_local)
        gpu.mem_free(indices_local)
    }

    upload_cmd_buf := gpu.commands_begin(.Main)

    upload_arena := gpu.arena_create()
    defer gpu.arena_destroy(&upload_arena)

    peach_tex := load_texture(Peach_Texture, &upload_arena, upload_cmd_buf)
    bowser_tex := load_texture(Bowser_Texture, &upload_arena, upload_cmd_buf)
    defer {
        gpu.texture_free_and_destroy(&peach_tex)
        gpu.texture_free_and_destroy(&bowser_tex)
    }
    gpu.cmd_mem_copy(upload_cmd_buf, verts_local, verts)
    gpu.cmd_mem_copy(upload_cmd_buf, indices_local, indices)
    gpu.cmd_barrier(upload_cmd_buf, .Transfer, .All, {})

    gpu.queue_submit(.Main, { upload_cmd_buf })

    bowser_tex_id := gpu.desc_pool_alloc_texture(&desc_pool, gpu.texture_view_descriptor(bowser_tex, {}))
    peach_tex_id  := gpu.desc_pool_alloc_texture(&desc_pool, gpu.texture_view_descriptor(peach_tex, {}))
    linear_sampler := gpu.desc_pool_alloc_sampler(&desc_pool, gpu.sampler_descriptor({}))

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
        sdl.GetWindowSize(window, &window_size_x, &window_size_y)
        if .MINIMIZED in sdl.GetWindowFlags(window) || window_size_x <= 0 || window_size_y <= 0
        {
            sdl.Delay(16)
            continue
        }

        if next_frame > Frames_In_Flight {
            gpu.semaphore_wait(frame_sem, next_frame - Frames_In_Flight)
        }
        if old_window_size_x != window_size_x || old_window_size_y != window_size_y {
            gpu.swapchain_resize({ u32(window_size_x), u32(window_size_y) })
        }
        swapchain := gpu.swapchain_acquire_next()  // Blocks CPU until at least one frame is available.
        if swapchain == {} {
            gpu.swapchain_resize({ u32(window_size_x), u32(window_size_y) })
            continue
        }

        last_ts := now_ts
        now_ts = sdl.GetPerformanceCounter()
        delta_time := min(max_delta_time, f32(f64((now_ts - last_ts)*1000) / f64(ts_freq)) / 1000.0)

        frame_arena := &frame_arenas[next_frame % Frames_In_Flight]
        gpu.arena_free_all(frame_arena)

        cmd_buf := gpu.commands_begin(.Main)
        gpu.cmd_begin_render_pass(cmd_buf, {
            color_attachments = {
                { texture = swapchain, clear_color = { 0.7, 0.7, 0.7, 1.0 } }
            }
        })
        gpu.cmd_set_shaders(cmd_buf, vert_shader, frag_shader)
        gpu.cmd_set_desc_heap(cmd_buf, desc_pool)
        Vert_Data :: struct {
            verts: rawptr,
        }
        verts_data := gpu.arena_alloc(frame_arena, Vert_Data)
        verts_data.cpu.verts = verts_local.gpu.ptr
        Frag_Data :: struct {
            texture_a: u32,
            texture_b: u32,
            sampler: u32,
            fade: f32
        }
        frag_data := gpu.arena_alloc(frame_arena, Frag_Data)
        frag_data.cpu.texture_a = bowser_tex_id
        frag_data.cpu.texture_b = peach_tex_id
        frag_data.cpu.sampler = linear_sampler
        frag_data.cpu.fade = changing_fade(delta_time)

        gpu.cmd_draw_indexed(cmd_buf, verts_data, frag_data, indices_local)
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

load_texture :: proc(bytes: []byte, upload_arena: ^gpu.Arena, cmd_buf: gpu.Command_Buffer) -> gpu.Owned_Texture
{
    options := image.Options {
        .alpha_add_if_missing,
    }
    img, err := image.load_from_bytes(bytes, options)
    ensure(err == nil, "Could not load texture.")
    defer image.destroy(img)

    staging := gpu.arena_alloc_raw(upload_arena, u64(len(img.pixels.buf)), 1)
    runtime.mem_copy(staging.cpu, raw_data(img.pixels.buf), len(img.pixels.buf))

    texture := gpu.texture_alloc_and_create({
        dimensions = { u32(img.width), u32(img.height), 1 },
        format = .RGBA8_Unorm,
        usage = { .Sampled },
    })
    gpu.cmd_copy_to_texture(cmd_buf, texture, staging)
    return texture
}

changing_fade :: proc(delta_time: f32) -> f32
{
    @(static) t: f32
    t = math.mod(t + delta_time * 1.7, math.PI * 2)
    return math.sin(t) * 0.5 + 0.5
}
