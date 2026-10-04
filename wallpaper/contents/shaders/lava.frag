#version 440
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float time;
    float brightness;
    vec2 resolution;
    vec4 base;
    vec4 colA;
    vec4 colB;
    vec4 colC;
    float sizeScale;
    float haze;
    float kick;   // the music, all 0..1: a bass hit that falls off...
    vec3 bands;   // ...and the energy in bass, mids, highs
    float fuseStyle; // what fusing wax turns to: 0 a neighbouring hue, 1 the palette's opposite, 2 the third wax
    float fusion; // 1 while music plays: fusing wax makes new colours; 0 is the plain blend
};

float hash(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }

// turn a colour around the grey axis: same lightness, another hue
vec3 hueTurn(vec3 c, float a) {
    const vec3 k = vec3(0.57735);
    return c * cos(a) + cross(k, c) * sin(a) + k * dot(k, c) * (1.0 - cos(a));
}

float chroma(vec3 c) { return length(c - (c.r + c.g + c.b) / 3.0); }   // how far from grey

void main() {
    // coordinates in units of the short screen side, so blobs stay round on portrait and landscape
    float s = min(resolution.x, resolution.y);
    vec2 p = qt_TexCoord0 * resolution / s;
    vec2 ext = resolution / s;
    // highs ripple the surface of the wax
    p += bands.z * 0.003 * vec2(sin(p.y * 34.0 + time * 2.3), cos(p.x * 34.0 - time * 1.9));

    vec3 wax = vec3(0.0);   // how much of each colour of wax (A, B, C) is here
    for (int i = 0; i < 9; i++) {
        float fi = float(i);
        // each colour of wax swells with its own band (A bass, B mids, C highs), and all of it on a kick
        float band = (i % 3 == 0) ? bands.x : ((i % 3 == 1) ? bands.y : bands.z);
        float r = (0.10 + 0.07 * fract(fi * 0.618)) * sizeScale * (1.0 + 0.14 * band + 0.05 * kick);
        // slow rise and fall like wax in a lamp, with a lazy sideways drift
        float sp = 0.035 + 0.02 * fract(fi * 0.377);
        float y = (0.5 + 0.5 * sin(time * sp + fi * 2.1)) * (ext.y + 0.4) - 0.2;
        float x = (0.5 + 0.42 * sin(time * sp * 0.7 + fi * 1.3) * cos(time * 0.011 + fi)) * ext.x;
        vec2 d = p - vec2(x, y);
        d.y *= 1.0 + 0.25 * sin(time * 0.05 + fi); // squish as they move
        float f = r * r / (dot(d, d) + 1e-4);
        wax += f * ((i % 3 == 0) ? vec3(1.0, 0.0, 0.0) : ((i % 3 == 1) ? vec3(0.0, 1.0, 0.0) : vec3(0.0, 0.0, 1.0)));
    }
    float field = wax.x + wax.y + wax.z;
    vec3 share = wax / max(field, 1e-4);
    vec3 tint = colA.rgb * share.x + colB.rgb * share.y + colC.rgb * share.z;
    // two colours of wax fusing make a new one, most where they meet half and half (fuseStyle picks
    // which: a neighbour, the palette's opposite, or the third wax). Only the wax turns: the haze keeps
    // the plain blend, or the new colour leaks out as a halo on the background
    vec3 plain = tint;
    vec3 fuse = fusion * 4.0 * share * share.yzx * smoothstep(0.12, 0.45, min(wax, wax.yzx));
    float fused = clamp(fuse.x + fuse.y + fuse.z, 0.0, 1.0);
    if (fuseStyle < 0.5) {          // neighbours: each pair turns the blend a little way round the wheel
        tint = hueTurn(tint, dot(fuse, vec3(0.5, -0.5, 0.9)));
    } else if (fuseStyle < 1.5) {   // opposite: every pair sparks the one accent across the wheel from the palette
        vec3 acc = hueTurn((colA.rgb + colB.rgb + colC.rgb) / 3.0, 3.14159);
        float ag = (acc.r + acc.g + acc.b) / 3.0;
        float vivid = max(chroma(colA.rgb), max(chroma(colB.rgb), chroma(colC.rgb)));   // as vivid as the most vivid wax
        acc = max(ag + (acc - ag) * min(vivid / max(chroma(acc), 1e-3), 4.0), 0.0);
        tint = mix(tint, acc, smoothstep(0.3, 0.7, fused));   // steep, or the way there is a grey ring
    } else {                        // third: two waxes fusing show the colour of the one that is missing
        tint = mix(tint, (fuse.x * colC.rgb + fuse.y * colA.rgb + fuse.z * colB.rgb) / max(fuse.x + fuse.y + fuse.z, 1e-4), fused);
    }
    float grey = (tint.r + tint.g + tint.b) / 3.0;
    tint = max(grey + (tint - grey) * (1.0 + 0.5 * fused), 0.0) * (1.0 + 0.3 * fused);

    float body = smoothstep(0.92, 1.08, field);           // the wax itself, crisp edge
    float glow = smoothstep(0.05, 0.9, field) * haze;     // faint haze around it
    float core = clamp((field - 1.0) * 0.4, 0.0, 1.0);    // hotter toward the middle

    vec3 col = base.rgb;
    col = mix(col, plain * 0.4, glow);
    col = mix(col, tint * (0.5 + 0.3 * core + 0.06 * kick), body);
    col *= brightness;

    // soft vignette + grain so dark gradients don't band
    vec2 v = qt_TexCoord0 - 0.5;
    col *= 1.0 - 0.35 * dot(v, v);
    col += (hash(gl_FragCoord.xy + fract(time)) - 0.5) / 255.0 * 1.5;

    fragColor = vec4(col, 1.0) * qt_Opacity;
}
