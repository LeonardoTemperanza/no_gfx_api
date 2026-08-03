
#+private
package gpu

import vmem "core:mem/virtual"
import "core:mem"
import "core:sync"
import "core:log"
import "base:runtime"
import intr "base:intrinsics"

// Implementation of a thread-safe resource pool to be used for no_gfx_api handles
Resource_Pool :: struct($Handle_T: typeid, $Info_T: typeid) where size_of(Handle_T) == 8
{
    arena: vmem.Arena,  // Makes pointers to elements stable.
    resources: [dynamic]Resource(Info_T),  // Uses 'arena'. Allocation is never moved so no need to lock on read.
    freelist: [dynamic]u32,
    lock: sync.Atomic_Mutex,
    init: bool,
}

Resource :: struct($T: typeid)
{
    info: T,
    gen: u32,
    lock: sync.Benaphore,
    alive: bool,
    meta: Resource_Metadata,
}

Resource_Metadata :: struct
{
    name: string,
    created_at: runtime.Source_Code_Location,
}

Resource_Key :: struct
{
    idx: u32,
    gen: u32,
}

pool_init :: proc(pool: ^Resource_Pool($Handle_T, $Info_T))
{
    pool.init = true

    err := vmem.arena_init_static(&pool.arena, mem.Gigabyte)
    ensure(err == nil)
    pool.resources = make([dynamic]Resource(Info_T), allocator = vmem.arena_allocator(&pool.arena))

    // Reserve element 0 for the nil handle.
    pool_add(pool, Info_T {}, {})
}

pool_check :: proc(pool: ^Resource_Pool($Handle_T, $Info_T), handle: Handle_T, name: string, loc: runtime.Source_Code_Location) -> bool
{
    assert(pool.init)

    if handle == {} {
        log.errorf("'%v' handle is nil.", name, location = loc)
        return false
    }

    key := transmute(Resource_Key) handle

    el := intr.volatile_load(&pool.resources[key.idx])
    if key.gen != el.gen {
        log.error("'%v' handle is used after it has been freed, or it's corrupted in some other way.", name, location = loc)
        return false
    }

    return true
}

pool_check_no_message :: proc(pool: ^Resource_Pool($Handle_T, $Info_T), handle: Handle_T) -> bool
{
    assert(pool.init)

    if handle == nil {
        return false
    }

    key := transmute(Resource_Key) handle
    el := intr.volatile_load(&pool.resources[key.idx])
    if key.gen != el.gen {
        return false
    }

    return true
}

pool_get_alive_list :: proc(pool: ^Resource_Pool($Handle_T, $Info_T), arena: runtime.Allocator) -> []Resource(Info_T)
{
    res := make([dynamic]Resource(Info_T), allocator = arena)
    for i in 1..<len(pool.resources)
    {
        el := intr.volatile_load(&pool.resources[i])
        if el.alive do append(&res, el)
    }

    return res[:]
}

pool_get :: proc(pool: ^Resource_Pool($Handle_T, $Info_T), handle: Handle_T) -> Info_T
{
    assert(pool.init)
    assert(handle != {})
    key := transmute(Resource_Key) handle

    el := intr.volatile_load(&pool.resources[key.idx])
    assert(key.gen == el.gen)
    return el.info
}

pool_get_lock :: proc(pool: ^Resource_Pool($Handle_T, $Info_T), handle: Handle_T) -> ^sync.Benaphore
{
    assert(pool.init)
    assert(handle != {})

    key := transmute(Resource_Key) handle
    el := &pool.resources[key.idx]
    el_gen := intr.volatile_load(&el.gen)
    assert(key.gen == el_gen)
    return &pool.resources[key.idx].lock
}

// NOTE: Synchronization must be done by the user! Call sync.guard(pool_get_lock(...))
// before this or synchronize by other means if needed.
pool_get_ptr :: proc(pool: ^Resource_Pool($Handle_T, $Info_T), handle: Handle_T) -> ^Info_T
{
    assert(pool.init)
    assert(handle != {})
    key := transmute(Resource_Key) handle

    el := intr.volatile_load(&pool.resources[key.idx])
    assert(key.gen == el.gen)
    return &pool.resources[key.idx].info
}

pool_add :: proc(pool: ^Resource_Pool($Handle_T, $Info_T), info: Info_T, meta: Resource_Metadata) -> Handle_T
{
    assert(pool.init)
    sync.guard(&pool.lock)

    free_idx: u32
    if len(pool.freelist) > 0 {
        free_idx = pop(&pool.freelist)
    } else {
        append(&pool.resources, Resource(Info_T) {})
        free_idx = u32(len(pool.resources)) - 1
    }

    sync.guard(&pool.resources[free_idx].lock)
    pool.resources[free_idx].info = info
    gen := pool.resources[free_idx].gen
    pool.resources[free_idx].alive = true
    pool.resources[free_idx].meta = meta

    key := Resource_Key { idx = free_idx, gen = gen }
    return transmute(Handle_T) key
}

pool_remove :: proc(pool: ^Resource_Pool($Handle_T, $Info_T), handle: Handle_T)
{
    assert(pool.init)
    assert(handle != {})
    sync.guard(&pool.lock)

    key := transmute(Resource_Key) handle

    el := &pool.resources[key.idx]
    el.alive = false
    assert(key.gen == el.gen)

    el.gen += 1
    append(&pool.freelist, key.idx)
}

pool_destroy :: proc(pool: ^Resource_Pool($Handle_T, $Info_T))
{
    assert(pool.init)
    sync.guard(&pool.lock)

    delete(pool.resources)
    delete(pool.freelist)
    vmem.arena_destroy(&pool.arena)

    pool.resources = {}
    pool.freelist = nil
    pool.init = false
}

// Scratch arena implementation
@(deferred_out = release_scratch)
acquire_scratch :: proc(used_allocators: ..mem.Allocator) -> (mem.Allocator, vmem.Arena_Temp)
{
    @(thread_local) scratch_arenas: [4]vmem.Arena = {}
    @(thread_local) initialized: bool = false
    if !initialized
    {
        for &scratch in scratch_arenas
        {
            error := vmem.arena_init_growing(&scratch)
            assert(error == nil)
        }

        initialized = true
    }

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
            }

            if available_arena != nil do break
        }
    }

    assert(available_arena != nil, "Available scratch arena not found.")

    return vmem.arena_allocator(available_arena), vmem.arena_temp_begin(available_arena)
}

release_scratch :: #force_inline proc(allocator: mem.Allocator, temp: vmem.Arena_Temp)
{
    vmem.arena_temp_end(temp)
}

// Utilities

is_block_compressed :: #force_inline proc(format: Texture_Format) -> bool
{
    #partial switch format
    {
        case .BC1_RGBA_Unorm,
             .BC3_RGBA_Unorm,
             .BC7_RGBA_Unorm,
             .ASTC_4x4_RGBA_Unorm,
             .ETC2_RGB8_Unorm,
             .ETC2_RGBA8_Unorm,
             .EAC_R11_Unorm,
             .EAC_RG11_Unorm:
            return true
    }
    return false
}

get_mip_dimensions_u32 :: proc(texture_dimensions: [3]u32, mip_level: u32) -> [3]u32
{
    return {
        max(1, u32(f32(texture_dimensions.x) / f32(u32(1) << mip_level))),
        max(1, u32(f32(texture_dimensions.y) / f32(u32(1) << mip_level))),
        max(1, u32(f32(texture_dimensions.z) / f32(u32(1) << mip_level))),
    }
}

get_mip_dimensions_i32 :: proc(texture_dimensions: [3]i32, mip_level: u32) -> [3]i32
{
    return {
        max(1, i32(f32(texture_dimensions.x) / f32(i32(1) << mip_level))),
        max(1, i32(f32(texture_dimensions.y) / f32(i32(1) << mip_level))),
        max(1, i32(f32(texture_dimensions.z) / f32(i32(1) << mip_level))),
    }
}

get_mip_dimensions :: proc { get_mip_dimensions_u32, get_mip_dimensions_i32 }

align_up :: proc(x, align: u64) -> (aligned: u64)
{
    assert(0 == (align & (align - 1)), "must align to a power of two")
    return (x + (align - 1)) &~ (align - 1)
}

// Misc

fatal_error :: proc(fmt: string, args: ..any, location := #caller_location)
{
    log.fatalf(fmt, ..args, location = location)
    runtime.panic("")
}

// Struct cleanup

texture_desc_cleanup :: #force_inline proc(desc: Texture_Desc) -> Texture_Desc
{
    res := desc
    if res.type == .Default do res.type = .D2
    if res.format == .Default do res.format = .RGBA8_Unorm
    res.mip_count = max(1, res.mip_count)
    res.layer_count = max(1, res.layer_count)
    res.sample_count = max(1, res.sample_count)
    return res
}

texture_view_desc_cleanup :: #force_inline proc(texture: Texture, desc: Texture_View_Desc) -> Texture_View_Desc
{
    res := desc
    if res.format == .Default {
        res.format = texture.format
    }
    if res.type == .Default {
        res.type = texture.type
    }
    res.mip_count = max(1, res.mip_count)
    res.layer_count = max(1, res.layer_count)
    return res
}
