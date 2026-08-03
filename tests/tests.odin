
#+feature dynamic-literals

package main

import "core:image"
import "core:image/bmp"
import "core:log"
import "core:os"
import "core:strings"

import "../gpu"

Target_Size :: 256

tests: map[string]proc(target: Render_Target) = {
    "test_triangle" = test_triangle,
    //"test_texture" = test_texture,
    //test_texture_advanced,
    //test_compute
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

    for name, test in tests
    {
        test(target)
        gpu.wait_idle()

        output_path := strings.concatenate({"tests/goldens/", name, ".bmp"})

        if gen_goldens {
            save_target_color(target, output_path)
        } else {
            compare_to_golden(target, output_path)
        }
        gpu.wait_idle()
    }
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

}

test_texture_advanced :: proc(target: Render_Target)
{

}

test_compute :: proc(target: Render_Target)
{

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
    return res
}

destroy_render_target :: proc(target: ^Render_Target)
{
    gpu.texture_free_and_destroy(&target.color)
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

compare_to_golden :: proc(target: Render_Target, path: string)
{
    
}
