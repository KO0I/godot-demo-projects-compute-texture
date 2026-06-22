shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec3 albedo : source_color;
uniform float metalic : hint_range(0.0, 1.0, 0.1) = 0.8;
uniform float roughness : hint_range(0.0, 1.0, 0.1) = 0.2;
uniform float specular : hint_range(0.0, 1.0, 0.1) = 0.5;
uniform vec3 reflection_tint : source_color = vec3(0.55, 0.85, 1.0);
uniform float reflection_strength : hint_range(0.0, 1.0, 0.01) = 0.35;
uniform float reflection_distortion : hint_range(0.0, 0.08, 0.001) = 0.018;
uniform bool mouse_reflection_enabled = false;
uniform vec2 mouse_reflection_position = vec2(0.0, 0.0);
uniform vec3 mouse_reflection_color : source_color = vec3(0.45, 0.95, 1.0);
uniform float mouse_reflection_radius : hint_range(0.02, 1.0, 0.01) = 0.22;
uniform float mouse_reflection_intensity : hint_range(0.0, 4.0, 0.01) = 1.0;
uniform sampler2D effect_texture;
uniform vec2 effect_texture_size;
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear_mipmap;

varying vec2 uv_tangent;
varying vec2 uv_binormal;
varying vec2 local_xz;

void vertex() {
	vec2 pixel_size = vec2(1.0, 1.0) / effect_texture_size;

	uv_tangent = UV + vec2(pixel_size.x, 0.0);
	uv_binormal = UV + vec2(0.0, pixel_size.y);
	local_xz = VERTEX.xz;
}

void fragment() {
	float f1 = texture(effect_texture, UV).r;
	float f2 = texture(effect_texture, uv_tangent).r;
	float f3 = texture(effect_texture, uv_binormal).r;

	vec3 tangent = normalize(vec3(1.0, 0.0, f2 - f1));
	vec3 binormal = normalize(vec3(0.0, 1.0, f3 - f1));
	NORMAL_MAP = normalize(cross(binormal, tangent)) * 0.5 + 0.5;

	vec2 wave_gradient = vec2(f2 - f1, f3 - f1);
	vec2 reflected_uv = SCREEN_UV + wave_gradient * reflection_distortion;
	vec3 screen_reflection = textureLod(screen_texture, reflected_uv, roughness * 5.0).rgb * reflection_tint;
	float fresnel = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 3.0);
	float reflection_amount = clamp(reflection_strength * (0.35 + fresnel), 0.0, 1.0);

	vec3 surface_color = mix(albedo.rgb, screen_reflection, reflection_amount);
	vec3 reflected_glow = vec3(0.0);
	if (mouse_reflection_enabled) {
		vec2 distorted_local_xz = local_xz + wave_gradient * max(reflection_distortion * 18.0, 0.05);
		float reflected_distance = length(distorted_local_xz - mouse_reflection_position);
		float core = smoothstep(mouse_reflection_radius, mouse_reflection_radius * 0.18, reflected_distance);
		float halo = smoothstep(mouse_reflection_radius * 3.2, mouse_reflection_radius, reflected_distance) * 0.35;
		reflected_glow = mouse_reflection_color * (core + halo) * mouse_reflection_intensity;
		surface_color = mix(surface_color, mouse_reflection_color, clamp(core + halo * 0.6, 0.0, 0.85));
	}

	ALBEDO = surface_color;
	EMISSION = reflected_glow;
	METALLIC = metalic;
	ROUGHNESS = roughness;
	SPECULAR = specular;
	RIM = reflection_strength * 0.35;
	RIM_TINT = 0.7;
}
