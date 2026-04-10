# Heightmap Loader (archived)

Saved from `src/terrain.nim` — raw f32 binary heightmap → `seq[Tri]`.

```nim
# terrain.nim — included from main.nim; Tri and Vec3 are already in scope.
#
# Loads a raw packed-f32 heightmap and returns a seq[Tri] ready to render.
# The grid has (w-1)*(h-1)*2 triangles, centred on the world origin.
#
# Tunable constants — edit these or pass overrides to loadHeightmap():
const
  TerrainW       = 245       ## columns (x-axis)
  TerrainH       = 163       ## rows    (z-axis)
  TerrainScale   = 1.0'f32   ## world units per grid cell  ← main size knob
  TerrainHScale  = 0.01'f32  ## vertical multiplier (compress tall terrain)

# ─── Colour by normalised height ──────────────────────────────────────────────
# low (0.0) → dark-green  mid (0.5) → tan  high (1.0) → snow-white

proc terrainColor(t: float32): (uint8, uint8, uint8) =
  if t < 0.35:
    let s = t / 0.35'f32
    (uint8(20  + s * 60),
     uint8(80  + s * 70),
     uint8(20  + s * 10))
  elif t < 0.65:
    let s = (t - 0.35'f32) / 0.30'f32
    (uint8(80  + s * 90),
     uint8(150 + s * 50),
     uint8(30  + s * 40))
  elif t < 0.85:
    let s = (t - 0.65'f32) / 0.20'f32
    (uint8(170 + s * 60),
     uint8(200 + s * 30),
     uint8(70  + s * 90))
  else:
    let s = (t - 0.85'f32) / 0.15'f32
    (uint8(230 + uint8(s * 25)),
     uint8(230 + uint8(s * 25)),
     uint8(160 + uint8(s * 95)))

# ─── Loader ───────────────────────────────────────────────────────────────────

proc loadHeightmap*(path: string;
                    w         = TerrainW;
                    h         = TerrainH;
                    scale     = TerrainScale;
                    hScale    = TerrainHScale): seq[Tri] =
  ## Reads a raw f32 heightmap (w*h floats, row-major) and builds terrain tris.
  ## `scale`  — world-space distance between adjacent grid vertices (X and Z).
  ## `hScale` — multiplier applied to each height sample.
  let raw      = readFile(path)
  let nFloats  = raw.len div 4

  var heights  = newSeq[float32](nFloats)
  copyMem(addr heights[0], unsafeAddr raw[0], nFloats * 4)

  # Height range for colour mapping.
  var minH = heights[0]
  var maxH = heights[0]
  for v in heights:
    if v < minH: minH = v
    if v > maxH: maxH = v
  let rng = maxH - minH

  # Centre the terrain at the world origin.
  let ox = float32(w - 1) * scale * 0.5'f32
  let oz = float32(h - 1) * scale * 0.5'f32

  template sampleH(col, row: int): float32 =
    let idx = row * w + col
    (if idx < nFloats: heights[idx] else: minH) * hScale

  template mkVert(col, row: int): Vec3 =
    vec3(float32(col) * scale - ox,
         sampleH(col, row),
         float32(row) * scale - oz)

  template normT(rawH: float32): float32 =
    if rng > 0'f32: clamp((rawH - minH) / rng, 0'f32, 1'f32) else: 0'f32

  result = newSeqOfCap[Tri]((w - 1) * (h - 1) * 2)

  for row in 0 ..< h - 1:
    for col in 0 ..< w - 1:
      let v00 = mkVert(col,     row)
      let v10 = mkVert(col + 1, row)
      let v01 = mkVert(col,     row + 1)
      let v11 = mkVert(col + 1, row + 1)

      # Upper-left triangle: v00, v10, v01
      let t1 = normT((sampleH(col,   row) +
                      sampleH(col+1, row) +
                      sampleH(col,   row+1)) / (3'f32 * hScale))
      let (r1, g1, b1) = terrainColor(t1)
      result.add Tri(v: [v00, v10, v01], r: r1, g: g1, b: b1)

      # Lower-right triangle: v10, v11, v01
      let t2 = normT((sampleH(col+1, row) +
                      sampleH(col+1, row+1) +
                      sampleH(col,   row+1)) / (3'f32 * hScale))
      let (r2, g2, b2) = terrainColor(t2)
      result.add Tri(v: [v10, v11, v01], r: r2, g: g2, b: b2)
```

## File format

`world/elevation.f32` — raw little-endian 32-bit floats, row-major, `TerrainW × TerrainH` samples.
