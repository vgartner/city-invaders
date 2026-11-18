shader_type spatial;
// Keep the existing CC0 grass scan, break its regular repetition at larger scales.
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool use_normal = false;
uniform float normal_strength = 1.0;
uniform vec2 uv_scale = vec2(1.0);
uniform vec4 tint : source_color = vec4(1.0);
varying vec3 world_pos;
float hash(vec2 p) {return fract(sin(dot(p,vec2(127.1,311.7))) * 43758.5453);}
float noise(vec2 p) {
	vec2 i=floor(p); vec2 f=fract(p); f=f*f*(3.0-2.0*f);
	return mix(mix(hash(i),hash(i+vec2(1,0)),f.x),mix(hash(i+vec2(0,1)),hash(i+vec2(1,1)),f.x),f.y);
}
void vertex() {world_pos=(MODEL_MATRIX*vec4(VERTEX,1.0)).xyz;}
void fragment() {
	float macro=noise(world_pos.xz*0.08);
	float patch=noise(world_pos.xz*0.31);
	vec3 base=texture(albedo_tex,UV*uv_scale).rgb*tint.rgb;
	ALBEDO=base*mix(0.84,1.08,macro)*mix(vec3(1.0),vec3(1.08,0.96,0.78),smoothstep(0.5,0.8,patch)*0.5);
	if (use_normal) {NORMAL_MAP=texture(normal_tex,UV*uv_scale).rgb; NORMAL_MAP_DEPTH=normal_strength;}
	ROUGHNESS=1.0; SPECULAR=0.12;
}
