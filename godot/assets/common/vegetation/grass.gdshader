shader_type spatial;
render_mode cull_disabled;
// Opaque blade geometry: no alpha overdraw or per-blade physics.
uniform float detail_end = 28.0;
void vertex() {
	vec3 anchor = MODEL_MATRIX[3].xyz;
	float fade = 1.0 - smoothstep(detail_end - 7.0, detail_end, distance(anchor.xz, CAMERA_POSITION_WORLD.xz));
	float tip = UV.y;
	VERTEX *= fade;
	float wind = sin(TIME * 1.7 + anchor.x * 0.7 + anchor.z * 0.35);
	VERTEX.x += wind * tip * tip * 0.025 * fade;
}
void fragment() {
	ALBEDO = COLOR.rgb;
	ROUGHNESS = 1.0;
	SPECULAR = 0.12;
	BACKLIGHT = COLOR.rgb * 0.18;
}
