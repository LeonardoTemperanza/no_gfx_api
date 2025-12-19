
package gpu

import "core:slice"
import "core:log"
import "base:runtime"
import vmem "core:mem/virtual"
import "core:mem"
import rbt "core:container/rbtree"

import sdl "vendor:sdl3"
import vk "vendor:vulkan"

PUSH_CONSTANTS_SIZE :: size_of(rawptr) * 2

@(private="file")
GPU_Alloc_Meta :: struct #all_or_none
{
    mem_handle: vk.DeviceMemory,
    buf_handle: vk.Buffer,
    device_address: vk.DeviceAddress,
    align: u32,
}

@(private="file")
Alloc_Range :: struct
{
    ptr: u64,
    size: u32,
}

@(private="file")
Context :: struct
{
    instance: vk.Instance,
    debug_messenger: vk.DebugUtilsMessengerEXT,
    surface: vk.SurfaceKHR,

    gpu_allocs: [dynamic]GPU_Alloc_Meta,
    cpu_ptr_to_alloc: map[rawptr]u32,  // Each entry has an index to its corresponding GPU allocation
    gpu_ptr_to_alloc: map[rawptr]u32,  // From base GPU allocation pointer to metadata
    alloc_tree: rbt.Tree(Alloc_Range, u32),

    phys_device: vk.PhysicalDevice,
    device: vk.Device,
    queue: vk.Queue,
    queue_family_idx: u32,

    // TEMPORARY
    cmd_pool: vk.CommandPool,

    // Common resources
    common_pipeline_layout: vk.PipelineLayout,

    // Swapchain
    swapchain: Swapchain,
    swapchain_image_idx: u32,
}

// Initialization

@(private="file")
ctx: Context
@(private="file")
vk_logger: log.Logger

_init :: proc(window: ^sdl.Window)
{
    init_scratch_arenas()

    // Load vulkan function pointers
    vk.load_proc_addresses_global(cast(rawptr) sdl.Vulkan_GetVkGetInstanceProcAddr())

    vk_logger = context.logger

    // Create instance
    {
        when ODIN_DEBUG
        {
            layers := []cstring {
                "VK_LAYER_KHRONOS_validation",
            }
        }
        else
        {
            layers := []cstring {}
        }

        count: u32
        instance_extensions := sdl.Vulkan_GetInstanceExtensions(&count)
        extensions := slice.concatenate([][]cstring {
            instance_extensions[:count],
            {
                vk.EXT_DEBUG_UTILS_EXTENSION_NAME,
                vk.KHR_WIN32_SURFACE_EXTENSION_NAME,
            }
        }, context.temp_allocator)

        debug_messenger_ci := vk.DebugUtilsMessengerCreateInfoEXT {
            sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
            messageSeverity = { .WARNING, .ERROR },
            messageType = { .VALIDATION, .PERFORMANCE },
            pfnUserCallback = vk_debug_callback
        }

        when ODIN_DEBUG
        {
            validation_features := []vk.ValidationFeatureEnableEXT {
                //.GPU_ASSISTED,
                //.GPU_ASSISTED_RESERVE_BINDING_SLOT,
                .SYNCHRONIZATION_VALIDATION,
            }
        }
        else
        {
            validation_features := []vk.ValidationFeatureEnableEXT {}
        }

        next: rawptr
        next = &debug_messenger_ci
        next = &vk.ValidationFeaturesEXT {
            sType = .VALIDATION_FEATURES_EXT,
            pNext = next,
            enabledValidationFeatureCount = u32(len(validation_features)),
            pEnabledValidationFeatures = raw_data(validation_features),
        }

        vk_check(vk.CreateInstance(&{
            sType = .INSTANCE_CREATE_INFO,
            pApplicationInfo = &{
                sType = .APPLICATION_INFO,
                apiVersion = vk.API_VERSION_1_3,
            },
            enabledLayerCount = u32(len(layers)),
            ppEnabledLayerNames = raw_data(layers),
            enabledExtensionCount = u32(len(extensions)),
            ppEnabledExtensionNames = raw_data(extensions),
            pNext = next,
        }, nil, &ctx.instance))

        vk.load_proc_addresses_instance(ctx.instance)
        assert(vk.DestroyInstance != nil, "Failed to load Vulkan instance API")

        vk_check(vk.CreateDebugUtilsMessengerEXT(ctx.instance, &debug_messenger_ci, nil, &ctx.debug_messenger))
    }

    // Create surface
    {
        ok_s := sdl.Vulkan_CreateSurface(window, ctx.instance, nil, &ctx.surface)
        if !ok_s do fatal_error("Could not create vulkan surface.")
    }

    // Physical device
    phys_device_count: u32
    vk_check(vk.EnumeratePhysicalDevices(ctx.instance, &phys_device_count, nil))
    if phys_device_count == 0 do fatal_error("Did not find any GPUs!")
    phys_devices := make([]vk.PhysicalDevice, phys_device_count, context.temp_allocator)
    vk_check(vk.EnumeratePhysicalDevices(ctx.instance, &phys_device_count, raw_data(phys_devices)))

    chosen_phys_device: vk.PhysicalDevice
    queue_family_idx: u32
    found := false
    device_loop: for candidate in phys_devices
    {
        queue_family_count: u32
        vk.GetPhysicalDeviceQueueFamilyProperties(candidate, &queue_family_count, nil)
        queue_families := make([]vk.QueueFamilyProperties, queue_family_count, context.temp_allocator)
        vk.GetPhysicalDeviceQueueFamilyProperties(candidate, &queue_family_count, raw_data(queue_families))

        for family, i in queue_families
        {
            supports_graphics := .GRAPHICS in family.queueFlags
            supports_present: b32
            vk_check(vk.GetPhysicalDeviceSurfaceSupportKHR(candidate, u32(i), ctx.surface, &supports_present))

            if supports_graphics && supports_present
            {
                chosen_phys_device = candidate
                queue_family_idx = u32(i)
                found = true
                break device_loop
            }
        }
    }

    if !found do fatal_error("Could not find suitable GPU.")

    ctx.phys_device = chosen_phys_device

    queue_priorities := []f32 { 0.0, 1.0 }
    queue_create_infos := []vk.DeviceQueueCreateInfo {
        {
            sType = .DEVICE_QUEUE_CREATE_INFO,
            queueFamilyIndex = queue_family_idx,
            queueCount = u32(len(queue_priorities)),
            pQueuePriorities = raw_data(queue_priorities),
        },
    }

    // Device
    device_extensions := []cstring {
        vk.KHR_SWAPCHAIN_EXTENSION_NAME,
        vk.EXT_SHADER_OBJECT_EXTENSION_NAME,
        vk.KHR_ACCELERATION_STRUCTURE_EXTENSION_NAME,
        vk.KHR_RAY_TRACING_PIPELINE_EXTENSION_NAME,
        vk.KHR_DEFERRED_HOST_OPERATIONS_EXTENSION_NAME,
        vk.KHR_RAY_TRACING_POSITION_FETCH_EXTENSION_NAME,
        vk.KHR_EXTERNAL_MEMORY_WIN32_EXTENSION_NAME,
    }

    next: rawptr
    /*
    next = &vk.PhysicalDeviceMaintenance6Features {
        sType = .PHYSICAL_DEVICE_MAINTENANCE_6_FEATURES,
        pNext = next,
        maintenance6 = true,
    }
    */
    next = &vk.PhysicalDeviceVulkan12Features {
        sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
        pNext = next,
        runtimeDescriptorArray = true,
        shaderSampledImageArrayNonUniformIndexing = true,
        timelineSemaphore = true,
        bufferDeviceAddress = true,
    }
    next = &vk.PhysicalDeviceVulkan13Features {
        sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
        pNext = next,
        dynamicRendering = true,
        synchronization2 = true,
    }
    next = &vk.PhysicalDeviceShaderObjectFeaturesEXT {
        sType = .PHYSICAL_DEVICE_SHADER_OBJECT_FEATURES_EXT,
        pNext = next,
        shaderObject = true,
    }
    next = &vk.PhysicalDeviceDepthClipEnableFeaturesEXT {
        sType = .PHYSICAL_DEVICE_DEPTH_CLIP_ENABLE_FEATURES_EXT,
        pNext = next,
        depthClipEnable = true,
    }
    next = &vk.PhysicalDeviceAccelerationStructureFeaturesKHR {
        sType = .PHYSICAL_DEVICE_ACCELERATION_STRUCTURE_FEATURES_KHR,
        pNext = next,
        accelerationStructure = true,
    }
    next = &vk.PhysicalDeviceRayTracingPipelineFeaturesKHR {
        sType = .PHYSICAL_DEVICE_RAY_TRACING_PIPELINE_FEATURES_KHR,
        pNext = next,
        rayTracingPipeline = true,
    }
    next = &vk.PhysicalDeviceFeatures2 {
        sType = .PHYSICAL_DEVICE_FEATURES_2,
        pNext = next,
        features = {
            shaderInt64 = true,
        }
    }
    next = &vk.PhysicalDeviceRayTracingPositionFetchFeaturesKHR {
        sType = .PHYSICAL_DEVICE_RAY_TRACING_POSITION_FETCH_FEATURES_KHR,
        pNext = next,
        rayTracingPositionFetch = true,
    }

    device_ci := vk.DeviceCreateInfo {
        sType = .DEVICE_CREATE_INFO,
        pNext = next,
        queueCreateInfoCount = u32(len(queue_create_infos)),
        pQueueCreateInfos = raw_data(queue_create_infos),
        enabledExtensionCount = u32(len(device_extensions)),
        ppEnabledExtensionNames = raw_data(device_extensions),
    }
    vk_check(vk.CreateDevice(chosen_phys_device, &device_ci, nil, &ctx.device))

    vk.load_proc_addresses_device(ctx.device)
    if vk.BeginCommandBuffer == nil do fatal_error("Failed to load Vulkan device API")

    vk.GetDeviceQueue(ctx.device, queue_family_idx, 0, &ctx.queue)

    // TEMPORARY
    cmd_pool_ci := vk.CommandPoolCreateInfo {
        sType = .COMMAND_POOL_CREATE_INFO,
        queueFamilyIndex = ctx.queue_family_idx,
        flags = { .TRANSIENT }
    }
    vk_check(vk.CreateCommandPool(ctx.device, &cmd_pool_ci, nil, &ctx.cmd_pool))

    // Common resources
    {
        push_constant_ranges := []vk.PushConstantRange {
            {
                stageFlags = { .VERTEX, .FRAGMENT },
                size = PUSH_CONSTANTS_SIZE,
            }
        }
        layout_ci := vk.PipelineLayoutCreateInfo {
            sType = .PIPELINE_LAYOUT_CREATE_INFO,
            pushConstantRangeCount = u32(len(push_constant_ranges)),
            pPushConstantRanges = raw_data(push_constant_ranges),
            setLayoutCount = 0,
            pSetLayouts = nil,
        }
        vk_check(vk.CreatePipelineLayout(ctx.device, &layout_ci, nil, &ctx.common_pipeline_layout))

        win_width, win_height: i32
        assert(sdl.GetWindowSize(window, &win_width, &win_height))
        ctx.swapchain = create_swapchain(u32(win_width), u32(win_height))
    }

    // Tree init
    rbt.init_cmp(&ctx.alloc_tree, proc(range_a: Alloc_Range, range_b: Alloc_Range) -> rbt.Ordering {
        // NOTE: When searching, Alloc_Range { ptr, 0 } is used.
        diff_ba := int(range_b.ptr) - int(range_a.ptr)
        diff_ab := int(range_a.ptr) - int(range_b.ptr)
        if diff_ba >= 0 && diff_ba < int(range_a.size) {
            return .Equal
        } else if diff_ab >= 0 && diff_ab < int(range_b.size) {
            return .Equal
        } else if range_a.ptr < range_b.ptr {
            return .Less
        } else {
            return .Greater
        }
    })
}

_cleanup :: proc()
{
    vk.DestroyDevice(ctx.device, nil)
}

_swapchain_acquire_next :: proc() -> vk.ImageView
{
    fence_ci := vk.FenceCreateInfo {
        sType = .FENCE_CREATE_INFO,
        flags = { },
    }
    fence: vk.Fence
    vk_check(vk.CreateFence(ctx.device, &fence_ci, nil, &fence))
    defer vk.DestroyFence(ctx.device, fence, nil)

    vk_check(vk.AcquireNextImageKHR(ctx.device, ctx.swapchain.handle, max(u64), {}, fence, &ctx.swapchain_image_idx))

    vk_check(vk.WaitForFences(ctx.device, 1, &fence, true, max(u64)))

    return ctx.swapchain.image_views[ctx.swapchain_image_idx]
}

_swapchain_present :: proc()
{
    vk_check(vk.QueuePresentKHR(ctx.queue, &{
        sType = .PRESENT_INFO_KHR,
        //waitSemaphoreCount = 1,
        //pWaitSemaphores = &present_semaphore,
        swapchainCount = 1,
        pSwapchains = &ctx.swapchain.handle,
        pImageIndices = &ctx.swapchain_image_idx,
    }))
}

_mem_alloc :: proc(bytes: u64, align: u64 = 1, mem_type := Memory.Default) -> rawptr
{
    to_alloc := bytes + align - 1  // Allocate extra for alignment

    properties: vk.MemoryPropertyFlags
    switch mem_type
    {
        case .Default: properties = { .HOST_VISIBLE, .HOST_COHERENT }
        case .GPU: properties = { .DEVICE_LOCAL }
        case .Readback: properties = { .HOST_VISIBLE, .HOST_CACHED }
    }

    buf_ci := vk.BufferCreateInfo {
        sType = .BUFFER_CREATE_INFO,
        size = cast(vk.DeviceSize) to_alloc,
        usage = { .SHADER_DEVICE_ADDRESS, .INDEX_BUFFER, .STORAGE_BUFFER, .TRANSFER_DST, .TRANSFER_SRC },
        sharingMode = .EXCLUSIVE,
    }
    buffer: vk.Buffer
    vk_check(vk.CreateBuffer(ctx.device, &buf_ci, nil, &buffer))

    mem_requirements: vk.MemoryRequirements
    vk.GetBufferMemoryRequirements(ctx.device, buffer, &mem_requirements)
    assert(mem_requirements.size >= vk.DeviceSize(to_alloc))

    next: rawptr
    next = &vk.MemoryAllocateFlagsInfo {
        sType = .MEMORY_ALLOCATE_FLAGS_INFO,
        pNext = next,
        flags = { .DEVICE_ADDRESS },
    }
    memory_ai := vk.MemoryAllocateInfo {
        sType = .MEMORY_ALLOCATE_INFO,
        pNext = next,
        allocationSize = mem_requirements.size,
        memoryTypeIndex = find_mem_type(ctx.phys_device, mem_requirements.memoryTypeBits, properties)
    }
    mem: vk.DeviceMemory
    vk_check(vk.AllocateMemory(ctx.device, &memory_ai, nil, &mem))

    vk_check(vk.BindBufferMemory(ctx.device, buffer, mem, 0))

    info := vk.BufferDeviceAddressInfo {
        sType = .BUFFER_DEVICE_ADDRESS_INFO,
        buffer = buffer
    }
    addr := vk.GetBufferDeviceAddress(ctx.device, &info)
    addr_ptr := cast(rawptr) cast(uintptr) addr

    append(&ctx.gpu_allocs, GPU_Alloc_Meta {
        mem_handle = mem,
        buf_handle = buffer,
        device_address = addr,
        align = u32(align),
    })
    gpu_alloc_idx := u32(len(ctx.gpu_allocs)) - 1
    ctx.gpu_ptr_to_alloc[addr_ptr] = gpu_alloc_idx
    rbt.find_or_insert(&ctx.alloc_tree, Alloc_Range { u64(addr), u32(bytes) }, gpu_alloc_idx)

    if mem_type != .GPU
    {
        ptr: rawptr
        vk_check(vk.MapMemory(ctx.device, mem, 0, vk.DeviceSize(to_alloc), {}, &ptr))
        ctx.cpu_ptr_to_alloc[ptr] = gpu_alloc_idx
        return ptr
    }

    return rawptr(uintptr(addr))
}

_mem_free :: proc(ptr: rawptr, loc := #caller_location)
{
    _, cpu_found := ctx.cpu_ptr_to_alloc[ptr]
    _, gpu_found := ctx.gpu_ptr_to_alloc[ptr]
    if !cpu_found && !gpu_found
    {
        log.error("Attempting to free a pointer which is not allocated.", location = loc)
        return
    }

    // TODO: Free stuff
}

_host_to_device_ptr :: proc(ptr: rawptr) -> rawptr
{
    // We could do a tree search here but that would be more expensive

    meta_idx, found := ctx.cpu_ptr_to_alloc[ptr]
    if !found
    {
        log.error("Attempting to get the device pointer of a host pointer which is not allocated. Note: The pointer passed to this function must be a base allocation pointer.")
        return {}
    }

    meta := ctx.gpu_allocs[meta_idx]
    return rawptr(uintptr(meta.device_address))
}

// Textures
_texture_size_and_align :: proc(desc: Texture_Desc) -> (size: u64, align: u64) { return {}, {} }
_texture_view_descriptor :: proc(texture: Texture, view_desc: Texture_View_Desc) -> [4]u64 { return {} }
_texture_rw_view_descriptor :: proc(texture: Texture, view_desc: Texture_View_Desc) -> [4]u64 { return {} }

// Shaders
_shader_create :: proc(code: []u32, type: Shader_Type) -> Shader
{
    vk_stage := to_vk_shader_stage(type)

    push_constant_ranges := []vk.PushConstantRange {
        {
            stageFlags = { .VERTEX, .FRAGMENT },
            size = PUSH_CONSTANTS_SIZE,
        }
    }

    shader_cis := vk.ShaderCreateInfoEXT {
        sType = .SHADER_CREATE_INFO_EXT,
        codeType = .SPIRV,
        codeSize = len(code) * size_of(code[0]),
        pCode = raw_data(code),
        pName = "main",
        stage = vk_stage,
        nextStage = vk.ShaderStageFlags { .FRAGMENT } if type == .Vertex else {},
        pushConstantRangeCount = u32(len(push_constant_ranges)),
        pPushConstantRanges = raw_data(push_constant_ranges),
        setLayoutCount = 0,
        pSetLayouts = {}
    }
    shader: vk.ShaderEXT
    vk_check(vk.CreateShadersEXT(ctx.device, 1, &shader_cis, nil, &shader))
    return transmute(Shader) shader
}

@(private="file")
to_vk_shader_stage :: #force_inline proc(type: Shader_Type) -> vk.ShaderStageFlags
{
    switch type
    {
        case .Vertex: return { .VERTEX }
        case .Fragment: return { .FRAGMENT }
    }

    return {}
}

@(private="file")
to_vk_stage :: #force_inline proc(stage: Stage) -> vk.PipelineStageFlags
{
    switch stage
    {
        case .Transfer: return { .TRANSFER }
        case .Compute: return { .COMPUTE_SHADER }
        case .Raster_Color_Out: return { .COLOR_ATTACHMENT_OUTPUT }
        case .Fragment_Shader: return { .FRAGMENT_SHADER }
        case .Vertex_Shader: return { .VERTEX_SHADER }
        case .All: return { .ALL_COMMANDS }
    }

    return {}
}

// Semaphores
_sem_create :: proc(init_value: u64) -> Semaphore { return {} }

// Commands
get_queue :: proc() -> Queue
{
    return cast(Queue) ctx.queue
}

commands_begin :: proc(queue: Queue) -> Command_Buffer
{
    cmd_buf_ai := vk.CommandBufferAllocateInfo {
        sType = .COMMAND_BUFFER_ALLOCATE_INFO,
        commandPool = ctx.cmd_pool,
        level = .PRIMARY,
        commandBufferCount = 1,
    }
    cmd_buf: vk.CommandBuffer
    vk_check(vk.AllocateCommandBuffers(ctx.device, &cmd_buf_ai, &cmd_buf))

    cmd_buf_bi := vk.CommandBufferBeginInfo {
        sType = .COMMAND_BUFFER_BEGIN_INFO,
        flags = { .ONE_TIME_SUBMIT },
    }
    vk_check(vk.BeginCommandBuffer(cmd_buf, &cmd_buf_bi))

    return cast(Command_Buffer) cmd_buf
}

queue_submit :: proc(queue: Queue, cmd_bufs: []Command_Buffer)
{
    vk_queue := cast(vk.Queue) queue

    for cmd_buf in cmd_bufs
    {
        vk_cmd_buf := cast(vk.CommandBuffer) cmd_buf
        vk_check(vk.EndCommandBuffer(vk_cmd_buf))
    }

    to_submit := transmute([]vk.CommandBuffer) cmd_bufs
    submit_info := vk.SubmitInfo {
        sType              = .SUBMIT_INFO,
        commandBufferCount = u32(len(to_submit)),
        pCommandBuffers    = raw_data(to_submit),
    }
    vk_check(vk.QueueSubmit(vk_queue, 1, &submit_info, {}))
}

_cmd_mem_copy :: proc(cmd_buf: Command_Buffer, src, dst: rawptr, bytes: u64)
{
    vk_cmd_buf := cast(vk.CommandBuffer) cmd_buf

    src_buf, src_offset, ok_s := compute_buf_offset_from_gpu_ptr(src)
    dst_buf, dst_offset, ok_d := compute_buf_offset_from_gpu_ptr(dst)
    if !ok_s || !ok_d
    {
        log.error("alloc not found")
        return
    }

    copy_regions := []vk.BufferCopy {
        {
            srcOffset = vk.DeviceSize(src_offset),
            dstOffset = vk.DeviceSize(dst_offset),
            size = vk.DeviceSize(bytes),
        }
    }
    vk.CmdCopyBuffer(vk_cmd_buf, src_buf, dst_buf, u32(len(copy_regions)), raw_data(copy_regions))
}

_cmd_copy_to_texture :: proc(cmd_buf: Command_Buffer, texture: Texture, src, dst: rawptr) {}

_cmd_set_active_texture_heap_ptr :: proc(cmd_buf: Command_Buffer, ptr: rawptr) {}

_cmd_barrier :: proc(cmd_buf: Command_Buffer, before: Stage, after: Stage, hazards: Hazard_Flags = {})
{
    vk_cmd_buf := cast(vk.CommandBuffer) cmd_buf

    vk_before := to_vk_stage(before)
    vk_after  := to_vk_stage(after)

    barrier := vk.MemoryBarrier {
        sType = .MEMORY_BARRIER,
        srcAccessMask = { .MEMORY_WRITE },
        dstAccessMask = { .MEMORY_READ }
    }
    vk.CmdPipelineBarrier(vk_cmd_buf, vk_before, vk_after, {}, 1, &barrier, 0, nil, 0, nil)
}

_cmd_signal_after :: proc() {}
_cmd_wait_before :: proc() {}

_cmd_set_shaders :: proc(cmd_buf: Command_Buffer, vert_shader: Shader, frag_shader: Shader)
{
    vk_cmd_buf := cast(vk.CommandBuffer) cmd_buf
    vk_vert_shader := transmute(vk.ShaderEXT) vert_shader
    vk_frag_shader := transmute(vk.ShaderEXT) frag_shader

    shader_stages := []vk.ShaderStageFlags { { .VERTEX }, { .FRAGMENT } }
    to_bind := []vk.ShaderEXT { vk_vert_shader, vk_frag_shader }
    assert(len(shader_stages) == len(to_bind))
    vk.CmdBindShadersEXT(vk_cmd_buf, u32(len(shader_stages)), raw_data(shader_stages), raw_data(to_bind))
}

_cmd_set_depth_state :: proc(cmd_buf: Command_Buffer, state: Depth_State)
{
    vk_cmd_buf := cast(vk.CommandBuffer) cmd_buf

    vk.CmdSetDepthCompareOp(vk_cmd_buf, .LESS)
    vk.CmdSetDepthTestEnable(vk_cmd_buf, false)
    vk.CmdSetDepthWriteEnable(vk_cmd_buf, false)
    vk.CmdSetDepthBiasEnable(vk_cmd_buf, false)
    vk.CmdSetDepthClipEnableEXT(vk_cmd_buf, true)

    vk.CmdSetStencilTestEnable(vk_cmd_buf, false)
}

_cmd_set_blend_state :: proc(cmd_buf: Command_Buffer, state: Blend_State)
{
    vk_cmd_buf := cast(vk.CommandBuffer) cmd_buf

    b32_false := b32(false)
    vk.CmdSetColorBlendEnableEXT(vk_cmd_buf, 0, 1, &b32_false)
}

_cmd_dispatch :: proc() {}
_cmd_dispatch_indirect :: proc() {}

_cmd_begin_render_pass :: proc(cmd_buf: Command_Buffer, desc: Render_Pass_Desc)
{
    vk_cmd_buf := cast(vk.CommandBuffer) cmd_buf

    clear_color := desc.color_attachments[0].clear_color

    color_attachment := vk.RenderingAttachmentInfo {
        sType = .RENDERING_ATTACHMENT_INFO,
        imageView = desc.color_attachments[0].view,
        imageLayout = .GENERAL,
        loadOp = .CLEAR,
        storeOp = .STORE,
        clearValue = {
            color = { float32 = { clear_color.r, clear_color.g, clear_color.b, clear_color.a } }
        }
    }
    rendering_info := vk.RenderingInfo {
        sType = .RENDERING_INFO,
        renderArea = {
            offset = { 0, 0 },
            extent = { 1900, 1900 }
        },
        layerCount = 1,
        colorAttachmentCount = 1,
        pColorAttachments = &color_attachment,
        pDepthAttachment = nil,
    }
    vk.CmdBeginRendering(vk_cmd_buf, &rendering_info)

    sample_mask := vk.SampleMask(1)
    vk.CmdSetSampleMaskEXT(vk_cmd_buf, { ._1 }, &sample_mask)
    vk.CmdSetAlphaToCoverageEnableEXT(vk_cmd_buf, false)
    vk.CmdSetPolygonModeEXT(vk_cmd_buf, .FILL)
    vk.CmdSetCullMode(vk_cmd_buf, {})
    vk.CmdSetFrontFace(vk_cmd_buf, .COUNTER_CLOCKWISE)
    vk.CmdSetDepthCompareOp(vk_cmd_buf, .LESS)
    vk.CmdSetDepthTestEnable(vk_cmd_buf, false)
    vk.CmdSetDepthWriteEnable(vk_cmd_buf, false)
    vk.CmdSetDepthBiasEnable(vk_cmd_buf, false)
    vk.CmdSetDepthClipEnableEXT(vk_cmd_buf, true)
    vk.CmdSetStencilTestEnable(vk_cmd_buf, false)
    b32_false := b32(false)
    vk.CmdSetColorBlendEnableEXT(vk_cmd_buf, 0, 1, &b32_false)
    color_mask := vk.ColorComponentFlags { .R, .G, .B, .A }
    vk.CmdSetColorWriteMaskEXT(vk_cmd_buf, 0, 1, &color_mask)

    viewport := vk.Viewport {
        x = 0, y = 0,
        width = 1900, height = 1900,
        minDepth = 0.0, maxDepth = 1.0,
    }
    vk.CmdSetViewportWithCount(vk_cmd_buf, 1, &viewport)
    scissor := vk.Rect2D {
        offset = {
            x = 0, y = 0
        },
        extent = {
            width = 1900, height = 1900,
        }
    }
    vk.CmdSetScissorWithCount(vk_cmd_buf, 1, &scissor)
    vk.CmdSetRasterizerDiscardEnable(vk_cmd_buf, false)

    vk.CmdSetVertexInputEXT(vk_cmd_buf, 0, nil, 0, nil)
    vk.CmdSetRasterizationSamplesEXT(vk_cmd_buf, { ._1 })
    vk.CmdSetPrimitiveTopology(vk_cmd_buf, .TRIANGLE_LIST)
    vk.CmdSetPrimitiveRestartEnable(vk_cmd_buf, false)
}

_cmd_end_render_pass :: proc(cmd_buf: Command_Buffer)
{
    vk_cmd_buf := cast(vk.CommandBuffer) cmd_buf
    vk.CmdEndRendering(vk_cmd_buf)
}

_cmd_draw_indexed_instanced :: proc(cmd_buf: Command_Buffer, vertex_data: rawptr, fragment_data: rawptr,
                                    indices: rawptr, index_count: u32, instance_count: u32 = 1)
{
    vk_cmd_buf := cast(vk.CommandBuffer) cmd_buf

    indices_buf, indices_offset, ok_i := compute_buf_offset_from_gpu_ptr(indices)
    if !ok_i
    {
        log.error("Indices alloc not found")
        return
    }

    ptrs := []rawptr { vertex_data, fragment_data }
    assert(PUSH_CONSTANTS_SIZE == len(ptrs) * size_of(ptrs[0]))
    vk.CmdPushConstants(vk_cmd_buf, ctx.common_pipeline_layout, { .VERTEX, .FRAGMENT }, 0, PUSH_CONSTANTS_SIZE, raw_data(ptrs))

    // TMP
    vk.CmdSetRasterizerDiscardEnable(vk_cmd_buf, false)
    vk.CmdSetCullMode(vk_cmd_buf, {})
    vk.CmdSetDepthTestEnable(vk_cmd_buf, {})

    vk.CmdBindIndexBuffer(vk_cmd_buf, indices_buf, vk.DeviceSize(indices_offset), .UINT32)
    vk.CmdDrawIndexed(vk_cmd_buf, index_count, instance_count, 0, 0, 0)
}

@(private="file")
vk_check :: proc(result: vk.Result, location := #caller_location)
{
    if result != .SUCCESS {
        fatal_error("Vulkan failure: %", result, location = location)
    }
}

@(private="file")
vk_debug_callback :: proc "system" (severity: vk.DebugUtilsMessageSeverityFlagsEXT,
                                    types: vk.DebugUtilsMessageTypeFlagsEXT,
                                    callback_data: ^vk.DebugUtilsMessengerCallbackDataEXT,
                                    user_data: rawptr) -> b32
{
    context = runtime.default_context()
    context.logger = vk_logger

    level: log.Level
    if .ERROR in severity        do level = .Error
    else if .WARNING in severity do level = .Warning
    else if .INFO in severity    do level = .Info
    else                         do level = .Debug
    log.log(level, callback_data.pMessage)

    return false
}

@(private="file")
fatal_error :: proc(fmt: string, args: ..any, location := #caller_location)
{
    when ODIN_DEBUG {
        log.fatal(fmt, args, location = location)
        runtime.panic("")
    } else {
        log.panicf(fmt, args, location = location)
    }
}

@(private="file")
find_mem_type :: proc(phys_device: vk.PhysicalDevice, type_filter: u32, properties: vk.MemoryPropertyFlags) -> u32
{
    mem_properties: vk.PhysicalDeviceMemoryProperties
    vk.GetPhysicalDeviceMemoryProperties(phys_device, &mem_properties)
    for i in 0..<mem_properties.memoryTypeCount
    {
        if (type_filter & (1 << i) != 0) &&
           (mem_properties.memoryTypes[i].propertyFlags & properties) == properties {
            return i
        }
    }

    panic("Vulkan Error: Could not find suitable memory type!")
}

@(private="file")
align_up :: proc(x, align: u64) -> (aligned: u64)
{
    assert(0 == (align & (align - 1)), "must align to a power of two")
    return (x + (align - 1)) &~ (align - 1)
}

// Scratch arenas

@(private="file")
scratch_arenas: [4]vmem.Arena

@(private="file")
init_scratch_arenas :: proc()
{
    for &scratch in scratch_arenas
    {
        error := vmem.arena_init_growing(&scratch)
        assert(error == nil)
    }
}

@(private="file")
@(deferred_out = release_scratch)
acquire_scratch :: proc(used_allocators: ..mem.Allocator) -> (mem.Allocator, vmem.Arena_Temp)
{
    available_arena: ^vmem.Arena
    if len(used_allocators) < 1
    {
        available_arena = &scratch_arenas[0]
    }
    else
    {
        for &scratch in scratch_arenas
        {
            for used_alloc in used_allocators
            {
                // NOTE: We assume that if the data points to the same exact address,
                // it's an arena allocator and it's the same arena
                if used_alloc.data != &scratch
                {
                    available_arena = &scratch
                    break
                }

                if available_arena != nil do break
            }
        }
    }

    assert(available_arena != nil, "Available scratch arena not found.")

    return vmem.arena_allocator(available_arena), vmem.arena_temp_begin(available_arena)
}

@(private="file")
release_scratch :: #force_inline proc(allocator: mem.Allocator, temp: vmem.Arena_Temp)
{
    vmem.arena_temp_end(temp)
}

@(private="file")
create_swapchain :: proc(width: u32, height: u32) -> Swapchain
{
    res: Swapchain

    surface_caps: vk.SurfaceCapabilitiesKHR
    vk_check(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(ctx.phys_device, ctx.surface, &surface_caps))

    image_count := max(2, surface_caps.minImageCount)
    if surface_caps.maxImageCount != 0 do image_count = min(image_count, surface_caps.maxImageCount)

    surface_format_count: u32
    vk_check(vk.GetPhysicalDeviceSurfaceFormatsKHR(ctx.phys_device, ctx.surface, &surface_format_count, nil))
    surface_formats := make([]vk.SurfaceFormatKHR, surface_format_count, context.temp_allocator)
    vk_check(vk.GetPhysicalDeviceSurfaceFormatsKHR(ctx.phys_device, ctx.surface, &surface_format_count, raw_data(surface_formats)))

    surface_format := surface_formats[0]
    for candidate in surface_formats
    {
        if candidate == {.B8G8R8A8_SRGB, .SRGB_NONLINEAR}
        {
            surface_format = candidate
            break
        }
    }

    present_mode_count: u32
    vk_check(vk.GetPhysicalDeviceSurfacePresentModesKHR(ctx.phys_device, ctx.surface, &present_mode_count, nil))
    present_modes := make([]vk.PresentModeKHR, present_mode_count, context.temp_allocator)
    vk_check(vk.GetPhysicalDeviceSurfacePresentModesKHR(ctx.phys_device, ctx.surface, &present_mode_count, raw_data(present_modes)))

    present_mode := vk.PresentModeKHR.FIFO
    for candidate in present_modes {
        if candidate == .MAILBOX {
            present_mode = candidate
            break
        }
    }

    res.width = width
    res.height = height

    swapchain_ci := vk.SwapchainCreateInfoKHR {
        sType = .SWAPCHAIN_CREATE_INFO_KHR,
        surface = ctx.surface,
        minImageCount = image_count,
        imageFormat = surface_format.format,
        imageColorSpace = surface_format.colorSpace,
        imageExtent = { res.width, res.height },
        imageArrayLayers = 1,
        imageUsage = { .COLOR_ATTACHMENT },
        preTransform = surface_caps.currentTransform,
        compositeAlpha = { .OPAQUE },
        presentMode = present_mode,
        clipped = true,
    }
    vk_check(vk.CreateSwapchainKHR(ctx.device, &swapchain_ci, nil, &res.handle))

    vk_check(vk.GetSwapchainImagesKHR(ctx.device, res.handle, &image_count, nil))
    res.images = make([]vk.Image, image_count, context.allocator)
    vk_check(vk.GetSwapchainImagesKHR(ctx.device, res.handle, &image_count, raw_data(res.images)))

    res.image_views = make([]vk.ImageView, image_count, context.allocator)
    for image, i in res.images
    {
        image_view_ci := vk.ImageViewCreateInfo {
            sType = .IMAGE_VIEW_CREATE_INFO,
            image = image,
            viewType = .D2,
            format = surface_format.format,
            subresourceRange = {
                aspectMask = { .COLOR },
                levelCount = 1,
                layerCount = 1,
            },
        }
        vk_check(vk.CreateImageView(ctx.device, &image_view_ci, nil, &res.image_views[i]))
    }

    res.present_semaphores = make([]vk.Semaphore, image_count, context.allocator)

    semaphore_ci := vk.SemaphoreCreateInfo { sType = .SEMAPHORE_CREATE_INFO }
    for &semaphore in res.present_semaphores {
        vk_check(vk.CreateSemaphore(ctx.device, &semaphore_ci, nil, &semaphore))
    }

    return res
}

@(private="file")
Swapchain :: struct
{
    handle: vk.SwapchainKHR,
    width, height: u32,
    images: []vk.Image,
    image_views: []vk.ImageView,
    present_semaphores: []vk.Semaphore,
}

// NOTE: This is slow but unfortunately needed for some things. Vulkan
// is still a "buffer object" centric API.
@(private="file")
search_alloc_from_gpu_ptr :: proc(ptr: rawptr) -> (res: u32, ok: bool)
{
    alloc_idx, found := rbt.find_value(&ctx.alloc_tree, Alloc_Range { u64(uintptr(ptr)), 0 })
    return alloc_idx, found
}

@(private="file")
compute_buf_offset_from_gpu_ptr :: proc(ptr: rawptr) -> (buf: vk.Buffer, offset: u32, ok: bool)
{
    alloc_idx, ok_s := search_alloc_from_gpu_ptr(ptr)
    if !ok_s do return {}, {}, false

    alloc := ctx.gpu_allocs[alloc_idx]

    buf = alloc.buf_handle
    offset = u32(uintptr(ptr) - uintptr(alloc.device_address))
    return buf, offset, true
}
