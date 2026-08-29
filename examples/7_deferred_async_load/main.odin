// This example demonstrates:
// - Using multiple render targets to render the G-buffer and passing them to the final pass shader as textures
// - Using multiple render passes
// - glTF texture loading and using textures for rendering
// - Asynchronous texture loading by rendering a default texture and swapping it out for the actual textures once loaded
// - Multithreaded texture loading

package main

import "../../gpu"
import intr "base:intrinsics"
import "base:runtime"
import "core:container/queue"
import "core:fmt"
import "core:image"
import "core:image/jpeg"
import "core:image/png"
import log "core:log"
import "core:math"
import "core:math/linalg"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:sys/info"

import sdl "vendor:sdl3"

import shared "../shared"
import gltf2 "../shared/gltf2"

Start_Window_Size_X :: 1000
Start_Window_Size_Y :: 1000
Frames_In_Flight :: 3
Example_Name_Format :: "Right-click + WASD for first-person controls. Left click to toggle texture type. Current: %v"

Sponza_Scene :: #load("../shared/assets/sponza.glb")

// Whether to load textures in parallel in the background or preload them in main thread before running the screne
Load_Textures_Async :: true

// How many textures to load in a single batch / command buffer
Loader_Chunk_Size :: 16

// Use CPU block-compressed mip generation instead of GPU mipmaps.
Compress_Textures :: false

// G-buffer texture indices in texture heap
GBUFFER_ALBEDO_IDX: u32
GBUFFER_NORMAL_IDX: u32
GBUFFER_METALLIC_ROUGHNESS_IDX: u32

// G-buffer texture type for toggling display
GBuffer_Texture_Type :: enum u32 {
	Albedo             = 0,
	Normal             = 1,
	Metallic_Roughness = 2,
}

// Currently selected gbuffer texture type to display
selected_texture_type: GBuffer_Texture_Type = .Albedo

// Textures can be loaded/unloaded on different threads, so we need to synchronize access to loaded_textures, image_to_texture and image_uploaded
mutex: sync.Mutex
// Every texture from loaded_textures array needs to be freed when we are done
loaded_textures: [dynamic]gpu.Owned_Texture
// Enables asynchronous cancellation of texture loading
cancel_loading_textures: bool
// Cache for image_index -> texture mapping, reused across texture loading chunks
image_to_texture: map[int]struct {
	texture:     gpu.Owned_Texture,
	texture_idx: u32,
}
image_uploaded: map[int]^sync.One_Shot_Event

upload_sem: gpu.Semaphore
upload_sem_val: u64

main :: proc() {
    shared.CAM_POS = {-7.581631, 1.1906259, 0.25928685}
	shared.CAM_ANGLE = {1.570796, 0.3665192}

	shared.sdl_init(moltenvk_working_status = .Does_Not_Work)

	console_logger := log.create_console_logger()
	defer log.destroy_console_logger(console_logger)
	context.logger = console_logger

	ts_freq := sdl.GetPerformanceFrequency()
	max_delta_time: f32 = 1.0 / 10.0 // 10fps

	window_flags :: sdl.WindowFlags{.HIGH_PIXEL_DENSITY, .VULKAN, .RESIZABLE}
	window_title := strings.clone_to_cstring(
		fmt.tprintf(Example_Name_Format, selected_texture_type),
	)
	defer delete(window_title)
	window := sdl.CreateWindow(
		window_title,
		Start_Window_Size_X,
		Start_Window_Size_Y,
		window_flags,
	)
	ensure(window != nil)

	display_scale: f32 = sdl.GetWindowDisplayScale(window)

	window_size_x := i32(Start_Window_Size_X * display_scale)
	window_size_y := i32(Start_Window_Size_Y * display_scale)

	ok := gpu.init()
	ensure(ok)
	defer gpu.cleanup()

	gpu.swapchain_create_from_sdl(window, Frames_In_Flight)

	vert_shader_gbuffer := gpu.shader_create(#load("shaders/gbuffer.vert.spv", []u32), .Vertex)
	frag_shader_gbuffer := gpu.shader_create(#load("shaders/gbuffer.frag.spv", []u32), .Fragment)
	defer {
		gpu.shader_destroy(vert_shader_gbuffer)
		gpu.shader_destroy(frag_shader_gbuffer)
	}

	vert_shader_final := gpu.shader_create(#load("shaders/final_pass.vert.spv", []u32), .Vertex)
	frag_shader_final := gpu.shader_create(#load("shaders/final_pass.frag.spv", []u32), .Fragment)
	defer {
		gpu.shader_destroy(vert_shader_final)
		gpu.shader_destroy(frag_shader_final)
	}

	upload_arena := gpu.arena_create()
	defer gpu.arena_destroy(&upload_arena)

	upload_sem = gpu.semaphore_create()
	defer gpu.semaphore_destroy(upload_sem)

	upload_cmd_buf := gpu.commands_begin(.Main)

	full_screen_quad_verts, full_screen_quad_indices := create_fullscreen_quad(
		&upload_arena,
		upload_cmd_buf,
	)
	defer {
		gpu.mem_free(full_screen_quad_verts)
		gpu.mem_free(full_screen_quad_indices)
	}

	desc_pool := gpu.desc_pool_create()
	defer gpu.desc_pool_destroy(&desc_pool)

	magenta_texture := create_magenta_texture(&upload_arena, upload_cmd_buf)
	defer gpu.texture_free_and_destroy(&magenta_texture)
	magenta_texture_id := gpu.desc_pool_alloc_texture(&desc_pool, gpu.texture_view_descriptor(magenta_texture, {}))

	scene, texture_infos, gltf_data := shared.load_scene_gltf(Sponza_Scene, magenta_texture_id)
	defer {
		shared.destroy_scene(&scene)
		gltf2.unload(gltf_data)
	}

	// Upload meshes
	meshes_gpu: [dynamic]Mesh_GPU
	defer {
		for &mesh_gpu in meshes_gpu do mesh_destroy(&mesh_gpu)
		delete(meshes_gpu)
	}

	for mesh in scene.meshes {
		append(&meshes_gpu, upload_mesh(&upload_arena, upload_cmd_buf, mesh))
	}

	defer {
		// Clean up loaded textures
		sync.guard(&mutex)
		for &tex in loaded_textures {
			gpu.texture_free_and_destroy(&tex)
		}
	}

	when Load_Textures_Async {
		worker_threads: [dynamic]^thread.Thread
		defer {
			cancel_loading_textures = true
			for t in worker_threads {
				thread.terminate(t, 0)
			}
		}

		Texture_Loader_Data :: struct {
			texture_infos: []shared.Gltf_Texture_Info,
			gltf_data:     ^gltf2.Data,
			scene:         ^shared.Scene,
			desc_pool:     ^gpu.Descriptor_Pool,
			logger:        log.Logger,
			current_chunk: ^int,
		}
		loader_data := Texture_Loader_Data {
			texture_infos = texture_infos,
			gltf_data     = gltf_data,
			scene         = &scene,
			desc_pool     = &desc_pool,
			logger        = console_logger,
			current_chunk = new(int),
		}

		texture_loader_thread_proc :: proc(thread: ^thread.Thread) {
			data := cast(^Texture_Loader_Data)thread.data
			context.logger = data.logger

			for !cancel_loading_textures {
				current_chunk_start := sync.atomic_add(data.current_chunk, Loader_Chunk_Size)
				current_chunk_end := min(current_chunk_start + Loader_Chunk_Size, len(data.texture_infos))

				if current_chunk_start >= len(data.texture_infos) {
					break
				}

				log.debugf("Creating texture loader for chunk %v of %v", current_chunk_start, len(data.texture_infos))

				load_scene_textures_from_gltf(
					data.texture_infos[current_chunk_start:current_chunk_end],
					data.gltf_data,
					data.scene,
					data.desc_pool,
				)
			}
		}

		_, num_async_worker_threads, ok_cpu := info.cpu_core_count()
		ensure(ok_cpu)
		for i := 0; i < num_async_worker_threads; i += 1 {
			texture_loader_thread := thread.create(texture_loader_thread_proc)
			texture_loader_thread.data = &loader_data
			thread.start(texture_loader_thread)
			append(&worker_threads, texture_loader_thread)
		}
	} else {
		for i := 0; i < len(texture_infos); i += Loader_Chunk_Size {
			end := min(i + Loader_Chunk_Size, len(texture_infos))
			chunk := texture_infos[i:end]
			load_scene_textures_from_gltf(chunk, gltf_data, &scene, &desc_pool)
		}
	}

	sampler_id := gpu.desc_pool_alloc_sampler(
		&desc_pool,
		gpu.sampler_descriptor({ max_anisotropy = min(16.0, gpu.device_limits().max_anisotropy) })
	)

	gbuffer_albedo, gbuffer_normal, gbuffer_metallic_roughness, depth_texture :=
		create_gbuffer_textures(
			u32(window_size_x),
			u32(window_size_y),
			&desc_pool,
		)
	defer {
		gpu.texture_free_and_destroy(&gbuffer_albedo)
		gpu.texture_free_and_destroy(&gbuffer_normal)
		gpu.texture_free_and_destroy(&gbuffer_metallic_roughness)
		gpu.texture_free_and_destroy(&depth_texture)
	}

	gpu.cmd_barrier(upload_cmd_buf, .Transfer, .All, {})
	gpu.queue_submit(.Main, {upload_cmd_buf})

	now_ts := sdl.GetPerformanceCounter()

	frame_arenas: [Frames_In_Flight]gpu.Arena
	for &frame_arena in frame_arenas do frame_arena = gpu.arena_create()
	defer for &frame_arena in frame_arenas do gpu.arena_destroy(&frame_arena)
	next_frame := u64(1)
	frame_sem := gpu.semaphore_create(0)
	defer gpu.semaphore_destroy(frame_sem)
	for true {
		proceed := shared.handle_window_events(window)
		if !proceed do break

		// Toggle gbuffer texture type on left mouse button click
		if shared.INPUT.left_click_pressed {
			selected_texture_type = GBuffer_Texture_Type((u32(selected_texture_type) + 1) % 3)
			title := strings.clone_to_cstring(
				fmt.tprintf(Example_Name_Format, selected_texture_type),
			)
			sdl.SetWindowTitle(window, title)
			delete(title)
		}

		old_window_size_x := window_size_x
		old_window_size_y := window_size_y
		sdl.GetWindowSizeInPixels(window, &window_size_x, &window_size_y)
		if .MINIMIZED in sdl.GetWindowFlags(window) || window_size_x <= 0 || window_size_y <= 0 {
			sdl.Delay(16)
			continue
		}

		if next_frame > Frames_In_Flight {
			gpu.semaphore_wait(frame_sem, next_frame - Frames_In_Flight)
		}
		if old_window_size_x != window_size_x || old_window_size_y != window_size_y {
			gpu.queue_wait_idle(.Main)
            gpu.swapchain_resize({ u32(window_size_x), u32(window_size_y) })

			gpu.texture_free_and_destroy(&gbuffer_albedo)
			gpu.texture_free_and_destroy(&gbuffer_normal)
			gpu.texture_free_and_destroy(&gbuffer_metallic_roughness)
			gpu.texture_free_and_destroy(&depth_texture)
			gbuffer_albedo, gbuffer_normal, gbuffer_metallic_roughness, depth_texture =
				create_gbuffer_textures(
					u32(window_size_x),
					u32(window_size_y),
					&desc_pool
				)
		}

		swapchain := gpu.swapchain_acquire_next() // Blocks CPU until at least one frame is available.
		if swapchain == {} {
            gpu.swapchain_resize({ u32(window_size_x), u32(window_size_y) })
            continue
		}

		last_ts := now_ts
		now_ts = sdl.GetPerformanceCounter()
		delta_time := min(
			max_delta_time,
			f32(f64((now_ts - last_ts) * 1000) / f64(ts_freq)) / 1000.0,
		)

		world_to_view := shared.first_person_camera_view(delta_time)
		aspect_ratio := f32(window_size_x) / f32(window_size_y)
		view_to_proj := linalg.matrix4_perspective_f32(
			math.RAD_PER_DEG * 59.0,
			aspect_ratio,
			0.1,
			1000.0,
			false,
		)

		frame_arena := &frame_arenas[next_frame % Frames_In_Flight]
		gpu.arena_free_all(frame_arena)

		cmd_buf := gpu.commands_begin(.Main)

		gpu.cmd_set_desc_heap(cmd_buf, desc_pool)

		// G-buffer pass: render geometry to multiple color attachments
		render_pass_gbuffer(
			cmd_buf,
			gbuffer_albedo,
			gbuffer_normal,
			gbuffer_metallic_roughness,
			depth_texture,
			vert_shader_gbuffer,
			frag_shader_gbuffer,
			frame_arena,
			&scene,
			meshes_gpu[:],
			world_to_view,
			view_to_proj,
			sampler_id
		)

		// Final pass: composite from G-buffer
		render_pass_final(
			cmd_buf,
			swapchain,
			gbuffer_albedo,
			gbuffer_normal,
			gbuffer_metallic_roughness,
			vert_shader_final,
			frag_shader_final,
			frame_arena,
			full_screen_quad_verts,
			full_screen_quad_indices,
		)

		gpu.cmd_add_signal_semaphore(cmd_buf, frame_sem, next_frame)
		gpu.queue_submit(.Main, {cmd_buf})

		gpu.swapchain_present(.Main, frame_sem, next_frame)
		next_frame += 1
	}

	gpu.wait_idle()
}

render_pass_gbuffer :: proc(
	cmd_buf: gpu.Command_Buffer,
	gbuffer_albedo: gpu.Texture,
	gbuffer_normal: gpu.Texture,
	gbuffer_metallic_roughness: gpu.Texture,
	depth_texture: gpu.Texture,
	vert_shader: gpu.Shader,
	frag_shader: gpu.Shader,
	frame_arena: ^gpu.Arena,
	scene: ^shared.Scene,
	meshes_gpu: []Mesh_GPU,
	world_to_view: matrix[4, 4]f32,
	view_to_proj: matrix[4, 4]f32,
	sampler_id: u32,
) {
	gpu.cmd_begin_render_pass(
		cmd_buf,
		{
			color_attachments = {
				{texture = gbuffer_albedo, clear_color = {0.0, 0.0, 0.0, 1.0}},
				{texture = gbuffer_normal, clear_color = {0.5, 0.5, 1.0, 1.0}},
				{texture = gbuffer_metallic_roughness, clear_color = {0.0, 0.0, 0.0, 1.0}},
			},
			depth_attachment = gpu.Render_Attachment{texture = depth_texture, clear_color = 1.0},
		},
	)
	gpu.cmd_set_shaders(cmd_buf, vert_shader, frag_shader)

	gpu.cmd_set_depth_state(cmd_buf, {mode = {.Read, .Write}, compare = .Less})

	for instance in scene.instances {
		mesh := meshes_gpu[instance.mesh_idx]
		base_color_map := scene.meshes[instance.mesh_idx].base_color_map
		metallic_roughness_map := scene.meshes[instance.mesh_idx].metallic_roughness_map
		normal_map := scene.meshes[instance.mesh_idx].normal_map

		Vert_Data :: struct #all_or_none {
			positions:             rawptr,
			normals:               rawptr,
			uvs:                   rawptr,
			model_to_world:        [16]f32,
			model_to_world_normal: [16]f32,
			world_to_view:         [16]f32,
			view_to_proj:          [16]f32,
		}
		#assert(size_of(Vert_Data) == 8 + 8 + 8 + 64 + 64 + 64 + 64)
		verts_data := gpu.arena_alloc(frame_arena, Vert_Data)
		verts_data.cpu^ = {
			positions             = mesh.pos.gpu.ptr,
			normals               = mesh.normals.gpu.ptr,
			uvs                   = mesh.uvs.gpu.ptr,
			model_to_world        = intr.matrix_flatten(instance.transform),
			model_to_world_normal = intr.matrix_flatten(
				linalg.transpose(linalg.inverse(instance.transform)),
			),
			world_to_view         = intr.matrix_flatten(world_to_view),
			view_to_proj          = intr.matrix_flatten(view_to_proj),
		}

		Frag_Data :: struct #all_or_none {
			base_color_map:                 u32,
			base_color_map_sampler:         u32,
			metallic_roughness_map:         u32,
			metallic_roughness_map_sampler: u32,
			normal_map:                     u32,
			normal_map_sampler:             u32,
		}
		frag_data := gpu.arena_alloc(frame_arena, Frag_Data)
		frag_data.cpu^ = {
			base_color_map                 = base_color_map,
			base_color_map_sampler         = sampler_id,
			metallic_roughness_map         = metallic_roughness_map,
			metallic_roughness_map_sampler = sampler_id,
			normal_map                     = normal_map,
			normal_map_sampler             = sampler_id,
		}

		gpu.cmd_draw_indexed(
			cmd_buf,
			verts_data,
			frag_data,
			mesh.indices,
		)
	}

	gpu.cmd_end_render_pass(cmd_buf)
	// Barrier to ensure G-buffer textures are ready for sampling in next pass
	gpu.cmd_barrier(cmd_buf, .Raster_Color_Out, .Fragment_Shader, {})
}

render_pass_final :: proc(
	cmd_buf: gpu.Command_Buffer,
	swapchain: gpu.Texture,
	gbuffer_albedo: gpu.Texture,
	gbuffer_normal: gpu.Texture,
	gbuffer_metallic_roughness: gpu.Texture,
	vert_shader: gpu.Shader,
	frag_shader: gpu.Shader,
	frame_arena: ^gpu.Arena,
	fsq_verts: gpu.slice_t(Fullscreen_Vertex),
	fsq_indices: gpu.slice_t(u32),
) {
	gpu.cmd_begin_render_pass(
		cmd_buf,
		{color_attachments = {{texture = swapchain, clear_color = {0.7, 0.7, 0.7, 1.0}}}},
	)
	gpu.cmd_set_shaders(cmd_buf, vert_shader, frag_shader)

	// Disable depth testing for fullscreen quad
	gpu.cmd_set_depth_state(cmd_buf, {mode = {}, compare = .Always})

	// Vertex data for fullscreen quad
	Vert_Data :: struct #all_or_none {
		verts: rawptr,
	}
	verts_data := gpu.arena_alloc(frame_arena, Vert_Data)
	verts_data.cpu.verts = fsq_verts.gpu.ptr

	// Fragment data with all G-buffer textures and selected texture type
	Frag_Data :: struct #all_or_none {
		gbuffer_albedo:                     u32,
		gbuffer_albedo_sampler:             u32,
		gbuffer_normal:                     u32,
		gbuffer_normal_sampler:             u32,
		gbuffer_metallic_roughness:         u32,
		gbuffer_metallic_roughness_sampler: u32,
		selected_texture_type:              i32,
	}
	frag_data := gpu.arena_alloc(frame_arena, Frag_Data)
	frag_data.cpu^ = {
		gbuffer_albedo                     = GBUFFER_ALBEDO_IDX,
		gbuffer_albedo_sampler             = 0,
		gbuffer_normal                     = GBUFFER_NORMAL_IDX,
		gbuffer_normal_sampler             = 0,
		gbuffer_metallic_roughness         = GBUFFER_METALLIC_ROUGHNESS_IDX,
		gbuffer_metallic_roughness_sampler = 0,
		selected_texture_type              = i32(selected_texture_type),
	}

	// Render fullscreen quad
	gpu.cmd_draw_indexed(cmd_buf, verts_data.gpu, frag_data.gpu, fsq_indices)

	gpu.cmd_end_render_pass(cmd_buf)
}

create_gbuffer_textures :: proc(
	window_size_x: u32,
	window_size_y: u32,
	desc_pool: ^gpu.Descriptor_Pool,
) -> (
	gbuffer_albedo: gpu.Owned_Texture,
	gbuffer_normal: gpu.Owned_Texture,
	gbuffer_metallic_roughness: gpu.Owned_Texture,
	depth_texture: gpu.Owned_Texture,
) {
	gbuffer_desc := gpu.Texture_Desc {
		dimensions   = {u32(window_size_x), u32(window_size_y), 1},
		format       = .RGBA8_Unorm,
		usage        = {.Color_Attachment, .Sampled, .Storage},
	}

	depth_desc := gpu.Texture_Desc {
		dimensions   = {u32(window_size_x), u32(window_size_y), 1},
		format       = .D32_Float,
		usage        = {.Depth_Stencil_Attachment},
	}

	// Albedo
	{
		new_gbuffer_albedo := gpu.texture_alloc_and_create(gbuffer_desc)
		GBUFFER_ALBEDO_IDX = gpu.desc_pool_alloc_texture(
			desc_pool,
			gpu.texture_view_descriptor(new_gbuffer_albedo, {})
		)
		gbuffer_albedo = new_gbuffer_albedo
	}

	// Normal
	{
		new_gbuffer_normal := gpu.texture_alloc_and_create(gbuffer_desc)
		GBUFFER_NORMAL_IDX = gpu.desc_pool_alloc_texture(
			desc_pool,
			gpu.texture_view_descriptor(new_gbuffer_normal, {})
		)
		gbuffer_normal = new_gbuffer_normal
	}

	// Metallic roughness
	{
		new_gbuffer_metallic_roughness := gpu.texture_alloc_and_create(gbuffer_desc)
		GBUFFER_METALLIC_ROUGHNESS_IDX = gpu.desc_pool_alloc_texture(
			desc_pool,
			gpu.texture_view_descriptor(new_gbuffer_metallic_roughness, {})
		)
		gbuffer_metallic_roughness = new_gbuffer_metallic_roughness
	}

	// Depth
	{
		new_depth_texture := gpu.texture_alloc_and_create(depth_desc)
		depth_texture = new_depth_texture
	}

	return gbuffer_albedo, gbuffer_normal, gbuffer_metallic_roughness, depth_texture
}

// Create a 1x1 magenta texture (useful as default/missing texture indicator)
create_magenta_texture :: proc(
	upload_arena: ^gpu.Arena,
	cmd_buf: gpu.Command_Buffer,
) -> gpu.Owned_Texture {
	magenta_pixels := [4]u8{255, 0, 255, 255}
	staging := gpu.arena_alloc(upload_arena, u8, 4)
	copy(staging.cpu, magenta_pixels[:])

	texture := gpu.texture_alloc_and_create(
		{
			type = .D2,
			dimensions = {1, 1, 1},
			format = .RGBA8_Unorm,
			usage = {.Sampled},
		},
	)
	gpu.cmd_copy_to_texture(cmd_buf, texture, staging)
	return texture
}

Fullscreen_Vertex :: struct {
	pos: [3]f32,
	uv:  [2]f32,
}

create_fullscreen_quad :: proc(
	upload_arena: ^gpu.Arena,
	cmd_buf: gpu.Command_Buffer,
) -> (
	gpu.slice_t(Fullscreen_Vertex),
	gpu.slice_t(u32),
) {
	fsq_verts := gpu.arena_alloc(upload_arena, Fullscreen_Vertex, 4)
	fsq_verts.cpu[0].pos = {-1.0, 1.0, 0.0} // Top-left
	fsq_verts.cpu[1].pos = {1.0, -1.0, 0.0} // Bottom-right
	fsq_verts.cpu[2].pos = {1.0, 1.0, 0.0} // Top-right
	fsq_verts.cpu[3].pos = {-1.0, -1.0, 0.0} // Bottom-left
	fsq_verts.cpu[0].uv = {0.0, 1.0}
	fsq_verts.cpu[1].uv = {1.0, 0.0}
	fsq_verts.cpu[2].uv = {1.0, 1.0}
	fsq_verts.cpu[3].uv = {0.0, 0.0}

	fsq_indices := gpu.arena_alloc(upload_arena, u32, 6)
	fsq_indices.cpu[0] = 0
	fsq_indices.cpu[1] = 2
	fsq_indices.cpu[2] = 1
	fsq_indices.cpu[3] = 0
	fsq_indices.cpu[4] = 1
	fsq_indices.cpu[5] = 3

	full_screen_quad_verts_local := gpu.mem_alloc(Fullscreen_Vertex, 4, gpu.Memory.GPU)
	full_screen_quad_indices_local := gpu.mem_alloc(u32, 6, gpu.Memory.GPU)

	gpu.cmd_mem_copy(
		cmd_buf,
		full_screen_quad_verts_local,
		fsq_verts,
	)
	gpu.cmd_mem_copy(
		cmd_buf,
		full_screen_quad_indices_local,
		fsq_indices,
	)

	return full_screen_quad_verts_local, full_screen_quad_indices_local
}

// Load textures from Texture_Info and update mesh texture IDs
load_scene_textures_from_gltf :: proc(
	texture_infos: []shared.Gltf_Texture_Info,
	data: ^gltf2.Data,
	scene: ^shared.Scene,
	desc_pool: ^gpu.Descriptor_Pool
) {
	upload_arena := gpu.arena_create()
	defer gpu.arena_destroy(&upload_arena)

	for info, i in texture_infos {
		if cancel_loading_textures {
			return
		}

		if info.mesh_id >= u32(len(scene.meshes)) {
			log.errorf(
				"Invalid mesh_id %v (only %v meshes available)",
				info.mesh_id,
				len(scene.meshes),
			)
			continue
		}

		sync.mutex_lock(&mutex)
		if event, ok := image_uploaded[info.image_index]; ok {
			sync.mutex_unlock(&mutex)
			sync.one_shot_event_wait(event)
		} else {
			event := new(sync.One_Shot_Event)
			image_uploaded[info.image_index] = event
			sync.mutex_unlock(&mutex)

			img := shared.load_texture_from_gltf(
                info.image_index,
                data,
            )
            defer image.destroy(img)

			texture_idx: u32
            if Compress_Textures {
                compressed := shared.bc3_compress_rgba8_mips(
                    img.pixels.buf[:],
                    u32(img.width),
                    u32(img.height),
                )
                defer delete(compressed.data)
                defer delete(compressed.offsets)
                texture := upload_bc3_texture(
                    img,
                    compressed,
                    &upload_arena
                )

				texture_idx = gpu.desc_pool_alloc_texture(desc_pool, gpu.texture_view_descriptor(texture, {}))
                if sync.guard(&mutex) do image_to_texture[info.image_index] = {texture, texture_idx}
            } else {
                texture := upload_texture(
                    img,
                    &upload_arena
                )

				texture_idx = gpu.desc_pool_alloc_texture(desc_pool, gpu.texture_view_descriptor(texture, {}))
                if sync.guard(&mutex) do image_to_texture[info.image_index] = {texture, texture_idx}
            }

			sync.one_shot_event_signal(event)

			log.infof(
				"Loaded texture for mesh %v, type %v, texture_id %v",
				info.mesh_id,
				info.texture_type,
				texture_idx,
			)
		}
	}

	for info, i in texture_infos {
		sync.guard(&mutex)

        texture := image_to_texture[info.image_index]
		gpu.semaphore_wait(upload_sem, upload_sem_val)

		switch info.texture_type {
		case .Base_Color:
			scene.meshes[info.mesh_id].base_color_map = texture.texture_idx
		case .Metallic_Roughness:
			scene.meshes[info.mesh_id].metallic_roughness_map = texture.texture_idx
		case .Normal:
			scene.meshes[info.mesh_id].normal_map = texture.texture_idx
		}
	}
}

upload_texture :: proc(
	img: ^image.Image,
	upload_arena: ^gpu.Arena,
) -> gpu.Owned_Texture {
	staging := gpu.arena_alloc_raw(upload_arena, len(img.pixels.buf), 1, 16)
	runtime.mem_copy(staging.cpu, raw_data(img.pixels.buf), len(img.pixels.buf))

	sync.guard(&mutex)
	upload_sem_value_old := upload_sem_val
	upload_sem_val += 1

	texture := gpu.texture_alloc_and_create(
		{
			type = .D2,
			dimensions = {u32(img.width), u32(img.height), 1},
			mip_count = u32(math.log2(f32(max(img.width, img.height)))),
			format = .RGBA8_Unorm,
			usage = { .Sampled, .Transfer_Src },
		},
		.Transfer,
	)
	append(&loaded_textures, texture)

	// Upload and mipmap generation happen on separate queues so they need to be synchronized using timeline semaphores

	{
		// Upload texture to GPU
		upload_cmd_buf := gpu.commands_begin(.Transfer)
		gpu.cmd_copy_to_texture(upload_cmd_buf, texture, staging)
		gpu.cmd_add_signal_semaphore(upload_cmd_buf, upload_sem, upload_sem_value_old + 1)
		gpu.queue_submit(.Transfer, {upload_cmd_buf})
	}

    if Compress_Textures {
		compressed := shared.bc3_compress_rgba8_mips(
			img.pixels.buf[:],
			u32(img.width),
			u32(img.height),
		)
		defer {
			delete(compressed.data)
			delete(compressed.offsets)
		}

		staging := gpu.arena_alloc(upload_arena, u8, len(compressed.data))
		copy(staging.cpu, compressed.data[:])

		texture = gpu.texture_alloc_and_create(
			{
				type = .D2,
				dimensions = {u32(img.width), u32(img.height), 1},
				mip_count = compressed.mip_count,
				layer_count = 1,
				sample_count = 1,
				format = .BC3_RGBA_Unorm,
				usage = { .Sampled, .Transfer_Src },
			},
			.Transfer,
		)
		append(&loaded_textures, texture)

		upload_cmd_buf := gpu.commands_begin(.Transfer)
        gpu.cmd_barrier(upload_cmd_buf, .Transfer, .Transfer, {})
        for mip in 0..<compressed.mip_count {
        	gpu.cmd_copy_to_texture(
        		upload_cmd_buf,
        		texture,
        		gpu.subslice(staging, compressed.offsets[mip]),
        		{ mip_level = mip }
        	)
        }
		gpu.cmd_add_wait_semaphore(upload_cmd_buf, upload_sem, upload_sem_value_old + 1)
		gpu.queue_submit(.Transfer, {upload_cmd_buf})
	} else {
		// Generate mipmaps
		mipmaps_cmd_buf := gpu.commands_begin(.Main)
		gpu.cmd_barrier(mipmaps_cmd_buf, .Transfer, .Transfer, {})
		gpu.cmd_generate_mipmaps(mipmaps_cmd_buf, texture)
		gpu.cmd_add_wait_semaphore(mipmaps_cmd_buf, upload_sem, upload_sem_value_old + 1)
		gpu.queue_submit(.Main, {mipmaps_cmd_buf})
	}

	return texture
}

upload_bc3_texture :: proc(
    img: ^image.Image,
	compressed: shared.Block_Compressed_Mips,
	upload_arena: ^gpu.Arena,
) -> gpu.Owned_Texture {
	sync.guard(&mutex)

	upload_sem_value_old := upload_sem_val
	upload_sem_val += 1

    upload_cmd_buf := gpu.commands_begin(.Transfer)
    staging := gpu.arena_alloc(upload_arena, u8, len(compressed.data))
    copy(staging.cpu, compressed.data[:])

    texture := gpu.texture_alloc_and_create(
        {
            type = .D2,
            dimensions = {u32(img.width), u32(img.height), 1},
            mip_count = compressed.mip_count,
            format = .BC3_RGBA_Unorm,
            usage = { .Sampled, .Transfer_Src },
        },
        .Transfer,
    )
    append(&loaded_textures, texture)

    for mip in 0..<compressed.mip_count {
    	gpu.cmd_copy_to_texture(
    		upload_cmd_buf,
    		texture,
    		gpu.subslice(staging, compressed.offsets[mip]),
    		{ mip_level = mip }
    	)
    }
    gpu.cmd_barrier(upload_cmd_buf, .Transfer, .Transfer, {})
    gpu.cmd_add_signal_semaphore(upload_cmd_buf, upload_sem, upload_sem_value_old + 1)
    gpu.queue_submit(.Transfer, {upload_cmd_buf})
	return texture
}

Mesh_GPU :: struct
{
	pos: gpu.slice_t([4]f32),
	normals: gpu.slice_t([4]f32),
	uvs: gpu.slice_t([2]f32),
	indices: gpu.slice_t(u32),
	idx_count: u32,
}

upload_mesh :: proc(upload_arena: ^gpu.Arena, cmd_buf: gpu.Command_Buffer, mesh: shared.Mesh) -> Mesh_GPU
{
	assert(len(mesh.pos) == len(mesh.normals))
	assert(len(mesh.pos) == len(mesh.uvs))

	positions_staging := gpu.arena_alloc(upload_arena, [4]f32, len(mesh.pos))
	normals_staging := gpu.arena_alloc(upload_arena, [4]f32, len(mesh.normals))
	uvs_staging := gpu.arena_alloc(upload_arena, [2]f32, len(mesh.uvs))
	indices_staging := gpu.arena_alloc(upload_arena, u32, len(mesh.indices))
	copy(positions_staging.cpu, mesh.pos[:])
	copy(normals_staging.cpu, mesh.normals[:])
	copy(uvs_staging.cpu, mesh.uvs[:])
	copy(indices_staging.cpu, mesh.indices[:])

	res: Mesh_GPU
	res.pos = gpu.mem_alloc([4]f32, len(mesh.pos), mem_type = gpu.Memory.GPU)
	res.normals = gpu.mem_alloc([4]f32, len(mesh.normals), mem_type = gpu.Memory.GPU)
	res.uvs = gpu.mem_alloc([2]f32, len(mesh.uvs), mem_type = gpu.Memory.GPU)
	res.indices = gpu.mem_alloc(u32, len(mesh.indices), mem_type = gpu.Memory.GPU)
	res.idx_count = u32(len(mesh.indices))
	gpu.cmd_mem_copy(cmd_buf, res.pos,     positions_staging)
	gpu.cmd_mem_copy(cmd_buf, res.normals, normals_staging  )
	gpu.cmd_mem_copy(cmd_buf, res.uvs,     uvs_staging      )
	gpu.cmd_mem_copy(cmd_buf, res.indices, indices_staging  )
	return res
}

mesh_destroy :: proc(mesh: ^Mesh_GPU)
{
	gpu.mem_free(mesh.pos)
	gpu.mem_free(mesh.normals)
	gpu.mem_free(mesh.uvs)
	gpu.mem_free(mesh.indices)
	mesh^ = {}
}
