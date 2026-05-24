shader_type canvas_item;
uniform float brightness : hint_range(0,1) = 0.5;
uniform vec4 tint : source_color = vec4(1,1,1,1);
void fragment() {
	COLOR = texture(TEXTURE, UV) * tint * brightness;
}
