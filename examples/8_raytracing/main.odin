
package main

import log "core:log"
import "core:math"
import "core:math/linalg"
import "base:runtime"
import intr "base:intrinsics"
import "core:fmt"

import "../../gpu"

import sdl "vendor:sdl3"

import shared "../shared"
import gltf2 "../shared/gltf2"

Start_Window_Size_X :: 1000
Start_Window_Size_Y :: 1000
Frames_In_Flight :: 3
Example_Name :: "Raytracing"

Sponza_Scene :: #load("../shared/assets/sponza.glb")

main :: proc()
{
    shared.CAM_POS = {-7.581631, 1.1906259, 0.25928685}
	shared.CAM_ANGLE = {1.570796, 0.3665192}

    fmt.println("Right-click + WASD for first-person controls.")

    shared.sdl_init(
        moltenvk_working_status = .Does_Not_Work,
        kosmickrisp_working_status = .Does_Not_Work
    )

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

    if !(.Raytracing in gpu.features_available()) {
        log.error("Raytracing is not supported, but it is mandatory for this example.")
        return
    }

    gpu.swapchain_create_from_sdl(window, Frames_In_Flight)

    group_size_x := u32(8)
    group_size_y := u32(8)
    vert_shader := gpu.shader_create(#load("shaders/shader.vert.spv", []u32), .Vertex)
    frag_shader := gpu.shader_create(#load("shaders/shader.frag.spv", []u32), .Fragment)
    pathtrace_shader := gpu.shader_create_compute(#load("shaders/pathtracer.comp.spv", []u32), group_size_x, group_size_y, 1)
    defer {
        gpu.shader_destroy(vert_shader)
        gpu.shader_destroy(frag_shader)
        gpu.shader_destroy(pathtrace_shader)
    }

    upload_arena := gpu.arena_create()
    defer gpu.arena_destroy(&upload_arena)
    bvh_scratch_arena := gpu.arena_create(mem_type = .GPU)
    defer gpu.arena_destroy(&bvh_scratch_arena)

    gltf_scene, _, gltf_data := shared.load_scene_gltf(Sponza_Scene, 0)
    defer {
        shared.destroy_scene(&gltf_scene)
        gltf2.unload(gltf_data)
    }

    desc_pool := gpu.desc_pool_create()
    defer gpu.desc_pool_destroy(&desc_pool)

    // Create a texture for the compute shader to write to
    output_desc := gpu.Texture_Desc {
        type = .D2,
        dimensions = { u32(window_size_x), u32(window_size_y), 1 },
        format = .RGBA16_Float,
        usage = { .Storage, .Sampled },
    }
    output_texture := gpu.texture_alloc_and_create(output_desc)
    defer gpu.texture_free_and_destroy(&output_texture)

    Compute_Data :: struct {
        output_texture_id: u32,
        tlas_id: u32,
        scene: Scene_Shader,
        accum_counter: u32,
        camera_to_world: [16]f32,
    }

    Vertex :: struct { pos: [3]f32, uv: [2]f32 }

    arena := gpu.arena_create()
    defer gpu.arena_destroy(&arena)

    // Create fullscreen quad
    verts := gpu.arena_alloc(&arena, Vertex, 4)
    verts.cpu[0].pos = { -1.0,  1.0, 0.0 }  // Top-left
    verts.cpu[1].pos = {  1.0, -1.0, 0.0 }  // Bottom-right
    verts.cpu[2].pos = {  1.0,  1.0, 0.0 }  // Top-right
    verts.cpu[3].pos = { -1.0, -1.0, 0.0 }  // Bottom-left
    verts.cpu[0].uv  = {  0.0,  0.0 }
    verts.cpu[1].uv  = {  1.0,  1.0 }
    verts.cpu[2].uv  = {  1.0,  0.0 }
    verts.cpu[3].uv  = {  0.0,  1.0 }

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
    gpu.cmd_mem_copy(upload_cmd_buf, verts_local, verts)
    gpu.cmd_mem_copy(upload_cmd_buf, indices_local, indices)

    scene := upload_scene(gltf_scene, &upload_arena, &bvh_scratch_arena, upload_cmd_buf)
    defer {
        scene_destroy(&scene)
    }

    gpu.cmd_barrier(upload_cmd_buf, .Transfer, .All, {})
    gpu.queue_submit(.Main, { upload_cmd_buf })

    texture_id := gpu.desc_pool_alloc_texture(&desc_pool, gpu.texture_view_descriptor(output_texture, {}))
    texture_rw_id := gpu.desc_pool_alloc_texture_rw(&desc_pool, gpu.texture_rw_view_descriptor(output_texture, {}))
    sampler_id := gpu.desc_pool_alloc_sampler(&desc_pool, gpu.sampler_descriptor({}))
    bvh_id := gpu.desc_pool_alloc_bvh(&desc_pool, scene.bvh)

    now_ts := sdl.GetPerformanceCounter()
    total_time: f32 = 0.0

    camera_to_world: matrix[4, 4]f32 = 1

    accum_counter := u32(0)
    max_accums := u32(1000)

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
        sdl.GetWindowSize(window, &window_size_x, &window_size_y)
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
            gpu.swapchain_resize({ u32(window_size_x), u32(window_size_y) })

            output_desc.dimensions.x = u32(window_size_x)
            output_desc.dimensions.y = u32(window_size_y)
            gpu.texture_free_and_destroy(&output_texture)
            output_texture = gpu.texture_alloc_and_create(output_desc)

            // Update descriptor for new texture
            gpu.desc_heap_set_textures(&desc_pool, texture_id, { gpu.texture_view_descriptor(output_texture, {}) })
            gpu.desc_heap_set_textures_rw(&desc_pool, texture_rw_id, { gpu.texture_rw_view_descriptor(output_texture, {}) })

            accum_counter = 0
        }

        if shared.INPUT.pressing_right_click do accum_counter = 0

        last_ts := now_ts
        now_ts = sdl.GetPerformanceCounter()
        delta_time := min(max_delta_time, f32(f64((now_ts - last_ts)*1000) / f64(ts_freq)) / 1000.0)
        total_time += delta_time

        frame_arena := &frame_arenas[next_frame % Frames_In_Flight]
        gpu.arena_free_all(frame_arena)

        old_camera_to_world := camera_to_world
        camera_to_world := linalg.inverse(shared.first_person_camera_view(delta_time))

        swapchain := gpu.swapchain_acquire_next()  // Blocks CPU until at least one frame is available.

        // Allocate compute data for this frame with current time and resolution
        compute_data := gpu.arena_alloc(frame_arena, Compute_Data)
        compute_data.cpu.output_texture_id = texture_rw_id
        compute_data.cpu.tlas_id = bvh_id
        compute_data.cpu.scene = { instances = scene.instances.gpu.ptr, meshes = scene.meshes_shader.gpu.ptr }
        compute_data.cpu.accum_counter = accum_counter
        compute_data.cpu.camera_to_world = intr.matrix_flatten(camera_to_world)

        cmd_buf := gpu.commands_begin(.Main)
        gpu.cmd_set_desc_heap(cmd_buf, desc_pool)

        if accum_counter < max_accums
        {
            // Dispatch compute shader to write to texture
            gpu.cmd_set_compute_shader(cmd_buf, pathtrace_shader)

            num_groups_x := (u32(window_size_x) + group_size_x - 1) / group_size_x
            num_groups_y := (u32(window_size_y) + group_size_y - 1) / group_size_y
            num_groups_z := u32(1)

            // Reads and writes into texture_rw_id (allowed if each thread only reads a texel and then writes to that same texel)
            gpu.cmd_dispatch(cmd_buf, compute_data, num_groups_x, num_groups_y, num_groups_z)

            // Barrier to ensure compute shader finishes before rendering
            gpu.cmd_barrier(cmd_buf, .Compute, .Fragment_Shader, {})
            // Next frame's pathtrace invocation will read this frame's output texture
            gpu.cmd_barrier(cmd_buf, .Compute, .Compute, {})
        }

        // Render the texture to the swapchain using a fullscreen quad
        gpu.cmd_begin_render_pass(cmd_buf, {
            color_attachments = {
                { texture = swapchain, clear_color = { 0.0, 0.0, 0.0, 1.0 } }
            }
        })
        gpu.cmd_set_shaders(cmd_buf, vert_shader, frag_shader)

        Vert_Data :: struct {
            verts: rawptr,
        }
        verts_data := gpu.arena_alloc(frame_arena, Vert_Data)
        verts_data.cpu.verts = verts_local.gpu.ptr

        Frag_Data :: struct {
            texture_id: u32,
            sampler_id: u32,
        }
        frag_data := gpu.arena_alloc(frame_arena, Frag_Data)
        frag_data.cpu.texture_id = texture_id
        frag_data.cpu.sampler_id = sampler_id

        gpu.cmd_draw_indexed(cmd_buf, verts_data, frag_data, indices_local)
        gpu.cmd_end_render_pass(cmd_buf)
        gpu.cmd_add_signal_semaphore(cmd_buf, frame_sem, next_frame)
        gpu.queue_submit(.Main, { cmd_buf })

        gpu.swapchain_present(.Main, frame_sem, next_frame)
        next_frame += 1
        accum_counter = min(accum_counter + 1, max_accums)  // Max 1000 accumulations
    }

    gpu.wait_idle()
}

Mesh_GPU :: struct
{
    pos: gpu.slice_t([4]f32),
    normals: gpu.slice_t([4]f32),
    indices: gpu.slice_t(u32),
    idx_count: u32,
    vert_count: u32,
    bvh: gpu.Owned_BVH,
}

Mesh_Shader :: struct
{
    pos: rawptr,
    normals: rawptr,
    indices: rawptr,
}

upload_mesh :: proc(upload_arena: ^gpu.Arena, cmd_buf: gpu.Command_Buffer, mesh: shared.Mesh) -> Mesh_GPU
{
    assert(len(mesh.pos) == len(mesh.normals))
    assert(len(mesh.pos) == len(mesh.uvs))

    positions_staging := gpu.arena_alloc(upload_arena, [4]f32, len(mesh.pos))
    normals_staging := gpu.arena_alloc(upload_arena, [4]f32, len(mesh.normals))
    uvs_staging := gpu.arena_alloc(upload_arena, [2]f32, len(mesh.uvs))
    indices_staging := gpu.arena_alloc(upload_arena, u32, len(mesh.indices))
    copy(positions_staging.cpu, mesh.pos[:])
    copy(normals_staging.cpu, mesh.normals[:])
    copy(uvs_staging.cpu, mesh.uvs[:])
    copy(indices_staging.cpu, mesh.indices[:])

    res: Mesh_GPU
    res.pos = gpu.mem_alloc([4]f32, len(mesh.pos), mem_type = gpu.Memory.GPU)
    res.normals = gpu.mem_alloc([4]f32, len(mesh.normals), mem_type = gpu.Memory.GPU)
    //res.uvs = gpu.mem_alloc([2]f32, len(mesh.uvs), mem_type = gpu.Memory.GPU)
    res.indices = gpu.mem_alloc(u32, len(mesh.indices), mem_type = gpu.Memory.GPU)
    gpu.cmd_mem_copy(cmd_buf, res.pos, positions_staging)
    gpu.cmd_mem_copy(cmd_buf, res.normals, normals_staging)
    //gpu.cmd_mem_copy(cmd_buf, res.uvs, uvs_staging)
    gpu.cmd_mem_copy(cmd_buf, res.indices, indices_staging)

    res.idx_count = u32(len(mesh.indices))
    res.vert_count = u32(len(mesh.pos))
    return res
}

mesh_destroy :: proc(mesh: ^Mesh_GPU)
{
    gpu.bvh_free_and_destroy(&mesh.bvh)
    gpu.mem_free(mesh.pos)
    gpu.mem_free(mesh.normals)
    gpu.mem_free(mesh.indices)
    mesh^ = {}
}

build_blas :: proc(bvh_scratch_arena: ^gpu.Arena, cmd_buf: gpu.Command_Buffer, positions: gpu.slice_t([4]f32), indices: gpu.slice_t(u32), idx_count: u32, vert_count: u32) -> gpu.Owned_BVH
{
    assert(idx_count % 3 == 0)

    desc := gpu.BLAS_Desc {
        hint = .Prefer_Fast_Trace,
        shapes = {
            gpu.BVH_Mesh_Desc {
                vertex_stride = 16,
                max_vertex = vert_count - 1,
                tri_count = idx_count / 3,
            }
        }
    }
    bvh := gpu.bvh_alloc_and_create(desc)
    scratch := gpu.bvh_alloc_build_scratch_buffer(bvh_scratch_arena, desc)
    gpu.cmd_build_blas(cmd_buf, bvh, scratch, { gpu.BVH_Mesh { verts = positions.gpu.ptr, indices = indices.gpu.ptr } })
    return bvh
}

build_tlas :: proc(bvh_scratch_arena: ^gpu.Arena, cmd_buf: gpu.Command_Buffer, instances: gpu.gpuptr, instance_count: u32) -> gpu.Owned_BVH
{
    desc := gpu.TLAS_Desc {
        hint = .Prefer_Fast_Trace,
        instance_count = instance_count
    }
    bvh := gpu.bvh_alloc_and_create(desc)
    scratch := gpu.bvh_alloc_build_scratch_buffer(bvh_scratch_arena, desc)
    gpu.cmd_build_tlas(cmd_buf, bvh, scratch, instances)
    return bvh
}

upload_bvh_instances :: proc(upload_arena: ^gpu.Arena, cmd_buf: gpu.Command_Buffer, instances: []shared.Instance, meshes: []Mesh_GPU) -> gpu.slice_t(gpu.BVH_Instance)
{
    instances_staging := gpu.arena_alloc(upload_arena, gpu.BVH_Instance, len(instances))
    for &instance, i in instances_staging.cpu
    {
        instance = {
            transform = shared.transform_to_gpu_transform(instances[i].transform),
            blas_root = gpu.bvh_root_ptr(meshes[instances[i].mesh_idx].bvh),
            disable_culling = true,
            flip_facing = true,
            mask = 1,
        }
    }
    instances_local := gpu.mem_alloc(gpu.BVH_Instance, len(instances), mem_type = gpu.Memory.GPU)
    gpu.cmd_mem_copy(cmd_buf, instances_local, instances_staging)
    return instances_local
}

Scene_GPU :: struct
{
    bvh: gpu.Owned_BVH,
    meshes: [dynamic]Mesh_GPU,
    instances_bvh: gpu.slice_t(gpu.BVH_Instance),

    // Shader view
    instances: gpu.slice_t(Instance_Shader),
    meshes_shader: gpu.slice_t(Mesh_Shader),
}

Scene_Shader :: struct
{
    instances: rawptr,
    meshes: rawptr,
}

Instance_Shader :: struct
{
    mesh_idx: u32,
}

upload_scene :: proc(scene: shared.Scene, upload_arena: ^gpu.Arena, bvh_scratch_arena: ^gpu.Arena, cmd_buf: gpu.Command_Buffer) -> Scene_GPU
{
    res: Scene_GPU

    // Upload meshes
    for mesh in scene.meshes
    {
        to_add := upload_mesh(upload_arena, cmd_buf, mesh)
        append(&res.meshes, to_add)
    }

    // Construct structures used by the shader
    instances_gpu := gpu.arena_alloc(upload_arena, Instance_Shader, len(scene.instances))
    for &instance, i in instances_gpu.cpu {
        instance = { mesh_idx = scene.instances[i].mesh_idx }
    }
    res.instances = gpu.mem_alloc(Instance_Shader, len(scene.instances), gpu.Memory.GPU)
    gpu.cmd_mem_copy(cmd_buf, res.instances, instances_gpu)

    meshes_gpu := gpu.arena_alloc(upload_arena, Mesh_Shader, len(scene.meshes))
    for &mesh, i in meshes_gpu.cpu {
        mesh.pos = res.meshes[i].pos.gpu.ptr
        mesh.normals = res.meshes[i].normals.gpu.ptr
        mesh.indices = res.meshes[i].indices.gpu.ptr
    }
    res.meshes_shader = gpu.mem_alloc(Mesh_Shader, len(scene.meshes), gpu.Memory.GPU)
    gpu.cmd_mem_copy(cmd_buf, res.meshes_shader, meshes_gpu)

    // Build BVHs
    gpu.cmd_barrier(cmd_buf, .Transfer, .Build_BVH)
    for &mesh in res.meshes {
        mesh.bvh = build_blas(bvh_scratch_arena, cmd_buf, mesh.pos, mesh.indices, mesh.idx_count, mesh.vert_count)
    }

    res.instances_bvh = upload_bvh_instances(upload_arena, cmd_buf, scene.instances[:], res.meshes[:])
    gpu.cmd_barrier(cmd_buf, .Transfer, .Build_BVH)

    res.bvh = build_tlas(upload_arena, cmd_buf, res.instances_bvh, u32(len(scene.instances)))
    gpu.cmd_barrier(cmd_buf, .Build_BVH, .All)

    return res
}

scene_destroy :: proc(scene: ^Scene_GPU)
{
    gpu.bvh_free_and_destroy(&scene.bvh)
    gpu.mem_free(scene.instances)
    gpu.mem_free(scene.meshes_shader)
    gpu.mem_free(scene.instances_bvh)
    for &mesh in scene.meshes {
        mesh_destroy(&mesh)
    }
    delete(scene.meshes)
    scene^ = {}
}
