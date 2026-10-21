// A flag waving in the wind: the cloth runs along local +X from the pole;
// travelling waves across it, growing towards the free end.
shader_type spatial;
render_mode cull_disabled;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform bool use_texture = true;
uniform float pole_x = 0.04;
uniform float cloth_length = 1.8;
uniform float amplitude = 0.13;
uniform float speed = 4.2;
uniform float wave_number = 3.4;

void vertex() {
	float d = clamp((VERTEX.x - pole_x) / cloth_length, 0.0, 1.0);
	float phase = VERTEX.x * wave_number - TIME * speed + VERTEX.y * 0.9;
	VERTEX.z += sin(phase) * amplitude * d;
	VERTEX.y += sin(phase * 0.6 + 1.3) * 0.025 * d;
	// tilt the normal with the slope of the wave so the folds catch the light
	float slope = cos(phase) * wave_number * amplitude * d;
	NORMAL = normalize(NORMAL + vec3(-slope * sign(NORMAL.z + 1e-4), 0.0, 0.0));
}

void fragment() {
	vec4 c = use_texture ? texture(albedo_tex, UV) * albedo_color : albedo_color;
	ALBEDO = c.rgb;
	ROUGHNESS = 0.85;
	SPECULAR = 0.2;
}
