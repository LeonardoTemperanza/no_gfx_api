package shared

import "base:runtime"
import "core:fmt"

import log "core:log"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:slice"
import "gltf2"
import "core:image"
import "core:strings"
import "core:image/jpeg"
import "core:image/png"
import intr "base:intrinsics"
import "core:os"

import sdl "vendor:sdl3"

MACOS_SDL_INIT_VULKAN_ERR_MSG :: `
Failed to load the vulkan library on macOS!

NOTE:
If you are having trouble running this on macOS, you might not have the 'VULKAN_SDK' environment variable populated. Make sure to "source" the "setup-env.sh" script present within the 'VulkanSDK' folder before running the app.

Like this:
> source ~/VulkanSDK/1.x.xxx.x/setup-env.sh
`

Working_Status :: enum
{
    Works,
    Partially_Works,
    Does_Not_Work,
}

sdl_init :: proc(moltenvk_working_status := Working_Status.Works, kosmickrisp_working_status := Working_Status.Works)
{
    ok_i := sdl.Init({.VIDEO})
	assert(ok_i)

    when ODIN_OS == .Darwin
    {
        // NOTE:
        // We make the assumption that if `VK_DRIVER_FILES` does *not* contain `libkosmickrisp`,
        // it is running MoltenVK. This is because, for now, MoltenVK is the default on macOS.
        // Until that changes, we will continue to make this assumption in the example setup
        // code.
        driver_used := os.get_env_alloc("VK_DRIVER_FILES", context.temp_allocator)

        using_moltenvk := !(strings.contains(driver_used, "libkosmickrisp"))

        if using_moltenvk
        {
            ensure(moltenvk_working_status != .Does_Not_Work, "This example unfortunately does not work on MoltenVK!")
            if moltenvk_working_status == .Partially_Works
            {
                fmt.printfln("[WARNING] - For this example, MoltenVK only partially works.")
            }
        }
        else
        {
            ensure(kosmickrisp_working_status != .Does_Not_Work, "This example unfortunately does not work on KosmicKrisp!")
            if kosmickrisp_working_status == .Partially_Works
            {
                fmt.printfln("[WARNING] - For this example, KosmicKrisp only partially works.")
            }
        }

        if !sdl.Vulkan_LoadLibrary("libvulkan.1.dylib")
        {
            panic(MACOS_SDL_INIT_VULKAN_ERR_MSG)
        }
    }
}

Texture_Type :: enum {
	Base_Color,
	Metallic_Roughness,
	Normal,
}

Gltf_Texture_Info :: struct {
	mesh_id:      u32,
	texture_type: Texture_Type,
	image_index:  int,
}

Mesh :: struct {
	pos:                    [dynamic][4]f32,
	normals:                [dynamic][4]f32,
	uvs:                    [dynamic][2]f32,
	indices:                [dynamic]u32,
	base_color_map:         u32,
	metallic_roughness_map: u32,
	normal_map:             u32,
}

destroy_mesh :: proc(mesh: ^Mesh) {
	delete(mesh.pos)
	delete(mesh.normals)
	delete(mesh.uvs)
	delete(mesh.indices)
	mesh^ = {}
}

Block_Compressed_Mips :: struct {
	data:      [dynamic]byte,
	offsets:   [dynamic]u64,
	mip_count: u32,
}

Scene :: struct {
	meshes:    [dynamic]Mesh,
	instances: [dynamic]Instance,
}

destroy_scene :: proc(scene: ^Scene) {
	for &mesh in scene.meshes {
		destroy_mesh(&mesh)
	}

	delete(scene.meshes)
	delete(scene.instances)
	scene^ = {}
}

bc3_compress_rgba8_mips :: proc(pixels: []byte, width, height: u32) -> Block_Compressed_Mips {
	assert(len(pixels) == int(width*height*4))

	res: Block_Compressed_Mips
	level_w := width
	level_h := height
	total_bytes: u64

	for {
		append(&res.offsets, total_bytes)
		total_bytes += bc3_mip_size(level_w, level_h)
		res.mip_count += 1

		if level_w == 1 && level_h == 1 {
			break
		}

		level_w = max(1, level_w / 2)
		level_h = max(1, level_h / 2)
	}

	res.data = make([dynamic]byte, int(total_bytes))

	current_pixels := pixels
	current_w := width
	current_h := height
	owns_pixels := false

	for mip: u32 = 0; mip < res.mip_count; mip += 1 {
		offset := int(res.offsets[mip])
		level_size := int(bc3_mip_size(current_w, current_h))
		dst_level := res.data[offset : offset+level_size]
		bc3_compress_level(current_pixels, current_w, current_h, dst_level)

		if current_w == 1 && current_h == 1 {
			break
		}

		prev_pixels := current_pixels
		prev_owned := owns_pixels

		next_pixels, next_w, next_h := downsample_rgba8_2x2(current_pixels, current_w, current_h)

		if prev_owned {
			delete(prev_pixels)
		}

		current_pixels = next_pixels
		current_w = next_w
		current_h = next_h
		owns_pixels = true
	}

	if owns_pixels {
		delete(current_pixels)
	}

	return res
}

bc3_mip_size :: proc(width, height: u32) -> u64 {
	blocks_x := max(1, (width + 3) / 4)
	blocks_y := max(1, (height + 3) / 4)
	return u64(blocks_x * blocks_y * 16)
}

downsample_rgba8_2x2 :: proc(pixels: []byte, width, height: u32) -> (next: []byte, next_w: u32, next_h: u32) {
	next_w = max(1, width / 2)
	next_h = max(1, height / 2)
	next = make([]byte, int(next_w*next_h*4))

	for y: u32 = 0; y < next_h; y += 1 {
		for x: u32 = 0; x < next_w; x += 1 {
			src_x0 := min(width-1, x*2)
			src_y0 := min(height-1, y*2)
			src_x1 := min(width-1, src_x0+1)
			src_y1 := min(height-1, src_y0+1)

			sum_r: u32
			sum_g: u32
			sum_b: u32
			sum_a: u32

			idx0 := int((src_y0*width + src_x0) * 4)
			idx1 := int((src_y0*width + src_x1) * 4)
			idx2 := int((src_y1*width + src_x0) * 4)
			idx3 := int((src_y1*width + src_x1) * 4)
			if idx3+3 >= len(pixels) do assert(false)

			sum_r += u32(pixels[idx0 + 0]) + u32(pixels[idx1 + 0]) +
				u32(pixels[idx2 + 0]) + u32(pixels[idx3 + 0])
			sum_g += u32(pixels[idx0 + 1]) + u32(pixels[idx1 + 1]) +
				u32(pixels[idx2 + 1]) + u32(pixels[idx3 + 1])
			sum_b += u32(pixels[idx0 + 2]) + u32(pixels[idx1 + 2]) +
				u32(pixels[idx2 + 2]) + u32(pixels[idx3 + 2])
			sum_a += u32(pixels[idx0 + 3]) + u32(pixels[idx1 + 3]) +
				u32(pixels[idx2 + 3]) + u32(pixels[idx3 + 3])

			dst_idx := int((y*next_w + x) * 4)
			if dst_idx+3 >= len(next) do assert(false)
			next[dst_idx + 0] = byte(sum_r / 4)
			next[dst_idx + 1] = byte(sum_g / 4)
			next[dst_idx + 2] = byte(sum_b / 4)
			next[dst_idx + 3] = byte(sum_a / 4)
		}
	}

	return
}

bc3_compress_level :: proc(pixels: []byte, width, height: u32, dst: []byte) {
	blocks_x := max(1, (width + 3) / 4)
	blocks_y := max(1, (height + 3) / 4)
	assert(len(dst) == int(blocks_x*blocks_y*16))

	block_idx: u32
	for by: u32 = 0; by < blocks_y; by += 1 {
		for bx: u32 = 0; bx < blocks_x; bx += 1 {
			min_a: u8 = 255
			max_a: u8
			min_luma: u32 = max(u32)
			max_luma: u32 = 0
			min_r: u8; min_g: u8; min_b: u8
			max_r: u8; max_g: u8; max_b: u8

			for y: u32 = 0; y < 4; y += 1 {
				for x: u32 = 0; x < 4; x += 1 {
					px := min(width-1, bx*4+x)
					py := min(height-1, by*4+y)
					idx := (py*width + px) * 4
					r := pixels[idx + 0]
					g := pixels[idx + 1]
					b := pixels[idx + 2]
					a := pixels[idx + 3]
					if a < min_a do min_a = a
					if a > max_a do max_a = a
					luma := u32(r)*2126 + u32(g)*7152 + u32(b)*722
					if luma < min_luma {
						min_luma = luma
						min_r = r
						min_g = g
						min_b = b
					}
					if luma > max_luma {
						max_luma = luma
						max_r = r
						max_g = g
						max_b = b
					}
				}
			}

			color0 := pack_rgb565(max_r, max_g, max_b)
			color1 := pack_rgb565(min_r, min_g, min_b)
			if color1 > color0 {
				color0, color1 = color1, color0
			}

			c0r, c0g, c0b := unpack_rgb565(color0)
			c1r, c1g, c1b := unpack_rgb565(color1)
			palette: [4][3]u32
			palette[0] = {c0r, c0g, c0b}
			palette[1] = {c1r, c1g, c1b}
			palette[2] = {(2*c0r + c1r) / 3, (2*c0g + c1g) / 3, (2*c0b + c1b) / 3}
			palette[3] = {(c0r + 2*c1r) / 3, (c0g + 2*c1g) / 3, (c0b + 2*c1b) / 3}

			alpha0 := max_a
			alpha1 := min_a
			if alpha1 > alpha0 {
				alpha0, alpha1 = alpha1, alpha0
			}
			alpha_palette: [8]u32
			alpha_palette[0] = u32(alpha0)
			alpha_palette[1] = u32(alpha1)
			if alpha0 > alpha1 {
				alpha_palette[2] = (6*alpha_palette[0] + 1*alpha_palette[1]) / 7
				alpha_palette[3] = (5*alpha_palette[0] + 2*alpha_palette[1]) / 7
				alpha_palette[4] = (4*alpha_palette[0] + 3*alpha_palette[1]) / 7
				alpha_palette[5] = (3*alpha_palette[0] + 4*alpha_palette[1]) / 7
				alpha_palette[6] = (2*alpha_palette[0] + 5*alpha_palette[1]) / 7
				alpha_palette[7] = (1*alpha_palette[0] + 6*alpha_palette[1]) / 7
			} else {
				alpha_palette[2] = (4*alpha_palette[0] + 1*alpha_palette[1]) / 5
				alpha_palette[3] = (3*alpha_palette[0] + 2*alpha_palette[1]) / 5
				alpha_palette[4] = (2*alpha_palette[0] + 3*alpha_palette[1]) / 5
				alpha_palette[5] = (1*alpha_palette[0] + 4*alpha_palette[1]) / 5
				alpha_palette[6] = 0
				alpha_palette[7] = 255
			}

			indices: u32
			alpha_indices: u64
			for y: u32 = 0; y < 4; y += 1 {
				for x: u32 = 0; x < 4; x += 1 {
					px := min(width-1, bx*4+x)
					py := min(height-1, by*4+y)
					idx := (py*width + px) * 4
					r := u32(pixels[idx + 0])
					g := u32(pixels[idx + 1])
					b := u32(pixels[idx + 2])
					a := u32(pixels[idx + 3])

					best_idx: u32
					best_dist: u32 = max(u32)
					for i := 0; i < 4; i += 1 {
						pr := palette[i][0]
						pg := palette[i][1]
						pb := palette[i][2]
						dr := i32(r) - i32(pr)
						dg := i32(g) - i32(pg)
						db := i32(b) - i32(pb)
						dist := u32(dr*dr + dg*dg + db*db)
						if dist < best_dist {
							best_dist = dist
							best_idx = u32(i)
						}
					}

					indices |= (best_idx & 0x3) << (2 * (y*4 + x))

					best_alpha_idx: u64
					best_alpha_dist: u32 = max(u32)
					for i := 0; i < 8; i += 1 {
						pa := alpha_palette[i]
						da := i32(a) - i32(pa)
						dist := u32(da * da)
						if dist < best_alpha_dist {
							best_alpha_dist = dist
							best_alpha_idx = u64(i)
						}
					}
					alpha_indices |= (best_alpha_idx & 0x7) << (3 * (y*4 + x))
				}
			}

			offset := int(block_idx * 16)
			dst[offset + 0] = byte(alpha0)
			dst[offset + 1] = byte(alpha1)
			dst[offset + 2] = byte(alpha_indices & 0xFF)
			dst[offset + 3] = byte((alpha_indices >> 8) & 0xFF)
			dst[offset + 4] = byte((alpha_indices >> 16) & 0xFF)
			dst[offset + 5] = byte((alpha_indices >> 24) & 0xFF)
			dst[offset + 6] = byte((alpha_indices >> 32) & 0xFF)
			dst[offset + 7] = byte((alpha_indices >> 40) & 0xFF)
			dst[offset + 8] = byte(color0 & 0xFF)
			dst[offset + 9] = byte((color0 >> 8) & 0xFF)
			dst[offset + 10] = byte(color1 & 0xFF)
			dst[offset + 11] = byte((color1 >> 8) & 0xFF)
			dst[offset + 12] = byte(indices & 0xFF)
			dst[offset + 13] = byte((indices >> 8) & 0xFF)
			dst[offset + 14] = byte((indices >> 16) & 0xFF)
			dst[offset + 15] = byte((indices >> 24) & 0xFF)

			block_idx += 1
		}
	}
}

pack_rgb565 :: proc(r, g, b: u8) -> u16 {
	r5 := (u16(r) * 31 + 127) / 255
	g6 := (u16(g) * 63 + 127) / 255
	b5 := (u16(b) * 31 + 127) / 255
	return (r5 << 11) | (g6 << 5) | b5
}

unpack_rgb565 :: proc(c: u16) -> (r: u32, g: u32, b: u32) {
	r = u32((c >> 11) & 0x1F)
	g = u32((c >> 5) & 0x3F)
	b = u32(c & 0x1F)
	r = (r * 255 + 15) / 31
	g = (g * 255 + 31) / 63
	b = (b * 255 + 15) / 31
	return
}

Instance :: struct {
	transform: matrix[4, 4]f32,
	mesh_idx:  u32,
}

// Input

Key_State :: struct {
	pressed:  bool,
	pressing: bool,
	released: bool,
}

Input :: struct {
	pressing_right_click: bool,
	left_click_pressed:   bool, // One-shot flag for left mouse button press
	keys:                 #sparse[sdl.Scancode]Key_State,
	mouse_dx:             f32, // pixels/dpi (inches), right is positive
	mouse_dy:             f32, // pixels/dpi (inches), up is positive
}

INPUT: Input

handle_window_events :: proc(window: ^sdl.Window) -> (proceed: bool) {
	// Reset "one-shot" inputs
	for &key in INPUT.keys {
		key.pressed = false
		key.released = false
	}
	INPUT.mouse_dx = 0
	INPUT.mouse_dy = 0
	INPUT.left_click_pressed = false

	event: sdl.Event
	proceed = true
	for sdl.PollEvent(&event) {
		#partial switch event.type {
		case .QUIT:
			proceed = false
		case .WINDOW_CLOSE_REQUESTED:
			{
				if event.window.windowID == sdl.GetWindowID(window) {
					proceed = false
				}
			}
		// Input events
		case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
			{
				event := event.button
				if event.type == .MOUSE_BUTTON_DOWN {
					if event.button == sdl.BUTTON_RIGHT {
						INPUT.pressing_right_click = true
					} else if event.button == sdl.BUTTON_LEFT {
						INPUT.left_click_pressed = true
					}
				} else if event.type == .MOUSE_BUTTON_UP {
					if event.button == sdl.BUTTON_RIGHT {
						INPUT.pressing_right_click = false
					}
				}
			}
		case .KEY_DOWN, .KEY_UP:
			{
				event := event.key
				if event.repeat do break

				if event.type == .KEY_DOWN {
					INPUT.keys[event.scancode].pressed = true
					INPUT.keys[event.scancode].pressing = true
				} else {
					INPUT.keys[event.scancode].pressing = false
					INPUT.keys[event.scancode].released = true
				}
			}
		case .MOUSE_MOTION:
			{
				event := event.motion
				INPUT.mouse_dx += event.xrel
				INPUT.mouse_dy -= event.yrel // In sdl, up is negative
			}
		}
	}

	return
}

CAM_POS: [3]f32
CAM_ANGLE: [2]f32
first_person_camera_view :: proc(delta_time: f32) -> (matrix[4, 4]f32) {
	cam_rot: quaternion128 = 1

	mouse_sensitivity := math.to_radians_f32(0.2) // Radians per pixel
	mouse: [2]f32
	if INPUT.pressing_right_click {
		mouse.x = INPUT.mouse_dx * mouse_sensitivity
		mouse.y = INPUT.mouse_dy * mouse_sensitivity
	}

	CAM_ANGLE += mouse

	// Wrap CAM_ANGLE.x
	for CAM_ANGLE.x < 0 do CAM_ANGLE.x += 2 * math.PI
	for CAM_ANGLE.x > 2 * math.PI do CAM_ANGLE.x -= 2 * math.PI

	CAM_ANGLE.y = clamp(CAM_ANGLE.y, math.to_radians_f32(-90), math.to_radians_f32(90))
	y_rot := linalg.quaternion_angle_axis(CAM_ANGLE.y, [3]f32{-1, 0, 0})
	x_rot := linalg.quaternion_angle_axis(CAM_ANGLE.x, [3]f32{0, 1, 0})
	cam_rot = x_rot * y_rot

	// Movement
	@(static) cur_vel: [3]f32
	move_speed: f32 : 6.0
	move_speed_fast: f32 : 15.0
	move_accel: f32 : 300.0

	keyboard_dir_xz: [3]f32
	keyboard_dir_y: f32
	if INPUT.pressing_right_click {
		keyboard_dir_xz.x = f32(int(INPUT.keys[.D].pressing) - int(INPUT.keys[.A].pressing))
		keyboard_dir_xz.z = f32(int(INPUT.keys[.W].pressing) - int(INPUT.keys[.S].pressing))
		keyboard_dir_y = f32(int(INPUT.keys[.E].pressing) - int(INPUT.keys[.Q].pressing))

		// It's a "direction" input so its length
		// should be no more than 1
		if linalg.dot(keyboard_dir_xz, keyboard_dir_xz) > 1 {
			keyboard_dir_xz = linalg.normalize(keyboard_dir_xz)
		}

		if abs(keyboard_dir_y) > 1 {
			keyboard_dir_y = math.sign(keyboard_dir_y)
		}
	}

	target_vel := keyboard_dir_xz * move_speed
	target_vel = linalg.quaternion_mul_vector3(cam_rot, target_vel)
	target_vel.y += keyboard_dir_y * move_speed

	cur_vel = approach_linear(cur_vel, target_vel, move_accel * delta_time)
	CAM_POS += cur_vel * delta_time

	return world_to_view_mat(CAM_POS, cam_rot)

	approach_linear :: proc(cur: [3]f32, target: [3]f32, delta: f32) -> [3]f32 {
		diff := target - cur
		dist := linalg.length(diff)

		if dist <= delta do return target
		return cur + diff / dist * delta
	}
}

world_to_view_mat :: proc(cam_pos: [3]f32, cam_rot: quaternion128) -> matrix[4, 4]f32 {
	view_rot := linalg.normalize(linalg.quaternion_inverse(cam_rot))
	view_pos := -cam_pos
	return(
		#force_inline linalg.matrix4_from_quaternion(view_rot) *
		#force_inline linalg.matrix4_translate(view_pos) \
	)
}

// I/O

buffer_slice_with_stride :: proc(
	$T: typeid,
	data: ^gltf2.Data,
	accessor_index: gltf2.Integer,
	allocator := context.allocator,
) -> []T {
	accessor := data.accessors[accessor_index]
	assert(accessor.buffer_view != nil, "accessor must have buffer_view")

	buffer_view := data.buffer_views[accessor.buffer_view.?]

	if _, ok := accessor.sparse.?; ok {
		assert(false, "Sparse not supported")
		return nil
	}

	start_byte := accessor.byte_offset + buffer_view.byte_offset
	uri := data.buffers[buffer_view.buffer].uri

	buffer_data: []byte
	#partial switch v in uri {
	case []byte:
		buffer_data = v
	case string:
		assert(false, "URI string not supported")
		return nil
	}

	element_size := size_of(T)

	stride := int(buffer_view.byte_stride.? or_else gltf2.Integer(element_size))

	count := int(accessor.count)
	result_data := make([]T, count, allocator)

	for i in 0 ..< count {
		src_offset := int(start_byte) + i * stride
		assert(src_offset + element_size <= len(buffer_data), "buffer access out of bounds")
		mem.copy(&result_data[i], &buffer_data[src_offset], element_size)
	}

	return result_data
}

load_scene_gltf :: proc(
	contents: []byte,
	missing_texture_id: u32,
) -> (
	Scene,
	[]Gltf_Texture_Info,
	^gltf2.Data,
) {
	options := gltf2.Options{}
	options.is_glb = true
	data, err_l := gltf2.parse(contents, options)
	switch err in err_l
	{
	case gltf2.JSON_Error:
		log.error(err)
	case gltf2.GLTF_Error:
		log.error(err)
	}
	// Note: data is returned to caller, who should call gltf2.unload(data) when done

	texture_infos: [dynamic]Gltf_Texture_Info

	log.infof("Collecting texture info from %v textures in GLTF", len(data.textures))

	// Build a map from texture index to image index for quick lookup
	texture_to_image: map[int]int
	defer delete(texture_to_image)
	for texture, i in data.textures {
		if texture.source != nil {
			image_idx := texture.source.?
			if int(image_idx) >= len(data.images) {
				log.errorf(
					"Texture %v references invalid image index %v (only %v images available)",
					i,
					image_idx,
					len(data.images),
				)
				continue
			}
			texture_to_image[i] = int(image_idx)
		} else {
			log.infof("Texture %v has no source, skipping", i)
		}
	}

	// Load meshes
	meshes: [dynamic]Mesh
	start_idx: [dynamic]u32
	defer delete(start_idx)
	for mesh, i in data.meshes {
		append(&start_idx, u32(len(meshes)))

		for primitive, j in mesh.primitives {
			assert(primitive.mode == .Triangles)

			positions := buffer_slice_with_stride(
				[3]f32,
				data,
				primitive.attributes["POSITION"],
				context.temp_allocator,
			)
			normals := buffer_slice_with_stride(
				[3]f32,
				data,
				primitive.attributes["NORMAL"],
				context.temp_allocator,
			)
			uvs := buffer_slice_with_stride(
				[2]f32,
				data,
				primitive.attributes["TEXCOORD_0"],
				context.temp_allocator,
			)

			lm_uvs: [][2]f32
			if texcoord1_idx, ok := primitive.attributes["TEXCOORD_1"]; ok {
				lm_uvs = buffer_slice_with_stride(
					[2]f32,
					data,
					texcoord1_idx,
					context.temp_allocator,
				)
			}

			indices := gltf2.buffer_slice(data, primitive.indices.?)

			indices_u32: [dynamic]u32
			defer delete(indices_u32)
			#partial switch ids in indices
			{
			case []u16:
				for i in 0 ..< len(ids) do append(&indices_u32, u32(ids[i]))
			case []u32:
				for i in 0 ..< len(ids) do append(&indices_u32, ids[i])
			case:
				assert(false)
			}

			mesh_idx := u32(len(meshes))
			base_color_map: u32 = missing_texture_id
			metallic_roughness_map: u32 = missing_texture_id
			normal_map: u32 = missing_texture_id

			if primitive.material != nil {
				material_idx := primitive.material.?
				material := data.materials[material_idx]

				// Base color texture
				if material.metallic_roughness != nil {
					if base_color_tex := material.metallic_roughness.?.base_color_texture;
					   base_color_tex != nil {
						if image_idx, ok := texture_to_image[int(base_color_tex.?.index)]; ok {
							append(
								&texture_infos,
								Gltf_Texture_Info {
									mesh_id = mesh_idx,
									texture_type = .Base_Color,
									image_index = image_idx,
								},
							)
						}
					}
					// Metallic roughness texture
					if mr_tex := material.metallic_roughness.?.metallic_roughness_texture;
					   mr_tex != nil {
						if image_idx, ok := texture_to_image[int(mr_tex.?.index)]; ok {
							append(
								&texture_infos,
								Gltf_Texture_Info {
									mesh_id = mesh_idx,
									texture_type = .Metallic_Roughness,
									image_index = image_idx,
								},
							)
						}
					}
				}

				// Normal texture
				if normal_tex := material.normal_texture; normal_tex != nil {
					if image_idx, ok := texture_to_image[int(normal_tex.?.index)]; ok {
						append(
							&texture_infos,
							Gltf_Texture_Info {
								mesh_id = mesh_idx,
								texture_type = .Normal,
								image_index = image_idx,
							},
						)
					}
				}
			}

			// Convert vec3 to vec4 (adding w=0 component)
			pos_final := to_vec4_array(positions, allocator = context.temp_allocator)
			normals_final := to_vec4_array(normals, allocator = context.temp_allocator)
			// Use TEXCOORD_0 if available, otherwise create default UVs
			uvs_final: [][2]f32
			if len(uvs) > 0 {
				uvs_final = uvs
			} else {
				// Create default UVs if not present
				uvs_final = make([][2]f32, len(positions), allocator = context.temp_allocator)
				for &uv, i in uvs_final {
					uv = {0.0, 0.0}
				}
			}

			loaded := Mesh {
				pos = slice.clone_to_dynamic(pos_final),
				normals = slice.clone_to_dynamic(normals_final),
				uvs = slice.clone_to_dynamic(uvs_final),
				indices = slice.clone_to_dynamic(indices_u32[:]),
				base_color_map = base_color_map,
				metallic_roughness_map = metallic_roughness_map,
				normal_map = normal_map,
			}
			append(&meshes, loaded)
		}
	}

	// Load instances
	instances: [dynamic]Instance
	for node_idx in data.scenes[0].nodes {
		node := data.nodes[node_idx]

		traverse_node(&instances, data, 1, int(node_idx), meshes, start_idx)

		traverse_node :: proc(
			instances: ^[dynamic]Instance,
			data: ^gltf2.Data,
			parent_transform: matrix[4, 4]f32,
			node_idx: int,
			meshes: [dynamic]Mesh,
			start_idx: [dynamic]u32,
		) {
			node := data.nodes[node_idx]

			flip_z: matrix[4, 4]f32 = 1
			flip_z[2, 2] = -1
			local_transform := xform_to_mat(node.translation, node.rotation, node.scale)
			transform := parent_transform * local_transform
			if node.mesh != nil {
				mesh_idx := node.mesh.?
				mesh := data.meshes[mesh_idx]

				for primitive, j in mesh.primitives {
					primitive_idx := start_idx[mesh_idx] + u32(j)
					instance := Instance {
						transform = flip_z * transform,
						mesh_idx  = primitive_idx,
					}
					append(instances, instance)
				}
			}

			for child in node.children {
				traverse_node(instances, data, transform, int(child), meshes, start_idx)
			}
		}
	}

	return {instances = instances, meshes = meshes}, texture_infos[:], data
}

load_texture_from_gltf :: proc(
	image_index: int,
	gltf_data: ^gltf2.Data,
) -> ^image.Image {
	image_bytes: []byte

	image_data := gltf_data.images[image_index]

	if image_data.buffer_view != nil {
		buffer_view_idx := image_data.buffer_view.?
		buffer_view := gltf_data.buffer_views[buffer_view_idx]
		buffer := gltf_data.buffers[buffer_view.buffer]

		switch v in buffer.uri {
		case []byte:
			start_byte := buffer_view.byte_offset
			end_byte := start_byte + buffer_view.byte_length
			image_bytes = v[start_byte:end_byte]
		case string:
			log.error("String URIs not supported for buffer_view images")
			panic("String URIs not supported for buffer_view images")
		case:
			log.error("Unknown buffer URI type")
			panic("Unknown buffer URI type")
		}
	} else {
		switch v in image_data.uri {
		case []byte:
			image_bytes = v
		case string:
			log.errorf("String URIs not supported for texture loading: %v", v)
			panic("String URIs not supported for texture loading")
		case:
			log.error("Image has neither buffer_view nor valid URI")
			panic("Image has neither buffer_view nor valid URI")
		}
	}

	if len(image_bytes) == 0 {
		log.error("Image bytes are empty")
		panic("Image bytes are empty")
	}

	options := image.Options{.alpha_add_if_missing}
	img, err := image.load_from_bytes(image_bytes, options)
	if err != nil {
		log.errorf(
			"Failed to load image from bytes: %v, image size: %v bytes",
			err,
			len(image_bytes),
		)
		panic("Could not load texture from GLTF image.")
	}

	return img
}

to_vec4_array :: proc(array: [][3]f32, allocator: runtime.Allocator) -> [][4]f32 {
	res := make([][4]f32, len(array), allocator = allocator)
	for &v, i in res do v = {array[i].x, array[i].y, array[i].z, 0.0}
	return res
}

xform_to_mat_f64 :: proc(pos: [3]f64, rot: quaternion256, scale: [3]f64) -> matrix[4, 4]f32 {
	return(
		cast(matrix[4, 4]f32)(#force_inline linalg.matrix4_translate(pos) *
			#force_inline linalg.matrix4_from_quaternion(rot) *
			#force_inline linalg.matrix4_scale(scale)) \
	)
}

xform_to_mat_f32 :: proc(pos: [3]f32, rot: quaternion128, scale: [3]f32) -> matrix[4, 4]f32 {
	return(
		#force_inline linalg.matrix4_translate(pos) *
		#force_inline linalg.matrix4_from_quaternion(rot) *
		#force_inline linalg.matrix4_scale(scale) \
	)
}

xform_to_mat :: proc {
	xform_to_mat_f32,
	xform_to_mat_f64,
}

transform_to_gpu_transform :: proc(transform: matrix[4, 4]f32) -> [12]f32 {
	transform_row_major := intr.transpose(transform)
	flattened := linalg.matrix_flatten(transform_row_major)
	return [12]f32 { flattened[0], flattened[1], flattened[2], flattened[3], flattened[4], flattened[5], flattened[6], flattened[7], flattened[8], flattened[9], flattened[10], flattened[11], }
}

// Basic meshes

build_sphere :: proc(radius: f32 = 0.5, lat_segments := 32, lon_segments := 32) -> (verts: [dynamic][3]f32, indices: [dynamic]u32)
{
    // Generate verts
    for lat in 0..=lat_segments
    {
        theta := math.PI * f32(lat) / f32(lat_segments)
        sin_theta := math.sin(theta)
        cos_theta := math.cos(theta)

        for lon in 0..=lon_segments
        {
            phi := 2.0 * math.PI * f32(lon) / f32(lon_segments)

			vert: [3]f32
            vert.x = radius * sin_theta * math.cos(phi)
            vert.y = radius * cos_theta
            vert.z = radius * sin_theta * math.sin(phi)
            append(&verts, vert)
        }
    }

    // Generate indices
    stride := lon_segments + 1
    for lat in 0..<lat_segments
    {
        for lon in 0..<lon_segments
        {
            a := lat * stride + lon
            b := a + stride
            c := a + 1
            d := b + 1

            append(&indices, u32(a), u32(b), u32(c))
            append(&indices, u32(c), u32(b), u32(d))
        }
    }

    return verts, indices
}

UNIT_CUBE_VERTS := [][3]f32{
    {-0.5, -0.5, -0.5},
    { 0.5, -0.5, -0.5},
    { 0.5,  0.5, -0.5},
    {-0.5,  0.5, -0.5},
    {-0.5, -0.5,  0.5},
    { 0.5, -0.5,  0.5},
    { 0.5,  0.5,  0.5},
    {-0.5,  0.5,  0.5},
}
CUBE_INDICES := []u32{
    4, 6, 5, 4, 7, 6, // Front (+Z)
    1, 3, 0, 1, 2, 3, // Back (-Z)
    0, 7, 4, 0, 3, 7, // Left (-X)
    5, 2, 1, 5, 6, 2, // Right (+X)
    3, 6, 7, 3, 2, 6, // Top (+Y)
    0, 5, 1, 0, 4, 5, // Bottom (-Y)
}
