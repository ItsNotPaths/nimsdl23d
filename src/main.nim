import sdl2
import vmath
import std/[json, math]

# ─── Constants ────────────────────────────────────────────────────────────────

const
  WinW      = 800
  WinH      = 600
  FovDeg    = 70.0'f32
  Near      = 0.1'f32
  Far       = 500.0'f32
  MoveSpeed = 5.0'f32
  MouseSens = 0.002'f32

const
  FProj = 1.0'f32 / tan(FovDeg * PI.float32 / 180.0'f32 / 2.0'f32)
  Asp   = WinW.float32 / WinH.float32

# ─── Types ────────────────────────────────────────────────────────────────────

type
  Tri = object
    v:       array[3, Vec3]
    r, g, b: uint8

  Cam = object
    pos:   Vec3
    yaw:   float32
    pitch: float32

# ─── World loading ────────────────────────────────────────────────────────────

proc loadTris(path: string): seq[Tri] =
  for t in parseFile(path)["triangles"]:
    let v = t["v"]
    let c = t["color"]
    result.add Tri(
      v: [vec3(v[0][0].getFloat.float32, v[0][1].getFloat.float32, v[0][2].getFloat.float32),
          vec3(v[1][0].getFloat.float32, v[1][1].getFloat.float32, v[1][2].getFloat.float32),
          vec3(v[2][0].getFloat.float32, v[2][1].getFloat.float32, v[2][2].getFloat.float32)],
      r: c[0].getInt.uint8,
      g: c[1].getInt.uint8,
      b: c[2].getInt.uint8)

# ─── Camera ───────────────────────────────────────────────────────────────────

proc camFwd(c: Cam): Vec3 =
  vec3(cos(c.pitch) * sin(c.yaw),
       sin(c.pitch),
       -cos(c.pitch) * cos(c.yaw))

proc camRgt(c: Cam): Vec3 =
  vec3(cos(c.yaw), 0'f32, sin(c.yaw))

# ─── Projection ───────────────────────────────────────────────────────────────

# Returns screen-space (px, py, 1/w).
# 1/w is perspective-correct depth: larger = closer. Negative signals clipped.
proc projectVert(v: Vec3; cam: Cam): Vec3 =
  let fwd = camFwd(cam)
  let rgt = camRgt(cam)
  let up  = cross(rgt, fwd)
  let t   = v - cam.pos
  let vx  = dot(t, rgt)
  let vy  = dot(t, up)
  let vz  = -dot(t, fwd)   # negative = in front

  if vz >= -Near: return vec3(0, 0, -1)

  let cw = -vz
  let nx = (FProj / Asp) * vx / cw
  let ny = FProj * vy / cw

  const Guard = 4096.0'f32
  vec3(clamp((nx + 1'f32) * 0.5'f32 * WinW.float32, -Guard, WinW.float32 + Guard),
       clamp((1'f32 - ny)  * 0.5'f32 * WinH.float32, -Guard, WinH.float32 + Guard),
       1.0'f32 / cw)

# ─── Rasterizer ───────────────────────────────────────────────────────────────

proc edgeFn(a, b, p: Vec2): float32 =
  (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)

proc drawTri(pixels: var seq[uint32]; zbuf: var seq[float32];
             s0, s1, s2: Vec3; color: uint32) =
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
        # Perspective-correct depth: interpolate 1/w, keep largest (closest).
        let z = (e0 * s0.z + e1 * s1.z + e2 * s2.z) / area
        let i = py * WinW + px
        if z > zbuf[i]:
          zbuf[i]   = z
          pixels[i] = color

# ─── Main ─────────────────────────────────────────────────────────────────────

proc main() =
  discard sdl2.init(INIT_VIDEO or INIT_EVENTS)
  defer: sdl2.quit()

  let win = createWindow("3D | WASD + mouse",
    SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
    WinW.cint, WinH.cint, SDL_WINDOW_SHOWN)
  defer: win.destroy()

  let ren = createRenderer(win, -1,
    Renderer_Accelerated or Renderer_PresentVsync)
  defer: ren.destroy()

  let tex = ren.createTexture(
    SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_STREAMING,
    WinW.cint, WinH.cint)
  defer: tex.destroy()

  discard setRelativeMouseMode(True32)

  let tris   = loadTris("world/world.json")
  var pixels = newSeq[uint32](WinW * WinH)
  var zbuf   = newSeq[float32](WinW * WinH)
  var cam    = Cam(pos: vec3(0'f32, 2'f32, 8'f32))
  var last   = getTicks()

  while true:
    let now = getTicks()
    let dt  = float32(now - last) / 1000'f32
    last = now

    var evt: Event
    while pollEvent(evt):
      case evt.kind
      of QuitEvent: return
      of KeyDown:
        if evt.key.keysym.sym == K_ESCAPE: return
      of MouseMotion:
        cam.yaw  += float32(evt.motion.xrel) * MouseSens
        cam.pitch = clamp(
          cam.pitch - float32(evt.motion.yrel) * MouseSens,
          -PI.float32 * 0.49'f32,
           PI.float32 * 0.49'f32)
      else: discard

    let kb = getKeyboardState(nil)
    let f  = camFwd(cam)
    let r  = camRgt(cam)
    if kb[SDL_SCANCODE_W.int] != 0: cam.pos = cam.pos + f * (MoveSpeed * dt)
    if kb[SDL_SCANCODE_S.int] != 0: cam.pos = cam.pos - f * (MoveSpeed * dt)
    if kb[SDL_SCANCODE_A.int] != 0: cam.pos = cam.pos - r * (MoveSpeed * dt)
    if kb[SDL_SCANCODE_D.int] != 0: cam.pos = cam.pos + r * (MoveSpeed * dt)

    for i in 0 ..< pixels.len:
      pixels[i] = 0xFF_1A1A2E'u32
      zbuf[i]   = 0'f32

    for t in tris:
      let s0 = projectVert(t.v[0], cam)
      let s1 = projectVert(t.v[1], cam)
      let s2 = projectVert(t.v[2], cam)
      if s0.z < 0 or s1.z < 0 or s2.z < 0: continue
      let col = 0xFF000000'u32 or
                (t.r.uint32 shl 16) or
                (t.g.uint32 shl 8)  or
                t.b.uint32
      drawTri(pixels, zbuf, s0, s1, s2, col)

    discard tex.updateTexture(nil, addr pixels[0], cint(WinW * 4))
    discard ren.copy(tex, nil, nil)
    ren.present()

main()
