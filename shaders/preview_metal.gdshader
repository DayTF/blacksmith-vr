shader_type spatial;
render_mode cull_disabled;

varying float thermal_emission;

void vertex() {
	thermal_emission = UV2.x;
}

void fragment() {
	ALBEDO = COLOR.rgb;
	METALLIC = 0.65;
	ROUGHNESS = 0.4;
	EMISSION = COLOR.rgb * thermal_emission;
}
