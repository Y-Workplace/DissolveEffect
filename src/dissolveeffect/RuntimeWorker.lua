--!native
--!optimize 2

--[=[
  @class RuntimeWorker

  RuntimeWorker computes dissolve frame data at playback time.
  A escala de resolução foi implementada para manter a proporção visual
  independente da resolução de entrada.
]=]
local b_readu8, b_writeu8 = buffer.readu8, buffer.writeu8
local b_readf32, b_writef32 = buffer.readf32, buffer.writef32
local b_readu32, b_writeu32 = buffer.readu32, buffer.writeu32
local m_floor, m_clamp, m_abs = math.floor, math.clamp, math.abs
local m_min, m_max, m_sqrt = math.min, math.max, math.sqrt
local m_sin, m_cos = math.sin, math.cos

local REF_RES = 1024
local LUT_RES = 1024
local INF = 1e9
local D1, D2 = 1, 1.414
local glowLUT = buffer.create(LUT_RES * 4)

do
	local maxGlow = 1 - (1 + 4) ^ -2

	for i = 0, LUT_RES - 1 do
		local t = i / (LUT_RES - 1)

		b_writef32(glowLUT, i * 4, 1 - ((1 - (1 + 4 * t) ^ -2) / maxGlow))
	end
end

-- Samples tileable noise with bilinear filtering and animated horizontal drift.
local function noiseWrap(
	x: number,
	y: number,
	scale: number,
	drift: number,
	nw: number,
	nh: number,
	buf: buffer
): number
	local sx = x * scale + drift
	local sy = y * scale
	local xi = m_floor(sx) % nw
	local yi = m_floor(sy) % nh

	if xi < 0 then
		xi += nw
	end

	if yi < 0 then
		yi += nh
	end

	local xi1 = (xi + 1) % nw
	local yi1 = (yi + 1) % nh
	local tx = sx - m_floor(sx)
	local ty = sy - m_floor(sy)
	local i00 = b_readu8(buf, yi * nw + xi)
	local i10 = b_readu8(buf, yi * nw + xi1)
	local i01 = b_readu8(buf, yi1 * nw + xi)
	local i11 = b_readu8(buf, yi1 * nw + xi1)
	local row0 = i00 + (i10 - i00) * tx
	local row1 = i01 + (i11 - i01) * tx

	return (row0 + (row1 - row0) * ty) / 127.5 - 1
end

-- Samples the low-resolution dissolve noise at the requested bake resolution.
local function sampleNoiseBilinear(
	x: number,
	y: number,
	w: number,
	h: number,
	buf: buffer,
	bw: number,
	bh: number
): number
	local fx = x / w * (bw - 1)
	local fy = y / h * (bh - 1)
	local x0, y0 = m_floor(fx), m_floor(fy)
	local x1 = m_min(x0 + 1, bw - 1)
	local y1 = m_min(y0 + 1, bh - 1)
	local tx, ty = fx - x0, fy - y0
	local i00 = b_readu8(buf, y0 * bw + x0)
	local i10 = b_readu8(buf, y0 * bw + x1)
	local i01 = b_readu8(buf, y1 * bw + x0)
	local i11 = b_readu8(buf, y1 * bw + x1)
	local a = i00 + (i10 - i00) * tx
	local b = i01 + (i11 - i01) * tx

	return (a + (b - a) * ty) / 255
end

-- Samples a wrapped signed-distance buffer with bilinear interpolation.
local function sampleSDF(fx: number, fy: number, w: number, h: number, buf: buffer): number
	local x0 = m_floor(fx) % w
	local y0 = m_floor(fy) % h
	local x1 = (x0 + 1) % w
	local y1 = (y0 + 1) % h
	local tx = fx - m_floor(fx)
	local ty = fy - m_floor(fy)
	local d00 = b_readf32(buf, (y0 * w + x0) * 4)
	local d10 = b_readf32(buf, (y0 * w + x1) * 4)
	local d01 = b_readf32(buf, (y1 * w + x0) * 4)
	local d11 = b_readf32(buf, (y1 * w + x1) * 4)
	local a = d00 + (d10 - d00) * tx
	local b = d01 + (d11 - d01) * tx

	return a + (b - a) * ty
end

-- Smoothstep function for edge fading.
local function smoothstep(t: number): number
	t = m_clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

-- Computes a wrapped two-pass distance field from a binary mask.
local function computeSDF(mask: buffer, w: number, h: number, out: buffer)
	for i = 0, w * h - 1 do
		b_writef32(out, i * 4, b_readu8(mask, i) > 0 and 0 or INF)
	end

	for y = 0, h - 1 do
		local py = (y - 1 + h) % h
		local ro, po = y * w, py * w

		for x = 0, w - 1 do
			local px = (x - 1 + w) % w
			local nx = (x + 1) % w
			local i = (ro + x) * 4
			local d = b_readf32(out, i)
			d = m_min(d, b_readf32(out, (ro + px) * 4) + D1)
			d = m_min(d, b_readf32(out, (po + x) * 4) + D1)
			d = m_min(d, b_readf32(out, (po + px) * 4) + D2)
			d = m_min(d, b_readf32(out, (po + nx) * 4) + D2)

			b_writef32(out, i, d)
		end
	end

	for y = h - 1, 0, -1 do
		local ny = (y + 1) % h
		local ro, no = y * w, ny * w

		for x = w - 1, 0, -1 do
			local px = (x - 1 + w) % w
			local nx = (x + 1) % w
			local i = (ro + x) * 4
			local d = b_readf32(out, i)

			d = m_min(d, b_readf32(out, (ro + nx) * 4) + D1)
			d = m_min(d, b_readf32(out, (no + x) * 4) + D1)
			d = m_min(d, b_readf32(out, (no + nx) * 4) + D2)
			d = m_min(d, b_readf32(out, (no + px) * 4) + D2)

			b_writef32(out, i, d)
		end
	end
end

-- Derives edge normals from the difference between solid and empty distance fields.
local function computeNormals(dSolid: buffer, dEmpty: buffer, w: number, h: number, normBuf: buffer)
	for y = 0, h - 1 do
		local ro = y * w

		for x = 0, w - 1 do
			local px = (x - 1 + w) % w
			local nx_ = (x + 1) % w
			local py = (y - 1 + h) % h
			local ny_ = (y + 1) % h

			local function raw(xi: number, yi: number): number
				return b_readf32(dSolid, (yi * w + xi) * 4) - b_readf32(dEmpty, (yi * w + xi) * 4)
			end

			local dx = raw(nx_, y) - raw(px, y)
			local dy = raw(x, ny_) - raw(x, py)
			local len = m_sqrt(dx * dx + dy * dy) + 1e-5
			local base = (ro + x) * 8

			b_writef32(normBuf, base, dx / len)
			b_writef32(normBuf, base + 4, dy / len)
		end
	end
end

--[=[
  @param data Data
  @return buffer
  @return buffer

  Computes a dissolve effect for a single runtime frame.
  Returns the base and emissive output buffers.
]=]
local function RuntimeFrame(data: Data): (buffer, buffer)
	local config = data.config
	local w, h = data.width, data.height
	local resScale = m_max(w, h) / REF_RES
	local total = w * h
	local nw, nh = data.noiseWidth, data.noiseHeight
	local nBuf = data.noiseBuffer
	local isBase = data.isBase

	local pW = m_max(1, m_floor(w * 0.25))
	local pH = m_max(1, m_floor(h * 0.25))
	local pCount = pW * pH
	local SDF_SCALE = 0.25

	local toNX = nw / pW
	local toNY = nh / pH

	local maskBuf = data.rt.maskBuf
	local invBuf = data.rt.invBuf
	local dSolid = data.rt.dSolid
	local dEmpty = data.rt.dEmpty
	local normBuf = data.rt.normBuf
	local distBuf = data.rt.distBuf

	local baseOut = data.baseOut or buffer.create(data.totalBytes)
	local emissiveOut = data.emissiveOut or buffer.create(data.totalBytes)

	if isBase then
		buffer.fill(emissiveOut, 0, 0, data.totalBytes)
	end

	local threshold = data.threshold
	local tTime = data.tTime
	local EdgeWidth = m_max(config.EdgeWidth * resScale * 0.4, 0.1)
	local GlowWidth = m_max(config.GlowWidth * resScale * 0.5, 0.1)
	local warpStrength = config.WarpStrength * resScale
	local dirPixelOffset = 4 * resScale

	for i = 0, pCount - 1 do
		local x = i % pW
		local y = m_floor(i / pW)
		local n = sampleNoiseBilinear(x, y, pW, pH, nBuf, nw, nh)
		local s = n > threshold and 255 or 0
		b_writeu8(maskBuf, i, s)
		b_writeu8(invBuf, i, s > 0 and 0 or 255)
	end

	computeSDF(invBuf, pW, pH, dEmpty)
	computeSDF(maskBuf, pW, pH, dSolid)
	computeNormals(dSolid, dEmpty, pW, pH, normBuf)

	local edgeWSDF = m_max(EdgeWidth * SDF_SCALE, 0.1)
	local edgeR = config.Color.R * 255
	local edgeG = config.Color.G * 255
	local edgeB = config.Color.B * 255
	local regFreq = config.RegionFrequency
	local thickGain = config.ThicknessGain
	local thickBias = config.ThicknessBias
	local invTG1 = 1 / (1 + thickGain)

	local edgeBand = edgeWSDF * (1 + thickGain) * 1.6 + (1.5 * resScale)
	local centerX = pW * 0.5
	local centerY = pH * 0.5
	local radialDenom = m_max(pW, pH)
	local radialFreq = m_max(regFreq, 0.1)
	local drift1 = tTime * 0.4 * nw
	local drift2 = tTime * 0.5 * nw
	local drift3 = tTime * 0.2 * nw
	local drift4 = tTime * 0.3 * nw
	local drift5 = tTime * 0.1 * nw

	for y = 0, h - 1 do
		local rowOff = y * w
		local gfy = (y + 0.5) * SDF_SCALE

		for x = 0, w - 1 do
			local gfx = (x + 0.5) * SDF_SCALE
			local idx = (rowOff + x) * 4
			local dS = sampleSDF(gfx, gfy, pW, pH, dSolid)
			local dE = sampleSDF(gfx, gfy, pW, pH, dEmpty)
			local rawDist = dS - dE
			local br, bg, bb, ba = 0, 0, 0, 0
			local er, eg, eb, ea = 0, 0, 0, 0

			if rawDist <= 0 then
				br = b_readu8(data.baseBuffer, idx)
				bg = b_readu8(data.baseBuffer, idx + 1)
				bb = b_readu8(data.baseBuffer, idx + 2)

				ba = 255
			end

			if m_abs(rawDist) < edgeBand then
				local ni = (m_floor(gfy) % pH * pW + m_floor(gfx) % pW) * 8
				local nx = b_readf32(normBuf, ni)
				local ny = b_readf32(normBuf, ni + 4)
				local ex = gfx - nx * rawDist
				local ey = gfy - ny * rawDist
				local enx = ex * toNX
				local eny = ey * toNY
				local warpN = noiseWrap(enx, eny, 1.5, drift1, nw, nh, nBuf)
				local warp2 = noiseWrap(enx, eny, 2.5, drift2, nw, nh, nBuf)
				local warpedDist = rawDist + warpN * warpStrength * 0.5 + warp2 * edgeWSDF * 0.3
				local warpedAbs = m_abs(warpedDist)
				local n1 = noiseWrap(enx, eny, 1.0, drift3, nw, nh, nBuf) * 0.5 + 0.5
				local n2 = noiseWrap(enx, eny, 2.0, drift4, nw, nh, nBuf) * 0.5 + 0.5
				local hf = noiseWrap(enx * 1.7 + 13.1, eny * 1.3 - 7.2, 6.0, drift2, nw, nh, nBuf) * 0.5 + 0.5
				local dx = (gfx - centerX) / radialDenom
				local dy = (gfy - centerY) / radialDenom
				local radius = m_sqrt(dx * dx + dy * dy)
				local invRadius = 1 / (radius + 1e-5)
				local dirX = dx * invRadius
				local dirY = dy * invRadius
				local radialPhase = radius * radialFreq * 6.28318530718 - tTime * 1.15
				local radialN = m_sin(radialPhase) * 0.42
					+ m_cos(radialPhase * 0.57 + (dirX * 1.7 - dirY * 1.3) * radialFreq) * 0.28
				local regionN = noiseWrap(enx * radialFreq * 0.35, eny * radialFreq * 0.35, 1.0, drift5, nw, nh, nBuf)
				local dirN = noiseWrap(
					enx + -ny * dirPixelOffset * toNX,
					eny + nx * dirPixelOffset * toNY,
					3.0,
					drift1,
					nw,
					nh,
					nBuf
				)
				local detail = (n1 * 2 - 1) * 0.22 + (n2 * 2 - 1) * 0.14 + (hf * 2 - 1) * 0.12 + dirN * 0.08
				local alpha = smoothstep(0.5 + radialN + regionN * 0.22 + thickBias)
				local tFac = m_clamp(invTG1 + ((1 + thickGain) - invTG1) * alpha + detail * 0.08, invTG1, 1 + thickGain)
				local dynEdge = m_max(edgeWSDF * tFac, 0.1)
				local edgeAlpha = m_clamp(1 - m_clamp((warpedAbs - dynEdge) / (1.25 * EdgeWidth), 0, 1), 0, 1)

				if edgeAlpha > 0 then
					if isBase then
						br = edgeR
						bg = edgeG
						bb = edgeB
						ba = 255
						er, eg, eb, ea = 255, 255, 255, 255
					else
						er, eg, eb, ea = edgeR, edgeG, edgeB, 255
					end
				end
			end

			b_writeu32(baseOut, idx, m_floor(br) + m_floor(bg) * 256 + m_floor(bb) * 65536 + m_floor(ba) * 16777216)
			b_writeu32(emissiveOut, idx, m_floor(er) + m_floor(eg) * 256 + m_floor(eb) * 65536 + m_floor(ea) * 16777216)
		end
	end

	if not isBase then
		for i = 0, total - 1 do
			local eAlpha = m_floor(b_readu32(emissiveOut, i * 4) / 16777216)
			b_writef32(distBuf, i * 4, eAlpha > 128 and 0 or INF)
		end

		for y = 0, h - 1 do
			local ym1 = (y == 0) and (h - 1) or (y - 1)
			local ro, rym = y * w, ym1 * w

			for x = 0, w - 1 do
				local xm1 = (x == 0) and (w - 1) or (x - 1)
				local xp1 = (x == w - 1) and 0 or (x + 1)
				local idx = (ro + x) * 4
				local d = b_readf32(distBuf, idx)

				d = m_min(d, b_readf32(distBuf, (ro + xm1) * 4) + D1)
				d = m_min(d, b_readf32(distBuf, (rym + x) * 4) + D1)
				d = m_min(d, b_readf32(distBuf, (rym + xm1) * 4) + D2)
				d = m_min(d, b_readf32(distBuf, (rym + xp1) * 4) + D2)

				b_writef32(distBuf, idx, d)
			end
		end

		for y = h - 1, 0, -1 do
			local yp1 = (y == h - 1) and 0 or (y + 1)
			local ro, ryp = y * w, yp1 * w

			for x = w - 1, 0, -1 do
				local xm1 = (x == 0) and (w - 1) or (x - 1)
				local xp1 = (x == w - 1) and 0 or (x + 1)
				local idx = (ro + x) * 4
				local d = b_readf32(distBuf, idx)

				d = m_min(d, b_readf32(distBuf, (ro + xp1) * 4) + D1)
				d = m_min(d, b_readf32(distBuf, (ryp + x) * 4) + D1)
				d = m_min(d, b_readf32(distBuf, (ryp + xp1) * 4) + D2)
				d = m_min(d, b_readf32(distBuf, (ryp + xm1) * 4) + D2)

				b_writef32(distBuf, idx, d)
			end
		end

		local gWidth = GlowWidth * 50
		local invGW = 1 / gWidth
		local glowR = config.GlowColor.R
		local glowG = config.GlowColor.G
		local glowB = config.GlowColor.B

		for i = 0, total - 1 do
			local d = b_readf32(distBuf, i * 4)

			if d > 0 and d < gWidth then
				local lutIdx = m_floor(d * invGW * (LUT_RES - 1))
				local gAlpha = b_readf32(glowLUT, lutIdx * 4)
				local cIdx = i * 4
				local cur = b_readu32(emissiveOut, cIdx)
				local pa = m_floor(cur / 16777216)
				local pb = m_floor(cur / 65536) % 256
				local pg = m_floor(cur / 256) % 256
				local pr = cur % 256
				local inten = gAlpha * 255
				local r = m_min(255, pr + glowR * inten)
				local g = m_min(255, pg + glowG * inten)
				local b = m_min(255, pb + glowB * inten)
				local a = m_max(pa, inten)

				b_writeu32(
					emissiveOut,
					cIdx,
					m_floor(r) + m_floor(g) * 256 + m_floor(b) * 65536 + m_floor(a) * 16777216
				)
			end
		end
	end

	return baseOut, emissiveOut
end

--[=[
  @within RuntimeWorker
  @interface Config
  @field Color Color3
  @field GlowColor Color3
  @field EdgeWidth number
  @field GlowWidth number
  @field BakeFrames number
  @field RegionFrequency number
  @field ThicknessGain number
  @field ThicknessBias number
  @field WarpStrength number

  Visual settings required to compute a dissolve in runtime.
]=]
type Config = {
	Color: Color3,
	GlowColor: Color3,
	EdgeWidth: number,
	GlowWidth: number,
	BakeFrames: number,
	RegionFrequency: number,
	ThicknessGain: number,
	ThicknessBias: number,
	WarpStrength: number,
}

--[=[
  @within RuntimeWorker
  @interface RuntimeBuffers
  @field maskBuf buffer
  @field invBuf buffer
  @field dSolid buffer
  @field dEmpty buffer
  @field normBuf buffer
  @field distBuf buffer

  Reusable scratch buffers shared by a single bake chunk.
]=]
type RuntimeBuffers = {
	maskBuf: buffer,
	invBuf: buffer,
	dSolid: buffer,
	dEmpty: buffer,
	normBuf: buffer,
	distBuf: buffer,
}

--[=[
  @within RuntimeWorker
  @interface Data
  @field config Config
  @field width number
  @field height number
  @field totalBytes number
  @field noiseWidth number
  @field noiseHeight number
  @field noiseBuffer buffer
  @field baseBuffer buffer
  @field threshold number
  @field tTime number
  @field baseOut buffer?
  @field emissiveOut buffer?
  @field isBase boolean
  @field rt RuntimeBuffers
]=]
type Data = {
	config: Config,
	width: number,
	height: number,
	totalBytes: number,
	noiseWidth: number,
	noiseHeight: number,
	noiseBuffer: buffer,
	baseBuffer: buffer,
	threshold: number,
	tTime: number,
	baseOut: buffer?,
	emissiveOut: buffer?,
	isBase: boolean,
	rt: RuntimeBuffers,
}

return RuntimeFrame
