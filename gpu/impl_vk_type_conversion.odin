
#+private
package gpu

import vk "vendor:vulkan"
import "base:runtime"

to_vk_shader_stage :: #force_inline proc(type: Shader_Type_Graphics) -> vk.ShaderStageFlags
{
    switch type
    {
        case .Vertex: return { .VERTEX }
        case .Fragment: return { .FRAGMENT }
    }
    return {}
}

to_vk_stage :: #force_inline proc(stage: Stage) -> vk.PipelineStageFlags
{
    switch stage
    {
        case .Transfer: return { .TRANSFER }
        case .Compute: return { .COMPUTE_SHADER }
        case .Raster_Color_Out: return { .COLOR_ATTACHMENT_OUTPUT }
        case .Fragment_Shader: return { .FRAGMENT_SHADER }
        case .Vertex_Shader: return { .VERTEX_SHADER }
        case .Build_BVH: return { .ACCELERATION_STRUCTURE_BUILD_KHR }
        case .All: return { .ALL_COMMANDS }
    }
    return {}
}

to_vk_load_op :: #force_inline proc(load_op: Load_Op) -> vk.AttachmentLoadOp
{
    switch load_op
    {
        case .Clear: return .CLEAR
        case .Load: return .LOAD
        case .Dont_Care: return .DONT_CARE
    }
    return {}
}

to_vk_store_op :: #force_inline proc(store_op: Store_Op) -> (vk.AttachmentStoreOp, vk.ResolveModeFlags)
{
    switch store_op
    {
        case .Store:             return .STORE,     {}
        case .Dont_Care:         return .DONT_CARE, {}
        case .Resolve:           return .DONT_CARE, { .AVERAGE }
        case .Resolve_And_Store: return .STORE,     { .AVERAGE }
    }
    return {}, {}
}

to_vk_compare_op :: #force_inline proc(compare_op: Compare_Op) -> vk.CompareOp
{
    switch compare_op
    {
        case .Never: return .NEVER
        case .Less: return .LESS
        case .Equal: return .EQUAL
        case .Less_Equal: return .LESS_OR_EQUAL
        case .Greater: return .GREATER
        case .Not_Equal: return .NOT_EQUAL
        case .Greater_Equal: return .GREATER_OR_EQUAL
        case .Always: return .ALWAYS
    }
    return {}
}

to_vk_texture_type :: #force_inline proc(type: Texture_Type) -> vk.ImageType
{
    switch type
    {
        case .Default: return .D2
        case .D2: return .D2
        case .D3: return .D3
        case .D1: return .D1
        case .Cube: return .D2
        case .D2_Array: return .D2
        case .D1_Array: return .D1
        case .Cube_Array: return .D2
    }
    return {}
}

to_vk_texture_view_type :: #force_inline proc(type: Texture_Type) -> vk.ImageViewType
{
    switch type
    {
        case .Default: panic("Implementation bug!")
        case .D2: return .D2
        case .D3: return .D3
        case .D1: return .D1
        case .Cube: return .CUBE
        case .D2_Array: return .D2_ARRAY
        case .D1_Array: return .D1_ARRAY
        case .Cube_Array: return .CUBE_ARRAY
    }
    return {}
}

to_vk_texture_format :: proc(format: Texture_Format) -> vk.Format
{
    switch format
    {
        case .Default: panic("Implementation bug!")
        case .R8_Unorm: return .R8_UNORM
        case .RG8_Unorm: return .R8G8_UNORM
        case .RGBA8_Unorm: return .R8G8B8A8_UNORM
        case .ABGR8_Unorm: return .A8B8G8R8_UNORM_PACK32
        case .BGRA8_Unorm: return .B8G8R8A8_UNORM
        case .R8_SRGB: return .R8_SRGB
        case .RG8_SRGB: return .R8G8_SRGB
        case .RGBA8_SRGB: return .R8G8B8A8_SRGB
        case .ABGR8_SRGB: return .A8B8G8R8_SRGB_PACK32
        case .BGRA8_SRGB: return .B8G8R8A8_SRGB
        case .R16_Unorm: return .R16_UNORM
        case .RG16_Unorm: return .R16G16_UNORM
        case .RGBA16_Unorm: return .R16G16B16A16_UNORM
        case .D16_Unorm: return .D16_UNORM
        case .D16_Unorm_S8_Uint: return .D16_UNORM_S8_UINT
        case .D24_Unorm_Pack32: return .X8_D24_UNORM_PACK32
        case .D24_Unorm_S8_Uint: return .D24_UNORM_S8_UINT
        case .D32_Float: return .D32_SFLOAT
        case .R16_Float: return .R16_SFLOAT
        case .RG16_Float: return .R16G16_SFLOAT
        case .RGBA16_Float: return .R16G16B16A16_SFLOAT
        case .R32_Float: return .R32_SFLOAT
        case .RG32_Float: return .R32G32_SFLOAT
        case .RGBA32_Float: return .R32G32B32A32_SFLOAT
        case .BC1_RGBA_Unorm: return .BC1_RGBA_UNORM_BLOCK
        case .BC3_RGBA_Unorm: return .BC3_UNORM_BLOCK
        case .BC4_R_Unorm: return .BC4_UNORM_BLOCK
        case .BC5_RG_Unorm: return .BC5_UNORM_BLOCK
        case .BC6H_RGB_Float: return .BC6H_SFLOAT_BLOCK
        case .BC7_RGBA_Unorm: return .BC7_UNORM_BLOCK
        case .BC7_RGBA_SRGB: return .BC7_SRGB_BLOCK
        case .ASTC_4x4_RGBA_Unorm: return .ASTC_4x4_UNORM_BLOCK
        case .ETC2_RGB8_Unorm: return .ETC2_R8G8B8_UNORM_BLOCK
        case .ETC2_RGBA8_Unorm: return .ETC2_R8G8B8A8_UNORM_BLOCK
        case .EAC_R11_Unorm: return .EAC_R11_UNORM_BLOCK
        case .EAC_RG11_Unorm: return .EAC_R11G11_UNORM_BLOCK
    }
    return {}
}

to_vk_image_aspect_flags :: #force_inline proc(format: Texture_Format) -> vk.ImageAspectFlags {
    #partial switch format
    {
        case .Default: panic("Implementation bug!")
        case .D16_Unorm, .D16_Unorm_S8_Uint, .D24_Unorm_Pack32, .D24_Unorm_S8_Uint, .D32_Float:
            return { .DEPTH }
        case: return { .COLOR }
    }
}

to_vk_sample_count :: proc(sample_count: u32) -> vk.SampleCountFlags
{
    switch sample_count
    {
        case 0: return { ._1 }
        case 1: return { ._1 }
        case 2: return { ._2 }
        case 4: return { ._4 }
        case 8: return { ._8 }
        case: panic("Unsupported sample count.")
    }
    return {}
}

to_vk_texture_usage :: proc(usage: Usage_Flags) -> vk.ImageUsageFlags
{
    res: vk.ImageUsageFlags
    if .Sampled in usage do                  res += { .SAMPLED }
    if .Storage in usage do                  res += { .STORAGE }
    if .Color_Attachment in usage do         res += { .COLOR_ATTACHMENT }
    if .Depth_Stencil_Attachment in usage do res += { .DEPTH_STENCIL_ATTACHMENT }
    if .Transfer_Src in usage do             res += { .TRANSFER_SRC }
    return res
}

to_vk_filter :: proc(filter: Filter) -> vk.Filter
{
    switch filter
    {
        case .Linear: return .LINEAR
        case .Nearest: return .NEAREST
    }
    return {}
}

to_vk_mipmap_filter :: proc(filter: Filter) -> vk.SamplerMipmapMode
{
    switch filter
    {
        case .Linear: return .LINEAR
        case .Nearest: return .NEAREST
    }
    return {}
}

to_vk_address_mode :: proc(addr_mode: Address_Mode) -> vk.SamplerAddressMode
{
    switch addr_mode
    {
        case .Repeat: return .REPEAT
        case .Mirrored_Repeat: return .MIRRORED_REPEAT
        case .Clamp_To_Edge: return .CLAMP_TO_EDGE
    }
    return {}
}

to_vk_blas_desc :: proc(blas_desc: BLAS_Desc, arena: runtime.Allocator) -> vk.AccelerationStructureBuildGeometryInfoKHR
{
    geometries := make([]vk.AccelerationStructureGeometryKHR, len(blas_desc.shapes), allocator = arena)
    for &geom, i in geometries
    {
        switch shape in blas_desc.shapes[i]
        {
            case BVH_Mesh_Desc:
            {
                flags: vk.GeometryFlagsKHR = { .OPAQUE } if shape.opacity == .Fully_Opaque else {}
                geom = vk.AccelerationStructureGeometryKHR {
                    sType = .ACCELERATION_STRUCTURE_GEOMETRY_KHR,
                    flags = flags,
                    geometryType = .TRIANGLES,
                    geometry = { triangles = {
                        sType = .ACCELERATION_STRUCTURE_GEOMETRY_TRIANGLES_DATA_KHR,
                        vertexFormat = .R32G32B32_SFLOAT,
                        vertexData = {},
                        vertexStride = vk.DeviceSize(shape.vertex_stride),
                        maxVertex = shape.max_vertex,
                        indexType = .UINT32,
                        indexData = {},
                        transformData = {},
                    } }
                }
            }
            case BVH_AABB_Desc:
            {
                flags: vk.GeometryFlagsKHR = { .OPAQUE } if shape.opacity == .Fully_Opaque else {}
                geom = vk.AccelerationStructureGeometryKHR {
                    sType = .ACCELERATION_STRUCTURE_GEOMETRY_KHR,
                    flags = flags,
                    geometryType = .AABBS,
                    geometry = { aabbs = {
                        sType = .ACCELERATION_STRUCTURE_GEOMETRY_AABBS_DATA_KHR,
                        stride = vk.DeviceSize(shape.stride),
                        data = {},
                    } }
                }
            }
        }
    }

    return vk.AccelerationStructureBuildGeometryInfoKHR {
        sType = .ACCELERATION_STRUCTURE_BUILD_GEOMETRY_INFO_KHR,
        flags = to_vk_bvh_flags(blas_desc.hint, blas_desc.caps),
        type = .BOTTOM_LEVEL,
        mode = .BUILD,
        geometryCount = u32(len(geometries)),
        pGeometries = raw_data(geometries)
    }
}

to_vk_tlas_desc :: proc(tlas_desc: TLAS_Desc, arena: runtime.Allocator) -> vk.AccelerationStructureBuildGeometryInfoKHR
{
    geometry := new(vk.AccelerationStructureGeometryKHR)
    geometry^ = {
        sType = .ACCELERATION_STRUCTURE_GEOMETRY_KHR,
        geometryType = .INSTANCES,
        geometry = {
            instances = {
                sType = .ACCELERATION_STRUCTURE_GEOMETRY_INSTANCES_DATA_KHR,
                arrayOfPointers = false,
                data = {
                    // deviceAddress = vku.get_buffer_device_address(device, instances_buf)
                }
            }
        }
    }

    return vk.AccelerationStructureBuildGeometryInfoKHR {
        sType = .ACCELERATION_STRUCTURE_BUILD_GEOMETRY_INFO_KHR,
        flags = to_vk_bvh_flags(tlas_desc.hint, tlas_desc.caps),
        type = .TOP_LEVEL,
        mode = .BUILD,
        geometryCount = 1,
        pGeometries = geometry
    }
}

to_vk_bvh_flags :: proc(hint: BVH_Hint, caps: BVH_Capabilities) -> vk.BuildAccelerationStructureFlagsKHR
{
    flags: vk.BuildAccelerationStructureFlagsKHR
    if .Update in caps do            flags += { .ALLOW_UPDATE }
    if .Compaction in caps do        flags += { .ALLOW_COMPACTION }
    if hint == .Prefer_Fast_Trace do flags += { .PREFER_FAST_TRACE }
    if hint == .Prefer_Fast_Build do flags += { .PREFER_FAST_BUILD }
    if hint == .Prefer_Low_Memory do flags += { .LOW_MEMORY }

    return flags
}

to_vk_blend_op :: proc(op: Blend_Op) -> vk.BlendOp
{
    switch op
    {
        case .Add:          return .ADD
        case .Subtract:     return .SUBTRACT
        case .Rev_Subtract: return .REVERSE_SUBTRACT
        case .Min:          return .MIN
        case .Max:          return .MAX
    }
    return {}
}

to_vk_blend_factor :: proc(blend: Blend_Factor) -> vk.BlendFactor
{
    switch blend
    {
        case .Zero:      return .ZERO
        case .One:       return .ONE
        case .Src_Color: return .SRC_COLOR
        case .Dst_Color: return .DST_COLOR
        case .Src_Alpha: return .SRC_ALPHA
        case .Dst_Alpha: return .DST_ALPHA
        case .One_Minus_Src_Alpha: return .ONE_MINUS_SRC_ALPHA
        case .One_Minus_Src_Color: return .ONE_MINUS_SRC_COLOR
        case .One_Minus_Dst_Alpha: return .ONE_MINUS_DST_ALPHA
        case .One_Minus_Dst_Color: return .ONE_MINUS_DST_COLOR
    }
    return {}
}

to_vk_image_create_info :: proc(desc: Texture_Desc) -> vk.ImageCreateInfo
{
    return {
        sType = .IMAGE_CREATE_INFO,
        flags = to_vk_image_create_flags(desc.type),
        imageType = to_vk_texture_type(desc.type),
        format = to_vk_texture_format(desc.format),
        extent = vk.Extent3D { desc.dimensions.x, desc.dimensions.y, desc.dimensions.z },
        mipLevels = desc.mip_count,
        arrayLayers = desc.layer_count,
        samples = to_vk_sample_count(desc.sample_count),
        usage = to_vk_texture_usage(desc.usage) + { .TRANSFER_DST },
        initialLayout = .UNDEFINED,
    }
}

to_vk_image_create_flags :: proc(type: Texture_Type) -> vk.ImageCreateFlags
{
    flags: vk.ImageCreateFlags
    if type == .Cube || type == .Cube_Array do flags += { .CUBE_COMPATIBLE }
    return flags
}

to_vk_viewport :: proc(viewport: Viewport) -> vk.Viewport
{
    return {
        x = viewport.origin.x, y = viewport.origin.y,
        width = viewport.size.x, height = viewport.size.y,
        minDepth = viewport.depth_min, maxDepth = viewport.depth_max,
    }
}

to_vk_rect_2D :: proc(rect: Rect_2D) -> vk.Rect2D
{
    return {
        offset = { rect.offset.x, rect.offset.y },
        extent = { rect.size.x, rect.size.y },
    }
}

to_vk_topology :: #force_inline proc(topology: Topology) -> vk.PrimitiveTopology
{
    switch topology
    {
        case .Triangle_List:  return .TRIANGLE_LIST
        case .Triangle_Strip: return .TRIANGLE_STRIP
        case .Triangle_Fan:   return .TRIANGLE_FAN
    }
    return {}
}

to_vk_cull_mode :: #force_inline proc(cull_mode: Cull_Mode) -> vk.CullModeFlags
{
    // IMPORTANT NOTE: Assuming that CCW is front!
    switch cull_mode
    {
        case .Cull_CW:  return { .BACK }
        case .Cull_CCW: return { .FRONT }
        case .None:     return {}
        case .All:      return { .FRONT, .BACK }
    }
    return {}
}

to_vk_index_format :: #force_inline proc(index_format: Index_Format) -> vk.IndexType
{
    switch index_format
    {
        case .U32: return .UINT32
        case .U16: return .UINT16
    }
    return {}
}

to_vk_present_mode :: #force_inline proc(present_mode: Present_Mode, supported_present_modes: []vk.PresentModeKHR) -> vk.PresentModeKHR
{
    res: vk.PresentModeKHR
    switch present_mode
    {
        case .Auto_VSync:
        {
            res = .FIFO
            // Look for FifoRelaxed
            for candidate in supported_present_modes {
                if candidate == .FIFO_RELAXED {
                    res = candidate
                    break
                }
            }
        }
        case .Auto_No_VSync:
        {
            res = .FIFO
            // Look for mailbox
            for candidate in supported_present_modes {
                if candidate == .MAILBOX {
                    res = candidate
                    break
                }
            }
            // Look for immediate
            for candidate in supported_present_modes {
                if candidate == .IMMEDIATE {
                    res = candidate
                    break
                }
            }
        }
        case .Fifo:         res = .FIFO
        case .Fifo_Relaxed: res = .FIFO_RELAXED
        case .Mailbox:      res = .MAILBOX
        case .Immediate:    res = .IMMEDIATE
    }

    return res
}
