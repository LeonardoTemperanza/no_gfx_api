package vma

when ODIN_OS == .Windows {
	when ODIN_ARCH == .amd64 {
		@export
		@(extra_linker_flags="/NODEFAULTLIB:libcmt /NODEFAULTLIB:libucrt")
		foreign import vmalib "vma_windows_x86_64.lib"
	} else when ODIN_ARCH == .arm64 {
		@export
		@(extra_linker_flags="/NODEFAULTLIB:libcmt /NODEFAULTLIB:libucrt")
		foreign import vmalib "vma_windows_ARM64.lib"
	} else {
		#panic("Unsupported architecture for VMA library on Windows")
	}
} else when ODIN_OS == .Darwin {
	when ODIN_ARCH == .amd64 {
		@export
		foreign import vmalib { "libvma_macosx_x86_64.a", "system:stdc++" }
	} else when ODIN_ARCH == .arm64 {
		@export
		foreign import vmalib { "libvma_macosx_x86_64.a", "system:stdc++" }
	} else {
		#panic("Unsupported architecture for VMA library on MacOSX")
	}
} else when ODIN_OS == .Linux {
	when ODIN_ARCH == .amd64 {
		@export
		foreign import vmalib { "libvma_linux_x86_64.a", "system:stdc++" }
	} else when ODIN_ARCH == .arm64 {
		@export
		foreign import vmalib { "libvma_linux_x86_64.a", "system:stdc++" }
	} else {
		#panic("Unsupported architecture for VMA library on Linux")
	}
} else {
	@export
	foreign import vmalib "system:libvma"
}

// Vendor
import vk "vendor:vulkan"

// VMA Version - vk.MAKE_VERSION()
VMA_VERSION: u32 : (3 << 22) | (4 << 12) | (0)

// Flags for created `Allocator`.
AllocatorCreateFlags :: bit_set[AllocatorCreateFlag; vk.Flags]
AllocatorCreateFlag :: enum i32 {
	// Allocator and all objects created from it will not be synchronized
	// internally, so you must guarantee they are used from only one thread at a
	// time or synchronized externally by you.
	//
	// Using this flag may increase performance because internal mutexes are not used.

	EXTERNALLY_SYNCHRONIZED,
	// Enables usage of `VK_KHR_dedicated_allocation` extension.
	//
	// The flag works only if `vma.AllocatorCreateInfo.vulkanApiVersion` `==
	// vk.API_VERSION_1_0`. When it is `vk.API_VERSION_1_1`, the flag is ignored
	// because the extension has been promoted to Vulkan 1.1.
	//
	// Using this extension will automatically allocate dedicated blocks of
	// memory for some buffers and images instead of suballocating place for
	// them out of bigger memory blocks (as if you explicitly used
	// `DEDICATED_MEMORY` flag) when it is recommended by the driver. It may
	// improve performance on some GPUs.
	//
	// You may set this flag only if you found out that following device
	// extensions are supported, you enabled them while creating Vulkan device
	// passed as vma.AllocatorCreateInfo.device, and you want them to be used
	// internally by this library:
	//
	// - `VK_KHR_get_memory_requirements2` (device extension)
	// - `VK_KHR_dedicated_allocation` (device extension)
	//
	// When this flag is set, you can experience following warnings reported by
	// Vulkan validation layer. You can ignore them.
	//
	// > `vk.bindBufferMemory()`: Binding memory to buffer `0x2d` but
	// `vk.etBufferMemoryRequirements()` has not been called on that buffer.
	KHR_DEDICATED_ALLOCATION,

	// Enables usage of `VK_KHR_bind_memory2` extension.
	//
	// The flag works only if `vma.AllocatorCreateInfo.vulkanApiVersion` `==
	// vk.API_VERSION_1_0`. When it is `vk.API_VERSION_1_1`, the flag is ignored
	// because the extension has been promoted to Vulkan 1.1.
	//
	// You may set this flag only if you found out that this device extension is
	// supported, you enabled it while creating Vulkan device passed as
	// vma.AllocatorCreateInfo.device, and you want it to be used internally by this library.
	//
	// The extension provides functions `vk.indBufferMemory2KHR` and
	// `vk.indImageMemory2KHR`, which allow to pass a chain of `pNext`
	// structures while binding. This flag is required if you use `pNext`
	// parameter in `vma.bindBufferMemory2()` or `vma.bindImageMemory2()`.
	KHR_BIND_MEMORY2,

	// Enables usage of `VK_EXT_memory_budget` extension.
	//
	// You may set this flag only if you found out that this device extension is
	// supported, you enabled it while creating Vulkan device passed as
	// `vma.AllocatorCreateInfo.device`, and you want it to be used internally by
	// this library, along with another instance extension
	// `VK_KHR_get_physical_device_properties2`, which is required by it (or
	// Vulkan 1.1, where this extension is promoted).
	//
	// The extension provides query for current memory usage and budget, which
	// will probably be more accurate than an estimation used by the library otherwise.
	EXT_MEMORY_BUDGET,

	// Enables usage of `VK_AMD_device_coherent_memory` extension.
	//
	// You may set this flag only if you:
	//
	// - found out that this device extension is supported and enabled it while
	//   creating Vulkan device passed as `vma.AllocatorCreateInfo.device`,
	// - checked that
	//   `vk.PhysicalDeviceCoherentMemoryFeaturesAMD.deviceCoherentMemory` is
	//   `true` and set it while creating the Vulkan device,
	// - want it to be used internally by this library.
	//
	// The extension and accompanying device feature provide access to memory
	// types with `COHERENT_AMD` and `UNCACHED_AMD` flags. They are useful
	// mostly for writing breadcrumb markers - a common method for debugging GPU
	// crash/hang/TDR.
	//
	// When the extension is not enabled, such memory types are still
	// enumerated, but their usage is illegal. To protect from this error, if
	// you don't create the allocator with this flag, it will refuse to allocate
	// any memory or create a custom pool in such memory type, returning
	// `vk.Result.ERROR_FEATURE_NOT_PRESENT`.
	AMD_DEVICE_COHERENT_MEMORY,

	// Enables usage of "buffer device address" feature, which allows you to use
	// function `vk.getBufferDeviceAddress*` to get raw GPU pointer to a buffer
	// and pass it for usage inside a shader.
	//
	// You may set this flag only if you:
	//
	// 1. (For Vulkan version < 1.2) Found as available and enabled device
	//    extension `VK_KHR_buffer_device_address`. This extension is promoted
	//    to core Vulkan 1.2.
	// 2. Found as available and enabled device feature
	//    `vk.PhysicalDeviceBufferDeviceAddressFeatures.bufferDeviceAddress`.
	//
	// When this flag is set, you can create buffers with
	// `vk.BufferUsageFlags.SHADER_DEVICE_ADDRESS` using VMA. The library
	// automatically adds `vk.MemoryAllocateFlags.DEVICE_ADDRESS` to allocated
	// memory blocks wherever it might be needed.
	BUFFER_DEVICE_ADDRESS,

	// Enables usage of `VK_EXT_memory_priority` extension in the library.
	//
	// You may set this flag only if you found available and enabled this device
	// extension, along with
	// `vk.PhysicalDeviceMemoryPriorityFeaturesEXT.memoryPriority == true`,
	// while creating Vulkan device passed as `vma.AllocatorCreateInfo.device`.
	//
	// When this flag is used, `vma.AllocationCreateInfo.priority` and
	// `vma.PoolCreateInfo.priority` are used to set priorities of allocated
	// Vulkan memory. Without it, these variables are ignored.
	//
	// A priority must be a floating-point value between 0 and 1, indicating the
	// priority of the allocation relative to other memory allocations. Larger
	// values are higher priority. The granularity of the priorities is
	// implementation-dependent. It is automatically passed to every call to
	// `vk.allocateMemory` done by the library using structure
	// `vk.MemoryPriorityAllocateInfoEXT`. The value to be used for default
	// priority is 0.5. For more details, see the documentation of the
	// `VK_EXT_memory_priority` extension.
	EXT_MEMORY_PRIORITY,

	// Enables usage of `VK_KHR_maintenance4` extension in the library.
	//
	// You may set this flag only if you found available and enabled this device
	// extension, while creating Vulkan device passed as
	// `vma.AllocatorCreateInfo.device`.
	KHR_MAINTENANCE4,

	// Enables usage of `VK_KHR_maintenance5` extension in the library.
	//
	// You should set this flag if you found available and enabled this device
	// extension, while creating Vulkan device passed as
	// `vma.AllocatorCreateInfo.device`.
	KHR_MAINTENANCE5,

	// Enables usage of `VK_KHR_external_memory_win32` extension in the library.
	//
	// You should set this flag if you found available and enabled this device
	// extension, while creating Vulkan device passed as
	// `vma.AllocatorCreateInfo.device`.
	KHR_EXTERNAL_MEMORY_WIN32,
}

// Intended usage of the allocated memory.
MemoryUsage :: enum i32 {
	// No intended memory usage specified.
	//
	// Use other members of `vma.AllocationCreateInfo` to specify your requirements.
	UNKNOWN,
	// **Deprecated**: Obsolete, preserved for backward compatibility.
	//
	// Prefers `vk.MemoryPropertyFlags.DEVICE_LOCAL`.
	GPU_ONLY,
	// **Deprecated**: Obsolete, preserved for backward compatibility.
	//
	// Guarantees `vk.MemoryPropertyFlags.HOST_VISIBLE` and
	// `vk.MemoryPropertyFlags.HOST_COHERENT`.
	CPU_ONLY,
	// **Deprecated**: Obsolete, preserved for backward compatibility.
	//
	// Guarantees `vk.MemoryPropertyFlags.HOST_VISIBLE`, prefers
	// `vk.MemoryPropertyFlags.DEVICE_LOCAL`.
	CPU_TO_GPU,
	// **Deprecated**: Obsolete, preserved for backward compatibility.
	//
	// Guarantees `vk.MemoryPropertyFlags.HOST_VISIBLE`, prefers
	// `vk.MemoryPropertyFlags.HOST_CACHED`.
	GPU_TO_CPU,
	// **Deprecated**: Obsolete, preserved for backward compatibility.

	// Prefers not `vk.MemoryPropertyFlags.DEVICE_LOCAL`.
	CPU_COPY,
	// Lazily allocated GPU memory having `vk.MemoryPropertyFlags.LAZILY_ALLOCATED`.
	// Exists mostly on mobile platforms. Using it on desktop PC or other GPUs
	// with no such memory type present will fail the allocation.
	//
	// Usage: Memory for transient attachment images (color attachments, depth
	// attachments etc.), created with `vk.ImageUsageFlags.TRANSIENT_ATTACHMENT`.
	//
	// Allocations with this usage are always created as dedicated - it implies
	// `vma.AllocationCreateFlags.DEDICATED_MEMORY`.
	GPU_LAZILY_ALLOCATED,
	// Selects best memory type automatically. This flag is recommended for most
	// common use cases.
	//
	// When using this flag, if you want to map the allocation (using
	// `vma.MapMemory()` or `vma.AllocationCreateFlags.MAPPED`), you must pass
	// one of the flags: `.HOST_ACCESS_SEQUENTIAL_WRITE` or `.HOST_ACCESS_RANDOM` in
	// `vma.AllocationCreateInfo.flags`.
	//
	// It can be used only with functions that let the library know
	// `vk.BufferCreateInfo` or `vk.ImageCreateInfo`, e.g. `vma.CreateBuffer()`,
	// `vma.CreateImage()`, `vma.FindMemoryTypeIndexForBufferInfo()`,
	// `vma.FindMemoryTypeIndexForImageInfo()` and not with generic memory
	// allocation functions.
	AUTO,
	// Selects best memory type automatically with preference for GPU (device) memory.
	//
	// When using this flag, if you want to map the allocation (using
	// `vma.MapMemory()` or `vma.AllocationCreateFlags.MAPPED`), you must pass
	// one of the flags: `.HOST_ACCESS_SEQUENTIAL_WRITE` or
	// `.HOST_ACCESS_RANDOM` in `vma.AllocationCreateInfo.flags`.
	//
	// It can be used only with functions that let the library know
	// `vk.BufferCreateInfo` or `vk.ImageCreateInfo`, e.g. `vma.CreateBuffer()`,
	// `vma.CreateImage()`, `vma.FindMemoryTypeIndexForBufferInfo()`,
	// `vma.FindMemoryTypeIndexForImageInfo()` and not with generic memory
	// allocation functions.
	AUTO_PREFER_DEVICE,
	// Selects best memory type automatically with preference for CPU (host) memory.
	//
	// When using this flag, if you want to map the allocation (using
	// `vma.MapMemory()` or `vma.AllocationCreateFlags.MAPPED`.), you must pass
	// one of the flags: `.HOST_ACCESS_SEQUENTIAL_WRITE` or
	// `.HOST_ACCESS_RANDOM` in `vma.AllocationCreateInfo.flags`.
	//
	// It can be used only with functions that let the library know
	// `vk.BufferCreateInfo` or `vk.ImageCreateInfo`, e.g. `vma.CreateBuffer()`,
	// `vma.CreateImage()`, `vma.FindMemoryTypeIndexForBufferInfo()`,
	// `vma.FindMemoryTypeIndexForImageInfo()` and not with generic memory
	// allocation functions.
	AUTO_PREFER_HOST,
}

// Flags to be passed as AllocationCreateInfo::flags.
AllocationCreateFlags :: bit_set[AllocationCreateFlag; vk.Flags]
AllocationCreateFlag :: enum {
	// Set this flag if the allocation should have its own memory block.
	//
	// Use it for special, big resources, like fullscreen images used as attachments.
	//
	// If you use this flag while creating a buffer or an image,
	// `vk.MemoryDedicatedAllocateInfo` structure is applied if possible.
	DEDICATED_MEMORY                   = 0,

	// Set this flag to only try to allocate from existing `vk.DeviceMemory`
	// blocks and never create new such block.
	//
	// If new allocation cannot be placed in any of the existing blocks,
	// allocation fails with `vk.Result.ERROR_OUT_OF_DEVICE_MEMORY` error.
	//
	// You should not use `DEDICATED_MEMORY` and `NEVER_ALLOCATE` at the same
	// time. It makes no sense.
	NEVER_ALLOCATE                     = 1,
	// Set this flag to use a memory that will be persistently mapped and
	// retrieve pointer to it.
	//
	// Pointer to mapped memory will be returned through
	// `vma.AllocationInfo.pMappedData`.
	//
	// It is valid to use this flag for allocation made from memory type that is
	// not `HOST_VISIBLE`. This flag is then ignored and memory is not mapped.
	// This is useful if you need an allocation that is efficient to use on GPU
	// (`DEVICE_LOCAL`) and still want to map it directly if possible on
	// platforms that support it (e.g. Intel GPU).
	MAPPED                             = 2,
	// **Deprecated**: Preserved for backward compatibility. Consider using
	// `vma.SetAllocationName()` instead.
	//
	// Set this flag to treat `vma.AllocationCreateInfo.pUserData` as pointer to
	// a nil-terminated string. Instead of copying pointer value, a local copy
	// of the string is made and stored in allocation's `pName`. The string is
	// automatically freed together with the allocation. It is also used in
	// `vma.BuildStatsString()`.
	USER_DATA_COPY_STRING              = 5,
	// Allocation will be created from upper stack in a double stack pool.
	//
	// This flag is only allowed for custom pools created with
	// `vma.PoolCreateFlags.LINEAR_ALGORITHM` flag.
	UPPER_ADDRESS                      = 6,
	// Create both buffer/image and allocation, but don't bind them together. It
	// is useful when you want to bind yourself to do some more advanced
	// binding, e.g. using some extensions. The flag is meaningful only with
	// functions that bind by default: `vma.CreateBuffer()`, `vma.CreateImage()`.
	// Otherwise it is ignored.
	//
	// If you want to make sure the new buffer/image is not tied to the new
	// memory allocation through `vk.MemoryDedicatedAllocateInfoKHR` structure in
	// case the allocation ends up in its own memory block, use also flag `CAN_ALIAS`.
	DONT_BIND                          = 7,
	// Create allocation only if additional device memory required for it, if
	// any, won't exceed memory budget. Otherwise return
	// `vk.Result.ERROR_OUT_OF_DEVICE_MEMORY`.
	WITHIN_BUDGET                      = 8,
	// Set this flag if the allocated memory will have aliasing resources.
	//
	// Usage of this flag prevents supplying `vk.MemoryDedicatedAllocateInfoKHR`
	// when `DEDICATED_MEMORY` is specified. Otherwise created dedicated memory
	// will not be suitable for aliasing resources, resulting in Vulkan
	// Validation Layer errors.
	CAN_ALIAS                          = 9,
	// Requests possibility to map the allocation (using `vma.MapMemory()` or `.MAPPED`).
	//
	// - If you use `MemoryUsage.AUTO` or other `MemoryUsage.AUTO*`
	//   value, you must use this flag to be able to map the allocation.
	//   Otherwise, mapping is incorrect.
	// - If you use other value of `MemoryUsage`, this flag is ignored and
	//   mapping is always possible in memory types that are `HOST_VISIBLE`.
	//   This includes allocations created in custom memory pools.
	//
	// Declares that mapped memory will only be written sequentially, e.g. using
	// `memcpy()` or a loop writing number-by-number, never read or accessed
	// randomly, so a memory type can be selected that is uncached and
	// write-combined.
	//
	// Warning! Violating this declaration may work correctly, but will likely
	// be very slow. Watch out for implicit reads introduced by doing e.g.
	// `pMappedData[i] += x;` Better prepare your data in a local variable and
	// `memcpy()` it to the mapped pointer all at once.
	HOST_ACCESS_SEQUENTIAL_WRITE       = 10,
	// Requests possibility to map the allocation (using `vma.MapMemory()` or `MAPPED`).
	//
	// - If you use `MemoryUsage.AUTO` or other `MemoryUsage.AUTO*` value, you
	//   must use this flag to be able to map the allocation. Otherwise, mapping
	//   is incorrect.
	// - If you use other value of `MemoryUsage`, this flag is ignored and
	//   mapping is always possible in memory types that are `HOST_VISIBLE`.
	//   This includes allocations created in custom memory pools.
	//
	// Declares that mapped memory can be read, written, and accessed in random
	// order, so a `HOST_CACHED` memory type is preferred.
	HOST_ACCESS_RANDOM                 = 11,
	// Together with `.HOST_ACCESS_SEQUENTIAL_WRITE` or `.HOST_ACCESS_RANDOM`, it
	// says that despite request for host access, a not-`HOST_VISIBLE` memory
	// type can be selected if it may improve performance.
	//
	// By using this flag, you declare that you will check if the allocation
	// ended up in a `HOST_VISIBLE` memory type (e.g. using
	// `vma.GetAllocationMemoryProperties()`) and if not, you will create some
	// "staging" buffer and issue an explicit transfer to write/read your data.
	// To prepare for this possibility, don't forget to add appropriate flags
	// like `vk.BufferUsageFlags.TRANSFER_DST`, `vk.BufferUsageFlags.TRANSFER_SRC` to
	// the parameters of created buffer or image.
	HOST_ACCESS_ALLOW_TRANSFER_INSTEAD = 12,
	// Allocation strategy that chooses smallest possible free range for the
	// allocation to minimize memory usage and fragmentation, possibly at the
	// expense of allocation time.
	STRATEGY_MIN_MEMORY                = 16,
	// Allocation strategy that chooses first suitable free range for the
	// allocation - not necessarily in terms of the smallest offset but the one
	// that is easiest and fastest to find to minimize allocation time, possibly
	// at the expense of allocation quality.
	STRATEGY_MIN_TIME                  = 17,
	// Allocation strategy that chooses always the lowest offset in available space.
	// This is not the most efficient strategy but achieves highly packed data.
	// Used internally by defragmentation, not recommended in typical usage.
	STRATEGY_MIN_OFFSET                = 18,
}

// Alias to `STRATEGY_MIN_MEMORY`.
ALLOCATION_CREATE_FLAGS_STRATEGY_BEST_FIT :: AllocationCreateFlags{.STRATEGY_MIN_MEMORY}

// Alias to `STRATEGY_MIN_TIME`.
ALLOCATION_CREATE_FLAGS_STRATEGY_FIRST_FIT :: AllocationCreateFlags{.STRATEGY_MIN_TIME}

// A bit mask to extract only `STRATEGY` bits from entire set of flags.
ALLOCATION_CREATE_FLAGS_STRATEGY_MASK :: AllocationCreateFlags {
	.STRATEGY_MIN_MEMORY,
	.STRATEGY_MIN_TIME,
	.STRATEGY_MIN_OFFSET,
}

// Flags to be passed as `vma.PoolCreateInfo.flags`.
PoolCreateFlags :: bit_set[PoolCreateFlag; vk.Flags]
PoolCreateFlag :: enum i32 {
	// Use this flag if you always allocate only buffers and linear images or
	// only optimal images out of this pool and so Buffer-Image Granularity can
	// be ignored.
	//
	// This is an optional optimization flag.
	//
	// If you always allocate using `vma.CreateBuffer()`, `vma.CreateImage()`,
	// `vma.AllocateMemoryForBuffer()`, then you don't need to use it because
	// allocator knows exact type of your allocations so it can handle
	// Buffer-Image Granularity in the optimal way.
	//
	// If you also allocate using `vma.AllocateMemoryForImage()` or
	// `vma.AllocateMemory()`, exact type of such allocations is not known, so
	// allocator must be conservative in handling Buffer-Image Granularity,
	// which can lead to suboptimal allocation (wasted memory). In that case, if
	// you can make sure you always allocate only buffers and linear images or
	// only optimal images out of this pool, use this flag to make allocator
	// disregard Buffer-Image Granularity and so make allocations faster and
	// more optimal.
	IGNORE_BUFFER_IMAGE_GRANULARITY = 1,

	// Enables alternative, linear allocation algorithm in this pool.
	//
	// Specify this flag to enable linear allocation algorithm, which always
	// creates new allocations after last one and doesn't reuse space from
	// allocations freed in between. It trades memory consumption for simplified
	// algorithm and data structure, which has better performance and uses less
	// memory for metadata.
	//
	// By using this flag, you can achieve behavior of free-at-once, stack, ring
	// buffer, and double stack.
	LINEAR_ALGORITHM                = 2,
}

// Bit mask to extract only `ALGORITHM` bits from entire set of flags.
POOL_CREATE_FLAGS_ALGORITHM_MASK :: PoolCreateFlags{.LINEAR_ALGORITHM}

// Flags to be passed as DefragmentationInfo::flags.
DefragmentationFlags :: bit_set[DefragmentationFlag; vk.Flags]
DefragmentationFlag :: enum i32 {
	// Use simple but fast algorithm for defragmentation.
	//
	// May not achieve best results but will require least time to compute and
	// least allocations to copy.
	ALGORITHM_FAST,
	// Default defragmentation algorithm, applied also when no `ALGORITHM` flag
	// is specified.
	//
	// Offers a balance between defragmentation quality and the amount of
	// allocations and bytes that need to be moved.
	ALGORITHM_BALANCED,
	// Perform full defragmentation of memory.
	//
	// Can result in notably more time to compute and allocations to copy, but
	// will achieve best memory packing.
	ALGORITHM_FULL,
	// Use the most roboust algorithm at the cost of time to compute and number
	// of copies to make.
	//
	// Only available when bufferImageGranularity is greater than 1, since it
	// aims to reduce alignment issues between different types of resources.
	//
	// Otherwise falls back to same behavior as `ALGORITHM_FULL`.
	ALGORITHM_EXTENSIVE,
}

// A bit mask to extract only `ALGORITHM` bits from entire set of flags.
DEFRAGMENTATION_FLAGS_ALGORITHM_MASK :: DefragmentationFlags{
	.ALGORITHM_FAST,
	.ALGORITHM_BALANCED,
	.ALGORITHM_FULL,
	.ALGORITHM_EXTENSIVE}

// Operation performed on single defragmentation move. See structure #DefragmentationMove.
DefragmentationMoveOperation :: enum {
	// Buffer/image has been recreated at `dstTmpAllocation`, data has been
	// copied, old buffer/image has been destroyed. `srcAllocation` should be
	// changed to point to the new place. This is the default value set by
	// `vma.BeginDefragmentationPass()`.
	COPY,
	// Set this value if you cannot move the allocation. New place reserved at
	// `dstTmpAllocation` will be freed. `srcAllocation` will remain unchanged.
	IGNORE,
	// Set this value if you decide to abandon the allocation and you destroyed
	// the buffer/image. New place reserved at `dstTmpAllocation` will be freed,
	// along with `srcAllocation`, which will be destroyed.
	DESTROY,
}

// Flags to be passed as `vma.VirtualBlockCreateInfo.flags`.
VirtualBlockCreateFlags :: bit_set[VirtualBlockCreateFlag; vk.Flags]
VirtualBlockCreateFlag :: enum i32 {
	// Enables alternative, linear allocation algorithm in this virtual block.
	//
	// Specify this flag to enable linear allocation algorithm, which always creates
	// new allocations after last one and doesn't reuse space from allocations freed in
	// between. It trades memory consumption for simplified algorithm and data
	// structure, which has better performance and uses less memory for metadata.
	//
	// By using this flag, you can achieve behavior of free-at-once, stack,
	// ring buffer, and double stack.
	//
	// For details, see documentation chapter linear algorithm.
	LINEAR_ALGORITHM,
}

// Bit mask to extract only `ALGORITHM` bits from entire set of flags.
VIRTUAL_BLOCK_CREATE_FLAGS_ALGORITHM_MASK :: VirtualBlockCreateFlags{
	.LINEAR_ALGORITHM,
}

// Flags to be passed as `vma.VirtualAllocationCreateInfo.flags`.
VirtualAllocationCreateFlags :: bit_set[VirtualAllocationCreateFlag; vk.Flags]
VirtualAllocationCreateFlag :: enum i32 {
	// Allocation will be created from upper stack in a double stack pool.
	//
	// This flag is only allowed for virtual blocks created with
	// `vma.VirtualBlockCreateFlags.LINEAR_ALGORITHM` flag.
	UPPER_ADDRESS       = 6,
	// Allocation strategy that tries to minimize memory usage.
	STRATEGY_MIN_MEMORY = 16,
	// Allocation strategy that tries to minimize allocation time.
	STRATEGY_MIN_TIME   = 17,
	// Allocation strategy that chooses always the lowest offset in available space.
	// This is not the most efficient strategy but achieves highly packed data.
	STRATEGY_MIN_OFFSET = 18,
}

// A bit mask to extract only `STRATEGY` bits from entire set of flags.
//
// These strategy flags are binary compatible with equivalent flags in
// `vma.AllocationCreateFlags`.
VIRTUAL_ALLOCATION_CREATE_FLAGS_STRATEGY_MASK :: VirtualAllocationCreateFlags{
	.STRATEGY_MIN_MEMORY,
	.STRATEGY_MIN_TIME,
	.STRATEGY_MIN_OFFSET,
}

// Represents main object of this library initialized.
//
// Fill structure `vma.AllocatorCreateInfo` and call function
// `vma.CreateAllocator()` to create it. Call function `vma.DestroyAllocator()`
// to destroy it.
//
// It is recommended to create just one object of this type per `vk.Device`
// object, right after Vulkan is initialized and keep it alive until before
// Vulkan device is destroyed.
Allocator :: distinct vk.Handle

// Represents custom memory pool
//
// Fill structure `vma.PoolCreateInfo` and call function `.CreatePool()` to
// create it. Call function `vma.DestroyPool()` to destroy it.
Pool :: distinct vk.Handle

// Represents single memory allocation.
//
// It may be either dedicated block of `vk.DeviceMemory` or a specific region of
// a bigger block of this type plus unique offset.
//
// There are multiple ways to create such object. You need to fill structure
// `vma.AllocationCreateInfo`.
//
// Although the library provides convenience functions that create Vulkan buffer
// or image, allocate memory for it and bind them together, binding of the
// allocation to a buffer or an image is out of scope of the allocation itself.
// Allocation object can exist without buffer/image bound, binding can be done
// manually by the user, and destruction of it can be done independently of
// destruction of the allocation.
//
// The object also remembers its size and some other information. To retrieve
// this information, use function `vma.GetAllocationInfo()` and inspect returned
// structure AllocationInfo.
Allocation :: distinct vk.Handle

// An opaque object that represents started defragmentation process.
//
// Fill structure `vma.DefragmentationInfo` and call function
// `vma.BeginDefragmentation()` to create it. Call function
// `vma.EndDefragmentation()` to destroy it.
DefragmentationContext :: distinct vk.Handle

// Represents single memory allocation done inside `VirtualBlock`.
//
// Use it as a unique identifier to virtual allocation within the single block.
//
// Use value `{}` to represent a nil/invalid allocation.
VirtualAllocation :: distinct vk.NonDispatchableHandle

// Handle to a virtual block object that allows to use core allocation algorithm
// without allocating any real GPU memory.
//
// Fill in `vma.VirtualBlockCreateInfo` structure and use `vma.CreateVirtualBlock()`
// to create it. Use `vma.DestroyVirtualBlock()` to destroy it.
//
// This object is not thread-safe - should not be used from multiple threads
// simultaneously, must be synchronized externally.
VirtualBlock :: distinct vk.Handle

// Callback function called after successful vk.AllocateMemory.
AllocateDeviceMemoryProc :: #type proc "c" (
	allocator: Allocator,
	memoryType: u32,
	memory: vk.DeviceMemory,
	size: vk.DeviceSize,
	pUserData: rawptr)

// Callback function called before vk.FreeMemory.
FreeDeviceMemoryProc :: #type proc "c" (
	allocator: Allocator,
	memoryType: u32,
	memory: vk.DeviceMemory,
	size: vk.DeviceSize,
	pUserData: rawptr)

// Set of callbacks that the library will call for `vk.AllocateMemory` and `vk.FreeMemory`.
//
// Provided for informative purpose, e.g. to gather statistics about number of
// allocations or total amount of memory allocated in Vulkan.
//
// Used in `vma.AllocatorCreateInfo.pDeviceMemoryCallbacks`.
DeviceMemoryCallbacks :: struct {
	// Optional, can be nil.
	pfnAllocate: AllocateDeviceMemoryProc,
	// Optional, can be nil.
	pfnFree:     FreeDeviceMemoryProc,
	// Optional, can be nil.
	pUserData:   rawptr,
}

// Pointers to some Vulkan functions - a subset used by the library.
//
// Used in AllocatorCreateInfo.pVulkanFunctions.
VulkanFunctions :: struct {
	// Required when using VMA_DYNAMIC_VULKAN_FUNCTIONS.
	GetInstanceProcAddr:                   vk.ProcGetInstanceProcAddr,
	// Required when using VMA_DYNAMIC_VULKAN_FUNCTIONS.
	GetDeviceProcAddr:                     vk.ProcGetDeviceProcAddr,
	GetPhysicalDeviceProperties:           vk.ProcGetPhysicalDeviceProperties,
	GetPhysicalDeviceMemoryProperties:     vk.ProcGetPhysicalDeviceMemoryProperties,
	AllocateMemory:                        vk.ProcAllocateMemory,
	FreeMemory:                            vk.ProcFreeMemory,
	MapMemory:                             vk.ProcMapMemory,
	UnmapMemory:                           vk.ProcUnmapMemory,
	FlushMappedMemoryRanges:               vk.ProcFlushMappedMemoryRanges,
	InvalidateMappedMemoryRanges:          vk.ProcInvalidateMappedMemoryRanges,
	BindBufferMemory:                      vk.ProcBindBufferMemory,
	BindImageMemory:                       vk.ProcBindImageMemory,
	GetBufferMemoryRequirements:           vk.ProcGetBufferMemoryRequirements,
	GetImageMemoryRequirements:            vk.ProcGetImageMemoryRequirements,
	CreateBuffer:                          vk.ProcCreateBuffer,
	DestroyBuffer:                         vk.ProcDestroyBuffer,
	CreateImage:                           vk.ProcCreateImage,
	DestroyImage:                          vk.ProcDestroyImage,
	CmdCopyBuffer:                         vk.ProcCmdCopyBuffer,
	// Fetch `vk.GetBufferMemoryRequirements2` on Vulkan >= 1.1, fetch
	// `vk.GetBufferMemoryRequirements2KHR` when using
	// `VK_KHR_dedicated_allocation` extension.
	GetBufferMemoryRequirements2KHR:       vk.ProcGetBufferMemoryRequirements2KHR,
	// Fetch `vk.GetImageMemoryRequirements2` on Vulkan >= 1.1, fetch
	// `vk.GetImageMemoryRequirements2KHR` when using
	// `VK_KHR_dedicated_allocation` extension.
	GetImageMemoryRequirements2KHR:        vk.ProcGetImageMemoryRequirements2KHR,
	// Fetch `vk.BindBufferMemory2` on Vulkan >= 1.1, fetch
	// `vk.BindBufferMemory2KHR` when using `VK_KHR_bind_memory2` extension.
	BindBufferMemory2KHR:                  vk.ProcBindBufferMemory2KHR,
	// Fetch `vk.BindImageMemory2` on Vulkan >= 1.1, fetch
	// `vk.BindImageMemory2KHR` when using `VK_KHR_bind_memory2` extension.
	BindImageMemory2KHR:                   vk.ProcBindImageMemory2KHR,
	// Fetch from `vk.GetPhysicalDeviceMemoryProperties2` on Vulkan >= 1.1, but
	// you can also fetch it from `vk.GetPhysicalDeviceMemoryProperties2KHR` if
	// you enabled extension `VK_KHR_get_physical_device_properties2`.
	GetPhysicalDeviceMemoryProperties2KHR: vk.ProcGetPhysicalDeviceMemoryProperties2KHR,
	// Fetch from `vk.GetDeviceBufferMemoryRequirements` on Vulkan >= 1.3, but
	// you can also fetch it from `vk.GetDeviceBufferMemoryRequirementsKHR` if
	// you enabled extension `VK_KHR_maintenance4`.
	GetDeviceBufferMemoryRequirements:     vk.ProcGetDeviceBufferMemoryRequirementsKHR,
	// Fetch from `vk.GetDeviceImageMemoryRequirements` on Vulkan >= 1.3, but
	// you can also fetch it from `vk.GetDeviceImageMemoryRequirementsKHR` if
	// you enabled extension `VK_KHR_maintenance4`.
	GetDeviceImageMemoryRequirements:      vk.ProcGetDeviceImageMemoryRequirementsKHR,
	GetMemoryWin32HandleKHR:               vk.ProcGetMemoryWin32HandleKHR,
	// Fetch from `vk.GetPhysicalDeviceProperties2` on Vulkan >= 1.1, but you
	// can also fetch it from `vk.GetPhysicalDeviceProperties2KHR` if you
	// enabled extension `VK_KHR_get_physical_device_properties2`.
	GetPhysicalDeviceProperties2KHR:       vk.ProcGetPhysicalDeviceProperties2KHR,
}

// Description of a Allocator to be created.
AllocatorCreateInfo :: struct {
	// Flags for created allocator. Use `vma.AllocatorCreateFlags`.
	flags:                          AllocatorCreateFlags,
	// Vulkan physical device.
	//
	// It must be valid throughout whole lifetime of created allocator.
	physicalDevice:                 vk.PhysicalDevice,
	// Vulkan device.
	//
	// It must be valid throughout whole lifetime of created allocator.
	device:                         vk.Device,
	// Preferred size of a single `vk.DeviceMemory` block to be allocated from
	// large heaps > 1 GiB. Optional. Set to 0 to use default, which is
	// currently 256 MiB.
	preferredLargeHeapBlockSize:    vk.DeviceSize,
	// Custom CPU memory allocation callbacks. Optional, can be nil.
	// When specified, will also be used for all CPU-side memory allocations.
	pAllocationCallbacks:           ^vk.AllocationCallbacks,
	// Informative callbacks for `vk.AllocateMemory`, `vk.FreeMemory`. Optional,
	// can be nil.
	pDeviceMemoryCallbacks:         ^DeviceMemoryCallbacks,
	// Either nil or a pointer to an array of limits on maximum number of bytes
	// that can be allocated out of particular Vulkan memory heap.
	//
	// If not nil, it must be a pointer to an array of
	// `vk.PhysicalDeviceMemoryProperties.memoryHeapCount` elements, defining
	// limit on maximum number of bytes that can be allocated out of particular
	// Vulkan memory heap.
	//
	// Any of the elements may be equal to `vk.WHOLE_SIZE`, which means no limit
	// on that heap. This is also the default in case of `pHeapSizeLimit` = nil.
	//
	// If there is a limit defined for a heap:
	//
	// - If user tries to allocate more memory from that heap using this
	//   allocator, the allocation fails with `vk.Result.ERROR_OUT_OF_DEVICE_MEMORY`.
	// - If the limit is smaller than heap size reported in
	//   `vk.MemoryHeap.size`, the value of this limit will be reported instead
	//   when using `vma.GetMemoryProperties()`.
	//
	// Warning! Using this feature may not be equivalent to installing a GPU
	// with smaller amount of memory, because graphics driver doesn't necessary
	// fail new allocations with `vk.Result.ERROR_OUT_OF_DEVICE_MEMORY` result when
	// memory capacity is exceeded. It may return success and just silently
	// migrate some device memory blocks to system RAM. This driver behavior can
	// also be controlled using `VK_AMD_memory_overallocation_behavior` extension.
	pHeapSizeLimit:                 ^vk.DeviceSize,
	// Pointers to Vulkan functions. Can be nil.
	pVulkanFunctions:               ^VulkanFunctions,
	// Handle to Vulkan instance object.
	//
	// Starting from version 3.0.0 this member is no longer optional, it must be set!
	instance:                       vk.Instance,
	// Optional. Vulkan version that the application uses.
	//
	// It must be a value in the format as created by macro `vk.MAKE_VERSION` or
	// a constant like: `vk.API_VERSION_1_1`, `vk.API_VERSION_1_0`. The patch
	// version number specified is ignored. Only the major and minor versions
	// are considered. Only versions 1.0...1.4 are supported by the current
	// implementation. Leaving it initialized to zero is equivalent to
	// `vk.API_VERSION_1_0`. It must match the Vulkan version used by the
	// application and supported on the selected physical device, so it must be
	// no higher than `vk.ApplicationInfo.apiVersion` passed to
	// `vk.CreateInstance` and no higher than
	// `vk.PhysicalDeviceProperties.apiVersion` found on the physical device used.
	vulkanApiVersion:               u32,
	// Either nil or a pointer to an array of external memory handle types for
	// each Vulkan memory type.
	//
	// If not nil, it must be a pointer to an array of
	// `vk.PhysicalDeviceMemoryProperties.memoryTypeCount` elements, defining
	// external memory handle types of particular Vulkan memory type, to be
	// passed using `vk.ExportMemoryAllocateInfoKHR`.
	//
	// Any of the elements may be equal to 0, which means not to use
	// `vk.ExportMemoryAllocateInfoKHR` on this memory type. This is also the
	// default in case of `pTypeExternalMemoryHandleTypes` = nil.
	pTypeExternalMemoryHandleTypes: ^vk.ExternalMemoryHandleTypeFlagsKHR,
}

// Information about existing `Allocator` object.
AllocatorInfo :: struct {
	// Handle to Vulkan instance object.
	//
	// This is the same value as has been passed through
	// `vma.AllocatorCreateInfo.instance`.
	instance:       vk.Instance,
	// Handle to Vulkan physical device object.
	//
	// This is the same value as has been passed through
	// `vma.AllocatorCreateInfo.physicalDevice`.
	physicalDevice: vk.PhysicalDevice,
	// Handle to Vulkan device object.
	//
	// This is the same value as has been passed through
	// `vma.AllocatorCreateInfo.device`.
	device:         vk.Device,
}

// Calculated statistics of memory usage e.g. in a specific memory type, heap,
// custom pool, or total.
//
// These are fast to calculate. See functions: `vma.GetHeapBudgets()`,
// `vma.GetPoolStatistics()`.
Statistics :: struct {
	// Number of `vk.DeviceMemory` objects - Vulkan memory blocks allocated.
	blockCount:      u32,
	// Number of `Allocation` objects allocated.
	//
	// Dedicated allocations have their own blocks, so each one adds 1 to
	// `allocationCount` as well as `blockCount`.
	allocationCount: u32,
	// Number of bytes allocated in `vk.DeviceMemory` blocks.
	//
	// NOTE: To avoid confusion, please be aware that what Vulkan calls an
	// "allocation" - a whole `vk.DeviceMemory` object (e.g. as in
	// `vk.PhysicalDeviceLimits.maxMemoryAllocationCount`) is called a "block"
	// in VMA, while VMA calls "allocation" a `Allocation` object that represents
	// a memory region sub-allocated from such block, usually for a single
	// buffer or image.
	blockBytes:      vk.DeviceSize,
	// Total number of bytes occupied by all `Allocation` objects.
	//
	// Always less or equal than `blockBytes`. Difference `(blockBytes -
	// allocationBytes)` is the amount of memory allocated from Vulkan but
	// unused by any `Allocation`.
	allocationBytes: vk.DeviceSize,
}

// More detailed statistics than #Statistics.
//
// These are slower to calculate. Use for debugging purposes.
// See functions: `vma.CalculateStatistics()`, `vma.CalculatePoolStatistics()`.
//
// Previous version of the statistics API provided averages, but they have been removed
// because they can be easily calculated as:
//
//    allocation_size_avg := detailed_stats.statistics.allocationBytes / detailed_stats.statistics.allocationCount
//    unused_bytes := detailed_stats.statistics.blockBytes - detailed_stats.statistics.allocationBytes
//    unused_range_size_avg := unused_bytes / detailed_stats.unusedRangeCount
DetailedStatistics :: struct {
	// Basic statistics.
	statistics:         Statistics,
	// Number of free ranges of memory between allocations.
	unusedRangeCount:   u32,
	// Smallest allocation size. `vk.WHOLE_SIZE` if there are 0 allocations.
	allocationSizeMin:  vk.DeviceSize,
	// Largest allocation size. 0 if there are 0 allocations.
	allocationSizeMax:  vk.DeviceSize,
	// Smallest empty range size. `vk.WHOLE_SIZE` if there are 0 empty ranges.
	unusedRangeSizeMin: vk.DeviceSize,
	// Largest empty range size. 0 if there are 0 empty ranges.
	unusedRangeSizeMax: vk.DeviceSize,
}

// General statistics from current state of the Allocator -
// total memory usage across all memory heaps and types.
//
// These are slower to calculate. Use for debugging purposes.
// See function vmaCalculateStatistics().
TotalStatistics :: struct {
	memoryType: [vk.MAX_MEMORY_TYPES]DetailedStatistics,
	memoryHeap: [vk.MAX_MEMORY_HEAPS]DetailedStatistics,
	total:      DetailedStatistics,
}

// Statistics of current memory usage and available budget for a specific memory heap.
//
// These are fast to calculate.
//
// See function `vma.GetHeapBudgets()`.
Budget :: struct {
	// Statistics fetched from the library.
	statistics: Statistics,
	// Estimated current memory usage of the program, in bytes.
	//
	// Fetched from system using `VK_EXT_memory_budget` extension if enabled.
	//
	// It might be different than `statistics.blockBytes` (usually higher) due
	// to additional implicit objects also occupying the memory, like swapchain,
	// pipelines, descriptor heaps, command buffers, or `vk.DeviceMemory` blocks
	// allocated outside of this library, if any.
	usage:      vk.DeviceSize,
	// Estimated amount of memory available to the program, in bytes.
	//
	// Fetched from system using `VK_EXT_memory_budget` extension if enabled.
	//
	// It might be different (most probably smaller) than
	// `vk.MemoryHeap.size[heapIndex]` due to factors external to the program,
	// decided by the operating system. Difference `budget - usage` is the
	// amount of additional memory that can probably be allocated without
	// problems. Exceeding the budget may result in various problems.
	budget:     vk.DeviceSize,
}

// Parameters of new `Allocation`.
//
// To be used with functions like `vma.CreateBuffer()`, `vma.CreateImage()`, and
// many others.
AllocationCreateInfo :: struct {
	// Use `vma.AllocationCreateFlags`.
	flags:          AllocationCreateFlags,
	// Intended usage of memory.
	//
	// You can leave `vma.MemoryUsage.UNKNOWN` if you specify memory
	// requirements in other way.
	//
	// If `pool` is not nil, this member is ignored.
	usage:          MemoryUsage,
	// Flags that must be set in a Memory Type chosen for an allocation.
	//
	// Leave 0 if you specify memory requirements in other way.
	// \n If `pool` is not nil, this member is ignored.
	requiredFlags:  vk.MemoryPropertyFlags,
	// Flags that preferably should be set in a memory type chosen for an allocation.
	//
	// Set to 0 if no additional flags are preferred.
	//
	// If `pool` is not nil, this member is ignored.
	preferredFlags: vk.MemoryPropertyFlags,
	// Bitmask containing one bit set for every memory type acceptable for this allocation.
	//
	// Value 0 is equivalent to `max(u32)` - it means any memory type is
	// accepted if it meets other requirements specified by this structure, with
	// no further restrictions on memory type index.
	//
	// If `pool` is not nil, this member is ignored.
	memoryTypeBits: u32,
	// Pool that this allocation should be created in.
	//
	// Leave `{}` to allocate from default pool. If not nil, members: `usage`,
	// `requiredFlags`, `preferredFlags`, `memoryTypeBits` are ignored.
	pool:           Pool,
	// Custom general-purpose pointer that will be stored in `Allocation`, can
	// be read as `vma.AllocationInfo.pUserData` and changed using
	// `vma.SetAllocationUserData()`.
	//
	// If `vma.AllocationCreateFlags.USER_DATA_COPY_STRING` is used, it must be
	// either nil or pointer to a nil-terminated string. The string will be then
	// copied to internal buffer, so it doesn't need to be valid after
	// allocation call.
	pUserData:      rawptr,
	// A floating-point value between 0 and 1, indicating the priority of the
	// allocation relative to other memory allocations.
	//
	// It is used only when `vma.AllocatorCreateFlags.EXT_MEMORY_PRIORITY` flag
	// was used during creation of the `Allocator` object and this allocation
	// ends up as dedicated or is explicitly forced as dedicated using
	// `vma.AllocationCreateFlags.DEDICATED_MEMORY`. Otherwise, it has the
	// priority of a memory block where it is placed and this variable is ignored.
	priority:       f32,
	// Additional minimum alignment to be used for this allocation. Can be 0.
	//
	// Leave 0 (default) not to impose any additional alignment. If not 0, it
	// must be a power of two.
	//
	// When creating a buffer or an image, specifying a custom alignment is not
	// needed in most cases, because Vulkan implementation inspects the
	// `CreateInfo` structure (including intended usage flags) and returns
	// required alignment through functions like
	// `vk.GetBufferMemoryRequirements2`, which VMA automatically uses and
	// respects. Extra alignment may be needed in some cases, like when using a
	// buffer for acceleration structure scratch
	// (`vk.PhysicalDeviceAccelerationStructurePropertiesKHR.
	// minAccelerationStructureScratchOffsetAlignment`,
	// see also issue #523) or when doing interop with OpenGL.
	minAlignment: vk.DeviceSize,
}

// Describes parameter of created #Pool.
PoolCreateInfo :: struct {
	// Vulkan memory type index to allocate this pool from.
	memoryTypeIndex:        u32,
	// Use combination of `PoolCreateFlags`.
	flags:                  PoolCreateFlags,
	// Size of a single `vk.DeviceMemory` block to be allocated as part of this
	// pool, in bytes. Optional.
	//
	// Specify nonzero to set explicit, constant size of memory blocks used by
	// this pool.
	//
	// Leave 0 to use default and let the library manage block sizes
	// automatically. Sizes of particular blocks may vary. In this case, the
	// pool will also support dedicated allocations.
	blockSize:              vk.DeviceSize,
	// Minimum number of blocks to be always allocated in this pool, even if they stay empty.
	//
	// Set to 0 to have no preallocated blocks and allow the pool be completely empty.
	minBlockCount:          uint,
	// Maximum number of blocks that can be allocated in this pool. Optional.
	//
	// Set to 0 to use default, which is `max(uint)`, which means no limit.
	//
	// Set to same value as `vma.PoolCreateInfo.minBlockCount` to have fixed amount
	// of memory allocated throughout whole lifetime of this pool.
	maxBlockCount:          uint,
	// A floating-point value between 0 and 1, indicating the priority of the
	// allocations in this pool relative to other memory allocations.
	//
	// It is used only when `vma.AllocatorCreateFlags.EXT_MEMORY_PRIORITY` flag
	// was used during creation of the `Allocator` object. Otherwise, this
	// variable is ignored.
	priority:               f32,
	// Additional minimum alignment to be used for all allocations created from
	// this pool. Can be 0.
	//
	// Leave 0 (default) not to impose any additional alignment. If not 0, it
	// must be a power of two.
	//
	// When creating a buffer or an image, specifying a custom alignment is not
	// needed in most cases, because Vulkan implementation inspects the
	// `CreateInfo` structure (including intended usage flags) and returns
	// required alignment through functions like
	// `vk.GetBufferMemoryRequirements2`, which VMA automatically uses and
	// respects. Extra alignment may be needed in some cases, like when using a
	// buffer for acceleration structure scratch
	// (`vk.PhysicalDeviceAccelerationStructurePropertiesKHR.
	// minAccelerationStructureScratchOffsetAlignment`,
	// see also issue #523) or when doing interop with OpenGL.
	minAllocationAlignment: vk.DeviceSize,
	// Additional `pNext` chain to be attached to `vk.MemoryAllocateInfo` used
	// for every allocation made by this pool. Optional.
	//
	// Optional, can be nil. If not nil, it must point to a `pNext` chain of
	// structures that can be attached to `vk.MemoryAllocateInfo`. It can be
	// useful for special needs such as adding `VkExportMemoryAllocateInfoKHR`.
	// Structures pointed by this member must remain alive and unchanged for the
	// whole lifetime of the custom pool.
	//
	// Please note that some structures, e.g. `vk.MemoryPriorityAllocateInfoEXT`,
	// `vk.MemoryDedicatedAllocateInfoKHR`, can be attached automatically by this
	// library when using other, more convenient of its features.
	pMemoryAllocateNext:    rawptr,
}

// Parameters of `Allocation` objects, that can be retrieved using function
// `vma.GetAllocationInfo()`.
//
// There is also an extended version of this structure that carries additional
// parameters: `vma.AllocationInfo2`.
AllocationInfo :: struct {
	// Memory type index that this allocation was allocated from.
	//
	// It never changes.
	memoryType:   u32,
	// Handle to Vulkan memory object.
	//
	// Same memory object can be shared by multiple allocations.
	//
	// It can change after the allocation is moved during defragmentation.
	deviceMemory: vk.DeviceMemory,
	// Offset in `vk.DeviceMemory` object to the beginning of this allocation,
	// in bytes. `(deviceMemory, offset)` pair is unique to this allocation.
	//
	// You usually don't need to use this offset. If you create a buffer or an
	// image together with the allocation using e.g. function `vma.CreateBuffer()`,
	// `vma.CreateImage()`, functions that operate on these resources refer to the
	// beginning of the buffer or image, not entire device memory block.
	// Functions like `vma.MapMemory()`, `vma.BindBufferMemory()` also refer to the
	// beginning of the allocation and apply this offset automatically.
	//
	// It can change after the allocation is moved during defragmentation.
	offset:       vk.DeviceSize,
	// Size of this allocation, in bytes.
	//
	// It never changes.
	//
	// NOTE - Allocation size returned in this variable may be greater than the size
	// requested for the resource e.g. as `vk.BufferCreateInfo.size`. Whole size of the
	// allocation is accessible for operations on memory e.g. using a pointer after
	// mapping with `vma.MapMemory()`, but operations on the resource e.g. using
	// `vk.CmdCopyBuffer` must be limited to the size of the resource.
	size:         vk.DeviceSize,
	// Pointer to the beginning of this allocation as mapped data.
	//
	// If the allocation hasn't been mapped using `vma.MapMemory()` and hasn't been
	// created with `vma.AllocationCreateFlags.MAPPED` flag, this value is nil.
	//
	// It can change after call to `vma.MapMemory()`, `vma.UnmapMemory()`. It can also
	// change after the allocation is moved during defragmentation.
	pMappedData:  rawptr,
	// Custom general-purpose pointer that was passed as
	// `vma.AllocationCreateInfo.pUserData` or set using
	// `vma.SetAllocationUserData()`.
	//
	// It can change after call to `vma.SetAllocationUserData()` for this allocation.
	pUserData:    rawptr,
	// Custom allocation name that was set with `vma.SetAllocationName()`.
	//
	// It can change after call to `vma.SetAllocationName()` for this allocation.
	//
	// Another way to set custom name is to pass it in
	// `vma.AllocationCreateInfo.pUserData` with additional flag
	// `vma.AllocationCreateFlags.USER_DATA_COPY_STRING` set [DEPRECATED].
	pName:        cstring,
}

// Extended parameters of a `Allocation` object that can be retrieved using
// function `vma.GetAllocationInfo2()`.
AllocationInfo2 :: struct {
	// Basic parameters of the allocation.
	//
	// If you need only these, you can use function vmaGetAllocationInfo() and
	// structure `AllocationInfo` instead.
	allocationInfo:  AllocationInfo,
	// Size of the `vk.DeviceMemory` block that the allocation belongs to.
	//
	// In case of an allocation with dedicated memory, it will be equal to
	// `allocationInfo.size`.
	blockSize:       vk.DeviceSize,
	// `true` if the allocation has dedicated memory, `false` if it was
	// placed as part of a larger memory block.
	//
	// When `true`, it also means `vk.MemoryDedicatedAllocateInfo` was used when
	// creating the allocation (if `VK_KHR_dedicated_allocation` extension or
	// Vulkan version >= 1.1 is enabled).
	dedicatedMemory: b32,
}

// Callback function called during `vma.BeginDefragmentation()` to check custom
// criterion about ending current defragmentation pass.
//
// Should return true if the defragmentation needs to stop current pass.
CheckDefragmentationBreakProc :: #type proc "c" (pUserData: rawptr) -> b32

// Parameters for defragmentation.
//
// To be used with function `vma.BeginDefragmentation()`.
DefragmentationInfo :: struct {
	// Use combination of `vma.DefragmentationFlags`.
	flags:                  DefragmentationFlags,
	// Custom pool to be defragmented.
	//
	// If nil then default pools will undergo defragmentation process.
	pool:                   Pool,
	// Maximum numbers of bytes that can be copied during single pass, while
	// moving allocations to different places.
	//
	// `0` means no limit.
	maxBytesPerPass:        vk.DeviceSize,
	// Maximum number of allocations that can be moved during single pass to a different place.
	//
	// `0` means no limit.
	maxAllocationsPerPass:  u32,
	// Optional custom callback for stopping `vma.BeginDefragmentation()`.
	//
	// Have to return true for breaking current defragmentation pass.
	pfnBreakCallback:       CheckDefragmentationBreakProc,
	// Optional data to pass to custom callback for stopping pass of defragmentation.
	pBreakCallbackUserData: rawptr,
}

// Single move of an allocation to be done for defragmentation.
DefragmentationMove :: struct {
	// Operation to be performed on the allocation by
	// `vma.EndDefragmentationPass()`. Default value is `.COPY`. You can modify it.
	operation:        DefragmentationMoveOperation,
	// Allocation that should be moved.
	srcAllocation:    Allocation,
	// Temporary allocation pointing to destination memory that will replace `srcAllocation`.
	//
	// Warning! Do not store this allocation in your data structures! It exists
	// only temporarily, for the duration of the defragmentation pass, to be
	// used for binding new buffer/image to the destination memory using e.g.
	// `vma.BindBufferMemory()`. `vma.EndDefragmentationPass()` will destroy it and
	// make `srcAllocation` point to this memory.
	dstTmpAllocation: Allocation,
}

// Parameters for incremental defragmentation steps.
//
// To be used with function `vma.BeginDefragmentationPass()`.
DefragmentationPassMoveInfo :: struct {
	// Number of elements in the `pMoves` array.
	moveCount: u32,
	// Array of moves to be performed by the user in the current defragmentation pass.
	//
	// Pointer to an array of `moveCount` elements, owned by VMA, created in
	// `vma.BeginDefragmentationPass()`, destroyed in `vma.EndDefragmentationPass()`.
	//
	// For each element, you should:
	//
	// 1. Create a new buffer/image in the place pointed by
	//    `DefragmentationMove.dstMemory` + `DefragmentationMove.dstOffset`.
	// 2. Copy data from the `DefragmentationMove.srcAllocation` e.g. using
	//    `vk.CmdCopyBuffer`, `vk.CmdCopyImage`.
	// 3. Make sure these commands finished executing on the GPU.
	// 4. Destroy the old buffer/image.
	//
	// Only then you can finish defragmentation pass by calling
	// `vma.EndDefragmentationPass()`. After this call, the allocation will point
	// to the new place in memory.
	//
	// Alternatively, if you cannot move specific allocation, you can set
	// `DefragmentationMove.operation` to `.IGNORE`.
	//
	// Alternatively, if you decide you want to completely remove the allocation:
	//
	// 1. Destroy its buffer/image.
	// 2. Set `DefragmentationMove.operation` to `.DESTROY`.
	//
	// Then, after `vma.EndDefragmentationPass()` the allocation will be freed.
	pMoves:    ^DefragmentationMove,
}

// Statistics returned for defragmentation process in function `vma.EndDefragmentation()`.
DefragmentationStats :: struct {
	// Total number of bytes that have been copied while moving allocations to different places.
	bytesMoved:              vk.DeviceSize,
	// Total number of bytes that have been released to the system by freeing
	// empty `vk.DeviceMemory` objects.
	bytesFreed:              vk.DeviceSize,
	// Number of allocations that have been moved to different places.
	allocationsMoved:        u32,
	// Number of empty `vk.DeviceMemory` objects that have been released to the system.
	deviceMemoryBlocksFreed: u32,
}

// Parameters of created `VirtualBlock` object to be passed to `vma.CreateVirtualBlock()`.
VirtualBlockCreateInfo :: struct {
	// Total size of the virtual block.
	//
	// Sizes can be expressed in bytes or any units you want as long as you are
	// consistent in using them. For example, if you allocate from some array of
	// structures, 1 can mean single instance of entire structure.
	size:                 vk.DeviceSize,

	// Use combination of `vma.VirtualBlockCreateFlags`.
	flags:                VirtualBlockCreateFlags,

	// Custom CPU memory allocation callbacks. Optional.
	//
	// Optional, can be nil. When specified, they will be used for all CPU-side
	// memory allocations.
	pAllocationCallbacks: ^vk.AllocationCallbacks,
}

// Parameters of created virtual allocation to be passed to `vma.VirtualAllocate()`.
VirtualAllocationCreateInfo :: struct {
	// Size of the allocation.
	//
	// Cannot be zero.
	size:      vk.DeviceSize,
	// Required alignment of the allocation. Optional.
	//
	// Must be power of two. Special value 0 has the same meaning as 1 - means
	// no special alignment is required, so allocation can start at any offset.
	alignment: vk.DeviceSize,
	// Use combination of `vma.VirtualAllocationCreateFlags`.
	flags:     VirtualAllocationCreateFlags,
	// Custom pointer to be associated with the allocation. Optional.
	//
	// It can be any value and can be used for user-defined purposes. It can be
	// fetched or changed later.
	pUserData: rawptr,
}

// Parameters of an existing virtual allocation, returned by `vma.GetVirtualAllocationInfo()`.
VirtualAllocationInfo :: struct {
	// Offset of the allocation.
	//
	// Offset at which the allocation was made.
	offset: vk.DeviceSize,
	// Size of the allocation.
	//
	// Same value as passed in `vma.VirtualAllocationCreateInfo.size`.
	size: vk.DeviceSize,
	// Custom pointer associated with the allocation.
	//
	// Same value as passed in `vma.VirtualAllocationCreateInfo.pUserData` or to
	// `vma.SetVirtualAllocationUserData()`.
	pUserData: rawptr,
}

@(link_prefix="vma")
@(default_calling_convention="c")
foreign vmalib {
	// Creates `vma.Allocator` object.
	CreateAllocator :: proc(
		#by_ptr pCreateInfo: AllocatorCreateInfo,
		pAllocator: ^Allocator) -> vk.Result ---

	// Destroys allocator object.
	DestroyAllocator :: proc(
		allocator: Allocator) ---

	// Returns information about existing `Allocator` object - handle to Vulkan
	// device etc.
	//
	// It might be useful if you want to keep just the `Allocator` handle and
	// fetch other required handles to `vk.PhysicalDevice`, `vk.Device` etc.
	// every time using this function.
	GetAllocatorInfo :: proc(
		allocator: Allocator,
		pAllocatorInfo: ^AllocatorInfo) ---

	// `vk.PhysicalDeviceProperties` are fetched from `physicalDevice` by the
	// `allocator`. You can access it here, without fetching it again on your own.
	GetPhysicalDeviceProperties :: proc(
		allocator: Allocator,
		ppPhysicalDeviceProperties: ^^vk.PhysicalDeviceProperties) ---

	// `vk.PhysicalDeviceMemoryProperties` are fetched from `physicalDevice` by the
	// `allocator`. You can access it here, without fetching it again on your own.
	GetMemoryProperties :: proc(
		allocator: Allocator,
		ppPhysicalDeviceMemoryProperties: ^^vk.PhysicalDeviceMemoryProperties) ---

	// Given Memory Type Index, returns Property Flags of this memory type.
	//
	// This is just a convenience function. Same information can be obtained using
	// `vma.GetMemoryProperties()`.
	GetMemoryTypeProperties :: proc(
		allocator: Allocator,
		memoryTypeIndex: u32,
		pFlags: ^vk.MemoryPropertyFlags) ---

	// Sets index of the current frame.
	SetCurrentFrameIndex :: proc(
		allocator: Allocator,
		frameIndex: u32) ---

	// Retrieves statistics from current state of the Allocator.
	//
	// This function is called "calculate" not "get" because it has to traverse
	// all internal data structures, so it may be quite slow. Use it for
	// debugging purposes. For faster but more brief statistics suitable to be
	// called every frame or every allocation, use vmaGetHeapBudgets().
	//
	// Note that when using allocator from multiple threads, returned
	// information may immediately become outdated.
	CalculateStatistics :: proc(
		allocator: Allocator,
		pStats: ^TotalStatistics) ---

	// Retrieves information about current memory usage and budget for all memory heaps.
	//
	// - `allocator`
	// - `[out] pBudgets` Must point to array with number of elements at least equal to
	//   number of memory heaps in physical device used.
	//
	// This function is called "get" not "calculate" because it is very fast, suitable
	// to be called every frame or every allocation. For more detailed statistics use
	// `vma.CalculateStatistics()`.
	//
	// Note that when using allocator from multiple threads, returned information may
	// immediately become outdated.
	GetHeapBudgets :: proc(
		allocator: Allocator,
		pBudgets: ^Budget) ---

	// Helps to find `memoryTypeIndex`, given `memoryTypeBits` and `AllocationCreateInfo`.
	//
	// This algorithm tries to find a memory type that:
	//
	// - Is allowed by `memoryTypeBits`.
	// - Contains all the flags from `pAllocationCreateInfo->requiredFlags`.
	// - Matches intended usage.
	// - Has as many flags from `pAllocationCreateInfo->preferredFlags` as possible.
	//
	// Returns `.ERROR_FEATURE_NOT_PRESENT` if not found. Receiving such result
	// from this function or any other allocating function probably means that your
	// device doesn't support any memory type with requested features for the specific
	// type of resource you want to use it for. Please check parameters of your
	// resource, like image layout (`OPTIMAL` versus `LINEAR`) or mip level count.
	FindMemoryTypeIndex :: proc(
		allocator: Allocator,
		memoryTypeBits: u32,
		#by_ptr pAllocationCreateInfo: AllocationCreateInfo,
		pMemoryTypeIndex: ^u32) -> vk.Result ---

	// Helps to find `memoryTypeIndex`, given `VkBufferCreateInfo` and
	// `AllocationCreateInfo`.
	//
	// It can be useful e.g. to determine value to be used as
	// `PoolCreateInfo.memoryTypeIndex`. It may need to internally create a
	// temporary, dummy buffer that never has memory bound.
	FindMemoryTypeIndexForBufferInfo :: proc(
		allocator: Allocator,
		#by_ptr pBufferCreateInfo: vk.BufferCreateInfo,
		#by_ptr pAllocationCreateInfo: AllocationCreateInfo,
		pMemoryTypeIndex: ^u32) -> vk.Result ---

	// Helps to find `memoryTypeIndex`, given `VkImageCreateInfo` and
	// `AllocationCreateInfo`.
	//
	// It can be useful e.g. to determine value to be used as
	// `PoolCreateInfo.memoryTypeIndex`. It may need to internally create a
	// temporary, dummy image that never has memory bound.
	FindMemoryTypeIndexForImageInfo :: proc(
		allocator: Allocator,
		#by_ptr pImageCreateInfo: vk.ImageCreateInfo,
		#by_ptr pAllocationCreateInfo: AllocationCreateInfo,
		pMemoryTypeIndex: ^u32) -> vk.Result ---

	// Allocates Vulkan device memory and creates #Pool object.
	//
	// - `allocator` Allocator object.
	// - `pCreateInfo` Parameters of pool to create.
	// - `[out] pPool` Handle to created pool.
	CreatePool :: proc(
		allocator: Allocator,
		#by_ptr pCreateInfo: PoolCreateInfo,
		pPool: ^Pool) -> vk.Result ---

	// Destroys #Pool object and frees Vulkan device memory.
	DestroyPool :: proc(
		allocator: Allocator,
		pool: Pool) ---

	// Retrieves statistics of existing #Pool object.
	//
	// - `allocator` Allocator object.
	// - `Pool` object.
	// - `[out] pPoolStats` Statistics of specified pool.
	//
	// Note that when using the pool from multiple threads, returned information may
	// immediately become outdated.
	GetPoolStatistics :: proc(
		allocator: Allocator,
		pool: Pool,
		pPoolStats: ^Statistics) ---

	// Retrieves detailed statistics of existing #Pool object.
	//
	// - `allocator` Allocator object.
	// - `pool` Pool object.
	// - `[out] pPoolStats` Statistics of specified pool.
	CalculatePoolStatistics :: proc(
		allocator: Allocator,
		pool: Pool,
		pPoolStats: ^DetailedStatistics) ---

	// Checks magic number in margins around all allocations in given memory
	// pool in search for corruptions.
	//
	// Corruption detection is enabled only when `VMA_DEBUG_DETECT_CORRUPTION`
	// macro is defined to nonzero, `VMA_DEBUG_MARGIN` is defined to nonzero and
	// the pool is created in memory type that is `HOST_VISIBLE` and
	// `HOST_COHERENT`.
	//
	// Possible return values:
	//
	// - `vk.Result.ERROR_FEATURE_NOT_PRESENT` - corruption detection is not enabled
	//   for specified pool.
	// - `vk.Result.SUCCESS` - corruption detection has been performed and succeeded.
	// - `vk.Result.ERROR_UNKNOWN` - corruption detection has been performed and found
	//   memory corruptions around one of the allocations. `VMA_ASSERT` is also
	//   fired in that case.
	// - Other value: Error returned by Vulkan, e.g. memory mapping failure.
	CheckPoolCorruption :: proc(
		allocator: Allocator,
		pool: Pool) -> vk.Result ---

	// Retrieves name of a custom pool.
	//
	// After the call `ppName` is either nil or points to an internally-owned
	// nil-terminated string containing name of the pool that was previously set. The
	// pointer becomes invalid when the pool is destroyed or its name is changed using
	// `vma.SetPoolName()`.
	GetPoolName :: proc(
		allocator: Allocator,
		pool: Pool,
		ppName: ^cstring) ---

	// Sets name of a custom pool.
	//
	// `pName` can be either nil or pointer to a nil-terminated string with new name
	// for the pool. Function makes internal copy of the string, so it can be changed
	// or freed immediately after this call.
	SetPoolName :: proc(
		allocator: Allocator,
		pool: Pool,
		pName: cstring) ---

	// General purpose memory allocation.
	//
	// - `allocator` The main allocator object.
	// - `pVkMemoryRequirements` Requirements for the allocated memory.
	// - `pCreateInfo` Allocation creation parameters.
	// - `[out] pAllocation` Handle to allocated memory.
	// - `[out] pAllocationInfo` Optional, can be nil. Information about
	//   allocated memory. It can be also fetched later using
	//   vmaGetAllocationInfo().
	//
	// The function creates a `Allocation` object without creating a buffer or an image
	// together with it.
	//
	// - It is recommended to use `vma.AllocateMemoryForBuffer()`,
	//   `vma.AllocateMemoryForImage()`, `vma.CreateBuffer()`, `vma.CreateImage()`
	//   instead whenever possible.
	// - You can also create a buffer or an image later in an existing allocation using
	//   `vmaCreateAliasingBuffer2()`, `vmaCreateAliasingImage2()`.
	// - You can also create a buffer or an image on your own and bind it to an
	//   existing allocation using `vma.BindBufferMemory2()`, `vma.BindImageMemory2()`.
	//
	// You must free the returned allocation object using `vma.FreeMemory()` or
	// `vma.FreeMemoryPages()`.
	//
	// There is also extended version of this function: `vma.AllocateDedicatedMemory()`
	// that offers additional parameter `pMemoryAllocateNext`.
	AllocateMemory :: proc(
		allocator: Allocator,
		#by_ptr pVkMemoryRequirements: vk.MemoryRequirements,
		#by_ptr pCreateInfo: AllocationCreateInfo,
		pAllocation: ^Allocation,
		pAllocationInfo: ^AllocationInfo) -> vk.Result ---

	// General purpose allocation of a dedicated memory.
	//
	// This function is similar `vma.AllocateMemory()`, but it always allocates
	// dedicated memory - flag `AllocationCreateFlags.DEDICATED_MEMORY` is
	// implied. It offers additional parameter `pMemoryAllocateNext`, which can
	// be used to attach `pNext` chain to the `vk.MemoryAllocateInfo` structure.
	// It can be useful for importing external memory.
	AllocateDedicatedMemory :: proc(
		allocator: Allocator,
		#by_ptr pVkMemoryRequirements: vk.MemoryRequirements,
		#by_ptr pCreateInfo: AllocationCreateInfo,
		pMemoryAllocateNext: rawptr,
		pAllocation: ^Allocation,
		pAllocationInfo: ^AllocationInfo) -> vk.Result ---

	// General purpose memory allocation for multiple allocation objects at once.
	//
	// - `allocator` Allocator object.
	// - `pVkMemoryRequirements` Memory requirements for each allocation.
	// - `pCreateInfo` Creation parameters for each allocation.
	// - `allocationCount` Number of allocations to make.
	// - `[out] pAllocations` Pointer to array that will be filled with handles to
	//   created allocations.
	// - `[out] pAllocationInfo` Optional. Pointer to array that will be filled with
	//   parameters of created allocations.
	//
	// You should free the memory using `vma.FreeMemory()` or `vma.FreeMemoryPages()`.
	//
	// Word "pages" is just a suggestion to use this function to allocate pieces of
	// memory needed for sparse binding. It is just a general purpose allocation
	// function able to make multiple allocations at once. It may be internally
	// optimized to be more efficient than calling `vma.AllocateMemory()`
	// `allocationCount` times.
	//
	// All allocations are made using same parameters. All of them are created out of
	// the same memory pool and type. If any allocation fails, all allocations already
	// made within this function call are also freed, so that when returned result is
	// not `vk.Result.SUCCESS`, `pAllocation` array is always entirely filled with `{}`.
	AllocateMemoryPages :: proc(
		allocator: Allocator,
		#by_ptr pVkMemoryRequirements: vk.MemoryRequirements,
		#by_ptr pCreateInfo: AllocationCreateInfo,
		allocationCount: uint,
		pAllocations: [^]Allocation,
		pAllocationInfo: [^]AllocationInfo) -> vk.Result ---

	// Allocates memory suitable for given `vk.Buffer`.
	//
	// - `allocator`
	// - `buffer`
	// - `pCreateInfo`
	// - `[out] pAllocation` Handle to allocated memory.
	// - `[out] pAllocationInfo` Optional. Information about allocated memory. It can
	//   be later fetched using function `vma.GetAllocationInfo()`.
	//
	// It only creates `Allocation`. To bind the memory to the buffer, use
	// `vma.BindBufferMemory()`.
	//
	// This is a special-purpose function. In most cases you should use
	// `vma.CreateBuffer()`.
	//
	// You must free the allocation using `vma.FreeMemory()` when no longer needed.
	AllocateMemoryForBuffer :: proc(
		allocator: Allocator,
		buffer: vk.Buffer,
		#by_ptr pCreateInfo: AllocationCreateInfo,
		pAllocation: ^Allocation,
		pAllocationInfo: ^AllocationInfo) -> vk.Result ---

	// Allocates memory suitable for given `vk.Image`.
	//
	// - `allocator`
	// - `image`
	// - `pCreateInfo`
	// - `[out] pAllocation` Handle to allocated memory.
	// - `[out] pAllocationInfo` Optional. Information about allocated memory. It can
	//   be later fetched using function `vma.GetAllocationInfo()`.
	//
	// It only creates `Allocation`. To bind the memory to the buffer, use
	// `vma.BindImageMemory()`.
	//
	// This is a special-purpose function. In most cases you should use
	// `vma.CreateImage()`.
	//
	// You must free the allocation using `vma.FreeMemory()` when no longer needed.
	AllocateMemoryForImage :: proc(
		allocator: Allocator,
		image: vk.Image,
		#by_ptr pCreateInfo: AllocationCreateInfo,
		pAllocation: ^Allocation,
		pAllocationInfo: ^AllocationInfo) -> vk.Result ---

	// Frees memory previously allocated using `vma.AllocateMemory()`,
	// `vma.AllocateMemoryForBuffer()`, or `vma.AllocateMemoryForImage()`.
	//
	// Passing `{}` as `allocation` is valid. Such function call is just skipped.
	FreeMemory :: proc(
		allocator: Allocator,
		allocation: Allocation) ---

	// Frees memory and destroys multiple allocations.
	//
	// Word "pages" is just a suggestion to use this function to free pieces of memory
	// used for sparse binding. It is just a general purpose function to free memory
	// and destroy allocations made using e.g. `vma.AllocateMemory()`,
	// `vma.AllocateMemoryPages()` and other functions. It may be internally optimized to
	// be more efficient than calling `vma.FreeMemory()` `allocationCount` times.
	//
	// Allocations in `pAllocations` array can come from any memory pools and types.
	// Passing `{}` as elements of `pAllocations` array is valid. Such entries are just skipped.
	FreeMemoryPages :: proc(
		allocator: Allocator,
		allocationCount: uint,
		pAllocations: [^]Allocation) ---

	// Returns current information about specified allocation.
	//
	// Current parameters of given allocation are returned in `pAllocationInfo`.
	//
	// Although this function doesn't lock any mutex, so it should be quite efficient,
	// you should avoid calling it too often. You can retrieve same AllocationInfo
	// structure while creating your resource, from function `vma.CreateBuffer()`,
	// vmaCreateImage(). You can remember it if you are sure parameters don't change
	// (e.g. due to defragmentation).
	//
	// There is also a new function vmaGetAllocationInfo2() that offers extended
	// information about the allocation, returned using new structure `AllocationInfo2`.
	GetAllocationInfo :: proc(
		allocator: Allocator,
		allocation: Allocation,
		pAllocationInfo: ^AllocationInfo) ---

	// Returns extended information about specified allocation.
	//
	// Current parameters of given allocation are returned in `pAllocationInfo`.
	// Extended parameters in structure `AllocationInfo2` include memory block size
	// and a flag telling whether the allocation has dedicated memory.
	// It can be useful e.g. for interop with OpenGL.
	GetAllocationInfo2 :: proc(
		allocator: Allocator,
		allocation: Allocation,
		pAllocationInfo: ^AllocationInfo2) ---

	// Sets `pUserData` in given allocation to new value.
	//
	// The value of pointer `pUserData` is copied to allocation's `pUserData`.
	// It is opaque, so you can use it however you want - e.g.
	// as a pointer, ordinal number or some handle to you own data.
	SetAllocationUserData :: proc(
		allocator: Allocator,
		allocation: Allocation,
		pUserData: rawptr) ---

	// Sets pName in given allocation to new value.
	//
	// `pName` must be either nil, or pointer to a nil-terminated string. The function
	// makes local copy of the string and sets it as allocation's `pName`. String
	// passed as pName doesn't need to be valid for whole lifetime of the allocation -
	// you can free it after this call. String previously pointed by allocation's
	// `pName` is freed from memory.
	SetAllocationName :: proc(
		allocator: Allocator,
		allocation: Allocation,
		pName: cstring) ---

	// Given an allocation, returns Property Flags of its memory type.
	//
	// This is just a convenience function. Same information can be obtained using
	// `vma.GetAllocationInfo()` + `vma.GetMemoryProperties()`.
	GetAllocationMemoryProperties :: proc(
		allocator: Allocator,
		allocation: Allocation,
		pFlags: ^vk.MemoryPropertyFlags) ---

	// Maps memory represented by given allocation and returns pointer to it.
	//
	// Maps memory represented by given allocation to make it accessible to CPU code.
	// When succeeded, `*ppData` contains pointer to first byte of this memory.
	//
	// **WARNING**
	//
	// If the allocation is part of a bigger `vk.DeviceMemory` block, returned pointer
	// is correctly offsetted to the beginning of region assigned to this particular
	// allocation. Unlike the result of `vk.MapMemory`, it points to the allocation,
	// not to the beginning of the whole block. You should not add
	// `vma.AllocationInfo.offset` to it!
	//
	// Mapping is internally reference-counted and synchronized, so despite raw Vulkan
	// function `vk.MapMemory()` cannot be used to map same block of `vk.DeviceMemory`
	// multiple times simultaneously, it is safe to call this function on allocations
	// assigned to the same memory block. Actual Vulkan memory will be mapped on first
	// mapping and unmapped on last unmapping.
	//
	// If the function succeeded, you must call `vma.UnmapMemory()` to unmap the
	// allocation when mapping is no longer needed or before freeing the allocation, at
	// the latest.
	//
	// It also safe to call this function multiple times on the same allocation. You
	// must call `vma.UnmapMemory()` same number of times as you called
	// `vma.MapMemory()`.
	//
	// It is also safe to call this function on allocation created with
	// `vma.AllocationCreateFlags.MAPPED` flag. Its memory stays mapped all the time.
	// You must still call `vma.UnmapMemory()` same number of times as you called
	// `vma.MapMemory()`. You must not call `vma.UnmapMemory()` additional time to free
	// the "0-th" mapping made automatically due to `vma.AllocationCreateFlags.MAPPED` flag.
	//
	// This function fails when used on allocation made in memory type that is not `HOST_VISIBLE`.
	//
	// This function doesn't automatically flush or invalidate caches. If the
	// allocation is made from a memory types that is not `HOST_COHERENT`, you also
	// need to use `vma.InvalidateAllocation()` / `vma.FlushAllocation()`, as required
	// by Vulkan specification.
	MapMemory :: proc(
		allocator: Allocator,
		allocation: Allocation,
		ppData: ^rawptr) -> vk.Result ---

	// Unmaps memory represented by given allocation, mapped previously using `vma.MapMemory()`.
	//
	// For details, see description of `vma.MapMemory()`.
	//
	// This function doesn't automatically flush or invalidate caches. If the
	// allocation is made from a memory types that is not `HOST_COHERENT`, you also
	// need to use `vma.InvalidateAllocation()` / `vma.FlushAllocation()`, as required
	// by Vulkan specification.
	UnmapMemory :: proc(
		allocator: Allocator,
		allocation: Allocation) ---

	// Flushes memory of given allocation.
	//
	// Calls `vk.FlushMappedMemoryRanges()` for memory associated with given range of
	// given allocation. It needs to be called after writing to a mapped memory for
	// memory types that are not `HOST_COHERENT`. Unmap operation doesn't do that
	// automatically.
	//
	// - `offset` must be relative to the beginning of allocation.
	// - `size` can be `vk.WHOLE_SIZE`. It means all memory from `offset` the the end
	//   of given allocation.
	// - `offset` and `size` don't have to be aligned. They are internally rounded
	//   down/up to multiply of `nonCoherentAtomSize`.
	// - If `size` is 0, this call is ignored.
	// - If memory type that the `allocation` belongs to is not `HOST_VISIBLE` or it is
	//   `HOST_COHERENT`, this call is ignored.
	//
	// Warning! `offset` and `size` are relative to the contents of given `allocation`.
	// If you mean whole allocation, you can pass 0 and `vk.WHOLE_SIZE`, respectively.
	// Do not pass allocation's offset as `offset`!!!
	//
	// This function returns the `vk.Result` from `vk.FlushMappedMemoryRanges` if it is
	// called, otherwise `VK_SUCCESS`.
	FlushAllocation :: proc(
		allocator: Allocator,
		allocation: Allocation,
		offset: vk.DeviceSize,
		size: vk.DeviceSize) -> vk.Result ---

	// Invalidates memory of given allocation.
	//
	// Calls `vk.InvalidateMappedMemoryRanges()` for memory associated with given range
	// of given allocation. It needs to be called before reading from a mapped memory
	// for memory types that are not `HOST_COHERENT`. Map operation doesn't do that
	// automatically.
	//
	// - `offset` must be relative to the beginning of allocation.
	// - `size` can be `vk.WHOLE_SIZE`. It means all memory from `offset` the the end
	//   of given allocation.
	// - `offset` and `size` don't have to be aligned. They are internally rounded
	//   down/up to multiply of `nonCoherentAtomSize`.
	// - If `size` is 0, this call is ignored.
	// - If memory type that the `allocation` belongs to is not `HOST_VISIBLE` or it is
	//   `HOST_COHERENT`, this call is ignored.
	//
	// Warning! `offset` and `size` are relative to the contents of given `allocation`.
	// If you mean whole allocation, you can pass 0 and `vk.WHOLE_SIZE`, respectively.
	// Do not pass allocation's offset as `offset`!!!
	//
	// This function returns the `vk.Result` from `vk.InvalidateMappedMemoryRanges` if
	// it is called, otherwise `vk.Result.SUCCESS`.
	InvalidateAllocation :: proc(
		allocator: Allocator,
		allocation: Allocation,
		offset: vk.DeviceSize,
		size: vk.DeviceSize) -> vk.Result ---

	// Flushes memory of given set of allocations.
	//
	// Calls `vk.FlushMappedMemoryRanges()` for memory associated with given ranges of
	// given allocations. For more information, see documentation of
	// `vma.FlushAllocation()`.
	//
	// - `allocator`
	// - `allocationCount`
	// - `allocations`
	// - `offsets` If not nil, it must point to an array of offsets of regions to
	//   flush, relative to the beginning of respective allocations. Null means all
	//   offsets are zero.
	// - `sizes` If not nil, it must point to an array of sizes of regions to flush in
	//   respective allocations. Null means `vk.WHOLE_SIZE` for all allocations.
	//
	// This function returns the `vk.Result` from `vk.FlushMappedMemoryRanges` if it is
	// called, otherwise `vk.Result.SUCCESS`.
	FlushAllocations :: proc(
		allocator: Allocator,
		allocationCount: u32,
		allocations: [^]Allocation,
		offsets: [^]vk.DeviceSize,
		sizes: [^]vk.DeviceSize) -> vk.Result ---

	// Invalidates memory of given set of allocations.
	//
	// Calls `vk.InvalidateMappedMemoryRanges()` for memory associated with given ranges
	// of given allocations. For more information, see documentation of
	// `vma.InvalidateAllocation()`.
	//
	// - `allocator`
	// - `allocationCount`
	// - `allocations`
	// - `offsets` If not nil, it must point to an array of offsets of regions to
	//   flush, relative to the beginning of respective allocations. Null means all
	//   offsets are zero.
	// - `sizes` If not nil, it must point to an array of sizes of regions to flush in
	//   respective allocations. Null means `vk.WHOLE_SIZE` for all allocations.
	//
	// This function returns the `vk.Result` from `vk.InvalidateMappedMemoryRanges` if
	// it is called, otherwise `vk.Result.SUCCESS`.
	InvalidateAllocations :: proc(
		allocator: Allocator,
		allocationCount: u32,
		allocations: [^]Allocation,
		offsets: [^]vk.DeviceSize,
		sizes: [^]vk.DeviceSize) -> vk.Result ---

	// Maps the allocation temporarily if needed, copies data from specified host
	// pointer to it, and flushes the memory from the host caches if needed.
	//
	// - `allocator`
	// - `pSrcHostPointer` Pointer to the host data that become source of the copy.
	// - `dstAllocation` Handle to the allocation that becomes destination of the copy.
	// - `dstAllocationLocalOffset` Offset within `dstAllocation` where to write copied
	//   data, in bytes.
	// - `size` Number of bytes to copy.
	//
	// This is a convenience function that allows to copy data from a host pointer to
	// an allocation easily. Same behavior can be achieved by calling
	// `vma.MapMemory()`, `copy()`, `vma.UnmapMemory()`, `vma.FlushAllocation()`.
	//
	// This function can be called only for allocations created in a memory type that
	// has `vk.MemoryPropertyFlags.HOST_VISIBLE` flag. It can be ensured e.g. by using
	// `vma.MemoryUsage.AUTO` and
	// `vma.AllocationCreateFlags.HOST_ACCESS_SEQUENTIAL_WRITE` or
	// `vma.AllocationCreateFlags.HOST_ACCESS_RANDOM`. Otherwise, the function will fail
	// and generate a Validation Layers error.
	//
	// `dstAllocationLocalOffset` is relative to the contents of given `dstAllocation`.
	// If you mean whole allocation, you should pass 0. Do not pass allocation's offset
	// within device memory block this parameter!
	CopyMemoryToAllocation :: proc(
		allocator: Allocator,
		pSrcHostPointer: rawptr,
		dstAllocation: Allocation,
		dstAllocationLocalOffset: vk.DeviceSize,
		size: vk.DeviceSize) -> vk.Result ---

	// Invalidates memory in the host caches if needed, maps the allocation temporarily
	// if needed, and copies data from it to a specified host pointer.
	//
	// - `allocator`
	// - `srcAllocation` Handle to the allocation that becomes source of the copy.
	// - `srcAllocationLocalOffset` Offset within `srcAllocation` where to read copied
	//   data, in bytes.
	// - `pDstHostPointer` Pointer to the host memory that become destination of the  copy.
	// - `size` Number of bytes to copy.
	//
	// This is a convenience function that allows to copy data from an allocation to a
	// host pointer easily. Same behavior can be achieved by calling
	// `vma.InvalidateAllocation()`, `vma.MapMemory()`, `copy()`, `vma.UnmapMemory()`.
	//
	// This function should be called only for allocations created in a memory type
	// that has `vk.MemoryPropertyFlags.HOST_VISIBLE` and
	// `vk.MemoryPropertyFlags.HOST_CACHED` flag. It can be ensured e.g. by using
	// `vma.MemoryUsage.AUTO` and `vma.AllocationCreateFlags.HOST_ACCESS_RANDOM`.
	// Otherwise, the function may fail and generate a Validation Layers error. It may
	// also work very slowly when reading from an uncached memory.
	//
	// `srcAllocationLocalOffset` is relative to the contents of given `srcAllocation`.
	// If you mean whole allocation, you should pass 0. Do not pass allocation's offset
	// within device memory block as this parameter!
	CopyAllocationToMemory :: proc(
		allocator: Allocator,
		srcAllocation: Allocation,
		srcAllocationLocalOffset: vk.DeviceSize,
		pDstHostPointer: rawptr,
		size: vk.DeviceSize) -> vk.Result ---

	// Checks magic number in margins around all allocations in given memory types (in
	// both default and custom pools) in search for corruptions.
	//
	// - `allocator`
	// - `memoryTypeBits` Bit mask, where each bit set means that a memory type with
	//   that index should be checked.
	//
	// Corruption detection is enabled only when `VMA_DEBUG_DETECT_CORRUPTION` macro is
	// defined to nonzero, `VMA_DEBUG_MARGIN` is defined to nonzero and only for memory
	// types that are `HOST_VISIBLE` and `HOST_COHERENT`. For more information, see
	// Corruption detection documentation.
	//
	// Possible return values:
	//
	// - `.ERROR_FEATURE_NOT_PRESENT` - corruption detection is not enabled for any
	//   of specified memory types.
	// - `.SUCCESS` - corruption detection has been performed and succeeded.
	// - `.ERROR_UNKNOWN` - corruption detection has been performed and found memory
	//   corruptions around one of the allocations. `VMA_ASSERT` is also fired in that case.
	// - Other value: Error returned by Vulkan, e.g. memory mapping failure.
	CheckCorruption :: proc(
		allocator: Allocator,
		memoryTypeBits: u32) -> vk.Result ---

	// Begins defragmentation process.
	//
	// - `allocator` Allocator object.
	// - `pInfo` Structure filled with parameters of defragmentation.
	// - `[out] pContext` Context object that must be passed to `vma.EndDefragmentation()`
	//   to finish defragmentation.
	//
	// Returns:
	//
	// - `.SUCCESS` if defragmentation can begin.
	// - `.ERROR_FEATURE_NOT_PRESENT` if defragmentation is not supported.
	//
	// For more information about defragmentation, see documentation chapter for
	// Defragmentation.
	BeginDefragmentation :: proc(
		allocator: Allocator,
		#by_ptr pInfo: DefragmentationInfo,
		pContext: ^DefragmentationContext) -> vk.Result ---

	// Ends defragmentation process.
	//
	// - `allocator` Allocator object.
	// - `ctx` Context object that has been created by `vma.BeginDefragmentation()`.
	// - `[out] pStats` Optional stats for the defragmentation. Can be nil.
	//
	// Use this function to finish defragmentation started by `vma.BeginDefragmentation()`.
	EndDefragmentation :: proc(
		allocator: Allocator,
		ctx: DefragmentationContext,
		pStats: ^DefragmentationStats) ---

	// Starts single defragmentation pass.
	//
	// - `allocator` Allocator object.
	// - `ctx` Context object that has been created by
	//   `vma.BeginDefragmentation()`.
	// - `[out]pPassInfo` Computed information for current pass.
	//
	// Returns
	//
	// - `.SUCCESS` if no more moves are possible. Then you can omit call to
	//   `vma.EndDefragmentationPass()` and simply end whole defragmentation.
	// - `.INCOMPLETE` if there are pending moves returned in `pPassInfo`. You need to
	//   perform them, call `vma.EndDefragmentationPass()`, and then preferably try
	//   another pass with `vma.BeginDefragmentationPass()`.
	BeginDefragmentationPass :: proc(
		allocator: Allocator,
		ctx: DefragmentationContext,
		pPassInfo: ^DefragmentationPassMoveInfo) -> vk.Result ---

	// Ends single defragmentation pass.
	//
	// - `allocator` Allocator object.
	// - `ctx` Context object that has been created by vmaBeginDefragmentation().
	// - `pPassInfo` Computed information for current pass filled by
	//   `vma.BeginDefragmentationPass()` and possibly modified by you.
	//
	// Returns `.SUCCESS` if no more moves are possible or `.INCOMPLETE` if more
	// defragmentations are possible.
	//
	// Ends incremental defragmentation pass and commits all defragmentation moves from
	// `pPassInfo`. After this call:
	//
	// - Allocations at `pPassInfo[i].srcAllocation` that had `pPassInfo[i].operation`
	//   == `DefragmentationMoveOperation.COPY` (which is the default) will be pointing
	//   to the new destination place.
	// - Allocation at `pPassInfo[i].srcAllocation` that had `pPassInfo[i].operation`
	//   == `DefragmentationMoveOperation.DESTROY` will be freed.
	//
	// If no more moves are possible you can end whole defragmentation.
	EndDefragmentationPass :: proc(
		allocator: Allocator,
		ctx: DefragmentationContext,
		pPassInfo: ^DefragmentationPassMoveInfo) -> vk.Result ---

	// Binds buffer to allocation.
	//
	// Binds specified buffer to region of memory represented by specified allocation.
	// Gets `vk.DeviceMemory` handle and offset from the allocation. If you want to
	// create a buffer, allocate memory for it and bind them together separately, you
	// should use this function for binding instead of standard `vk.BindBufferMemory()`,
	// because it ensures proper synchronization so that when a `vk.DeviceMemory`
	// object is used by multiple allocations, calls to `vk.Bind*Memory()` or
	// `vk.MapMemory()` won't happen from multiple threads simultaneously (which is
	// illegal in Vulkan).
	//
	// It is recommended to use function `vma.CreateBuffer()` instead of this one.
	BindBufferMemory :: proc(
		allocator: Allocator,
		allocation: Allocation,
		buffer: vk.Buffer) -> vk.Result ---

	// Binds buffer to allocation with additional parameters.
	//
	// - `allocator`
	// - `allocation`
	// - `allocationLocalOffset` Additional offset to be added while binding, relative
	//   to the beginning of the `allocation`. Normally it should be 0.
	// - `buffer`
	// - `pNext` A chain of structures to be attached to `vk.BindBufferMemoryInfoKHR`
	//   structure used internally. Normally it should be nil.
	//
	// This function is similar to `vma.BindBufferMemory()`, but it provides additional
	// parameters.
	//
	// If `pNext` is not nil, `Allocator` object must have been created with
	// `AllocatorCreateFlags.KHR_BIND_MEMORY2` flag or with
	// `AllocatorCreateInfo.vulkanApiVersion` >= `vk.API_VERSION_1_1`. Otherwise the
	// call fails.
	BindBufferMemory2 :: proc(
		allocator: Allocator,
		allocation: Allocation,
		allocationLocalOffset: vk.DeviceSize,
		buffer: vk.Buffer,
		pNext: rawptr) -> vk.Result ---

	// Binds image to allocation.
	//
	// Binds specified image to region of memory represented by specified allocation.
	// Gets `vk.DeviceMemory` handle and offset from the allocation. If you want to
	// create an image, allocate memory for it and bind them together separately, you
	// should use this function for binding instead of standard `vk.BindImageMemory()`,
	// because it ensures proper synchronization so that when a `vk.DeviceMemory`
	// object is used by multiple allocations, calls to `vkBind*Memory()` or
	// `vk.MapMemory()` won't happen from multiple threads simultaneously (which is
	// illegal in Vulkan).
	//
	// It is recommended to use function `vmaC.reateImage()` instead of this one.
	BindImageMemory :: proc(
		allocator: Allocator,
		allocation: Allocation,
		image: vk.Image) -> vk.Result ---

	// Binds image to allocation with additional parameters.
	//
	// - `allocator`
	// - `allocation`
	// - `allocationLocalOffset` Additional offset to be added while binding, relative
	//   to the beginning of the `allocation`. Normally it should be 0.
	// - `image`
	// - `pNext` A chain of structures to be attached to `vk.BindImageMemoryInfoKHR`
	//   structure used internally. Normally it should be nil.
	//
	// This function is similar to `vma.BindImageMemory()`, but it provides additional
	// parameters.
	//
	// If `pNext` is not nil, `Allocator` object must have been created with
	// `AllocatorCreateFlags.KHR_BIND_MEMORY2` flag or with
	// `AllocatorCreateInfo.vulkanApiVersion` >= `vk.API_VERSION_1_1`. Otherwise the
	// call fails.
	BindImageMemory2 :: proc(
		allocator: Allocator,
		allocation: Allocation,
		allocationLocalOffset: vk.DeviceSize,
		image: vk.Image,
		pNext: rawptr) -> vk.Result ---

	// Creates a new `vk.Buffer`, allocates and binds memory for it.
	//
	// - `allocator` The main allocator object.
	// - `pBufferCreateInfo` Buffer creation parameters.
	// - `pAllocationCreateInfo` Allocation creation parameters.
	// - `[out] pBuffer` Buffer that was created.
	// - `[out] pAllocation` Allocation that was created.
	// - `[out] pAllocationInfo` Optional, can be nil. Information about
	//   allocated memory. It can be also fetched later using
	//   `vma.GetAllocationInfo()`.
	//
	// This function automatically:
	//
	// - Creates buffer.
	// - Allocates appropriate memory for it.
	// - Binds the buffer with the memory.
	//
	// If any of these operations fail, buffer and allocation are not created, returned
	// value is negative error code, `*pBuffer` and `*pAllocation` are returned as nil.
	//
	// If the function succeeded, you must destroy both buffer and allocation when you
	// no longer need them using either convenience function `vma.DestroyBuffer()` or
	// separately, using `vk.DestroyBuffer()` and `vma.FreeMemory()`.
	//
	// If `VK_KHR_dedicated_allocation` extenion or Vulkan version >= 1.1 is used, the
	// function queries the driver whether it requires or prefers the new buffer to
	// have dedicated allocation. If yes, and if dedicated allocation is possible
	// (`AllocationCreateFlags.NEVER_ALLOCATE` is not used), it creates dedicated
	// allocation for this buffer, just like when using
	// `AllocationCreateFlags.DEDICATED_MEMORY`.
	//
	// **Note**: This function creates a new `VkBuffer`. Sub-allocation of parts of
	// one large buffer, although recommended as a good practice, is out of
	// scope of this library and could be implemented by the user as a
	// higher-level logic on top of VMA.
	//
	// There is also an extended versions of this function available with
	// additional parameter `pMemoryAllocateNext` - see
	// `vma.CreateDedicatedBuffer()`.
	CreateBuffer :: proc(
		allocator: Allocator,
		#by_ptr pBufferCreateInfo: vk.BufferCreateInfo,
		#by_ptr pAllocationCreateInfo: AllocationCreateInfo,
		pBuffer: ^vk.Buffer,
		pAllocation: ^Allocation,
		pAllocationInfo: ^AllocationInfo) -> vk.Result ---

	// Creates a buffer with additional minimum alignment.
	//
	// Similar to `vma.CreateBuffer()` but provides additional parameter `minAlignment`
	// which allows to specify custom, minimum alignment to be used when placing the
	// buffer inside a larger memory block, which may be needed e.g. for interop with
	// OpenGL.
	//
	// **Deprecated**: This function in obsolete since new
	// `AllocationCreateInfo.minAlignment` member allows specifying custom alignment
	// while using any allocation function, like the standard `vma.CreateBuffer()`.
	@(deprecated="Use AllocationCreateInfo.minAlignment instead")
	CreateBufferWithAlignment :: proc(
		allocator: Allocator,
		#by_ptr pBufferCreateInfo: vk.BufferCreateInfo,
		#by_ptr pAllocationCreateInfo: AllocationCreateInfo,
		minAlignment: vk.DeviceSize,
		pBuffer: ^vk.Buffer,
		pAllocation: ^Allocation,
		pAllocationInfo: ^AllocationInfo) -> vk.Result ---

	// Creates a dedicated buffer while offering extra parameter `pMemoryAllocateNext`.
	//
	// This function is similar `vma.CreateBuffer()`, but it always allocates dedicated
	// memory for the buffer - flag `AllocationCreateFlags.DEDICATED_MEMORY` is
	// implied. It offers additional parameter `pMemoryAllocateNext`, which can be used
	// to attach `pNext` chain to the `vk.MemoryAllocateInfo` structure. It can be
	// useful for importing external memory. For more information, see \ref
	// other_api_interop.
	CreateDedicatedBuffer :: proc(
		allocator: Allocator,
		#by_ptr pBufferCreateInfo: vk.BufferCreateInfo,
		#by_ptr pAllocationCreateInfo: AllocationCreateInfo,
		pMemoryAllocateNext: rawptr,
		pBuffer: ^vk.Buffer,
		pAllocation: ^Allocation,
		pAllocationInfo: ^AllocationInfo) -> vk.Result ---

	// Creates a new `vk.Buffer`, binds already created memory for it.
	//
	// - `allocator`
	// - `allocation` Allocation that provides memory to be used for binding new buffer
	//   to it.
	// - `pBufferCreateInfo`
	// - `[out] pBuffer` Buffer that was created.
	//
	// This function automatically:
	//
	// - Creates buffer.
	// - Binds the buffer with the supplied memory.
	//
	// If any of these operations fail, buffer is not created, returned value is
	// negative error code and `*pBuffer` is nil.
	//
	// If the function succeeded, you must destroy the buffer when you no longer need
	// it using `vk.DestroyBuffer()`. If you want to also destroy the corresponding
	// allocation you can use convenience function `vma.DestroyBuffer()`.
	//
	// **Note**: There is a new version of this function augmented with parameter
	// `allocationLocalOffset` - see `vma.CreateAliasingBuffer2()`.
	CreateAliasingBuffer :: proc(
		allocator: Allocator,
		allocation: Allocation,
		#by_ptr pBufferCreateInfo: vk.BufferCreateInfo,
		pBuffer: ^vk.Buffer) -> vk.Result ---

	// Creates a new `vk.Buffer`, binds already created memory for it.
	//
	// - `allocator`
	// - `allocation` Allocation that provides memory to be used for binding new buffer
	//   to it.
	// - `allocationLocalOffset` Additional offset to be added while binding, relative
	//   to the beginning of the allocation. Normally it should be 0.
	// - `pBufferCreateInfo`
	// - `[out] pBuffer` Buffer that was created.
	//
	// This function automatically:
	//
	// - Creates buffer.
	// - Binds the buffer with the supplied memory.
	//
	// If any of these operations fail, buffer is not created, returned value is
	// negative error code and `^pBuffer` is nil.
	//
	// If the function succeeded, you must destroy the buffer when you no longer need
	// it using `vk.DestroyBuffer()`. If you want to also destroy the corresponding
	// allocation you can use convenience function `vma.DestroyBuffer()`.
	//
	// Note: This is a new version of the function augmented with parameter
	// `allocationLocalOffset`.
	CreateAliasingBuffer2 :: proc(
		allocator: Allocator,
		allocation: Allocation,
		allocationLocalOffset: vk.DeviceSize,
		#by_ptr pBufferCreateInfo: vk.BufferCreateInfo,
		pBuffer: ^vk.Buffer) -> vk.Result ---

	// Destroys Vulkan buffer and frees allocated memory.
	//
	// This is just a convenience function equivalent to:
	//
	//    vk.DestroyBuffer(device, buffer, allocationCallbacks)
	//    vma.FreeMemory(allocator, allocation)
	//
	// It is safe to pass nil as buffer and/or allocation.
	DestroyBuffer :: proc(
		allocator: Allocator,
		buffer: vk.Buffer,
		allocation: Allocation) ---

	// Function similar to `vma.CreateBuffer()` but for images.
	//
	// There is also an extended version of this function available:
	// `vma.CreateDedicatedImage()` which offers additional parameter
	// `pMemoryAllocateNext`.
	CreateImage :: proc(
		allocator: Allocator,
		#by_ptr pImageCreateInfo: vk.ImageCreateInfo,
		#by_ptr pAllocationCreateInfo: AllocationCreateInfo,
		pImage: ^vk.Image,
		pAllocation: ^Allocation,
		pAllocationInfo: ^AllocationInfo) -> vk.Result ---

	// Function similar to `vma.CreateDedicatedBuffer()` but for images.
	//
	// This function is similar vmaCreateImage(), but it always allocates dedicated
	// memory for the image - flag `AllocationCreateFlags.DEDICATED_MEMORY` is
	// implied. It offers additional parameter `pMemoryAllocateNext`, which can be used
	// to attach `pNext` chain to the `VkMemoryAllocateInfo` structure. It can be
	// useful for importing external memory. For more information, see \ref
	// other_api_interop.
	CreateDedicatedImage :: proc(
		allocator: Allocator,
		#by_ptr pImageCreateInfo: vk.ImageCreateInfo,
		#by_ptr pAllocationCreateInfo: AllocationCreateInfo,
		pMemoryAllocateNext: rawptr,
		pImage: ^vk.Image,
		pAllocation: ^Allocation,
		pAllocationInfo: ^AllocationInfo) -> vk.Result ---

	// Function similar to `vma.CreateAliasingBuffer()` but for images.
	CreateAliasingImage :: proc(
		allocator: Allocator,
		allocation: Allocation,
		#by_ptr pImageCreateInfo: vk.ImageCreateInfo,
		pImage: ^vk.Image) -> vk.Result ---

	// Function similar to `vma.CreateAliasingBuffer2()` but for images.
	CreateAliasingImage2 :: proc(
		allocator: Allocator,
		allocation: Allocation,
		allocationLocalOffset: vk.DeviceSize,
		#by_ptr pImageCreateInfo: vk.ImageCreateInfo,
		pImage: ^vk.Image) -> vk.Result ---

	// Destroys Vulkan image and frees allocated memory.
	//
	// This is just a convenience function equivalent to:
	//
	//    vk.DestroyImage(device, image, allocationCallbacks)
	//    vma.FreeMemory(allocator, allocation)
	//
	// It is safe to pass nil as image and/or allocation.
	DestroyImage :: proc(
		allocator: Allocator,
		image: vk.Image,
		allocation: Allocation) ---

	// Creates new `VirtualBlock` object.
	//
	// - `pCreateInfo` Parameters for creation.
	// - `[out] pVirtualBlock` Returned virtual block object or `nil` if creation failed.
	CreateVirtualBlock :: proc(
		#by_ptr pCreateInfo: VirtualBlockCreateInfo,
		pVirtualBlock: ^VirtualBlock) -> vk.Result ---

	// Destroys `VirtualBlock` object.
	//
	// Please note that you should consciously handle virtual allocations that could
	// remain unfreed in the block. You should either free them individually using
	// `vma.VirtualFree()` or call `vma.ClearVirtualBlock()` if you are sure this is what you
	// want. If you do neither, an assert is called.
	//
	// If you keep pointers to some additional metadata associated with your virtual
	// allocations in their `pUserData`, don't forget to free them.
	DestroyVirtualBlock :: proc(
		virtualBlock: VirtualBlock) ---

	// Returns true of the `VirtualBlock` is empty - contains 0 virtual allocations and
	// has all its space available for new allocations.
	IsVirtualBlockEmpty :: proc(
		virtualBlock: VirtualBlock) -> b32 ---

	// Returns information about a specific virtual allocation within a virtual block,
	// like its size and `pUserData` pointer.
	GetVirtualAllocationInfo :: proc(
		virtualBlock: VirtualBlock,
		allocation: VirtualAllocation,
		pVirtualAllocInfo: ^VirtualAllocationInfo) ---

	// Allocates new virtual allocation inside given `VirtualBlock`.
	//
	// If the allocation fails due to not enough free space available,
	// `.ERROR_OUT_OF_DEVICE_MEMORY` is returned (despite the function doesn't ever
	// allocate actual GPU memory). `pAllocation` is then set to `{}` and `pOffset`, if
	// not nil, it set to `max(u64)`.
	//
	// - `virtualBlock` Virtual block
	// - `pCreateInfo` Parameters for the allocation
	// - `[out] pAllocation` Returned handle of the new allocation
	// - `[out] pOffset` Returned offset of the new allocation. Optional, can be nil.
	VirtualAllocate :: proc(
		virtualBlock: VirtualBlock,
		#by_ptr pCreateInfo: VirtualAllocationCreateInfo,
		pAllocation: ^VirtualAllocation,
		pOffset: ^vk.DeviceSize) -> vk.Result ---

	// Frees virtual allocation inside given `VirtualBlock`.
	//
	// It is correct to call this function with `allocation == {}` - it does nothing.
	VirtualFree :: proc(
		virtualBlock: VirtualBlock,
		allocation: VirtualAllocation) ---

	// Frees all virtual allocations inside given `VirtualBlock`.
	//
	// You must either call this function or free each virtual allocation individually
	// with `vma.VirtualFree()` before destroying a virtual block. Otherwise, an assert is
	// called.
	//
	// If you keep pointer to some additional metadata associated with your virtual
	// allocation in its `pUserData`, don't forget to free it as well.
	ClearVirtualBlock :: proc(
		virtualBlock: VirtualBlock) ---

	// Changes custom pointer associated with given virtual allocation.
	SetVirtualAllocationUserData :: proc(
		virtualBlock: VirtualBlock,
		allocation: VirtualAllocation,
		pUserData: rawptr) ---

	// Calculates and returns statistics about virtual allocations and memory usage in
	// given `VirtualBlock`.
	//
	// This function is fast to call. For more detailed statistics, see
	// `vma.CalculateVirtualBlockStatistics()`.
	GetVirtualBlockStatistics :: proc(
		virtualBlock: VirtualBlock,
		pStats: ^Statistics) ---

	// Calculates and returns detailed statistics about virtual allocations and memory
	// usage in given `VirtualBlock`.
	//
	// This function is slow to call. Use for debugging purposes. For less detailed
	// statistics, see `vma.GetVirtualBlockStatistics()`.
	CalculateVirtualBlockStatistics :: proc(
		virtualBlock: VirtualBlock,
		pStats: ^DetailedStatistics) ---

	// Builds and returns a nil-terminated string in JSON format with information about
	// given `VirtualBlock`.
	//
	// - `virtualBlock` Virtual block.
	// - `[out] ppStatsString` Returned string.
	// - `detailedMap` Pass `false` to only obtain statistics as returned by
	//   vmaCalculateVirtualBlockStatistics(). Pass `true` to also obtain full list of
	//   allocations and free spaces.
	//
	// Returned string must be freed using `vma.FreeVirtualBlockStatsString()`.
	BuildVirtualBlockStatsString :: proc(
		virtualBlock: VirtualBlock,
		ppStatsString: ^cstring,
		detailedMap: b32) ---

	// Frees a string returned by `vma.BuildVirtualBlockStatsString()`.
	FreeVirtualBlockStatsString :: proc(
		virtualBlock: VirtualBlock,
		pStatsString: cstring) ---

	// Builds and returns statistics as a nil-terminated string in JSON format.
	//
	// - `allocator`
	// - `[out] ppStatsString` Must be freed using vmaFreeStatsString() function.
	// - `detailedMap`
	BuildStatsString :: proc(
		allocator: Allocator,
		ppStatsString: ^cstring,
		detailedMap: b32) ---

	FreeStatsString :: proc(
		allocator: Allocator,
		pStatsString: cstring) ---
}

// Bind Vulkan procedures to VMA.
create_vulkan_functions :: proc() -> (functions: VulkanFunctions) {
    functions = {
        GetInstanceProcAddr                   = vk.GetInstanceProcAddr,
        GetDeviceProcAddr                     = vk.GetDeviceProcAddr,
        GetPhysicalDeviceProperties           = vk.GetPhysicalDeviceProperties,
        GetPhysicalDeviceMemoryProperties     = vk.GetPhysicalDeviceMemoryProperties,
        AllocateMemory                        = vk.AllocateMemory,
        FreeMemory                            = vk.FreeMemory,
        MapMemory                             = vk.MapMemory,
        UnmapMemory                           = vk.UnmapMemory,
        FlushMappedMemoryRanges               = vk.FlushMappedMemoryRanges,
        InvalidateMappedMemoryRanges          = vk.InvalidateMappedMemoryRanges,
        BindBufferMemory                      = vk.BindBufferMemory,
        BindImageMemory                       = vk.BindImageMemory,
        GetBufferMemoryRequirements           = vk.GetBufferMemoryRequirements,
        GetImageMemoryRequirements            = vk.GetImageMemoryRequirements,
        CreateBuffer                          = vk.CreateBuffer,
        DestroyBuffer                         = vk.DestroyBuffer,
        CreateImage                           = vk.CreateImage,
        DestroyImage                          = vk.DestroyImage,
        CmdCopyBuffer                         = vk.CmdCopyBuffer,
        GetBufferMemoryRequirements2KHR       = vk.GetBufferMemoryRequirements2KHR,
        GetImageMemoryRequirements2KHR        = vk.GetImageMemoryRequirements2KHR,
        BindBufferMemory2KHR                  = vk.BindBufferMemory2KHR,
        BindImageMemory2KHR                   = vk.BindImageMemory2KHR,
        GetPhysicalDeviceMemoryProperties2KHR = vk.GetPhysicalDeviceMemoryProperties2KHR,
        GetDeviceBufferMemoryRequirements     = vk.GetDeviceBufferMemoryRequirementsKHR,
        GetDeviceImageMemoryRequirements      = vk.GetDeviceImageMemoryRequirementsKHR,
        GetMemoryWin32HandleKHR               = vk.GetMemoryWin32HandleKHR,
        GetPhysicalDeviceProperties2KHR       = vk.GetPhysicalDeviceProperties2KHR,
    }

    // Promoted-to-core fallbacks when the KHR alias isn't exported.
    if functions.GetBufferMemoryRequirements2KHR == nil {
        functions.GetBufferMemoryRequirements2KHR = vk.GetBufferMemoryRequirements2
    }
    if functions.GetImageMemoryRequirements2KHR == nil {
        functions.GetImageMemoryRequirements2KHR = vk.GetImageMemoryRequirements2
    }
    if functions.BindBufferMemory2KHR == nil {
        functions.BindBufferMemory2KHR = vk.BindBufferMemory2
    }
    if functions.BindImageMemory2KHR == nil {
        functions.BindImageMemory2KHR = vk.BindImageMemory2
    }
    if functions.GetPhysicalDeviceMemoryProperties2KHR == nil {
        functions.GetPhysicalDeviceMemoryProperties2KHR = vk.GetPhysicalDeviceMemoryProperties2
    }
    if functions.GetDeviceBufferMemoryRequirements == nil {
        functions.GetDeviceBufferMemoryRequirements = vk.GetDeviceBufferMemoryRequirements
    }
    if functions.GetDeviceImageMemoryRequirements == nil {
        functions.GetDeviceImageMemoryRequirements = vk.GetDeviceImageMemoryRequirements
    }

    return
}

CreateVulkanFunctions :: create_vulkan_functions

// Bind Vulkan procedures to VMA.
create_device_vulkan_functions :: proc(fp: vk.Device_VTable) -> (functions: VulkanFunctions) {
    functions = {
        // Global
        GetInstanceProcAddr                   = vk.GetInstanceProcAddr,
        GetDeviceProcAddr                     = vk.GetDeviceProcAddr,
        GetPhysicalDeviceProperties           = vk.GetPhysicalDeviceProperties,
        GetPhysicalDeviceMemoryProperties     = vk.GetPhysicalDeviceMemoryProperties,
        GetPhysicalDeviceMemoryProperties2KHR = vk.GetPhysicalDeviceMemoryProperties2KHR,
        GetPhysicalDeviceProperties2KHR       = vk.GetPhysicalDeviceProperties2KHR,

        AllocateMemory                        = fp.AllocateMemory,
        FreeMemory                            = fp.FreeMemory,
        MapMemory                             = fp.MapMemory,
        UnmapMemory                           = fp.UnmapMemory,
        FlushMappedMemoryRanges               = fp.FlushMappedMemoryRanges,
        InvalidateMappedMemoryRanges          = fp.InvalidateMappedMemoryRanges,
        BindBufferMemory                      = fp.BindBufferMemory,
        BindImageMemory                       = fp.BindImageMemory,
        GetBufferMemoryRequirements           = fp.GetBufferMemoryRequirements,
        GetImageMemoryRequirements            = fp.GetImageMemoryRequirements,
        CreateBuffer                          = fp.CreateBuffer,
        DestroyBuffer                         = fp.DestroyBuffer,
        CreateImage                           = fp.CreateImage,
        DestroyImage                          = fp.DestroyImage,
        CmdCopyBuffer                         = fp.CmdCopyBuffer,
        GetBufferMemoryRequirements2KHR       = fp.GetBufferMemoryRequirements2KHR,
        GetImageMemoryRequirements2KHR        = fp.GetImageMemoryRequirements2KHR,
        BindBufferMemory2KHR                  = fp.BindBufferMemory2KHR,
        BindImageMemory2KHR                   = fp.BindImageMemory2KHR,
        GetDeviceBufferMemoryRequirements     = fp.GetDeviceBufferMemoryRequirementsKHR,
        GetDeviceImageMemoryRequirements      = fp.GetDeviceImageMemoryRequirementsKHR,
        GetMemoryWin32HandleKHR               = fp.GetMemoryWin32HandleKHR,
    }

    // Promoted-to-core fallbacks when the KHR alias isn't exported.
    if functions.GetPhysicalDeviceMemoryProperties2KHR == nil {
        functions.GetPhysicalDeviceMemoryProperties2KHR = vk.GetPhysicalDeviceMemoryProperties2
    }
    if functions.GetPhysicalDeviceProperties2KHR == nil {
        functions.GetPhysicalDeviceProperties2KHR = vk.GetPhysicalDeviceProperties2
    }
    if functions.GetBufferMemoryRequirements2KHR == nil {
        functions.GetBufferMemoryRequirements2KHR = fp.GetBufferMemoryRequirements2
    }
    if functions.GetImageMemoryRequirements2KHR == nil {
        functions.GetImageMemoryRequirements2KHR = fp.GetImageMemoryRequirements2
    }
    if functions.BindBufferMemory2KHR == nil {
        functions.BindBufferMemory2KHR = fp.BindBufferMemory2
    }
    if functions.BindImageMemory2KHR == nil {
        functions.BindImageMemory2KHR = fp.BindImageMemory2
    }
    if functions.GetDeviceBufferMemoryRequirements == nil {
        functions.GetDeviceBufferMemoryRequirements = fp.GetDeviceBufferMemoryRequirements
    }
    if functions.GetDeviceImageMemoryRequirements == nil {
        functions.GetDeviceImageMemoryRequirements = fp.GetDeviceImageMemoryRequirements
    }

    return
}

CreateDeviceVulkanFunctions :: create_device_vulkan_functions
