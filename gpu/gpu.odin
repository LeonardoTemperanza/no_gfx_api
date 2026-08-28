
#+vet !unused-imports

package gpu

import "base:runtime"
import intr "base:intrinsics"
import "core:slice"
import "core:sync"
import mem "core:mem"
import "core:math"

import sdl "vendor:sdl3"
import vk "vendor:vulkan"

// This API follows the ZII (Zero Is Initialization) principle. Initializing to 0
// will yield predictable and reasonable behavior in general.

// Handles
Handle :: rawptr
Big_Handle :: [2]u64
Texture_Handle :: distinct Handle
Command_Buffer :: distinct Handle
Semaphore :: distinct Handle
Shader :: distinct Handle
BVH :: struct { _: Handle }
Descriptor_Heap :: struct { _: Handle }
Texture_Descriptor :: distinct Big_Handle
Sampler_Descriptor :: distinct Handle

// Enums
Present_Mode :: enum
{
    Auto_VSync = 0,  // First supported from [ FifoRelaxed, Fifo ].
    Auto_No_VSync,   // First supported from [ Immediate, Mailbox, Fifo].
    Fifo,            // Standard V-SYNC. Guaranteed to be supported.
    Fifo_Relaxed,    // Low support coverage. V-SYNC with reduced stutter, will tear when rendering slower than refresh.
    Mailbox,         // V-SYNC, but rendering still goes as fast as possible.
    Immediate,       // no V-SYNC, tearing will occur.
}
Feature :: enum { Raytracing = 0, Draw_Indirect_Multi }
Features :: bit_set[Feature; u32]
Memory :: enum { Default = 0, GPU, Readback }
Queue :: enum { Main = 0, Compute, Transfer }
Texture_Type :: enum { Default = 0, D2, D3, D1, Cube, D2_Array, D1_Array, Cube_Array }
Texture_Format :: enum
{
    Default = 0,
    R8_Unorm, RG8_Unorm, RGBA8_Unorm, ABGR8_Unorm, BGRA8_Unorm,
    R8_SRGB, RG8_SRGB, RGBA8_SRGB, ABGR8_SRGB, BGRA8_SRGB,
    R16_Unorm, RG16_Unorm, RGBA16_Unorm,
    D16_Unorm, D16_Unorm_S8_Uint, D24_Unorm_Pack32, D24_Unorm_S8_Uint, D32_Float,
    R16_Float, RG16_Float, RGBA16_Float, R32_Float, RG32_Float, RGBA32_Float,
    BC1_RGBA_Unorm,
    BC3_RGBA_Unorm,
    BC4_R_Unorm,
    BC5_RG_Unorm,
    BC6H_RGB_Float,
    BC7_RGBA_Unorm, BC7_RGBA_SRGB,
    ASTC_4x4_RGBA_Unorm,
    ETC2_RGB8_Unorm, ETC2_RGBA8_Unorm,
    EAC_R11_Unorm, EAC_RG11_Unorm,
}
// Each side corresponds to a texture layer
Cubemap_Side :: enum { PX = 0, NX = 1, PY = 2, NY = 3, PZ = 4, NZ = 5 }
Usage :: enum { Sampled = 0, Storage, Transfer_Src, Color_Attachment, Depth_Stencil_Attachment }
Usage_Flags :: bit_set[Usage; u32]
Shader_Type_Graphics :: enum { Vertex = 0, Fragment }
Load_Op :: enum { Clear = 0, Load, Dont_Care }
Store_Op :: enum { Store = 0, Dont_Care, Resolve, Resolve_And_Store }
Compare_Op :: enum { Never = 0, Less, Equal, Less_Equal, Greater, Not_Equal, Greater_Equal, Always }
Blend_Op :: enum { Add, Subtract, Rev_Subtract, Min, Max }
Blend_Factor :: enum { Zero, One, Src_Color, Dst_Color, Src_Alpha, Dst_Alpha, One_Minus_Src_Alpha, One_Minus_Src_Color, One_Minus_Dst_Alpha, One_Minus_Dst_Color }
Index_Format :: enum { U32 = 0, U16 }
Topology :: enum { Triangle_List = 0, Triangle_Strip, Triangle_Fan };
Cull_Mode :: enum { Cull_CW = 0, Cull_CCW, None, All };
Depth_Mode :: enum { Read = 0, Write }
Depth_Flags :: bit_set[Depth_Mode; u32]
Hazard :: enum { Draw_Arguments = 0, Descriptors, Depth_Stencil, BVHs }
Hazard_Flags :: bit_set[Hazard; u32]
Stage :: enum { Transfer = 0, Compute, Raster_Color_Out, Fragment_Shader, Vertex_Shader, Build_BVH, All }
Color_Component_Flag :: enum { R = 0, G = 1, B = 2, A = 3 }
Color_Component_Flags :: distinct bit_set[Color_Component_Flag; u8]
Color_Components_All :: Color_Component_Flags { .R, .G, .B, .A }
Filter :: enum { Linear = 0, Nearest }
Address_Mode :: enum { Repeat = 0, Mirrored_Repeat, Clamp_To_Edge }
BVH_Instance_Flag :: enum { Disable_Culling = 0, Flip_Facing = 1, Force_Opaque = 2, Force_Not_Opaque = 3 }
BVH_Instance_Flags :: distinct bit_set[BVH_Instance_Flag; u32]
BVH_Opacity :: enum { Fully_Opaque = 0, Transparent }
BVH_Hint :: enum { Default = 0, Prefer_Fast_Trace, Prefer_Fast_Build, Prefer_Low_Memory }
BVH_Capability :: enum { Update = 0, Compaction }
BVH_Capabilities :: distinct bit_set[BVH_Capability; u32]

// Structs

Viewport :: struct
{
    origin: [2]f32,
    size: [2]f32,
    depth_min: f32,
    depth_max: f32,
}

Rect_2D :: struct
{
    offset: [2]i32,
    size: [2]u32,
}

Rect_3D :: struct
{
    offset: [3]i32,
    size: [3]u32,
}

Texture_Region :: struct
{
    rect: Rect_3D,     // rect.size == 0 -> entire size
    mip_level: u32,
    base_layer: u32,
    layer_count: u32,  // 0 = 1
}

Blit_Rect :: struct
{
    offset_a: [3]i32,  // offset_a == 0 && offset_b == 0 -> full image
    offset_b: [3]i32,  // offset_a == 0 && offset_b == 0 -> full image
    mip_level: u32,
    base_layer: u32,
    layer_count: u32,
}

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

Sampler_Desc :: struct
{
    min_filter: Filter,
    mag_filter: Filter,
    mip_filter: Filter,
    address_mode_u: Address_Mode,
    address_mode_v: Address_Mode,
    address_mode_w: Address_Mode,
    mip_lod_bias: f32,
    min_lod: f32,
    max_lod: f32,  // 0.0 = use all lods
    max_anisotropy: f32,
    compare_op: Compare_Op,  // Used for comparison/shadow sampling
}

Texture_View_Desc :: struct
{
    type: Texture_Type,      // .Default = inherits the texture's type
    format: Texture_Format,  // .Default = inherits the texture's format
    base_mip: u32,
    mip_count: u8,           // 0 = all mips
    base_layer: u16,
    layer_count: u16,        // 0 = all layers
}

Render_Attachment :: struct
{
    texture: Texture,
    view: Texture_View_Desc,
    load_op: Load_Op,
    store_op: Store_Op,
    clear_color: [4]f32,
    resolve_texture: Texture,
    resolve_view: Texture_View_Desc,
}

Render_Pass_Desc :: struct
{
    render_area_offset: [2]i32,
    render_area_size:   [2]u32,  // 0 = full texture size
    layer_count:        u32,     // 0 = 1
    view_mask:          u32,
    color_attachments:  []Render_Attachment,
    depth_attachment:   Maybe(Render_Attachment),
    stencil_attachment: Maybe(Render_Attachment),
}

Texture :: struct #all_or_none
{
    type: Texture_Type,
    dimensions: [3]u32,
    format: Texture_Format,
    mip_count: u32,
    layer_count: u32,
    sample_count: u32,
    handle: Texture_Handle
}

Raster_State :: struct
{
    topology: Topology,
    cull_mode: Cull_Mode,
    alpha_to_coverage: bool,
}

Depth_State :: struct
{
    mode: Depth_Flags,
    compare: Compare_Op
}

Blend_State :: struct
{
    enable: bool,
    color_op: Blend_Op,
    src_color_factor: Blend_Factor,
    dst_color_factor: Blend_Factor,
    alpha_op: Blend_Op,
    src_alpha_factor: Blend_Factor,
    dst_alpha_factor: Blend_Factor,
    color_write_mask: Color_Component_Flags,
}

Draw_Indexed_Indirect_Command :: struct
{
    index_count: u32,
    instance_count: u32,
    first_index: u32,
    vertex_offset: i32,
    first_instance: u32,
}

Dispatch_Indirect_Command :: struct
{
    num_groups_x: u32,
    num_groups_y: u32,
    num_groups_z: u32,
}

BVH_Instance :: struct
{
    transform: [12]f32,  // Row-major 3x4 matrix!
    using _: bit_field u32 {
        custom_idx: u32 | 24,
        mask:       u32 | 8,
    },
    using _: bit_field u32 {
        _unused: u32 | 24,
        disable_culling: bool | 1,
        flip_facing: bool | 1,
        force_opaque: bool | 1,
        force_not_opaque: bool | 1,
        force_opacity_micromaps: bool | 1,
        disable_opacity_micromaps: bool | 1,
        _unused_flags: bool | 2,
    },
    blas_root: rawptr,
}

BVH_Mesh_Desc :: struct
{
    opacity: BVH_Opacity,
    vertex_stride: u32,
    max_vertex: u32,  // e.g. if reading vertices [200..300], this value must be 300.
    tri_count: u32,
}
BVH_AABB_Desc :: struct
{
    opacity: BVH_Opacity,
    stride: u32,
    aabb_count: u32,
}
BVH_Shape_Desc :: union { BVH_Mesh_Desc, BVH_AABB_Desc }

BVH_Mesh  :: struct { verts: rawptr, indices: rawptr }
BVH_AABBs :: struct { data: rawptr }
BVH_Shape :: union { BVH_Mesh, BVH_AABBs }

BLAS_Desc :: struct
{
    hint: BVH_Hint,
    caps: BVH_Capabilities,
    shapes: []BVH_Shape_Desc,
}

TLAS_Desc :: struct
{
    hint: BVH_Hint,
    caps: BVH_Capabilities,
    instance_count: u32,
}

Device_Limits :: struct
{
    max_anisotropy: f32,
}

Spec_Constant :: struct
{
    id: u32,
    value: union { f32, b32, i32, u32 }
}

// Procedures

// Initialization and interaction with the OS.
init: proc(validation := true, loc := #caller_location) -> bool : _init
cleanup: proc(loc := #caller_location) : _cleanup
wait_idle: proc() : _wait_idle
// Can be called for recreation. Automatically destroyed by cleanup()
swapchain_create: proc(surface: vk.SurfaceKHR, init_size: [2]u32, frames_in_flight: u32, present_mode: Present_Mode = {}) : _swapchain_create
swapchain_resize: proc(size: [2]u32) : _swapchain_resize  // NOTE: Do not call this every frame! Only if the dimensions change.
// Blocks CPU until at least one frame is available.
// NOTE: This can return a nil texture because of OS quirks!
swapchain_acquire_next: proc(loc := #caller_location) -> Texture : _swapchain_acquire_next
swapchain_present: proc(queue: Queue, sem_wait: Semaphore, wait_value: u64, loc := #caller_location) : _swapchain_present
features_available: proc() -> Features : _features_available
device_limits: proc() -> Device_Limits : _device_limits

// Memory
gpuptr :: struct { ptr: rawptr, _impl: [2]u64 }
ptr :: struct { cpu: rawptr, using gpu: gpuptr }
null :: gpuptr {}
mem_alloc_raw: proc(#any_int el_size, #any_int el_count, #any_int align: i64, mem_type := Memory.Default, loc := #caller_location) -> ptr : _mem_alloc_raw
mem_suballoc: proc(addr: ptr, offset, el_size, el_count: i64, loc := #caller_location) -> ptr : _mem_suballoc
mem_free_raw: proc(addr: gpuptr, loc := #caller_location) : _mem_free_raw

// Textures
texture_size_and_align: proc(desc: Texture_Desc, loc := #caller_location) -> (size: u64, align: u64) : _texture_size_and_align
texture_create: proc(desc: Texture_Desc, storage: gpuptr, queue: Queue = nil, signal_sem: Semaphore = {}, signal_value: u64 = 0, name := "", loc := #caller_location) -> Texture : _texture_create
texture_destroy: proc(texture: Texture, loc := #caller_location) : _texture_destroy

// Descriptors
desc_heap_create: proc(texture_count: u32 = 65536, texture_rw_count: u32 = 65536, sampler_count: u32 = 32, bvh_count: u32 = 16, name := "", loc := #caller_location) -> Descriptor_Heap : _desc_heap_create
desc_heap_destroy: proc(heap: Descriptor_Heap, loc := #caller_location) : _desc_heap_destroy
desc_heap_set_textures: proc(heap: Descriptor_Heap, start_idx: u32, textures: []Texture_Descriptor, loc := #caller_location) : _desc_heap_set_textures
desc_heap_set_textures_rw: proc(heap: Descriptor_Heap, start_idx: u32, textures: []Texture_Descriptor, loc := #caller_location) : _desc_heap_set_textures_rw
desc_heap_set_samplers : proc(heap: Descriptor_Heap, start_idx: u32, samplers: []Sampler_Descriptor, loc := #caller_location) : _desc_heap_set_samplers
desc_heap_set_bvhs: proc(heap: Descriptor_Heap, start_idx: u32, bvhs: []BVH, loc := #caller_location) : _desc_heap_set_bvhs
texture_view_descriptor: proc(texture: Texture, view_desc: Texture_View_Desc, loc := #caller_location) -> Texture_Descriptor : _texture_descriptor
texture_rw_view_descriptor: proc(texture: Texture, view_desc: Texture_View_Desc, loc := #caller_location) -> Texture_Descriptor : _texture_rw_descriptor
sampler_descriptor: proc(sampler_desc: Sampler_Desc, loc := #caller_location) -> Sampler_Descriptor : _sampler_descriptor

// Shaders
shader_create: proc(code: []u32, type: Shader_Type_Graphics, entry_point_name := "main", name := "", spec_constants: []Spec_Constant = {}, loc := #caller_location) -> Shader : _shader_create
shader_create_compute: proc(code: []u32, group_size_x: u32, group_size_y: u32 = 1, group_size_z: u32 = 1, entry_point_name := "main", name := "", spec_constants: []Spec_Constant = {}, loc := #caller_location) -> Shader : _shader_create_compute
shader_destroy: proc(shader: Shader, loc := #caller_location) : _shader_destroy

// Semaphores
semaphore_create: proc(init_value: u64 = 0, name := "", loc := #caller_location) -> Semaphore : _semaphore_create
semaphore_get_value: proc(sem: Semaphore, loc := #caller_location) -> u64 : _semaphore_get_value
semaphore_wait: proc(sem: Semaphore, wait_value: u64, loc := #caller_location) : _semaphore_wait
semaphore_destroy: proc(sem: Semaphore, loc := #caller_location) : _semaphore_destroy

// Queues
queue_wait_idle: proc(queue: Queue) : _queue_wait_idle
queue_submit: proc(queue: Queue, cmd_bufs: []Command_Buffer, loc := #caller_location) : _queue_submit

// Raytracing
blas_size_and_align: proc(desc: BLAS_Desc, loc := #caller_location) -> (size: u64, align: u64) : _blas_size_and_align
blas_create: proc(desc: BLAS_Desc, storage: gpuptr, name := "", loc := #caller_location) -> BVH : _blas_create
blas_build_scratch_buffer_size_and_align: proc(desc: BLAS_Desc, loc := #caller_location) -> (size: u64, align: u64) : _blas_build_scratch_buffer_size_and_align
tlas_size_and_align: proc(desc: TLAS_Desc, loc := #caller_location) -> (size: u64, align: u64) : _tlas_size_and_align
tlas_create: proc(desc: TLAS_Desc, storage: gpuptr, name := "", loc := #caller_location) -> BVH : _tlas_create
tlas_build_scratch_buffer_size_and_align: proc(desc: TLAS_Desc, loc := #caller_location) -> (size: u64, align: u64) : _tlas_build_scratch_buffer_size_and_align
bvh_size_and_align :: proc { blas_size_and_align, tlas_size_and_align }
bvh_create :: proc { blas_create, tlas_create }
bvh_build_scratch_buffer_size_and_align :: proc { blas_build_scratch_buffer_size_and_align, tlas_build_scratch_buffer_size_and_align }
bvh_root_ptr: proc(bvh: BVH, loc := #caller_location) -> rawptr : _bvh_root_ptr
bvh_destroy: proc(bvh: BVH, loc := #caller_location) : _bvh_destroy

// Command buffer
commands_begin: proc(queue: Queue, loc := #caller_location) -> Command_Buffer : _commands_begin

// Commands
cmd_mem_copy_raw: proc(cmd_buf: Command_Buffer, dst, src: gpuptr, #any_int bytes: i64, loc := #caller_location) : _cmd_mem_copy_raw
cmd_copy_to_texture: proc(cmd_buf: Command_Buffer, dst: Texture, src: gpuptr, region: Texture_Region = {}, loc := #caller_location) : _cmd_copy_to_texture
cmd_copy_from_texture: proc(cmd_buf: Command_Buffer, dst: gpuptr, src: Texture, region: Texture_Region = {}, loc := #caller_location) : _cmd_copy_from_texture
cmd_blit_texture: proc(cmd_buf: Command_Buffer, dst: Texture, dst_rect: Blit_Rect, src: Texture, src_rect: Blit_Rect, filter: Filter, loc := #caller_location) : _cmd_blit_texture

cmd_set_desc_heap: proc(cmd_buf: Command_Buffer, heap: Descriptor_Heap, loc := #caller_location) : _cmd_set_desc_heap

cmd_add_wait_semaphore: proc(cmd_buf: Command_Buffer, sem: Semaphore, wait_value: u64, loc := #caller_location) : _cmd_add_wait_semaphore
cmd_add_signal_semaphore: proc(cmd_buf: Command_Buffer, sem: Semaphore, signal_value: u64, loc := #caller_location) : _cmd_add_signal_semaphore

cmd_barrier: proc(cmd_buf: Command_Buffer, before: Stage, after: Stage, hazards: Hazard_Flags = {}, loc := #caller_location) : _cmd_barrier

cmd_set_shaders: proc(cmd_buf: Command_Buffer, vert_shader: Shader, frag_shader: Shader, loc := #caller_location) : _cmd_set_shaders
cmd_set_compute_shader: proc(cmd_buf: Command_Buffer, compute_shader: Shader, loc := #caller_location) : _cmd_set_compute_shader
cmd_set_depth_state: proc(cmd_buf: Command_Buffer, state: Depth_State, loc := #caller_location) : _cmd_set_depth_state
cmd_set_raster_state: proc(cmd_buf: Command_Buffer, state: Raster_State, loc := #caller_location) : _cmd_set_raster_state
cmd_set_blend_state: proc(cmd_buf: Command_Buffer, state: Blend_State, loc := #caller_location) : _cmd_set_blend_state
cmd_set_viewport: proc(cmd_buf: Command_Buffer, viewport: Viewport, loc := #caller_location) : _cmd_set_viewport
cmd_set_scissor: proc(cmd_buf: Command_Buffer, scissor: Rect_2D, loc := #caller_location) : _cmd_set_scissor

cmd_dispatch: proc(cmd_buf: Command_Buffer, compute_data: gpuptr, num_groups_x: u32, num_groups_y: u32 = 1, num_groups_z: u32 = 1, loc := #caller_location) : _cmd_dispatch

// Schedule indirect compute shader based on number of groups, arguments is a pointer to a Dispatch_Indirect_Command struct
cmd_dispatch_indirect_raw: proc(cmd_buf: Command_Buffer, compute_data, arguments: gpuptr, loc := #caller_location) : _cmd_dispatch_indirect_raw

cmd_begin_render_pass: proc(cmd_buf: Command_Buffer, desc: Render_Pass_Desc, loc := #caller_location) : _cmd_begin_render_pass
cmd_end_render_pass: proc(cmd_buf: Command_Buffer, loc := #caller_location) : _cmd_end_render_pass

// Draw procedures:
// Vertex_data and fragment_data can be nil if not used in the currently bound shader
cmd_draw: proc(cmd_buf: Command_Buffer, vertex_data, fragment_data: gpuptr,
               vertex_count: u32, instance_count: u32 = 1, loc := #caller_location) : _cmd_draw
cmd_draw_indexed_raw: proc(cmd_buf: Command_Buffer, vertex_data, fragment_data, indices: gpuptr,
                           index_format: Index_Format, index_count: u32, instance_count: u32 = 1, loc := #caller_location) : _cmd_draw_indexed_raw
cmd_draw_indexed_indirect_raw: proc(cmd_buf: Command_Buffer, vertex_data, fragment_data, indices: gpuptr,
                                    index_format: Index_Format, indirect_arguments: gpuptr, loc := #caller_location) : _cmd_draw_indexed_indirect_raw
cmd_draw_indexed_indirect_multi_raw: proc(cmd_buf: Command_Buffer, vertex_data, fragment_data, indices: gpuptr,
                                          index_format: Index_Format, indirect_arguments: gpuptr, stride: u32, draw_count: gpuptr, loc := #caller_location) : _cmd_draw_indexed_indirect_multi_raw

cmd_build_blas: proc(cmd_buf: Command_Buffer, bvh: BVH, scratch_storage: gpuptr, shapes: []BVH_Shape, loc := #caller_location) : _cmd_build_blas
cmd_build_tlas: proc(cmd_buf: Command_Buffer, bvh: BVH, scratch_storage: gpuptr, instances: gpuptr, loc := #caller_location) : _cmd_build_tlas

// Debug utilities
cmd_begin_debug_label: proc(cmd_buf: Command_Buffer, name: string, color: [4]f32, loc := #caller_location) : _cmd_begin_debug_label
cmd_end_debug_label: proc(cmd_buf: Command_Buffer, loc := #caller_location) : _cmd_end_debug_label
// Shows up as a single event in the debugger
cmd_insert_debug_label: proc(cmd_buf: Command_Buffer, name: string, color: [4]f32, loc := #caller_location) : _cmd_insert_debug_label

/////////////////////////
// Userland Utilities

// Pointer
ptr_advance :: proc(addr: ptr, #any_int offset: i64) -> ptr
{
    res := addr
    if res.cpu != nil { res.cpu = rawptr(uintptr(res.cpu) + uintptr(offset)) }
    res.gpu.ptr = rawptr(uintptr(res.gpu.ptr) + uintptr(offset))
    return res
}

// Slice
// end == -1 means "until the end"
subslice :: #force_inline proc(s: slice_t($T), #any_int start: i64, #any_int end: i64 = -1) -> slice_t(T)
{
    end_clean := end if end != -1 else i64(len(s.cpu))
    assert(start >= 0)
    assert(start < i64(len(s.cpu)))
    assert(end_clean >= 0)
    assert(end_clean <= i64(len(s.cpu)))
    res := s
    res.cpu = res.cpu[start:end_clean]
    res.gpu.ptr = rawptr(uintptr(res.gpu.ptr) + uintptr(start * size_of(T)))
    return res
}

slice_len :: #force_inline proc(s: slice_t($T)) -> i64
{
    return i64(len(s.cpu))
}

slice_to_ptr :: #force_inline proc(s: slice_t($T)) -> ptr_t(T)
{
    return {
        cpu = raw_data(s.cpu),
        gpu = s.gpu,
    }
}

// Type-safe variants of raw procedures
cmd_draw_indexed :: #force_inline proc(cmd_buf: Command_Buffer, vertex_data, fragment_data: gpuptr, indices: slice_t($T),
                                       instance_count: u32 = 1, loc := #caller_location)
{
    #assert(T == u32 || T == u16)
    idx_fmt: Index_Format = .U32 when T == u32 else .U16
    cmd_draw_indexed_raw(cmd_buf, vertex_data, fragment_data, indices, idx_fmt, u32(slice_len(indices)), instance_count, loc)
}

cmd_dispatch_indirect :: #force_inline proc(cmd_buf: Command_Buffer, compute_data: gpuptr,
                                            arguments: ptr_t(Dispatch_Indirect_Command), loc := #caller_location)
{
    cmd_dispatch_indirect_raw(cmd_buf, compute_data, arguments, loc)
}

cmd_draw_indexed_indirect :: #force_inline proc(cmd_buf: Command_Buffer, vertex_data, fragment_data: gpuptr, indices: slice_t($T),
                                                indirect_arguments: ptr_t($T2), loc := #caller_location)
{
    #assert(T == u32 || T == u16)
    idx_fmt: Index_Format = .U32 when T == u32 else .U16
    cmd_draw_indexed_indirect_raw(cmd_buf, vertex_data, fragment_data, indices, idx_fmt, indirect_arguments, loc)
}

cmd_draw_indexed_indirect_multi :: #force_inline proc(cmd_buf: Command_Buffer, vertex_data, fragment_data: gpuptr, indices: slice_t($T),
                                                      indirect_arguments: slice_t($T2), draw_count: ptr_t(u32), loc := #caller_location)
{
    #assert(T == u32 || T == u16)
    idx_fmt: Index_Format = .U32 when T == u32 else .U16
    cmd_draw_indexed_indirect_multi_raw(cmd_buf, vertex_data, fragment_data, indices, idx_fmt, indirect_arguments, size_of(T2), draw_count, loc)
}

// Memory

ptr_t :: struct($T: typeid)
{
    cpu: ^T,
    using gpu: gpuptr,
}

slice_t :: struct($T: typeid)
{
    cpu: []T,
    using gpu: gpuptr,
}

mem_alloc_ptr :: #force_inline proc($T: typeid, mem_type := Memory.Default, loc := #caller_location) -> ptr_t(T)
{
    p := mem_alloc_raw(size_of(T), 1, align_of(T), mem_type = mem_type, loc = loc)
    return ptr_t(T) {
        cpu = cast(^T) p.cpu,
        gpu = p.gpu
    }
}

mem_alloc_slice :: #force_inline proc($T: typeid, #any_int count: i32, mem_type := Memory.Default, loc := #caller_location) -> slice_t(T)
{
    p := mem_alloc_raw(size_of(T), count, align_of(T), mem_type = mem_type, loc = loc)
    return slice_t(T) {
        cpu = slice.from_ptr(cast(^T)p.cpu, int(count)),
        gpu = p.gpu
    }
}

mem_alloc :: proc {
    mem_alloc_ptr,
    mem_alloc_slice,
}

mem_free_ptr :: #force_inline proc(addr: ptr_t($T), loc := #caller_location)
{
    mem_free_raw(addr.gpu, loc = loc)
}

mem_free_slice :: #force_inline proc(addr: slice_t($T), loc := #caller_location)
{
    mem_free_raw(addr.gpu, loc = loc)
}

mem_free :: proc {
    mem_free_ptr,
    mem_free_slice,
}

cmd_mem_copy_ptr :: #force_inline proc(cmd_buf: Command_Buffer, dst: ptr_t($T), src: ptr_t(T), loc := #caller_location)
{
    cmd_mem_copy_raw(cmd_buf, dst.gpu, src.gpu, size_of(T), loc = loc)
}

cmd_mem_copy_slice :: proc(cmd_buf: Command_Buffer, dst: slice_t($T), src: slice_t(T), loc := #caller_location)
{
    cmd_mem_copy_raw(cmd_buf, dst.gpu, src.gpu, size_of(T) * min(slice_len(dst), slice_len(src)), loc = loc)
}

cmd_mem_copy :: proc {
    cmd_mem_copy_ptr,
    cmd_mem_copy_slice,
}

// Simple linear allocator. Not thread-safe, as it is meant for
// temporary, thread-local allocations (e.g. staging buffers).
Arena :: struct
{
    block_size: i64,
    mem_type: Memory,

    offset: i64,
    block_idx: i64,
    blocks: [dynamic]Arena_Block,
}

@(private="file")
Arena_Block :: struct
{
    p: ptr,
    size: i64,
}

arena_create :: proc(#any_int block_size: i64 = 4*1024*1024, mem_type := Memory.Default, loc := #caller_location) -> Arena
{
    assert(block_size > 0, "block_size must be positive")

    res: Arena
    res.block_size = block_size
    res.mem_type = mem_type
    first_block := Arena_Block {
        p = mem_alloc_raw(block_size, 1, 16, mem_type = mem_type, loc = loc),
        size = block_size,
    }
    append(&res.blocks, first_block)
    return res
}

arena_alloc_raw :: proc(arena: ^Arena, #any_int el_size: i64, #any_int el_count: i64, #any_int align: i32 = 16) -> ptr
{
    assert(arena.block_size > 0, "Arena is not initialized! Did you call arena_create()?")

    bytes := el_size * el_count
    assert(bytes >= 0 && align > 0)

    align_cleaned := max(16, align)

    if bytes == 0 do return {}

    block := arena.blocks[arena.block_idx]

    // If we request an alignment of > 16 and cpu/gpu are only aligned to 16,
    // it's impossible to find the same offset for both.
    if block.p.cpu != nil && uintptr(block.p.cpu) % uintptr(align_cleaned) != uintptr(block.p.gpu.ptr) % uintptr(align_cleaned) {
        panic("Could not satisfy alignment requirements in GPU arena allocation.")
    }

    gpu_addr := uintptr(block.p.gpu.ptr) + uintptr(arena.offset)
    arena.offset = i64(align_up(u64(gpu_addr), u64(align_cleaned)) - u64(uintptr(block.p.gpu.ptr)))
    if arena.offset + bytes > block.size {
        block = arena_next_block(arena, bytes, align_cleaned)
        arena.offset = 0
    }

    suballoc_ptr := mem_suballoc(block.p, arena.offset, el_size, el_count)
    arena.offset += bytes

    return suballoc_ptr

    arena_next_block :: proc(arena: ^Arena, bytes: i64, align: i32) -> Arena_Block
    {
        arena.block_idx += 1
        arena.offset = 0
        if arena.block_idx >= i64(len(arena.blocks))
        {
            new_size := max(arena.block_size, bytes)
            new_p := mem_alloc_raw(new_size, 1, align, mem_type = arena.mem_type)
            new_block := Arena_Block { p = new_p, size = new_size }
            append(&arena.blocks, new_block)
            return new_block
        }
        else
        {
            if arena.blocks[arena.block_idx].size >= bytes
            {
                return arena.blocks[arena.block_idx]
            }
            else
            {
                mem_free_raw(arena.blocks[arena.block_idx].p.gpu)
                new_size := max(arena.block_size, bytes)
                new_p := mem_alloc_raw(new_size, 1, align, mem_type = arena.mem_type)
                new_block := Arena_Block { p = new_p, size = new_size }
                arena.blocks[arena.block_idx] = new_block
                return new_block
            }
        }
    }
}

arena_alloc_ptr :: #force_inline proc(arena: ^Arena, $T: typeid) -> ptr_t(T)
{
    return transmute(ptr_t(T)) arena_alloc_raw(arena, size_of(T), 1, align_of(T))
}

arena_alloc_slice :: #force_inline proc(arena: ^Arena, $T: typeid, #any_int count: i32) -> slice_t(T)
{
    p_raw := arena_alloc_raw(arena, size_of(T), count, align_of(T))
    return slice_t(T) {
        cpu = slice.from_ptr(cast(^T) p_raw.cpu, int(count)),
        gpu = p_raw.gpu
    }
}

arena_alloc :: proc {
    arena_alloc_ptr,
    arena_alloc_slice,
}

arena_free_all :: proc(arena: ^Arena)
{
    arena.offset = 0
    arena.block_idx = 0
}

arena_destroy :: proc(arena: ^Arena, loc := #caller_location)
{
    for block in arena.blocks {
        mem_free_raw(block.p.gpu, loc = loc)
    }
    delete(arena.blocks)
    arena^ = {}
}

Owned_Texture :: struct
{
    using tex: Texture,
    mem: gpuptr,
}

texture_alloc_and_create :: proc(desc: Texture_Desc, queue: Queue = nil, signal_sem: Semaphore = {}, signal_value: u64 = 0, name := "", loc := #caller_location) -> Owned_Texture
{
    size, align := texture_size_and_align(desc, loc = loc)
    ptr := mem_alloc_raw(size, 1, align, .GPU, loc = loc)
    texture := texture_create(desc, ptr, queue, signal_sem, signal_value, name = name, loc = loc)
    return Owned_Texture { texture, ptr.gpu }
}

texture_free_and_destroy :: proc(texture: ^Owned_Texture, loc := #caller_location)
{
    texture_destroy(texture, loc = loc)
    mem_free_raw(texture.mem, loc = loc)
    texture^ = {}
}

Owned_BVH :: struct
{
    using handle: BVH,
    mem: gpuptr,
}

blas_alloc_and_create :: proc(desc: BLAS_Desc, loc := #caller_location) -> Owned_BVH
{
    size, align := bvh_size_and_align(desc, loc = loc)
    ptr := mem_alloc_raw(size, 1, align, .GPU, loc = loc)
    bvh := bvh_create(desc, ptr, loc = loc)
    return Owned_BVH { bvh, ptr }
}

tlas_alloc_and_create :: proc(desc: TLAS_Desc, loc := #caller_location) -> Owned_BVH
{
    size, align := bvh_size_and_align(desc, loc = loc)
    ptr := mem_alloc_raw(size, 1, align, .GPU, loc = loc)
    bvh := bvh_create(desc, ptr, loc = loc)
    return Owned_BVH { bvh, ptr }
}

bvh_alloc_and_create :: proc { blas_alloc_and_create, tlas_alloc_and_create }

bvh_free_and_destroy :: proc(bvh: ^Owned_BVH, loc := #caller_location)
{
    bvh_destroy(bvh, loc = loc)
    mem_free_raw(bvh.mem, loc = loc)
    bvh^ = {}
}

blas_alloc_build_scratch_buffer :: proc(arena: ^Arena, desc: BLAS_Desc, loc := #caller_location) -> ptr
{
    size, align := blas_build_scratch_buffer_size_and_align(desc, loc = loc)
    return arena_alloc_raw(arena, size, 1, align)
}

tlas_alloc_build_scratch_buffer :: proc(arena: ^Arena, desc: TLAS_Desc, loc := #caller_location) -> ptr
{
    size, align := tlas_build_scratch_buffer_size_and_align(desc, loc = loc)
    return arena_alloc_raw(arena, size, 1, align)
}

bvh_alloc_build_scratch_buffer :: proc { blas_alloc_build_scratch_buffer, tlas_alloc_build_scratch_buffer }

// Swapchain utils

swapchain_create_from_sdl :: proc(window: ^sdl.Window, frames_in_flight: u32, present_mode: Present_Mode = {})
{
    vk_surface: vk.SurfaceKHR
    ok := sdl.Vulkan_CreateSurface(window, vk_get_instance(), nil, &vk_surface)
    ensure(ok, "Could not create surface.")

    window_size_x: i32
    window_size_y: i32
    sdl.GetWindowSize(window, &window_size_x, &window_size_y)
    swapchain_create(vk_surface, { u32(max(0, window_size_x)), u32(max(0, window_size_y)) }, frames_in_flight, present_mode)
}

// Texture utils

cmd_generate_mipmaps :: proc(cmd_buf: Command_Buffer, texture: Texture)
{
    for mip in 1..<texture.mip_count
    {
        if mip > 1 {
            cmd_barrier(cmd_buf, .Transfer, .Transfer)
        }

        src := Blit_Rect { mip_level = mip - 1 }
        dst := Blit_Rect { mip_level = mip }
        cmd_blit_texture(cmd_buf, texture, dst, texture, src, .Linear)
    }
}

// Scoped procs

@(private="file")
Scoped_Render_Pass_Out :: struct
{
    cmd_buf: Command_Buffer,
    loc: runtime.Source_Code_Location,
}

@(deferred_out = cmd_scoped_render_pass_end)
cmd_scoped_render_pass :: #force_inline proc(cmd_buf: Command_Buffer, desc: Render_Pass_Desc, loc := #caller_location) -> Scoped_Render_Pass_Out
{
    cmd_begin_render_pass(cmd_buf, desc, loc)
    return { cmd_buf, loc }
}

@(private="file")
cmd_scoped_render_pass_end :: #force_inline proc(scope_out: Scoped_Render_Pass_Out)
{
    cmd_end_render_pass(scope_out.cmd_buf, scope_out.loc)
}

@(private="file")
Scoped_Debug_Label_Out :: struct
{
    cmd_buf: Command_Buffer,
    loc: runtime.Source_Code_Location,
}

@(deferred_out = cmd_scoped_debug_label_end)
cmd_scoped_debug_label :: #force_inline proc(cmd_buf: Command_Buffer, name: string, color: [4]f32, loc := #caller_location) -> Scoped_Debug_Label_Out
{
    cmd_begin_debug_label(cmd_buf, name, color, loc)
    return { cmd_buf, loc }
}

@(private="file")
cmd_scoped_debug_label_end :: #force_inline proc(scope_out: Scoped_Debug_Label_Out)
{
    cmd_end_debug_label(scope_out.cmd_buf, scope_out.loc)
}

// Descriptors

@(private="file")
Descriptor_Pool_Freelist :: struct
{
    el_count: u8,
    free: [dynamic]u32,
}

@(private="file")
Descriptor_Pool_Resource :: struct($T: typeid)
{
    res_count: u32,  // Current number of allocated descriptors in addr.
    res_capacity: u32,
    lock: sync.Atomic_Mutex,
    freelists: [dynamic]Descriptor_Pool_Freelist,  // One freelist per allocation size.
    alloc_size: [dynamic]u8,  // byte i contains the number of descriptors for allocation of index i.
    default_res: T,
}

// Simple allocator of descriptor indices. Thread-safe.
Descriptor_Pool :: struct
{
    using heap: Descriptor_Heap,
    texture_pool: Descriptor_Pool_Resource(Texture_Descriptor),
    texture_rw_pool: Descriptor_Pool_Resource(Texture_Descriptor),
    sampler_pool: Descriptor_Pool_Resource(Sampler_Descriptor),
    bvh_pool: Descriptor_Pool_Resource(BVH),
}

// NOTE: There can be fragmentation so make sure you reserve more
// slots than are actually needed. Most of the time a single global
// descriptor pool is good enough and for that, these defaults are
// fairly reasonable.
desc_pool_create :: proc(texture_count: u32 = 65536,
                         texture_rw_count: u32 = 65536,
                         sampler_count: u32 = 32,
                         bvh_count: u32 = 16,
                         loc := #caller_location) -> Descriptor_Pool
{
    res: Descriptor_Pool
    res.texture_pool = desc_pool_resource_init(i64(texture_count), Texture_Descriptor)
    res.sampler_pool = desc_pool_resource_init(i64(sampler_count), Sampler_Descriptor)
    res.texture_rw_pool = desc_pool_resource_init(i64(texture_rw_count), Texture_Descriptor)
    res.bvh_pool = desc_pool_resource_init(i64(bvh_count), BVH)
    res.heap = desc_heap_create(texture_count, texture_rw_count, sampler_count, bvh_count, loc = loc)
    return res
}

desc_pool_destroy :: proc(pool: ^Descriptor_Pool, loc := #caller_location)
{
    desc_pool_resource_destroy(&pool.texture_pool)
    desc_pool_resource_destroy(&pool.texture_rw_pool)
    desc_pool_resource_destroy(&pool.sampler_pool)
    desc_pool_resource_destroy(&pool.bvh_pool)
    desc_heap_destroy(pool.heap, loc = loc)
    pool^ = {}
}

desc_pool_free_textures :: #force_inline proc(pool: ^Descriptor_Pool, idx: u32) {
    desc_pool_resource_free(&pool.texture_pool, idx)
}
desc_pool_free_textures_rw :: #force_inline proc(pool: ^Descriptor_Pool, idx: u32) {
    desc_pool_resource_free(&pool.texture_rw_pool, idx)
}
desc_pool_free_samplers :: #force_inline proc(pool: ^Descriptor_Pool, idx: u32) {
    desc_pool_resource_free(&pool.sampler_pool, idx)
}
desc_pool_free_bvhs :: #force_inline proc(pool: ^Descriptor_Pool, idx: u32) {
    desc_pool_resource_free(&pool.bvh_pool, idx)
}

desc_pool_free_all :: proc(pool: ^Descriptor_Pool)
{
    desc_pool_resource_free_all(&pool.texture_pool)
    desc_pool_resource_free_all(&pool.texture_rw_pool)
    desc_pool_resource_free_all(&pool.sampler_pool)
    desc_pool_resource_free_all(&pool.bvh_pool)
}

desc_pool_alloc_texture :: proc(pool: ^Descriptor_Pool, texture: Texture_Descriptor) -> u32 {
    return desc_pool_alloc_textures(pool, { texture })
}
desc_pool_alloc_texture_rw :: proc(pool: ^Descriptor_Pool, texture: Texture_Descriptor) -> u32 {
    return desc_pool_alloc_textures_rw(pool, { texture })
}
desc_pool_alloc_sampler :: proc(pool: ^Descriptor_Pool, sampler: Sampler_Descriptor) -> u32 {
    return desc_pool_alloc_samplers(pool, { sampler })
}
desc_pool_alloc_bvh :: proc(pool: ^Descriptor_Pool, bvh: BVH) -> u32 {
    return desc_pool_alloc_bvhs(pool, { bvh })
}

// Passing multiple descriptors to desc_pool_alloc_X is useful for contiguous descriptors.
// One usecase for this is to group descriptors into contiguous sets. This enables grouping
// based on update frequency and so on. In the shader you can store a single index and then
// do something like:
// texture_sample(material_base_id + 0, ...);
// texture_sample(material_base_id + 1, ...);
// texture_sample(material_base_id + 2, ...);
desc_pool_alloc_textures :: proc(pool: ^Descriptor_Pool, textures: []Texture_Descriptor) -> u32
{
    assert(len(textures) <= int(max(u8)))
    idx := desc_pool_resource_alloc(&pool.texture_pool, i64(len(textures)))
    desc_heap_set_textures(pool.heap, idx, textures)
    return idx
}

desc_pool_alloc_textures_rw :: proc(pool: ^Descriptor_Pool, textures_rw: []Texture_Descriptor) -> u32
{
    assert(len(textures_rw) <= int(max(u8)))
    idx := desc_pool_resource_alloc(&pool.texture_rw_pool, i64(len(textures_rw)))
    desc_heap_set_textures_rw(pool.heap, idx, textures_rw)
    return idx
}

desc_pool_alloc_samplers :: proc(pool: ^Descriptor_Pool, samplers: []Sampler_Descriptor) -> u32
{
    assert(len(samplers) <= int(max(u8)))
    idx := desc_pool_resource_alloc(&pool.sampler_pool, i64(len(samplers)))
    desc_heap_set_samplers(pool.heap, idx, samplers)
    return idx
}

desc_pool_alloc_bvhs :: proc(pool: ^Descriptor_Pool, bvhs: []BVH) -> u32
{
    assert(len(bvhs) <= int(max(u8)))
    idx := desc_pool_resource_alloc(&pool.bvh_pool, i64(len(bvhs)))
    desc_heap_set_bvhs(pool.heap, idx, bvhs)
    return idx
}

@(private="file")
desc_pool_resource_init :: proc(res_count: i64, $T: typeid) -> Descriptor_Pool_Resource(T)
{
    res: Descriptor_Pool_Resource(T)
    res.res_count = 0
    res.res_capacity = u32(res_count)
    return res
}

@(private="file")
desc_pool_resource_alloc :: proc(pool: ^Descriptor_Pool_Resource($T), count: i64) -> u32
{
    assert(count > 0)
    assert(count <= i64(max(u8)))
    assert(count <= 16, "Descriptor_Pool is built for small allocation sizes.")
    sync.guard(&pool.lock)

    found: ^Descriptor_Pool_Freelist
    for &freelist in pool.freelists
    {
        if len(freelist.free) <= 0 do continue

        if i64(freelist.el_count) == count {
            found = &freelist
            break
        }
    }

    if found != nil
    {
        free_slot := pop(&found.free)
        pool.alloc_size[free_slot] = u8(count)
        return free_slot
    }
    else
    {
        assert(pool.res_count + u32(count) < pool.res_capacity)
        free_slot := pool.res_count
        pool.res_count += u32(count)
        resize(&pool.alloc_size, pool.res_count)
        pool.alloc_size[free_slot] = u8(count)
        return free_slot
    }
}

@(private="file")
desc_pool_resource_free :: proc(pool: ^Descriptor_Pool_Resource($T), idx: u32)
{
    sync.guard(&pool.lock)

    count := pool.alloc_size[idx]

    found: ^Descriptor_Pool_Freelist
    for &freelist in pool.freelists
    {
        if len(freelist.free) <= 0 do continue

        if freelist.el_count == count {
            found = &freelist
            break
        }
    }

    if found == nil
    {
        append(&pool.freelists, Descriptor_Pool_Freelist {
            el_count = count,
            free = {},
        })

        found = &pool.freelists[len(pool.freelists)-1]
    }

    append(&found.free, idx)
}

@(private="file")
desc_pool_resource_free_all :: proc(pool: ^Descriptor_Pool_Resource($T))
{
    for &freelist in pool.freelists do delete(freelist.free)
    delete(pool.freelists)
    pool.res_count = 0
}

@(private="file")
desc_pool_resource_destroy :: proc(pool: ^Descriptor_Pool_Resource($T))
{
    desc_pool_resource_free_all(pool)
}
