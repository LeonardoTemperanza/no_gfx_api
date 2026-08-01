
package gpu

import "core:slice"
import "core:log"
import "base:runtime"
import "core:sync"
import "core:dynlib"
import "core:container/priority_queue"
import "core:strings"
import "core:fmt"
import intr "base:intrinsics"

import vk "vendor:vulkan"
import "vma"

@(private="file")
Max_Textures :: 65536
@(private="file")
Max_Samplers :: 256
@(private="file")
Max_BVHs :: 16

@(private="file")
Graphics_Shader_Push_Constants :: struct #packed {
    vert_data: rawptr,
    frag_data: rawptr,
    indirect_data: rawptr,
}

@(private="file")
Compute_Shader_Push_Constants :: struct #packed {
    compute_data: rawptr,
}

@(private="file")
Alloc_Handle :: distinct Handle

@(private="file")
Context :: struct
{
    validation: bool,
    features: Features,
    instance: vk.Instance,
    debug_messenger: vk.DebugUtilsMessengerEXT,
    surface: vk.SurfaceKHR,
    phys_device: vk.PhysicalDevice,
    device: vk.Device,
    vma_allocator: vma.Allocator,
    physical_properties: Physical_Properties,

    // Common resources
    desc_layouts: [dynamic]vk.DescriptorSetLayout,
    common_pipeline_layout_graphics: vk.PipelineLayout,
    common_pipeline_layout_compute: vk.PipelineLayout,

    // Resource pools
    allocs: Resource_Pool(Alloc_Handle, Alloc_Info),
    queues: [Queue]Queue_Info,  // Reserve slot 0 for invalid queue.
    textures: Resource_Pool(Texture_Handle, Texture_Info),
    bvhs: Resource_Pool(BVH, BVH_Info),
    shaders: Resource_Pool(Shader, Shader_Info),
    command_buffers: Resource_Pool(Command_Buffer, Command_Buffer_Info),
    semaphores: Resource_Pool(Semaphore, vk.Semaphore),
    desc_heaps: Resource_Pool(Descriptor_Heap, Descriptor_Heap_Info),

    cmd_bufs_sems: [Queue]Semaphore,
    cmd_bufs_counters: [Queue]u64,

    // Swapchain
    swapchain: Swapchain,
    swapchain_desc: Swapchain_Desc,
    swapchain_image_idx: u32,

    queue_lock: sync.Atomic_Mutex,
    tls_lock: sync.Atomic_Mutex,
    tls_contexts: [dynamic]^Thread_Local_Context,
}

@(private="file")
Free_Command_Buffer :: struct
{
    handle: Command_Buffer,
    timeline_value: u64, // Duplicated information from Command_Buffer_Info to avoid locking during search
}

@(private="file")
Thread_Local_Context :: struct
{
    pools: [Queue]vk.CommandPool,
    free_buffers: [Queue]priority_queue.Priority_Queue(Free_Command_Buffer),
    samplers: [dynamic]Sampler_Info,  // Samplers are interned but have permanent lifetime
}

@(private="file")
Physical_Properties :: struct
{
    bvh_props: vk.PhysicalDeviceAccelerationStructurePropertiesKHR,
    props2: vk.PhysicalDeviceProperties2,
}

@(private="file")
BVH_Info :: struct
{
    handle: vk.AccelerationStructureKHR,
    mem: rawptr,
    is_blas: bool,
    shapes: [dynamic]BVH_Shape_Desc,  // Only used if BLAS.
    blas_desc: BLAS_Desc,
    tlas_desc: TLAS_Desc,
}

@(private="file")
Alloc_Info :: struct
{
    buf_handle: vk.Buffer,
    allocation: vma.Allocation,
    cpu: rawptr,
    gpu: rawptr,
    align: u32,
    buf_size: vk.DeviceSize,
}

Alloc_Impl_Info :: struct
{
    range_end: rawptr,
    handle: Alloc_Handle,
}

@(private="file")
Texture_Info :: struct
{
    handle: vk.Image,
    views: [dynamic]Image_View_Info,
    owns_image: bool,
}

@(private="file")
Image_View_Info :: struct
{
    info: vk.ImageViewCreateInfo,
    view: vk.ImageView,
}

@(private="file")
Sampler_Info :: struct
{
    info: vk.SamplerCreateInfo,
    sampler: vk.Sampler,
}

@(private="file")
Queue_Info :: struct
{
    handle: vk.Queue,
    family_idx: u32,
    queue_idx: u32,
}

@(private="file")
Shader_Info :: struct {
    handle: vk.ShaderEXT,
    current_workgroup_size: [3]u32,
    is_compute: bool,
}

// NOTE: Command buffers are required by the API
// to be thread local, they can't be passed to other
// threads. Just make new ones. Because of this
// we won't need to synchronize as much.
// TODO: We should add this check in the validation layer.
@(private="file")
Command_Buffer_Info :: struct {
    handle: vk.CommandBuffer,
    timeline_value: u64,
    thread_id: int,
    queue: Queue,
    compute_shader: Shader,
    recording: bool,

    wait_sems: [dynamic]Semaphore_Value,
    signal_sems: [dynamic]Semaphore_Value,
}

@(private="file")
Descriptor_Heap_Info :: struct
{
    desc_pool: vk.DescriptorPool,
    textures: vk.DescriptorSet,
    textures_rw: vk.DescriptorSet,
    samplers: vk.DescriptorSet,
    bvhs: vk.DescriptorSet,
}

@(private="file")
Semaphore_Value :: struct
{
    sem: Semaphore,
    val: u64,
}

// Initialization

@(private="file")
ctx: Context

@(private="file")
vk_logger: log.Logger

@(require_results)
_init :: proc(validation := true, loc := #caller_location) -> bool
{
    // Clear API specific arguments
    defer {
        delete(EXTRA_OPT_DEVICE_EXTENSIONS)
        EXTRA_OPT_DEVICE_EXTENSIONS = {}
        delete(EXTRA_DEVICE_EXTENSIONS)
        EXTRA_DEVICE_EXTENSIONS = {}
    }

    scratch, _ := acquire_scratch()

    // Load vulkan function pointers
    vk.load_proc_addresses_global(cast(rawptr) get_instance_proc_address)

    vk_logger = context.logger
    ctx.validation = validation

    // Create instance
    {
        required_layers := make([dynamic]cstring, allocator = scratch)
        optional_layers := make([dynamic]cstring, allocator = scratch)
        if ctx.validation {
            append(&optional_layers, "VK_LAYER_KHRONOS_validation")
        }
        // NOTE: Emulation layer for the shader_object extension, will
        // disable itself if it is actually supported.
        append(&optional_layers, "VK_LAYER_KHRONOS_shader_object")

        for opt in optional_layers {
            if supports_layer(opt) {
                append(&required_layers, opt)
            }
        }

        if ctx.validation && !supports_layer("VK_LAYER_KHRONOS_validation") {
            log.warn("init was called with validation = true, but Vulkan validation layers were not found (Did you install the Vulkan SDK?). Only high-level no_gfx validations will be performed.", location = loc)
        }

        required_extensions := make([dynamic]cstring, allocator = scratch)
        append(&required_extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)
        append(&required_extensions, vk.KHR_SURFACE_EXTENSION_NAME)

        unsupported_extensions := make([dynamic]cstring, allocator = scratch)

        optional_extensions := make([dynamic]cstring, allocator = scratch)
        append(&optional_extensions, "VK_KHR_win32_surface")
        append(&optional_extensions, "VK_KHR_wayland_surface")
        append(&optional_extensions, "VK_KHR_xlib_surface")
        append(&optional_extensions, vk.EXT_METAL_SURFACE_EXTENSION_NAME)
        append(&optional_extensions, vk.KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME)

        // Check that required_extensions are supported
        for req in required_extensions {
            if !supports_instance_extension(req) {
                append(&unsupported_extensions, req)
            }
        }

        if len(unsupported_extensions) > 0 {
            log_unsupported_extensions(unsupported_extensions[:], loc)
            return false
        }

        for opt in optional_extensions {
            if supports_instance_extension(opt) {
                append(&required_extensions, opt)
            }
        }

        debug_messenger_ci := vk.DebugUtilsMessengerCreateInfoEXT {
            sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
            messageSeverity = { .WARNING, .ERROR },
            messageType = { .VALIDATION, .PERFORMANCE },
            pfnUserCallback = vk_debug_callback
        }

        validation_features := make([dynamic]vk.ValidationFeatureEnableEXT, allocator = scratch)
        if ctx.validation {
            append(&validation_features, vk.ValidationFeatureEnableEXT.SYNCHRONIZATION_VALIDATION)
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
            flags = { .ENUMERATE_PORTABILITY_KHR },
            enabledLayerCount = u32(len(required_layers)),
            ppEnabledLayerNames = raw_data(required_layers),
            enabledExtensionCount = u32(len(required_extensions)),
            ppEnabledExtensionNames = raw_data(required_extensions),
            pNext = next,
        }, nil, &ctx.instance))

        vk.load_proc_addresses_instance(ctx.instance)
        assert(vk.DestroyInstance != nil, "Failed to load Vulkan instance API")

        vk_check(vk.CreateDebugUtilsMessengerEXT(ctx.instance, &debug_messenger_ci, nil, &ctx.debug_messenger))
    }

    // Physical device
    {
        phys_device_count: u32
        vk_check(vk.EnumeratePhysicalDevices(ctx.instance, &phys_device_count, nil))
        if phys_device_count == 0 do fatal_error("Did not find any GPUs!")
        phys_devices := make([]vk.PhysicalDevice, phys_device_count, allocator = scratch)
        vk_check(vk.EnumeratePhysicalDevices(ctx.instance, &phys_device_count, raw_data(phys_devices)))

        found := false
        best_score: u32
        device_loop: for candidate in phys_devices
        {
            score: u32

            properties := vk.PhysicalDeviceProperties2 { sType = .PHYSICAL_DEVICE_PROPERTIES_2 }
            features := vk.PhysicalDeviceFeatures2 { sType = .PHYSICAL_DEVICE_FEATURES_2 }
            vk.GetPhysicalDeviceProperties2(candidate, &properties);
            vk.GetPhysicalDeviceFeatures2(candidate, &features);

            #partial switch properties.properties.deviceType
            {
                case .DISCRETE_GPU:   score += 1000
                case .VIRTUAL_GPU:    score += 100
                case .INTEGRATED_GPU: score += 10
                case: {}
            }

            if best_score < score
            {
                best_score = score
                ctx.phys_device = candidate
                found = true
            }
        }

        if !found do fatal_error("Could not find suitable GPU.")
    }

    raytracing_extensions := []cstring {
        vk.KHR_DEFERRED_HOST_OPERATIONS_EXTENSION_NAME,
        vk.KHR_ACCELERATION_STRUCTURE_EXTENSION_NAME,
        vk.KHR_RAY_QUERY_EXTENSION_NAME,
    }

    draw_indirect_multi_extension := cstring(vk.KHR_DRAW_INDIRECT_COUNT_EXTENSION_NAME)

    // Query physical device feature availability
    {
        supports_raytracing := true
        supports_draw_indirect_multi := false

        count: u32
        vk.EnumerateDeviceExtensionProperties(ctx.phys_device, nil, &count, nil)
        extensions := make([]vk.ExtensionProperties, count, allocator = scratch)
        vk.EnumerateDeviceExtensionProperties(ctx.phys_device, nil, &count, raw_data(extensions))

        for required_ext in raytracing_extensions
        {
            found := false
            for &supported_ext in extensions
            {
                if cstring(&supported_ext.extensionName[0]) == required_ext {
                    found = true
                    continue
                }
            }

            if !found {
                supports_raytracing = false
                break
            }
        }

        for &supported_ext in extensions
        {
            if cstring(&supported_ext.extensionName[0]) == draw_indirect_multi_extension
            {
                supports_draw_indirect_multi = true
                break
            }
        }

        ray_query_features := vk.PhysicalDeviceRayQueryFeaturesKHR {
            sType = .PHYSICAL_DEVICE_RAY_QUERY_FEATURES_KHR
        }
        accel_features := vk.PhysicalDeviceAccelerationStructureFeaturesKHR {
            sType = .PHYSICAL_DEVICE_ACCELERATION_STRUCTURE_FEATURES_KHR,
            pNext = &ray_query_features,
        }
        features := vk.PhysicalDeviceFeatures2 {
            sType = .PHYSICAL_DEVICE_FEATURES_2,
            pNext = &accel_features
        }
        vk.GetPhysicalDeviceFeatures2(ctx.phys_device, &features)

        supports_raytracing = supports_raytracing && accel_features.accelerationStructure && ray_query_features.rayQuery

        if supports_raytracing do ctx.features += { .Raytracing }
        if supports_draw_indirect_multi do ctx.features += { .Draw_Indirect_Multi }
    }

    // Get physical device properties
    accel_props := vk.PhysicalDeviceAccelerationStructurePropertiesKHR {
        sType = .PHYSICAL_DEVICE_ACCELERATION_STRUCTURE_PROPERTIES_KHR
    }
    props2 := vk.PhysicalDeviceProperties2 {
        sType = .PHYSICAL_DEVICE_PROPERTIES_2,
        pNext = &accel_props,
    }
    vk.GetPhysicalDeviceProperties2(ctx.phys_device, &props2)
    ctx.physical_properties = {
        accel_props, props2
    }

    // Queues create info
    priority: f32 = 1.0
    queue_create_infos: [dynamic]vk.DeviceQueueCreateInfo = make([dynamic]vk.DeviceQueueCreateInfo, allocator = scratch)
    {
        families: [Queue]u32
        families[.Main] = find_queue_family(graphics = true, compute = true, transfer = true)
        families[.Compute] = find_queue_family(graphics = false, compute = true, transfer = true)
        families[.Transfer] = find_queue_family(graphics = false, compute = false, transfer = true)

        main: for i in 0..<len(Queue)
        {
            #assert(min(Queue) == Queue(0))
            #assert(max(Queue) == Queue(len(Queue) - 1))
            type := Queue(i)

            for j in 0..<i
            {
                if ctx.queues[Queue(j)].family_idx == families[type] {
                    ctx.queues[Queue(i)] = ctx.queues[Queue(j)]
                    continue main
                }
            }

            ctx.queues[type].family_idx = families[type]
            ctx.queues[type].queue_idx = 0

            append(&queue_create_infos, vk.DeviceQueueCreateInfo {
                sType = .DEVICE_QUEUE_CREATE_INFO,
                queueFamilyIndex = families[type],
                queueCount = 1,
                pQueuePriorities = &priority,
            })
        }
    }

    // Device
    {
        unsupported_extensions := make([dynamic]cstring, allocator = scratch)

        required_extensions := make([dynamic]cstring, allocator = scratch)
        append(&required_extensions, vk.KHR_SWAPCHAIN_EXTENSION_NAME)
        append(&required_extensions, vk.EXT_SHADER_OBJECT_EXTENSION_NAME)
        for req_ext in EXTRA_DEVICE_EXTENSIONS {
            append(&required_extensions, req_ext)
        }

        optional_extensions := make([dynamic]cstring, allocator = scratch)
        append(&optional_extensions, vk.KHR_PORTABILITY_SUBSET_EXTENSION_NAME)
        for opt_ext in EXTRA_OPT_DEVICE_EXTENSIONS {
            append(&optional_extensions, opt_ext)
        }

        // Check that required extensions are present
        for req in required_extensions {
            if !supports_device_extension(req) {
                append(&unsupported_extensions, req)
            }
        }

        if len(unsupported_extensions) > 0 {
            log_unsupported_extensions(unsupported_extensions[:], loc)
            return false
        }

        // Add optional extensions
        if .Raytracing in ctx.features
        {
            append(&required_extensions, vk.KHR_DEFERRED_HOST_OPERATIONS_EXTENSION_NAME)
            append(&required_extensions, vk.KHR_RAY_QUERY_EXTENSION_NAME)
            append(&required_extensions, vk.KHR_ACCELERATION_STRUCTURE_EXTENSION_NAME)
        }

        if .Draw_Indirect_Multi in ctx.features
        {
            append(&required_extensions, vk.KHR_DRAW_INDIRECT_COUNT_EXTENSION_NAME)
        }

        for opt in optional_extensions {
            if supports_device_extension(opt) {
                append(&required_extensions, opt)
            }
        }

        next: rawptr
        next = &vk.PhysicalDeviceVulkan12Features {
            sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
            pNext = next,
            runtimeDescriptorArray = true,
            shaderSampledImageArrayNonUniformIndexing = true,
            shaderStorageImageArrayNonUniformIndexing = true,
            descriptorBindingSampledImageUpdateAfterBind = true,
            descriptorBindingStorageImageUpdateAfterBind = true,
            descriptorBindingPartiallyBound = true,
            timelineSemaphore = true,
            bufferDeviceAddress = true,
            drawIndirectCount = b32(.Draw_Indirect_Multi in ctx.features),
            scalarBlockLayout = true,
            shaderInt8 = true,
        }
        next = &vk.PhysicalDeviceVulkan11Features {
            sType = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
            pNext = next,
            shaderDrawParameters = true,
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
            // NOTE(MP): On darwin (macOS, iOS, etc.), this extension doesn't
            // exist, however, thankfully, depth clip is already the default there.
            depthClipEnable = ODIN_OS != .Darwin,
        }
        next = &vk.PhysicalDeviceFeatures2 {
            sType = .PHYSICAL_DEVICE_FEATURES_2,
            pNext = next,
            features = {
                shaderInt64 = true,
                shaderInt16 = true,
                vertexPipelineStoresAndAtomics = true,
                samplerAnisotropy = true,
                imageCubeArray = true,
            }
        }
        raytracing_features := &vk.PhysicalDeviceAccelerationStructureFeaturesKHR {
            sType = .PHYSICAL_DEVICE_ACCELERATION_STRUCTURE_FEATURES_KHR,
            pNext = next,
            accelerationStructure = true,
            descriptorBindingAccelerationStructureUpdateAfterBind = true,
        }
        if .Raytracing in ctx.features do next = raytracing_features
        rayquery_features := &vk.PhysicalDeviceRayQueryFeaturesKHR {
            sType = .PHYSICAL_DEVICE_RAY_QUERY_FEATURES_KHR,
            pNext = next,
            rayQuery = true,
        }
        if .Raytracing in ctx.features do next = rayquery_features

        device_ci := vk.DeviceCreateInfo {
            sType = .DEVICE_CREATE_INFO,
            pNext = next,
            queueCreateInfoCount = u32(len(queue_create_infos)),
            pQueueCreateInfos = raw_data(queue_create_infos),
            enabledExtensionCount = u32(len(required_extensions)),
            ppEnabledExtensionNames = raw_data(required_extensions),
        }
        vk_check(vk.CreateDevice(ctx.phys_device, &device_ci, nil, &ctx.device))

        vk.load_proc_addresses_device(ctx.device)
        if vk.BeginCommandBuffer == nil do fatal_error("Failed to load Vulkan device API")
    }

    for &queue in ctx.queues {
        vk.GetDeviceQueue(ctx.device, queue.family_idx, queue.queue_idx, &queue.handle)
    }

    // Common resources
    {
        flags_ci := vk.DescriptorSetLayoutBindingFlagsCreateInfo {
            sType = .DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
            bindingCount = 1,
            pBindingFlags = &vk.DescriptorBindingFlags { .UPDATE_AFTER_BIND, .PARTIALLY_BOUND },
        }

        {
            layout_ci := vk.DescriptorSetLayoutCreateInfo {
                sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
                pNext = &flags_ci,
                flags = { .UPDATE_AFTER_BIND_POOL },
                bindingCount = 1,
                pBindings = &vk.DescriptorSetLayoutBinding {
                    binding = 0,
                    descriptorType = .SAMPLED_IMAGE,
                    descriptorCount = Max_Textures,
                    stageFlags = { .VERTEX, .FRAGMENT, .COMPUTE },
                },
            }
            layout: vk.DescriptorSetLayout
            vk_check(vk.CreateDescriptorSetLayout(ctx.device, &layout_ci, nil, &layout))
            append(&ctx.desc_layouts, layout)
        }
        {
            layout_ci := vk.DescriptorSetLayoutCreateInfo {
                sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
                pNext = &flags_ci,
                flags = { .UPDATE_AFTER_BIND_POOL },
                bindingCount = 1,
                pBindings = &vk.DescriptorSetLayoutBinding {
                    binding = 0,
                    descriptorType = .STORAGE_IMAGE,
                    descriptorCount = Max_Textures,
                    stageFlags = { .VERTEX, .FRAGMENT, .COMPUTE },
                },
            }
            layout: vk.DescriptorSetLayout
            vk_check(vk.CreateDescriptorSetLayout(ctx.device, &layout_ci, nil, &layout))
            append(&ctx.desc_layouts, layout)
        }
        {
            layout_ci := vk.DescriptorSetLayoutCreateInfo {
                sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
                pNext = &flags_ci,
                flags = { .UPDATE_AFTER_BIND_POOL },
                bindingCount = 1,
                pBindings = &vk.DescriptorSetLayoutBinding {
                    binding = 0,
                    descriptorType = .SAMPLER,
                    descriptorCount = Max_Samplers,
                    stageFlags = { .VERTEX, .FRAGMENT, .COMPUTE },
                },
            }
            layout: vk.DescriptorSetLayout
            vk_check(vk.CreateDescriptorSetLayout(ctx.device, &layout_ci, nil, &layout))
            append(&ctx.desc_layouts, layout)
        }
        if .Raytracing in ctx.features
        {
            layout_ci := vk.DescriptorSetLayoutCreateInfo {
                sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
                pNext = &flags_ci,
                flags = { .UPDATE_AFTER_BIND_POOL },
                bindingCount = 1,
                pBindings = &vk.DescriptorSetLayoutBinding {
                    binding = 0,
                    descriptorType = .ACCELERATION_STRUCTURE_KHR,
                    descriptorCount = Max_BVHs,
                    stageFlags = { .VERTEX, .FRAGMENT, .COMPUTE },
                },
            }
            layout: vk.DescriptorSetLayout
            vk_check(vk.CreateDescriptorSetLayout(ctx.device, &layout_ci, nil, &layout))
            append(&ctx.desc_layouts, layout)
        }

        // Graphics pipeline layout
        {
            push_constant_ranges := []vk.PushConstantRange {
                {
                    stageFlags = { .VERTEX, .FRAGMENT },
                    size = size_of(Graphics_Shader_Push_Constants),
                }
            }
            pipeline_layout_ci := vk.PipelineLayoutCreateInfo {
                sType = .PIPELINE_LAYOUT_CREATE_INFO,
                pushConstantRangeCount = u32(len(push_constant_ranges)),
                pPushConstantRanges = raw_data(push_constant_ranges),
                setLayoutCount = u32(len(ctx.desc_layouts)),
                pSetLayouts = raw_data(ctx.desc_layouts),
            }
            vk_check(vk.CreatePipelineLayout(ctx.device, &pipeline_layout_ci, nil, &ctx.common_pipeline_layout_graphics))
        }

        // Compute pipeline layout
        {
            push_constant_ranges := []vk.PushConstantRange {
                {
                    stageFlags = { .COMPUTE },
                    size = size_of(Compute_Shader_Push_Constants),
                }
            }
            pipeline_layout_ci := vk.PipelineLayoutCreateInfo {
                sType = .PIPELINE_LAYOUT_CREATE_INFO,
                pushConstantRangeCount = u32(len(push_constant_ranges)),
                pPushConstantRanges = raw_data(push_constant_ranges),
                setLayoutCount = u32(len(ctx.desc_layouts)),
                pSetLayouts = raw_data(ctx.desc_layouts),
            }
            vk_check(vk.CreatePipelineLayout(ctx.device, &pipeline_layout_ci, nil, &ctx.common_pipeline_layout_compute))
        }
    }

    // Resource pools
    pool_init(&ctx.allocs)
    pool_init(&ctx.textures)
    pool_init(&ctx.bvhs)
    pool_init(&ctx.shaders)
    pool_init(&ctx.command_buffers)
    pool_init(&ctx.semaphores)
    pool_init(&ctx.desc_heaps)

    // VMA allocator
    vma_vulkan_procs := vma.create_vulkan_functions()
    // VMA validates KHR aliases; some loaders expose only core names on 1.1+.
    if vma_vulkan_procs.get_buffer_memory_requirements2_khr == nil && vk.GetDeviceProcAddr != nil {
        addr := vk.GetDeviceProcAddr(ctx.device, "vkGetBufferMemoryRequirements2")
        if addr == nil do addr = vk.GetDeviceProcAddr(ctx.device, "vkGetBufferMemoryRequirements2KHR")
        vma_vulkan_procs.get_buffer_memory_requirements2_khr = auto_cast addr
    }
    if vma_vulkan_procs.get_image_memory_requirements2_khr == nil && vk.GetDeviceProcAddr != nil {
        addr := vk.GetDeviceProcAddr(ctx.device, "vkGetImageMemoryRequirements2")
        if addr == nil do addr = vk.GetDeviceProcAddr(ctx.device, "vkGetImageMemoryRequirements2KHR")
        vma_vulkan_procs.get_image_memory_requirements2_khr = auto_cast addr
    }
    if vma_vulkan_procs.bind_buffer_memory2_khr == nil && vk.GetDeviceProcAddr != nil {
        addr := vk.GetDeviceProcAddr(ctx.device, "vkBindBufferMemory2")
        if addr == nil do addr = vk.GetDeviceProcAddr(ctx.device, "vkBindBufferMemory2KHR")
        vma_vulkan_procs.bind_buffer_memory2_khr = auto_cast addr
    }
    if vma_vulkan_procs.bind_image_memory2_khr == nil && vk.GetDeviceProcAddr != nil {
        addr := vk.GetDeviceProcAddr(ctx.device, "vkBindImageMemory2")
        if addr == nil do addr = vk.GetDeviceProcAddr(ctx.device, "vkBindImageMemory2KHR")
        vma_vulkan_procs.bind_image_memory2_khr = auto_cast addr
    }
    if vma_vulkan_procs.get_physical_device_memory_properties2_khr == nil && vk.GetInstanceProcAddr != nil {
        addr := vk.GetInstanceProcAddr(ctx.instance, "vkGetPhysicalDeviceMemoryProperties2")
        if addr == nil do addr = vk.GetInstanceProcAddr(ctx.instance, "vkGetPhysicalDeviceMemoryProperties2KHR")
        vma_vulkan_procs.get_physical_device_memory_properties2_khr = auto_cast addr
    }
    ok_vma := vma.create_allocator({
        flags = { .Buffer_Device_Address },
        instance = ctx.instance,
        vulkan_api_version = vk.API_VERSION_1_3,
        physical_device = ctx.phys_device,
        device = ctx.device,
        vulkan_functions = &vma_vulkan_procs,
    }, &ctx.vma_allocator)
    assert(ok_vma == .SUCCESS)

    // Init cmd_bufs_sem_vals
    {
        for type in Queue {
            ctx.cmd_bufs_sems[type] = semaphore_create(0)
        }
    }

    return true

    // From GLFW: https://github.com/glfw/glfw
    get_instance_proc_address :: proc "system"(p: rawptr, name: cstring) -> rawptr
    {
        context = runtime.default_context()

        vk_dll_path: string
        when ODIN_OS == .Windows {
            vk_dll_path = "vulkan-1.dll"
        } else when ODIN_OS == .OpenBSD || ODIN_OS == .NetBSD {
            vk_dll_path = "libvulkan.so"
        } else when ODIN_OS == .Linux {
            vk_dll_path = "libvulkan.so.1"
        } else when ODIN_OS == .Darwin {
            vk_dll_path = "libvulkan.1.dylib"
        } else do #panic("OS not supported!")

        @(static) vk_dll: dynlib.Library
        if vk_dll == nil
        {
            did_load: bool
            vk_dll, did_load = dynlib.load_library(vk_dll_path, allocator = context.allocator)
            vk.GetInstanceProcAddr = auto_cast dynlib.symbol_address(vk_dll, "vkGetInstanceProcAddr", allocator = context.allocator)
            assert(did_load)
        }

        // NOTE: Vulkan 1.0 and 1.1 vkGetInstanceProcAddr cannot return itself
        if name == "vkGetInstanceProcAddr" do return auto_cast vk.GetInstanceProcAddr

        addr := vk.GetInstanceProcAddr(auto_cast p, name);
        if addr == nil {
            addr = auto_cast dynlib.symbol_address(vk_dll, string(name), allocator = context.allocator)
        }
        return auto_cast addr
    }

    supports_layer :: proc(name: cstring) -> bool
    {
        scratch, _ := acquire_scratch()

        count: u32
        vk_check(vk.EnumerateInstanceLayerProperties(&count, nil))
        available_layers := make([]vk.LayerProperties, count, allocator = scratch)
        vk_check(vk.EnumerateInstanceLayerProperties(&count, raw_data(available_layers)))

        for &available in available_layers {
            if name == cstring(&available.layerName[0]) do return true
        }

        return false
    }

    supports_instance_extension :: proc(name: cstring) -> bool
    {
        scratch, _ := acquire_scratch()

        count: u32
        vk_check(vk.EnumerateInstanceExtensionProperties(nil, &count, nil))
        available_extensions := make([]vk.ExtensionProperties, count, allocator = scratch)
        vk_check(vk.EnumerateInstanceExtensionProperties(nil, &count, raw_data(available_extensions)))

        for &available in available_extensions {
            if name == cstring(&available.extensionName[0]) do return true
        }
        return false
    }

    supports_device_extension :: proc(name: cstring) -> bool
    {
        scratch, _ := acquire_scratch()

        count: u32
        vk_check(vk.EnumerateDeviceExtensionProperties(ctx.phys_device, nil, &count, nil))
        available_extensions := make([]vk.ExtensionProperties, count, allocator = scratch)
        vk_check(vk.EnumerateDeviceExtensionProperties(ctx.phys_device, nil, &count, raw_data(available_extensions)))
        for &available in available_extensions {
            if name == cstring(&available.extensionName[0]) do return true
        }
        return false
    }

    log_unsupported_extensions :: proc(unsupported: []cstring, loc: runtime.Source_Code_Location)
    {
        if len(unsupported) <= 0 do return
        if !ctx.validation do return

        sb := strings.builder_make_none()
        defer strings.builder_destroy(&sb)

        strings.write_string(&sb, "This device is not supported by no_gfx as it is missing the following critical Vulkan extensions:\n")
        for ext in unsupported
        {
            strings.write_string(&sb, string(ext))
            strings.write_string(&sb, "\n")
        }
        log.error(strings.to_string(sb), location = loc)
    }
}

@(private="file")
get_tls :: proc() -> ^Thread_Local_Context
{
    @(thread_local)
    tls_ctx: ^Thread_Local_Context

    if tls_ctx != nil do return tls_ctx

    tls_ctx = new(Thread_Local_Context)

    for queue in Queue
    {
        queue_info := ctx.queues[queue]
        cmd_pool_ci := vk.CommandPoolCreateInfo {
            sType = .COMMAND_POOL_CREATE_INFO,
            queueFamilyIndex = queue_info.family_idx,
            flags = { .TRANSIENT, .RESET_COMMAND_BUFFER }
        }
        vk_check(vk.CreateCommandPool(ctx.device, &cmd_pool_ci, nil, &tls_ctx.pools[queue]))

        priority_queue.init(
            &tls_ctx.free_buffers[queue],
            less = proc(a,b: Free_Command_Buffer) -> bool {
                return a.timeline_value < b.timeline_value
            },
            swap = proc(q: []Free_Command_Buffer, i, j: int) {
                q[i], q[j] = q[j], q[i]
            }
        )
    }

    if sync.guard(&ctx.tls_lock) do append(&ctx.tls_contexts, tls_ctx)

    return tls_ctx
}

_cleanup :: proc(loc := #caller_location)
{
    scratch, _ := acquire_scratch()

    {
        // Cleanup all TLS contexts
        for tls_context in ctx.tls_contexts {
            if tls_context != nil {
                for type in Queue {
                    vk.DestroyCommandPool(ctx.device, tls_context.pools[type], nil)
                    priority_queue.destroy(&tls_context.free_buffers[type])
                }

                for sampler in tls_context.samplers
                {
                    vk.DestroySampler(ctx.device, sampler.sampler, nil)
                }

                free(tls_context)
            }
        }

        delete(ctx.tls_contexts)
        ctx.tls_contexts = {}
    }

    destroy_swapchain(&ctx.swapchain)

    // Common resources
    {
        for &layout in ctx.desc_layouts {
            vk.DestroyDescriptorSetLayout(ctx.device, layout, nil)
        }
        delete(ctx.desc_layouts)

        vk.DestroyPipelineLayout(ctx.device, ctx.common_pipeline_layout_graphics, nil)
        vk.DestroyPipelineLayout(ctx.device, ctx.common_pipeline_layout_compute, nil)
    }

    for semaphore in ctx.cmd_bufs_sems {
        semaphore_destroy(semaphore)
    }

    vma.destroy_allocator(ctx.vma_allocator)

    // Check for leaked resources
    can_destroy_device := true
    if ctx.validation
    {
        {
            sb := strings.builder_make_none()
            defer strings.builder_destroy(&sb)

            leaked_allocs := pool_get_alive_list(&ctx.allocs, scratch)
            if len(leaked_allocs) > 0
            {
                strings.write_string(&sb, "There are leaked allocations present:\n")
                can_destroy_device = false

                for leaked, i in leaked_allocs
                {
                    fmt.sbprintf(&sb, "Allocated at: %v", leaked.meta.created_at)
                    if i < len(leaked_allocs) - 1 {
                        fmt.sbprintln(&sb, "")
                    }
                }

                log.error(strings.to_string(sb), location = loc)
            }
        }

        print_leaked_resources(&ctx.textures,   "Texture_Handle", &can_destroy_device, loc)
        print_leaked_resources(&ctx.bvhs,       "BVH",            &can_destroy_device, loc)
        print_leaked_resources(&ctx.shaders,    "Shader",         &can_destroy_device, loc)
        print_leaked_resources(&ctx.semaphores, "Semaphore",      &can_destroy_device, loc)

        print_leaked_resources :: proc(pool: ^Resource_Pool($Handle_T, $Info_T), handle_name: string, can_destroy_device: ^bool, loc: runtime.Source_Code_Location)
        {
            sb := strings.builder_make_none()
            defer strings.builder_destroy(&sb)

            scratch, _ := acquire_scratch()
            leaked_res := pool_get_alive_list(pool, scratch)
            if len(leaked_res) > 0
            {
                fmt.sbprintfln(&sb, "There are leaked %vs present:", handle_name)
                can_destroy_device^ = false

                for leaked, i in leaked_res
                {
                    if leaked.meta.name == "" {
                        fmt.sbprintf(&sb, "(no name), Created at: %v", leaked.meta.created_at)
                    } else {
                        fmt.sbprintf(&sb, "\"%v\", Created at: %v", leaked.meta.name, leaked.meta.created_at)
                    }

                    if i < len(leaked_res) - 1 {
                        fmt.sbprintln(&sb, "")
                    }
                }

                log.error(strings.to_string(sb), location = loc)
            }
        }

        // Destroy pools
        pool_destroy(&ctx.allocs)
        pool_destroy(&ctx.textures)
        pool_destroy(&ctx.bvhs)
        pool_destroy(&ctx.shaders)
        pool_destroy(&ctx.command_buffers)
        pool_destroy(&ctx.semaphores)
    }

    if can_destroy_device {
        vk.DestroyDevice(ctx.device, nil)
    } else {
        runtime.debug_trap()  // Break here so user has a chance to read the last error logs.
    }
}

_wait_idle :: proc()
{
    if sync.guard(&ctx.queue_lock) do vk.DeviceWaitIdle(ctx.device)
}

_swapchain_create :: proc(surface: vk.SurfaceKHR, init_size: [2]u32, frames_in_flight: u32, present_mode: Present_Mode = {})
{
    if ctx.swapchain.handle != {} {
        queue_wait_idle(.Main)
        destroy_swapchain(&ctx.swapchain)
    }

    ctx.swapchain_desc = {
        frames_in_flight = frames_in_flight,
        width = init_size.x,
        height = init_size.y,
        present_mode = present_mode,
    }
    ctx.surface = surface

    // NOTE: surface_caps.currentExtent could be max(u32)!!!
    surface_caps: vk.SurfaceCapabilitiesKHR
    vk_check(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(ctx.phys_device, ctx.surface, &surface_caps))
    extent := surface_caps.currentExtent
    if extent.width == max(u32) || extent.height == max(u32) {
        extent.width = init_size[0]
        extent.height = init_size[1]
    }
    assert(extent.width != max(u32) && extent.height != max(u32))

    ctx.swapchain_desc.width = max(extent.width, 1)
    ctx.swapchain_desc.height = max(extent.height, 1)
    ctx.swapchain = create_swapchain(ctx.swapchain_desc)
}

_swapchain_resize :: proc(size: [2]u32)
{
    old_handle := ctx.swapchain.handle
    if ctx.swapchain.handle != {} {
        queue_wait_idle(.Main)
        destroy_swapchain(&ctx.swapchain, free_handle = false)
    }

    ctx.swapchain_desc.width = size.x
    ctx.swapchain_desc.height = size.y

    // NOTE: surface_caps.currentExtent could be max(u32)!!!
    surface_caps: vk.SurfaceCapabilitiesKHR
    vk_check(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(ctx.phys_device, ctx.surface, &surface_caps))
    extent := surface_caps.currentExtent
    if extent.width == max(u32) || extent.height == max(u32) {
        extent.width = size[0]
        extent.height = size[1]
    }
    assert(extent.width != max(u32) && extent.height != max(u32))

    ctx.swapchain_desc.width = max(extent.width, 1)
    ctx.swapchain_desc.height = max(extent.height, 1)
    ctx.swapchain = create_swapchain(ctx.swapchain_desc, old_handle)

    if old_handle != {} {
        vk.DestroySwapchainKHR(ctx.device, old_handle, nil)
    }
}

_swapchain_acquire_next :: proc() -> Texture
{
    fence_ci := vk.FenceCreateInfo { sType = .FENCE_CREATE_INFO }
    fence: vk.Fence
    vk_check(vk.CreateFence(ctx.device, &fence_ci, nil, &fence))
    defer vk.DestroyFence(ctx.device, fence, nil)

    res := vk.AcquireNextImageKHR(ctx.device, ctx.swapchain.handle, max(u64), {}, fence, &ctx.swapchain_image_idx)
    if res == .SUBOPTIMAL_KHR do log.warn("Suboptimal swapchain acquire!")
    if res != .SUCCESS && res != .SUBOPTIMAL_KHR {
        vk_check(res)
    }

    vk_check(vk.WaitForFences(ctx.device, 1, &fence, true, max(u64)))

    // Transition layout from swapchain
    {
        cmd_buf := commands_begin(.Main)
        vk_cmd_buf := vk_get_command_buffer(cmd_buf)

        transition := vk.ImageMemoryBarrier2 {
            sType = .IMAGE_MEMORY_BARRIER_2,
            image = ctx.swapchain.images[ctx.swapchain_image_idx],
            subresourceRange = {
                aspectMask = { .COLOR },
                levelCount = 1,
                layerCount = 1,
            },
            oldLayout = .UNDEFINED,
            newLayout = .GENERAL,
            srcStageMask = { .ALL_COMMANDS },
            srcAccessMask = { .MEMORY_WRITE },
            dstStageMask = { .COLOR_ATTACHMENT_OUTPUT },
            dstAccessMask = { .MEMORY_READ, .MEMORY_WRITE },
        }
        vk.CmdPipelineBarrier2(vk_cmd_buf, &vk.DependencyInfo {
            sType = .DEPENDENCY_INFO,
            imageMemoryBarrierCount = 1,
            pImageMemoryBarriers = &transition,
        })

        queue_submit(.Main, {cmd_buf})
    }

    return Texture {
        type = .D2,
        dimensions = { ctx.swapchain_desc.width, ctx.swapchain_desc.height, 1 },
        format = .BGRA8_Unorm,
        mip_count = 1,
        sample_count = 1,
        layer_count = 1,
        handle = ctx.swapchain.texture_handles[ctx.swapchain_image_idx],
    }
}

_swapchain_present :: proc(queue: Queue, sem_wait: Semaphore, wait_value: u64)
{
    queue_info := ctx.queues[queue]
    vk_queue := queue_info.handle

    present_semaphore := ctx.swapchain.present_semaphores[ctx.swapchain_image_idx]
    vk_present_semaphore := vk_get_semaphore(present_semaphore)

    // NOTE: Workaround for the fact that swapchain presentation
    // only supports binary semaphores.
    // wait on sem_wait on wait_value and signal ctx.binary_sem
    {
        cmd_buf := commands_begin(queue)
        vk_cmd_buf := vk_get_command_buffer(cmd_buf)

        // Switch to optimal layout for presentation (this is mandatory)
        {
            transition := vk.ImageMemoryBarrier2 {
                sType = .IMAGE_MEMORY_BARRIER_2,
                image = ctx.swapchain.images[ctx.swapchain_image_idx],
                subresourceRange = {
                    aspectMask = { .COLOR },
                    levelCount = 1,
                    layerCount = 1,
                },
                oldLayout = .GENERAL,
                newLayout = .PRESENT_SRC_KHR,
                srcStageMask = { .ALL_COMMANDS },
                srcAccessMask = { .MEMORY_WRITE },
                dstStageMask = { .COLOR_ATTACHMENT_OUTPUT },
                dstAccessMask = { .MEMORY_READ },
            }
            vk.CmdPipelineBarrier2(vk_cmd_buf, &vk.DependencyInfo {
                sType = .DEPENDENCY_INFO,
                imageMemoryBarrierCount = 1,
                pImageMemoryBarriers = &transition,
            })
        }

        cmd_add_wait_semaphore(cmd_buf, sem_wait, wait_value)
        cmd_add_signal_semaphore(cmd_buf, present_semaphore, 0)  // This is a binary semaphore, so the value is unused here.
        queue_submit(queue, { cmd_buf })
    }

    if sync.guard(&ctx.queue_lock)
    {
        res := vk.QueuePresentKHR(vk_queue, &{
            sType = .PRESENT_INFO_KHR,
            swapchainCount = 1,
            waitSemaphoreCount = 1,
            pWaitSemaphores = &vk_present_semaphore,
            pSwapchains = &ctx.swapchain.handle,
            pImageIndices = &ctx.swapchain_image_idx,
        })
        if res == .SUBOPTIMAL_KHR do log.warn("Suboptimal swapchain present!")
        if res != .SUCCESS && res != .SUBOPTIMAL_KHR {
            vk_check(res)
        }
    }
}

_features_available :: proc() -> Features
{
    return ctx.features
}

_device_limits :: proc() -> Device_Limits
{
    return {
        max_anisotropy = max(1.0, ctx.physical_properties.props2.properties.limits.maxSamplerAnisotropy),
    }
}

// Memory

_mem_alloc_raw :: proc(#any_int el_size, #any_int el_count, #any_int align: i64, mem_type := Memory.Default, loc := #caller_location) -> ptr
{
    bytes := el_size * el_count
    if bytes == 0 do return {}

    vma_usage: vma.Memory_Usage
    properties: vk.MemoryPropertyFlags
    switch mem_type
    {
        case .Default:
        {
            properties = { .HOST_VISIBLE, .HOST_COHERENT }
            vma_usage = .Cpu_To_Gpu
        }
        case .GPU:
        {
            properties = { .DEVICE_LOCAL }
            vma_usage = .Gpu_Only
        }
        case .Readback:
        {
            properties = { .HOST_VISIBLE, .HOST_CACHED, .HOST_COHERENT }
            vma_usage = .Gpu_To_Cpu
        }
    }

    buf_usage: vk.BufferUsageFlags
    buf_usage = { .SHADER_DEVICE_ADDRESS, .STORAGE_BUFFER, .INDEX_BUFFER, .TRANSFER_SRC, .TRANSFER_DST, .INDIRECT_BUFFER }
    if .Raytracing in ctx.features {
        buf_usage += { .ACCELERATION_STRUCTURE_STORAGE_KHR, .ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_KHR }
    }

    buf_ci := vk.BufferCreateInfo {
        sType = .BUFFER_CREATE_INFO,
        size = cast(vk.DeviceSize) bytes,
        usage = buf_usage,
        sharingMode = .EXCLUSIVE,
    }

    buf: vk.Buffer
    vk_check(vk.CreateBuffer(ctx.device, &buf_ci, nil, &buf))

    mem_requirements: vk.MemoryRequirements
    vk.GetBufferMemoryRequirements(ctx.device, buf, &mem_requirements)

    mem_requirements.alignment = vk.DeviceSize(max(i64(mem_requirements.alignment), align))

    alloc_ci := vma.Allocation_Create_Info {
        flags = vma.Allocation_Create_Flags { .Mapped } if mem_type != .GPU else {},
        usage = vma_usage,
        required_flags = properties,
    }
    alloc: vma.Allocation
    vma_alloc_info: vma.Allocation_Info
    vk_check(vma.allocate_memory(ctx.vma_allocator, mem_requirements, alloc_ci, &alloc, &vma_alloc_info))

    vk_check(vma.bind_buffer_memory(ctx.vma_allocator, alloc, buf))

    p: ptr
    if mem_type != .GPU do p.cpu = vma_alloc_info.mapped_data

    info := vk.BufferDeviceAddressInfo {
        sType = .BUFFER_DEVICE_ADDRESS_INFO,
        buffer = buf
    }
    addr := vk.GetBufferDeviceAddress(ctx.device, &info)
    p.gpu.ptr = cast(rawptr) cast(uintptr) addr

    alloc_info := Alloc_Info {
        allocation = alloc,
        buf_handle = buf,
        cpu = p.cpu,
        gpu = p.gpu.ptr,
        align = u32(align),
        buf_size = cast(vk.DeviceSize) bytes,
    }
    alloc_handle := pool_add(&ctx.allocs, alloc_info, { created_at = loc })
    end_ptr := rawptr(uintptr(p.gpu.ptr) + uintptr(bytes))
    alloc_impl := Alloc_Impl_Info { end_ptr, alloc_handle }
    p.gpu._impl = transmute([2]u64) alloc_impl
    return p
}

_mem_suballoc :: proc(addr: ptr, offset, el_size, el_count: i64, loc := #caller_location) -> ptr
{
    bytes := el_size * el_count

    if ctx.validation
    {
        ok := true
        if bytes != 0 {
            ok &= check_ptr(addr, "addr", loc)
        }
        if !ok do return {}
    }

    if bytes == 0 do return {}

    suballoc_p := addr
    if suballoc_p.cpu != nil {
        suballoc_p.cpu = auto_cast(uintptr(suballoc_p.cpu) + uintptr(offset))
    }
    suballoc_p.gpu.ptr = auto_cast(uintptr(suballoc_p.gpu.ptr) + uintptr(offset))

    // Update internal _impl.
    addr_impl := transmute(Alloc_Impl_Info) addr._impl
    addr_impl.range_end = rawptr(uintptr(suballoc_p.gpu.ptr) + uintptr(bytes))
    suballoc_p._impl = transmute([2]u64) addr_impl

    return suballoc_p
}

_mem_free_raw :: proc(addr: gpuptr, loc := #caller_location)
{
    alloc_impl := transmute(Alloc_Impl_Info) addr._impl
    alloc := alloc_impl.handle

    if ctx.validation
    {
        ok := true
        if addr != {} {
            ok &= check_ptr(addr, "addr", loc)
            ok &= check_ptr_must_not_be_suballoc(addr, "addr", loc)
        }
        if !ok do return
    }

    if addr == {} do return

    alloc_info := pool_get(&ctx.allocs, alloc)
    vma.destroy_buffer(ctx.vma_allocator, alloc_info.buf_handle, alloc_info.allocation)
    pool_remove(&ctx.allocs, alloc)
}

// Textures
_texture_size_and_align :: proc(desc: Texture_Desc, loc := #caller_location) -> (size: u64, align: u64)
{
    desc_clean := texture_desc_cleanup(desc)

    image_ci := to_vk_image_create_info(desc_clean)

    plane_aspect := to_vk_image_aspect_flags(desc_clean.format)

    info := vk.DeviceImageMemoryRequirements {
        sType = .DEVICE_IMAGE_MEMORY_REQUIREMENTS,
        pCreateInfo = &image_ci,
        planeAspect = plane_aspect,
    }

    mem_requirements_2 := vk.MemoryRequirements2 { sType = .MEMORY_REQUIREMENTS_2 }
    vk.GetDeviceImageMemoryRequirements(ctx.device, &info, &mem_requirements_2)

    mem_requirements := mem_requirements_2.memoryRequirements
    return u64(mem_requirements.size), u64(mem_requirements.alignment)
}

_texture_create :: proc(desc: Texture_Desc, storage: gpuptr, queue: Queue = .Main, signal_sem: Semaphore = {}, signal_value: u64 = 0, name := "", loc := #caller_location) -> Texture
{
    if ctx.validation
    {
        ok := true
        ok &= check_ptr(storage, "storage", loc)
        if !ok do return {}
    }

    desc_clean := texture_desc_cleanup(desc)

    queue_to_use := queue
    alloc_impl := transmute(Alloc_Impl_Info) storage._impl
    alloc_info := pool_get(&ctx.allocs, alloc_impl.handle)

    image: vk.Image
    offset := uintptr(storage.ptr) - uintptr(alloc_info.gpu)
    image_ci := to_vk_image_create_info(desc_clean)
    vk_check(vma.create_aliasing_image2(ctx.vma_allocator, alloc_info.allocation, vk.DeviceSize(offset), image_ci, &image))

    plane_aspect := to_vk_image_aspect_flags(desc_clean.format)

    // Transition layout from UNDEFINED to GENERAL
    {
        cmd_buf := commands_begin(queue_to_use)
        vk_cmd_buf := vk_get_command_buffer(cmd_buf)

        transition := vk.ImageMemoryBarrier2 {
            sType = .IMAGE_MEMORY_BARRIER_2,
            image = image,
            subresourceRange = {
                aspectMask = plane_aspect,
                levelCount = desc_clean.mip_count,
                layerCount = desc_clean.layer_count,
            },
            oldLayout = .UNDEFINED,
            newLayout = .GENERAL,
            srcStageMask = { .ALL_COMMANDS },
            srcAccessMask = { .MEMORY_WRITE },
            dstStageMask = { .ALL_COMMANDS },
            dstAccessMask = { .MEMORY_READ, .MEMORY_WRITE },
        }
        vk.CmdPipelineBarrier2(vk_cmd_buf, &vk.DependencyInfo {
            sType = .DEPENDENCY_INFO,
            imageMemoryBarrierCount = 1,
            pImageMemoryBarriers = &transition,
        })

        if signal_sem != {} do cmd_add_signal_semaphore(cmd_buf, signal_sem, signal_value)
        queue_submit(queue_to_use, { cmd_buf })
    }

    vk_set_debug_name(name, u64(image), .IMAGE)

    tex_info := Texture_Info { handle = image, owns_image = true }
    return Texture {
        type = desc_clean.type,
        dimensions = desc_clean.dimensions,
        format = desc_clean.format,
        mip_count = desc_clean.mip_count,
        sample_count = desc_clean.sample_count,
        layer_count = desc_clean.layer_count,
        handle = pool_add(&ctx.textures, tex_info, { name = name, created_at = loc } )
    }
}

_texture_destroy :: proc(texture: Texture, loc := #caller_location)
{
    if ctx.validation
    {
        ok := true
        ok &= pool_check(&ctx.textures, texture.handle, "texture", loc)
        if !ok do return
    }

    tex_info := pool_get(&ctx.textures, texture.handle)
    vk_image := tex_info.handle

    for view in tex_info.views {
        vk.DestroyImageView(ctx.device, view.view, nil)
    }
    delete(tex_info.views)
    tex_info.views = {}

    if tex_info.owns_image {
        vk.DestroyImage(ctx.device, vk_image, nil)
    }
    pool_remove(&ctx.textures, texture.handle)
}

@(private="file")
get_or_add_image_view :: proc(texture: Texture_Handle, info: vk.ImageViewCreateInfo) -> vk.ImageView
{
    sync.guard(pool_get_lock(&ctx.textures, texture))
    tex_info := pool_get_ptr(&ctx.textures, texture)

    for view in tex_info.views
    {
        if view.info == info {
            return view.view
        }
    }

    image_view: vk.ImageView
    view_ci := info
    vk_check(vk.CreateImageView(ctx.device, &view_ci, nil, &image_view))
    append(&tex_info.views, Image_View_Info { info, image_view })
    return image_view
}

@(private="file")
get_or_add_sampler :: proc(info: vk.SamplerCreateInfo) -> vk.Sampler
{
    tls := get_tls()

    for sampler in tls.samplers
    {
        if sampler.info == info {
            return sampler.sampler
        }
    }

    sampler: vk.Sampler
    sampler_ci := info
    vk_check(vk.CreateSampler(ctx.device, &sampler_ci, nil, &sampler))
    append(&tls.samplers, Sampler_Info { info, sampler })
    return sampler
}

_texture_descriptor :: proc(texture: Texture, view_desc: Texture_View_Desc, loc := #caller_location) -> Texture_Descriptor
{
    if ctx.validation
    {
        ok := true
        ok &= pool_check(&ctx.textures, texture.handle, "texture", loc)
        if !ok do return {}
    }

    tex_info := pool_get(&ctx.textures, texture.handle)
    vk_image := tex_info.handle

    view_desc_clean := texture_view_desc_cleanup(texture, view_desc)

    plane_aspect := to_vk_image_aspect_flags(view_desc_clean.format)

    image_view_ci := vk.ImageViewCreateInfo {
        sType = .IMAGE_VIEW_CREATE_INFO,
        image = vk_image,
        viewType = to_vk_texture_view_type(view_desc_clean.type),
        format = to_vk_texture_format(view_desc_clean.format),
        subresourceRange = {
            aspectMask = plane_aspect,
            levelCount = texture.mip_count,
            layerCount = texture.layer_count,
        }
    }
    view := get_or_add_image_view(texture.handle, image_view_ci)

    return { transmute(u64) texture.handle, cast(u64) view }
}

_texture_rw_descriptor :: proc(texture: Texture, view_desc: Texture_View_Desc, loc := #caller_location) -> Texture_Descriptor
{
    if ctx.validation
    {
        ok := true
        ok &= pool_check(&ctx.textures, texture.handle, "texture", loc)
        if !ok do return {}
    }

    tex_info := pool_get(&ctx.textures, texture.handle)
    vk_image := tex_info.handle

    view_desc_clean := texture_view_desc_cleanup(texture, view_desc)

    plane_aspect := to_vk_image_aspect_flags(view_desc_clean.format)

    image_view_ci := vk.ImageViewCreateInfo {
        sType = .IMAGE_VIEW_CREATE_INFO,
        image = vk_image,
        viewType = to_vk_texture_view_type(view_desc_clean.type),
        format = to_vk_texture_format(view_desc_clean.format),
        subresourceRange = {
            aspectMask = plane_aspect,
            levelCount = texture.mip_count,
            layerCount = texture.layer_count,
        }
    }
    view := get_or_add_image_view(texture.handle, image_view_ci)

    return { transmute(u64) texture.handle, cast(u64) view }
}

_sampler_descriptor :: proc(sampler_desc: Sampler_Desc, loc := #caller_location) -> Sampler_Descriptor
{
    if sampler_desc.max_anisotropy != 0.0 {
        ensure(
            sampler_desc.max_anisotropy >= 1.0 &&
            sampler_desc.max_anisotropy <= ctx.physical_properties.props2.properties.limits.maxSamplerAnisotropy,
            "Sampler anisotropy out of range. Call gpu.device_limits() to get the supported maximum anisotropy.",
        )
    }

    sampler_ci := vk.SamplerCreateInfo {
        sType = .SAMPLER_CREATE_INFO,
        magFilter = to_vk_filter(sampler_desc.mag_filter),
        minFilter = to_vk_filter(sampler_desc.min_filter),
        mipmapMode = to_vk_mipmap_filter(sampler_desc.mip_filter),
        addressModeU = to_vk_address_mode(sampler_desc.address_mode_u),
        addressModeV = to_vk_address_mode(sampler_desc.address_mode_v),
        addressModeW = to_vk_address_mode(sampler_desc.address_mode_w),
        mipLodBias = sampler_desc.mip_lod_bias,
        minLod = sampler_desc.min_lod,
        maxLod = sampler_desc.max_lod if sampler_desc.max_lod != 0.0 else vk.LOD_CLAMP_NONE,
        anisotropyEnable = b32(sampler_desc.max_anisotropy > 1.0),
        maxAnisotropy = sampler_desc.max_anisotropy,
    }
    sampler := get_or_add_sampler(sampler_ci)

    return transmute(Sampler_Descriptor) sampler
}

_desc_heap_create :: proc(texture_count: u32 = 65536,
                          texture_rw_count: u32 = 65536,
                          sampler_count: u32 = 32,
                          bvh_count: u32 = 16,
                          name := "", loc := #caller_location) -> Descriptor_Heap
{
    if ctx.validation
    {
        ok := true
        if texture_count > Max_Textures {
            log.errorf("'texture_count' is %v and is greater than the maximum allowed by no_gfx (%v)", texture_count, Max_Textures, location = loc)
            ok = false
        }
        if texture_rw_count > Max_Textures {
            log.errorf("'texture_rw_count' is %v and is greater than the maximum allowed by no_gfx (%v)", texture_rw_count, Max_Textures, location = loc)
            ok = false
        }
        if sampler_count > Max_Samplers {
            log.errorf("'sampler_count' is %v and is greater than the maximum allowed by no_gfx (%v)", sampler_count, Max_Samplers, location = loc)
            ok = false
        }
        if bvh_count > Max_BVHs {
            log.errorf("'bvh_count' is %v and is greater than the maximum allowed by no_gfx (%v)", bvh_count, Max_BVHs, location = loc)
            ok = false
        }
        if !ok do return {}
    }

    pool_sizes := []vk.DescriptorPoolSize {
        { type = .SAMPLED_IMAGE, descriptorCount = Max_Textures },
        { type = .STORAGE_IMAGE, descriptorCount = Max_Textures },
        { type = .SAMPLER,       descriptorCount = Max_Samplers },
        { type = .ACCELERATION_STRUCTURE_KHR, descriptorCount = Max_BVHs },
    }
    desc_pool_ci := vk.DescriptorPoolCreateInfo {
        sType = .DESCRIPTOR_POOL_CREATE_INFO,
        flags = { .FREE_DESCRIPTOR_SET, .UPDATE_AFTER_BIND },
        maxSets = 4,
        poolSizeCount = u32(len(ctx.desc_layouts)),
        pPoolSizes = raw_data(pool_sizes)
    }
    desc_pool: vk.DescriptorPool
    vk_check(vk.CreateDescriptorPool(ctx.device, &desc_pool_ci, nil, &desc_pool))

    alloc_info := vk.DescriptorSetAllocateInfo {
        sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
        descriptorPool = desc_pool,
        descriptorSetCount = u32(len(ctx.desc_layouts)),  // NOTE: This is 3 if the device doesn't support RT
        pSetLayouts = raw_data(ctx.desc_layouts),
    }

    desc_sets: [4]vk.DescriptorSet
    vk_check(vk.AllocateDescriptorSets(ctx.device, &alloc_info, &desc_sets[0]))

    desc_heap_info := Descriptor_Heap_Info {
        textures = desc_sets[0],
        textures_rw = desc_sets[1],
        samplers = desc_sets[2],
        bvhs = desc_sets[3],
        desc_pool = desc_pool,
    }
    return pool_add(&ctx.desc_heaps, desc_heap_info, { created_at = loc, name = name })
}

_desc_heap_destroy :: proc(heap: Descriptor_Heap, loc := #caller_location)
{
    if ctx.validation
    {
        ok := true
        ok &= pool_check(&ctx.desc_heaps, heap, "heap", loc)
        if !ok do return
    }

    heap_info := pool_get(&ctx.desc_heaps, heap)

    to_free := [4]vk.DescriptorSet {
        heap_info.textures, heap_info.textures_rw, heap_info.samplers, heap_info.bvhs
    }
    vk_check(vk.FreeDescriptorSets(ctx.device, heap_info.desc_pool, u32(len(ctx.desc_layouts)), &to_free[0]))

    vk.DestroyDescriptorPool(ctx.device, heap_info.desc_pool, nil)

    pool_remove(&ctx.desc_heaps, heap)
}

_desc_heap_set_textures :: proc(heap: Descriptor_Heap, start_idx: u32, textures: []Texture_Descriptor, loc := #caller_location)
{
    if ctx.validation
    {
        ok := true
        ok &= pool_check(&ctx.desc_heaps, heap, "heap", loc)
        for desc, i in textures {
            ok &= check_texture_descriptor(desc, "textures", i, loc)
        }
        if !ok do return
    }

    heap_info := pool_get(&ctx.desc_heaps, heap)

    scratch, _ := acquire_scratch()
    image_infos := make([]vk.DescriptorImageInfo, len(textures), allocator = scratch)
    for &info, i in image_infos
    {
        info = {
            sampler = {},
            imageView = texture_descriptor_get_vk_view(textures[i]),
            imageLayout = .GENERAL,
        }
    }

    write := vk.WriteDescriptorSet {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = heap_info.textures,
        dstBinding = 0,
        dstArrayElement = start_idx,
        descriptorCount = u32(len(textures)),
        descriptorType = .SAMPLED_IMAGE,
        pImageInfo = raw_data(image_infos),
    }
    vk.UpdateDescriptorSets(ctx.device, 1, &write, 0, nil)
}

_desc_heap_set_textures_rw :: proc(heap: Descriptor_Heap, start_idx: u32, textures: []Texture_Descriptor, loc := #caller_location)
{
    if ctx.validation
    {
        ok := true
        ok &= pool_check(&ctx.desc_heaps, heap, "heap", loc)
        if !ok do return
    }

    heap_info := pool_get(&ctx.desc_heaps, heap)

    scratch, _ := acquire_scratch()
    image_infos := make([]vk.DescriptorImageInfo, len(textures), allocator = scratch)
    for &info, i in image_infos
    {
        info = {
            sampler = {},
            imageView = texture_descriptor_get_vk_view(textures[i]),
            imageLayout = .GENERAL,
        }
    }

    write := vk.WriteDescriptorSet {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = heap_info.textures_rw,
        dstBinding = 0,
        dstArrayElement = start_idx,
        descriptorCount = u32(len(textures)),
        descriptorType = .STORAGE_IMAGE,
        pImageInfo = raw_data(image_infos),
    }
    vk.UpdateDescriptorSets(ctx.device, 1, &write, 0, nil)
}

_desc_heap_set_samplers :: proc(heap: Descriptor_Heap, start_idx: u32, samplers: []Sampler_Descriptor, loc := #caller_location)
{
    if ctx.validation
    {
        ok := true
        ok &= pool_check(&ctx.desc_heaps, heap, "heap", loc)
        if !ok do return
    }

    heap_info := pool_get(&ctx.desc_heaps, heap)

    scratch, _ := acquire_scratch()
    sampler_infos := make([]vk.DescriptorImageInfo, len(samplers), allocator = scratch)
    for &info, i in sampler_infos
    {
        info = {
            sampler = transmute(vk.Sampler) samplers[i],
            imageView = {},
            imageLayout = {},
        }
    }

    write := vk.WriteDescriptorSet {
        sType = .WRITE_DESCRIPTOR_SET,
        dstSet = heap_info.samplers,
        dstBinding = 0,
        dstArrayElement = start_idx,
        descriptorCount = u32(len(samplers)),
        descriptorType = .SAMPLER,
        pImageInfo = raw_data(sampler_infos)
    }
    vk.UpdateDescriptorSets(ctx.device, 1, &write, 0, nil)
}

_desc_heap_set_bvhs :: proc(heap: Descriptor_Heap, start_idx: u32, bvhs: []BVH, loc := #caller_location)
{
    if ctx.validation
    {
        ok := true
        ok &= pool_check(&ctx.desc_heaps, heap, "heap", loc)
        if !ok do return
    }

    heap_info := pool_get(&ctx.desc_heaps, heap)

    scratch, _ := acquire_scratch()
    vk_bvhs := make([]vk.AccelerationStructureKHR, len(bvhs), allocator = scratch)
    for i in 0..<len(bvhs) {
        vk_bvhs[i] = pool_get(&ctx.bvhs, bvhs[i]).handle
    }

    write_bvh := vk.WriteDescriptorSetAccelerationStructureKHR {
        sType = .WRITE_DESCRIPTOR_SET_ACCELERATION_STRUCTURE_KHR,
        accelerationStructureCount = u32(len(bvhs)),
        pAccelerationStructures = raw_data(vk_bvhs),
    }
    write := vk.WriteDescriptorSet {
        sType = .WRITE_DESCRIPTOR_SET,
        pNext = &write_bvh,
        dstSet = heap_info.bvhs,
        dstBinding = 0,
        dstArrayElement = start_idx,
        descriptorCount = u32(len(bvhs)),
        descriptorType = .ACCELERATION_STRUCTURE_KHR,
    }
    vk.UpdateDescriptorSets(ctx.device, 1, &write, 0, nil)
}

// Shaders
@(private="file")
_shader_create_internal :: proc(code: []u32, is_compute: bool, vk_stage: vk.ShaderStageFlags, entry_point_name := "main", group_size_x: u32 = 1, group_size_y: u32 = 1, group_size_z: u32 = 1, name: string, loc: runtime.Source_Code_Location) -> Shader
{
    push_constant_ranges: []vk.PushConstantRange
    if is_compute {
        push_constant_ranges = []vk.PushConstantRange {
            {
                stageFlags = { .COMPUTE },
                size = size_of(Compute_Shader_Push_Constants),
            }
        }
    } else {
        push_constant_ranges = []vk.PushConstantRange {
            {
                stageFlags = { .VERTEX, .FRAGMENT },
                size = size_of(Graphics_Shader_Push_Constants),
            }
        }
    }

    // Setup specialization constants for compute shader workgroup size
    spec_map_entries: [3]vk.SpecializationMapEntry
    spec_data: [3]u32
    spec_info: vk.SpecializationInfo
    spec_info_ptr: ^vk.SpecializationInfo = nil
    spec_count: u32 = 0

    if is_compute
    {
        {
            spec_map_entries[spec_count] = vk.SpecializationMapEntry {
                constantID = 13370, // Random big ids to avoid conflicts with user defined constants
                offset = u32(spec_count * size_of(u32)),
                size = size_of(u32),
            }
            spec_data[spec_count] = group_size_x
            spec_count += 1
        }

        {
            spec_map_entries[spec_count] = vk.SpecializationMapEntry {
                constantID = 13371, // Random big ids to avoid conflicts with user defined constants
                offset = u32(spec_count * size_of(u32)),
                size = size_of(u32),
            }
            spec_data[spec_count] = group_size_y
            spec_count += 1
        }

        {
            spec_map_entries[spec_count] = vk.SpecializationMapEntry {
                constantID = 13372, // Random big ids to avoid conflicts with user defined constants
                offset = u32(spec_count * size_of(u32)),
                size = size_of(u32),
            }
            spec_data[spec_count] = group_size_z
            spec_count += 1
        }
    }

    if spec_count > 0
    {
        spec_info = vk.SpecializationInfo {
            mapEntryCount = spec_count,
            pMapEntries = raw_data(spec_map_entries[:spec_count]),
            dataSize = int(spec_count * size_of(u32)),
            pData = raw_data(spec_data[:spec_count]),
        }
        spec_info_ptr = &spec_info
    }

    next_stage: vk.ShaderStageFlags
    if is_compute {
        next_stage = {}
    } else if vk_stage == { .VERTEX } {
        next_stage = { .FRAGMENT }
    } else {
        next_stage = {}
    }

    entry_point_name_cstr := strings.clone_to_cstring(entry_point_name)
    defer delete(entry_point_name_cstr)

    shader_cis := vk.ShaderCreateInfoEXT {
        sType = .SHADER_CREATE_INFO_EXT,
        codeType = .SPIRV,
        codeSize = len(code) * size_of(code[0]),
        pCode = raw_data(code),
        pName = entry_point_name_cstr,
        stage = vk_stage,
        nextStage = next_stage,
        pushConstantRangeCount = u32(len(push_constant_ranges)),
        pPushConstantRanges = raw_data(push_constant_ranges),
        setLayoutCount = u32(len(ctx.desc_layouts)),
        pSetLayouts = raw_data(ctx.desc_layouts),
        pSpecializationInfo = spec_info_ptr,
    }

    vk_shader: vk.ShaderEXT
    vk_check(vk.CreateShadersEXT(ctx.device, 1, &shader_cis, nil, &vk_shader))

    vk_set_debug_name(name, u64(vk_shader), .SHADER_EXT)

    shader: Shader_Info
    shader.handle = vk_shader
    shader.current_workgroup_size = { group_size_x, group_size_y, group_size_z }
    shader.is_compute = is_compute

    return pool_add(&ctx.shaders, shader, { created_at = loc, name = name })
}

_shader_create :: proc(code: []u32, type: Shader_Type_Graphics, entry_point_name := "main", name := "", loc := #caller_location) -> Shader
{
    vk_stage := to_vk_shader_stage(type)
    return _shader_create_internal(code, false, vk_stage, entry_point_name, name = name, loc = loc)
}

_shader_create_compute :: proc(code: []u32, group_size_x: u32, group_size_y: u32 = 1, group_size_z: u32 = 1, entry_point_name := "main", name := "", loc := #caller_location) -> Shader
{
    return _shader_create_internal(code, true, { .COMPUTE }, entry_point_name, group_size_x, group_size_y, group_size_z, name = name, loc = loc)
}

_shader_destroy :: proc(shader: Shader, loc := #caller_location)
{
    if ctx.validation
    {
        ok := true
        ok &= pool_check(&ctx.shaders, shader, "shader", loc)
        if !ok do return
    }

    shader_info := pool_get(&ctx.shaders, shader)
    vk_shader := shader_info.handle
    vk.DestroyShaderEXT(ctx.device, vk_shader, nil)

    pool_remove(&ctx.shaders, shader)
}

// Semaphores
_semaphore_create :: proc(init_value: u64 = 0, name := "", loc := #caller_location) -> Semaphore
{
    next: rawptr
    next = &vk.SemaphoreTypeCreateInfo {
        sType = .SEMAPHORE_TYPE_CREATE_INFO,
        pNext = next,
        semaphoreType = .TIMELINE,
        initialValue = init_value,
    }
    sem_ci := vk.SemaphoreCreateInfo {
        sType = .SEMAPHORE_CREATE_INFO,
        pNext = next
    }
    sem: vk.Semaphore
    vk_check(vk.CreateSemaphore(ctx.device, &sem_ci, nil, &sem))

    vk_set_debug_name(name, u64(sem), .SEMAPHORE)

    return pool_add(&ctx.semaphores, sem, { name = name, created_at = loc })
}

_semaphore_get_value :: proc(sem: Semaphore, loc := #caller_location) -> u64
{
    if ctx.validation
    {
        ok := true
        ok &= pool_check(&ctx.semaphores, sem, "sem", loc)
        if !ok do return {}
    }

    res: u64
    vk_sem := pool_get(&ctx.semaphores, sem)
    vk.GetSemaphoreCounterValue(ctx.device, vk_sem, &res)
    return res
}

_semaphore_wait :: proc(sem: Semaphore, wait_value: u64, loc := #caller_location)
{
    if ctx.validation
    {
        ok := true
        ok &= pool_check(&ctx.semaphores, sem, "sem", loc)
        if !ok do return
    }

    sems := []vk.Semaphore { pool_get(&ctx.semaphores, sem) }
    values := []u64 { wait_value }
    assert(len(sems) == len(values))
    vk.WaitSemaphores(ctx.device, &{
        sType = .SEMAPHORE_WAIT_INFO,
        semaphoreCount = u32(len(sems)),
        pSemaphores = raw_data(sems),
        pValues = raw_data(values),
    }, timeout = max(u64))
}

_semaphore_destroy :: proc(sem: Semaphore, loc := #caller_location)
{
    if ctx.validation
    {
        ok := true
        ok &= pool_check(&ctx.semaphores, sem, "sem", loc)
        if !ok do return
    }

    vk_sem := pool_get(&ctx.semaphores, sem)
    vk.DestroySemaphore(ctx.device, vk_sem, nil)
    pool_remove(&ctx.semaphores, sem)
}

// Raytracing
_blas_size_and_align :: proc(desc: BLAS_Desc, loc := #caller_location) -> (size: u64, align: u64)
{
    return u64(get_vk_blas_size_info(desc).accelerationStructureSize), 16
}

_blas_create :: proc(desc: BLAS_Desc, storage: gpuptr, name := "", loc := #caller_location) -> BVH
{
    if ctx.validation
    {
        ok := true
        ok &= check_ptr(storage, "storage", loc)
        if !ok do return {}
    }

    storage_buf, storage_offset, _ := get_buf_offset_from_gpu_ptr(storage)
    size_info := get_vk_blas_size_info(desc)

    bvh_handle: vk.AccelerationStructureKHR
    blas_ci := vk.AccelerationStructureCreateInfoKHR {
        sType = .ACCELERATION_STRUCTURE_CREATE_INFO_KHR,
        buffer = storage_buf,
        offset = vk.DeviceSize(storage_offset),
        size = size_info.accelerationStructureSize,
        type = .BOTTOM_LEVEL,
    }
    vk_check(vk.CreateAccelerationStructureKHR(ctx.device, &blas_ci, nil, &bvh_handle))

    vk_set_debug_name(name, u64(bvh_handle), .ACCELERATION_STRUCTURE_KHR)

    new_desc := desc
    cloned_shapes := slice.clone_to_dynamic(new_desc.shapes)
    new_desc.shapes = cloned_shapes[:]
    bvh_info := BVH_Info {
        handle = bvh_handle,
        mem = storage.ptr,
        is_blas = true,
        shapes = cloned_shapes,
        blas_desc = desc,
    }
    return pool_add(&ctx.bvhs, bvh_info, { created_at = loc, name = name })
}

_blas_build_scratch_buffer_size_and_align :: proc(desc: BLAS_Desc, loc := #caller_location) -> (size: u64, align: u64)
{
    return u64(get_vk_blas_size_info(desc).buildScratchSize), u64(ctx.physical_properties.bvh_props.minAccelerationStructureScratchOffsetAlignment)
}

_tlas_size_and_align :: proc(desc: TLAS_Desc, loc := #caller_location) -> (size: u64, align: u64)
{
    return u64(get_vk_tlas_size_info(desc).accelerationStructureSize), 1
}

_tlas_create :: proc(desc: TLAS_Desc, storage: gpuptr, name := "", loc := #caller_location) -> BVH
{
    if ctx.validation
    {
        ok := true
        ok &= check_ptr(storage, "storage", loc)
        if !ok do return {}
    }

    storage_buf, storage_offset, _ := get_buf_offset_from_gpu_ptr(storage)
    size_info := get_vk_tlas_size_info(desc)

    bvh_handle: vk.AccelerationStructureKHR
    tlas_ci := vk.AccelerationStructureCreateInfoKHR {
        sType = .ACCELERATION_STRUCTURE_CREATE_INFO_KHR,
        buffer = storage_buf,
        offset = vk.DeviceSize(storage_offset),
        size = size_info.accelerationStructureSize,
        type = .TOP_LEVEL,
    }
    vk_check(vk.CreateAccelerationStructureKHR(ctx.device, &tlas_ci, nil, &bvh_handle))

    vk_set_debug_name(name, u64(bvh_handle), .ACCELERATION_STRUCTURE_KHR)

    bvh_info := BVH_Info {
        handle = bvh_handle,
        mem = storage.ptr,
        is_blas = false,
        tlas_desc = desc
    }
    return pool_add(&ctx.bvhs, bvh_info, { created_at = loc, name = name })
}

_tlas_build_scratch_buffer_size_and_align :: proc(desc: TLAS_Desc, loc := #caller_location) -> (size: u64, align: u64)
{
    return u64(get_vk_tlas_size_info(desc).buildScratchSize), u64(ctx.physical_properties.bvh_props.minAccelerationStructureScratchOffsetAlignment)
}

_bvh_root_ptr :: proc(bvh: BVH, loc := #caller_location) -> rawptr
{
    if ctx.validation
    {
        ok := true
        ok &= pool_check(&ctx.bvhs, bvh, "bvh", loc)
        if !ok do return nil
    }

    bvh_info := pool_get(&ctx.bvhs, bvh)

    return transmute(rawptr) vk.GetAccelerationStructureDeviceAddressKHR(ctx.device, & {
        sType = .ACCELERATION_STRUCTURE_DEVICE_ADDRESS_INFO_KHR,
        accelerationStructure = bvh_info.handle
    })
}

_bvh_destroy :: proc(bvh: BVH, loc := #caller_location)
{
    if ctx.validation
    {
        ok := true
        ok &= pool_check(&ctx.bvhs, bvh, "bvh", loc)
        if !ok do return
    }

    bvh_info := pool_get(&ctx.bvhs, bvh)
    vk.DestroyAccelerationStructureKHR(ctx.device, bvh_info.handle, nil)
    pool_remove(&ctx.bvhs, bvh)
}

@(private="file")
get_vk_blas_size_info :: proc(desc: BLAS_Desc) -> vk.AccelerationStructureBuildSizesInfoKHR
{
    scratch, _ := acquire_scratch()

    primitive_counts := make([]u32, len(desc.shapes), allocator = scratch)
    for shape, i in desc.shapes
    {
        switch s in shape
        {
            case BVH_Mesh_Desc: primitive_counts[i] = s.tri_count
            case BVH_AABB_Desc: primitive_counts[i] = s.aabb_count
        }
    }

    build_info := to_vk_blas_desc(desc, scratch)

    size_info := vk.AccelerationStructureBuildSizesInfoKHR { sType = .ACCELERATION_STRUCTURE_BUILD_SIZES_INFO_KHR }
    vk.GetAccelerationStructureBuildSizesKHR(ctx.device, .DEVICE, &build_info, raw_data(primitive_counts), &size_info)
    return size_info
}

@(private="file")
get_vk_tlas_size_info :: proc(desc: TLAS_Desc) -> vk.AccelerationStructureBuildSizesInfoKHR
{
    scratch, _ := acquire_scratch()

    build_info := to_vk_tlas_desc(desc, scratch)

    size_info := vk.AccelerationStructureBuildSizesInfoKHR { sType = .ACCELERATION_STRUCTURE_BUILD_SIZES_INFO_KHR }
    primitive_count := desc.instance_count
    vk.GetAccelerationStructureBuildSizesKHR(ctx.device, .DEVICE, &build_info, &primitive_count, &size_info)
    return size_info
}

// Command buffer

_queue_wait_idle :: proc(queue: Queue)
{
    if sync.guard(&ctx.queue_lock) do vk.QueueWaitIdle(ctx.queues[queue].handle)
}

_commands_begin :: proc(queue: Queue, loc := #caller_location) -> Command_Buffer
{
    cmd_buf := vk_acquire_cmd_buf(queue)
    cmd_buf_info := pool_get(&ctx.command_buffers, cmd_buf)

    cmd_buf_bi := vk.CommandBufferBeginInfo {
        sType = .COMMAND_BUFFER_BEGIN_INFO,
        flags = { .ONE_TIME_SUBMIT },
    }
    vk_cmd_buf := cmd_buf_info.handle
    vk_check(vk.BeginCommandBuffer(vk_cmd_buf, &cmd_buf_bi))

    return cmd_buf
}

_queue_submit :: proc(queue: Queue, cmd_bufs: []Command_Buffer, loc := #caller_location)
{
    if ctx.validation
    {
        ok := true
        for cmd_buf, i in cmd_bufs
        {
            cmd_buf_info := pool_get(&ctx.command_buffers, cmd_buf)
            if cmd_buf_info.queue != queue {
                log.errorf("'queue' does not match the queue associated with 'cmd_bufs[%v]'.", i)
                ok = false
            }

            if cmd_buf_info.thread_id != sync.current_thread_id() {
                log.errorf("Attempting to submit 'cmd_bufs[%v]' on thread '%v' even though it was created on thread '%v'. This is not allowed.",
                           i, sync.current_thread_id(), cmd_buf_info.thread_id)
                ok = false
            }
        }

        // TODO: Check that all wait sems and signal sems are still valid here.

        if !ok do return
    }

    for cmd_buf in cmd_bufs
    {
        cmd_buf_info := pool_get(&ctx.command_buffers, cmd_buf)
        vk_cmd_buf := cmd_buf_info.handle
        vk_check(vk.EndCommandBuffer(vk_cmd_buf))
    }

    vk_submit_cmd_bufs(cmd_bufs)
}

// Commands

_cmd_mem_copy_raw :: proc(cmd_buf: Command_Buffer, dst, src: gpuptr, #any_int bytes: i64, loc := #caller_location)
{
    if ctx.validation
    {
        ok := true
        ok &= pool_check(&ctx.command_buffers, cmd_buf, "cmd_buf", loc)
        if bytes > 0
        {
            ok &= check_ptr_range(dst, bytes, "dst", loc)
            ok &= check_ptr_range(src, bytes, "src", loc)
        }
        if !ok do return
    }

    if bytes == 0 do return

    cmd_buf_info := pool_get(&ctx.command_buffers, cmd_buf)

    src_alloc_impl := transmute(Alloc_Impl_Info) src._impl
    src_alloc_info := pool_get(&ctx.allocs, src_alloc_impl.handle)
    dst_alloc_impl := transmute(Alloc_Impl_Info) dst._impl
    dst_alloc_info := pool_get(&ctx.allocs, dst_alloc_impl.handle)

    src_buf, src_offset, _ := get_buf_offset_from_gpu_ptr(src)
    dst_buf, dst_offset, _ := get_buf_offset_from_gpu_ptr(dst)

    // Clamp copy regions
    to_copy: uintptr
    if uintptr(src_offset) > uintptr(src_alloc_info.buf_size) || uintptr(dst_offset) > uintptr(dst_alloc_info.buf_size) {
        to_copy = 0
    } else {
        to_copy = min(uintptr(bytes), min(uintptr(src_alloc_info.buf_size) - uintptr(src_offset), uintptr(dst_alloc_info.buf_size) - uintptr(dst_offset)))
    }

    if to_copy > 0
    {
        copy_regions := []vk.BufferCopy {
            {
                srcOffset = vk.DeviceSize(src_offset),
                dstOffset = vk.DeviceSize(dst_offset),
                size = vk.DeviceSize(to_copy),
            }
        }
        vk.CmdCopyBuffer(cmd_buf_info.handle, src_buf, dst_buf, u32(len(copy_regions)), raw_data(copy_regions))
    }
}

_cmd_copy_to_texture :: proc(cmd_buf: Command_Buffer, dst: Texture, src: gpuptr, region: Texture_Region = {}, loc := #caller_location)
{
    if ctx.validation
    {
        ok := true
        ok &= pool_check(&ctx.command_buffers, cmd_buf, "cmd_buf", loc)
        ok &= pool_check(&ctx.textures, dst.handle, "dst", loc)
        ok &= check_ptr(src, "src", loc)
        if !ok do return
    }

    cmd_buf_info := pool_get(&ctx.command_buffers, cmd_buf)
    tex_info := pool_get(&ctx.textures, dst.handle)

    src_buf, src_offset, ok_s := get_buf_offset_from_gpu_ptr(src)
    assert(ok_s)

    plane_aspect := to_vk_image_aspect_flags(dst.format)
    is_compressed := is_block_compressed(dst.format)

    mip_width := max(1, dst.dimensions.x >> region.mip_level)
    mip_height := max(1, dst.dimensions.y >> region.mip_level)
    mip_depth := max(1, dst.dimensions.z >> region.mip_level)

    copy := vk.BufferImageCopy{
        bufferOffset = vk.DeviceSize(src_offset),
        bufferRowLength = 0 if is_compressed else mip_width,
        bufferImageHeight = 0 if is_compressed else mip_height,
        imageSubresource = {
            aspectMask = plane_aspect,
            mipLevel = region.mip_level,
            baseArrayLayer = region.base_layer,
            layerCount = max(1, region.layer_count),
        },
        imageOffset = {},
        imageExtent = { mip_width, mip_height, mip_depth },
    }

    vk.CmdCopyBufferToImage(cmd_buf_info.handle, src_buf, tex_info.handle, .GENERAL, 1, &copy)
}

// TODO: Missing: cmd_copy_from_texture

_cmd_blit_texture :: proc(cmd_buf: Command_Buffer, dst: Texture, dst_rect: Blit_Rect, src: Texture, src_rect: Blit_Rect, filter: Filter, loc := #caller_location)
{
    if ctx.validation
    {
        ok := true
        ok &= pool_check(&ctx.command_buffers, cmd_buf, "cmd_buf", loc)
        ok &= check_cmd_buf_must_be_graphics(cmd_buf, "cmd_buf", loc)
        if !ok do return
    }

    cmd_buf_info := pool_get(&ctx.command_buffers, cmd_buf)
    src_info := pool_get(&ctx.textures, src.handle)
    dst_info := pool_get(&ctx.textures, dst.handle)

    vk_filter := to_vk_filter(filter)

    src_dimensions := [3]i32 { i32(src.dimensions.x), i32(src.dimensions.y), i32(src.dimensions.z) }
    dst_dimensions := [3]i32 { i32(dst.dimensions.x), i32(dst.dimensions.y), i32(dst.dimensions.z) }

    src_offsets := [2][3]i32 { src_rect.offset_a, src_rect.offset_b }
    if src_offsets == ([2][3]i32 { { 0, 0, 0 }, { 0, 0, 0 } }) {
        src_offsets[1] = get_mip_dimensions_i32(src_dimensions, src_rect.mip_level)
    }

    dst_offsets := [2][3]i32 { dst_rect.offset_a, dst_rect.offset_b }
    if dst_offsets == ([2][3]i32 { { 0, 0, 0 }, { 0, 0, 0 } }) {
        dst_offsets[1] = get_mip_dimensions_i32(dst_dimensions, dst_rect.mip_level)
    }

    region := vk.ImageBlit {
        srcSubresource = {
            aspectMask = { .COLOR },
            mipLevel = src_rect.mip_level,
            baseArrayLayer = src_rect.base_layer,
            layerCount = src_rect.layer_count if src_rect.layer_count > 0 else 1,  // TODO
        },
        srcOffsets = {
            { src_offsets[0].x, src_offsets[0].y, src_offsets[0].z },
            { src_offsets[1].x, src_offsets[1].y, src_offsets[1].z },
        },
        dstSubresource = {
            aspectMask = { .COLOR },
            mipLevel = dst_rect.mip_level,
            baseArrayLayer = dst_rect.base_layer,
            layerCount = dst_rect.layer_count if dst_rect.layer_count > 0 else 1,  // TODO
        },
        dstOffsets = {
            { dst_offsets[0].x, dst_offsets[0].y, dst_offsets[0].z },
            { dst_offsets[1].x, dst_offsets[1].y, dst_offsets[1].z },
        }
    }

    vk.CmdBlitImage(cmd_buf_info.handle, src_info.handle, .GENERAL, dst_info.handle, .GENERAL, 1, &region, vk_filter)
}

_cmd_set_desc_heap :: proc(cmd_buf: Command_Buffer, heap: Descriptor_Heap, loc := #caller_location)
{
    if ctx.validation
    {
        ok := true
        ok &= pool_check(&ctx.command_buffers, cmd_buf, "cmd_buf", loc)
        ok &= pool_check(&ctx.desc_heaps, heap, "heap", loc)
        if !ok do return
    }

    cmd_buf_info := pool_get(&ctx.command_buffers, cmd_buf)
    vk_cmd_buf := cmd_buf_info.handle

    heap_info := pool_get(&ctx.desc_heaps, heap)

    sets := [4]vk.DescriptorSet {
        heap_info.textures,
        heap_info.textures_rw,
        heap_info.samplers,
        heap_info.bvhs,
    }
    vk.CmdBindDescriptorSets(vk_cmd_buf, .GRAPHICS, ctx.common_pipeline_layout_graphics, 0, u32(len(ctx.desc_layouts)), &sets[0], 0, nil)
    vk.CmdBindDescriptorSets(vk_cmd_buf, .COMPUTE, ctx.common_pipeline_layout_compute, 0, u32(len(ctx.desc_layouts)), &sets[0], 0, nil)
}

_cmd_add_wait_semaphore :: proc(cmd_buf: Command_Buffer, sem: Semaphore, wait_value: u64, loc := #caller_location)
{
    if ctx.validation
    {
        ok := true
        ok &= pool_check(&ctx.command_buffers, cmd_buf, "cmd_buf", loc)
        ok &= check_cmd_buf_must_be_recording(cmd_buf, "cmd_buf", loc)
        ok &= pool_check(&ctx.semaphores, sem, "sem", loc)
        if !ok do return
    }

    cmd_buf_ptr := pool_get_ptr(&ctx.command_buffers, cmd_buf)
    append(&cmd_buf_ptr.wait_sems, Semaphore_Value { sem = sem, val = wait_value })
}

_cmd_add_signal_semaphore :: proc(cmd_buf: Command_Buffer, sem: Semaphore, signal_value: u64, loc := #caller_location)
{
    if ctx.validation
    {
        ok := true
        ok &= pool_check(&ctx.command_buffers, cmd_buf, "cmd_buf", loc)
        ok &= check_cmd_buf_must_be_recording(cmd_buf, "cmd_buf", loc)
        ok &= pool_check(&ctx.semaphores, sem, "sem", loc)
        if !ok do return
    }

    cmd_buf_ptr := pool_get_ptr(&ctx.command_buffers, cmd_buf)
    append(&cmd_buf_ptr.signal_sems, Semaphore_Value { sem = sem, val = signal_value })
}

_cmd_barrier :: proc(cmd_buf: Command_Buffer, before: Stage, after: Stage, hazards: Hazard_Flags = {}, loc := #caller_location)
{
    if ctx.validation
    {
        ok := true
        ok &= pool_check(&ctx.command_buffers, cmd_buf, "cmd_buf", loc)
        if !ok do return
    }

    cmd_buf := pool_get(&ctx.command_buffers, cmd_buf)

    vk_cmd_buf := cmd_buf.handle

    vk_before := to_vk_stage(before)
    vk_after  := to_vk_stage(after)

    // Determine access masks based on hazards
    src_access: vk.AccessFlags
    dst_access: vk.AccessFlags

    if .Draw_Arguments in hazards
    {
        // When compute shader writes draw arguments, ensure they're visible to indirect draw commands
        // Source: compute shader writes
        src_access += { .SHADER_WRITE }
        // Destination: indirect command read (for draw/dispatch indirect)
        dst_access += { .INDIRECT_COMMAND_READ }
    }
    if .Descriptors in hazards
    {
        // When descriptors are updated, ensure visibility
        src_access += { .SHADER_WRITE }
        dst_access += { .SHADER_READ }
    }
    if .Depth_Stencil in hazards
    {
        // Depth/stencil attachment synchronization
        src_access += { .DEPTH_STENCIL_ATTACHMENT_WRITE }
        dst_access += { .DEPTH_STENCIL_ATTACHMENT_READ, .DEPTH_STENCIL_ATTACHMENT_WRITE }
    }
    if .BVHs in hazards
    {
        src_access += { .ACCELERATION_STRUCTURE_WRITE_KHR }
        dst_access += { .ACCELERATION_STRUCTURE_READ_KHR }
    }

    // If no specific hazards, use generic memory barrier
    if card(hazards) == 0
    {
        src_access = { .MEMORY_WRITE }
        dst_access = { .MEMORY_READ, .MEMORY_WRITE }
    }

    barrier := vk.MemoryBarrier {
        sType = .MEMORY_BARRIER,
        srcAccessMask = src_access,
        dstAccessMask = dst_access,
    }
    vk.CmdPipelineBarrier(vk_cmd_buf, vk_before, vk_after, {}, 1, &barrier, 0, nil, 0, nil)
}

_cmd_set_shaders :: proc(cmd_buf: Command_Buffer, vert_shader: Shader, frag_shader: Shader, loc := #caller_location)
{
    if ctx.validation
    {
        ok := true
        ok &= pool_check(&ctx.command_buffers, cmd_buf, "cmd_buf", loc)
        ok &= pool_check(&ctx.shaders, vert_shader, "vert_shader", loc)
        ok &= pool_check(&ctx.shaders, frag_shader, "frag_shader", loc)
        if !ok do return
    }

    cmd_buf := pool_get(&ctx.command_buffers, cmd_buf)
    vert_shader := pool_get(&ctx.shaders, vert_shader)
    frag_shader := pool_get(&ctx.shaders, frag_shader)

    vk_cmd_buf := cmd_buf.handle
    vk_vert_shader := vert_shader.handle
    vk_frag_shader := frag_shader.handle

    shader_stages := []vk.ShaderStageFlags { { .VERTEX }, { .FRAGMENT } }
    to_bind := []vk.ShaderEXT { vk_vert_shader, vk_frag_shader }
    assert(len(shader_stages) == len(to_bind))
    vk.CmdBindShadersEXT(vk_cmd_buf, u32(len(shader_stages)), raw_data(shader_stages), raw_data(to_bind))
}

_cmd_set_depth_state :: proc(cmd_buf: Command_Buffer, state: Depth_State, loc := #caller_location)
{
    if ctx.validation
    {
        ok := true
        ok &= pool_check(&ctx.command_buffers, cmd_buf, "cmd_buf", loc)
        if !ok do return
    }

    cmd_buf := pool_get(&ctx.command_buffers, cmd_buf)

    vk_cmd_buf := cmd_buf.handle

    vk.CmdSetDepthCompareOp(vk_cmd_buf, to_vk_compare_op(state.compare))
    vk.CmdSetDepthTestEnable(vk_cmd_buf, .Read in state.mode)
    vk.CmdSetDepthWriteEnable(vk_cmd_buf, .Write in state.mode)
    vk.CmdSetDepthBiasEnable(vk_cmd_buf, false)
    vk.CmdSetStencilTestEnable(vk_cmd_buf, false)
    when ODIN_OS != .Darwin {
        vk.CmdSetDepthClipEnableEXT(vk_cmd_buf, true)
    }
}

_cmd_set_raster_state :: proc(cmd_buf: Command_Buffer, state: Raster_State, loc := #caller_location)
{
    if ctx.validation
    {
        ok := true
        ok &= pool_check(&ctx.command_buffers, cmd_buf, "cmd_buf", loc)
        if !ok do return
    }

    cmd_buf := pool_get(&ctx.command_buffers, cmd_buf)
    vk_cmd_buf := cmd_buf.handle

    vk.CmdSetPrimitiveTopology(vk_cmd_buf, to_vk_topology(state.topology))
    vk.CmdSetCullMode(vk_cmd_buf, to_vk_cull_mode(state.cull_mode))
    vk.CmdSetAlphaToCoverageEnableEXT(vk_cmd_buf, b32(state.alpha_to_coverage))
}

_cmd_set_blend_state :: proc(cmd_buf: Command_Buffer, state: Blend_State, loc := #caller_location)
{
    if ctx.validation
    {
        ok := true
        ok &= pool_check(&ctx.command_buffers, cmd_buf, "cmd_buf", loc)
        if !ok do return
    }

    cmd_buf := pool_get(&ctx.command_buffers, cmd_buf)
    vk_cmd_buf := cmd_buf.handle

    enable_b32 := b32(state.enable)
    vk.CmdSetColorBlendEnableEXT(vk_cmd_buf, 0, 1, &enable_b32)

    vk.CmdSetColorBlendEquationEXT(vk_cmd_buf, 0, 1, &vk.ColorBlendEquationEXT {
        srcColorBlendFactor = to_vk_blend_factor(state.src_color_factor),
        dstColorBlendFactor = to_vk_blend_factor(state.dst_color_factor),
        colorBlendOp        = to_vk_blend_op(state.color_op),
        srcAlphaBlendFactor = to_vk_blend_factor(state.src_alpha_factor),
        dstAlphaBlendFactor = to_vk_blend_factor(state.dst_alpha_factor),
        alphaBlendOp        = to_vk_blend_op(state.alpha_op),
    })

    color_write_mask := transmute(vk.ColorComponentFlags) cast(u32) transmute(u8) state.color_write_mask
    vk.CmdSetColorWriteMaskEXT(vk_cmd_buf, 0, 1, &color_write_mask)
}

_cmd_set_viewport :: proc(cmd_buf: Command_Buffer, viewport: Viewport, loc := #caller_location)
{
    if ctx.validation
    {
        ok := true
        ok &= pool_check(&ctx.command_buffers, cmd_buf, "cmd_buf", loc)
        if viewport.size.x <= 0 || viewport.size.y <= 0 {
            log.error("Viewport width and height must be > 0.", location = loc)
            ok = false
        }
        if !ok do return
    }

    vk_cmd_buf := pool_get(&ctx.command_buffers, cmd_buf).handle
    vk_viewport := to_vk_viewport(viewport)
    vk.CmdSetViewportWithCount(vk_cmd_buf, 1, &vk_viewport)
}

_cmd_set_scissor :: proc(cmd_buf: Command_Buffer, scissor: Rect_2D, loc := #caller_location)
{
    if ctx.validation
    {
        ok := true
        ok &= pool_check(&ctx.command_buffers, cmd_buf, "cmd_buf", loc)
        if !ok do return
    }

    vk_cmd_buf := pool_get(&ctx.command_buffers, cmd_buf).handle
    vk_scissor := to_vk_rect_2D(scissor)
    vk.CmdSetScissorWithCount(vk_cmd_buf, 1, &vk_scissor)
}

_cmd_set_compute_shader :: proc(cmd_buf: Command_Buffer, compute_shader: Shader, loc := #caller_location)
{
    if ctx.validation
    {
        ok := true
        ok &= pool_check(&ctx.command_buffers, cmd_buf, "cmd_buf", loc)
        ok &= pool_check(&ctx.shaders, compute_shader, "compute_shader", loc)
        if !ok do return
    }

    shader_info := pool_get(&ctx.shaders, compute_shader)
    vk_shader_info := shader_info.handle

    cmd_buf_ptr := pool_get_ptr(&ctx.command_buffers, cmd_buf)
    cmd_buf_ptr.compute_shader = compute_shader
    vk_cmd_buf := cmd_buf_ptr.handle

    shader_stages := []vk.ShaderStageFlags { { .COMPUTE } }
    to_bind := []vk.ShaderEXT { vk_shader_info }
    assert(len(shader_stages) == len(to_bind))
    vk.CmdBindShadersEXT(vk_cmd_buf, u32(len(shader_stages)), raw_data(shader_stages), raw_data(to_bind))

}

_cmd_dispatch :: proc(cmd_buf: Command_Buffer, compute_data: gpuptr, num_groups_x: u32, num_groups_y: u32 = 1, num_groups_z: u32 = 1, loc := #caller_location)
{
    if ctx.validation
    {
        ok := true
        ok &= pool_check(&ctx.command_buffers, cmd_buf, "cmd_buf", loc)
        ok &= check_ptr(compute_data, "compute_data", loc)
        ok &= check_cmd_buf_has_compute_shader_set(cmd_buf, "cmd_buf", loc)
        if !ok do return
    }

    cmd_buf_info := pool_get(&ctx.command_buffers, cmd_buf)
    vk_cmd_buf := cmd_buf_info.handle

    push_constants := Compute_Shader_Push_Constants {
        compute_data = compute_data.ptr,
    }

    vk.CmdPushConstants(vk_cmd_buf, ctx.common_pipeline_layout_compute, { .COMPUTE }, 0, size_of(Compute_Shader_Push_Constants), &push_constants)

    vk.CmdDispatch(vk_cmd_buf, num_groups_x, num_groups_y, num_groups_z)
}

_cmd_dispatch_indirect_raw :: proc(cmd_buf: Command_Buffer, compute_data, arguments: gpuptr, loc := #caller_location)
{
    if ctx.validation
    {
        ok := true
        ok &= pool_check(&ctx.command_buffers, cmd_buf, "cmd_buf", loc)
        ok &= check_ptr(compute_data, "compute_data", loc)
        ok &= check_ptr(arguments, "arguments", loc)
        ok &= check_cmd_buf_has_compute_shader_set(cmd_buf, "cmd_buf", loc)
        if !ok do return
    }

    cmd_buf_info := pool_get(&ctx.command_buffers, cmd_buf)
    vk_cmd_buf := cmd_buf_info.handle

    arguments_buf, arguments_offset, ok_a := get_buf_offset_from_gpu_ptr(arguments)
    assert(ok_a)

    push_constants := Compute_Shader_Push_Constants {
        compute_data = compute_data.ptr,
    }

    vk.CmdPushConstants(vk_cmd_buf, ctx.common_pipeline_layout_compute, { .COMPUTE }, 0, size_of(Compute_Shader_Push_Constants), &push_constants)

    vk.CmdDispatchIndirect(vk_cmd_buf, arguments_buf, vk.DeviceSize(arguments_offset))
}

_cmd_begin_render_pass :: proc(cmd_buf: Command_Buffer, desc: Render_Pass_Desc, loc := #caller_location)
{
    if ctx.validation
    {
        ok := true
        ok &= pool_check(&ctx.command_buffers, cmd_buf, "cmd_buf", loc)
        ok &= check_cmd_buf_must_be_graphics(cmd_buf, "cmd_buf", loc)
        if !ok do return
    }

    cmd_buf_info := pool_get(&ctx.command_buffers, cmd_buf)
    vk_cmd_buf := cmd_buf_info.handle

    scratch, _ := acquire_scratch()

    // Compute sample count
    sample_count := u32(1)
    {
        for attachment in desc.color_attachments {
            sample_count = max(sample_count, attachment.texture.sample_count)
        }
        if desc.depth_attachment != nil {
            sample_count = max(sample_count, desc.depth_attachment.?.texture.sample_count)
        }
    }

    vk_color_attachments := make([]vk.RenderingAttachmentInfo, len(desc.color_attachments), allocator = scratch)
    for &vk_attach, i in vk_color_attachments {
        vk_attach = to_vk_render_attachment(desc.color_attachments[i])
    }

    vk_depth_attachment: vk.RenderingAttachmentInfo
    vk_depth_attachment_ptr: ^vk.RenderingAttachmentInfo
    if desc.depth_attachment != nil
    {
        vk_depth_attachment = to_vk_render_attachment(desc.depth_attachment.?)
        vk_depth_attachment_ptr = &vk_depth_attachment
    }

    width := desc.render_area_size.x
    if width == {} {
        width = desc.color_attachments[0].texture.dimensions.x
    }
    height := desc.render_area_size.y
    if height == {} {
        height = desc.color_attachments[0].texture.dimensions.y
    }
    layer_count := desc.layer_count
    if layer_count == 0 {
        layer_count = 1
    }

    rendering_info := vk.RenderingInfo {
        sType = .RENDERING_INFO,
        renderArea = {
            offset = { desc.render_area_offset.x, desc.render_area_offset.y },
            extent = { width, height }
        },
        layerCount = layer_count,
        colorAttachmentCount = u32(len(vk_color_attachments)),
        pColorAttachments = raw_data(vk_color_attachments),
        pDepthAttachment = vk_depth_attachment_ptr,
    }
    vk.CmdBeginRendering(vk_cmd_buf, &rendering_info)

    // Blend state
    vk.CmdSetStencilTestEnable(vk_cmd_buf, false)
    color_attachment_count := u32(len(vk_color_attachments))
    if color_attachment_count > 0 {
        // Set blend enable for all attachments
        blend_enables := make([]b32, color_attachment_count, allocator = scratch)
        for i in 0 ..< color_attachment_count {
            blend_enables[i] = false
        }
        vk.CmdSetColorBlendEnableEXT(vk_cmd_buf, 0, color_attachment_count, raw_data(blend_enables))

        // Set color write mask for all attachments
        color_mask := vk.ColorComponentFlags { .R, .G, .B, .A }
        color_masks := make([]vk.ColorComponentFlags, color_attachment_count, allocator = scratch)
        for i in 0 ..< color_attachment_count {
            color_masks[i] = color_mask
        }
        vk.CmdSetColorWriteMaskEXT(vk_cmd_buf, 0, color_attachment_count, raw_data(color_masks))
    }

    // Raster state
    vk.CmdSetRasterizationSamplesEXT(vk_cmd_buf, to_vk_sample_count(sample_count))
    vk.CmdSetPrimitiveTopology(vk_cmd_buf, .TRIANGLE_LIST)
    vk.CmdSetPolygonModeEXT(vk_cmd_buf, .FILL)
    vk.CmdSetCullMode(vk_cmd_buf, { .BACK })
    vk.CmdSetFrontFace(vk_cmd_buf, .COUNTER_CLOCKWISE)

    // Depth state
    vk.CmdSetDepthCompareOp(vk_cmd_buf, .LESS)
    vk.CmdSetDepthTestEnable(vk_cmd_buf, false)
    vk.CmdSetDepthWriteEnable(vk_cmd_buf, false)
    vk.CmdSetDepthBiasEnable(vk_cmd_buf, false)
    when ODIN_OS != .Darwin {
        vk.CmdSetDepthClipEnableEXT(vk_cmd_buf, true)
    }

    // Viewport
    viewport := vk.Viewport {
        x = 0, y = 0,
        width = f32(width), height = f32(height),
        minDepth = 0.0, maxDepth = 1.0,
    }
    vk.CmdSetViewportWithCount(vk_cmd_buf, 1, &viewport)
    scissor := vk.Rect2D {
        offset = {
            x = 0, y = 0
        },
        extent = {
            width = width, height = height,
        }
    }
    vk.CmdSetScissorWithCount(vk_cmd_buf, 1, &scissor)
    vk.CmdSetRasterizerDiscardEnable(vk_cmd_buf, false)
    vk.CmdSetColorBlendEquationEXT(vk_cmd_buf, 0, 1, &vk.ColorBlendEquationEXT {
        srcColorBlendFactor = .SRC_ALPHA,
        dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
        colorBlendOp        = .ADD,
        srcAlphaBlendFactor = .ONE,
        dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA,
        alphaBlendOp        = .ADD,
    })

    // Unused
    vk.CmdSetVertexInputEXT(vk_cmd_buf, 0, nil, 0, nil)
    vk.CmdSetPrimitiveRestartEnable(vk_cmd_buf, false)

    sample_mask := vk.SampleMask(0xFF)
    vk.CmdSetSampleMaskEXT(vk_cmd_buf, to_vk_sample_count(sample_count), &sample_mask)
    vk.CmdSetAlphaToCoverageEnableEXT(vk_cmd_buf, false)
}

_cmd_end_render_pass :: proc(cmd_buf: Command_Buffer, loc := #caller_location)
{
    if ctx.validation
    {
        ok := true
        ok &= pool_check(&ctx.command_buffers, cmd_buf, "cmd_buf", loc)
        if !ok do return
    }

    cmd_buf := pool_get(&ctx.command_buffers, cmd_buf)
    vk_cmd_buf := cmd_buf.handle
    vk.CmdEndRendering(vk_cmd_buf)
}

_cmd_draw :: proc(cmd_buf: Command_Buffer, vertex_data, fragment_data: gpuptr,
                  vertex_count: u32, instance_count: u32 = 1, loc := #caller_location)
{
    if ctx.validation
    {
        ok := true
        ok &= pool_check(&ctx.command_buffers, cmd_buf, "cmd_buf", loc)
        ok &= check_ptr_allow_nil(vertex_data, "vertex_data", loc)
        ok &= check_ptr_allow_nil(fragment_data, "fragment_data", loc)
        if !ok do return
    }

    cmd_buf := pool_get(&ctx.command_buffers, cmd_buf)
    vk_cmd_buf := cmd_buf.handle

    push_constants := Graphics_Shader_Push_Constants {
        vert_data = vertex_data.ptr,
        frag_data = fragment_data.ptr,
        indirect_data = nil,
    }
    vk.CmdPushConstants(vk_cmd_buf, ctx.common_pipeline_layout_graphics, { .VERTEX, .FRAGMENT }, 0, size_of(Graphics_Shader_Push_Constants), &push_constants)

    vk.CmdDraw(vk_cmd_buf, vertex_count, instance_count, 0, 0)
}

_cmd_draw_indexed_raw :: proc(cmd_buf: Command_Buffer, vertex_data, fragment_data, indices: gpuptr,
                              index_format: Index_Format, index_count: u32, instance_count: u32 = 1, loc := #caller_location)
{

    if ctx.validation
    {
        index_size: u32 = 4 if index_format == .U32 else 2
        ok := true
        ok &= pool_check(&ctx.command_buffers, cmd_buf, "cmd_buf", loc)
        ok &= check_ptr_allow_nil(vertex_data, "vertex_data", loc)
        ok &= check_ptr_allow_nil(fragment_data, "fragment_data", loc)
        ok &= check_ptr_range(indices, index_size * index_count, "indices", loc)
        if !ok do return
    }

    cmd_buf := pool_get(&ctx.command_buffers, cmd_buf)
    vk_cmd_buf := cmd_buf.handle

    indices_buf, indices_offset, ok_i := get_buf_offset_from_gpu_ptr(indices)
    assert(ok_i)

    push_constants := Graphics_Shader_Push_Constants {
        vert_data = vertex_data.ptr,
        frag_data = fragment_data.ptr,
        indirect_data = nil,
    }
    vk.CmdPushConstants(vk_cmd_buf, ctx.common_pipeline_layout_graphics, { .VERTEX, .FRAGMENT }, 0, size_of(Graphics_Shader_Push_Constants), &push_constants)

    vk.CmdBindIndexBuffer(vk_cmd_buf, indices_buf, vk.DeviceSize(indices_offset), to_vk_index_format(index_format))
    vk.CmdDrawIndexed(vk_cmd_buf, index_count, instance_count, 0, 0, 0)
}

_cmd_draw_indexed_indirect_raw :: proc(cmd_buf: Command_Buffer, vertex_data, fragment_data, indices: gpuptr, index_format: Index_Format, indirect_arguments: gpuptr, loc := #caller_location)
{
    if ctx.validation
    {
        ok := true
        ok &= pool_check(&ctx.command_buffers, cmd_buf, "cmd_buf", loc)
        ok &= check_ptr_allow_nil(vertex_data, "vertex_data", loc)
        ok &= check_ptr_allow_nil(fragment_data, "fragment_data", loc)
        ok &= check_ptr_allow_nil(indices, "indices", loc)
        ok &= check_ptr(indirect_arguments, "indirect_arguments", loc)
        if !ok do return
    }

    cmd_buf_info := pool_get(&ctx.command_buffers, cmd_buf)
    vk_cmd_buf := cmd_buf_info.handle

    indices_buf, indices_offset, _ := get_buf_offset_from_gpu_ptr(indices)
    arguments_buf, arguments_offset, _ := get_buf_offset_from_gpu_ptr(indirect_arguments)

    push_constants := Graphics_Shader_Push_Constants {
        vert_data = vertex_data.ptr,
        frag_data = fragment_data.ptr,
        indirect_data = indirect_arguments.ptr,
    }
    vk.CmdPushConstants(vk_cmd_buf, ctx.common_pipeline_layout_graphics, { .VERTEX, .FRAGMENT }, 0, size_of(Graphics_Shader_Push_Constants), &push_constants)

    vk.CmdBindIndexBuffer(vk_cmd_buf, indices_buf, vk.DeviceSize(indices_offset), to_vk_index_format(index_format))
    vk.CmdDrawIndexedIndirect(vk_cmd_buf, arguments_buf, vk.DeviceSize(arguments_offset), 1, 0)
}

_cmd_draw_indexed_indirect_multi_raw :: proc(cmd_buf: Command_Buffer, vertex_data, fragment_data, indices: gpuptr,
                                             index_format: Index_Format, indirect_arguments: gpuptr, stride: u32, draw_count: gpuptr, loc := #caller_location)
{
    if ctx.validation
    {
        ok := true
        ok &= pool_check(&ctx.command_buffers, cmd_buf, "cmd_buf", loc)
        ok &= check_ptr_allow_nil(vertex_data, "vertex_data", loc)
        ok &= check_ptr_allow_nil(fragment_data, "fragment_data", loc)
        ok &= check_ptr_allow_nil(indices, "indices", loc)
        ok &= check_ptr(indirect_arguments, "indirect_arguments", loc)
        ok &= check_ptr(draw_count, "draw_count", loc)
        ok &= supports_indirect_multi_draw(loc)
        if !ok do return
    }

    cmd_buf := pool_get(&ctx.command_buffers, cmd_buf)

    vk_cmd_buf := cmd_buf.handle

    indices_buf, indices_offset, _ := get_buf_offset_from_gpu_ptr(indices)
    arguments_buf, arguments_offset, _ := get_buf_offset_from_gpu_ptr(indirect_arguments)
    draw_count_buf, draw_count_offset, _ := get_buf_offset_from_gpu_ptr(draw_count)

    // vertex_data and fragment_data are shared data for vertex and fragment shaders
    // indirect_arguments points to the unified indirect data array containing both command and user data
    // The stride is the size of the combined struct { IndirectDrawCommand cmd; UserData data; }
    push_constants := Graphics_Shader_Push_Constants {
        vert_data = vertex_data.ptr,
        frag_data = fragment_data.ptr,
        indirect_data = indirect_arguments.ptr,
    }
    vk.CmdPushConstants(vk_cmd_buf, ctx.common_pipeline_layout_graphics, { .VERTEX, .FRAGMENT }, 0, size_of(Graphics_Shader_Push_Constants), &push_constants)

    vk.CmdBindIndexBuffer(vk_cmd_buf, indices_buf, vk.DeviceSize(indices_offset), to_vk_index_format(index_format))

    max_draw_count := max(u32)
    buf_size, ok_size := get_buf_size_from_gpu_ptr(indirect_arguments)
    if ok_size && buf_size > vk.DeviceSize(arguments_offset)
    {
        available_size := buf_size - vk.DeviceSize(arguments_offset)
        max_draw_count = u32(available_size / vk.DeviceSize(stride))
    }

    vk.CmdDrawIndexedIndirectCount(vk_cmd_buf, arguments_buf, vk.DeviceSize(arguments_offset), draw_count_buf, vk.DeviceSize(draw_count_offset), max_draw_count, stride)
}

_cmd_build_blas :: proc(cmd_buf: Command_Buffer, bvh: BVH, scratch_storage: gpuptr, shapes: []BVH_Shape, loc := #caller_location)
{
    if ctx.validation
    {
        ok := true
        ok &= pool_check(&ctx.command_buffers, cmd_buf, "cmd_buf", loc)
        ok &= check_ptr(scratch_storage, "scratch_storage", loc)
        ok &= check_bvh_must_be_blas(bvh, "bvh", loc)
        if !ok do return
    }

    cmd_buf_info := pool_get(&ctx.command_buffers, cmd_buf)
    vk_cmd_buf := cmd_buf_info.handle
    bvh_info := pool_get(&ctx.bvhs, bvh)

    if len(shapes) != len(bvh_info.blas_desc.shapes)
    {
        log.error("Length used in the shapes argument and length used in the shapes supplied during the creation of this BVH don't match.")
        return
    }

    // TODO: Check for mismatching types.
    /*
    for shape, i in shapes
    {
        switch s in shape
        {
            case BVH_Mesh: {}
            case BVH_AABBs: {}
        }
    }
    */

    scratch, _ := acquire_scratch()

    build_info := to_vk_blas_desc(bvh_info.blas_desc, arena = scratch)
    build_info.dstAccelerationStructure = bvh_info.handle
    build_info.scratchData.deviceAddress = transmute(vk.DeviceAddress) scratch_storage.ptr
    assert(u32(len(shapes)) == build_info.geometryCount)

    range_infos := make([]vk.AccelerationStructureBuildRangeInfoKHR, len(shapes), allocator = scratch)

    // Fill in actual data in shapes
    for i in 0..<build_info.geometryCount
    {
        range_infos[i] = {
            // primitiveCount = primitive_count,
            primitiveOffset = 0,
            firstVertex = 0,
            transformOffset = 0,
        }

        geom := &build_info.pGeometries[i]
        switch s in shapes[i]
        {
            case BVH_Mesh:
            {
                geom.geometry.triangles.vertexData.deviceAddress = transmute(vk.DeviceAddress) s.verts
                geom.geometry.triangles.indexData.deviceAddress = transmute(vk.DeviceAddress) s.indices
                range_infos[i].primitiveCount = bvh_info.blas_desc.shapes[i].(BVH_Mesh_Desc).tri_count
            }
            case BVH_AABBs:
            {
                geom.geometry.aabbs.data.deviceAddress = transmute(vk.DeviceAddress) s.data
            }
        }
    }

    // Vulkan expects an array of pointers (to arrays), one pointer per BVH to build.
    // We always build one at a time, so we only need a pointer to an array (double pointer).
    range_infos_ptr := raw_data(range_infos)
    vk.CmdBuildAccelerationStructuresKHR(vk_cmd_buf, 1, &build_info, &range_infos_ptr)
}

_cmd_build_tlas :: proc(cmd_buf: Command_Buffer, bvh: BVH, scratch_storage, instances: gpuptr, loc := #caller_location)
{
    if ctx.validation
    {
        ok := true
        ok &= pool_check(&ctx.command_buffers, cmd_buf, "cmd_buf", loc)
        ok &= check_ptr(scratch_storage, "scratch_storage", loc)
        ok &= check_ptr(instances, "instances", loc)
        ok &= check_bvh_must_be_tlas(bvh, "bvh", loc)
        if !ok do return
    }

    cmd_buf_info := pool_get(&ctx.command_buffers, cmd_buf)
    bvh_info := pool_get(&ctx.bvhs, bvh)
    vk_cmd_buf := cmd_buf_info.handle

    scratch, _ := acquire_scratch()

    build_info := to_vk_tlas_desc(bvh_info.tlas_desc, arena = scratch)
    build_info.dstAccelerationStructure = bvh_info.handle
    build_info.scratchData.deviceAddress = transmute(vk.DeviceAddress) scratch_storage.ptr
    assert(build_info.geometryCount == 1)

    // Fill in actual data
    build_info.pGeometries[0].geometry.instances.data.deviceAddress = transmute(vk.DeviceAddress) instances.ptr

    // Vulkan expects an array of pointers (to arrays), one pointer per BVH to build.
    // We always build one at a time, and a TLAS always has only one geometry.
    range_info := []vk.AccelerationStructureBuildRangeInfoKHR {
        {
            primitiveCount = bvh_info.tlas_desc.instance_count
        }
    }
    range_info_ptr := raw_data(range_info)
    vk.CmdBuildAccelerationStructuresKHR(vk_cmd_buf, 1, &build_info, &range_info_ptr)
}

_cmd_begin_debug_label :: proc(cmd_buf: Command_Buffer, name: string, color: [4]f32, loc := #caller_location)
{
    if ctx.validation
    {
        ok := true
        ok &= pool_check(&ctx.command_buffers, cmd_buf, "cmd_buf", loc)
        if !ok do return
    }

    scratch, _ := acquire_scratch()
    name_cstr := strings.clone_to_cstring(name, allocator = scratch)

    vk_cmd_buf := pool_get(&ctx.command_buffers, cmd_buf).handle
    vk.CmdBeginDebugUtilsLabelEXT(vk_cmd_buf, &vk.DebugUtilsLabelEXT {
        sType = .DEBUG_UTILS_LABEL_EXT,
        pLabelName = name_cstr,
        color = color,
    })
}

_cmd_end_debug_label :: proc(cmd_buf: Command_Buffer, loc := #caller_location)
{
    if ctx.validation
    {
        ok := true
        ok &= pool_check(&ctx.command_buffers, cmd_buf, "cmd_buf", loc)
        if !ok do return
    }

    vk_cmd_buf := pool_get(&ctx.command_buffers, cmd_buf).handle
    vk.CmdEndDebugUtilsLabelEXT(vk_cmd_buf)
}

_cmd_insert_debug_label :: proc(cmd_buf: Command_Buffer, name: string, color: [4]f32, loc := #caller_location)
{
    if ctx.validation
    {
        ok := true
        ok &= pool_check(&ctx.command_buffers, cmd_buf, "cmd_buf", loc)
        if !ok do return
    }

    scratch, _ := acquire_scratch()
    name_cstr := strings.clone_to_cstring(name, allocator = scratch)

    vk_cmd_buf := pool_get(&ctx.command_buffers, cmd_buf).handle
    vk.CmdInsertDebugUtilsLabelEXT(vk_cmd_buf, &vk.DebugUtilsLabelEXT {
        sType = .DEBUG_UTILS_LABEL_EXT,
        pLabelName = name_cstr,
        color = color,
    })
}

@(private="file")
vk_check :: proc(result: vk.Result, location := #caller_location)
{
    if result != .SUCCESS {
        fatal_error("Vulkan failure: %v", result, location = location)
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
create_swapchain :: proc(swapchain_desc: Swapchain_Desc, prev_swapchain: vk.SwapchainKHR = {}) -> Swapchain
{
    scratch, _ := acquire_scratch()

    res: Swapchain

    surface_caps: vk.SurfaceCapabilitiesKHR
    vk_check(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(ctx.phys_device, ctx.surface, &surface_caps))

    image_count := max(max(2, surface_caps.minImageCount), swapchain_desc.frames_in_flight)
    if surface_caps.maxImageCount != 0 do assert(image_count <= surface_caps.maxImageCount)

    surface_format_count: u32
    vk_check(vk.GetPhysicalDeviceSurfaceFormatsKHR(ctx.phys_device, ctx.surface, &surface_format_count, nil))
    surface_formats := make([]vk.SurfaceFormatKHR, surface_format_count, allocator = scratch)
    vk_check(vk.GetPhysicalDeviceSurfaceFormatsKHR(ctx.phys_device, ctx.surface, &surface_format_count, raw_data(surface_formats)))

    surface_format := surface_formats[0]
    for candidate in surface_formats
    {
        if candidate == { .B8G8R8A8_UNORM, .SRGB_NONLINEAR }
        {
            surface_format = candidate
            break
        }
    }

    present_mode_count: u32
    vk_check(vk.GetPhysicalDeviceSurfacePresentModesKHR(ctx.phys_device, ctx.surface, &present_mode_count, nil))
    present_modes := make([]vk.PresentModeKHR, present_mode_count, allocator = scratch)
    vk_check(vk.GetPhysicalDeviceSurfacePresentModesKHR(ctx.phys_device, ctx.surface, &present_mode_count, raw_data(present_modes)))

    vk_present_mode := to_vk_present_mode(swapchain_desc.present_mode, present_modes)

    swapchain_ci := vk.SwapchainCreateInfoKHR {
        sType = .SWAPCHAIN_CREATE_INFO_KHR,
        surface = ctx.surface,
        minImageCount = image_count,
        imageFormat = surface_format.format,
        imageColorSpace = surface_format.colorSpace,
        imageExtent = { ctx.swapchain_desc.width, ctx.swapchain_desc.height },
        imageArrayLayers = 1,
        imageUsage = { .COLOR_ATTACHMENT, .TRANSFER_SRC, .TRANSFER_DST },
        preTransform = surface_caps.currentTransform,
        compositeAlpha = { .OPAQUE },
        presentMode = vk_present_mode,
        clipped = true,
        oldSwapchain = prev_swapchain,
    }
    vk_check(vk.CreateSwapchainKHR(ctx.device, &swapchain_ci, nil, &res.handle))

    vk_check(vk.GetSwapchainImagesKHR(ctx.device, res.handle, &image_count, nil))
    res.images = make([]vk.Image, image_count, context.allocator)
    res.texture_handles = make([]Texture_Handle, image_count, context.allocator)
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

        tex_info := Texture_Info { handle = image }
        append(&tex_info.views, Image_View_Info { info = image_view_ci, view = res.image_views[i] })
        res.texture_handles[i] = pool_add(&ctx.textures, tex_info, {})
    }

    res.present_semaphores = make([]Semaphore, image_count, context.allocator)

    semaphore_ci := vk.SemaphoreCreateInfo { sType = .SEMAPHORE_CREATE_INFO }
    for &semaphore in res.present_semaphores
    {
        vk_sem: vk.Semaphore
        vk_check(vk.CreateSemaphore(ctx.device, &semaphore_ci, nil, &vk_sem))
        semaphore = vk_move_semaphore(vk_sem)
    }

    return res
}

@(private="file")
destroy_swapchain :: proc(swapchain: ^Swapchain, free_handle := true)
{
    delete(swapchain.images)
    for semaphore in swapchain.present_semaphores {
        semaphore_destroy(semaphore)
    }
    delete(swapchain.present_semaphores)
    for image_view in swapchain.image_views {
        vk.DestroyImageView(ctx.device, image_view, nil)
    }
    delete(swapchain.image_views)

    if free_handle {
        vk.DestroySwapchainKHR(ctx.device, swapchain.handle, nil)
    }

    for handle in swapchain.texture_handles
    {
        tex_info := pool_get(&ctx.textures, handle)
        // Vulkan objects for views are already destroyed by destroying swapchain.image_views
        delete(tex_info.views)
        pool_remove(&ctx.textures, handle)
    }
    delete(swapchain.texture_handles)

    swapchain^ = {}
}

@(private="file")
Swapchain :: struct
{
    handle: vk.SwapchainKHR,
    images: []vk.Image,
    texture_handles: []Texture_Handle,
    image_views: []vk.ImageView,
    present_semaphores: []Semaphore,
}

@(private="file")
Swapchain_Desc :: struct
{
    width, height: u32,
    frames_in_flight: u32,
    present_mode: Present_Mode,
}

@(private="file")
get_buf_offset_from_gpu_ptr :: proc(p: gpuptr) -> (buf: vk.Buffer, offset: u32, ok: bool)
{
    if p == {} do return {}, {}, false

    alloc_impl := transmute(Alloc_Impl_Info) p._impl
    alloc_info := pool_get(&ctx.allocs, alloc_impl.handle)

    buf = alloc_info.buf_handle
    offset = u32(uintptr(p.ptr) - uintptr(alloc_info.gpu))
    return buf, offset, true
}

@(private="file")
get_buf_size_from_gpu_ptr :: proc(p: gpuptr) -> (size: vk.DeviceSize, ok: bool)
{
    if p == {} do return {}, false

    alloc_impl := transmute(Alloc_Impl_Info) p._impl
    alloc_info := pool_get(&ctx.allocs, alloc_impl.handle)
    return alloc_info.buf_size, true
}

// Command buffers
@(private="file")
vk_acquire_cmd_buf :: proc(queue: Queue) -> Command_Buffer
{
    tls_ctx := get_tls()

    // Check whether there is a free command buffer available with a timeline value
    // that is less than or equal to the current semaphore value.
    queue_elem, ok := priority_queue.pop_safe(&tls_ctx.free_buffers[queue])
    if ok
    {
        cmd_buf_info_ptr := pool_get_ptr(&ctx.command_buffers, queue_elem.handle)

        assert(!cmd_buf_info_ptr.recording)
        assert(cmd_buf_info_ptr.queue == queue)
        assert(cmd_buf_info_ptr.thread_id == sync.current_thread_id())

        cur_sem_value := semaphore_get_value(ctx.cmd_bufs_sems[queue])
        if cur_sem_value >= cmd_buf_info_ptr.timeline_value
        {
            cmd_buf_info_ptr.recording = true
            cmd_buf_info_ptr.queue = queue
            cmd_buf_info_ptr.compute_shader = {}
            cmd_buf_info_ptr.thread_id = sync.current_thread_id()
            return queue_elem.handle
        }
        else
        {
            priority_queue.push(&tls_ctx.free_buffers[queue], queue_elem)
        }
    }

    // We didn't find a command buffer that is not in a recording
    // state and that also has finished on the GPU side.

    cmd_buf_info := Command_Buffer_Info {
        recording = true,
        queue = queue,
        compute_shader = {},
        thread_id = sync.current_thread_id(),
    }

    // If no free command buffer is available, create a new one
    cmd_buf_ai := vk.CommandBufferAllocateInfo {
        sType = .COMMAND_BUFFER_ALLOCATE_INFO,
        commandPool = tls_ctx.pools[queue],
        level = .PRIMARY,
        commandBufferCount = 1,
    }
    vk_check(vk.AllocateCommandBuffers(ctx.device, &cmd_buf_ai, &cmd_buf_info.handle))

    cmd_buf := pool_add(&ctx.command_buffers, cmd_buf_info, {})
    return cmd_buf
}

@(private="file")
vk_submit_cmd_bufs :: proc(cmd_bufs: []Command_Buffer)
{
    if len(cmd_bufs) <= 0 do return

    tls_ctx := get_tls()

    // NOTE: In Vulkan, submissions have to be ordered w.r.t. the semaphore
    // values, which means that if cmd_buf A signals semaphore S with value 3,
    // and cmd_buf B signals semaphore S with value 4, A must be submitted before B.
    // So we need to lock the whole critical section from the generation of a new
    // counter all the way up until the command buffers are submitted.
    if sync.guard(&ctx.queue_lock)
    {
        for cmd_buf in cmd_bufs
        {
            cmd_buf_info_ptr := pool_get_ptr(&ctx.command_buffers, cmd_buf)
            next := ctx.cmd_bufs_counters[cmd_buf_info_ptr.queue] + 1
            ctx.cmd_bufs_counters[cmd_buf_info_ptr.queue] = next
            cmd_buf_info_ptr.timeline_value = next
        }

        scratch, _ := acquire_scratch()
        submit_infos := make([dynamic]vk.SubmitInfo, allocator = scratch)
        queue: Queue
        for cmd_buf in cmd_bufs
        {
            cmd_buf_info := pool_get(&ctx.command_buffers, cmd_buf)

            queue = cmd_buf_info.queue
            queue_sem := ctx.cmd_bufs_sems[queue]
            vk_queue_sem := pool_get(&ctx.semaphores, queue_sem)
            assert(cmd_buf_info.recording)
            assert(cmd_buf_info.thread_id == sync.current_thread_id())

            wait_count := len(cmd_buf_info.wait_sems)
            signal_count := len(cmd_buf_info.signal_sems) + 1

            wait_sems     := make([]vk.Semaphore,          wait_count,   allocator = scratch)
            wait_values   := make([]u64,                   wait_count,   allocator = scratch)
            wait_stages   := make([]vk.PipelineStageFlags, wait_count,   allocator = scratch)
            signal_sems   := make([]vk.Semaphore,          signal_count, allocator = scratch)
            signal_values := make([]u64,                   signal_count, allocator = scratch)

            for wait_sem, i in cmd_buf_info.wait_sems
            {
                wait_sems[i] = pool_get(&ctx.semaphores, wait_sem.sem)
                wait_stages[i] = { .ALL_COMMANDS }
                wait_values[i] = wait_sem.val
            }
            for signal_sem, i in cmd_buf_info.signal_sems
            {
                signal_sems[i] = pool_get(&ctx.semaphores, signal_sem.sem)
                signal_values[i] = signal_sem.val
            }

            signal_sems[signal_count - 1] = vk_queue_sem
            signal_values[signal_count - 1] = cmd_buf_info.timeline_value

            to_submit := make([]vk.CommandBuffer, 1, allocator = scratch)
            to_submit[0] = cmd_buf_info.handle

            next := new(vk.TimelineSemaphoreSubmitInfo, allocator = scratch)
            next^ = {
                sType = .TIMELINE_SEMAPHORE_SUBMIT_INFO,
                waitSemaphoreValueCount = u32(len(wait_values)),
                pWaitSemaphoreValues = raw_data(wait_values),
                signalSemaphoreValueCount = u32(len(signal_values)),
                pSignalSemaphoreValues = raw_data(signal_values),
            }
            submit_info := vk.SubmitInfo {
                sType = .SUBMIT_INFO,
                pNext = next,
                commandBufferCount = u32(len(to_submit)),
                pCommandBuffers = raw_data(to_submit),
                waitSemaphoreCount = u32(len(wait_sems)),
                pWaitSemaphores = raw_data(wait_sems),
                pWaitDstStageMask = raw_data(wait_stages),
                signalSemaphoreCount = u32(len(signal_sems)),
                pSignalSemaphores = raw_data(signal_sems),
            }
            append(&submit_infos, submit_info)
        }

        queue_info := ctx.queues[queue]
        vk_queue := queue_info.handle
        vk_check(vk.QueueSubmit(vk_queue, u32(len(submit_infos)), raw_data(submit_infos), {}))
    }

    // Recycle the command buffers
    for cmd_buf in cmd_bufs
    {
        cmd_buf_info_ptr := pool_get_ptr(&ctx.command_buffers, cmd_buf)
        cmd_buf_info_ptr.compute_shader = {}
        cmd_buf_info_ptr.recording = false
        clear(&cmd_buf_info_ptr.wait_sems)
        clear(&cmd_buf_info_ptr.signal_sems)

        to_push := Free_Command_Buffer {
            handle = cmd_buf,
            timeline_value = cmd_buf_info_ptr.timeline_value
        }
        priority_queue.push(&tls_ctx.free_buffers[cmd_buf_info_ptr.queue], to_push)
    }
}

@(private="file")
find_queue_family :: proc(graphics: bool, compute: bool, transfer: bool) -> u32
{
    {
        scratch, _ := acquire_scratch()

        family_count: u32
        vk.GetPhysicalDeviceQueueFamilyProperties(ctx.phys_device, &family_count, nil)
        family_properties := make([]vk.QueueFamilyProperties, family_count, allocator = scratch)
        vk.GetPhysicalDeviceQueueFamilyProperties(ctx.phys_device, &family_count, raw_data(family_properties))

        for props, i in family_properties
        {
            if props.queueCount == 0 do continue

            // NOTE: If a queue family supports graphics, it is required
            // to also support transfer, but it's NOT required
            // to report .TRANSFER in its queueFlags, as stated in
            // the Vulkan spec: https://docs.vulkan.org/spec/latest/chapters/devsandqueues.html
            // (Why?????????)
            supports_graphics := .GRAPHICS in props.queueFlags
            supports_compute  := .COMPUTE in props.queueFlags
            supports_transfer := .TRANSFER in props.queueFlags || supports_graphics || supports_compute

            if graphics != supports_graphics do continue
            if compute  != supports_compute  do continue
            if transfer != supports_transfer do continue

            return u32(i)
        }

        // Ideal queue family Not found. Be a little less strict now in your search.
        for props, i in family_properties
        {
            if props.queueCount == 0 do continue

            supports_graphics := .GRAPHICS in props.queueFlags
            supports_compute  := .COMPUTE in props.queueFlags
            supports_transfer := .TRANSFER in props.queueFlags || supports_graphics || supports_compute

            if graphics && !supports_graphics do continue
            if compute  && !supports_compute  do continue
            if transfer && !supports_transfer do continue

            return u32(i)
        }
    }

    panic("Queue family not found!")
}

// Interop

_vk_get_instance :: proc() -> vk.Instance
{
    return ctx.instance
}

_vk_get_physical_device :: proc() -> vk.PhysicalDevice
{
    return ctx.phys_device
}

_vk_get_device :: proc() -> vk.Device
{
    return ctx.device
}

_vk_get_queue :: proc(queue: Queue) -> vk.Queue
{
    return ctx.queues[queue].handle
}

_vk_get_queue_family :: proc(queue: Queue) -> u32
{
    return ctx.queues[queue].family_idx
}

_vk_get_command_buffer :: proc(cmd_buf: Command_Buffer) -> vk.CommandBuffer
{
    cmd_buf := pool_get(&ctx.command_buffers, cmd_buf)
    return cmd_buf.handle
}

_vk_get_swapchain_image_count :: proc() -> u32
{
    return u32(len(ctx.swapchain.images))
}

_vk_get_image :: proc(texture: Texture) -> vk.Image
{
    image := pool_get(&ctx.textures, texture.handle)
    return image.handle
}

_vk_get_buffer :: proc(addr: gpuptr) -> (vk.Buffer, u32)
{
    buf, offset, ok := get_buf_offset_from_gpu_ptr(addr)
    ensure(ok)
    return buf, offset
}

_vk_get_semaphore :: proc(semaphore: Semaphore) -> vk.Semaphore
{
    return pool_get(&ctx.semaphores, semaphore)
}

_vk_wrap_image :: proc(image: vk.Image, desc: Texture_Desc, name := "", loc := #caller_location) -> Texture
{
    desc_clean := texture_desc_cleanup(desc)

    if ctx.validation {
        ensure(image != {}, "Cannot wrap a nil VkImage.")
    }

    tex_info := Texture_Info {
        handle = image,
        owns_image = false,
    }

    return Texture {
        type = desc_clean.type,
        dimensions = desc_clean.dimensions,
        format = desc_clean.format,
        mip_count = desc_clean.mip_count,
        sample_count = desc_clean.sample_count,
        layer_count = desc_clean.layer_count,
        handle = pool_add(&ctx.textures, tex_info, { name = name, created_at = loc }),
    }
}

@(thread_local) EXTRA_OPT_DEVICE_EXTENSIONS: [dynamic]cstring
_vk_add_opt_device_extension :: proc(extension: cstring)
{
    append(&EXTRA_OPT_DEVICE_EXTENSIONS, extension)
}

@(thread_local) EXTRA_DEVICE_EXTENSIONS: [dynamic]cstring
_vk_add_device_extension :: proc(extension: cstring)
{
    append(&EXTRA_DEVICE_EXTENSIONS, extension)
}

_vk_move_semaphore :: proc(semaphore: vk.Semaphore, loc := #caller_location) -> Semaphore
{
    return pool_add(&ctx.semaphores, semaphore, { name = "", created_at = loc })
}

@(private)
to_vk_render_attachment :: #force_inline proc(attach: Render_Attachment) -> vk.RenderingAttachmentInfo
{
    view_desc := attach.view
    texture := attach.texture
    resolve_texture := attach.resolve_texture
    resolve_view_desc := attach.resolve_view

    has_output := texture != {}
    vk_image := pool_get(&ctx.textures, texture.handle).handle if has_output else vk.Image(0)
    has_resolve := resolve_texture != {}
    vk_resolve_image := pool_get(&ctx.textures, resolve_texture.handle).handle if has_resolve else vk.Image(0)

    view_desc_clean := texture_view_desc_cleanup(texture, view_desc)
    resolve_view_desc_clean := texture_view_desc_cleanup(resolve_texture, resolve_view_desc)

    plane_aspect := to_vk_image_aspect_flags(view_desc_clean.format)

    view: vk.ImageView
    if has_output
    {
        image_view_ci := vk.ImageViewCreateInfo {
            sType = .IMAGE_VIEW_CREATE_INFO,
            image = vk_image,
            viewType = to_vk_texture_view_type(view_desc_clean.type),
            format = to_vk_texture_format(view_desc_clean.format),
            subresourceRange = {
                aspectMask = plane_aspect,
                baseMipLevel = u32(view_desc_clean.base_mip),
                levelCount = u32(view_desc_clean.mip_count),
                baseArrayLayer = u32(view_desc_clean.base_layer),
                layerCount = u32(view_desc_clean.layer_count),
            }
        }
        view = get_or_add_image_view(texture.handle, image_view_ci)
    }

    resolve_view: vk.ImageView
    if has_resolve
    {
        resolve_image_view_ci := vk.ImageViewCreateInfo {
            sType = .IMAGE_VIEW_CREATE_INFO,
            image = vk_resolve_image,
            viewType = to_vk_texture_view_type(resolve_view_desc_clean.type),
            format = to_vk_texture_format(resolve_view_desc_clean.format),
            subresourceRange = {
                aspectMask = plane_aspect,
                baseMipLevel = u32(resolve_view_desc_clean.base_mip),
                levelCount = u32(resolve_view_desc_clean.mip_count),
                baseArrayLayer = u32(resolve_view_desc_clean.base_layer),
                layerCount = u32(resolve_view_desc_clean.layer_count),
            }
        }
        resolve_view = get_or_add_image_view(resolve_texture.handle, resolve_image_view_ci)
    }

    vk_store_op, vk_resolve_mode := to_vk_store_op(attach.store_op)

    return {
        sType = .RENDERING_ATTACHMENT_INFO,
        imageView = view,
        imageLayout = .GENERAL,
        loadOp = to_vk_load_op(attach.load_op),
        storeOp = vk_store_op,
        clearValue = { color = { float32 = attach.clear_color } },
        resolveMode = vk_resolve_mode,
        resolveImageView = resolve_view,
        resolveImageLayout = .GENERAL if has_resolve else {},
    }
}

//////////////////////////////////////
// Validation

@(private="file")
check_ptr :: proc(p: gpuptr, name: string, loc: runtime.Source_Code_Location) -> bool
{
    if p == {} {
        log.errorf("'%v' address is nil.", name, location = loc)
        return false
    }

    alloc_impl := transmute(Alloc_Impl_Info) p._impl
    alloc_handle := alloc_impl.handle
    if !pool_check_no_message(&ctx.allocs, alloc_handle) {
        log.errorf("'%v' address is stale, has been freed before.", name, location = loc)
        return false
    }
    alloc_info := pool_get(&ctx.allocs, alloc_handle)

    if uintptr(p.ptr) > uintptr(alloc_info.gpu) + uintptr(alloc_info.buf_size) || uintptr(p.ptr) < uintptr(alloc_info.gpu) {
        log.errorf("'%v' address is out of range for the designated allocation. %v bytes were allocated, but you're attempting to access offset %v.",
                   name, alloc_info.buf_size, i64(uintptr(p.ptr)) - i64(uintptr(alloc_info.gpu)), location = loc)
        return false
    }

    return true
}

@(private="file")
check_ptr_allow_nil :: proc(p: gpuptr, name: string, loc: runtime.Source_Code_Location) -> bool
{
    if p == {} {
        return true
    }

    alloc_impl := transmute(Alloc_Impl_Info) p._impl
    alloc_handle := alloc_impl.handle
    if !pool_check_no_message(&ctx.allocs, alloc_handle) {
        log.errorf("'%v' address is stale, has been freed before.", name, location = loc)
        return false
    }
    alloc_info := pool_get(&ctx.allocs, alloc_handle)

    if uintptr(p.ptr) > uintptr(alloc_info.gpu) + uintptr(alloc_info.buf_size) || uintptr(p.ptr) < uintptr(alloc_info.gpu) {
        log.errorf("'%v' address is out of range for the designated allocation. %v bytes were allocated, but you're attempting to access offset %v.",
                   name, alloc_info.buf_size, i64(uintptr(p.ptr)) - i64(uintptr(alloc_info.gpu)), location = loc)
        return false
    }

    return true
}

@(private="file")
check_ptr_range :: proc(p: gpuptr, #any_int size: i64, name: string, loc: runtime.Source_Code_Location) -> bool
{
    if p == {} {
        log.errorf("'%v' address is nil.", name, location = loc)
        return false
    }

    alloc_impl := transmute(Alloc_Impl_Info) p._impl
    alloc_handle := alloc_impl.handle
    if !pool_check_no_message(&ctx.allocs, alloc_handle) {
        log.errorf("'%v' address is stale, has been freed before.", name, location = loc)
        return false
    }
    alloc_info := pool_get(&ctx.allocs, alloc_handle)

    if uintptr(p.ptr) + uintptr(size) > uintptr(alloc_impl.range_end) || uintptr(p.ptr) < uintptr(alloc_info.gpu) {
        log.errorf("'%v' address is out of range for the designated allocation. %v bytes were allocated, but you're attempting to access [0, %v].",
                   name, i64(uintptr(alloc_impl.range_end)) - i64(uintptr(p.ptr)), size, location = loc)
        return true  // Proceed with execution, make sure to clamp accesses.
    }

    return true
}

check_ptr_must_not_be_suballoc :: proc(p: gpuptr, name: string, loc: runtime.Source_Code_Location) -> bool
{
    if p == {} {
        log.errorf("'%v' address is nil.", name, location = loc)
        return false
    }

    alloc_impl := transmute(Alloc_Impl_Info) p._impl
    alloc_handle := alloc_impl.handle
    if !pool_check_no_message(&ctx.allocs, alloc_handle) {
        log.errorf("'%v' address is stale, has been freed before.", name, location = loc)
        return false
    }
    alloc_info := pool_get(&ctx.allocs, alloc_handle)

    end_ptr := rawptr(uintptr(alloc_info.gpu) + uintptr(alloc_info.buf_size))
    if uintptr(alloc_impl.range_end) < uintptr(end_ptr) || uintptr(p.ptr) > uintptr(alloc_info.gpu) {
        log.errorf("'%v' address was suballocated, need an actual allocation here.", name, location = loc)
        return false
    }

    return true
}

@(private="file")
check_cmd_buf_has_compute_shader_set :: proc(cmd_buf: Command_Buffer, name: string, loc: runtime.Source_Code_Location) -> bool
{
    if !pool_check_no_message(&ctx.command_buffers, cmd_buf) do return false

    cmd_buf_info := pool_get(&ctx.command_buffers, cmd_buf)

    if cmd_buf_info.compute_shader == nil {
        log.errorf("'%v' does not have an associated compute shader. Call cmd_set_compute_shader first.", name, location = loc)
        return false
    }

    return true
}

@(private="file")
check_cmd_buf_must_be_graphics :: proc(cmd_buf: Command_Buffer, name: string, loc: runtime.Source_Code_Location) -> bool
{
    if !pool_check_no_message(&ctx.command_buffers, cmd_buf) do return false

    cmd_buf_info := pool_get(&ctx.command_buffers, cmd_buf)
    if cmd_buf_info.queue != .Main {
        log.errorf("'%v' must be of type '%v', got type '%v'.", name, Queue.Main, cmd_buf_info.queue, location = loc)
        return false
    }

    return true
}

@(private="file")
check_cmd_buf_must_be_recording :: proc(cmd_buf: Command_Buffer, name: string, loc: runtime.Source_Code_Location) -> bool
{
    if !pool_check_no_message(&ctx.command_buffers, cmd_buf) do return false

    cmd_buf_info := pool_get(&ctx.command_buffers, cmd_buf)
    if !cmd_buf_info.recording {
        log.errorf("'%v' must be in a recording state, it's illegal to reuse a command buffer after submit. Command buffers are temporary handles.", name, location = loc)
        return false
    }

    return true
}

@(private="file")
check_bvh_must_be_tlas :: proc(bvh: BVH, name: string, loc: runtime.Source_Code_Location) -> bool
{
    bvh_info := pool_get(&ctx.bvhs, bvh)
    if bvh_info.is_blas {
        log.errorf("'%v' must be a TLAS.", name, location = loc)
        return false
    }

    return true
}

@(private="file")
check_bvh_must_be_blas :: proc(bvh: BVH, name: string, loc: runtime.Source_Code_Location) -> bool
{
    bvh_info := pool_get(&ctx.bvhs, bvh)
    if !bvh_info.is_blas {
        log.errorf("'%v' must be a BLAS.", name, location = loc)
        return false
    }

    return true
}

@(private="file")
check_texture_descriptor :: proc(desc: Texture_Descriptor, name: string, index: int, loc: runtime.Source_Code_Location) -> bool
{
    if desc == {} || texture_descriptor_get_handle(desc) == {} {
        log.errorf("'%v[%v]' texture descriptor is nil.", name, index, location = loc)
        return false
    }

    if !pool_check_no_message(&ctx.textures, texture_descriptor_get_handle(desc)) {
        log.errorf("'%v[%v]' texture descriptor is stale, the underlying texture has been freed.", name, index, location = loc)
        return false
    }

    return true
}

@(private="file")
texture_descriptor_get_handle :: #force_inline proc(desc: Texture_Descriptor) -> Texture_Handle
{
    return transmute(Texture_Handle) (cast([2]u64)desc)[0]
}

@(private="file")
texture_descriptor_get_vk_view :: #force_inline proc(desc: Texture_Descriptor) -> vk.ImageView
{
    return cast(vk.ImageView) (cast([2]u64)desc)[1]
}

vk_set_debug_name :: proc(name: string, handle: u64, type: vk.ObjectType)
{
    if name == "" || !ctx.validation do return

    scratch, _ := acquire_scratch()
    name_cstr := strings.clone_to_cstring(name, allocator = scratch)

    vk.SetDebugUtilsObjectNameEXT(ctx.device, &vk.DebugUtilsObjectNameInfoEXT {
        sType = .DEBUG_UTILS_OBJECT_NAME_INFO_EXT,
        objectType = type,
        objectHandle = handle,
        pObjectName = name_cstr,
    })
}

@(private="file")
supports_indirect_multi_draw :: proc(loc: runtime.Source_Code_Location) -> bool
{
    if .Draw_Indirect_Multi not_in ctx.features
    {
        log.errorf("'cmd_draw_indexed_indirect_multi*' is not supported on this device.", location = loc)
        return false
    }

    return true
}