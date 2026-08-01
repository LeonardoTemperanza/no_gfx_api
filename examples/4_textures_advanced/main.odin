
#+vet !unused-imports

package main

import log "core:log"
import "core:image"
import "core:image/png"
import "core:math"
import "core:math/linalg"
import "core:fmt"
import intr "base:intrinsics"

import "../../gpu"
import sdl "vendor:sdl3"

import shared "../shared"

Start_Window_Size_X :: 1000
Start_Window_Size_Y :: 1000
Frames_In_Flight :: 3
Example_Name :: "Textures (Advanced)"

main :: proc()
{
    shared.CAM_POS = {-1.3, -1.7, -1.3}
    shared.CAM_ANGLE = {math.PI * 0.25, math.PI * 0.25}
    fmt.println("Right-click + WASD for first-person controls.")

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

    display_scale: f32 = sdl.GetWindowDisplayScale(window)

    window_size_x := i32(Start_Window_Size_X * display_scale)
    window_size_y := i32(Start_Window_Size_Y * display_scale)

    ok := gpu.init()
    ensure(ok)
    defer gpu.cleanup()

    gpu.swapchain_create_from_sdl(window, Frames_In_Flight)

    depth_desc := gpu.Texture_Desc {
        dimensions = { u32(window_size_x), u32(window_size_y), 1 },
        format = .D32_Float,
        usage = { .Depth_Stencil_Attachment },
    }
    depth_texture := gpu.texture_alloc_and_create(depth_desc)
    defer gpu.texture_free_and_destroy(&depth_texture)

    sky_vert_shader := gpu.shader_create(#load("shaders/sky.vert.spv", []u32), .Vertex)
    sky_frag_shader := gpu.shader_create(#load("shaders/sky.frag.spv", []u32), .Fragment)
    defer {
        gpu.shader_destroy(sky_vert_shader)
        gpu.shader_destroy(sky_frag_shader)
    }

    cloud_vert_shader := gpu.shader_create(#load("shaders/cloud.vert.spv", []u32), .Vertex)
    cloud_frag_shader := gpu.shader_create(#load("shaders/cloud.frag.spv", []u32), .Fragment)
    defer {
        gpu.shader_destroy(cloud_vert_shader)
        gpu.shader_destroy(cloud_frag_shader)
    }

    desc_pool := gpu.desc_pool_create()
    defer gpu.desc_pool_destroy(&desc_pool)

    upload_arena := gpu.arena_create()
    defer gpu.arena_destroy(&upload_arena)

    upload_cmd_buf := gpu.commands_begin(.Main)

    sky_cubemap := build_sky_cubemap(&upload_arena, upload_cmd_buf)
    defer gpu.texture_free_and_destroy(&sky_cubemap)

    cloud_3d_texture := build_cloud_3d_texture(&upload_arena, upload_cmd_buf)
    defer gpu.texture_free_and_destroy(&cloud_3d_texture)

    sky_verts, sky_indices := build_sky_mesh(&upload_arena, upload_cmd_buf)
    defer {
        gpu.mem_free(sky_verts)
        gpu.mem_free(sky_indices)
    }

    cloud_verts, cloud_indices := build_cloud_mesh(&upload_arena, upload_cmd_buf)
    defer {
        gpu.mem_free(cloud_verts)
        gpu.mem_free(cloud_indices)
    }

    gpu.cmd_barrier(upload_cmd_buf, .Transfer, .All, {})
    gpu.queue_submit(.Main, { upload_cmd_buf })

    sky_cubemap_id := gpu.desc_pool_alloc_texture(&desc_pool, gpu.texture_view_descriptor(sky_cubemap, {}))
    cloud_3d_texture_id := gpu.desc_pool_alloc_texture(&desc_pool, gpu.texture_view_descriptor(cloud_3d_texture, {}))
    linear_sampler_id := gpu.desc_pool_alloc_sampler(&desc_pool, gpu.sampler_descriptor({}))

    now_ts := sdl.GetPerformanceCounter()

    frame_arenas: [Frames_In_Flight]gpu.Arena
    for &frame_arena in frame_arenas do frame_arena = gpu.arena_create()
    defer for &frame_arena in frame_arenas do gpu.arena_destroy(&frame_arena)
    next_frame := u64(1)
    frame_sem := gpu.semaphore_create(0)
    defer gpu.semaphore_destroy(frame_sem)
    for true
    {
        proceed := shared.handle_window_events(window)
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
        if old_window_size_x != window_size_x || old_window_size_y != window_size_y
        {
            gpu.queue_wait_idle(.Main)
            gpu.swapchain_resize({ u32(max(0, window_size_x)), u32(max(0, window_size_y)) })
            depth_desc.dimensions.x = u32(window_size_x)
            depth_desc.dimensions.y = u32(window_size_y)
            gpu.texture_free_and_destroy(&depth_texture)
            depth_texture = gpu.texture_alloc_and_create(depth_desc)
        }

        swapchain := gpu.swapchain_acquire_next()  // Blocks CPU until at least one frame is available.

        frame_arena := &frame_arenas[next_frame % Frames_In_Flight]
        gpu.arena_free_all(frame_arena)

        last_ts := now_ts
        now_ts = sdl.GetPerformanceCounter()
        delta_time := min(max_delta_time, f32(f64((now_ts - last_ts)*1000) / f64(ts_freq)) / 1000.0)

        world_to_view := shared.first_person_camera_view(delta_time)
        aspect_ratio := f32(window_size_x) / f32(window_size_y)
        view_to_proj := linalg.matrix4_perspective_f32(math.RAD_PER_DEG * 59.0, aspect_ratio, 0.1, 1000.0, false)

        cmd_buf := gpu.commands_begin(.Main)
        gpu.cmd_begin_render_pass(cmd_buf, {
            color_attachments = {
                { texture = swapchain, clear_color = { 0.7, 0.7, 0.7, 1.0 } }
            },
            depth_attachment = gpu.Render_Attachment {
                texture = depth_texture, clear_color = 1.0
            },
        })

        gpu.cmd_set_desc_heap(cmd_buf, desc_pool)

        // Draw skysphere
        {
            gpu.cmd_set_shaders(cmd_buf, sky_vert_shader, sky_frag_shader)
            gpu.cmd_set_depth_state(cmd_buf, { compare = .Always })
            // Render the skysphere inside out
            gpu.cmd_set_raster_state(cmd_buf, { cull_mode = .Cull_CCW })

            Vert_Data :: struct #all_or_none {
                positions: rawptr,
                world_to_view: [16]f32,
                view_to_proj: [16]f32,
            }
            verts_data := gpu.arena_alloc(frame_arena, Vert_Data)
            verts_data.cpu^ = {
                positions = sky_verts.gpu.ptr,
                world_to_view = intr.matrix_flatten(world_to_view),
                view_to_proj = intr.matrix_flatten(view_to_proj),
            }

            Frag_Data :: struct #all_or_none {
                sky_texture: u32,
                sky_sampler: u32,
            }
            frag_data := gpu.arena_alloc(frame_arena, Frag_Data)
            frag_data.cpu^ = {
                sky_texture = sky_cubemap_id,
                sky_sampler = linear_sampler_id,
            }

            gpu.cmd_draw_indexed(cmd_buf, verts_data, frag_data, sky_indices)
        }

        // Draw cloud
        {
            gpu.cmd_set_shaders(cmd_buf, cloud_vert_shader, cloud_frag_shader)
            gpu.cmd_set_depth_state(cmd_buf, { mode = { .Read, .Write }, compare = .Less })
            gpu.cmd_set_raster_state(cmd_buf, { cull_mode = .Cull_CW })
            gpu.cmd_set_blend_state(cmd_buf, {
                enable = true,
                color_op = .Add,
                src_color_factor = .Src_Alpha,
                dst_color_factor = .One_Minus_Src_Alpha,
                alpha_op = .Add,
                src_alpha_factor = .One,
                dst_alpha_factor = .One_Minus_Src_Alpha,
                color_write_mask = gpu.Color_Components_All,
            })

            Vert_Data :: struct #all_or_none {
                positions: rawptr,
                model_to_world: [16]f32,
                world_to_view: [16]f32,
                view_to_proj: [16]f32,
            }
            verts_data := gpu.arena_alloc(frame_arena, Vert_Data)
            verts_data.cpu^ = {
                positions = cloud_verts.gpu.ptr,
                model_to_world = intr.matrix_flatten(cast(matrix[4, 4]f32) 1),
                world_to_view = intr.matrix_flatten(world_to_view),
                view_to_proj = intr.matrix_flatten(view_to_proj),
            }

            Frag_Data :: struct #all_or_none {
                cloud_texture: u32,
                cloud_sampler: u32,
                camera_pos: [3]f32,
            }
            frag_data := gpu.arena_alloc(frame_arena, Frag_Data)
            frag_data.cpu^ = {
                cloud_texture = cloud_3d_texture_id,
                cloud_sampler = linear_sampler_id,
                camera_pos = shared.CAM_POS
            }
            gpu.cmd_draw_indexed(cmd_buf, verts_data, frag_data, cloud_indices)
        }

        gpu.cmd_end_render_pass(cmd_buf)
        gpu.cmd_add_signal_semaphore(cmd_buf, frame_sem, next_frame)
        gpu.queue_submit(.Main, { cmd_buf })

        gpu.swapchain_present(.Main, frame_sem, next_frame)
        next_frame += 1
    }

    gpu.wait_idle()
}

build_sky_mesh :: proc(upload_arena: ^gpu.Arena, cmd_buf: gpu.Command_Buffer) -> (gpu.slice_t([3]f32), gpu.slice_t(u32))
{
    verts, indices := shared.build_sphere()
    defer {
        delete(verts)
        delete(indices)
    }

    verts_staging := gpu.arena_alloc(upload_arena, [3]f32, len(verts))
    indices_staging := gpu.arena_alloc(upload_arena, u32, len(indices))
    copy(verts_staging.cpu, verts[:])
    copy(indices_staging.cpu, indices[:])

    verts_local := gpu.mem_alloc([3]f32, len(verts))
    indices_local := gpu.mem_alloc(u32, len(indices))
    gpu.cmd_mem_copy(cmd_buf, verts_local, verts_staging)
    gpu.cmd_mem_copy(cmd_buf, indices_local, indices_staging)
    return verts_local, indices_local
}

build_cloud_mesh :: proc(upload_arena: ^gpu.Arena, cmd_buf: gpu.Command_Buffer) -> (gpu.slice_t([3]f32), gpu.slice_t(u32))
{
    verts := shared.UNIT_CUBE_VERTS[:]
    indices := shared.CUBE_INDICES[:]
    verts_staging := gpu.arena_alloc(upload_arena, [3]f32, len(verts))
    indices_staging := gpu.arena_alloc(upload_arena, u32, len(indices))
    copy(verts_staging.cpu, verts[:])
    copy(indices_staging.cpu, indices[:])

    verts_local := gpu.mem_alloc([3]f32, len(verts))
    indices_local := gpu.mem_alloc(u32, len(indices))
    gpu.cmd_mem_copy(cmd_buf, verts_local, verts_staging)
    gpu.cmd_mem_copy(cmd_buf, indices_local, indices_staging)
    return verts_local, indices_local
}

Sky_Textures: [gpu.Cubemap_Side][]u8 = {
    .PX = #load("textures/px.png"),
    .NX = #load("textures/nx.png"),
    .PY = #load("textures/py.png"),
    .NY = #load("textures/ny.png"),
    .PZ = #load("textures/pz.png"),
    .NZ = #load("textures/nz.png"),
}
build_sky_cubemap :: proc(upload_arena: ^gpu.Arena, cmd_buf: gpu.Command_Buffer) -> gpu.Owned_Texture
{
    texture: gpu.Owned_Texture

    for side in gpu.Cubemap_Side
    {
        options := image.Options {
            .alpha_add_if_missing,
        }
        img, err := image.load_from_bytes(Sky_Textures[side], options)
        ensure(err == nil, "Could not load texture.")
        defer image.destroy(img)

        if texture == {}
        {
            texture = gpu.texture_alloc_and_create({
                type = .Cube,
                dimensions = { u32(img.width), u32(img.height), 1 },
                format = .RGBA8_Unorm,
                usage = { .Sampled },
                layer_count = 6,
            })
        }

        staging := gpu.arena_alloc(upload_arena, u8, len(img.pixels.buf))
        copy(staging.cpu, img.pixels.buf[:])
        gpu.cmd_copy_to_texture(cmd_buf, texture, staging, region = { base_layer = u32(side) })
    }
    return texture
}

// Generate cloud volume

generate_cloud_volume :: proc(size: int) -> []u8
{
    data := make([]u8, size*size*size)

    inv := 1.0 / f32(size - 1)

    for z in 0..<size
    {
        for y in 0..<size
        {
            for x in 0..<size
            {
                nx := f32(x) * inv
                ny := f32(y) * inv
                nz := f32(z) * inv

                // center volume
                dx := nx*2 - 1
                dy := ny*2 - 1
                dz := nz*2 - 1

                // Perlin
                n := fbm(nx*3, ny*3, nz*3)

                density := n
                density = density - 0.35
                density = density * 1.8
                density = clamp(density, 0.0, 1.0)

                idx := x + y*size + z*size*size
                data[idx] = u8(density * 255.0)
            }
        }
    }

    return data
}

smooth :: proc(t: f32) -> f32
{
    return 3*t*t - 2*t*t*t
}

hash3 :: proc(x, y, z: int) -> f32
{
    h := u32(x)*73856093 ~
         u32(y)*19349663 ~
         u32(z)*83492791

    h ~= h >> 13
    h *= 0x85ebca6b
    h ~= h >> 16

    return f32(h) / f32(0xffffffff)
}

value_noise :: proc(x, y, z: f32) -> f32
{
    xi := int(math.floor(x))
    yi := int(math.floor(y))
    zi := int(math.floor(z))

    xf := smooth(x - f32(xi))
    yf := smooth(y - f32(yi))
    zf := smooth(z - f32(zi))

    c000 := hash3(xi+0, yi+0, zi+0)
    c100 := hash3(xi+1, yi+0, zi+0)
    c010 := hash3(xi+0, yi+1, zi+0)
    c110 := hash3(xi+1, yi+1, zi+0)

    c001 := hash3(xi+0, yi+0, zi+1)
    c101 := hash3(xi+1, yi+0, zi+1)
    c011 := hash3(xi+0, yi+1, zi+1)
    c111 := hash3(xi+1, yi+1, zi+1)

    x00 := math.lerp(c000, c100, xf)
    x10 := math.lerp(c010, c110, xf)
    x01 := math.lerp(c001, c101, xf)
    x11 := math.lerp(c011, c111, xf)

    y0 := math.lerp(x00, x10, yf)
    y1 := math.lerp(x01, x11, yf)

    return math.lerp(y0, y1, zf)
}

fbm :: proc(x, y, z: f32) -> f32
{
    v := f32(0)
    amp := f32(0.5)
    freq := f32(1.0)
    damping :: 0.6
    freq_growth :: 2.3

    for _ in 0..<4
    {
        v += amp * value_noise(x*freq, y*freq, z*freq)
        amp *= damping
        freq *= freq_growth
    }

    return v
}

build_cloud_3d_texture :: proc(upload_arena: ^gpu.Arena, cmd_buf: gpu.Command_Buffer) -> gpu.Owned_Texture
{
    volume_res :: 128
    texture := gpu.texture_alloc_and_create({
        type = .D3,
        dimensions = { volume_res, volume_res, volume_res },
        format = .R8_Unorm,
        usage = { .Sampled },
    })

    log.info("Generating cloud...")
    cloud_volume := generate_cloud_volume(volume_res)
    log.info("Done!")

    staging := gpu.arena_alloc(upload_arena, u8, len(cloud_volume))
    copy(staging.cpu, cloud_volume)
    gpu.cmd_copy_to_texture(cmd_buf, texture, staging)
    return texture
}
