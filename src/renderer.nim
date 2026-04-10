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

const ShowFps* {.booldefine.} = true

const
  FProj = 1.0'f32 / tan(FovDeg * PI.float32 / 180.0'f32 / 2.0'f32)
  Asp   = WinW.float32 / WinH.float32
  ProjA = -(Far + Near) / (Far - Near)
  ProjB = -2.0'f32 * Near * Far / (Far - Near)

# ─── Types ────────────────────────────────────────────────────────────────────

type
  Tri* = object
    v*:       array[3, Vec3]
    uv*:      array[3, Vec2]
    r*, g*, b*: uint8

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

proc camFwd*(c: Cam): Vec3 =
  vec3(cos(c.pitch) * sin(c.yaw),
       sin(c.pitch),
       -cos(c.pitch) * cos(c.yaw))

proc camRgt*(c: Cam): Vec3 =
  vec3(cos(c.yaw), 0'f32, sin(c.yaw))

# ─── Projection ───────────────────────────────────────────────────────────────

proc toClip*(v: Vec3; cam: Cam): Vec4 =
  let fwd = camFwd(cam)
  let rgt = camRgt(cam)
  let up  = cross(rgt, fwd)
  let t   = v - cam.pos
  let vx  = dot(t, rgt)
  let vy  = dot(t, up)
  let vz  = -dot(t, fwd)
  vec4((FProj / Asp) * vx,
       FProj * vy,
       ProjA * vz + ProjB,
       -vz)

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
  if abs(area) < 0.5'f32: return

  let x0 = max(0,       int(min(s0.x, min(s1.x, s2.x))))
  let x1 = min(WinW-1,  int(max(s0.x, max(s1.x, s2.x))) + 1)
  let y0 = max(0,       int(min(s0.y, min(s1.y, s2.y))))
  let y1 = min(WinH-1,  int(max(s0.y, max(s1.y, s2.y))) + 1)

  for py in y0..y1:
    for px in x0..x1:
      let p  = vec2(float32(px) + 0.5'f32, float32(py) + 0.5'f32)
      let e0 = edgeFn(a1, a2, p)
      let e1 = edgeFn(a2, a0, p)
      let e2 = edgeFn(a0, a1, p)
      let inside = if area > 0: e0 >= 0 and e1 >= 0 and e2 >= 0
                   else:         e0 <= 0 and e1 <= 0 and e2 <= 0
      if inside:
        # 1/w interpolated across screen space — largest value = closest to cam.
        let z = (e0 * s0.z + e1 * s1.z + e2 * s2.z) / area
        let i = py * WinW + px
        if z > zbuf[i]:
          zbuf[i] = z
          # Perspective-correct UV: interpolate u/w and v/w, then divide by 1/w.
          let uOverW = (e0 * uv0.x * s0.z + e1 * uv1.x * s1.z + e2 * uv2.x * s2.z) / area
          let vOverW = (e0 * uv0.y * s0.z + e1 * uv1.y * s1.z + e2 * uv2.y * s2.z) / area
          let tc  = sampleTex(tex, uOverW / z, vOverW / z)
          let tr  = (tc shr 16) and 0xFF'u32
          let tg  = (tc shr 8)  and 0xFF'u32
          let tb  =  tc         and 0xFF'u32
          pixels[i] = 0xFF000000'u32 or
                      ((tr * uint32(r) div 255'u32) shl 16) or
                      ((tg * uint32(g) div 255'u32) shl 8)  or
                       (tb * uint32(b) div 255'u32)

# ─── Bitmap font (5×7, 2× scale) ─────────────────────────────────────────────

const
  CharW*  = 5
  CharH*  = 7
  CharSc* = 2  # pixel scale multiplier

# Indexed as: '0'-'9' → 0-9, 'F' → 10, 'P' → 11, 'S' → 12, ':' → 13, else → 14 (space)
# Each entry is 7 rows; each row is 5 bits, bit-4 = leftmost pixel.
const fontData: array[15, array[7, uint8]] = [
  [14'u8, 17, 17, 17, 17, 17, 14],  # 0  .###. #...# #...# #...# #...# #...# .###.
  [ 4'u8, 12,  4,  4,  4,  4, 14],  # 1  ..#.. .##.. ..#.. ..#.. ..#.. ..#.. .###.
  [14'u8, 17,  1,  6, 12, 16, 31],  # 2  .###. #...# ....# ..##. .##.. #.... #####
  [14'u8, 17,  1,  6,  1, 17, 14],  # 3  .###. #...# ....# ..##. ....# #...# .###.
  [ 6'u8, 10, 18, 31,  2,  2,  2],  # 4  ..##. .#.#. #..#. ##### ...#. ...#. ...#.
  [31'u8, 16, 30,  1,  1, 17, 14],  # 5  ##### #.... ####. ....# ....# #...# .###.
  [ 6'u8,  8, 16, 30, 17, 17, 14],  # 6  ..##. .#... #.... ####. #...# #...# .###.
  [31'u8,  1,  2,  4,  8,  8,  8],  # 7  ##### ....# ...#. ..#.. .#... .#... .#...
  [14'u8, 17, 17, 14, 17, 17, 14],  # 8  .###. #...# #...# .###. #...# #...# .###.
  [14'u8, 17, 17, 15,  1,  1, 14],  # 9  .###. #...# #...# .#### ....# ....# .###.
  [31'u8, 16, 16, 30, 16, 16, 16],  # F  ##### #.... #.... ####. #.... #.... #....
  [30'u8, 17, 17, 30, 16, 16, 16],  # P  ####. #...# #...# ####. #.... #.... #....
  [15'u8, 16, 16, 14,  1,  1, 30],  # S  .#### #.... #.... .###. ....# ....# ####.
  [ 0'u8, 12, 12,  0, 12, 12,  0],  # :  ..... .##.. .##.. ..... .##.. .##.. .....
  [ 0'u8,  0,  0,  0,  0,  0,  0],  # (space)
]

proc charIdx(c: char): int =
  case c
  of '0'..'9': ord(c) - ord('0')
  of 'F': 10
  of 'P': 11
  of 'S': 12
  of ':': 13
  else:   14

proc drawChar*(pixels: var seq[uint32]; x, y: int; c: char; color: uint32) =
  let d = fontData[charIdx(c)]
  for row in 0 ..< CharH:
    for col in 0 ..< CharW:
      if (d[row] and (0b10000'u8 shr col)) != 0:
        for sy in 0 ..< CharSc:
          for sx in 0 ..< CharSc:
            let px = x + col * CharSc + sx
            let py = y + row * CharSc + sy
            if px in 0 ..< WinW and py in 0 ..< WinH:
              pixels[py * WinW + px] = color

proc drawText*(pixels: var seq[uint32]; x, y: int; text: string; color: uint32) =
  var cx = x
  for c in text:
    drawChar(pixels, cx, y, c, color)
    cx += (CharW + 1) * CharSc
