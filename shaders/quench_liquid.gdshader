shader_type spatial;
render_mode cull_back;

uniform sampler2D opaque_color : hint_screen_texture, repeat_disable, filter_linear;
uniform sampler2D opaque_depth : hint_depth_texture, repeat_disable, filter_nearest;
uniform vec3 liquid_color : source_color = vec3(0.06, 0.30, 0.34);
uniform float absorption = 5.0;
uniform float surface_roughness = 0.18;
uniform float ripple_strength = 0.065;
uniform float ripple_speed = 2.0;

varying vec2 tank_position;

void vertex() {
	tank_position = VERTEX.xz;
}

void fragment() {
	vec2 ripple = vec2(
		sin(dot(tank_position, vec2(31.0, 17.0)) - TIME * ripple_speed),
		sin(dot(tank_position, vec2(-19.0, 37.0)) + TIME * ripple_speed * 0.78)
	) * ripple_strength;
	NORMAL = normalize(NORMAL + mat3(VIEW_MATRIX) * vec3(ripple.x, 0.0, ripple.y));
	float depth = texture(opaque_depth, SCREEN_UV).r;
	vec4 behind = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	float distance_in_liquid = max(0.0, VERTEX.z - behind.z / max(behind.w, 0.00001));
	float transmission = exp(-absorption * distance_in_liquid);
	float fresnel = 0.02 + 0.98 * pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 5.0);
	ALBEDO = liquid_color * mix(0.22, 0.85, fresnel);
	ROUGHNESS = surface_roughness;
	SPECULAR = 0.35;
	vec3 reflected = mat3(INV_VIEW_MATRIX) * reflect(-VIEW, NORMAL);
	// Approximate the broad cool fill from the wall above the tank.
	float wall_reflection = smoothstep(0.15, 0.85, reflected.y);
	vec3 scatter = liquid_color * (1.0 - transmission) * 0.18;
	vec3 reflection = vec3(0.18, 0.25, 0.33) * wall_reflection * fresnel;
	EMISSION = (texture(opaque_color, SCREEN_UV).rgb * transmission * 0.9 + scatter)
		* (1.0 - fresnel) + reflection;
}
