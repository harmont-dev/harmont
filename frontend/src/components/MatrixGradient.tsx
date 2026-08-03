import { onMount, onCleanup } from "solid-js";

const VERT = `
attribute vec2 a_position;
void main() {
  gl_Position = vec4(a_position, 0.0, 1.0);
}`;

const FRAG = `
precision highp float;
uniform float u_time;
uniform vec2 u_resolution;
uniform float u_dpr;
uniform float u_scale;

float hash(vec2 p) {
  return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

vec2 bulge(vec2 pos, vec2 center, float r2, float str) {
  vec2 d = pos - center;
  return d * exp(-dot(d, d) / r2) * str;
}

void main() {
  vec2 px = gl_FragCoord.xy;
  vec2 uv = px / u_resolution;
  float aspect = u_resolution.x / u_resolution.y;
  float t = u_time * 0.45;

  // Blob centers — irrational Lissajous (never repeats)
  vec2 bc1 = vec2(
    0.5 + 0.22 * sin(t * 0.7071) + 0.13 * sin(t * 1.2247 + 0.8),
    0.5 + 0.20 * cos(t * 0.8660) + 0.15 * cos(t * 1.4142 + 1.3));
  vec2 bc2 = vec2(
    0.5 + 0.25 * cos(t * 0.5774 + 1.0) + 0.15 * cos(t * 1.3229 + 2.1),
    0.5 + 0.18 * sin(t * 0.7937 + 2.0) + 0.12 * sin(t * 1.1180 + 0.4));
  vec2 bc3 = vec2(
    0.5 + 0.18 * sin(t * 0.6180 + 3.0) + 0.12 * sin(t * 1.0488 + 1.7),
    0.5 + 0.22 * cos(t * 0.4472 + 1.5) + 0.13 * cos(t * 1.1547 + 3.2));
  vec2 bc4 = vec2(
    0.5 + 0.20 * cos(t * 0.8944 + 0.5) + 0.15 * cos(t * 1.2910 + 2.8),
    0.5 + 0.25 * sin(t * 0.3162 + 2.5) + 0.15 * sin(t * 1.0954 + 0.9));
  vec2 bc5 = vec2(
    0.5 + 0.17 * sin(t * 0.4142 + 4.2) + 0.11 * sin(t * 1.1832 + 1.1),
    0.5 + 0.20 * cos(t * 0.7320 + 3.8) + 0.12 * cos(t * 1.0607 + 2.4));

  // Lens displacement — push dots outward from blob centers
  float bR = 200.0 * u_dpr * u_scale;
  float bR2 = bR * bR;
  float bStr = 0.05;
  float margin = bR * bStr * 0.6;
  vec2 displaced = px + margin;
  displaced += bulge(displaced, bc1 * u_resolution, bR2, bStr);
  displaced += bulge(displaced, bc2 * u_resolution, bR2, bStr);
  displaced += bulge(displaced, bc3 * u_resolution, bR2, bStr);
  displaced += bulge(displaced, bc4 * u_resolution, bR2, bStr);
  displaced += bulge(displaced, bc5 * u_resolution, bR2, bStr);

  // Grid from displaced position
  float spacing = 13.0 * u_dpr;
  vec2 cellId = floor(displaced / spacing);
  vec2 cell = fract(displaced / spacing) - 0.5;
  float d = length(cell);

  // Blob influence (aspect-corrected UV, original position)
  vec2 uvA = vec2(uv.x * aspect, uv.y);
  vec2 b1 = vec2(bc1.x * aspect, bc1.y);
  vec2 b2 = vec2(bc2.x * aspect, bc2.y);
  vec2 b3 = vec2(bc3.x * aspect, bc3.y);
  vec2 b4 = vec2(bc4.x * aspect, bc4.y);
  vec2 b5 = vec2(bc5.x * aspect, bc5.y);

  float sp = 0.09 * u_scale;
  vec2 s1 = vec2(sp * (1.0 + 0.4 * sin(t * 0.3)),       sp * (1.0 - 0.3 * sin(t * 0.3)));
  vec2 s2 = vec2(sp * (1.0 - 0.35 * cos(t * 0.4 + 1.0)), sp * (1.0 + 0.35 * cos(t * 0.4 + 1.0)));
  vec2 s3 = vec2(sp * (1.0 + 0.3 * sin(t * 0.5 + 2.0)), sp * (1.0 - 0.25 * sin(t * 0.5 + 2.0)));
  vec2 s4 = vec2(sp * (1.0 - 0.3 * cos(t * 0.35 + 3.0)), sp * (1.0 + 0.4 * cos(t * 0.35 + 3.0)));
  vec2 s5 = vec2(sp * (1.0 + 0.25 * sin(t * 0.45 + 4.0)), sp * (1.0 - 0.35 * sin(t * 0.45 + 4.0)));

  vec2 d1 = uvA - b1; float i1 = exp(-(d1.x*d1.x/s1.x + d1.y*d1.y/s1.y));
  vec2 d2 = uvA - b2; float i2 = exp(-(d2.x*d2.x/s2.x + d2.y*d2.y/s2.y));
  vec2 d3 = uvA - b3; float i3 = exp(-(d3.x*d3.x/s3.x + d3.y*d3.y/s3.y));
  vec2 d4 = uvA - b4; float i4 = exp(-(d4.x*d4.x/s4.x + d4.y*d4.y/s4.y));
  vec2 d5 = uvA - b5; float i5 = exp(-(d5.x*d5.x/s5.x + d5.y*d5.y/s5.y));

  float intensity = i1 + i2 + i3 + i4 + i5;

  // Dot size swells near blobs
  float minR = 0.08;
  float maxR = 0.16;
  float radius = mix(minR, maxR, clamp(intensity * 1.2, 0.0, 1.0));
  float sharpness = mix(3.0, 1.2, clamp(intensity * 1.5, 0.0, 1.0));
  float aa = sharpness / spacing;
  float shrink = mix(aa * 0.6, 0.0, clamp(intensity * 1.5, 0.0, 1.0));
  float mask = smoothstep(radius + aa - shrink, radius - shrink, d);

  // Per-dot shimmer
  float shimmer = 0.9 + 0.1 * sin(hash(cellId) * 6.2831 + u_time * 2.5);

  // Mostly grey, faint color tint from blobs
  vec3 tint1 = vec3(0.145, 0.388, 0.922);
  vec3 tint2 = vec3(0.545, 0.361, 0.965);
  vec3 tint3 = vec3(0.024, 0.714, 0.831);
  vec3 tint4 = vec3(0.133, 0.773, 0.369);
  vec3 tint5 = vec3(0.35, 0.35, 0.45);
  vec3 blobTint = (tint1 * i1 + tint2 * i2 + tint3 * i3 + tint4 * i4 + tint5 * i5) / (intensity + 0.001);

  vec3 bg = vec3(0.039);
  vec3 dotDim = vec3(0.09);
  float saturation = clamp(intensity * intensity * 0.45, 0.0, 0.38);
  vec3 dotLit = vec3(0.28) + blobTint * saturation;
  vec3 dotColor = mix(dotDim, dotLit, clamp(intensity, 0.0, 1.0)) * shimmer;

  float luma = dot(dotColor, vec3(0.299, 0.587, 0.114));
  dotColor = mix(vec3(luma), dotColor, 0.8);
  dotColor = pow(dotColor, vec3(0.85));
  vec3 col = mix(bg, dotColor, mask);

  // Edge fade on all four sides
  vec2 edgePx = 2.0 * u_dpr / u_resolution;
  float edgeFade = smoothstep(0.0, edgePx.x, uv.x)
                 * smoothstep(0.0, edgePx.x, 1.0 - uv.x)
                 * smoothstep(0.0, edgePx.y, uv.y)
                 * smoothstep(0.0, edgePx.y, 1.0 - uv.y);
  col = mix(bg, col, edgeFade);

  gl_FragColor = vec4(col, 1.0);
}`;

export type MatrixGradientProps = {
  class?: string;
  /** Multiplies the moving-blob feature size. 1 = login-page look (default);
   *  smaller values (e.g. 0.45) shrink the blobs so several fit a small panel.
   *  The dot grid spacing is unaffected. Read once at mount — not reactive. */
  scale?: number;
};

function compileShader(gl: WebGLRenderingContext, type: number, src: string) {
  const s = gl.createShader(type)!;
  gl.shaderSource(s, src);
  gl.compileShader(s);
  return s;
}

function linkProgram(gl: WebGLRenderingContext, vs: WebGLShader, fs: WebGLShader) {
  const p = gl.createProgram()!;
  gl.attachShader(p, vs);
  gl.attachShader(p, fs);
  gl.linkProgram(p);
  return p;
}

export function MatrixGradient(props: MatrixGradientProps) {
  let canvas!: HTMLCanvasElement;

  onMount(() => {
    const gl = canvas.getContext("webgl", { alpha: false, antialias: false });
    if (!gl) return;

    const vs = compileShader(gl, gl.VERTEX_SHADER, VERT);
    const fs = compileShader(gl, gl.FRAGMENT_SHADER, FRAG);
    const program = linkProgram(gl, vs, fs);

    const buf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(
      gl.ARRAY_BUFFER,
      new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]),
      gl.STATIC_DRAW,
    );

    const aPos = gl.getAttribLocation(program, "a_position");
    gl.enableVertexAttribArray(aPos);
    gl.vertexAttribPointer(aPos, 2, gl.FLOAT, false, 0, 0);

    const uTime = gl.getUniformLocation(program, "u_time");
    const uRes = gl.getUniformLocation(program, "u_resolution");
    const uDpr = gl.getUniformLocation(program, "u_dpr");
    const uScale = gl.getUniformLocation(program, "u_scale");

    gl.useProgram(program);
    gl.uniform1f(uScale, props.scale ?? 1);

    const resize = () => {
      const dpr = window.devicePixelRatio || 1;
      const rect = canvas.getBoundingClientRect();
      canvas.width = rect.width * dpr;
      canvas.height = rect.height * dpr;
      gl.viewport(0, 0, canvas.width, canvas.height);
      gl.uniform1f(uDpr, dpr);
    };

    const ro = new ResizeObserver(resize);
    ro.observe(canvas);
    resize();

    let raf: number;
    const start = performance.now();
    const render = () => {
      gl.uniform1f(uTime, (performance.now() - start) / 1000);
      gl.uniform2f(uRes, canvas.width, canvas.height);
      gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
      raf = requestAnimationFrame(render);
    };
    raf = requestAnimationFrame(render);

    onCleanup(() => {
      cancelAnimationFrame(raf);
      ro.disconnect();
    });
  });

  return (
    <canvas
      ref={canvas!}
      class={`absolute inset-0 w-full h-full ${props.class ?? ""}`}
    />
  );
}
