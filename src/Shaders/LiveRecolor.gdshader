shader_type texture_blit;
render_mode blend_disabled;

uniform sampler2D source_texture0 : hint_blit_source0, filter_nearest;
uniform vec4 target_color;

void blit() {
	vec4 original = texture(source_texture0, UV);
	COLOR0 = original.a > 0.0 ? target_color : original;
}
