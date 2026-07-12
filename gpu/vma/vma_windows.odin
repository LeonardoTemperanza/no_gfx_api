#+build windows
package vma

// Core
import win32 "core:sys/windows"

// Vendor
import vk "vendor:vulkan"

@(link_prefix="vma")
@(default_calling_convention="c")
foreign vmalib {
	// Given an allocation, returns Win32 handle that may be imported by other
	// processes or APIs.
	//
	// - `allocator` The main allocator object.
	// - `allocation` Allocation.
	// - `hTargetProcess` A valid handle to target process or null. If it's null, the
	//   function returns handle for the current process.
	// - `[out] pHandle` Output parameter that returns the handle.
	//
	// The function fills `pHandle` with handle that can be used in target process. The
	// handle is fetched using function `vk.GetMemoryWin32HandleKHR`.
	//
	// Each call to this function creates a new handle that must be closed using:
	//
	//     win32.CloseHandle(handle)
	//
	// You can close it any time, before or after destroying the allocation object. It
	// is reference-counted internally by Windows.
	//
	// Note the handle is returned for the entire `VkDeviceMemory` block that the
	// allocation belongs to. If the allocation is sub-allocated from a larger block,
	// you may need to consider the offset of the allocation (`AllocationInfo.offset`).
	//
	// This function always uses `vk.ExternalMemoryHandleTypeFlags.OPAQUE_WIN32`. An
	// extended version of this function is available as `vma.GetMemoryWin32Handle2()`
	// that allows using other handle type.
	//
	// This function is available compile-time only when `VK_KHR_external_memory_win32`
	// extension is available. It can be manually disabled by predefining
	// `VMA_EXTERNAL_MEMORY_WIN32=0` macro.
	//
	// If the function fails with `VK_ERROR_FEATURE_NOT_PRESENT` error code, please
	// double-check that ``VulkanFunctions.GetMemoryWin32HandleKHR` function pointer
	// is set, e.g. either by using macro `VMA_DYNAMIC_VULKAN_FUNCTIONS` or by manually
	// passing it through `AllocatorCreateInfo.pVulkanFunctions`.
    GetMemoryWin32Handle :: proc(allocator: Allocator,
        allocation: Allocation,
        hTargetProcess: win32.HANDLE,
        pHandle: win32.HANDLE) -> vk.Result ---

	// Given an allocation, returns Win32 handle that may be imported by
	// other processes or APIs.
	//
	// - `allocator` The main allocator object.
	// - `allocation` Allocation.
	// - `handleType` Type of handle to be exported. It should be one of:
	//     - `vk.ExternalMemoryHandleTypeFlags.OPAQUE_WIN32_KHR`
	//     - `vk.ExternalMemoryHandleTypeFlags.OPAQUE_WIN32_KMT_KHR`
	//     - `vk.ExternalMemoryHandleTypeFlags.D3D11_TEXTURE_KHR`
	//     - `vk.ExternalMemoryHandleTypeFlags.D3D11_TEXTURE_KMT_KHR`
	//     - `vk.ExternalMemoryHandleTypeFlags.D3D12_HEAP_KHR`
	//     - `vk.ExternalMemoryHandleTypeFlags.D3D12_RESOURCE_KHR`
	// - `hTargetProcess` A valid handle to target process or null. If it's
	//   null, the function returns handle for the current process.
	// - `[out] pHandle` Output parameter that returns the handle.
	//
	// The function fills `pHandle` with handle that can be used in target process. The
	// handle is fetched using function `vk.GetMemoryWin32HandleKHR`.
	//
	// If `handleType == vk.ExternalMemoryHandleTypeFlags.OPAQUE_WIN32`, or other NT
	// handle types, each call to this function creates a new handle that must be
	// closed using:
	//
	//     win32.CloseHandle(handle)
	//
	// You can close it any time, before or after destroying the allocation object. It
	// is reference-counted internally by Windows.
	//
	// Note the handle is returned for the entire `VkDeviceMemory` block that the
	// allocation belongs to. If the allocation is sub-allocated from a larger block,
	// you may need to consider the offset of the allocation (`AllocationInfo.offset`).
	//
	// This function is available compile-time only when `VK_KHR_external_memory_win32`
	// extension is available. It can be manually disabled by predefining
	// `VMA_EXTERNAL_MEMORY_WIN32=0` macro.
	//
	// If the function fails with `.ERROR_FEATURE_NOT_PRESENT` error code, please
	// double-check that `VulkanFunctions.GetMemoryWin32HandleKHR` function pointer is
	// set, e.g. either by using macro `VMA_DYNAMIC_VULKAN_FUNCTIONS` or by manually
	// passing it through `AllocatorCreateInfo.pVulkanFunctions`.
	GetMemoryWin32Handle2 :: proc(
	    allocator: Allocator,
	    allocation: Allocation,
	    handleType: vk.ExternalMemoryHandleTypeFlags,
	    hTargetProcess: win32.HANDLE,
	    pHandle: ^win32.HANDLE) -> vk.Result ---
}
