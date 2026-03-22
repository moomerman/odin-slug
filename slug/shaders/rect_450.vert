#version 450

layout(location = 0) in vec2 inPos;
layout(location = 1) in vec4 inCol;

layout(push_constant) uniform PC {
    mat4 mvp;
} pc;

layout(location = 0) out vec4 vColor;

void main() {
    gl_Position = pc.mvp * vec4(inPos, 0.0, 1.0);
    vColor = inCol;
}
