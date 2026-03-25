shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back;

uniform sampler2D albedo_texture : source_color, hint_default_white;
uniform vec4 base_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform vec4 pulse_color : source_color = vec4(1.0, 0.28, 0.12, 1.0);
uniform float pulse_speed : hint_range(0.5, 8.0) = 2.4;
uniform float pulse_min : hint_range(0.0, 2.0) = 0.35;
uniform float pulse_max : hint_range(0.0, 3.5) = 1.5;
uniform float rim_power : hint_range(0.5, 8.0) = 2.4;

void fragment() {
	vec4 tex_color = texture(albedo_texture, UV) * base_color;
	float pulse = sin(TIME * pulse_speed * 6.28318) * 0.5 + 0.5;
	float pulse_value = mix(pulse_min, pulse_max, pulse);
	float rim = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), rim_power);

	ALBEDO = tex_color.rgb * (1.0 + pulse * 0.12);
	EMISSION = pulse_color.rgb * pulse_value * (0.45 + rim);
	ROUGHNESS = 0.72;
	METALLIC = 0.0;
	ALPHA = tex_color.a;
}
