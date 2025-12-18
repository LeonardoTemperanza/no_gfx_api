
package gpu

import "core:slice"
import "core:log"
import "base:runtime"

import "core:fmt"

import sdl "vendor:sdl3"
import vk "vendor:vulkan"

// NOTE: "GPU Pointers" are actually fake and contain 28 (high) bits of index into gpu_allocs
// and 36 bits of byte offset from that buffer. They should still support pointer arithmetic
// and act like pointers.

Offset_Num_Bits :: 36

@(private="file")
gpu_ptr_pack :: #force_inline proc(buf_idx: u32, offset: u64) -> rawptr
{
    high := u64(buf_idx) << Offset_Num_Bits
    low_mask := ((u64(1) << Offset_Num_Bits) - 1)
    low := offset & low_mask
    return cast(rawptr) cast(uintptr) (high | low)
}

@(private="file")
gpu_ptr_unpack :: #force_inline proc(ptr: rawptr) -> (buf_idx: u32, offset: u64)
{
    ptr_u64 := u64(uintptr(ptr))
    buf_idx = u32(ptr_u64 >> Offset_Num_Bits)
    mask := ((u64(1) << Offset_Num_Bits) - 1)
    offset = ptr_u64 & mask
    return buf_idx, offset
}

@(private="file")
gpu_ptr_to_device_address :: #force_inline proc(ptr: rawptr) -> rawptr
{
    buf_idx, offset := gpu_ptr_unpack(ptr)
    return auto_cast (cast(uintptr) ctx.gpu_allocs[buf_idx].device_address + uintptr(offset))
}

@(private="file")
GPU_Alloc_Meta :: struct #all_or_none
{
    mem_handle: vk.DeviceMemory,
    buf_handle: vk.Buffer,
    device_address: vk.DeviceAddress,
    align: u32,
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

    phys_device: vk.PhysicalDevice,
    device: vk.Device,
    queue: vk.Queue,
    queue_family_idx: u32,

    // TEMPORARY
    cmd_pool: vk.CommandPool,
}

// Initialization

@(private="file")
ctx: Context
@(private="file")
vk_logger: log.Logger

_init :: proc(window: ^sdl.Window)
{
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
        vk.EXT_CONSERVATIVE_RASTERIZATION_EXTENSION_NAME,
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
            geometryShader = true,  // For the tri_idx gbuffer.
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
}

_cleanup :: proc()
{

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
        usage = { .STORAGE_BUFFER, .TRANSFER_DST, .TRANSFER_SRC, .SHADER_DEVICE_ADDRESS, .ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_KHR },
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
    addr := align_up(u64(vk.GetBufferDeviceAddress(ctx.device, &info)), align)
    addr_ptr := cast(rawptr) cast(uintptr) addr

    append(&ctx.gpu_allocs, GPU_Alloc_Meta {
        mem_handle = mem,
        buf_handle = buffer,
        device_address = cast(vk.DeviceAddress)addr,
        align = u32(align),
    })
    gpu_alloc_idx := u32(len(ctx.gpu_allocs)) - 1
    ctx.gpu_ptr_to_alloc[addr_ptr] = gpu_alloc_idx

    if mem_type != .GPU
    {
        ptr: rawptr
        vk_check(vk.MapMemory(ctx.device, mem, 0, vk.DeviceSize(to_alloc), {}, &ptr))
        ctx.cpu_ptr_to_alloc[ptr] = gpu_alloc_idx
        return ptr
    }

    return gpu_ptr_pack(gpu_alloc_idx, 0)
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
    meta_idx, found := ctx.cpu_ptr_to_alloc[ptr]
    if !found
    {
        log.error("Attempting to get the device pointer of a host pointer which is not allocated. Note: The pointer passed to this function must be a base allocation pointer.")
        return {}
    }

    return gpu_ptr_pack(meta_idx, 0)
}

// Textures
_texture_size_and_align :: proc(desc: Texture_Desc) -> (size: u64, align: u64) { return {}, {} }
_texture_view_descriptor :: proc(texture: Texture, view_desc: Texture_View_Desc) -> [4]u64 { return {} }
_texture_rw_view_descriptor :: proc(texture: Texture, view_desc: Texture_View_Desc) -> [4]u64 { return {} }

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

    src_buffer_idx, src_offset := gpu_ptr_unpack(src)
    dst_buffer_idx, dst_offset := gpu_ptr_unpack(dst)
    src_buf := ctx.gpu_allocs[src_buffer_idx].buf_handle
    dst_buf := ctx.gpu_allocs[dst_buffer_idx].buf_handle

    copy_regions := []vk.BufferCopy {
        {
            srcOffset = vk.DeviceSize(src_offset),
            dstOffset = vk.DeviceSize(dst_offset),
            size = vk.DeviceSize(bytes),
        }
    }
    vk.CmdCopyBuffer(vk_cmd_buf, src_buf, dst_buf, u32(len(copy_regions)), raw_data(copy_regions))

    fmt.println("Copied", src_buffer_idx, src_offset, "into", dst_buffer_idx, dst_offset)
}

_cmd_copy_to_texture :: proc(cmd_buf: Command_Buffer, texture: Texture, src, dst: rawptr) {}

_cmd_set_active_texture_heap_ptr :: proc(cmd_buf: Command_Buffer, ptr: rawptr) {}

_cmd_barrier :: proc() {}
_cmd_signal_after :: proc() {}
_cmd_wait_before :: proc() {}

_cmd_set_pipeline :: proc() {}
_cmd_set_depth_stencil_state :: proc() {}
_cmd_set_blend_state :: proc() {}

_cmd_dispatch :: proc() {}
_cmd_dispatch_indirect :: proc() {}

_cmd_begin_render_pass :: proc() {}
_cmd_end_render_pass :: proc() {}

_cmd_draw_indexed_instanced :: proc(cmd_buf: Command_Buffer, vertex_data: rawptr, pixel_data: rawptr,
                                   indices: rawptr, index_count: u32, instance_count: u32) {}

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
