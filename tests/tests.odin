
#+feature dynamic-literals

package main

import "core:image"
import "core:image/bmp"
import "core:log"
import "core:os"
import "core:fmt"
import "../examples/shared"
import "../examples/shared/gltf2"
import "core:math"
import "core:math/linalg"
import intr "base:intrinsics"
import "core:slice"

import "../gpu"

Target_Size :: 1024

Test :: struct
{
    name: string,
    test_proc: proc(target: Render_Target),
}

tests := []Test {
    { "triangle", test_triangle },
    { "texture", test_texture },
    { "texture_advanced", test_texture_advanced },
    { "compute", test_compute },
    { "comparison_sampler", test_comparison_sampler },
}

main :: proc()
{
    cmd_args := os.args

    gen_goldens := false
    if len(cmd_args) > 1 && cmd_args[1] == "gen_goldens" {
        gen_goldens = true
    }

    console_logger := log.create_console_logger()
    defer log.destroy_console_logger(console_logger)
    context.logger = console_logger

    ok := gpu.init()
    ensure(ok)
    defer gpu.cleanup()

    target := create_render_target()
    defer destroy_render_target(&target)

    program_return := 0
    for test, idx in tests
    {
        test_id := idx + 1

        // Clear render target
        {
            cmd_buf := gpu.commands_begin(.Main)
            gpu.cmd_begin_render_pass(cmd_buf, {
                color_attachments = {
                    { texture = target.color, clear_color = { 0, 0, 0, 1 } }
                }
            })
            gpu.cmd_end_render_pass(cmd_buf)
            gpu.queue_submit(.Main, { cmd_buf })
            gpu.wait_idle()
        }

        test.test_proc(target)
        gpu.wait_idle()

        output_path  := fmt.tprintf("tests/goldens_local/%v_%v.bmp", test_id, test.name)
        compare_path := fmt.tprintf("tests/goldens/%v_%v.bmp", test_id, test.name)

        if gen_goldens
        {
            save_target_color(target, output_path)
        }
        else
        {
            matches := compare_to_golden(target, compare_path)
            if matches {
                fmt.printfln("%v - Ok.", test.name)
            } else {
                fmt.printfln("%v - Fail!", test.name)
                program_return = 1
            }
        }
        gpu.wait_idle()
    }

    if program_return != 0 do os.exit(1)
}

test_triangle :: proc(target: Render_Target)
{
    vert_shader := gpu.shader_create(#load("../examples/1_triangle/shaders/shader.vert.spv", []u32), .Vertex)
    frag_shader := gpu.shader_create(#load("../examples/1_triangle/shaders/shader.frag.spv", []u32), .Fragment)
    defer {
        gpu.shader_destroy(vert_shader)
        gpu.shader_destroy(frag_shader)
    }

    Vertex :: struct { pos: [3]f32, color: [3]f32 }

    arena := gpu.arena_create()
    defer gpu.arena_destroy(&arena)

    verts := gpu.arena_alloc(&arena, Vertex, 3)
    verts.cpu[0].pos = { -0.5,  0.5, 0.0 }
    verts.cpu[1].pos = {  0.0, -0.5, 0.0 }
    verts.cpu[2].pos = {  0.5,  0.5, 0.0 }
    verts.cpu[0].color = { 1.0, 0.0, 0.0 }
    verts.cpu[1].color = { 0.0, 1.0, 0.0 }
    verts.cpu[2].color = { 0.0, 0.0, 1.0 }

    indices := gpu.arena_alloc(&arena, u32, 3)
    indices.cpu[0] = 0
    indices.cpu[1] = 2
    indices.cpu[2] = 1

    verts_local := gpu.mem_alloc(Vertex, 3, gpu.Memory.GPU)
    indices_local := gpu.mem_alloc(u32, 3, gpu.Memory.GPU)
    defer {
        gpu.mem_free(verts_local)
        gpu.mem_free(indices_local)
    }

    upload_cmd_buf := gpu.commands_begin(.Main)
    gpu.cmd_mem_copy(upload_cmd_buf, verts_local, verts)
    gpu.cmd_mem_copy(upload_cmd_buf, indices_local, indices)
    gpu.cmd_barrier(upload_cmd_buf, .Transfer, .All, {})
    gpu.queue_submit(.Main, { upload_cmd_buf })

    cmd_buf := gpu.commands_begin(.Main)
    gpu.cmd_begin_render_pass(cmd_buf, {
        color_attachments = {
            { texture = target.color }
        }
    })
    gpu.cmd_set_shaders(cmd_buf, vert_shader, frag_shader)
    Vert_Data :: struct {
        verts: rawptr,
    }
    verts_data := gpu.arena_alloc(&arena, Vert_Data)
    verts_data.cpu^ = { verts = verts_local.gpu.ptr }

    gpu.cmd_draw_indexed(cmd_buf, verts_data, {}, indices_local)
    gpu.cmd_end_render_pass(cmd_buf)
    gpu.queue_submit(.Main, { cmd_buf })
    gpu.wait_idle()
}

test_texture :: proc(target: Render_Target)
{
    Mona_Lisa_Texture :: #load("assets/monalisa.jpg")
}

test_texture_advanced :: proc(target: Render_Target)
{

}

test_compute :: proc(target: Render_Target)
{
    group_size_x := u32(8)
    group_size_y := u32(8)
    compute_shader := gpu.shader_create_compute(#load("shaders/shadertoy.comp.spv", []u32), group_size_x, group_size_y, 1)
    vert_shader := gpu.shader_create(#load("shaders/fullscreen_quad.vert.spv", []u32), .Vertex)
    frag_shader := gpu.shader_create(#load("shaders/fullscreen_quad.frag.spv", []u32), .Fragment)
    defer {
        gpu.shader_destroy(compute_shader)
        gpu.shader_destroy(vert_shader)
        gpu.shader_destroy(frag_shader)
    }

    // Indirect dispatch command (group counts)
    indirect_dispatch_command := gpu.mem_alloc(gpu.Dispatch_Indirect_Command)
    defer gpu.mem_free(indirect_dispatch_command)

    Compute_Data :: struct {
        output_texture_id: u32,
        time: f32,
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
    gpu.cmd_barrier(upload_cmd_buf, .Transfer, .All, {})
    gpu.queue_submit(.Main, { upload_cmd_buf })

    desc_pool := gpu.desc_pool_create()
    defer gpu.desc_pool_destroy(&desc_pool)

    // Create a texture for the compute shader to write to
    output_desc := gpu.Texture_Desc {
        dimensions = { u32(Target_Size), u32(Target_Size), 1 },
        format = .RGBA8_Unorm,
        usage = { .Storage, .Sampled },
    }
    output_texture := gpu.texture_alloc_and_create(output_desc)
    defer gpu.texture_free_and_destroy(&output_texture)

    // Create texture descriptor for sampled access (fragment shader)
    texture_id := gpu.desc_pool_alloc_texture(&desc_pool, gpu.texture_view_descriptor(output_texture, {}))
    // Create texture descriptor for RW access (compute shader)
    texture_rw_id := gpu.desc_pool_alloc_texture_rw(&desc_pool, gpu.texture_rw_view_descriptor(output_texture, {}))
    sampler_id := gpu.desc_pool_alloc_sampler(&desc_pool, gpu.sampler_descriptor({}))

    frame_arena := &arena

    // Allocate compute data for this frame with current time and resolution
    compute_data := gpu.arena_alloc(frame_arena, Compute_Data)
    compute_data.cpu.output_texture_id = texture_rw_id
    compute_data.cpu.time = 0.0

    cmd_buf := gpu.commands_begin(.Main)

    gpu.cmd_set_desc_heap(cmd_buf, desc_pool)

    // Dispatch compute shader to write to texture
    gpu.cmd_set_compute_shader(cmd_buf, compute_shader)

    num_groups_x := (u32(Target_Size) + group_size_x - 1) / group_size_x
    num_groups_y := (u32(Target_Size) + group_size_y - 1) / group_size_y
    num_groups_z := u32(1)

    Use_Indirect :: true
    if Use_Indirect {
        indirect_dispatch_command.cpu^ = gpu.Dispatch_Indirect_Command {
            num_groups_x,
            num_groups_y,
            num_groups_z,
        }

        gpu.cmd_dispatch_indirect(cmd_buf, compute_data, indirect_dispatch_command)
    } else {
        gpu.cmd_dispatch(cmd_buf, compute_data, num_groups_x, num_groups_y, num_groups_z)
    }

    // Barrier to ensure compute shader finishes before rendering
    gpu.cmd_barrier(cmd_buf, .Compute, .Fragment_Shader, {})

    // Render the texture to the swapchain using a fullscreen quad
    gpu.cmd_begin_render_pass(cmd_buf, {
        color_attachments = {
            { texture = target.color, clear_color = { 0.0, 0.0, 0.0, 1.0 } }
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
    gpu.queue_submit(.Main, { cmd_buf })
    gpu.wait_idle()
}

// NOTE: This is not only to test comparison samplers but by default this will
// also lead to pointers that are not 16B aligned, which leads to problems on NVidia (due to a driver bug?).
// So this test will make sure that arena allocations are all explicitly aligned to 16B.
test_comparison_sampler :: proc(target: Render_Target)
{
    shared.CAM_POS = { -7.581631, 1.1906259, 0.25928685 }
	shared.CAM_ANGLE = { 1.570796, 0.3665192 }

    Mesh_GPU :: struct
    {
        pos: gpu.slice_t([4]f32),
        normals: gpu.slice_t([4]f32),
        uvs: gpu.slice_t([2]f32),
        indices: gpu.slice_t(u32),
    }

    mesh_destroy :: proc(mesh: ^Mesh_GPU)
    {
        gpu.mem_free(mesh.pos)
        gpu.mem_free(mesh.normals)
        gpu.mem_free(mesh.uvs)
        gpu.mem_free(mesh.indices)
        mesh^ = {}
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
        res.pos = gpu.mem_alloc([4]f32, len(mesh.pos), gpu.Memory.GPU)
        res.normals = gpu.mem_alloc([4]f32, len(mesh.normals), gpu.Memory.GPU)
        res.uvs = gpu.mem_alloc([2]f32, len(mesh.uvs), gpu.Memory.GPU)
        res.indices = gpu.mem_alloc(u32, len(mesh.indices), gpu.Memory.GPU)
        gpu.cmd_mem_copy(cmd_buf, res.pos, positions_staging)
        gpu.cmd_mem_copy(cmd_buf, res.normals, normals_staging)
        gpu.cmd_mem_copy(cmd_buf, res.uvs, uvs_staging)
        gpu.cmd_mem_copy(cmd_buf, res.indices, indices_staging)
        return res
    }

    Sponza_Scene :: #load("assets/sponza.glb")

    // Shadow texture
    shadow_depth_desc := gpu.Texture_Desc {
        dimensions = { 1024*4, 1024*4, 1 },
        format = .D32_Float,
        usage = { .Depth_Stencil_Attachment, .Sampled },
    }
    shadow_depth_texture := gpu.texture_alloc_and_create(shadow_depth_desc)
    defer gpu.texture_free_and_destroy(&shadow_depth_texture)

    desc_pool := gpu.desc_pool_create()
    defer gpu.desc_pool_destroy(&desc_pool)

    shadow_tex_id  := gpu.desc_pool_alloc_texture(&desc_pool, gpu.texture_view_descriptor(shadow_depth_texture, {}))
    shadow_sampler := gpu.desc_pool_alloc_sampler(&desc_pool, gpu.sampler_descriptor({compare_op = .Less}))

    vert_shader := gpu.shader_create(#load("shaders/shadowmap.vert.spv", []u32), .Vertex)
    frag_shader := gpu.shader_create(#load("shaders/shadowmap.frag.spv", []u32), .Fragment)
    shadow_frag_shader := gpu.shader_create(#load("shaders/shadowmap.shadow_frag.spv", []u32), .Fragment)
    defer {
        gpu.shader_destroy(vert_shader)
        gpu.shader_destroy(frag_shader)
        gpu.shader_destroy(shadow_frag_shader)
    }

    arena := gpu.arena_create()
    defer gpu.arena_destroy(&arena)

    scene, _, gltf_data := shared.load_scene_gltf(Sponza_Scene, 0)
    defer {
        shared.destroy_scene(&scene)
        gltf2.unload(gltf_data)
    }

    meshes_gpu: [dynamic]Mesh_GPU
    defer {
        for &mesh_gpu in meshes_gpu do mesh_destroy(&mesh_gpu)
        delete(meshes_gpu)
    }

    upload_cmd_buf := gpu.commands_begin(.Main)
    for mesh in scene.meshes {
        append(&meshes_gpu, upload_mesh(&arena, upload_cmd_buf, mesh))
    }
    gpu.cmd_barrier(upload_cmd_buf, .Transfer, .All, {})
    gpu.queue_submit(.Main, { upload_cmd_buf })

    // Wrap CAM_ANGLE.x
    LIGHT_POS: [3]f32 = {0,0,0};
    LIGHT_ANGLE: [2]f32 = {math.RAD_PER_DEG * 45, math.RAD_PER_DEG * -80};
    LIGHT_ANGLE.y = clamp(LIGHT_ANGLE.y, math.to_radians_f32(-90), math.to_radians_f32(90))
    y_rot := linalg.quaternion_angle_axis(LIGHT_ANGLE.y, [3]f32{-1, 0, 0})
    x_rot := linalg.quaternion_angle_axis(LIGHT_ANGLE.x, [3]f32{0, 1, 0})
    light_rot: = x_rot * y_rot
    world_to_light := shared.world_to_view_mat(LIGHT_POS, light_rot);

    world_to_view := shared.first_person_camera_view(0.0)
    aspect_ratio := f32(Target_Size) / f32(Target_Size)
    view_to_proj := linalg.matrix4_perspective_f32(math.RAD_PER_DEG * 59.0, aspect_ratio, 0.1, 1000.0, false)
    light_to_proj := linalg.matrix_ortho3d_f32(-25,25, 18,-18, -40, 9, false)

    cmd_buf := gpu.commands_begin(.Main)

    frame_arena := &arena

    // ShadowPass
    {
        gpu.cmd_begin_render_pass(cmd_buf, {
            color_attachments = {},
            depth_attachment = gpu.Render_Attachment {
                texture = shadow_depth_texture, clear_color = 1.0
            },
        })
        gpu.cmd_set_shaders(cmd_buf, vert_shader, shadow_frag_shader)
        gpu.cmd_set_desc_heap(cmd_buf, desc_pool)
        gpu.cmd_set_depth_state(cmd_buf, { mode = { .Read, .Write }, compare = .Less })

        for instance in scene.instances
        {
            mesh := meshes_gpu[instance.mesh_idx]

            Vert_Data :: struct #all_or_none {
                positions: rawptr,
                normals: rawptr,
                model_to_world: [16]f32,
                model_to_world_normal: [16]f32,
                world_to_view: [16]f32,
                world_to_light: [16]f32,
                view_to_proj: [16]f32,
            }
            verts_data := gpu.arena_alloc(frame_arena, Vert_Data)
            verts_data.cpu^ = {
                positions = mesh.pos.gpu.ptr,
                normals = mesh.normals.gpu.ptr,
                model_to_world = intr.matrix_flatten(instance.transform),
                model_to_world_normal = intr.matrix_flatten(linalg.transpose(linalg.inverse(instance.transform))),
                world_to_view = intr.matrix_flatten(world_to_light),
                world_to_light = intr.matrix_flatten(light_to_proj * world_to_light),
                view_to_proj = intr.matrix_flatten(light_to_proj),
            }

            gpu.cmd_draw_indexed(cmd_buf, verts_data, {}, mesh.indices)
        }

        gpu.cmd_end_render_pass(cmd_buf)
    }

    // Render Pass
    {
        gpu.cmd_begin_render_pass(cmd_buf, {
            color_attachments = {
                { texture = target.color, clear_color = { 0.7, 0.7, 0.7, 1.0 } }
            },
            depth_attachment = gpu.Render_Attachment {
                texture = target.depth, clear_color = 1.0
            },
        })
        gpu.cmd_set_shaders(cmd_buf, vert_shader, frag_shader)
        gpu.cmd_set_desc_heap(cmd_buf, desc_pool)
        gpu.cmd_set_depth_state(cmd_buf, { mode = { .Read, .Write }, compare = .Less })

        for instance in scene.instances
        {
            mesh := meshes_gpu[instance.mesh_idx]

            Vert_Data :: struct #all_or_none {
                positions: rawptr,
                normals: rawptr,
                model_to_world: [16]f32,
                model_to_world_normal: [16]f32,
                world_to_view: [16]f32,
                world_to_light: [16]f32,
                view_to_proj: [16]f32,
            }
            verts_data := gpu.arena_alloc(frame_arena, Vert_Data)
            verts_data.cpu^ = {
                positions = mesh.pos.gpu.ptr,
                normals = mesh.normals.gpu.ptr,
                model_to_world = intr.matrix_flatten(instance.transform),
                model_to_world_normal = intr.matrix_flatten(linalg.transpose(linalg.inverse(instance.transform))),
                world_to_view = intr.matrix_flatten(world_to_view),
                world_to_light = intr.matrix_flatten(light_to_proj * world_to_light),
                view_to_proj = intr.matrix_flatten(view_to_proj),
            }

            Frag_Data :: struct {
                shadow_map: u32,
                shadow_sampler: u32,
                light_dir: [3]f32,
            }
            base_light_dir : [4]f32 = {0,0,1, 1}
            frag_data := gpu.arena_alloc(frame_arena, Frag_Data)
            frag_data.cpu^ = {
                shadow_map = shadow_tex_id,
                shadow_sampler = shadow_sampler,
                light_dir = (linalg.transpose(linalg.inverse(world_to_light)) * base_light_dir).xyz,
            }

            gpu.cmd_draw_indexed(cmd_buf, verts_data, frag_data, mesh.indices)
        }

        gpu.cmd_end_render_pass(cmd_buf)
    }

    gpu.queue_submit(.Main, { cmd_buf })
    gpu.wait_idle()
}

Render_Target :: struct
{
    color: gpu.Owned_Texture,
    depth: gpu.Owned_Texture,
}

create_render_target :: proc() -> Render_Target
{
    res: Render_Target
    res.color = gpu.texture_alloc_and_create({
        dimensions = { Target_Size, Target_Size, 1 },
        format = .RGBA8_Unorm,
        usage = { .Color_Attachment, .Transfer_Src }
    })
    res.depth = gpu.texture_alloc_and_create({
        dimensions = { Target_Size, Target_Size, 1 },
        format = .D32_Float,
        usage = { .Depth_Stencil_Attachment },
    })
    return res
}

destroy_render_target :: proc(target: ^Render_Target)
{
    gpu.texture_free_and_destroy(&target.color)
    gpu.texture_free_and_destroy(&target.depth)
}

save_target_color :: proc(target: Render_Target, path: string)
{
    cmd_buf := gpu.commands_begin(.Main)

    readback := gpu.mem_alloc([4]u8, Target_Size * Target_Size, gpu.Memory.Readback)
    defer gpu.mem_free(readback)

    gpu.cmd_copy_from_texture(cmd_buf, readback, target.color, {})
    gpu.queue_submit(.Main, { cmd_buf })

    gpu.wait_idle()

    // Save to disk
    img, ok_i := image.pixels_to_image(readback.cpu, Target_Size, Target_Size)
    ensure(ok_i)
    err := bmp.save(path, &img)
    if err != nil do log.error("Failed to save golden:", err)
    ensure(err == nil)
}

compare_to_golden :: proc(target: Render_Target, path: string) -> bool
{
    golden_file_content, err := os.read_entire_file_from_path(path, allocator = context.allocator)
    if err != nil do return false
    defer delete(golden_file_content)

    options := image.Options {
        .alpha_add_if_missing,
    }
    golden, err_l := image.load_from_bytes(golden_file_content, options)
    ensure(err_l == nil, "Could not load texture.")
    defer image.destroy(golden)

    readback := gpu.mem_alloc(u8, Target_Size * Target_Size * 4, gpu.Memory.Readback)
    defer gpu.mem_free(readback)
    cmd_buf := gpu.commands_begin(.Main)
    gpu.cmd_copy_from_texture(cmd_buf, readback, target.color, {})
    gpu.queue_submit(.Main, { cmd_buf })
    gpu.wait_idle()

    is_same := slice.equal(readback.cpu, golden.pixels.buf[:])
    return is_same
}
