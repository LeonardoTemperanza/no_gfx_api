
package gpu

import "core:slice"

import sdl "vendor:sdl3"

// This API follows the ZII (Zero Is Initialization) principle. Initializing to 0
// will yield predictable and reasonable behavior in general.

// Handles
Handle :: rawptr
Texture :: distinct Handle
Command_Buffer :: distinct Handle
Queue :: distinct Handle
Semaphore :: distinct Handle
Shader :: distinct Handle

// Enums
Memory :: enum { Default = 0, GPU, Readback }
Texture_Type :: enum { D2 = 0, D3, D1, Cube, D2_Array, Cube_Array }
Texture_Format :: enum { None = 0, Rgba8_Unorm, D32_Float, Rg11B10_Float, Rgb10_A2_Unorm }
Usage :: enum { Sampled = 0, Storage, Color_Attachment, Depth_Stencil_Attachment }
Usage_Flags :: bit_set[Usage; u32]
Shader_Type :: enum { Vertex = 0, Fragment }

// Constants
All_Mips: u8 : max(u8)
All_Layers: u16 : max(u16)

// Structs
Texture_Desc :: struct
{
    type: Texture_Type,
    dimensions: [3]u32,
    mip_count: u32,     // 0 = 1
    layer_count: u32,   // 0 = 1
    sample_count: u32,  // 0 = 1
    format: Texture_Format,
    usage: Usage_Flags,
}

Texture_View_Desc :: struct
{
    format: Texture_Format,
    base_mip: u32,
    mip_count: u8,     // 0 = All_Mips
    base_layer: u16,
    layer_count: u16,  // 0 = All_Layers
}

Attachment :: struct
{
    test: u32
}

Render_Pass_Desc :: struct
{
    //renderArea:           Rect2D,
    layer_count:          u32,
    view_mask:            u32,
    color_attachments:    []Attachment,
    depth_attachment:     Maybe(Attachment),
    stencil_attachment:   Maybe(Attachment),
}

// Initialization. This is simpler than it would actually be, for brevity.
init: proc(window: ^sdl.Window) : _init
cleanup: proc() : _cleanup

// Memory
mem_alloc: proc(bytes: u64, align: u64 = 1, mem_type := Memory.Default) -> rawptr : _mem_alloc
mem_free: proc(ptr: rawptr, loc := #caller_location) : _mem_free
host_to_device_ptr: proc(ptr: rawptr) -> rawptr : _host_to_device_ptr  // Only supports base allocation pointers, like mem_free!

// Textures
//texture_size_and_align: proc(desc: Texture_Desc) -> (size: u64, align: u64) : _texture_size_and_align
//texture_view_descriptor: proc(texture: Texture, view_desc: Texture_View_Desc) -> [4]u64 : _texture_view_descriptor
//texture_rw_view_descriptor: proc(texture: Texture, view_desc: Texture_View_Desc) -> [4]u64 : _texture_rw_view_descriptor

// Shaders
shader_create :: proc(code: []byte, type: Shader_Type)

// Semaphores
// sem_create: proc(init_value: u64) -> Semaphore : _sem_create

// Commands
cmd_mem_copy: proc(cmd_buf: Command_Buffer, src, dst: rawptr, bytes: u64) : _cmd_mem_copy
//cmd_copy_to_texture: proc(cmd_buf: Command_Buffer, texture: Texture, src, dst: rawptr) : _cmd_copy_to_texture

//cmd_set_active_texture_heap_ptr: proc(cmd_buf: Command_Buffer, ptr: rawptr) : _cmd_set_active_texture_heap_ptr

//cmd_barrier: proc() : _cmd_barrier
//cmd_signal_after: proc() : _cmd_signal_after
//cmd_wait_before: proc() : _cmd_wait_before

cmd_set_shaders: proc(cmd_buf: Command_Buffer, vert_shader: Shader, frag_shader: Shader) : _cmd_set_shaders
//cmd_set_depth_stencil_state: proc() : _cmd_set_depth_stencil_state
//cmd_set_blend_state: proc() : _cmd_set_blend_state

//cmd_dispatch: proc() : _cmd_dispatch
//cmd_dispatch_indirect: proc() : _cmd_dispatch_indirect

cmd_begin_render_pass: proc(cmd_buf: Command_Buffer, desc: Render_Pass_Desc) : _cmd_begin_render_pass
cmd_end_render_pass: proc(cmd_buf: Command_Buffer) : _cmd_end_render_pass

// Indices can be nil
cmd_draw_indexed_instanced: proc(cmd_buf: Command_Buffer, vertex_data: rawptr, pixel_data: rawptr,
                                 indices: rawptr, index_count: u32, instance_count: u32 = 1) : _cmd_draw_indexed_instanced

// Userland Utilities

mem_alloc_typed :: proc($T: typeid, count: u64) -> []T
{
    ptr := mem_alloc(size_of(T) * count, align_of(T))
    return slice.from_ptr(cast(^T) ptr, int(count))
}

mem_alloc_typed_gpu :: proc($T: typeid, count: u64) -> rawptr
{
    ptr := mem_alloc(size_of(T) * count, align_of(T), mem_type = .GPU)
    return ptr
}

// Avoid -vet warnings about unused "slice" package
@(private="file")
_fictitious :: proc() { mem_alloc_typed(u32, 0) }

mem_free_typed :: proc(mem: []$T, loc := #caller_location)
{
    mem_free(raw_data(mem), loc = loc)
}

Arena :: struct
{
    cpu: rawptr,
    gpu: rawptr,
    offset: u64,
    size: u64,
}

Allocation :: struct($T: typeid)
{
    cpu: []T,
    gpu: rawptr,
}

arena_init :: proc(storage: u64) -> Arena
{
    res: Arena
    res.size = storage
    res.cpu = mem_alloc(storage)
    res.gpu = host_to_device_ptr(res.cpu)
    return res
}

arena_alloc_untyped :: proc(using arena: ^Arena, bytes: u64, align: u64 = 16) -> (alloc_cpu: rawptr, alloc_gpu: rawptr)
{
    offset = u64(align_up(offset, align))
    if offset + bytes > size do offset = 0  // No overflow detection

    alloc_cpu = auto_cast(uintptr(cpu) + uintptr(offset))
    alloc_gpu = auto_cast(uintptr(gpu) + uintptr(offset))
    offset += bytes
    return
}

arena_alloc :: proc(using arena: ^Arena, $T: typeid, count: u64) -> Allocation(T)
{
    alloc_cpu, alloc_gpu := arena_alloc_untyped(arena, size_of(T) * count, align_of(T))
    return {
        cpu = slice.from_ptr(cast(^T) alloc_cpu, int(count)),
        gpu = alloc_gpu
    }
}

arena_free_all :: proc(using arena: ^Arena)
{
    offset = 0
}

arena_destroy :: proc(using arena: ^Arena)
{
    offset = 0
    size = 0
    mem_free(cpu)
    cpu = nil
    gpu = nil
}

@(private="file")
align_up :: proc(x, align: u64) -> (aligned: u64)
{
    assert(0 == (align & (align - 1)), "must align to a power of two")
    return (x + (align - 1)) &~ (align - 1)
}
