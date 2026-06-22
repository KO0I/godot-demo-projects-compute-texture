extends Node3D

# Note, the code here just adds some control to our effects.
# Check res://water_plane/water_plane.gd for the real implementation.

var y = 0.0

@onready var water_plane = $WaterPlane

func _ready():
	var reflection_menu := $Container/ReflectionPreset/OptionButton
	reflection_menu.clear()
	for preset_name in $WaterPlane.get_reflection_preset_names():
		reflection_menu.add_item(preset_name)
	reflection_menu.select($WaterPlane.reflection_preset)

	$Container/RainSize/HSlider.value = $WaterPlane.rain_size
	$Container/MouseSize/HSlider.value = $WaterPlane.mouse_size
	$Container/SphereShine/HSlider.value = $WaterPlane.sphere_shine
	_update_rain_size_label($WaterPlane.rain_size)
	_update_mouse_size_label($WaterPlane.mouse_size)
	_update_sphere_shine_label($WaterPlane.sphere_shine)
	_update_sphere_speed_label()


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta):
	if $Container/Rotate.button_pressed:
		y += delta
		water_plane.basis = Basis(Vector3.UP, y)
	_update_sphere_speed_label()


func _on_rain_size_changed(value):
	$WaterPlane.rain_size = value
	_update_rain_size_label(value)


func _on_mouse_size_changed(value):
	$WaterPlane.mouse_size = value
	_update_mouse_size_label(value)


func _on_sphere_shine_changed(value):
	$WaterPlane.sphere_shine = value
	_update_sphere_shine_label(value)


func _update_sphere_shine_label(value):
	$Container/SphereShine/Value.text = "%0.2f" % value


func _update_rain_size_label(value):
	$Container/RainSize/Value.text = "%0.1f" % value


func _update_mouse_size_label(value):
	$Container/MouseSize/Value.text = "%0.1f" % value


func _update_sphere_speed_label():
	$Container/SphereSpeed/Value.text = "%0.2f" % $WaterPlane.sphere_speed


func _on_reflection_preset_selected(index):
	$WaterPlane.apply_reflection_preset(index)
