import sdl2
import vmath
import std/math

# ─── Constants ────────────────────────────────────────────────────────────────

const WinW* {.intdefine.} = 800
const WinH* {.intdefine.} = 600

const
  FovDeg* = 70.0'f32
  Near*   = 0.1'f32
  Far*    = 500.0'f32

const
  FProj = 1.0'f32 / tan(FovDeg * PI.float32 / 180.0'f32 / 2.0'f32)
  Asp   = WinW.float32 / WinH.float32
  ProjA = -(Far + Near) / (Far - Near)
  ProjB = -2.0'f32 * Near * Far / (Far - Near)

# ─── Types ────────────────────────────────────────────────────────────────────

type
  Tri* = object
    v*:         array[3, Vec3]
    uv*:        array[3, Vec2]
    r*, g*, b*: uint8
    tex*:       ptr Texture

  Cam* = object
    pos*:   Vec3
    yaw*:   float32
    pitch*: float32

  Texture* = object
    pixels*: seq[uint32]
    w*, h*:  int

  ClipVert* = object
    pos*: Vec4
    uv*:  Vec2

# ─── Texture loading ──────────────────────────────────────────────────────────

proc loadTexture*(path: string): Texture =
  let surf = loadBMP(path)
  assert surf != nil, "failed to load texture: " & path
  let conv = surf.convertSurfaceFormat(SDL_PIXELFORMAT_ARGB8888, 0)
  surf.freeSurface()
  result.w = conv.w
  result.h = conv.h
  let nPix = result.w * result.h
  result.pixels = newSeq[uint32](nPix)
  copyMem(addr result.pixels[0], conv.pixels, nPix * 4)
  conv.freeSurface()

# ─── Camera ───────────────────────────────────────────────────────────────────

proc camFwd*(c: Cam): Vec3 {.inline.} =
  vec3(cos(c.pitch) * sin(c.yaw),
       sin(c.pitch),
       -cos(c.pitch) * cos(c.yaw))

proc camRgt*(c: Cam): Vec3 {.inline.} =
  vec3(cos(c.yaw), 0'f32, sin(c.yaw))

type CamBasis* = object
  fwd*, rgt*, up*: Vec3

proc camBasis*(c: Cam): CamBasis {.inline.} =
  let fwd = camFwd(c)
  let rgt = camRgt(c)
  CamBasis(fwd: fwd, rgt: rgt, up: cross(rgt, fwd))

# ─── Projection ───────────────────────────────────────────────────────────────

proc toClip*(v: Vec3; cam: Cam; basis: CamBasis): Vec4 {.inline.} =
  let t  = v - cam.pos
  let vx = dot(t, basis.rgt)
  let vy = dot(t, basis.up)
  let vz = -dot(t, basis.fwd)
  vec4((FProj / Asp) * vx,
       FProj * vy,
       ProjA * vz + ProjB,
       -vz)

proc toClip*(v: Vec3; cam: Cam): Vec4 {.inline.} =
  toClip(v, cam, camBasis(cam))

proc clipPolygon*(verts: seq[ClipVert]): seq[ClipVert] =
  # Sutherland-Hodgman against 6 homogeneous frustum planes.
  # UVs are interpolated alongside positions.
  proc sd(v: Vec4; plane: int): float32 =
    case plane
    of 0: v.w           # near:   w > 0
    of 1: v.w - v.z     # far:    z < w
    of 2: v.x + v.w     # left:   x > -w
    of 3: v.w - v.x     # right:  x < w
    of 4: v.y + v.w     # bottom: y > -w
    of 5: v.w - v.y     # top:    y < w
    else: 0'f32

  result = verts
  for plane in 0..5:
    if result.len == 0: return
    var clipped: seq[ClipVert]
    let n = result.len
    for i in 0 ..< n:
      let a  = result[i]
      let b  = result[(i + 1) mod n]
      let da = sd(a.pos, plane)
      let db = sd(b.pos, plane)
      if da >= 0:
        if db >= 0:
          clipped.add b
        else:
          let t = da / (da - db)
          clipped.add ClipVert(pos: a.pos + (b.pos - a.pos) * t,
                               uv:  a.uv  + (b.uv  - a.uv)  * t)
      else:
        if db >= 0:
          let t = da / (da - db)
          clipped.add ClipVert(pos: a.pos + (b.pos - a.pos) * t,
                               uv:  a.uv  + (b.uv  - a.uv)  * t)
          clipped.add b
    result = clipped

proc clipToScreen*(c: Vec4): Vec3 =
  let nx = c.x / c.w
  let ny = c.y / c.w
  vec3((nx + 1'f32) * 0.5'f32 * WinW.float32,
       (1'f32 - ny) * 0.5'f32 * WinH.float32,
       1.0'f32 / c.w)

# ─── Rasterizer ───────────────────────────────────────────────────────────────

proc edgeFn*(a, b, p: Vec2): float32 =
  (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)

proc sampleTex*(tex: Texture; u, v: float32): uint32 =
  # Repeat wrap; works correctly for any float including negative values
  # because bitwise-and on a signed int gives correct power-of-2 modulo.
  let tx = int(u * float32(tex.w)) and (tex.w - 1)
  let ty = int(v * float32(tex.h)) and (tex.h - 1)
  tex.pixels[ty * tex.w + tx]

proc drawTri*(pixels: var seq[uint32]; zbuf: var seq[float32];
              s0, s1, s2: Vec3; uv0, uv1, uv2: Vec2;
              r, g, b: uint8; tex: Texture) =
  let a0   = vec2(s0.x, s0.y)
  let a1   = vec2(s1.x, s1.y)
  let a2   = vec2(s2.x, s2.y)
  let area = edgeFn(a0, a1, a2)
  # Back-face cull: area >= 0 means tri faces away (CCW winding expected).
  # Degenerate triangles (area ≈ 0) are also skipped.
  if area >= -0.5'f32: return

  let x0 = max(0,       int(min(s0.x, min(s1.x, s2.x))))
  let x1 = min(WinW-1,  int(max(s0.x, max(s1.x, s2.x))) + 1)
  let y0 = max(0,       int(min(s0.y, min(s1.y, s2.y))))
  let y1 = min(WinH-1,  int(max(s0.y, max(s1.y, s2.y))) + 1)

  # Incremental edge + attribute steps — avoids per-pixel multiplications.
  # Δe per pixel right: -(b.y - a.y); per row down: (b.x - a.x)
  let dE0dx = a1.y - a2.y;  let dE0dy = a2.x - a1.x
  let dE1dx = a2.y - a0.y;  let dE1dy = a0.x - a2.x
  let dE2dx = a0.y - a1.y;  let dE2dy = a1.x - a0.x

  let invArea = 1.0'f32 / area
  # Precomputed attribute steps (z = 1/w, u = u/w, v = v/w in screen space)
  let dZdx = (dE0dx * s0.z  + dE1dx * s1.z  + dE2dx * s2.z)         * invArea
  let dZdy = (dE0dy * s0.z  + dE1dy * s1.z  + dE2dy * s2.z)         * invArea
  let dUdx = (dE0dx * uv0.x * s0.z + dE1dx * uv1.x * s1.z + dE2dx * uv2.x * s2.z) * invArea
  let dUdy = (dE0dy * uv0.x * s0.z + dE1dy * uv1.x * s1.z + dE2dy * uv2.x * s2.z) * invArea
  let dVdx = (dE0dx * uv0.y * s0.z + dE1dx * uv1.y * s1.z + dE2dx * uv2.y * s2.z) * invArea
  let dVdy = (dE0dy * uv0.y * s0.z + dE1dy * uv1.y * s1.z + dE2dy * uv2.y * s2.z) * invArea

  # Seed at top-left corner of bounding box
  let p0    = vec2(float32(x0) + 0.5'f32, float32(y0) + 0.5'f32)
  var rowE0 = edgeFn(a1, a2, p0)
  var rowE1 = edgeFn(a2, a0, p0)
  var rowE2 = edgeFn(a0, a1, p0)
  var rowZ  = (rowE0 * s0.z  + rowE1 * s1.z  + rowE2 * s2.z)         * invArea
  var rowU  = (rowE0 * uv0.x * s0.z + rowE1 * uv1.x * s1.z + rowE2 * uv2.x * s2.z) * invArea
  var rowV  = (rowE0 * uv0.y * s0.z + rowE1 * uv1.y * s1.z + rowE2 * uv2.y * s2.z) * invArea

  for py in y0..y1:
    var e0 = rowE0; var e1 = rowE1; var e2 = rowE2
    var z = rowZ;   var u = rowU;   var v = rowV
    let rowBase = py * WinW
    for px in x0..x1:
      if e0 <= 0 and e1 <= 0 and e2 <= 0:  # all ≤ 0 = inside (CCW)
        let i = rowBase + px
        if z > zbuf[i]:
          zbuf[i] = z
          let tc = sampleTex(tex, u / z, v / z)
          let tr = (tc shr 16) and 0xFF'u32
          let tg = (tc shr 8)  and 0xFF'u32
          let tb =  tc         and 0xFF'u32
          pixels[i] = 0xFF000000'u32 or
                      ((tr * uint32(r) div 255'u32) shl 16) or
                      ((tg * uint32(g) div 255'u32) shl 8)  or
                       (tb * uint32(b) div 255'u32)
      e0 += dE0dx; e1 += dE1dx; e2 += dE2dx
      z  += dZdx;  u  += dUdx;  v  += dVdx
    rowE0 += dE0dy; rowE1 += dE1dy; rowE2 += dE2dy
    rowZ  += dZdy;  rowU  += dUdy;  rowV  += dVdy

# ─── High-level draw — clips and rasterises a Tri using its own texture ───────

proc drawTri*(pixels: var seq[uint32]; zbuf: var seq[float32];
              t: Tri; cam: Cam; basis: CamBasis) =
  assert t.tex != nil, "Tri.tex must be set before drawing"
  var poly = @[
    ClipVert(pos: toClip(t.v[0], cam, basis), uv: t.uv[0]),
    ClipVert(pos: toClip(t.v[1], cam, basis), uv: t.uv[1]),
    ClipVert(pos: toClip(t.v[2], cam, basis), uv: t.uv[2])]
  poly = clipPolygon(poly)
  if poly.len < 3: return
  var ss: seq[tuple[s: Vec3, uv: Vec2]]
  for cv in poly:
    ss.add (clipToScreen(cv.pos), cv.uv)
  for i in 1 .. ss.len - 2:
    drawTri(pixels, zbuf,
            ss[0].s, ss[i].s, ss[i+1].s,
            ss[0].uv, ss[i].uv, ss[i+1].uv,
            t.r, t.g, t.b, t.tex[])

proc drawTri*(pixels: var seq[uint32]; zbuf: var seq[float32];
              t: Tri; cam: Cam) {.inline.} =
  drawTri(pixels, zbuf, t, cam, camBasis(cam))