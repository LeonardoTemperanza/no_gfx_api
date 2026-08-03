package vma

when ODIN_OS == .Linux {
	@(require, extra_linker_flags = "-lstdc++")
	foreign import stdcpp "system:stdc++"
}
when ODIN_OS == .Darwin {
	@(require)
	foreign import stdcpp "system:c++"
}

when ODIN_OS == .Windows {
	when ODIN_ARCH == .amd64 {
		@(extra_linker_flags="/NODEFAULTLIB:libcmt /NODEFAULTLIB:libucrt")
		foreign import _lib_ "vma_windows_x86_64.lib"
	} else when ODIN_ARCH == .arm64 {
		@(extra_linker_flags="/NODEFAULTLIB:libcmt /NODEFAULTLIB:libucrt")
		foreign import _lib_ "vma_windows_ARM64.lib"
	} else {
		#panic("Unsupported architecture for VMA library on Windows")
	}
} else when ODIN_OS == .Darwin {
	when ODIN_ARCH == .amd64 {
		foreign import _lib_ "libvma_macosx_x86_64.a"
	} else when ODIN_ARCH == .arm64 {
		foreign import _lib_ "libvma_macosx_ARM64.a"
	} else {
		#panic("Unsupported architecture for VMA library on MacOSX")
	}
} else when ODIN_OS == .Linux {
	when ODIN_ARCH == .amd64 {
		foreign import _lib_ "libvma_linux_x86_64.a"
	} else when ODIN_ARCH == .arm64 {
		foreign import _lib_ "libvma_linux_ARM64.a"
	} else {
		#panic("Unsupported architecture for VMA library on Linux")
	}
} else {
	foreign import _lib_ "system:libvma"
}

// Vendor
import vk "vendor:vulkan"

// Flags for created `Allocator`.
Allocator_Create_Flags :: bit_set[Allocator_Create_Flag;u32]
Allocator_Create_Flag :: enum u32 {
	// Allocator and all objects created from it will not be synchronized
	// internally, so you must  guarantee they are used from only one thread at a
	// time or synchronized externally by you.
	//
	// Using this flag may increase performance because internal mutexes are not
	// used.
	Externally_Synchronized,

	// Enables usage of `VK_KHR_dedicated_allocation` extension.
	//
	// The flag works only if `Allocator_Create_Info.vulkan_api_version ==
	// vk.API_VERSION_1_0`. When it is `vk.API_VERSION_1_1`, the flag is ignored
	// because the extension has been promoted to Vulkan 1.1.
	//
	// Using this extension will automatically allocate dedicated blocks of memory
	// for some buffers and images instead of suballocating place for them out of
	// bigger memory blocks (as if you explicitly used
	// `Allocation_Create_Flag.Dedicated_Memory` flag) when it is recommended by
	// the driver. It may improve performance on some GPUs.
	//
	// You may set this flag only if you found out that following device
	// extensions are supported, you enabled them while creating Vulkan device
	// passed as `Allocator_Create_Info.device`, and you want them to be used
	// internally by this library:
	//
	// - `VK_KHR_get_memory_requirements2` (device extension)
	// - `VK_KHR_dedicated_allocation` (device extension)
	//
	// When this flag is set, you can experience following warnings reported by
	// Vulkan validation layer. You can ignore them.
	//
	// - vkBindBufferMemory(): Binding memory to buffer 0x2d but
	// - vkGetBufferMemoryRequirements() has not been called on that buffer.
	Khr_Dedicated_Allocation,

	// Enables usage of `VK_KHR_bind_memory2` extension.
	//
	// The flag works only if `Allocator_Create_Info.vulkan_api_version ==
	// vk.API_VERSION_1_0`. When it is `vk.API_VERSION_1_1`, the flag is ignored
	// because the extension has been promoted to Vulkan 1.1.
	//
	// You may set this flag only if you found out that this device extension is
	// supported, you enabled it while creating Vulkan device passed as
	// `Allocator_Create_Info.device`, and you want it to be used internally by
	// this library.
	//
	// The extension provides functions `vk.BindBufferMemory2KHR` and
	// `vk.BindImageMemory2KHR`, which allow to pass a chain of `pNext` structures
	// while binding. This flag is required if you use `pNext` parameter in
	// `vk.aBindBufferMemory2()` or `vk.aBindImageMemory2()`.
	Khr_Bind_Memory2,

	// Enables usage of `VK_EXT_memory_budget` extension.
	//
	// You may set this flag only if you found out that this device extension is
	// supported, you enabled it while creating Vulkan device passed as
	// `Allocator_Create_Info.device`, and you want it to be used internally by
	// this library, along with another instance extension
	// `VK_KHR_get_physical_device_properties2`, which is required by it (or
	// Vulkan 1.1, where this extension is promoted).
	//
	// The extension provides query for current memory usage and budget, which
	// will probably be more accurate than an estimation used by the library
	// otherwise.
	Ext_Memory_Budget,

	// Enables usage of `VK_AMD_device_coherent_memory` extension.
	//
	// You may set this flag only if you:
	//
	// - found out that this device extension is supported and enabled it while
	//   creating Vulkan device passed as `Allocator_Create_Info.device`,
	// - checked that
	//   `vk.PhysicalDeviceCoherentMemoryFeaturesAMD.deviceCoherentMemory` is true
	//   and set it while creating the Vulkan device,
	// - want it to be used internally by this library.
	//
	// The extension and accompanying device feature provide access to memory
	// types with `VK_MEMORY_PROPERTY_DEVICE_COHERENT_AMD` and
	// `VK_MEMORY_PROPERTY_DEVICE_UNCACHED_AMD` flags. They are useful mostly for
	// writing breadcrumb markers - a common method for debugging GPU
	// crash/hang/TDR.
	//
	// When the extension is not enabled, such memory types are still enumerated,
	// but their usage is illegal. To protect from this error, if you don't create
	// the allocator with this flag, it will refuse to allocate any memory or
	// create a custom pool in such memory type, returning
	// `vk.ERROR_FEATURE_NOT_PRESENT`.
	Amd_Device_Coherent_Memory,
	Buffer_Device_Address,
	Ext_Memory_Priority,
	Khr_Maintenance4,
	Khr_Maintenance5,
	Khr_External_Memory_Win32,
}

// Intended usage of the allocated memory.
Memory_Usage :: enum u32 {
	// No intended memory usage specified. Use other members of
	// `Allocation_Create_Info` to specify your requirements.
	Unknown,
	Gpu_Only,
	Cpu_Only,
	Cpu_To_Gpu,
	Gpu_To_Cpu,
	Cpu_Copy,
	Gpu_Lazily_Allocated,
	Auto,
	Auto_Prefer_Device,
	Auto_Prefer_Host,
}

// Flags to be passed as Allocation_Create_Info::flags.
Allocation_Create_Flags :: bit_set[Allocation_Create_Flag;u32]
Allocation_Create_Flag :: enum u32 {
	Dedicated_Memory                   = 0,
	Never_Allocate                     = 1,
	Mapped                             = 2,
	User_Data_Copy_String              = 5,
	Upper_Address                      = 6,
	Dont_Bind                          = 7,
	Within_Budget                      = 8,
	Can_Alias                          = 9,
	Host_Access_Sequential_Write       = 10,
	Host_Access_Random                 = 11,
	Host_Access_Allow_Transfer_Instead = 12,
	Strategy_Min_Memory                = 16,
	Strategy_Min_Time                  = 17,
	Strategy_Min_Offset                = 18,
}

ALLOCATION_CREATE_STRATEGY_BEST_FIT :: Allocation_Create_Flags{.Strategy_Min_Memory}
ALLOCATION_CREATE_STRATEGY_FIRST_FIT :: Allocation_Create_Flags{.Strategy_Min_Time}
ALLOCATION_CREATE_STRATEGY_MASK :: Allocation_Create_Flags {
	.Strategy_Min_Memory,
	.Strategy_Min_Time,
	.Strategy_Min_Offset,
}

// Flags to be passed as VmaPoolCreateInfo::flags.
Pool_Create_Flags :: bit_set[Pool_Create_Flag;u32]
Pool_Create_Flag :: enum u32 {
	Ignore_Buffer_Image_Granularity = 1,
	Linear_Algorithm                = 2,
}

POOL_CREATE_ALGORITHM_MASK :: Pool_Create_Flags{.Linear_Algorithm}

// Flags to be passed as VmaDefragmentationInfo::flags.
Defragmentation_Flags :: bit_set[Defragmentation_Flag;u32]
Defragmentation_Flag :: enum u32 {
	Algorithm_Fast,
	Algorithm_Balanced,
	Algorithm_Full,
	Algorithm_Extensive,
}

// A bit mask to extract only `ALGORITHM` bits from entire set of flags.
DEFRAGMENTATION_ALGORITHM_MASK :: Defragmentation_Flags {
	.Algorithm_Fast,
	.Algorithm_Balanced,
	.Algorithm_Full,
	.Algorithm_Extensive,
}

// Operation performed on single defragmentation move. See structure
// #VmaDefragmentationMove.
Defragmentation_Move_Operation :: enum u32 {
	// Buffer/image has been recreated at `dstTmpAllocation`, data has been
	// copied, old buffer/image has been destroyed. `srcAllocation` should be
	// changed to point to the new place. This is the default value set by
	// vm.begin_defragmentation_pass().
	Operation_Copy,

	// Set this value if you cannot move the allocation. New place reserved at
	// `dstTmpAllocation` will be freed. `srcAllocation` will remain unchanged.
	Operation_Ignore,

	// Set this value if you decide to abandon the allocation and you destroyed
	// the buffer/image. New place reserved at `dstTmpAllocation` will be freed,
	// along with `srcAllocation`, which will be destroyed.
	Operation_Destroy,
}

// Flags to be passed as `Virtual_Block_Create_Info.flags`.
Virtual_Block_Create_Flags :: bit_set[Virtual_Block_Create_Flag;u32]
Virtual_Block_Create_Flag :: enum u32 {
	Linear_Algorithm,
}

VIRTUAL_BLOCK_CREATE_ALGORITHM_MASK :: Virtual_Block_Create_Flags{.Linear_Algorithm}

// Flags to be passed as Virtual_Allocation_Create_Info.flags.
Virtual_Allocation_Create_Flags :: bit_set[Virtual_Allocation_Create_Flag;u32]
Virtual_Allocation_Create_Flag :: enum u32 {
	Upper_Address       = 7,
	Strategy_Min_Memory = 16,
	Strategy_Min_Time   = 17,
	Strategy_Min_Offset = 18,
}

VIRTUAL_ALLOCATION_CREATE_STRATEGY_MASK :: Virtual_Allocation_Create_Flags {
	.Strategy_Min_Memory,
	.Strategy_Min_Time,
	.Strategy_Min_Offset,
}

// Represents main object of this library initialized.
//
// Fill structure `Allocator_Create_Info` and call procedure `create_allocator()` to create it.
// Call procedure `destroy_allocator()` to destroy it.
//
// It is recommended to create just one object of this type per `VkDevice` object, right after
// Vulkan is initialized and keep it alive until before Vulkan device is destroyed.
Allocator :: distinct rawptr

// Represents custom memory pool
//
// Fill structure `Pool_Create_Info` and call procedure `create_pool()` to create it. Call
// procedure `destroy_pool()` to destroy it.
Pool :: distinct rawptr

// Represents single memory allocation.
//
// It may be either dedicated block of `VkDeviceMemory` or a specific region of a bigger block
// of this type plus unique offset.
//
// There are multiple ways to create such object. You need to fill structure
// VmaAllocationCreateInfo.
//
// Although the library provides convenience procedures that create Vulkan buffer or image,
// allocate memory for it and bind them together, binding of the allocation to a buffer or an
// image is out of scope of the allocation itself. Allocation object can exist without
// buffer/image bound, binding can be done manually by the user, and destruction of it can be
// done independently of destruction of the allocation.
//
// The object also remembers its size and some other information. To retrieve this information,
// use procedure vmaGetAllocationInfo() and inspect returned structure VmaAllocationInfo.
Allocation :: distinct rawptr

// An opaque object that represents started defragmentation process.
Defragmentation_Context :: distinct rawptr

// Represents single memory allocation done inside VmaVirtualBlock.
Virtual_Allocation :: vk.NonDispatchableHandle

// Handle to a virtual block object that allows to use core allocation algorithm without
// allocating any real GPU memory.
Virtual_Block :: distinct rawptr

/* Callback procedure called after successful `vkAllocateMemory`. */
Allocate_Device_Memory_Proc :: #type proc "c" (
	allocator: Allocator,
	memory_type: u32,
	memory: vk.DeviceMemory,
	size: vk.DeviceSize,
	user_data: rawptr,
)

// Callback procedure called before vkFreeMemory.
Free_Device_Memory_Proc :: #type proc "c" (
	allocator: Allocator,
	memory_type: u32,
	memory: vk.DeviceMemory,
	size: vk.DeviceSize,
	user_data: rawptr,
)

// Set of callbacks that the library will call for `vkAllocateMemory` and `vkFreeMemory`.
Device_Memory_Callbacks :: struct {
	// Optional, can be nil.
	allocate_proc: Allocate_Device_Memory_Proc,
	// Optional, can be nil.
	free_proc:     Free_Device_Memory_Proc,
	// Optional, can be nil.
	user_data:     rawptr,
}

// Pointers to some Vulkan procedures - a subset used by the library.
Vulkan_Functions :: struct {
	_unused_1:                                  proc(), // vk.ProcGetInstanceProcAddr
	_unused_2:                                  proc(), // vk.ProcGetDeviceProcAddr
	get_physical_device_properties:             vk.ProcGetPhysicalDeviceProperties,
	get_physical_device_memory_properties:      vk.ProcGetPhysicalDeviceMemoryProperties,
	allocate_memory:                            vk.ProcAllocateMemory,
	free_memory:                                vk.ProcFreeMemory,
	map_memory:                                 vk.ProcMapMemory,
	unmap_memory:                               vk.ProcUnmapMemory,
	flush_mapped_memory_ranges:                 vk.ProcFlushMappedMemoryRanges,
	invalidate_mapped_memory_ranges:            vk.ProcInvalidateMappedMemoryRanges,
	bind_buffer_memory:                         vk.ProcBindBufferMemory,
	bind_image_memory:                          vk.ProcBindImageMemory,
	get_buffer_memory_requirements:             vk.ProcGetBufferMemoryRequirements,
	get_image_memory_requirements:              vk.ProcGetImageMemoryRequirements,
	create_buffer:                              vk.ProcCreateBuffer,
	destroy_buffer:                             vk.ProcDestroyBuffer,
	create_image:                               vk.ProcCreateImage,
	destroy_image:                              vk.ProcDestroyImage,
	cmd_copy_buffer:                            vk.ProcCmdCopyBuffer,
	get_buffer_memory_requirements2_khr:        vk.ProcGetBufferMemoryRequirements2KHR,
	get_image_memory_requirements2_khr:         vk.ProcGetImageMemoryRequirements2KHR,
	bind_buffer_memory2_khr:                    vk.ProcBindBufferMemory2KHR,
	bind_image_memory2_khr:                     vk.ProcBindImageMemory2KHR,
	get_physical_device_memory_properties2_khr: vk.ProcGetPhysicalDeviceMemoryProperties2KHR,
	get_device_buffer_memory_requirements:      vk.ProcGetDeviceBufferMemoryRequirementsKHR,
	get_device_image_memory_requirements:       vk.ProcGetDeviceImageMemoryRequirementsKHR,
	get_memory_win32_handle_khr:                vk.ProcGetMemoryWin32HandleKHR,
}

// Description of a Allocator to be created.
Allocator_Create_Info :: struct {
	// Flags for created allocator.
	flags:                             Allocator_Create_Flags,
	// Vulkan physical device.
	physical_device:                   vk.PhysicalDevice,
	// Vulkan device.
	device:                            vk.Device,
	// Preferred size of a single `vk.DeviceMemory` block to be allocated from
	// large heaps > 1 GiB. Optional.
	preferred_large_heap_block_size:   vk.DeviceSize,
	// Custom CPU memory allocation callbacks. Optional.
	allocation_callbacks:              ^vk.AllocationCallbacks,
	// Informative callbacks for `vkAllocateMemory`, `vkFreeMemory`. Optional.
	device_memory_callbacks:           ^Device_Memory_Callbacks,
	heap_size_limit:                   [^]vk.DeviceSize,
	vulkan_functions:                  ^Vulkan_Functions,
	instance:                          vk.Instance,
	vulkan_api_version:                u32,
	type_external_memory_handle_types: ^vk.ExternalMemoryHandleTypeFlagsKHR,
}

// Information about existing `Allocator` object.
Allocator_Info :: struct {
	instance:        vk.Instance,
	physical_device: vk.PhysicalDevice,
	device:          vk.Device,
}

// Calculated statistics of memory usage e.g. in a specific memory type, heap, custom pool, or
// total.
Statistics :: struct {
	block_count:      u32,
	allocation_count: u32,
	block_bytes:      vk.DeviceSize,
	allocation_bytes: vk.DeviceSize,
}

// More detailed statistics than #VmaStatistics.
Detailed_Statistics :: struct {
	// Basic statistics.
	statistics:            Statistics,
	// Number of free ranges of memory between allocations.
	unused_range_count:    u32,
	// Smallest allocation size. `vk.WHOLE_SIZE` if there are 0 allocations.
	allocation_size_min:   vk.DeviceSize,
	// Largest allocation size. 0 if there are 0 allocations.
	allocation_size_max:   vk.DeviceSize,
	// Smallest empty range size. `vk.WHOLE_SIZE` if there are 0 empty ranges.
	unused_range_size_min: vk.DeviceSize,
	// Largest empty range size. 0 if there are 0 empty ranges.
	unused_range_size_max: vk.DeviceSize,
}

// General statistics from current state of the Allocator - total memory usage across all
// memory heaps and types.
Total_Statistics :: struct {
	memory_type: [vk.MAX_MEMORY_TYPES]Detailed_Statistics,
	memory_heap: [vk.MAX_MEMORY_HEAPS]Detailed_Statistics,
	total:       Detailed_Statistics,
}

// Statistics of current memory usage and available budget for a specific memory heap.
Budget :: struct {
	statistics: Statistics,
	usage:      vk.DeviceSize,
	budget:     vk.DeviceSize,
}

// Parameters of new `Allocation`.
Allocation_Create_Info :: struct {
	flags:            Allocation_Create_Flags,
	usage:            Memory_Usage,
	required_flags:   vk.MemoryPropertyFlags,
	preferred_flags:  vk.MemoryPropertyFlags,
	memory_type_bits: u32,
	pool:             Pool,
	user_data:        rawptr,
	priority:         f32,
}

// Describes parameter of created #VmaPool.
Pool_Create_Info :: struct {
	memory_type_index:        u32,
	flags:                    Pool_Create_Flags,
	block_size:               vk.DeviceSize,
	min_block_count:          uint,
	max_block_count:          uint,
	priority:                 f32,
	min_allocation_alignment: vk.DeviceSize,
	memory_allocate_next:     rawptr,
}

// Parameters of `Allocation` objects, that can be retrieved using procedure
// `get_allocation_info()`.
Allocation_Info :: struct {
	memory_type:   u32,
	device_memory: vk.DeviceMemory,
	offset:        vk.DeviceSize,
	size:          vk.DeviceSize,
	mapped_data:   rawptr,
	user_data:     rawptr,
	name:          cstring,
}

// Extended parameters of a #VmaAllocation object that can be retrieved using procedure
// `get_allocation_info2()`.
Allocation_Info2 :: struct {
	allocation_info:  Allocation_Info,
	block_size:       vk.DeviceSize,
	dedicated_memory: b32,
}

// Callback procedure called during `begin_defragmentation()` to check custom criterion about
// ending current defragmentation pass.
Check_Defragmentation_Break_Proc :: #type proc "c" (user_data: rawptr) -> b32

// Parameters for defragmentation.
Defragmentation_Info :: struct {
	// Use combination of #VmaDefragmentationFlagBits.
	flags:                    Defragmentation_Flags,
	pool:                     Pool,
	max_bytes_per_pass:       vk.DeviceSize,
	max_allocations_per_pass: u32,
	proc_break_callback:      Check_Defragmentation_Break_Proc,
	// Optional data to pass to custom callback for stopping pass of defragmentation.
	break_callback_user_data: rawptr,
}

// Single move of an allocation to be done for defragmentation.
Defragmentation_Move :: struct {
	// Operation to be performed on the allocation by vmaEndDefragmentationPass(). Default
	// value is #VMA_DEFRAGMENTATION_MOVE_OPERATION_COPY. You can modify it.
	operation:          Defragmentation_Move_Operation,
	// Allocation that should be moved.
	src_allocation:     Allocation,
	dst_tmp_allocation: Allocation,
}

Defragmentation_Pass_Move_Info :: struct {
	// Number of elements in the `moves` array.
	move_count: u32,
	moves:      [^]Defragmentation_Move,
}

// Statistics returned for defragmentation process in procedure `end_defragmentation()`.
Defragmentation_Stats :: struct {
	// Total number of bytes that have been copied while moving allocations to different
	// places.
	bytes_moved:                vk.DeviceSize,
	// Total number of bytes that have been released to the system by freeing empty
	// `vk.DeviceMemory` objects.
	bytes_freed:                vk.DeviceSize,
	// Number of allocations that have been moved to different places.
	allocations_moved:          u32,
	// Number of empty `vk.DeviceMemory` objects that have been released to the system.
	device_memory_blocks_freed: u32,
}

// Parameters of created `Virtual_Block` object to be passed to `create_virtual_block()`.
Virtual_Block_Create_Info :: struct {
	size:                 vk.DeviceSize,
	flags:                Virtual_Block_Create_Flags,
	allocation_callbacks: ^vk.AllocationCallbacks,
}

// Parameters of created virtual allocation to be passed to `virtual_allocate()`.
Virtual_Allocation_Create_Info :: struct {
	size:      vk.DeviceSize,
	alignment: vk.DeviceSize,
	flags:     Virtual_Allocation_Create_Flags,
	user_data: rawptr,
}

// Parameters of an existing virtual allocation, returned by `get_virtual_allocation_info()`.
Virtual_Allocation_Info :: struct {
	offset:    vk.DeviceSize,
	size:      vk.DeviceSize,
	user_data: rawptr,
}

// Bind vulkan procedures to vma.
create_vulkan_functions :: proc() -> (procedures: Vulkan_Functions) {
	procedures = Vulkan_Functions {
		get_physical_device_properties             = vk.GetPhysicalDeviceProperties,
		get_physical_device_memory_properties      = vk.GetPhysicalDeviceMemoryProperties,
		allocate_memory                            = vk.AllocateMemory,
		free_memory                                = vk.FreeMemory,
		map_memory                                 = vk.MapMemory,
		unmap_memory                               = vk.UnmapMemory,
		flush_mapped_memory_ranges                 = vk.FlushMappedMemoryRanges,
		invalidate_mapped_memory_ranges            = vk.InvalidateMappedMemoryRanges,
		bind_buffer_memory                         = vk.BindBufferMemory,
		bind_image_memory                          = vk.BindImageMemory,
		get_buffer_memory_requirements             = vk.GetBufferMemoryRequirements,
		get_image_memory_requirements              = vk.GetImageMemoryRequirements,
		create_buffer                              = vk.CreateBuffer,
		destroy_buffer                             = vk.DestroyBuffer,
		create_image                               = vk.CreateImage,
		destroy_image                              = vk.DestroyImage,
		cmd_copy_buffer                            = vk.CmdCopyBuffer,
		get_buffer_memory_requirements2_khr        = vk.GetBufferMemoryRequirements2KHR,
		get_image_memory_requirements2_khr         = vk.GetImageMemoryRequirements2KHR,
		bind_buffer_memory2_khr                    = vk.BindBufferMemory2KHR,
		bind_image_memory2_khr                     = vk.BindImageMemory2KHR,
		get_physical_device_memory_properties2_khr = vk.GetPhysicalDeviceMemoryProperties2KHR,
		get_device_buffer_memory_requirements      = vk.GetDeviceBufferMemoryRequirements,
		get_device_image_memory_requirements       = vk.GetDeviceImageMemoryRequirements,
		get_memory_win32_handle_khr                = vk.GetMemoryWin32HandleKHR,
	}

	return
}

VK_VERSION_MAJOR :: proc(version: u32) -> u32 {
	return (version >> 22) & 0x7F
}

VK_VERSION_MINOR :: proc(version: u32) -> u32 {
	return (version >> 12) & 0x3FF
}

VK_VERSION_PATCH :: proc(version: u32) -> u32 {
	return version & 0xFFF
}

// Convert between Vulkan's bit-packed version to decimal "MMmmppp" format.
//
// `api_version` should be a value from the api or constructed with `vk.MAKE_VERSION`.
VK_API_VERSION_TO_DECIMAL :: proc(api_version: u32) -> u32 {
    major := VK_VERSION_MAJOR(api_version) * 1000000
    minor := VK_VERSION_MINOR(api_version) * 1000
    patch := VK_VERSION_PATCH(api_version)
    return major + minor + patch
}

// odinfmt: disable
@(default_calling_convention = "c")
foreign _lib_ {
	// Creates `Allocator` object.
	@(link_name = "vmaCreateAllocator")
	create_allocator :: proc(
		#by_ptr create_info: Allocator_Create_Info,
		allocator: ^Allocator) -> vk.Result ---

	// Destroys allocator object.
	@(link_name = "vmaDestroyAllocator")
	destroy_allocator :: proc(allocator: Allocator) ---

	// Returns information about existing `Allocator` object - handle to Vulkan
	// device etc.
	//
	// It might be useful if you want to keep just the `Allocator` handle and
	// fetch other required handles to `vk.PhysicalDevice`, `vk.Device` etc. every
	// time using this procedure.
	@(link_name = "vmaGetAllocatorInfo")
	get_allocator_info :: proc(
		allocator: Allocator,
		allocator_info: ^Allocator_Info) ---

	// `vk.PhysicalDeviceProperties` are fetched from physicalDevice by the
	// allocator. You can access it here, without fetching it again on your own.
	@(link_name = "vmaGetPhysicalDeviceProperties")
	get_physical_device_properties :: proc(
		allocator: Allocator,
		physical_device_properties: ^^vk.PhysicalDeviceProperties) ---

	// `vk.PhysicalDeviceMemoryProperties` are fetched from physicalDevice by the
	// allocator. You can access it here, without fetching it again on your own.
	@(link_name = "vmaGetMemoryProperties")
	get_memory_properties :: proc(
		allocator: Allocator,
		physical_device_memory_properties: ^^vk.PhysicalDeviceMemoryProperties) ---

	// Given Memory Type Index, returns Property Flags of this memory type.
	//
	// This is just a convenience procedure. Same information can be obtained
	// using `get_memory_properties()`.
	@(link_name = "vmaGetMemoryTypeProperties")
	get_memory_type_properties :: proc(
		allocator: Allocator,
		memory_type_index: u32,
		flags: ^vk.MemoryPropertyFlags) ---

	// Sets index of the current frame.
	@(link_name = "vmaSetCurrentFrameIndex")
	set_current_frame_index :: proc(
		allocator: Allocator,
		frame_index: u32) ---

	// Retrieves statistics from current state of the Allocator.
	//
	// This procedure is called "calculate" not "get" because it has to traverse
	// all internal data structures, so it may be quite slow. Use it for debugging
	// purposes. For faster but more brief statistics suitable to be called every
	// frame or every allocation, use `get_heap_budgets()`.
	//
	// Note that when using allocator from multiple threads, returned information
	// may immediately become outdated.
	@(link_name = "vmaCalculateStatistics")
	calculate_statistics :: proc(
		allocator: Allocator,
		stats: ^Total_Statistics) ---

	// Retrieves information about current memory usage and budget for all memory
	// heaps.
	//
	// `budgets` must point to array with number of elements at least equal to
	// number of memory heaps in physical device used.
	//
	// This procedure is called "get" not "calculate" because it is very fast,
	// suitable to be called every frame or every allocation. For more detailed
	// statistics use `calculate_statistics()`.
	//
	// Note that when using allocator from multiple threads, returned information
	// may immediately become outdated.
	@(link_name = "vmaGetHeapBudgets")
	get_heap_budgets :: proc(
		allocator: Allocator,
		budgets: [^]Budget) ---

	// Helps to find `memory_type_index`, given `memory_type_bits` and
	// `allocation_create_info`.
	//
	// This algorithm tries to find a memory type that:
	//
	// - Is allowed by `memory_type_bits`.
	// - Contains all the flags from `allocation_create_info.required_flags`.
	// - Matches intended usage.
	// - Has as many flags from `allocation_create_info.preferred_flags` as
	//   possible.
	//
	// Returns `ERROR_FEATURE_NOT_PRESENT` if not found. Receiving such result
	// from this PROCEDURE or any other allocating PROCEDURE probably means that
	// your device doesn't support any memory type with requested features for the
	// specific type of resource you want to use it for. Please check parameters
	// of your resource, like image layout (OPTIMAL versus LINEAR) or mip level
	// count.
	@(link_name = "vmaFindMemoryTypeIndex")
	find_memory_type_index :: proc(
		allocator: Allocator,
		memory_type_bits: u32,
		#by_ptr allocation_create_info: Allocation_Create_Info,
		memory_type_index: ^u32) -> vk.Result ---

	// Helps to find `memory_type_index`, given `vk.BufferCreateInfo` and
	// `Allocation_Create_Info`.
	//
	// It can be useful e.g. to determine value to be used as
	// `Pool_Create_Info.memory_type_index`. It internally creates a temporary,
	// dummy buffer that never has memory bound.
	@(link_name = "vmaFindMemoryTypeIndexForBufferInfo")
	find_memory_type_index_for_buffer_info :: proc(
		allocator: Allocator,
		#by_ptr buffer_create_info: vk.BufferCreateInfo,
		#by_ptr allocation_create_info: Allocation_Create_Info,
		memory_type_index: ^u32) -> vk.Result ---

	// Find `memory_type_index`, given `vk.ImageCreateInfo` and `Allocation_Create_Info`.
	//
	// It can be useful e.g. to determine value to be used as
	// `Pool_Create_Info.memory_type_index`. It internally creates a temporary,
	// dummy image
	// that never has memory bound.
	@(link_name = "vmaFindMemoryTypeIndexForImageInfo")
	find_memory_type_index_for_image_info :: proc(
		allocator: Allocator,
		#by_ptr image_create_info: vk.ImageCreateInfo,
		#by_ptr allocation_create_info: Allocation_Create_Info,
		memory_type_index: ^u32) -> vk.Result ---

	// Allocates Vulkan device memory and creates `Pool` object.
	@(link_name = "vmaCreatePool")
	create_pool :: proc(
		allocator: Allocator,
		#by_ptr create_info: Pool_Create_Info,
		pool: ^Pool) -> vk.Result ---

	// Destroys `Pool` object and frees Vulkan device memory.
	@(link_name = "vmaDestroyPool")
	destroy_pool :: proc(
		allocator: Allocator,
		pool: Pool) ---

	// Retrieves statistics of existing `Pool` object.
	//
	// Note that when using the pool from multiple threads, returned information
	// may immediately become outdated.
	@(link_name = "vmaGetPoolStatistics")
	get_pool_statistics :: proc(
		allocator: Allocator,
		pool: Pool,
		pool_stats: ^Statistics) ---

	// Retrieves detailed statistics of existing `Pool` object.
	@(link_name = "vmaCalculatePoolStatistics")
	calculate_pool_statistics :: proc(
		allocator: Allocator,
		pool: Pool,
		pool_stats: ^Detailed_Statistics) ---

	// Checks magic number in margins around all allocations in given memory pool
	// in search for corruptions.
	@(link_name = "vmaCheckPoolCorruption")
	check_pool_corruption :: proc(
		allocator: Allocator,
		pool: Pool) -> vk.Result ---

	// Retrieves name of a custom pool.
	//
	// After the call `name` is either nil or points to an internally-owned
	// `nil`-terminated string containing name of the pool that was previously
	// set. The pointer becomes invalid when the pool is destroyed or its name is
	// changed using `set_pool_name()`.
	@(link_name = "vmaGetPoolName")
	get_pool_name :: proc(
		allocator: Allocator,
		pool: Pool,
		name: ^cstring) ---

	// Sets name of a custom pool.
	//
	// `name` can be either nil or pointer to a `nil`-terminated string with new
	// name for the pool. Procedure makes internal copy of the string, so it can
	// be changed or freed immediately after this call.
	@(link_name = "vmaSetPoolName")
	set_pool_name :: proc(
		allocator: Allocator,
		pool: Pool,
		name: cstring) ---

	// General purpose memory allocation.
	//
	// Inputs:
	// - `allocator`
	// - `memory_requirements`
	// - `create_info`
	// - [out] `allocation` Handle to allocated memory.
	// - [out] `allocation_info` Optional. Information about allocated memory. It
	//   can be later fetched using PROCEDURE `get_allocation_info()`.
	//
	// You should free the memory using `free_memory()` or `free_memory_pages()`.
	//
	// It is recommended to use `allocate_memory_for_buffer()`,
	// `allocate_memory_for_image()`, `create_buffer()`, `create_image()` instead
	// whenever possible.
	@(link_name = "vmaAllocateMemory")
	allocate_memory :: proc(
		allocator: Allocator,
		#by_ptr memory_requirements: vk.MemoryRequirements,
		#by_ptr create_info: Allocation_Create_Info,
		allocation: ^Allocation,
		allocation_info: ^Allocation_Info) -> vk.Result ---

	// General purpose memory allocation for multiple allocation objects at once.
	//
	// - `allocator` Allocator object.
	// - `vk_memory_requirements` Memory requirements for each allocation.
	// - `create_info` Creation parameters for each allocation.
	// - `allocation_count` Number of allocations to make.
	// - [out] `allocations` Pointer to array that will be filled with handles to
	//   created allocations.
	// - [out] `allocation_info` Optional. Pointer to array that will be filled
	//   with parameters of created allocations.
	//
	// You should free the memory using `free_memory()` or `free_memory_pages()`.
	//
	// Word "pages" is just a suggestion to use this PROCEDURE to allocate pieces
	// of memory needed for sparse binding. It is just a general purpose
	// allocation PROCEDURE able to make multiple allocations at once. It may be
	// internally optimized to be more efficient than calling `allocate_memory()`
	// `allocationCount` times.
	//
	// All allocations are made using same parameters. All of them are created out
	// of the same memory pool and type. If any allocation fails, all allocations
	// already made within this PROCEDURE call are also freed, so that when
	// returned result is not `.SUCCESS`, `allocations` array is always entirely
	// filled with `VK_NULL_HANDLE`.
	@(link_name = "vmaAllocateMemoryPages")
	allocate_memory_pages :: proc(
		allocator: Allocator,
		memory_requirements: [^]vk.MemoryRequirements,
		create_info: [^]Allocation_Create_Info,
		allocation_count: uint,
		allocations: [^]Allocation,
		allocation_info: [^]Allocation_Info) -> vk.Result ---

	// Allocates memory suitable for given `VkBuffer`.
	//
	// - `allocator`
	// - `buffer`
	// - `create_info`
	// - [out] `allocation` Handle to allocated memory.
	// - [out] `allocation_info` Optional. Information about allocated memory. It
	//   can be later fetched using procedure `get_allocation_info()`.
	//
	// It only creates #VmaAllocation. To bind the memory to the buffer, use
	// `bind_buffer_memory()`.
	//
	// This is a special-purpose procedure. In most cases you should use
	// `create_buffer()`.
	//
	// You must free the allocation using `free_memory()` when no longer needed.
	@(link_name = "vmaAllocateMemoryForBuffer")
	allocate_memory_for_buffer :: proc(
		allocator: Allocator,
		buffer: vk.Buffer,
		#by_ptr create_info: Allocation_Create_Info,
		allocation: ^Allocation,
		allocation_info: ^Allocation_Info) -> vk.Result ---

	// Allocates memory suitable for given `vk.Image`.
	//
	// - `allocator`
	// - `image`
	// - `create_info`
	// - [out] `allocation` Handle to allocated memory.
	// - [out] `allocation_info` Optional. Information about allocated memory. It
	//   can be later fetched using procedure `get_allocation_info()`.
	//
	// It only creates #VmaAllocation. To bind the memory to the buffer, use
	// `bind_image_memory()`.
	//
	// This is a special-purpose procedure. In most cases you should use
	// `create_image()`.
	//
	// You must free the allocation using `free_memory()` when no longer needed.
	@(link_name = "vmaAllocateMemoryForImage")
	allocate_memory_for_image :: proc(
		allocator: Allocator,
		image: vk.Image,
		#by_ptr create_info: Allocation_Create_Info,
		allocation: ^Allocation,
		allocation_info: ^Allocation_Info) -> vk.Result ---

	// Frees memory previously allocated using `allocate_memory()`,
	// `allocate_memory_for_buffer()`, or `allocate_memory_for_image()`.
	//
	// Passing `nil` as `allocation` is valid. Such procedure call is just
	// skipped.
	@(link_name = "vmaFreeMemory")
	free_memory :: proc(
		allocator: Allocator,
		allocation: Allocation) ---

	// Frees memory and destroys multiple allocations.
	//
	// Word "pages" is just a suggestion to use this procedure to free pieces of
	// memory used for sparse binding. It is just a general purpose procedure to
	// free memory and destroy allocations made using e.g. `allocate_memory()`,
	// `allocate_memory_pages()` and other procedures. It may be internally
	// optimized to be more efficient than calling `free_memory()`
	// `allocation_count` times.
	//
	// Allocations in `allocations` array can come from any memory pools and
	// types. Passing `nil` as elements of `allocations` array is valid. Such
	// entries are just skipped.
	@(link_name = "vmaFreeMemoryPages")
	free_memory_pages :: proc(
		allocator: Allocator,
		allocation_count: uint,
		allocations: [^]Allocation) ---

	// Returns current information about specified allocation.
	//
	// Current parameters of given allocation are returned in `allocation_info`.
	//
	// Although this procedure doesn't lock any mutex, so it should be quite
	// efficient, you should avoid calling it too often. You can retrieve same
	// `Allocation_Info` structure while creating your resource, from procedure
	// `create_buffer()`, `create_image()`. You can remember it if you are sure
	// parameters don't change (e.g. due to defragmentation).
	//
	// There is also a new procedure `get_allocation_info2()` that offers extended
	// information about the allocation, returned using new structure
	// `Allocation_Info2`.
	@(link_name = "vmaGetAllocationInfo")
	get_allocation_info :: proc(
		allocator: Allocator,
		allocation: Allocation,
		allocation_info: ^Allocation_Info) ---

	// Returns extended information about specified allocation.
	//
	// Current parameters of given allocation are returned in `allocation_info`.
	// Extended parameters in structure `Allocation_Info2` include memory block
	// size and a flag telling whether the allocation has dedicated memory. It can
	// be useful e.g. for interop with OpenGL.
	@(link_name = "vmaGetAllocationInfo2")
	get_allocation_info2 :: proc(
		allocator: Allocator,
		allocation: Allocation,
		allocation_info: ^Allocation_Info2) ---

	// Sets user_data in given allocation to new value.
	//
	// The value of pointer `user_data` is copied to allocation's `user_data`. It
	// is opaque, so you can use it however you want - e.g. as a pointer, ordinal
	// number or some handle to you own data.
	@(link_name = "vmaSetAllocationUserData")
	set_allocation_user_data :: proc(
		allocator: Allocator,
		allocation: Allocation,
		user_data: rawptr) ---

	// Sets name in given allocation to new value.
	//
	// `name` must be either `nil`, or a pointer to a `nil`-terminated string. The
	// procedure makes a local copy of the string and sets it as allocation's
	// `name`. The string passed as `name` doesn't need to be valid for the whole
	// lifetime of the allocation - you can free it after this call. The string
	// previously pointed to by allocation's `name` is freed from memory.
	@(link_name = "vmaSetAllocationName")
	set_allocation_name :: proc(
		allocator: Allocator,
		allocation: Allocation,
		name: cstring) ---

	// Given an allocation, returns Win32 handle that may be imported by other
	// processes or APIs.
	//
	// -  `target_process` Must be a valid handle to target process or null. If
	//    it's null, the procedure returns handle for the current process.
	// - [out] `handle` Output parameter that returns the handle.
	//
	// The procedure fills `handle` with handle that can be used in target
	// process. The handle is fetched using procedure
	// `vk.GetMemoryWin32HandleKHR`. When no longer needed, you must close it
	// using:
	//
	// ```
	// win32.CloseHandle(handle)
	// ```
	//
	// You can close it any time, before or after destroying the allocation
	// object. It is reference-counted internally by Windows.
	//
	// Note the handle is returned for the entire `vk.DeviceMemory` block that the
	// allocation belongs to. If the allocation is sub-allocated from a larger
	// block, you may need to consider the offset of the allocation
	// (`Allocation_Info.offset`).
	//
	// If the procedure fails with `vk.ERROR_FEATURE_NOT_PRESENT` error code,
	// please double-check that `Vulkan_Functions.get_memory_win32_handle_khr`
	// procedure pointer is set, e.g. either by using
	// `VMA_DYNAMIC_VULKAN_FUNCTIONS` or by manually passing it through
	// `Allocator_Create_Info.vulkan_functions`.
	@(link_name = "vmaGetMemoryWin32Handle")
	get_memory_win32_handle :: proc(
		allocator: Allocator,
		allocation: Allocation,
		target_process: vk.HANDLE,
		handle: ^vk.HANDLE) -> vk.Result ---

	// Given an allocation, returns Property Flags of its memory type.
	//
	// This is just a convenience procedure. Same information can be obtained
	// using `get_allocation_info()` + `get_memory_properties()`.
	@(link_name = "vmaGetAllocationMemoryProperties")
	get_allocation_memory_properties :: proc(
		allocator: Allocator,
		allocation: Allocation,
		flags: ^vk.MemoryPropertyFlags) ---

	// Maps memory represented by given allocation and returns pointer to it.
	//
	// Maps memory represented by given allocation to make it accessible to CPU
	// code. When succeeded, `*data` contains a pointer to the first byte of this
	// memory.
	//
	// Warning: If the allocation is part of a bigger `VkDeviceMemory` block, the
	// returned pointer is correctly offset to the beginning of the region
	// assigned to this particular allocation. Unlike the result of `vkMapMemory`,
	// it points to the allocation, not to the beginning of the whole block. You
	// should not add VmaAllocationInfo::offset to it!
	//
	// Mapping is internally reference-counted and synchronized, so despite raw
	// Vulkan procedure `vkMapMemory()` cannot be used to map the same block of
	// `VkDeviceMemory` multiple times simultaneously, it is safe to call this
	// procedure on allocations assigned to the same memory block. Actual Vulkan
	// memory will be mapped on the first mapping and unmapped on the last
	// unmapping.
	//
	// If the procedure succeeded, you must call `unmap_memory()` to unmap the
	// allocation when mapping is no longer needed or before freeing the
	// allocation, at the latest.
	//
	// It is also safe to call this procedure multiple times on the same
	// allocation. You must call `unmap_memory()` the same number of times as you
	// called `map_memory()`.
	//
	// This procedure fails when used on an allocation made in a memory type that
	// is not `HOST_VISIBLE`.
	//
	// This procedure doesn't automatically flush or invalidate caches. If the
	// allocation is made from a memory type that is not `HOST_COHERENT`, you also
	// need to use `invalidate_allocation()` / `flush_allocation()`, as required
	// by Vulkan specification.
	@(link_name = "vmaMapMemory")
	map_memory :: proc(
		allocator: Allocator,
		allocation: Allocation,
		data: ^rawptr) -> vk.Result ---

	// Unmaps memory represented by given allocation, mapped previously using
	// `map_memory()`.
	//
	// For details, see the description of `map_memory()`.
	//
	// This procedure doesn't automatically flush or invalidate caches. If the
	// allocation is made from a memory type that is not `HOST_COHERENT`, you also
	// need to use `invalidate_allocation()` / `flush_allocation()`, as required
	// by Vulkan specification.
	@(link_name = "vmaUnmapMemory")
	unmap_memory :: proc(
		allocator: Allocator,
		allocation: Allocation) ---

	// Flushes memory of given allocation.
	//
	// Calls `vk.FlushMappedMemoryRanges()` for memory associated with the given
	// range of the given allocation. It needs to be called after writing to a
	// mapped memory for memory types that are not `HOST_COHERENT`. Unmap
	// operation doesn't do that automatically.
	//
	// - `offset` must be relative to the beginning of the allocation.
	// - `size` can be `vk.WHOLE_SIZE`. It means all memory from `offset` to the
	//   end of the given allocation.
	// - `offset` and `size` don't have to be aligned. They are internally rounded
	//   down/up to a multiple of `nonCoherentAtomSize`.
	// - If `size` is 0, this call is ignored.
	// - If the memory type that the `allocation` belongs to is not `HOST_VISIBLE`
	//   or it is `HOST_COHERENT`, this call is ignored.
	//
	// Warning! `offset` and `size` are relative to the contents of the given
	// `allocation`. If you mean the whole allocation, you can pass 0 and
	// `vk.WHOLE_SIZE`, respectively. Do not pass the allocation's offset as
	// `offset`!!!
	//
	// This procedure returns the `vk.Result` from `vk.FlushMappedMemoryRanges` if
	// it is called, otherwise `vk.SUCCESS`.
	@(link_name = "vmaFlushAllocation")
	flush_allocation :: proc(
		allocator: Allocator,
		allocation: Allocation,
		offset: vk.DeviceSize,
		size: vk.DeviceSize) -> vk.Result ---

	// Invalidates memory of given allocation.
	//
	// Calls `vk.InvalidateMappedMemoryRanges()` for memory associated with the
	// given range of the given allocation. It needs to be called before reading
	// from a mapped memory for memory types that are not `HOST_COHERENT`. Map
	// operation doesn't do that automatically.
	//
	// - `offset` must be relative to the beginning of the allocation.
	// - `size` can be `vk.WHOLE_SIZE`. It means all memory from `offset` to the
	//   end of the given allocation.
	// - `offset` and `size` don't have to be aligned. They are internally rounded
	//   down/up to a multiple of `nonCoherentAtomSize`.
	// - If `size` is 0, this call is ignored.
	// - If the memory type that the `allocation` belongs to is not `HOST_VISIBLE`
	//   or it is `HOST_COHERENT`, this call is ignored.
	//
	// Warning! `offset` and `size` are relative to the contents of the given
	// `allocation`. If you mean the whole allocation, you can pass 0 and
	// `vk.WHOLE_SIZE`, respectively. Do not pass the allocation's offset as
	// `offset`!!!
	//
	// This procedure returns the `VkResult` from
	// `vk.InvalidateMappedMemoryRanges` if it is called, otherwise `vk.SUCCESS`.
	@(link_name = "vmaInvalidateAllocation")
	invalidate_allocation :: proc(
		allocator: Allocator,
		allocation: Allocation,
		offset: vk.DeviceSize,
		size: vk.DeviceSize) -> vk.Result ---

	// Flushes memory of given set of allocations.
	//
	// Calls `vk.FlushMappedMemoryRanges()` for memory associated with the given
	// ranges of the given allocations.
	//
	// - `allocator`: The allocator object.
	// - `allocation_count`: The number of allocations to flush.
	// - `allocations`: An array of allocations to flush.
	// - `offsets`: If not `nil`, it must point to an array of offsets of regions
	//   to flush, relative to the beginning of respective allocations. `nil`
	//   means all offsets are zero.
	// - `sizes`: If not `nil`, it must point to an array of sizes of regions to
	//   flush in respective allocations. `nil` means `vk.WHOLE_SIZE` for all
	//   allocations.
	//
	// This procedure returns the `VkResult` from `vk.FlushMappedMemoryRanges` if
	// it is called, otherwise `vk.SUCCESS`.
	@(link_name = "vmaFlushAllocations")
	flush_allocations :: proc(
		allocator: Allocator,
		allocation_count: u32,
		allocations: [^]Allocation,
		offsets: [^]vk.DeviceSize,
		sizes: [^]vk.DeviceSize) -> vk.Result ---

	// Invalidates memory of given set of allocations.
	//
	// Calls `vk.InvalidateMappedMemoryRanges()` for memory associated with the
	// given ranges of the given allocations.
	//
	// - `allocator`: The allocator object.
	// - `allocation_count`: The number of allocations to invalidate.
	// - `allocations`: An array of allocations to invalidate.
	// - `offsets`: If not `nil`, it must point to an array of offsets of regions
	//   to invalidate, relative to the beginning of respective allocations. `nil`
	//   means all offsets are zero.
	// - `sizes`: If not `nil`, it must point to an array of sizes of regions to
	//   invalidate in respective allocations. `nil` means `vk.WHOLE_SIZE` for all
	//   allocations.
	//
	// This procedure returns the `VkResult` from
	// `vk.InvalidateMappedMemoryRanges` if it is called, otherwise `vk.SUCCESS`.
	@(link_name = "vmaInvalidateAllocations")
	invalidate_allocations :: proc(
		allocator: Allocator,
		allocation_count: u32,
		allocations: [^]Allocation,
		offsets: [^]vk.DeviceSize,
		sizes: [^]vk.DeviceSize) -> vk.Result ---

	// Maps the allocation temporarily if needed, copies data from the specified
	// host pointer to it, and flushes the memory from the host caches if needed.
	//
	// - `allocator`: The allocator object.
	// - `src_data`: Pointer to the host data that becomes the source of the copy.
	// - `dst_allocation`: Handle to the allocation that becomes the destination
	//   of the copy.
	// - `dst_offset`: Offset within `dst_allocation` where to write the copied
	//   data, in bytes.
	// - `size`: Number of bytes to copy.
	//
	// This is a convenience procedure that allows copying data from a host
	// pointer to an allocation easily. The same behavior can be achieved by
	// calling `map_memory()`, `memcpy()`, `unmap_memory()`, and
	// `flush_allocation()`.
	//
	// This procedure can be called only for allocations created in a memory type
	// that has `VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT` flag. It can be ensured,
	// e.g., by using `VMA_MEMORY_USAGE_AUTO` and
	// `VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT` or
	// `VMA_ALLOCATION_CREATE_HOST_ACCESS_RANDOM_BIT`. Otherwise, the procedure
	// will fail and generate a Validation Layers error.
	//
	// `dst_offset` is relative to the contents of the given `dst_allocation`. If
	// you mean the whole allocation, you should pass 0. Do not pass the
	// allocation's offset within the device memory block as this parameter!
	@(link_name = "vmaCopyMemoryToAllocation")
	copy_memory_to_allocation :: proc(
		allocator: Allocator,
		src_data: rawptr,
		dst_allocation: Allocation,
		dst_offset: vk.DeviceSize,
		size: vk.DeviceSize) -> vk.Result ---

	// Invalidates memory in the host caches if needed, maps the allocation
	// temporarily if needed, and copies data from it to a specified host pointer.
	//
	// - `allocator`: The allocator object.
	// - `src_allocation`: Handle to the allocation that becomes the source of the
	//   copy.
	// - `src_offset`: Offset within `src_allocation` where to read the copied
	//   data, in bytes.
	// - `dst_host_pointer`: Pointer to the host memory that becomes the
	//   destination of the copy.
	// - `size`: Number of bytes to copy.
	//
	// This is a convenience procedure that allows copying data from an allocation
	// to a host pointer easily. The same behavior can be achieved by calling
	// vmaInvalidateAllocation(), vmaMapMemory(), `memcpy()`, and
	// vmaUnmapMemory().
	//
	// This procedure should be called only for allocations created in a memory
	// type that has `VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT` and
	// `VK_MEMORY_PROPERTY_HOST_CACHED_BIT` flag. It can be ensured, e.g., by
	// using `VMA_MEMORY_USAGE_AUTO` and
	// `VMA_ALLOCATION_CREATE_HOST_ACCESS_RANDOM_BIT`. Otherwise, the procedure
	// may fail and generate a Validation Layers error. It may also work very
	// slowly when reading from an uncached memory.
	//
	// `src_offset` is relative to the contents of the given `src_allocation`. If
	// you mean the whole allocation, you should pass 0. Do not pass the
	// allocation's offset within the device memory block as this parameter!
	@(link_name = "vmaCopyAllocationToMemory")
	copy_allocation_to_memory :: proc(
		allocator: Allocator,
		src_allocation: Allocation,
		src_offset: vk.DeviceSize,
		dst_host_pointer: rawptr,
		size: vk.DeviceSize) -> vk.Result ---

	// Checks magic number in margins around all allocations in given memory types
	// (in both default and custom pools) in search for corruptions.
	//
	// - `allocator`: The allocator object.
	// - `memory_type_bits`: Bit mask, where each bit set means that a memory type
	//   with that index should be checked.
	//
	// Corruption detection is enabled only when `VMA_DEBUG_DETECT_CORRUPTION`
	// macro is defined to nonzero, `VMA_DEBUG_MARGIN` is defined to nonzero, and
	// only for memory types that are `HOST_VISIBLE` and `HOST_COHERENT`.
	//
	// Possible return values:
	//
	// - `vk.ERROR_FEATURE_NOT_PRESENT`: Corruption detection is not enabled for
	//   any of the specified memory types.
	// - `vk.SUCCESS`: Corruption detection has been performed and succeeded.
	// - `VK_ERROR_UNKNOWN`: Corruption detection has been performed and found
	//   memory corruptions around one of the allocations. `VMA_ASSERT` is also
	//   fired in that case.
	// - Other value: Error returned by Vulkan, e.g., memory mapping failure.
	@(link_name = "vmaCheckCorruption")
	check_corruption :: proc(
		allocator: Allocator,
		memory_type_bits: u32) -> vk.Result ---

	// Begins defragmentation process.
	//
	// - `allocator`: The allocator object.
	// - `defragmentation_info`: Structure filled with parameters of
	//   defragmentation.
	// - `ctx`: Context object that must be passed to `end_defragmentation()` to
	//   finish defragmentation.
	//
	// Returns:
	// - `vk.SUCCESS` if defragmentation can begin.
	// - `vk.ERROR_FEATURE_NOT_PRESENT` if defragmentation is not supported.
	@(link_name = "vmaBeginDefragmentation")
	begin_defragmentation :: proc(
		allocator: Allocator,
		#by_ptr defragmentation_info: Defragmentation_Info,
		ctx: ^Defragmentation_Context) -> vk.Result ---

	// Ends defragmentation process.
	//
	// - `allocator`: The allocator object.
	// - `ctx`: Context object that has been created by vmaBeginDefragmentation().
	// - `stats`: Optional stats for the defragmentation. Can be `nil`.
	//
	// Use this procedure to finish defragmentation started by
	// vmaBeginDefragmentation().
	@(link_name = "vmaEndDefragmentation")
	end_defragmentation :: proc(
		allocator: Allocator,
		ctx: Defragmentation_Context,
		stats: ^Defragmentation_Stats) ---

	// Starts single defragmentation pass.
	//
	// - `allocator`: The allocator object.
	// - `ctx`: Context object that has been created by `begin_defragmentation()`.
	// - `pass_info`: Computed information for the current pass.
	//
	// Returns:
	// - `vk.SUCCESS` if no more moves are possible. Then you can omit the call to
	//   `end_defragmentation_pass()` and simply end the whole defragmentation.
	// - `vk.INCOMPLETE` if there are pending moves returned in `pass_info`. You
	//   need to perform them, call `end_defragmentation_pass()`, and then
	//   preferably try another pass with `begin_defragmentation_pass()`.
	@(link_name = "vmaBeginDefragmentationPass")
	begin_defragmentation_pass :: proc(
		allocator: Allocator,
		ctx: Defragmentation_Context,
		pass_info: ^Defragmentation_Pass_Move_Info) -> vk.Result ---

	// Ends single defragmentation pass.
	//
	// - `allocator` Allocator object.
	// - `ctx` Context object that has been created by `begin_defragmentation()`.
	// - `pass_info` Computed information for current pass filled by
	//   `begin_defragmentation_pass()` and possibly modified by you.
	//
	// Returns `vk.SUCCESS` if no more moves are possible or `VK_INCOMPLETE` if
	// more defragmentations are possible.
	//
	// Ends incremental defragmentation pass and commits all defragmentation moves
	// from `pPassInfo`. After this call:
	//
	// - Allocations at `pPassInfo[i].srcAllocation` that had
	//   `pPassInfo[i].operation ==` #VMA_DEFRAGMENTATION_MOVE_OPERATION_COPY
	//   (which is the default) will be pointing to the new destination place.
	// - Allocation at `pPassInfo[i].srcAllocation` that had
	//   `pPassInfo[i].operation ==` #VMA_DEFRAGMENTATION_MOVE_OPERATION_DESTROY
	//   will be freed.
	//
	// If no more moves are possible you can end whole defragmentation.
	@(link_name = "vmaEndDefragmentationPass")
	end_defragmentation_pass :: proc(
		allocator: Allocator,
		ctx: Defragmentation_Context,
		pass_info: ^Defragmentation_Pass_Move_Info) -> vk.Result ---

	// Binds buffer to allocation.
	//
	// Binds specified buffer to region of memory represented by specified
	// allocation. Gets `VkDeviceMemory` handle and offset from the allocation. If
	// you want to create a buffer, allocate memory for it and bind them together
	// separately, you should use this procedure for binding instead of standard
	// `vkBindBufferMemory()`, because it ensures proper synchronization so that
	// when a `VkDeviceMemory` object is used by multiple allocations, calls to
	// `vkBind*Memory()` or `vkMapMemory()` won't happen from multiple threads
	// simultaneously (which is illegal in Vulkan).
	//
	// It is recommended to use procedure `create_buffer()` instead of this one.
	@(link_name = "vmaBindBufferMemory")
	bind_buffer_memory :: proc(
		allocator: Allocator,
		allocation: Allocation,
		buffer: vk.Buffer) -> vk.Result ---

	// Binds buffer to allocation with additional parameters.
	//
	// - `allocator` Allocator object.
	// - `allocation` Allocation object.
	// - `allocation_local_offset` Additional offset to be added while binding,
	//   relative to the beginning of the `allocation`. Normally it should be 0.
	// - `buffer` Buffer to bind.
	// - `next` A chain of structures to be attached to
	//   `VkBindBufferMemoryInfoKHR` structure used internally. Normally it should
	//   be `nil`.
	//
	// This procedure is similar to `bind_buffer_memory()`, but it provides
	// additional parameters.
	//
	// If `next` is not `nil`, `Allocator` object must have been created with
	// `VMA_ALLOCATOR_CREATE_KHR_BIND_MEMORY2_BIT` flag or with
	// `VmaAllocatorCreateInfo::vulkanApiVersion` `>= VK_API_VERSION_1_1`.
	// Otherwise the call fails.
	@(link_name = "vmaBindBufferMemory2")
	bind_buffer_memory2 :: proc(
		allocator: Allocator,
		allocation: Allocation,
		allocation_local_offset: vk.DeviceSize,
		buffer: vk.Buffer,
		next: rawptr) -> vk.Result ---

	// Binds image to allocation.
	//
	// Binds specified image to region of memory represented by specified
	// allocation. Gets `VkDeviceMemory` handle and offset from the allocation. If
	// you want to create an image, allocate memory for it and bind them together
	// separately, you should use this procedure for binding instead of standard
	// `vkBindImageMemory()`, because it ensures proper synchronization so that
	// when a `VkDeviceMemory` object is used by multiple allocations, calls to
	// `vkBind*Memory()` or `vkMapMemory()` won't happen from multiple threads
	// simultaneously (which is illegal in Vulkan).
	//
	// It is recommended to use procedure `create_image()` instead of this one.
	@(link_name = "vmaBindImageMemory")
	bind_image_memory :: proc(
		allocator: Allocator,
		allocation: Allocation,
		image: vk.Image) -> vk.Result ---

	// Binds image to allocation with additional parameters.
	//
	// - `allocator` Allocator object.
	// - `allocation` Allocation object.
	// - `allocation_local_offset` Additional offset to be added while binding,
	//   relative to the beginning of the `allocation`. Normally it should be 0.
	// - `image` Image to bind.
	// - `next` A chain of structures to be attached to `VkBindImageMemoryInfoKHR`
	//   structure used internally. Normally it should be `nil`.
	//
	// This procedure is similar to `bind_image_memory()`, but it provides
	// additional parameters.
	//
	// If `next` is not `nil`, `Allocator` object must have been created with
	// `VMA_ALLOCATOR_CREATE_KHR_BIND_MEMORY2_BIT` flag or with
	// `VmaAllocatorCreateInfo::vulkanApiVersion` `>= VK_API_VERSION_1_1`.
	// Otherwise the call fails.
	@(link_name = "vmaBindImageMemory2")
	bind_image_memory2 :: proc(
		allocator: Allocator,
		allocation: Allocation,
		allocation_local_offset: vk.DeviceSize,
		image: vk.Image,
		next: rawptr) -> vk.Result ---

	// Creates a new `VkBuffer`, allocates and binds memory for it.
	//
	// - `allocator` Allocator object.
	// - `buffer_create_info` Parameters for buffer creation.
	// - `allocation_create_info` Parameters for memory allocation.
	// - `buffer` Output parameter for the created buffer.
	// - `allocation` Output parameter for the created allocation.
	// - `allocation_info` Optional. Information about allocated memory. It can be
	//   later fetched using procedure `get_allocation_info()`.
	//
	// This procedure automatically:
	// - Creates buffer.
	// - Allocates appropriate memory for it.
	// - Binds the buffer with the memory.
	//
	// If any of these operations fail, buffer and allocation are not created,
	// returned value is negative error code, `buffer` and `allocation` are `nil`.
	//
	// If the procedure succeeded, you must destroy both buffer and allocation
	// when you no longer need them using either convenience procedure
	// `destroy_buffer()` or separately, using `vkDestroyBuffer()` and
	// `free_memory()`.
	//
	// If `VMA_ALLOCATOR_CREATE_KHR_DEDICATED_ALLOCATION_BIT` flag was used,
	// `VK_KHR_dedicated_allocation` extension is used internally to query driver
	// whether it requires or prefers the new buffer to have dedicated allocation.
	// If yes, and if dedicated allocation is possible
	// (`VMA_ALLOCATION_CREATE_NEVER_ALLOCATE_BIT` is not used), it creates
	// dedicated allocation for this buffer, just like when using
	// `VMA_ALLOCATION_CREATE_DEDICATED_MEMORY_BIT`.
	@(link_name = "vmaCreateBuffer")
	create_buffer :: proc(
		allocator: Allocator,
		#by_ptr buffer_create_info: vk.BufferCreateInfo,
		#by_ptr allocation_create_info: Allocation_Create_Info,
		buffer: ^vk.Buffer,
		allocation: ^Allocation,
		allocation_info: ^Allocation_Info) -> vk.Result ---

	// Creates a buffer with additional minimum alignment.
	//
	// Similar to `create_buffer()` but provides additional parameter
	// `min_alignment` which allows to specify custom, minimum alignment to be
	// used when placing the buffer inside a larger memory block, which may be
	// needed e.g. for interop with OpenGL.
	@(link_name = "vmaCreateBufferWithAlignment")
	create_buffer_with_alignment :: proc(
		allocator: Allocator,
		#by_ptr buffer_create_info: vk.BufferCreateInfo,
		#by_ptr allocation_create_info: Allocation_Create_Info,
		min_alignment: vk.DeviceSize,
		buffer: ^vk.Buffer,
		allocation: ^Allocation,
		allocation_info: ^Allocation_Info) -> vk.Result ---

	// Creates a new `VkBuffer`, binds already created memory for it.
	//
	// - `allocator` Allocator object.
	// - `allocation` Allocation that provides memory to be used for binding new
	//   buffer to it.
	// - `buffer_create_info` Parameters for buffer creation.
	// - `buffer` Output parameter for the created buffer.
	//
	// This procedure automatically:
	// - Creates buffer.
	// - Binds the buffer with the supplied memory.
	//
	// If any of these operations fail, buffer is not created, returned value is
	// negative error code and `buffer` is `nil`.
	//
	// If the procedure succeeded, you must destroy the buffer when you no longer
	// need it using `vkDestroyBuffer()`. If you want to also destroy the
	// corresponding allocation you can use convenience procedure
	// `destroy_buffer()`.
	@(link_name = "vmaCreateAliasingBuffer")
	create_aliasing_buffer :: proc(
		allocator: Allocator,
		allocation: Allocation,
		#by_ptr buffer_create_info: vk.BufferCreateInfo,
		buffer: ^vk.Buffer) -> vk.Result ---

	// Creates a new `VkBuffer`, binds already created memory for it.
	//
	// - `allocator` Allocator object.
	// - `allocation` Allocation that provides memory to be used for binding new
	//   buffer to it.
	// - `allocation_local_offset` Additional offset to be added while binding,
	//   relative to the beginning of the allocation. Normally it should be 0.
	// - `buffer_create_info` Parameters for buffer creation.
	// - `buffer` Output parameter for the created buffer.
	//
	// This procedure automatically:
	// - Creates buffer.
	// - Binds the buffer with the supplied memory.
	//
	// If any of these operations fail, buffer is not created, returned value is
	// negative error code and `buffer` is `nil`.
	//
	// If the procedure succeeded, you must destroy the buffer when you no longer
	// need it using `vkDestroyBuffer()`. If you want to also destroy the
	// corresponding allocation you can use convenience procedure
	// `destroy_buffer()`.
	@(link_name = "vmaCreateAliasingBuffer2")
	create_aliasing_buffer2 :: proc(
		allocator: Allocator,
		allocation: Allocation,
		allocation_local_offset: vk.DeviceSize,
		#by_ptr buffer_create_info: vk.BufferCreateInfo,
		buffer: ^vk.Buffer) -> vk.Result ---

	// Destroys Vulkan buffer and frees allocated memory.
	//
	// This is just a convenience procedure equivalent to:
	// ```
	// vkDestroyBuffer(device, buffer, allocation_callbacks);
	// vmaFreeMemory(allocator, allocation);
	// ```
	//
	// It is safe to pass `nil` as buffer and/or allocation.
	@(link_name = "vmaDestroyBuffer")
	destroy_buffer :: proc(
		allocator: Allocator,
		buffer: vk.Buffer,
		allocation: Allocation) ---

	// Creates a new `vk.Image`, allocates and binds memory for it.
	//
	// - `allocator` Allocator object.
	// - `image_create_info` Parameters for image creation.
	// - `allocation_create_info` Parameters for memory allocation.
	// - `image` Output parameter for the created image.
	// - `allocation` Output parameter for the created allocation.
	// - `allocation_info` Optional. Information about allocated memory. It can be
	//   later fetched using procedure `get_allocation_info()`.
	//
	// This procedure automatically:
	// - Creates image.
	// - Allocates appropriate memory for it.
	// - Binds the image with the memory.
	//
	// If any of these operations fail, image and allocation are not created,
	// returned value is negative error code, `image` and `allocation` are `nil`.
	//
	// If the procedure succeeded, you must destroy both image and allocation when
	// you no longer need them using either convenience procedure
	// `destroy_image()` or separately, using `vk.DestroyImage()` and
	// `free_memory()`.
	@(link_name = "vmaCreateImage")
	create_image :: proc(
		allocator: Allocator,
		#by_ptr image_create_info: vk.ImageCreateInfo,
		#by_ptr allocation_create_info: Allocation_Create_Info,
		image: ^vk.Image,
		allocation: ^Allocation,
		allocation_info: ^Allocation_Info) -> vk.Result ---

	// Creates a new `vk.Image`, binds already created memory for it.
	//
	// - `allocator` Allocator object.
	// - `allocation` Allocation that provides memory to be used for binding new
	//   image to it.
	// - `image_create_info` Parameters for image creation.
	// - `image` Output parameter for the created image.
	//
	// This procedure automatically:
	// - Creates image.
	// - Binds the image with the supplied memory.
	//
	// If any of these operations fail, image is not created, returned value is
	// negative error code and `image` is `nil`.
	//
	// If the procedure succeeded, you must destroy the image when you no longer
	// need it using `vk.DestroyImage()`. If you want to also destroy the
	// corresponding allocation you can use convenience procedure
	// `destroy_image()`.
	@(link_name = "vmaCreateAliasingImage")
	create_aliasing_image :: proc(
		allocator: Allocator,
		allocation: Allocation,
		#by_ptr image_create_info: vk.ImageCreateInfo,
		image: ^vk.Image) -> vk.Result ---

	// Creates a new `vk.Image`, binds already created memory for it.
	//
	// - `allocator` Allocator object.
	// - `allocation` Allocation that provides memory to be used for binding new
	//   image to it.
	// - `allocation_local_offset` Additional offset to be added while binding,
	//   relative to the beginning of the allocation. Normally it should be 0.
	// - `image_create_info` Parameters for image creation.
	// - `image` Output parameter for the created image.
	//
	// This procedure automatically:
	// - Creates image.
	// - Binds the image with the supplied memory.
	//
	// If any of these operations fail, image is not created, returned value is
	// negative error code and `image` is `nil`.
	//
	// If the procedure succeeded, you must destroy the image when you no longer
	// need it using `vk.DestroyImage()`. If you want to also destroy the
	// corresponding allocation you can use convenience procedure
	// `destroy_image()`.
	@(link_name = "vmaCreateAliasingImage2")
	create_aliasing_image2 :: proc(
		allocator: Allocator,
		allocation: Allocation,
		allocation_local_offset: vk.DeviceSize,
		#by_ptr image_create_info: vk.ImageCreateInfo,
		image: ^vk.Image) -> vk.Result ---

	// Destroys Vulkan image and frees allocated memory.
	//
	// This is just a convenience procedure equivalent to:
	// ```
	// destroy_image(device, image, allocation_callbacks)
	// free_memory(allocator, allocation)
	// ```
	//
	// It is safe to pass `nil` as image and/or allocation.
	@(link_name = "vmaDestroyImage")
	destroy_image :: proc(
		allocator: Allocator,
		image: vk.Image,
		allocation: Allocation) ---

	// Creates new virtual block.
	//
	// - `create_info` Parameters for creation.
	// - `virtual_block` Output parameter for the created virtual block.
	//
	// Returns `vk.SUCCESS` if creation was successful, otherwise an error code.
	@(link_name = "vmaCreateVirtualBlock")
	create_virtual_block :: proc(
		#by_ptr create_info: Virtual_Block_Create_Info,
		virtual_block: ^Virtual_Block) -> vk.Result ---

	// Destroys virtual block.
	//
	// Please note that you should consciously handle virtual allocations that
	// could remain unfreed in the block. You should either free them individually
	// using `virtual_free()` or call `clear_virtual_block()` if you are sure this
	// is what you want. If you do neither, an assert is called.
	//
	// If you keep pointers to some additional metadata associated with your
	// virtual allocations in their `user_data`, don't forget to free them.
	@(link_name = "vmaDestroyVirtualBlock")
	destroy_virtual_block :: proc(
		virtual_block: Virtual_Block) ---

	// Returns true if the virtual block is empty - contains 0 virtual allocations
	// and has all its space available for new allocations.
	@(link_name = "vmaIsVirtualBlockEmpty")
	is_virtual_block_empty :: proc(
		virtual_block: Virtual_Block) -> b32 ---

	// Returns information about a specific virtual allocation within a virtual
	// block, like its size and `user_data` pointer.
	@(link_name = "vmaGetVirtualAllocationInfo")
	get_virtual_allocation_info :: proc(
		virtual_block: Virtual_Block,
		allocation: Virtual_Allocation,
		allocation_info: ^Virtual_Allocation_Info) ---

	// Allocates new virtual allocation inside given virtual block.
	//
	// - `virtual_block` Virtual block.
	// - `create_info` Parameters for the allocation.
	// - `allocation` Output parameter for the new allocation.
	// - `offset` Output parameter for the offset of the new allocation. Optional,
	//   can be `nil`.
	//
	// Returns `vk.SUCCESS` if allocation was successful, otherwise an error code.
	@(link_name = "vmaVirtualAllocate")
	virtual_allocate :: proc(
		virtual_block: Virtual_Block,
		#by_ptr create_info: Virtual_Allocation_Create_Info,
		allocation: ^Virtual_Allocation,
		offset: ^vk.DeviceSize) -> vk.Result ---

	// Frees virtual allocation inside given virtual block.
	//
	// It is correct to call this procedure with `allocation == VK_NULL_HANDLE` -
	// it does nothing.
	@(link_name = "vmaVirtualFree")
	virtual_free :: proc(
		virtual_block: Virtual_Block,
		allocation: Virtual_Allocation) ---

	// Frees all virtual allocations inside given virtual block.
	//
	// You must either call this procedure or free each virtual allocation
	// individually with `virtual_free()` before destroying a virtual block.
	// Otherwise, an assert is called.
	//
	// If you keep pointer to some additional metadata associated with your
	// virtual allocation in its `user_data`, don't forget to free it as well.
	@(link_name = "vmaClearVirtualBlock")
	clear_virtual_block :: proc(
		virtual_block: Virtual_Block) ---

	// Changes custom pointer associated with given virtual allocation.
	@(link_name = "vmaSetVirtualAllocationUserData")
	set_virtual_allocation_user_data :: proc(
		virtual_block: Virtual_Block,
		allocation: Virtual_Allocation,
		user_data: rawptr) ---

	// Calculates and returns statistics about virtual allocations and memory
	// usage in given virtual block.
	//
	// This procedure is fast to call. For more detailed statistics, see
	// `calculate_virtual_block_statistics()`.
	@(link_name = "vmaGetVirtualBlockStatistics")
	get_virtual_block_statistics :: proc(
		virtual_block: Virtual_Block,
		stats: ^Statistics) ---

	// Calculates and returns detailed statistics about virtual allocations and
	// memory usage in given virtual block.
	//
	// This procedure is slow to call. Use for debugging purposes. For less
	// detailed statistics, see `get_virtual_block_statistics()`.
	@(link_name = "vmaCalculateVirtualBlockStatistics")
	calculate_virtual_block_statistics :: proc(
		virtual_block: Virtual_Block,
		stats: ^Detailed_Statistics) ---

	// Builds and returns a `nil`-terminated string in JSON format with
	// information about given `Virtual_Block`.
	// - `virtual_block` Virtual block.
	// - [out] `stats_string` Returned string.
	// - `detailed_map` Pass `false` to only obtain statistics as returned by
	//   `calculate_virtual_block_statistics()`. Pass `true` to also obtain full
	//   list of allocations and free spaces.
	//
	// Returned string must be freed using `free_virtual_block_stats_string()`.
	@(link_name = "vmaBuildVirtualBlockStatsString")
	build_virtual_block_stats_string :: proc(
		virtual_block: Virtual_Block,
		stats_string: ^cstring,
		detailed_map: b32) ---

	// Frees a string returned by `build_virtual_block_stats_string()`.
	@(link_name = "vmaFreeVirtualBlockStatsString")
	free_virtual_block_stats_string :: proc(
		virtual_block: Virtual_Block,
		stats_string: cstring) ---

	// Builds and returns statistics as a `nil`-terminated string in JSON format.
	// - `allocator`
	// - [out] `stats_string` Must be freed using `free_stats_string()` procedure.
	// - `detailed_map`
	@(link_name = "vmaBuildStatsString")
	build_stats_string :: proc(
		allocator: Allocator,
		stats_string: ^cstring,
		detailed_map: b32) ---

	@(link_name = "vmaFreeStatsString")
	free_stats_string :: proc(
		allocator: Allocator,
		stats_string: cstring) ---
}
// odinfmt: enable
