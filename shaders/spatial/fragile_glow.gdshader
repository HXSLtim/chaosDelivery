shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back;

uniform sampler2D albedo_texture : source_color, hint_default_white;
uniform vec4 base_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform vec4 glow_color : source_color = vec4(0.55, 0.82, 1.0, 1.0);
uniform float glow_intensity : hint_range(0.0, 3.0) = 0.85;
uniform float flicker_speed : hint_range(0.0, 6.0) = 1.6;
uniform float flicker_amount : hint_range(0.0, 1.0) = 0.18;
uniform float rim_power : hint_range(0.5, 8.0) = 3.2;

void fragment() {
	vec4 tex_color = texture(albedo_texture, UV) * base_color;
	float flicker = sin(TIME * flicker_speed * 6.28318) * 0.5 + 0.5;
	float flicker_multiplier = 1.0 - flicker_amount + flicker * flicker_amount;
	float rim = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), rim_power);

	ALBEDO = tex_color.rgb + glow_color.rgb * 0.12;
	EMISSION = glow_color.rgb * glow_intensity * flicker_multiplier * (0.35 + rim);
	ROUGHNESS = 0.82;
	METALLIC = 0.0;
	ALPHA = tex_color.a;
}
