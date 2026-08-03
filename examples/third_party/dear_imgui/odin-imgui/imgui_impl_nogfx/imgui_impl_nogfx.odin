
#+vet !unused-imports

package imgui_impl_nogfx

import "base:runtime"
import "core:slice"

import im "../"
import "../../../../../gpu"

// no_gfx backend, written by basically porting over the SDL_GPU and Vulkan backends.
// NOTE: Texture_IDs are just the texture indices (u32s).

Init_Info :: struct
{
    frames_in_flight: u32,
}

Backend_Data :: struct
{
    init_info: Init_Info,
    created_device_objects: bool,

    // Shaders
    vert_shader: gpu.Shader,
    frag_shader: gpu.Shader,

    upload_arena: gpu.Arena,

    // Font
    fonts_texture: gpu.Owned_Texture,
    fonts_texture_id: u32,
    sampler_linear_id: u32,
    sampler_nearest_id: u32,

    // Frame data for main window
    main_window_frames_data: Frames_Data,
}

MAX_FRAMES_IN_FLIGHT :: 10
Frames_Data :: struct
{
    idx: u32,
    count: u32,
    frames: [MAX_FRAMES_IN_FLIGHT]Frame_Data
}

// Data used for one frame in flight.
Frame_Data :: struct
{
    staging_arena: gpu.Arena,
}

// Just like the SDL_GPU backend,
// this is temporarily stored in GetPlatformIO().Renderer_RenderState during the imgui_impl_nogfx.render_draw_data() call.
Render_State :: struct
{
    sampler_linear_id: u32,  // Bilinear filtering sampler
    sampler_nearest_id: u32,  // Nearest/point filtering sampler
    sampler_current_id: u32,  // Current sampler (may be changed by callback)
}

init :: proc(init_info: Init_Info, desc_pool: ^gpu.Descriptor_Pool) -> bool
{
    assert(init_info.frames_in_flight <= MAX_FRAMES_IN_FLIGHT, "Exceeded max limit for frames in flight.")

    io := im.get_io()
    im.CHECKVERSION()
    assert(io.backend_renderer_user_data == nil, "Already initialized a renderer backend!")

    bd := new(Backend_Data)
    io.backend_renderer_user_data = rawptr(bd)
    io.backend_renderer_name = "imgui_impl_nogfx"
    // We can honor the ImDrawCmd::VtxOffset field, allowing for large meshes.
    io.backend_flags += { .Renderer_Has_Vtx_Offset }

    bd.init_info = init_info

    if !bd.created_device_objects do create_device_objects(desc_pool)

    bd.upload_arena = gpu.arena_create()
    return true
}

get_backend_data :: proc() -> ^Backend_Data
{
    if im.get_current_context() == nil do return nil
    return cast(^Backend_Data) im.get_io().backend_renderer_user_data
}

shutdown :: proc()
{
    bd := get_backend_data()
    assert(bd != nil, "No renderer backend to shutdown, or already shutdown?")
    io := im.get_io()
    platform_io := im.get_platform_io()

    destroy_device_objects()

    io.backend_renderer_name = nil
    io.backend_renderer_user_data = nil
    io.backend_flags -= { .Renderer_Has_Vtx_Offset }
    // platform_io.ClearRendererHandlers()
    free(bd)
}

new_frame :: proc()
{
    bd := get_backend_data()
    assert(bd != nil, "Context or backend not initialized! Did you call imgui_impl_nogfx.init()?")
}

render_draw_data :: proc(draw_data: ^im.Draw_Data, cmd_buf: gpu.Command_Buffer)
{
    // Avoid rendering when minimized, scale coordinates for retina displays (screen coordinates != framebuffer coordinates)
    fb_width := int(draw_data.display_size.x * draw_data.framebuffer_scale.x)
    fb_height := int(draw_data.display_size.y * draw_data.framebuffer_scale.y)
    if fb_width <= 0 || fb_height <= 0 do return

    bd := get_backend_data()

    frames_data := &bd.main_window_frames_data
    if frames_data.count == 0
    {
        frames_data.count = bd.init_info.frames_in_flight
        for i in 0..<frames_data.count {
            frames_data.frames[i].staging_arena = gpu.arena_create()
        }
    }

    fd := &frames_data.frames[frames_data.idx]
    frames_data.idx = (frames_data.idx + 1) % frames_data.count

    gpu.arena_free_all(&fd.staging_arena)

    // Will project scissor/clipping rectangles into framebuffer space
    clip_off := draw_data.display_pos         // (0,0) unless using multi-viewports
    clip_scale := draw_data.framebuffer_scale // (1,1) unless using retina display which are often (2,2)

    // Setup render state structure (for callbacks and custom texture bindings)
    platform_io := im.get_platform_io()

    render_state: Render_State
    setup_render_state(draw_data, &render_state, cmd_buf, fd, fb_width, fb_height)

    platform_io.renderer_render_state = &render_state;

    // Prepare verts
    verts: gpu.slice_t(im.Draw_Vert)
    indices: gpu.slice_t(u16)
    if draw_data.total_vtx_count > 0
    {
        verts   = gpu.arena_alloc(&fd.staging_arena, im.Draw_Vert, draw_data.total_vtx_count)
        indices = gpu.arena_alloc(&fd.staging_arena, u16,          draw_data.total_idx_count)
        dst_vert := 0
        dst_idx  := 0
        for i in 0..<draw_data.cmd_lists_count
        {
            draw_list := ptr_to_multi_ptr(draw_data.cmd_lists.data)[i]
            idx_buffer_vec := ptr_to_multi_ptr(draw_list.idx_buffer.data)
            vtx_buffer_vec := ptr_to_multi_ptr(draw_list.vtx_buffer.data)

            copy(verts.cpu[dst_vert:],  vtx_buffer_vec[:draw_list.vtx_buffer.size])
            copy(indices.cpu[dst_idx:], idx_buffer_vec[:draw_list.idx_buffer.size])
            dst_vert += int(draw_list.vtx_buffer.size)
            dst_idx += int(draw_list.idx_buffer.size)
        }
    }

    // Render command lists
    // (Because we merged all buffers into a single one, we maintain our own offset into them)
    global_vtx_offset := i32(0)
    global_idx_offset := i32(0)
    for draw_list_i in 0..<draw_data.cmd_lists.size
    {
        draw_list := ptr_to_multi_ptr(draw_data.cmd_lists.data)[draw_list_i]

        for cmd_i in 0..<draw_list.cmd_buffer.size
        {
            pcmd := &(ptr_to_multi_ptr(draw_list.cmd_buffer.data)[cmd_i])
            if pcmd.user_callback != nil
            {
                // User callback, registered via ImDrawList::AddCallback()
                // (ImDrawCallback_ResetRenderState is a special callback value used by the user to request the renderer to reset render state.)
                if pcmd.user_callback == transmute(im.Draw_Callback) i64(-8) {
                    setup_render_state(draw_data, &render_state, cmd_buf, fd, fb_width, fb_height)
                } else {
                    pcmd.user_callback(draw_list, pcmd)
                }
            }
            else
            {
                // Project scissor/clipping rectangles into framebuffer space
                clip_min := [2]f32 { (pcmd.clip_rect.x - clip_off.x) * clip_scale.x, (pcmd.clip_rect.y - clip_off.y) * clip_scale.y }
                clip_max := [2]f32 { (pcmd.clip_rect.z - clip_off.x) * clip_scale.x, (pcmd.clip_rect.w - clip_off.y) * clip_scale.y }

                // Clamp to viewport
                if clip_min.x < 0.0 do clip_min.x = 0.0
                if clip_min.y < 0.0 do clip_min.y = 0.0
                if clip_max.x > f32(fb_width) do clip_max.x = f32(fb_width)
                if clip_max.y > f32(fb_height) do clip_max.y = f32(fb_height)
                if clip_max.x <= clip_min.x || clip_max.y <= clip_min.y {
                    continue
                }

                // Apply scissor/clipping rectangle
                gpu.cmd_set_scissor(cmd_buf, {
                    { i32(clip_min.x), i32(clip_min.y) },
                    { u32(clip_max.x - clip_min.x), u32(clip_max.y - clip_min.y) }
                })

                Vert_Data :: struct {
                    verts: rawptr,
                    vert_offset: u32,
                    scale: [2]f32,
                    translate: [2]f32,
                }
                vert_data := gpu.arena_alloc(&fd.staging_arena, Vert_Data)
                scale := [2]f32 { 2.0 / draw_data.display_size.x, 2.0 / draw_data.display_size.y }
                vert_data.cpu^ = Vert_Data {
                    verts = verts.gpu.ptr,
                    vert_offset = pcmd.vtx_offset + u32(global_vtx_offset),
                    scale = scale,
                    translate = {
                        -1.0 - draw_data.display_pos.x * scale.x,
                        -1.0 - draw_data.display_pos.y * scale.y,
                    }
                }

                Frag_Data :: struct {
                    tex_id: u32,
                    sampler_id: u32,
                }
                frag_data := gpu.arena_alloc(&fd.staging_arena, Frag_Data)
                frag_data.cpu^ = Frag_Data {
                    tex_id = u32(im.draw_cmd_get_tex_id(pcmd)),
                    sampler_id = render_state.sampler_current_id,
                }
                offset_start := i32(pcmd.idx_offset) + global_idx_offset
                gpu.cmd_draw_indexed(cmd_buf, vert_data, frag_data, gpu.subslice(indices, offset_start, offset_start + i32(pcmd.elem_count)))
            }
        }
        global_idx_offset += draw_list.idx_buffer.size
        global_vtx_offset += draw_list.vtx_buffer.size
    }

    // Note: at this point both gpu.cmd_set_viewport() and gpu.cmd_set_scissor() have been called.
    // Our last values will leak into user/application rendering if you forgot to call gpu.cmd_set_viewport() and gpu.cmd_set_scissor() yourself to explicitly set that state
    // In theory we should aim to backup/restore those values but this is not possible.
    gpu.cmd_set_scissor(cmd_buf, {
        offset = {},
        size = { u32(fb_width), u32(fb_height) }
    })
}

create_fonts_texture :: proc(desc_pool: ^gpu.Descriptor_Pool)
{
    io := im.get_io()
    bd := get_backend_data()

    if bd.fonts_texture != {}
    {
        gpu.wait_idle()
        destroy_fonts_texture()
    }

    cmd_buf := gpu.commands_begin(.Main)

    pixels_ptr: ^u8
    width, height: i32
    im.font_atlas_get_tex_data_as_rgba32(io.fonts, &pixels_ptr, &width, &height)
    pixels := slice.from_ptr(pixels_ptr, int(width * height * 4))

    staging := gpu.arena_alloc(&bd.upload_arena, u8, u64(len(pixels)))
    copy(staging.cpu, pixels)

    bd.fonts_texture = gpu.texture_alloc_and_create({
        dimensions = { u32(width), u32(height), 1 },
        format = .RGBA8_Unorm,
        usage = { .Sampled },
    })
    gpu.cmd_copy_to_texture(cmd_buf, bd.fonts_texture, staging)

    bd.fonts_texture_id = gpu.desc_pool_alloc_texture(desc_pool, gpu.texture_view_descriptor(bd.fonts_texture, {}))

    // Store our identifier
    im.font_atlas_set_tex_id(io.fonts, transmute(im.Texture_ID)u64(bd.fonts_texture_id))

    gpu.cmd_barrier(cmd_buf, .Transfer, .All)
    gpu.queue_submit(.Main, { cmd_buf })
}

destroy_fonts_texture :: proc()
{
    bd := get_backend_data()
    gpu.texture_free_and_destroy(&bd.fonts_texture)
}

setup_render_state :: proc(draw_data: ^im.Draw_Data, render_state: ^Render_State, cmd_buf: gpu.Command_Buffer, fd: ^Frame_Data, fb_width: int, fb_height: int)
{
    bd := get_backend_data()
    gpu.cmd_set_shaders(cmd_buf, bd.vert_shader, bd.frag_shader)
    gpu.cmd_set_viewport(cmd_buf, {
        size = { f32(fb_width), f32(fb_height) },
        depth_min = 0, depth_max = 1,
    })
    gpu.cmd_set_raster_state(cmd_buf, { cull_mode = .None })
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

    render_state.sampler_linear_id  = bd.sampler_linear_id
    render_state.sampler_nearest_id = bd.sampler_nearest_id
    render_state.sampler_current_id = bd.sampler_linear_id
}

create_device_objects :: proc(desc_pool: ^gpu.Descriptor_Pool)
{
    bd := get_backend_data();

    if bd.created_device_objects {
        destroy_device_objects()
    }

    bd.created_device_objects = true

    bd.sampler_linear_id = gpu.desc_pool_alloc_sampler(desc_pool, gpu.sampler_descriptor({
        min_filter = .Linear,
        mag_filter = .Linear,
        mip_filter = .Linear,
        address_mode_u = .Clamp_To_Edge,
        address_mode_v = .Clamp_To_Edge,
        address_mode_w = .Clamp_To_Edge,
        min_lod = -1000,
        max_lod =  1000
    }))
    bd.sampler_nearest_id = gpu.desc_pool_alloc_sampler(desc_pool, gpu.sampler_descriptor({
        min_filter = .Nearest,
        mag_filter = .Nearest,
        mip_filter = .Nearest,
        address_mode_u = .Clamp_To_Edge,
        address_mode_v = .Clamp_To_Edge,
        address_mode_w = .Clamp_To_Edge,
        min_lod = -1000,
        max_lod =  1000,
    }))

    create_shaders()
}

destroy_device_objects :: proc()
{
    destroy_frame_data()
    destroy_fonts_texture()

    bd := get_backend_data()
    if bd.vert_shader != {} { gpu.shader_destroy(bd.vert_shader) }
    if bd.frag_shader != {} { gpu.shader_destroy(bd.frag_shader) }
    if bd.upload_arena.block_size != {} { gpu.arena_destroy(&bd.upload_arena) }
}

destroy_frame_data :: proc()
{
    bd := get_backend_data()
    fd := &bd.main_window_frames_data
    for &frame in fd.frames {
        gpu.arena_destroy(&frame.staging_arena)
    }
}

create_shaders :: proc()
{
    bd := get_backend_data()
    bd.vert_shader = gpu.shader_create(#load("shaders/im.vert.spv", []u32), .Vertex)
    bd.frag_shader = gpu.shader_create(#load("shaders/im.frag.spv", []u32), .Fragment)
}

// NOTE: The Dear ImGui bindings are wrong because they don't use multipointers and instead use regular pointers
// for C arrays making it so you can't index into them
@(private="file")
ptr_to_multi_ptr :: #force_inline proc(ptr: ^$T) -> [^]T
{
    return transmute([^]T) ptr
}
