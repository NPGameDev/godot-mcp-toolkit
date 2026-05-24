shader_type canvas_item;
uniform float brightness : hint_range(0, 1) = 0.75;
void fragment() {
	COLOR.rgb *= brightness;
}
