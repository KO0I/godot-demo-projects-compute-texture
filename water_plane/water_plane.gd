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

@export var rain_size : float = 3.0
@export var mouse_size : float = 5.0
@export var texture_size : Vector2i = Vector2i(512, 512)
@export_range(1.0, 10.0, 0.1) var damping : float = 1.0

var t = 0.0
var max_t = 0.1

var texture : Texture2DRD
var next_texture : int = 0

var add_wave_point : Vector4
var mouse_pos : Vector2
var mouse_pressed : bool = false

# Called when the node enters the scene tree for the first time.
func _ready():
	# In case we're running stuff on the rendering thread
	# we need to do our initialisation on that thread.
	RenderingServer.call_on_render_thread(_initialize_compute_code.bind(texture_size))

	# Get our texture from our material so we set our RID.
	var material : ShaderMaterial = $MeshInstance3D.material_override
	if material:
		material.set_shader_parameter("effect_texture_size", texture_size)

		# Get our texture object.
		texture = material.get_shader_parameter("effect_texture")


func _exit_tree():
	# Make sure we clean up!
	if texture:
		texture.texture_rd_rid = RID()

	RenderingServer.call_on_render_thread(_free_compute_resources)


func _unhandled_input(event):
	# If tool enabled, we don't want to handle our input in the editor.
	if Engine.is_editor_hint():
		return

	if event is InputEventMouseMotion or event is InputEventMouseButton:
		mouse_pos = event.global_position

	if event is InputEventMouseButton and event.button_index == MouseButton.MOUSE_BUTTON_LEFT:
		mouse_pressed = event.pressed


func _check_mouse_pos():
	# This is a mouse event, do a raycast.
	var camera = get_viewport().get_camera_3d()

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
	else:
		add_wave_point.x = 0.0
		add_wave_point.y = 0.0
		add_wave_point.w = 0.0


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta):
	# If tool is enabled, ignore mouse input.
	if Engine.is_editor_hint():
		add_wave_point.w = 0.0
	else:
		# Check where our mouse intersects our area, can change if things move.
		_check_mouse_pos()

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
		add_wave_point.z = mouse_size if mouse_pressed else 0.0

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

###############################################################################
# Everything after this point is designed to run on our rendering thread.

var rd : RenderingDevice

var shader : RID
var pipeline : RID
var compute_ready : bool = false

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
