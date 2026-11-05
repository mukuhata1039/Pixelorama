shader_type texture_blit;
render_mode blend_disabled;

uniform sampler2D source_texture0 : hint_blit_source0, filter_nearest;
uniform vec4 target_color;
uniform bool preserve_alpha = false;

void blit() {
	vec4 original = texture(source_texture0, UV);
	if (original.a > 0.0) {
		float alpha = preserve_alpha ? original.a * target_color.a : target_color.a;
		COLOR0 = vec4(target_color.rgb, alpha);
	}
	else {
		COLOR0 = original;
	}
}
