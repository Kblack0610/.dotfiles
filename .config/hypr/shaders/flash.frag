// timebox lap-boundary flash: tint the whole screen red for a moment.
// Applied briefly via `hyprctl keyword decoration:screen_shader` by timebox-flash.
#version 300 es
precision highp float;
in vec2 v_texcoord;
uniform sampler2D tex;
out vec4 fragColor;
void main() {
    vec4 pixel = texture(tex, v_texcoord);
    fragColor = mix(pixel, vec4(1.0, 0.15, 0.15, 1.0), 0.45);
}
