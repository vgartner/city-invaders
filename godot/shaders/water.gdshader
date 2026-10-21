// Lake / river surface: two scrolling noise normal maps, dark teal body,
// glossy so the sky and sun reflect, a little brighter at grazing angles.
shader_type spatial;
render_mode cull_disabled;

uniform sampler2D ripples_a : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D ripples_b : hint_normal, filter_linear_mipmap, repeat_enable;
uniform vec3 deep_colour : source_color = vec3(0.04, 0.12, 0.14);
uniform vec3 sky_tint : source_color = vec3(0.32, 0.42, 0.48);

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = world_pos.xz;
	vec3 a = texture(ripples_a, p * 0.045 + TIME * vec2(0.012, 0.007)).rgb;
	vec3 b = texture(ripples_b, p * 0.11 - TIME * vec2(0.010, 0.016)).rgb;
	NORMAL_MAP = normalize(mix(a, b, 0.45) * 2.0 - 1.0) * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = 0.6;
	float fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 4.0);
	ALBEDO = mix(deep_colour, sky_tint, fresnel * 0.6);
	ROUGHNESS = 0.06;
	METALLIC = 0.0;
	SPECULAR = 0.75;
}
