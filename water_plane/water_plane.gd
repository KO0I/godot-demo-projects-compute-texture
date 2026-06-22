@tool
extends Area3D

############################################################################
# Water ripple effect shader - Bastiaan Olij
#
# This is an example of how to implement a more complex compute shader
# in Godot and making use of the new Custom Texture RD API added to
# the RenderingServer.
#
# If thread model is set to Multi-Threaded the code related to compute will
# run on the render thread. This is needed as we want to add our logic to
# the normal rendering pipeline for this thread.
#
# The effect itself is an implementation of the classic ripple effect
# that has been around since the 90ies but in a compute shader.
# If someone knows if the original author ever published a paper I could
# quote, please let me know :)

const INDICATOR_SPHERE_RADIUS := 0.045
const INDICATOR_SPHERE_DIAMETER := INDICATOR_SPHERE_RADIUS * 2.0
const DEFAULT_SPHERE_HEIGHT := 0.16
const MIN_SPHERE_HEIGHT := -1.5
const MAX_SPHERE_HEIGHT := 1.5
const RIGHT_DRAG_HEIGHT_PER_PIXEL := 0.006
const IMPACT_SPEED_MULTIPLIER := 0.5
const MAX_IMPACT_MULTIPLIER := 4.0
const CONTACT_WAVE_DELAY_FRAMES := 4
const CONTACT_WAVE_MIN_SIZE := 1.0
const SHOCK_CONE_SEGMENTS := 48
const SHOCK_CONE_LENGTH := 0.52
const SHOCK_CONE_START_RADIUS := 0.075
const SHOCK_CONE_END_RADIUS := 0.34
const SHOCK_CONE_MOVEMENT_THRESHOLD := 0.003
const SHOCK_CONE_VISIBLE_SPEED := 0.35

@export var rain_size : float = 3.0
@export var mouse_size : float = 5.0
@export_range(0.0, 1.0, 0.01) var sphere_shine : float = 1.0:
	set(value):
		sphere_shine = clampf(value, 0.0, 1.0)
		_apply_sphere_shine()
@export var texture_size : Vector2i = Vector2i(512, 512)
@export_range(1.0, 10.0, 0.1) var damping : float = 1.0
@export_enum("Original", "Matte Water", "Glossy Water", "Mirror", "Metallic") var reflection_preset : int = 0

var t = 0.0
var max_t = 0.1

var texture : Texture2DRD
var next_texture : int = 0

var add_wave_point : Vector4
var mouse_pos : Vector2
var mouse_pressed : bool = false
var mouse_indicator : MeshInstance3D
var mouse_indicator_reflection : MeshInstance3D
var shock_cone : MeshInstance3D
var mouse_indicator_local_position : Vector3
var right_dragging_indicator : bool = false
var sphere_height : float = DEFAULT_SPHERE_HEIGHT
var pending_surface_impact_size : float = 0.0
var last_sphere_height_update_usec : int = 0
var sphere_intersecting_surface : bool = false
var contact_wave_delay_frames_remaining : int = 0
var pending_contact_wave_size : float = 0.0
var last_sphere_center : Vector3
var has_last_sphere_center : bool = false
var sphere_speed : float = 0.0

# Called when the node enters the scene tree for the first time.
func _ready():
	_ensure_mouse_indicator()

	compute_supported = RenderingServer.get_rendering_device() != null
	if compute_supported:
		# In case we're running stuff on the rendering thread
		# we need to do our initialisation on that thread.
		RenderingServer.call_on_render_thread(_initialize_compute_code.bind(texture_size))
	else:
		push_warning("RenderingDevice is unavailable; water compute shader will not run in this context.")

	# Get our texture from our material so we set our RID.
	var material : ShaderMaterial = $MeshInstance3D.material_override
	if material:
		material.set_shader_parameter("effect_texture_size", texture_size)
		apply_reflection_preset(reflection_preset)

		# Get our texture object.
		texture = material.get_shader_parameter("effect_texture")


func get_reflection_preset_names() -> PackedStringArray:
	return PackedStringArray([
		"Original",
		"Matte Water",
		"Glossy Water",
		"Mirror",
		"Metallic"
	])


func apply_reflection_preset(preset_index : int):
	reflection_preset = clampi(preset_index, 0, get_reflection_preset_names().size() - 1)

	var material : ShaderMaterial = $MeshInstance3D.material_override
	if not material:
		return

	var values := _get_reflection_preset_values(reflection_preset)
	for parameter_name in values:
		material.set_shader_parameter(parameter_name, values[parameter_name])


func _get_reflection_preset_values(preset_index : int) -> Dictionary:
	match preset_index:
		1:
			return {
				"metalic": 0.0,
				"roughness": 0.65,
				"specular": 0.25,
				"reflection_tint": Color(0.35, 0.55, 0.65, 1.0),
				"reflection_strength": 0.08,
				"reflection_distortion": 0.01
			}
		2:
			return {
				"metalic": 0.0,
				"roughness": 0.08,
				"specular": 0.85,
				"reflection_tint": Color(0.65, 0.9, 1.0, 1.0),
				"reflection_strength": 0.55,
				"reflection_distortion": 0.02
			}
		3:
			return {
				"metalic": 0.0,
				"roughness": 0.0,
				"specular": 1.0,
				"reflection_tint": Color(1.0, 1.0, 1.0, 1.0),
				"reflection_strength": 0.9,
				"reflection_distortion": 0.006
			}
		4:
			return {
				"metalic": 1.0,
				"roughness": 0.12,
				"specular": 0.9,
				"reflection_tint": Color(0.9, 0.95, 1.0, 1.0),
				"reflection_strength": 0.7,
				"reflection_distortion": 0.012
			}
		_:
			return {
				"metalic": 1.0,
				"roughness": 0.0,
				"specular": 0.5,
				"reflection_tint": Color(0.55, 0.85, 1.0, 1.0),
				"reflection_strength": 0.35,
				"reflection_distortion": 0.018
			}


func _exit_tree():
	# Make sure we clean up!
	if compute_supported and texture:
		texture.texture_rd_rid = RID()

	if compute_supported:
		RenderingServer.call_on_render_thread(_free_compute_resources)


func _unhandled_input(event):
	# If tool enabled, we don't want to handle our input in the editor.
	if Engine.is_editor_hint():
		return

	if event is InputEventMouseMotion or event is InputEventMouseButton:
		mouse_pos = event.global_position

	if event is InputEventMouseMotion and right_dragging_indicator:
		set_sphere_height(sphere_height - event.relative.y * RIGHT_DRAG_HEIGHT_PER_PIXEL)

	if event is InputEventMouseButton and event.button_index == MouseButton.MOUSE_BUTTON_LEFT:
		mouse_pressed = event.pressed
		if not mouse_pressed:
			_set_shock_cone_visible(false)
			has_last_sphere_center = false
			sphere_speed = 0.0
	elif event is InputEventMouseButton and event.button_index == MouseButton.MOUSE_BUTTON_RIGHT:
		right_dragging_indicator = event.pressed


func _check_mouse_pos():
	# This is a mouse event, do a raycast.
	var camera = get_viewport().get_camera_3d()
	if camera == null:
		_set_mouse_indicator_visible(false)
		return

	var parameters = PhysicsRayQueryParameters3D.new()
	parameters.from = camera.project_ray_origin(mouse_pos)
	parameters.to = parameters.from + camera.project_ray_normal(mouse_pos) * 100.0
	parameters.collision_mask = 1
	parameters.collide_with_bodies = false
	parameters.collide_with_areas = true

	var result = get_world_3d().direct_space_state.intersect_ray(parameters)
	if result.size() > 0:
		# Transform our intersection point.
		var pos = global_transform.affine_inverse() * result.position
		add_wave_point.x = clamp(pos.x / 5.0, -0.5, 0.5) * texture_size.x + 0.5 * texture_size.x
		add_wave_point.y = clamp(pos.z / 5.0, -0.5, 0.5) * texture_size.y + 0.5 * texture_size.y
		add_wave_point.w = 1.0 # We have w left over so we use it to indicate mouse is over our water plane.
		_update_mouse_indicator(pos)
	else:
		add_wave_point.x = 0.0
		add_wave_point.y = 0.0
		add_wave_point.w = 0.0
		_set_mouse_indicator_visible(false)


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta):
	# If tool is enabled, ignore mouse input.
	if Engine.is_editor_hint():
		add_wave_point.w = 0.0
	else:
		# Check where our mouse intersects our area, can change if things move.
		_check_mouse_pos()
		_update_surface_contact_wave()
		_update_shock_cone(delta)

	# If we're not using the mouse, animate water drops, we (ab)used our W for this.
	if add_wave_point.w == 0.0:
		t += delta
		if t > max_t:
			t = 0
			add_wave_point.x = randi_range(0, texture_size.x)
			add_wave_point.y = randi_range(0, texture_size.y)
			add_wave_point.z = rain_size
		else:
			add_wave_point.z = 0.0
	else:
		add_wave_point.z = mouse_size if mouse_pressed and _can_sphere_make_mouse_ripples() else 0.0
		_set_mouse_indicator_pressed(mouse_pressed)

	if pending_surface_impact_size > 0.0 and add_wave_point.w > 0.0:
		add_wave_point.z = maxf(add_wave_point.z, pending_surface_impact_size)
		pending_surface_impact_size = 0.0

	if pending_contact_wave_size > 0.0 and add_wave_point.w > 0.0:
		add_wave_point.z = maxf(add_wave_point.z, pending_contact_wave_size)
		pending_contact_wave_size = 0.0

	if compute_supported:
		# Increase our next texture index.
		next_texture = (next_texture + 1) % 3

		# Update our texture to show our next result (we are about to create).
		# Note that `_initialize_compute_code` may not have run yet so the first
		# frame this may be an empty RID.
		if texture and texture_rds[next_texture].is_valid():
			texture.texture_rd_rid = texture_rds[next_texture]

		# While our render_process may run on the render thread it will run before our texture
		# is used and thus our next_rd will be populated with our next result.
		# It's probably overkill to send texture_size and damping as parameters as these are static
		# but we send add_wave_point as it may be modified while process runs in parallel.
		RenderingServer.call_on_render_thread(_render_process.bind(next_texture, add_wave_point, texture_size, damping))


func _ensure_mouse_indicator():
	mouse_indicator = get_node_or_null("MouseIndicator") as MeshInstance3D
	if mouse_indicator == null:
		mouse_indicator = MeshInstance3D.new()
		mouse_indicator.name = "MouseIndicator"
		mouse_indicator.mesh = SphereMesh.new()
		mouse_indicator.mesh.radius = INDICATOR_SPHERE_RADIUS
		mouse_indicator.mesh.height = INDICATOR_SPHERE_DIAMETER
		mouse_indicator.material_override = _create_indicator_material(Color(0.45, 0.95, 1.0, 1.0), 2.8)
		mouse_indicator.visible = false
		add_child(mouse_indicator)

	mouse_indicator_reflection = get_node_or_null("MouseIndicatorReflection") as MeshInstance3D
	if mouse_indicator_reflection == null:
		mouse_indicator_reflection = MeshInstance3D.new()
		mouse_indicator_reflection.name = "MouseIndicatorReflection"
		mouse_indicator_reflection.visible = false
		add_child(mouse_indicator_reflection)

	var reflection_mesh := SphereMesh.new()
	reflection_mesh.radius = INDICATOR_SPHERE_RADIUS
	reflection_mesh.height = INDICATOR_SPHERE_DIAMETER
	mouse_indicator_reflection.mesh = reflection_mesh
	mouse_indicator_reflection.scale = Vector3(1.0, 0.55, 1.0)
	mouse_indicator_reflection.material_override = _create_reflection_material()

	shock_cone = get_node_or_null("ShockCone") as MeshInstance3D
	if shock_cone == null:
		shock_cone = MeshInstance3D.new()
		shock_cone.name = "ShockCone"
		shock_cone.visible = false
		add_child(shock_cone)

	shock_cone.mesh = _create_shock_cone_mesh()
	shock_cone.material_override = _create_shock_cone_material()
	_apply_sphere_shine()


func _create_indicator_material(color : Color, energy : float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.emission_enabled = sphere_shine > 0.001
	material.emission = color
	material.emission_energy_multiplier = energy * sphere_shine
	material.roughness = _get_sphere_roughness()
	return material


func _create_reflection_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(0.25, 0.9, 1.0, 0.34)
	material.emission_enabled = sphere_shine > 0.001
	material.emission = Color(0.25, 0.9, 1.0, 1.0)
	material.emission_energy_multiplier = 1.5 * sphere_shine
	material.roughness = 0.0
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return material


func _create_shock_cone_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(0.74, 0.94, 1.0, 0.28)
	material.emission_enabled = true
	material.emission = Color(0.55, 0.9, 1.0, 1.0)
	material.emission_energy_multiplier = 0.7
	material.roughness = 0.35
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material


func _create_shock_cone_mesh() -> ArrayMesh:
	var vertices := PackedVector3Array()
	var indices := PackedInt32Array()

	for index in range(SHOCK_CONE_SEGMENTS):
		var angle := TAU * float(index) / float(SHOCK_CONE_SEGMENTS)
		var ring_direction := Vector3(cos(angle), sin(angle), 0.0)
		vertices.append(ring_direction * SHOCK_CONE_START_RADIUS)
		vertices.append(ring_direction * SHOCK_CONE_END_RADIUS + Vector3(0.0, 0.0, -SHOCK_CONE_LENGTH))

	for index in range(SHOCK_CONE_SEGMENTS):
		var next_index := (index + 1) % SHOCK_CONE_SEGMENTS
		var near_a := index * 2
		var far_a := near_a + 1
		var near_b := next_index * 2
		var far_b := near_b + 1
		indices.append_array(PackedInt32Array([near_a, near_b, far_a, near_b, far_b, far_a]))

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _update_mouse_indicator(local_position : Vector3):
	if mouse_indicator == null or mouse_indicator_reflection == null:
		return

	var clamped_position := Vector3(
		clamp(local_position.x, -2.5, 2.5),
		0.0,
		clamp(local_position.z, -2.5, 2.5)
	)
	mouse_indicator_local_position = clamped_position
	mouse_indicator.position = clamped_position + Vector3(0.0, sphere_height, 0.0)
	mouse_indicator_reflection.position = clamped_position + Vector3(0.0, -sphere_height, 0.0)
	_update_mouse_reflection_shader(true)
	_set_mouse_indicator_visible(true)


func _set_mouse_indicator_visible(is_visible : bool):
	if mouse_indicator:
		mouse_indicator.visible = is_visible
	if mouse_indicator_reflection:
		mouse_indicator_reflection.visible = is_visible and _should_show_sphere_reflection()
	if shock_cone and not is_visible:
		_set_shock_cone_visible(false)
	if not is_visible:
		pending_surface_impact_size = 0.0
		pending_contact_wave_size = 0.0
		sphere_intersecting_surface = false
		contact_wave_delay_frames_remaining = 0
		has_last_sphere_center = false
	_update_mouse_reflection_shader(is_visible)


func _set_mouse_indicator_pressed(is_pressed : bool):
	if mouse_indicator == null:
		return

	_apply_sphere_shine()


func _update_mouse_reflection_shader(is_visible : bool):
	var material := $MeshInstance3D.material_override as ShaderMaterial
	if not material:
		return

	material.set_shader_parameter("mouse_reflection_enabled", is_visible and sphere_shine > 0.001 and _should_show_sphere_reflection())
	material.set_shader_parameter("mouse_reflection_position", Vector2(mouse_indicator_local_position.x, mouse_indicator_local_position.z))
	material.set_shader_parameter("mouse_reflection_color", Color(0.85, 1.0, 1.0, 1.0) if mouse_pressed else Color(0.45, 0.95, 1.0, 1.0))
	material.set_shader_parameter("mouse_reflection_intensity", (1.85 if mouse_pressed else 1.0) * sphere_shine)


func set_sphere_height(value : float):
	var old_height := sphere_height
	var new_height := clampf(value, MIN_SPHERE_HEIGHT, MAX_SPHERE_HEIGHT)
	var now_usec := Time.get_ticks_usec()
	var elapsed_seconds := 1.0 / 60.0
	if last_sphere_height_update_usec > 0:
		elapsed_seconds = maxf(float(now_usec - last_sphere_height_update_usec) / 1000000.0, 1.0 / 240.0)

	last_sphere_height_update_usec = now_usec
	sphere_height = new_height
	_queue_surface_crossing_impact(old_height, new_height, absf(new_height - old_height) / elapsed_seconds)

	if mouse_indicator:
		mouse_indicator.position.y = sphere_height
	if mouse_indicator_reflection:
		mouse_indicator_reflection.position.y = -sphere_height
		mouse_indicator_reflection.visible = mouse_indicator.visible and _should_show_sphere_reflection()
	_update_mouse_reflection_shader(mouse_indicator.visible if mouse_indicator else false)


func _queue_surface_crossing_impact(old_height : float, new_height : float, vertical_speed : float):
	if not _sphere_crossed_surface(old_height, new_height):
		return
	if mouse_indicator and not mouse_indicator.visible:
		return

	pending_surface_impact_size = maxf(pending_surface_impact_size, _get_sphere_surface_impact_size(vertical_speed))


func _sphere_crossed_surface(old_height : float, new_height : float) -> bool:
	var entered_from_above := old_height > INDICATOR_SPHERE_RADIUS and new_height <= INDICATOR_SPHERE_RADIUS
	var entered_from_below := old_height < -INDICATOR_SPHERE_RADIUS and new_height >= -INDICATOR_SPHERE_RADIUS
	var exited_above := old_height <= INDICATOR_SPHERE_RADIUS and new_height > INDICATOR_SPHERE_RADIUS
	var exited_below := old_height >= -INDICATOR_SPHERE_RADIUS and new_height < -INDICATOR_SPHERE_RADIUS
	return entered_from_above or entered_from_below or exited_above or exited_below


func _update_surface_contact_wave():
	var intersects_surface := add_wave_point.w > 0.0 and absf(sphere_height) <= INDICATOR_SPHERE_RADIUS
	if not intersects_surface:
		sphere_intersecting_surface = false
		contact_wave_delay_frames_remaining = 0
		return

	if not sphere_intersecting_surface:
		sphere_intersecting_surface = true
		contact_wave_delay_frames_remaining = CONTACT_WAVE_DELAY_FRAMES

	if contact_wave_delay_frames_remaining > 0:
		contact_wave_delay_frames_remaining -= 1
		return

	pending_contact_wave_size = maxf(pending_contact_wave_size, _get_surface_contact_wave_size())


func _update_shock_cone(delta : float):
	if mouse_indicator == null or shock_cone == null or not mouse_indicator.visible or sphere_height < 0.0:
		_set_shock_cone_visible(false)
		has_last_sphere_center = false
		sphere_speed = 0.0
		return

	var sphere_center := _get_sphere_center()
	if not has_last_sphere_center:
		last_sphere_center = sphere_center
		has_last_sphere_center = true
		sphere_speed = 0.0
		_set_shock_cone_visible(false)
		return

	var movement := sphere_center - last_sphere_center
	last_sphere_center = sphere_center
	var movement_distance := movement.length()
	var speed := movement_distance / maxf(delta, 0.0001)
	sphere_speed = speed
	if not mouse_pressed or movement_distance < SHOCK_CONE_MOVEMENT_THRESHOLD or speed < SHOCK_CONE_VISIBLE_SPEED:
		_set_shock_cone_visible(false)
		return

	var movement_direction := movement / movement_distance
	var intensity := clampf((speed - SHOCK_CONE_VISIBLE_SPEED) * 0.75, 0.0, 1.0)
	shock_cone.position = sphere_center - movement_direction * INDICATOR_SPHERE_RADIUS * 0.4
	shock_cone.basis = _basis_from_forward(movement_direction)
	shock_cone.scale = Vector3.ONE * lerpf(0.65, 1.2, intensity)

	var material := shock_cone.material_override as StandardMaterial3D
	if material:
		material.albedo_color = Color(0.74, 0.94, 1.0, lerpf(0.12, 0.34, intensity))
		material.emission_energy_multiplier = lerpf(0.25, 1.1, intensity)

	_set_shock_cone_visible(true)


func _set_shock_cone_visible(is_visible : bool):
	if shock_cone:
		shock_cone.visible = is_visible


func _get_sphere_center() -> Vector3:
	return mouse_indicator_local_position + Vector3(0.0, sphere_height, 0.0)


func _basis_from_forward(forward : Vector3) -> Basis:
	var z_axis := forward.normalized()
	var up_axis := Vector3.UP
	if absf(z_axis.dot(up_axis)) > 0.95:
		up_axis = Vector3.RIGHT
	var x_axis := up_axis.cross(z_axis).normalized()
	var y_axis := z_axis.cross(x_axis).normalized()
	return Basis(x_axis, y_axis, z_axis)


func _get_sphere_roughness() -> float:
	return lerpf(1.0, 0.15, sphere_shine)


func _should_show_sphere_reflection() -> bool:
	return sphere_height >= 0.0


func _can_sphere_make_mouse_ripples() -> bool:
	return sphere_height >= 0.0 or absf(sphere_height) <= INDICATOR_SPHERE_RADIUS


func _get_sphere_surface_impact_size(vertical_speed : float) -> float:
	var base_impact := INDICATOR_SPHERE_DIAMETER / 5.0 * float(mini(texture_size.x, texture_size.y))
	var speed_multiplier := clampf(1.0 + vertical_speed * IMPACT_SPEED_MULTIPLIER, 1.0, MAX_IMPACT_MULTIPLIER)
	return base_impact * speed_multiplier


func _get_surface_contact_wave_size() -> float:
	var middle_weight := 1.0 - clampf(absf(sphere_height) / INDICATOR_SPHERE_RADIUS, 0.0, 1.0)
	middle_weight = smoothstep(0.0, 1.0, middle_weight)
	return lerpf(minf(CONTACT_WAVE_MIN_SIZE, mouse_size), mouse_size, middle_weight)


func _apply_sphere_shine():
	var emits := sphere_shine > 0.001

	if mouse_indicator:
		var material := mouse_indicator.material_override as StandardMaterial3D
		if material:
			var color := Color(0.85, 1.0, 1.0, 1.0) if mouse_pressed else Color(0.45, 0.95, 1.0, 1.0)
			material.albedo_color = color
			material.emission = color
			material.emission_enabled = emits
			material.emission_energy_multiplier = (5.0 if mouse_pressed else 2.8) * sphere_shine
			material.roughness = _get_sphere_roughness()

	if mouse_indicator_reflection:
		var reflection_material := mouse_indicator_reflection.material_override as StandardMaterial3D
		if reflection_material:
			var reflection_color := Color(0.55, 1.0, 1.0, 0.48) if mouse_pressed else Color(0.25, 0.9, 1.0, 0.32)
			reflection_material.albedo_color = reflection_color
			reflection_material.emission = Color(reflection_color.r, reflection_color.g, reflection_color.b, 1.0)
			reflection_material.emission_enabled = emits
			reflection_material.emission_energy_multiplier = (2.6 if mouse_pressed else 1.4) * sphere_shine

	if is_inside_tree():
		_update_mouse_reflection_shader(mouse_indicator.visible if mouse_indicator else false)

###############################################################################
# Everything after this point is designed to run on our rendering thread.

var rd : RenderingDevice

var shader : RID
var pipeline : RID
var compute_ready : bool = false
var compute_supported : bool = false

# We use 3 textures:
# - One to render into
# - One that contains the last frame rendered
# - One for the frame before that
var texture_rds : Array = [ RID(), RID(), RID() ]
var texture_sets : Array = [
	[ RID(), RID(), RID() ],
	[ RID(), RID(), RID() ],
	[ RID(), RID(), RID() ]
]

func _create_uniform_set(texture_rd : RID, set_index : int) -> RID:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = 0
	uniform.add_id(texture_rd)
	var uniform_set := rd.uniform_set_create([uniform], shader, set_index)
	if not uniform_set.is_valid():
		push_error("Failed to create water compute uniform set %d. Check water_compute.glsl set/binding declarations." % set_index)
	return uniform_set


func _initialize_compute_code(init_with_texture_size):
	compute_ready = false

	# As this becomes part of our normal frame rendering,
	# we use our main rendering device here.
	rd = RenderingServer.get_rendering_device()
	if rd == null:
		push_warning("RenderingDevice is unavailable; water compute shader will not run in this context.")
		return

	# Create our shader.
	var shader_file = load("res://water_plane/water_compute.glsl")
	if shader_file == null:
		push_error("Failed to load water compute shader resource.")
		return

	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
	if shader_spirv == null:
		push_error("Failed to get SPIR-V from water compute shader resource.")
		return

	shader = rd.shader_create_from_spirv(shader_spirv)
	if not shader.is_valid():
		push_error("Failed to create water compute shader from SPIR-V.")
		return

	pipeline = rd.compute_pipeline_create(shader)
	if not pipeline.is_valid():
		push_error("Failed to create water compute pipeline.")
		return

	# Create our textures to manage our wave.
	var tf : RDTextureFormat = RDTextureFormat.new()
	tf.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	tf.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	tf.width = init_with_texture_size.x
	tf.height = init_with_texture_size.y
	tf.depth = 1
	tf.array_layers = 1
	tf.mipmaps = 1
	tf.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT + RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT + RenderingDevice.TEXTURE_USAGE_STORAGE_BIT + RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT + RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT

	for i in range(3):
		# Create our texture.
		texture_rds[i] = rd.texture_create(tf, RDTextureView.new(), [])

		# Make sure our textures are cleared.
		rd.texture_clear(texture_rds[i], Color(0, 0, 0, 0), 0, 1, 0, 1)

		# Create one uniform set per shader set, because each texture RID rotates
		# through current, previous, and output bindings over time.
		for set_index in range(3):
			texture_sets[i][set_index] = _create_uniform_set(texture_rds[i], set_index)
			if not texture_sets[i][set_index].is_valid():
				return

	compute_ready = true


func _render_process(with_next_texture, wave_point, tex_size, wave_damping):
	if not compute_ready or rd == null or not pipeline.is_valid():
		return

	# We don't have structures (yet) so we need to build our push constant
	# "the hard way"...
	var push_constant : PackedFloat32Array = PackedFloat32Array()
	push_constant.push_back(wave_point.x)
	push_constant.push_back(wave_point.y)
	push_constant.push_back(wave_point.z)
	push_constant.push_back(wave_point.w)

	push_constant.push_back(tex_size.x)
	push_constant.push_back(tex_size.y)
	push_constant.push_back(wave_damping)
	push_constant.push_back(0.0)

	# Calculate our dispatch group size.
	# We do `n - 1 / 8 + 1` in case our texture size is not nicely
	# divisible by 8.
	# In combination with a discard check in the shader this ensures
	# we cover the entire texture.
	var x_groups = (tex_size.x - 1) / 8 + 1
	var y_groups = (tex_size.y - 1) / 8 + 1

	var next_set = texture_sets[with_next_texture][2]
	var current_set = texture_sets[(with_next_texture - 1) % 3][0]
	var previous_set = texture_sets[(with_next_texture - 2) % 3][1]

	# Run our compute shader.
	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, current_set, 0)
	rd.compute_list_bind_uniform_set(compute_list, previous_set, 1)
	rd.compute_list_bind_uniform_set(compute_list, next_set, 2)
	rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4)
	rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)
	rd.compute_list_end()

	# We don't need to sync up here, Godots default barriers will do the trick.
	# If you want the output of a compute shader to be used as input of
	# another computer shader you'll need to add a barrier:
	#rd.barrier(RenderingDevice.BARRIER_MASK_COMPUTE)


func _free_compute_resources():
	compute_ready = false
	if rd == null:
		return

	# Note that our sets and pipeline are cleaned up automatically as they are dependencies :P
	for i in range(3):
		if texture_rds[i]:
			rd.free_rid(texture_rds[i])

	if shader:
		rd.free_rid(shader)
