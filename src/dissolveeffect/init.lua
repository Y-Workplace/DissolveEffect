--!native
--!optimize 2

--[=[
==============================================================================
==                              Dissolve Engine                             ==
==============================================================================

	A configurable dissolve effect system for Roblox capable of dissolving
	3D objects, textures, overlays, and UI elements using animated pixel masks.

	The system can generate dissolve effects in multiple ways:
	* Fully pre-baked for maximum playback performance
	* Hybrid mask baking for reduced memory usage
	* Fully runtime-generated for dynamic effects

	The dissolve effect supports:
	* Glowing edges
	* Noise-based dissolve patterns
	* Emissive rendering
	* Animated reconstruction ("Appear" mode)
	* Shared bake caching between identical effects
	* Parallel baking using Actors
	* EditableImage rendering
	* SurfaceAppearance integration

	Supported Objects:
	* Parts
	* MeshParts
	* SurfaceAppearances (ColorMap Only)
	* Decals
	* Textures
	* ImageLabels
	* ImageButtons

	The module is designed to:
	* Handle large amounts of dissolve effects efficiently
	* Reduce duplicated processing through shared caches
	* Keep runtime playback smooth after preparation
	* Allow customizable visual styles and dissolve behaviors

	Runtime Notes:
	* Runs only on the client
	* Requires EditableImage API enabled
	* Intended for LocalScript environments

	License:
		MIT License

	Author:
		Y-Hythm — 2026

==============================================================================
]=]

local RunService = game:GetService("RunService")
if RunService:IsServer() then
	warn("[Dissolve]: EditableImage is client-side only. Module will not run on the server.")
	return {} :: Dissolve
end

local AssetService = game:GetService("AssetService")

local success = pcall(function()
	task.wait()
	local i = AssetService:CreateEditableImage()
	i:ReadPixelsBuffer(Vector2.zero, Vector2.one)
	return i
end)

if not success then
	warn("[Dissolve]: EditableImage API is not enabled in this experience.")
	return {} :: Dissolve
end

local Packages = script.Parent.Parent.Parent
local Signal = require(Packages.Signal)
local JobManager = require(script:WaitForChild("JobManager"))
local RuntimeWorker = require(script:WaitForChild("RuntimeWorker"))

-- Avoid lookups
local mathClamp = math.clamp
local mathNoise = math.noise
local mathRandom = math.random
local mathFloor = math.floor
local mathPi2 = math.pi * 2
local mathCos = math.cos
local mathSin = math.sin
local bufferWriteu8 = buffer.writeu8
local bufferWriteu32 = buffer.writeu32
local bufferCreate = buffer.create
local bufferCopy = buffer.copy
local bufferReadu8 = buffer.readu8
local bufferLen = buffer.len
local mathMin = math.min
local mathMax = math.max
local bit32Band = bit32.band
local bit32Rshift = bit32.rshift
local tableCreate = table.create
local v3 = Vector3.new

local BaseFolder = Instance.new("Folder")
BaseFolder.Name = "BaseMask"
BaseFolder.Parent = workspace

local temp = Instance.new("Folder")
temp.Name = "DissolveEffect"
temp.Parent = game:GetService("Players").LocalPlayer.PlayerScripts

JobManager:Init(script:WaitForChild("Actor"), temp)

local BYTES_PP = 4

local bakeCache: { [string]: BakeCacheEntry } = {}
local registerCache: { [string]: SignalObject } = {}
local noiseBufferCache: { [string]: NoiseBufferEntry } = {}
local AssetCache: { [number]: {
	state: boolean,
	info: string,
} } = {}

local defaults = {
	Color = Color3.fromRGB(247, 249, 18),
	GlowColor = Color3.fromRGB(255, 85, 0),
	Speed = 0.15,
	EdgeWidth = 5,
	GlowWidth = 5,
	NoiseScale = 0.5,
	NoiseResolution = 64,
	BakeFrames = 60,
	Size = Vector2.new(128, 128),
	RegionFrequency = 10,
	ThicknessGain = 6,
	ThicknessBias = 0,
	WarpStrength = 0,
	Bake = "Full", -- "Full" | "Mask" | "None"
	YieldMode = "Relaxed", -- "Aggressive" | "Balanced" | "Relaxed"
	NoiseMap = nil,
	TransformAutoUpdateEnabled = true,
	EmissiveStrength = 5.75,

	Behavior = {
		ShowProgress = true,
		AutoDiscover = "All", -- "All" | "Children" | "None"
	},

	Blacklist = {},
}

local shapeToMesh = {
	[Enum.PartType.Ball] = "rbxassetid://128964124285205",
	[Enum.PartType.Block] = "rbxassetid://99921273059490",
	[Enum.PartType.Cylinder] = "rbxassetid://104841802306455",
	[Enum.PartType.Wedge] = "rbxassetid://91285112329400",
	[Enum.PartType.CornerWedge] = "rbxassetid://128951775158237",
}

local shapeMap: { [Enum.PartType]: ScaleFn } = {
	[Enum.PartType.Ball] = function(s)
		local d = mathMin(s.X, s.Y, s.Z)
		return v3(d, d, d)
	end,

	[Enum.PartType.Cylinder] = function(s)
		local d = mathMin(s.Y, s.Z)
		return v3(s.X, d, d)
	end,
}

local supportedObjects = {
	Part = "Base",
	MeshPart = "Base",
	Decal = "Overlay",
	Texture = "Overlay",
	ImageLabel = "UI",
	ImageButton = "UI",
}

local modifiers = {
	SpecialMesh = true,
	SurfaceAppearance = true,
	Decal = true,
	Texture = true,
}

--[=[
	@class Dissolve

	A Dissolve effect builds temporary masks for Roblox objects and animates
	their pixels through a configurable dissolve pass.

	The module supports 3D parts, mesh parts, decals, textures, and image UI.
	Depending on the selected bake mode, frames can be precomputed, partially
	precomputed, or generated at runtime.

	Run this module from a LocalScript or another client-side context. The module
	returns an empty table on the server or when EditableImage is unavailable.

	For example:
	```lua
	local dissolve = Dissolve.new({ workspace.Model }, {
		Bake = "Mask",
		Speed = 0.2,
	})

	dissolve.StateChanged:Connect(function(state)
		print("Dissolve state:", state)
	end)

	dissolve.Ready:Connect(function()
		dissolve:Start()
	end)
	```
]=]
local Dissolve = {}
Dissolve.__index = Dissolve

--[=[
	@within Dissolve
	@interface Dissolve
	* State: string
	* Completed: Signal
	* Ready: Signal
	* StateChanged: Signal

	Runtime object returned by `Dissolve.new`.

	`Ready` fires when all targets are prepared and `Start` can be called.
	`StateChanged` fires for lifecycle changes such as `"Baking"`, `"Ready"`,
	`"Running"`, and `"Destroyed"`. `Completed` fires when the current playback
	reaches the end, before the effect resets to `Ready`.
]=]
export type Dissolve = typeof(setmetatable(
	{} :: {
		State: string,
		_bakingProgress: string,
		_destroyed: boolean,
		Completed: SignalObject,
		Ready: SignalObject,
		StateChanged: SignalObject,
		_config: Config,
		_conn: SchedulerHandle?,
		_progress: number,
		_currentFrame: number,
		_center: Vector3?,
		_instances: { ResolvedTarget }?,
		_bakingCount: number,
		_readyCount: number,
		_part: Part?,
		_billboard: BillboardGui?,
		_label: TextLabel?,
		_glowLUT: { number }?,
		_query: { JobManager.JobHandle },
	},
	Dissolve
))

-- Keeps a shared baked frame cache / noise buffer cache alive while a target still references it.
local function RetainCache(key: string)
	local entry = bakeCache[key] or noiseBufferCache[key]
	if entry then
		entry.refCount += 1
	end
end

-- Releases a baked frame cache / noise buffer cache entry once no active dissolve instance uses it.
local function ReleaseCache(key: string)
	local entry = bakeCache[key] or noiseBufferCache[key]
	if not entry then
		return
	end
	entry.refCount -= 1
	if entry.refCount <= 0 then
		bakeCache[key] = nil
		noiseBufferCache[key] = nil
	end
end

-- Generates seamless noise by sampling around a torus-shaped coordinate space.
local function TileableNoise(x: number, y: number, w: number, h: number, scale: number, seed: number): number
	local u = x / w
	local v = y / h
	local angleU = u * mathPi2
	local angleV = v * mathPi2
	local nx = mathCos(angleU) * scale
	local ny = mathSin(angleU) * scale
	local nz = mathCos(angleV) * scale
	local nw = mathSin(angleV) * scale
	return mathNoise(nx + seed, ny, nz + nw)
end

-- Converts a Color3 into a stable cache key component.
local function ColorToKey(c: Color3): string
	return mathFloor(c.R * 255) .. "_" .. mathFloor(c.G * 255) .. "_" .. mathFloor(c.B * 255)
end

-- Packs a Color3 into an integer for texture-less cache keys.
local function ColorToID(c: Color3): number
	return mathFloor(c.R * 255) * 0x10000 + mathFloor(c.G * 255) * 0x100 + mathFloor(c.B * 255)
end

-- Builds the full bake cache key from the source asset and all visual settings.
local function GetBakeKey(id: string | number, config: Config, size: Vector2, isBase: boolean): string
	return table.concat({
		tostring(id),
		tostring(size.X),
		tostring(size.Y),
		ColorToKey(config.Color),
		tostring(config.Speed),
		tostring(config.EdgeWidth),
		tostring(config.GlowWidth),
		ColorToKey(config.GlowColor),
		tostring(config.NoiseScale),
		tostring(config.NoiseResolution),
		tostring(config.BakeFrames),
		tostring(config.RegionFrequency),
		tostring(config.ThicknessGain),
		tostring(config.ThicknessBias),
		tostring(config.WarpStrength),
		tostring(config.Bake),
		tostring(isBase),
		tostring(config.NoiseMap or ""),
	}, "|")
end

-- EditableImages cannot be resized in-place, so a new image is drawn from the source.
local function ResizeEditableImage(src: EditableImage, newSize: Vector2): EditableImage
	task.wait()
	local dst = AssetService:CreateEditableImage({ Size = newSize })
	dst:DrawImageTransformed(newSize / 2, Vector2.new(newSize.X / src.Size.X, newSize.Y / src.Size.Y), 0, src, {
		CombineType = Enum.ImageCombineType.Overwrite,
		SamplingMode = Enum.ResamplerMode.Default,
		PivotPoint = src.Size / 2,
	})

	src:Destroy()

	return dst
end

-- Returns the MeshSize of a mesh asset by creating a temporary MeshPart instance. This is required to compute the correct UV scale for meshes that don't use SpecialMeshes.
local function GetMeshSizeFromMeshId(meshId: string): Vector3
	task.wait()
	local meshPart = AssetService:CreateMeshPartAsync(Content.fromUri(meshId))

	local size = meshPart.MeshSize
	meshPart:Destroy()

	return size
end

-- Returns the equivalent MeshPart.Size from a SpecialMesh.Scale and the original MeshSize
local function GetSizeFromScaleAndMeshSize(Scale: Vector3, MeshSize: Vector3): Vector3
	return Scale * MeshSize
end

-- Validates that an asset ID can be used to create an EditableImage, and returns the ID along with a once-created EditableImage if successful.
local function ValidateAsset(assetId: number?): (number?, EditableImage?)
	if not assetId then
		return
	end

	local cached = AssetCache[assetId]
	if cached then
		if cached.state == false then
			warn(string.format("[Dissolve] Failed to validate asset %d. \nERROR: %s", assetId, tostring(cached.info)))
		end
		return cached.state
	end

	local success, result = pcall(function()
		task.wait()
		return AssetService:CreateEditableImageAsync(Content.fromAssetId(assetId))
	end)

	if not success or not result then
		local errorMsg = result or "Unknown Error (Check Permissions)"
		warn(string.format("[Dissolve] Failed to validate asset %d. \nERROR: %s", assetId, tostring(errorMsg)))

		AssetCache[assetId] = {
			state = false,
			info = errorMsg,
		}
		return
	end

	AssetCache[assetId] = {
		state = assetId,
		info = "Success",
	}

	return assetId, result
end

-- Parses an image asset ID from a string and validates it for use in editable images.
local function ResolveAsset(s: string?): (number?, EditableImage?)
	if not s or s == "" then
		return nil
	end

	local id = tonumber(s:match("%d+"))

	if not id then
		return nil
	end

	return ValidateAsset(id)
end

-- Returns paired callbacks that hide and restore an object's original visibility.
local function CreateVisibilityWrapper(instance: any, originalProp: string): (() -> (), () -> ())
	local originalValue = instance[originalProp]
	return function()
		instance[originalProp] = 1
	end, function()
		instance[originalProp] = originalValue
	end
end

-- Collects supported roots and optional visual modifiers from the requested instances.
local function DiscoverTargets(instances: { Instance }, config: Config): { [Instance]: { [string]: { Instance } } }
	local targets: { [Instance]: { [string]: { Instance } } } = {}
	local mode = config.Behavior.AutoDiscover

	local function process(obj: Instance)
		if supportedObjects[obj.ClassName] then
			targets[obj] = targets[obj] or {}

			if mode ~= "None" then
				for _, child in ipairs(obj:GetChildren()) do
					if modifiers[child.ClassName] then
						targets[obj][child.ClassName] = targets[obj][child.ClassName] or {}
						table.insert(targets[obj][child.ClassName], child)
					end
				end
			end
		end
	end

	for _, root in ipairs(instances) do
		process(root)
		if mode == "All" then
			for _, desc in ipairs(root:GetDescendants()) do
				process(desc)
			end
		end
	end

	return targets
end

-- Converts discovered Roblox instances into normalized dissolve targets.
local function ResolveTargets(
	discovered: { [Instance]: { [string]: { Instance } } },
	config: Config
): { ResolvedTarget }
	local resolved: { ResolvedTarget } = {}
	local visited: { [Instance]: boolean } = {}

	local blacklist = {}
	for _, v in ipairs(config.Blacklist) do
		blacklist[v] = true
	end

	for instance, children in pairs(discovered) do
		if blacklist[instance] or visited[instance] then
			continue
		end

		if instance:IsA("ImageLabel") or instance:IsA("ImageButton") then
			local id, editableImage = ResolveAsset(instance.Image)
			local hide, show = CreateVisibilityWrapper(instance, "ImageTransparency")
			table.insert(resolved, {
				type = "UI",
				parent = instance.Parent :: Instance,
				textureID = id,
				editableImage = editableImage,
				GetColor = function()
					return instance.ImageColor3
				end,
				Hide = hide,
				Show = show,
				Clone = function()
					return instance:Clone()
				end,
			})
			visited[instance] = true
			continue
		end

		if instance:IsA("Decal") or instance:IsA("Texture") then
			local id, editableImage = ResolveAsset(instance.Texture)
			local hide, show = CreateVisibilityWrapper(instance, "Transparency")
			table.insert(resolved, {
				type = "Overlay",
				parent = instance.Parent :: Instance,
				textureID = id,
				editableImage = editableImage,
				GetColor = function()
					return (instance :: any).Color3 or Color3.new(1, 1, 1)
				end,
				Hide = hide,
				Show = show,
				Clone = function()
					return instance:Clone()
				end,
			})
			visited[instance] = true
			continue
		end

		if instance:IsA("BasePart") then
			local hide, show = CreateVisibilityWrapper(instance, "Transparency")
			local baseTextureID: number?, editableImage: EditableImage? = nil, nil
			local baseMeshID: string? = instance:IsA("MeshPart") and instance.MeshId or nil

			local sm: SpecialMesh? = children.SpecialMesh and children.SpecialMesh[1]

			if sm then
				baseMeshID = sm.MeshId

				baseTextureID, editableImage = ResolveAsset(sm.TextureId)
			end

			local sa: SurfaceAppearance? = children.SurfaceAppearance and children.SurfaceAppearance[1]

			if sa and not baseTextureID then
				local ok, content = pcall(function()
					return sa.ColorMapContent
				end)

				if ok and content and content.Uri then
					baseTextureID, editableImage = ResolveAsset(content.Uri)
				end
			end

			if not baseTextureID and instance:IsA("MeshPart") then
				baseTextureID, editableImage = ResolveAsset(instance.TextureID)
			end

			if baseMeshID or (instance:IsA("Part") and not sm) then
				local MeshSize
				if baseMeshID and sm and not instance:IsA("MeshPart") then
					MeshSize = GetMeshSizeFromMeshId(baseMeshID)
				end
				table.insert(resolved, {
					type = "Base",
					parent = instance,
					textureID = baseTextureID,
					editableImage = editableImage,
					meshID = baseMeshID or (instance:IsA("Part") and shapeToMesh[instance.Shape]),
					GetParentCframe = function()
						return instance.CFrame
					end,
					GetSize = baseMeshID and function()
						return sm
								and GetSizeFromScaleAndMeshSize(
									sm.Scale,
									(instance:IsA("MeshPart") and instance.MeshSize or MeshSize)
								)
							or instance.Size
					end or nil,
					GetColor = function()
						return instance.Color
					end,
					Hide = hide,
					Show = show,
					Clone = function()
						task.wait()
						local clone
						clone = instance:IsA("MeshPart") and instance:Clone()
							or AssetService:CreateMeshPartAsync(
								Content.fromUri(baseMeshID or (instance:IsA("Part") and shapeToMesh[instance.Shape]))
							)
						for _, child in ipairs(clone:GetChildren()) do
							child:Destroy()
						end
						return clone
					end,
				})
			end

			for _, className in ipairs({ "Decal", "Texture" }) do
				if children[className] then
					for _, obj in ipairs(children[className]) do
						if blacklist[obj] or visited[obj] then
							continue
						end
						local tid, teditableImage = ResolveAsset((obj :: any).Texture)
						local oHide, oShow = CreateVisibilityWrapper(obj, "Transparency")
						table.insert(resolved, {
							type = "Overlay",
							parent = instance,
							textureID = tid,
							editableImage = teditableImage,
							GetColor = function()
								return (obj :: any).Color3 or Color3.new(1, 1, 1)
							end,
							Hide = oHide,
							Show = oShow,
							Clone = function()
								return obj:Clone()
							end,
						})
						visited[obj] = true
						task.wait()
					end
				end
			end
		end
		task.wait()
	end

	return resolved
end

-- Returns the mesh scale needed to cover the original Part shape.
local function ComputeMeshScale(part: Part): Vector3
	local size = part.Size
	local fn = shapeMap[part.Shape]

	if fn then
		return fn(size)
	end

	return size
end

-- Updates the Base mask's transform to match its parent object, if it has one. This is required to keep the mask aligned during baking and when the target is animated.
local function UpdateBaseMaskTransform(
	obj: { GetParentCframe: () -> CFrame, Mask: DissolveMask, parent: Part } & ResolvedTarget
)
	if obj.type ~= "Base" then
		return
	end

	local cf = obj.GetParentCframe()
	if obj.BaseCFrame ~= cf then
		obj.Mask.CFrame = cf
		obj.BaseCFrame = cf
	end

	local sc = (obj.GetSize and obj.GetSize() or ComputeMeshScale(obj.parent)) * 0.99

	if obj.BaseScale ~= sc then
		obj.Mask.Size = sc
		obj.BaseScale = sc
	end
end

--[=[
	@param instances { Instance } -- Objects that should receive the dissolve effect.
	@param config PartialConfig? -- Optional settings that override the defaults.
	@return Dissolve

	Constructs a new Dissolve effect and starts preparing its target masks.

	Targets are discovered from the given instances according to
	`Behavior.AutoDiscover`. The instance enters the `Ready` state after all
	required editable images and baked frames are prepared. If you create the
	effect with `Bake = "None"`, preparation is minimal and frames are generated
	at runtime when `Start` is called.
	```lua
	local dissolve = Dissolve.new({ workspace.Character }, {
		Bake = "Mask",
		Speed = 0.25,
		Behavior = {
			ShowProgress = true,
			AutoDiscover = "All",
		},
	})

	if dissolve:IsReady() then
		dissolve:Start()
	else
		dissolve.Ready:Connect(function()
			dissolve:Start()
		end)
	end
	```
]=]
function Dissolve.new(instances: { Instance }, config: PartialConfig?): Dissolve
	local self: Dissolve = setmetatable({}, Dissolve) :: Dissolve

	self.State = "Idle"
	self._bakingProgress = "Baking..."
	self._destroyed = false
	self.Completed = Signal.new()
	self.Ready = Signal.new()
	self.StateChanged = Signal.new()
	self._config = table.clone(defaults)
	self._conn = nil
	self._progress = 0
	self._currentFrame = 0
	self._query = {}

	if config then
		for k, v in pairs(config) do
			self._config[k] = v
		end
	end

	local discovered = DiscoverTargets(instances, self._config)
	local resolved = ResolveTargets(discovered, self._config)

	local count = 0
	local position = Vector3.zero
	for _, obj in ipairs(resolved) do
		if obj.GetParentCframe then
			count += 1
			position += obj.GetParentCframe().Position
		end
	end
	self._center = (count > 0) and (position / count) or nil
	self._instances = resolved

	self._bakingCount = 0
	self._readyCount = 0

	if self._config.Behavior.ShowProgress and count > 0 and self._config.Bake ~= "None" then
		self:_CreateBillboard()
	end

	for _, obj in ipairs(resolved) do
		self._bakingCount += 1
	end

	for _, obj in ipairs(resolved) do
		if obj.type == "Base" then
			local BaseMesh = obj.Clone()
			BaseMesh.Name = "Mask"
			BaseMesh.Transparency = 1
			BaseMesh.Color = Color3.new(1, 1, 1)
			BaseMesh.CanCollide = false
			BaseMesh.CanQuery = false
			BaseMesh.CanTouch = false
			BaseMesh.AudioCanCollide = false
			BaseMesh.Anchored = true

			obj.Mask = BaseMesh

			UpdateBaseMaskTransform(obj)

			obj.Mask.Parent = BaseFolder
		elseif obj.type == "Overlay" then
			obj.Mask = { Base = obj.Clone(), Overlay = obj.Clone() }
			obj.Mask.Overlay.Color3 = Color3.fromRGB(500, 500, 500)
			obj.Mask.Base.Name = "Base"
			obj.Mask.Overlay.Name = "Overlay"
			obj.Mask.Overlay.ZIndex += 1
			obj.Mask.Base.Transparency = 1
			obj.Mask.Overlay.Transparency = 1
			RunService.Heartbeat:Wait() -- Move to the next frame
			task.defer(function()
				obj.Mask.Base.Parent = obj.parent
				obj.Mask.Overlay.Parent = obj.parent
			end)
		else
			obj.Mask = { Base = obj.Clone(), Overlay = obj.Clone() }
			obj.Mask.Overlay.ImageColor3 = Color3.fromRGB(255, 255, 255)
			obj.Mask.Base.BackgroundTransparency = 1
			obj.Mask.Overlay.BackgroundTransparency = 1
			obj.Mask.Base.Name = "Base"
			obj.Mask.Overlay.Name = "Overlay"
			obj.Mask.Base.ZIndex -= 2
			obj.Mask.Overlay.ZIndex -= 1
			obj.Mask.Base.Visible = true
			obj.Mask.Overlay.Visible = true
			obj.Mask.Base.ImageTransparency = 1
			obj.Mask.Overlay.ImageTransparency = 1
			obj.Mask.Base.Parent = obj.parent
			obj.Mask.Overlay.Parent = obj.parent
		end
		self:Prepare(obj)
		task.wait()
	end

	return self
end

--[=[
	@param obj ResolvedTarget

	Prepares editable images, buffers, and cached bake data for a resolved target.

	This is called internally by `Dissolve.new` and `Dissolve:SetConfig`.
]=]
function Dissolve.Prepare(self: Dissolve, obj: { Mask: DissolveMask } & ResolvedTarget)
	local editable
	local textureID = obj.textureID

	task.wait()
	if textureID then
		editable = obj.editableImage or AssetService:CreateEditableImageAsync(Content.fromAssetId(textureID))
	else
		editable = AssetService:CreateEditableImage({ Size = self._config.Size })
	end

	if editable.Size ~= self._config.Size then
		editable = ResizeEditableImage(editable, self._config.Size)
	end

	task.wait()
	local emissiveEditable = AssetService:CreateEditableImage({ Size = self._config.Size })

	obj.editable = editable
	obj.emissiveEditable = emissiveEditable

	if obj.type == "Base" then
		task.wait()
		local surface = AssetService:CreateSurfaceAppearanceAsync({
			ColorMap = Content.fromObject(editable),
			EmissiveMask = Content.fromObject(emissiveEditable),
		})

		surface.Name = "Surface"
		surface.AlphaMode = Enum.AlphaMode.Transparency
		surface.EmissiveStrength = self._config.EmissiveStrength
		surface.EmissiveTint = self._config.GlowColor
		surface.Parent = obj.Mask
	elseif obj.type == "Overlay" then
		obj.Mask.Base.ColorMapContent = Content.fromObject(editable)
		obj.Mask.Overlay.ColorMapContent = Content.fromObject(emissiveEditable)
	else
		obj.Mask.Base.ImageContent = Content.fromObject(editable)
		obj.Mask.Overlay.ImageContent = Content.fromObject(emissiveEditable)
	end

	local size = editable.Size
	obj.width = size.X
	obj.height = size.Y
	obj.size = size

	local id = obj.textureID
	if not id or id == "" then
		id = ColorToID(obj.GetColor())
	end

	local key = GetBakeKey(id, self._config, size, obj.type == "Base")

	local function ApplyCachedBake()
		local baked = bakeCache[key]

		RetainCache(key)
		obj._cacheKey = key

		if baked.mode == "Mask" then
			obj.dissolveFramesBuffer = baked.dissolveFramesBuffer
			obj.edgeFramesBuffer = baked.edgeFramesBuffer
			obj.glowFramesBuffer = baked.glowFramesBuffer
			obj.pixelCount = baked.pixelCount

			local totalBytes = baked.pixelCount * 4
			obj.totalBytes = totalBytes

			local pixelBuffer = bufferCreate(totalBytes)
			obj.emissivePixelBuffer = bufferCreate(totalBytes)

			obj.pixelBuffer = pixelBuffer

			for i = 0, totalBytes - 1, 4 do
				bufferWriteu32(obj.pixelBuffer, i, 0)
				bufferWriteu32(obj.emissivePixelBuffer, i, 0)
			end

			obj._originalPixels = bufferCreate(totalBytes)
			bufferCopy(obj._originalPixels, 0, obj.pixelBuffer, 0, totalBytes)
		elseif baked.mode == "Full" then
			obj.baseFramesBuffer = baked.baseFramesBuffer
			obj.emissiveFramesBuffer = baked.emissiveFramesBuffer
			local totalBytes = baked.totalBytes
			obj.totalBytes = totalBytes

			local pixelBuffer = bufferCreate(totalBytes)
			obj.pixelBuffer = pixelBuffer
			obj.emissivePixelBuffer = bufferCreate(totalBytes)

			bufferCopy(pixelBuffer, 0, baked.baseFramesBuffer, 0, totalBytes)

			obj._originalPixels = bufferCreate(totalBytes)
			bufferCopy(obj._originalPixels, 0, obj.pixelBuffer, 0, totalBytes)
		elseif baked.mode == "None" then
			obj.baseBuffer = baked.baseBuffer
			obj.noiseBuffer = baked.noiseBuffer
			local totalBytes = baked.totalBytes
			obj.totalBytes = totalBytes
			obj.noiseWidth = baked.noiseWidth
			obj.noiseHeight = baked.noiseHeight

			local pixelBuffer = bufferCreate(totalBytes)
			obj.pixelBuffer = pixelBuffer
			obj.emissivePixelBuffer = bufferCreate(totalBytes)
			obj.baseOut = bufferCreate(totalBytes)
			obj.emissiveOut = bufferCreate(totalBytes)

			bufferCopy(pixelBuffer, 0, baked.baseBuffer, 0, totalBytes)

			for i = 0, totalBytes - 1, 4 do
				bufferWriteu32(obj.emissivePixelBuffer, i, 0)
			end

			obj._originalPixels = bufferCreate(totalBytes)
			bufferCopy(obj._originalPixels, 0, obj.pixelBuffer, 0, totalBytes)
		end

		self:_IncreasedReady()
	end

	if bakeCache[key] then
		ApplyCachedBake()
	elseif registerCache[key] then
		registerCache[key]:Connect(ApplyCachedBake)
	else
		registerCache[key] = Signal.new()
		self:_Setup(obj)

		if self._config.Bake ~= "None" then
			self:_AddJob(obj)
		else
			bakeCache[key] = {
				baseBuffer = obj.baseBuffer,
				noiseBuffer = obj.noiseBuffer,
				noiseWidth = obj.noiseWidth,
				noiseHeight = obj.noiseHeight,
				totalBytes = obj.totalBytes,
				refCount = 1,
				mode = "None",
			}
			obj._cacheKey = key

			obj.baseOut = bufferCreate(obj.totalBytes)
			obj.emissiveOut = bufferCreate(obj.totalBytes)

			if registerCache[key] then
				registerCache[key]:Fire()
				task.defer(function()
					if registerCache[key] then
						registerCache[key]:Destroy()
						registerCache[key] = nil
					end
				end)
			end

			self:_IncreasedReady()
		end
	end
end

-- Changes the public state and notifies listeners when the value changes.
function Dissolve._SetState(self: Dissolve, state: string)
	if self.State == state then
		return
	end
	self.State = state
	if state == "Ready" then
		self.Ready:Fire()
	end
	self.StateChanged:Fire(state)
end

-- Tracks target readiness and removes the progress billboard when baking finishes.
function Dissolve._IncreasedReady(self: Dissolve)
	self._readyCount += 1
	if self._readyCount >= self._bakingCount then
		local part = self._part
		if part then
			part:Destroy()
			self._billboard = nil
			self._label = nil
			self._part = nil
		end
		self:_SetState("Ready")
	end
end

-- Allocates per-target pixel buffers, noise data, and bake-frame storage.
function Dissolve._Setup(
	self: Dissolve,
	obj: {
		width: number,
		height: number,
		editable: EditableImage,
		emissiveEditable: EditableImage,
		size: Vector2,
		Mask: DissolveMask,
	} & ResolvedTarget
)
	local totalBytes = obj.width * obj.height * BYTES_PP
	obj.totalBytes = totalBytes

	local noiseWidth, noiseHeight = self._config.NoiseResolution, self._config.NoiseResolution
	obj.noiseWidth = noiseWidth
	obj.noiseHeight = noiseHeight

	obj.noiseBuffer = bufferCreate(noiseWidth * noiseHeight)

	if obj.textureID then
		obj.pixelBuffer = obj.editable:ReadPixelsBuffer(Vector2.zero, obj.size)
	else
		obj.pixelBuffer = bufferCreate(totalBytes)
		local color = obj.GetColor()
		local r, g, b = mathFloor(color.R * 255), mathFloor(color.G * 255), mathFloor(color.B * 255)
		for i = 0, totalBytes - 1, 4 do
			bufferWriteu8(obj.pixelBuffer, i, r)
			bufferWriteu8(obj.pixelBuffer, i + 1, g)
			bufferWriteu8(obj.pixelBuffer, i + 2, b)
			bufferWriteu8(obj.pixelBuffer, i + 3, 255)
		end
	end

	if obj._originalPixels then
		bufferCopy(obj.pixelBuffer, 0, obj._originalPixels, 0, totalBytes)
	else
		obj._originalPixels = bufferCreate(totalBytes)
		if not obj._originalPixels then
			return
		end
		bufferCopy(obj._originalPixels :: buffer, 0, obj.pixelBuffer, 0, totalBytes)
	end

	obj.emissivePixelBuffer = bufferCreate(totalBytes)

	local noiseKey = tostring(self._config.NoiseMap) .. "|" .. noiseWidth .. "|" .. noiseHeight
	local cached = noiseBufferCache[noiseKey]

	if cached then
		bufferCopy(obj.noiseBuffer, 0, cached.noiseBuffer, 0, bufferLen(cached.noiseBuffer))
		RetainCache(noiseKey)
		obj._noiseCacheKey = noiseKey
	else
		task.wait()
		local customNoise, editableImage = ResolveAsset(tostring(self._config.NoiseMap))

		if self._config.NoiseMap and customNoise then
			local noiseEditable = editableImage
				or AssetService:CreateEditableImageAsync(Content.fromAssetId(customNoise))
			local targetSize = Vector2.new(noiseWidth, noiseHeight)

			if noiseEditable.Size ~= targetSize then
				noiseEditable = ResizeEditableImage(noiseEditable, targetSize)
			end

			local pixels = noiseEditable:ReadPixelsBuffer(Vector2.zero, targetSize)
			noiseEditable:Destroy()

			for i = 0, noiseWidth * noiseHeight - 1 do
				local base = i * 4
				local r = bufferReadu8(pixels, base)
				local g = bufferReadu8(pixels, base + 1)
				local b = bufferReadu8(pixels, base + 2)
				local lum = mathFloor(r * 0.299 + g * 0.587 + b * 0.114)
				bufferWriteu8(obj.noiseBuffer, i, lum)
			end

			local saved = bufferCreate(bufferLen(obj.noiseBuffer))
			bufferCopy(saved, 0, obj.noiseBuffer, 0, bufferLen(obj.noiseBuffer))
			noiseBufferCache[noiseKey] = { noiseBuffer = saved, refCount = 1 }
			obj._noiseCacheKey = noiseKey
		else
			local seed = mathRandom() * 100
			local scale = self._config.NoiseScale
			local nw = obj.noiseWidth
			local nh = obj.noiseHeight
			for y = 0, nh - 1 do
				local rowOffset = y * nw
				for x = 0, nw - 1 do
					local n = TileableNoise(x, y, nw, nh, scale, seed)
					n = mathClamp((n + 1) * 0.5, 0, 1)
					bufferWriteu8(obj.noiseBuffer, rowOffset + x, mathFloor(n * 255))
				end
			end
		end
	end

	obj.baseBuffer = bufferCreate(totalBytes)
	bufferCopy(obj.baseBuffer, 0, obj.pixelBuffer, 0, totalBytes)

	if self._config.Bake == "Mask" then
		local pixelCount = obj.width * obj.height

		obj.dissolveFramesBuffer = bufferCreate(pixelCount * self._config.BakeFrames)
		obj.edgeFramesBuffer = bufferCreate(pixelCount * self._config.BakeFrames)
		obj.glowFramesBuffer = bufferCreate(pixelCount * self._config.BakeFrames)
	else
		obj.baseFramesBuffer = bufferCreate(totalBytes * self._config.BakeFrames)
		obj.emissiveFramesBuffer = bufferCreate(totalBytes * self._config.BakeFrames)
	end
end

-- Sends a target bake request to the worker pool and records progress text.
function Dissolve._AddJob(self: Dissolve, obj: ResolvedTarget)
	local label = self._label
	local bakingCount = self._bakingCount
	local readyRef = self

	local function onProgress(done, total)
		if label then
			if bakingCount > 1 then
				label.Text = done .. " / " .. total .. "\n" .. readyRef._readyCount .. " / " .. bakingCount
			else
				label.Text = done .. " / " .. total
			end
		end
		self._bakingProgress = done .. " / " .. total
	end

	local w, h = obj.width, obj.height
	local total = w * h
	local pW = mathMax(1, mathFloor(w * 0.25))
	local pH = mathMax(1, mathFloor(h * 0.25))
	local pCount = pW * pH
	obj._rt = {
		maskBuf = bufferCreate(pCount),
		invBuf = bufferCreate(pCount),
		dSolid = bufferCreate(pCount * 4),
		dEmpty = bufferCreate(pCount * 4),
		normBuf = bufferCreate(pCount * 8),
		distBuf = bufferCreate(total * 4),
	}

	local handle
	handle = JobManager:AddJob(self, {
		baseBuffer = obj.baseBuffer,
		noiseBuffer = obj.noiseBuffer,
		width = obj.width,
		height = obj.height,
		noiseWidth = obj.noiseWidth,
		noiseHeight = obj.noiseHeight,
		config = self._config,
		totalBytes = obj.totalBytes,
		isBase = obj.type == "Base",
		rt = obj._rt,
		onProgress = onProgress,
	}, function(results)
		if self._destroyed then
			return
		end

		if handle._cancelled then
			return
		end

		for i, h in ipairs(self._query) do
			if h == handle then
				table.remove(self._query, i)
				break
			end
		end

		self:_MergeBakeResults(results, obj)
	end)

	table.insert(self._query, handle)
end

-- Creates the temporary world-space progress label used during baking.
function Dissolve._CreateBillboard(self: Dissolve)
	if not self._config.Behavior.ShowProgress or not self._center then
		return
	end

	local part = Instance.new("Part")
	part.Anchored = true
	part.Transparency = 1
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Position = self._center

	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromScale(4, 2)
	gui.AlwaysOnTop = true

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextScaled = true
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.5
	label.Font = Enum.Font.GothamBold
	label.Text = "Baking..."

	label.Parent = gui
	gui.Parent = part
	part.Parent = workspace

	self._billboard = gui
	self._label = label
	self._part = part
end

--[=[
	@param config PartialConfig

	Updates the dissolve configuration and rebuilds any data affected by it.

	Changing the bake mode, size, noise, color, edge, glow, or runtime settings
	can restart preparation for every resolved target. Existing cache references
	are released before the new configuration is prepared.

	`Behavior` is merged into the current behavior table, so you can update only
	`ShowProgress` or only `AutoDiscover`. Target discovery itself is not rerun;
	create a new `Dissolve` instance if you need a different target set or
	blacklist after construction.
	```lua
	dissolve:SetConfig({
		Color = Color3.fromRGB(0, 255, 255),
		GlowColor = Color3.fromRGB(0, 80, 255),
		Bake = "Mask",
		Behavior = {
			ShowProgress = true,
		},
	})

	if dissolve:IsReady() then
		dissolve:Start()
	else
		dissolve.Ready:Connect(function()
			dissolve:Start()
		end)
	end
	```
]=]
function Dissolve.SetConfig(self: Dissolve, config: PartialConfig)
	if self._destroyed then
		return
	end

	if self._conn then
		self._conn:Disconnect()
		self._conn = nil
	end

	self:_SetState("Baking")

	for k, v in pairs(config) do
		if k == "Behavior" then
			for k2, v2 in pairs(v) do
				self._config.Behavior[k2] = v2
			end
		else
			self._config[k] = v
		end
	end

	local mode = self._config.Bake

	self._readyCount = 0
	self._bakingCount = self._instances and #self._instances or 0

	if self._part then
		self._part:Destroy()
		self._billboard = nil
		self._label = nil
		self._part = nil
	end

	if self._instances then
		for _, obj in ipairs(self._instances) do
			if obj._cacheKey then
				ReleaseCache(obj._cacheKey)
				obj._cacheKey = nil
			end

			if obj._noiseCacheKey then
				ReleaseCache(obj._noiseCacheKey)
				obj._noiseCacheKey = nil
			end

			obj.baseFramesBuffer = nil
			obj.emissiveFramesBuffer = nil
			obj.dissolveFramesBuffer = nil
			obj.edgeFramesBuffer = nil
			obj.glowFramesBuffer = nil

			obj._aliveMask = nil
			obj._preparedFrame = nil

			if obj.type == "Base" then
				obj.Mask.Surface.EmissiveTint = self._config.GlowColor
			end

			if mode == "None" then
				if not obj.baseBuffer then
					obj.baseBuffer = bufferCreate(obj.totalBytes)
					bufferCopy(obj.baseBuffer :: buffer, 0, obj.pixelBuffer, 0, obj.totalBytes)
				end

				obj.baseOut = bufferCreate(obj.totalBytes)
				obj.emissiveOut = bufferCreate(obj.totalBytes)

				self:_IncreasedReady()
			else
				if obj._rt then
					obj._rt.maskBuf = nil
					obj._rt.invBuf = nil
					obj._rt.dSolid = nil
					obj._rt.dEmpty = nil
					obj._rt.normBuf = nil
					obj._rt.distBuf = nil
					obj._rt = nil
				end

				self:_Setup(obj)
				self:_AddJob(obj)
			end
		end
	end

	if mode ~= "None" and self._config.Behavior.ShowProgress and self._center then
		self:_CreateBillboard()
	end
end

-- Merges worker chunks into the final baked buffers and publishes the cache entry.
function Dissolve._MergeBakeResults(self: Dissolve, partials, obj: { size: Vector2 } & ResolvedTarget)
	if self._destroyed then
		return
	end

	local isMask = self._config.Bake == "Mask"
	local pixelCount = obj.size.X * obj.size.Y

	if isMask then
		for _, chunk in ipairs(partials) do
			local startOffset = (chunk.startFrame - 1) * pixelCount

			local size = bufferLen(chunk.dissolve)

			bufferCopy(obj.dissolveFramesBuffer, startOffset, chunk.dissolve, 0, size)
			bufferCopy(obj.edgeFramesBuffer, startOffset, chunk.edge, 0, size)
			bufferCopy(obj.glowFramesBuffer, startOffset, chunk.glow, 0, size)
		end
	else
		local totalBytes = obj.totalBytes

		for _, chunk in ipairs(partials) do
			local startOffset = (chunk.startFrame - 1) * totalBytes
			local size = bufferLen(chunk.base)

			bufferCopy(obj.baseFramesBuffer, startOffset, chunk.base, 0, size)
			bufferCopy(obj.emissiveFramesBuffer, startOffset, chunk.emissive, 0, size)
		end
	end

	local id = obj.textureID
	if not id or id == "" then
		id = ColorToID(obj.GetColor())
	end

	local key = GetBakeKey(id, self._config, obj.size, obj.type == "Base")

	if isMask then
		bakeCache[key] = {
			dissolveFramesBuffer = obj.dissolveFramesBuffer,
			edgeFramesBuffer = obj.edgeFramesBuffer,
			glowFramesBuffer = obj.glowFramesBuffer,
			pixelCount = pixelCount,
			refCount = 1,
			mode = "Mask",
		}
	else
		bakeCache[key] = {
			baseFramesBuffer = obj.baseFramesBuffer,
			emissiveFramesBuffer = obj.emissiveFramesBuffer,
			totalBytes = obj.totalBytes,
			refCount = 1,
			mode = "Full",
		}
	end

	obj._cacheKey = key
	obj.noiseBuffer = nil
	obj.baseBuffer = nil

	if obj._rt then
		obj._rt.maskBuf = nil
		obj._rt.invBuf = nil
		obj._rt.dSolid = nil
		obj._rt.dEmpty = nil
		obj._rt.normBuf = nil
		obj._rt.distBuf = nil
		obj._rt = nil
	end

	if registerCache[key] then
		registerCache[key]:Fire()
		task.defer(function()
			if registerCache[key] then
				registerCache[key]:Destroy()
				registerCache[key] = nil
			end
		end)
	end

	self:_IncreasedReady()
end

--[=[
	@param Appear boolean? -- When true, plays the effect as an appear/rebuild animation.

	Starts the dissolve animation.

	The effect must be in the `Ready` state before it can run. Calling `Start`
	mounts the generated masks, hides the original targets, and advances frames
	on `PreRender` until the effect completes. On completion, `Completed` fires
	and the effect resets to `Ready`.

	If `Appear` is true, the animation runs in reverse: it starts from the last
	baked frame and reconstructs the object over time, creating a materialization
	effect instead of dissolution. In this mode, frame progression is inverted
	and the object becomes visible as the mask fills back in.

	```lua
	if dissolve:IsReady() then
		dissolve:Start() -- Dissolve (default)
		-- dissolve:Start(true) -- Appear (reverse)
	end
	```
]=]
function Dissolve.Start(self: Dissolve, Appear: boolean?)
	if self._destroyed then
		warn("[Dissolve]: Attempt to Start() after Destroy()")
		return
	elseif self.State ~= "Ready" then
		warn("[Dissolve]: Attempt to Start() before bake is ready (state = " .. self.State .. ")")
		return
	end

	local mode = self._config.Bake
	local instances = self._instances
	self._currentFrame = 0
	local bakeFrames = self._config.BakeFrames
	local initialFrame = Appear and bakeFrames or 1
	local applyFrame

	if mode == "Mask" then
		applyFrame = Appear and self._ApplyFrameMaskAppear or self._ApplyFrameMask
	elseif mode == "Full" then
		applyFrame = self._ApplyFrame
	else
		applyFrame = self._ApplyFrameRuntime
	end

	self._currentFrame = initialFrame

	for _, obj in ipairs(instances) do
		if mode == "None" then
			local w, h = obj.width, obj.height
			local total = w * h
			local pW = mathMax(1, mathFloor(w * 0.25))
			local pH = mathMax(1, mathFloor(h * 0.25))
			local pCount = pW * pH
			obj._rt = {
				maskBuf = bufferCreate(pCount),
				invBuf = bufferCreate(pCount),
				dSolid = bufferCreate(pCount * 4),
				dEmpty = bufferCreate(pCount * 4),
				normBuf = bufferCreate(pCount * 8),
				distBuf = bufferCreate(total * 4),
			}
		end

		applyFrame(self, initialFrame, obj)
		obj._preparedFrame = nil
		obj.Hide()
	end

	for _, obj in ipairs(instances) do
		if self._config.Bake == "None" then
			obj.baseOut = bufferCreate(obj.totalBytes)
			obj.emissiveOut = bufferCreate(obj.totalBytes)
		end

		UpdateBaseMaskTransform(obj)
	end

	for _, obj in ipairs(instances) do
		if obj.type == "Base" then
			obj.Mask.Transparency = 0
		elseif obj.type == "Overlay" then
			obj.Mask.Base.Transparency = 0
			obj.Mask.Overlay.Transparency = 0
		else
			obj.Mask.Base.ImageTransparency = 0
			obj.Mask.Overlay.ImageTransparency = 0
		end
	end

	local speed = self._config.Speed
	local direction = Appear and -1 or 1
	local progress = 0
	self._progress = progress

	if self._conn then
		self._conn:Disconnect()
		self._conn = nil
	end

	self:_SetState("Running")
	local TransformAutoUpdateEnabled = self._config.TransformAutoUpdateEnabled
	local completed, destroyed = false, false

	self._conn = RunService.PreRender:Connect(function(dt)
		if self._destroyed then
			if not destroyed then
				self:Reset(true)
			end
			destroyed = true
			return
		end
		self._progress += dt * speed

		if self._progress >= 1 then
			if completed then
				return
			end

			completed = true
			self.Completed:Fire()
			self:Reset()
		end

		local forward = mathClamp(mathFloor(self._progress * bakeFrames), 0, bakeFrames)
		local targetFrame = (direction == 1) and forward or mathMax(1, bakeFrames - forward)

		if (targetFrame - self._currentFrame) * direction > 0 then
			self._currentFrame = targetFrame

			for _, obj in ipairs(instances) do
				if TransformAutoUpdateEnabled then
					UpdateBaseMaskTransform(obj)
				end

				if self._progress < 1 then
					applyFrame(self, targetFrame, obj)
				end
			end
		end
	end)
end

-- Applies a fully baked frame directly to the target editable images.
function Dissolve._ApplyFrame(
	self: Dissolve,
	frame: number,
	obj: {
		totalBytes: number,
		editable: EditableImage,
		emissiveEditable: EditableImage,
		size: Vector2,
		pixelBuffer: buffer,
		emissivePixelBuffer: buffer,
	} & ResolvedTarget
): boolean
	if obj._preparedFrame ~= frame then
		local offset = (frame - 1) * obj.totalBytes

		bufferCopy(obj.pixelBuffer, 0, obj.baseFramesBuffer, offset, obj.totalBytes)
		bufferCopy(obj.emissivePixelBuffer, 0, obj.emissiveFramesBuffer, offset, obj.totalBytes)
		obj._preparedFrame = frame

		obj.editable:WritePixelsBuffer(Vector2.zero, obj.size, obj.pixelBuffer)
		obj.emissiveEditable:WritePixelsBuffer(Vector2.zero, obj.size, obj.emissivePixelBuffer)
	end

	return true
end

-- Applies mask-only baked data while rebuilding final colors on the client.
function Dissolve._ApplyFrameMask(
	self: Dissolve,
	frame: number,
	obj: {
		size: Vector2,
		editable: EditableImage,
		emissiveEditable: EditableImage,
		type: string,
	} & ResolvedTarget
): boolean
	if obj._preparedFrame ~= frame then
		obj._preparedFrame = frame

		local pixelCount = obj.size.X * obj.size.Y
		local offset = (frame - 1) * pixelCount

		local aliveMask = obj._aliveMask
		if not aliveMask then
			aliveMask = bufferCreate(pixelCount)
			for i = 0, pixelCount - 1 do
				bufferWriteu8(aliveMask, i, 1)
			end
			obj._aliveMask = aliveMask
		end

		local isBaseTarget = obj.type == "Base"

		local baseColor = obj.GetColor()
		local bR = mathFloor(baseColor.R * 255)
		local bG = mathFloor(baseColor.G * 255)
		local bB = mathFloor(baseColor.B * 255)
		local baseU32 = bR + bG * 256 + bB * 65536 + 4278190080

		local edgeColor = self._config.Color
		local eR = mathFloor(edgeColor.R * 255)
		local eG = mathFloor(edgeColor.G * 255)
		local eB = mathFloor(edgeColor.B * 255)
		local edgeU32 = eR + eG * 256 + eB * 65536 + 4278190080

		local glowLUT = self._glowLUT
		if not glowLUT then
			local glowColor = self._config.GlowColor
			local gR = mathFloor(glowColor.R * 255)
			local gG = mathFloor(glowColor.G * 255)
			local gB = mathFloor(glowColor.B * 255)

			glowLUT = tableCreate(256, 0)
			glowLUT[0] = 0

			for i = 1, 255 do
				local t = i / 255
				glowLUT[i] = mathFloor(gR * t) + mathFloor(gG * t) * 256 + mathFloor(gB * t) * 65536 + i * 16777216
			end

			self._glowLUT = glowLUT
		end

		local pixBuf = obj.pixelBuffer
		local emisBuf = obj.emissivePixelBuffer
		local dissolveBuf = obj.dissolveFramesBuffer
		local edgeBuf = obj.edgeFramesBuffer
		local glowBuf = obj.glowFramesBuffer

		local idx = 0

		for i = 0, pixelCount - 1 do
			local alive = bufferReadu8(aliveMask, i)
			if alive == 0 then
				bufferWriteu32(pixBuf, idx, 0)
				bufferWriteu32(emisBuf, idx, 0)
				idx += 4
				continue
			end

			local pos = offset + i

			local d = bufferReadu8(dissolveBuf, pos)
			local e = bufferReadu8(edgeBuf, pos)
			local _g = bufferReadu8(glowBuf, pos)

			local emissiveOut = glowLUT[_g]
			local out = (d > 0) and baseU32 or 0

			if e > 0 then
				local cur = emissiveOut

				local pr = bit32Band(cur, 0xFF)
				local pg = bit32Band(bit32Rshift(cur, 8), 0xFF)
				local pb = bit32Band(bit32Rshift(cur, 16), 0xFF)
				local pa = bit32Rshift(cur, 24)

				if isBaseTarget then
					-- Comportamento isBase: Emissive torna-se branco e Base assume cor da edge
					local r = mathMin(255, pr + 255)
					local g = mathMin(255, pg + 255)
					local b = mathMin(255, pb + 255)
					local a = mathMax(pa, 255)
					emissiveOut = r + g * 256 + b * 65536 + a * 16777216
					out = edgeU32
				else
					-- Comportamento normal: Emissive recebe a cor da edge, Base permanece intacto
					local r = mathMin(255, pr + eR)
					local g = mathMin(255, pg + eG)
					local b = mathMin(255, pb + eB)
					local a = mathMax(pa, 255)
					emissiveOut = r + g * 256 + b * 65536 + a * 16777216
				end
			end

			if out == 0 and emissiveOut == 0 then
				bufferWriteu8(aliveMask, i, 0)
			end

			bufferWriteu32(pixBuf, idx, out)
			bufferWriteu32(emisBuf, idx, emissiveOut)

			idx += 4
		end

		obj.editable:WritePixelsBuffer(Vector2.zero, obj.size, pixBuf)
		obj.emissiveEditable:WritePixelsBuffer(Vector2.zero, obj.size, emisBuf)
	end

	return true
end

-- Applies mask-only baked in reverse with masking only while reconstructing the final colors on the client.
function Dissolve._ApplyFrameMaskAppear(
	self: Dissolve,
	frame: number,
	obj: {
		size: Vector2,
		editable: EditableImage,
		emissiveEditable: EditableImage,
		type: string,
	} & ResolvedTarget
): boolean
	if obj._preparedFrame ~= frame then
		obj._preparedFrame = frame

		local pixelCount = obj.size.X * obj.size.Y
		local offset = (frame - 1) * pixelCount

		local isBaseTarget = obj.type == "Base"

		local baseColor = obj.GetColor()
		local bR = mathFloor(baseColor.R * 255)
		local bG = mathFloor(baseColor.G * 255)
		local bB = mathFloor(baseColor.B * 255)
		local baseU32 = bR + bG * 256 + bB * 65536 + 4278190080

		local edgeColor = self._config.Color
		local eR = mathFloor(edgeColor.R * 255)
		local eG = mathFloor(edgeColor.G * 255)
		local eB = mathFloor(edgeColor.B * 255)
		local edgeU32 = eR + eG * 256 + eB * 65536 + 4278190080

		local glowLUT = self._glowLUT
		if not glowLUT then
			local glowColor = self._config.GlowColor
			local gR = mathFloor(glowColor.R * 255)
			local gG = mathFloor(glowColor.G * 255)
			local gB = mathFloor(glowColor.B * 255)

			glowLUT = tableCreate(256, 0)
			glowLUT[0] = 0

			for i = 1, 255 do
				local t = i / 255
				glowLUT[i] = mathFloor(gR * t) + mathFloor(gG * t) * 256 + mathFloor(gB * t) * 65536 + i * 16777216
			end

			self._glowLUT = glowLUT
		end

		local pixBuf = obj.pixelBuffer
		local emisBuf = obj.emissivePixelBuffer
		local dissolveBuf = obj.dissolveFramesBuffer
		local edgeBuf = obj.edgeFramesBuffer
		local glowBuf = obj.glowFramesBuffer

		local idx = 0

		for i = 0, pixelCount - 1 do
			local pos = offset + i

			local d = bufferReadu8(dissolveBuf, pos)
			local e = bufferReadu8(edgeBuf, pos)
			local _g = bufferReadu8(glowBuf, pos)

			local emissiveOut = glowLUT[_g]
			local out = (d > 0) and baseU32 or 0

			if e > 0 then
				local cur = emissiveOut
				local pr = bit32Band(cur, 0xFF)
				local pg = bit32Band(bit32Rshift(cur, 8), 0xFF)
				local pb = bit32Band(bit32Rshift(cur, 16), 0xFF)
				local pa = bit32Rshift(cur, 24)

				if isBaseTarget then
					local r = mathMin(255, pr + 255)
					local g = mathMin(255, pg + 255)
					local b = mathMin(255, pb + 255)
					local a = mathMax(pa, 255)
					emissiveOut = r + g * 256 + b * 65536 + a * 16777216
					out = edgeU32
				else
					local r = mathMin(255, pr + eR)
					local g = mathMin(255, pg + eG)
					local b = mathMin(255, pb + eB)
					local a = mathMax(pa, 255)
					emissiveOut = r + g * 256 + b * 65536 + a * 16777216
				end
			end

			bufferWriteu32(pixBuf, idx, out)
			bufferWriteu32(emisBuf, idx, emissiveOut)

			idx += 4
		end

		obj.editable:WritePixelsBuffer(Vector2.zero, obj.size, pixBuf)
		obj.emissiveEditable:WritePixelsBuffer(Vector2.zero, obj.size, emisBuf)
	end

	return true
end

-- Computes and applies a frame without using pre-baked dissolve data.
function Dissolve._ApplyFrameRuntime(
	self: Dissolve,
	frame: number,
	obj: { size: Vector2, editable: EditableImage, emissiveEditable: EditableImage } & ResolvedTarget
): boolean
	if obj._preparedFrame ~= frame then
		local threshold = mathClamp(frame / self._config.BakeFrames, 0, 1)

		local base, emissive = RuntimeWorker({
			config = self._config,
			width = obj.size.X,
			height = obj.size.Y,
			totalBytes = obj.totalBytes,
			noiseWidth = obj.noiseWidth,
			noiseHeight = obj.noiseHeight,
			noiseBuffer = obj.noiseBuffer,
			baseBuffer = obj.baseBuffer,
			threshold = threshold,
			tTime = frame * 0.05,
			baseOut = obj.baseOut,
			emissiveOut = obj.emissiveOut,
			isBase = obj.type == "Base",
			rt = obj._rt,
		})

		obj.baseOut = base
		obj.emissiveOut = emissive
		obj._preparedFrame = frame

		obj.editable:WritePixelsBuffer(Vector2.zero, obj.size, base)
		obj.emissiveEditable:WritePixelsBuffer(Vector2.zero, obj.size, emissive)
	end

	return true
end

--[=[
	Stops the current animation and restores every original target.

	Reset leaves the effect in the `Ready` state, so it can be started again.
	```lua
	dissolve:Reset()
	dissolve:Start()
	```
]=]
function Dissolve.Reset(self: Dissolve, noMark: boolean)
	if self._destroyed then
		return
	end

	if self._conn then
		self._conn:Disconnect()
		self._conn = nil
	end

	self._progress = 0
	self._currentFrame = 0

	if self._instances then
		for _, obj in ipairs(self._instances) do
			obj.Show()

			obj._preparedFrame = nil
			bufferCopy(obj.pixelBuffer, 0, obj._originalPixels, 0, obj.totalBytes)

			if obj._aliveMask then
				local len = bufferLen(obj._aliveMask)
				for i = 0, len - 1 do
					bufferWriteu8(obj._aliveMask, i, 1)
				end
			end

			if obj.type == "Base" then
				obj.Mask.Transparency = 1
			elseif obj.type == "Overlay" then
				obj.Mask.Base.Transparency = 1
				obj.Mask.Overlay.Transparency = 1
			else
				obj.Mask.Base.ImageTransparency = 1
				obj.Mask.Overlay.ImageTransparency = 1
			end
			if obj._rt then
				obj._rt.maskBuf = nil
				obj._rt.invBuf = nil
				obj._rt.dSolid = nil
				obj._rt.dEmpty = nil
				obj._rt.normBuf = nil
				obj._rt.distBuf = nil
				obj._rt = nil
			end
		end
	end

	if not noMark then
		self:_SetState("Ready")
	end
end

--[=[
	Cleans up the dissolve effect.

	Disconnects active updates, destroys generated editable images and masks,
	releases cache references, and destroys public signals.
	```lua
	dissolve:Destroy()
	```
]=]
function Dissolve.Destroy(self: Dissolve)
	if self._destroyed then
		return
	end

	self:Reset(true)

	self._destroyed = true

	self.StateChanged:Destroy()
	self.Ready:Destroy()

	for _, job in ipairs(self._query) do
		job:Cancel()
	end

	if self._instances then
		for _, obj in ipairs(self._instances) do
			if obj.editable then
				obj.editable:Destroy()
			end
			if obj.emissiveEditable then
				obj.emissiveEditable:Destroy()
			end

			if obj.Mask then
				if typeof(obj.Mask) == "Instance" then
					obj.Mask:Destroy()
				else
					if obj.Mask.Base then
						obj.Mask.Base:Destroy()
					end
					if obj.Mask.Overlay then
						obj.Mask.Overlay:Destroy()
					end
				end
			end

			obj.pixelBuffer = nil
			obj._originalPixels = nil
			obj.emissivePixelBuffer = nil
			obj.baseBuffer = nil
			obj.baseFramesBuffer = nil
			obj.emissiveFramesBuffer = nil
			obj.dissolveFramesBuffer = nil
			obj.edgeFramesBuffer = nil
			obj.glowFramesBuffer = nil
			obj.noiseBuffer = nil
			obj._aliveMask = nil
			obj._preparedFrame = nil

			if obj._rt then
				obj._rt.maskBuf = nil
				obj._rt.invBuf = nil
				obj._rt.dSolid = nil
				obj._rt.dEmpty = nil
				obj._rt.normBuf = nil
				obj._rt.distBuf = nil
				obj._rt = nil
			end

			if obj._cacheKey then
				ReleaseCache(obj._cacheKey)
				obj._cacheKey = nil
			end

			if obj._noiseCacheKey then
				ReleaseCache(obj._noiseCacheKey)
				obj._noiseCacheKey = nil
			end
		end
	end

	if self._part then
		self._part:Destroy()
		self._billboard = nil
		self._label = nil
		self._part = nil
	end

	self._instances = nil
	self:_SetState("Destroyed")
	self.Completed:Destroy()
end

--[=[
	@return boolean -- `true` when the effect is prepared and can be started.
]=]
function Dissolve.IsReady(self: Dissolve)
	return self.State == "Ready"
end

--[=[
	@return boolean -- `true` while the dissolve animation is active.
]=]
function Dissolve.IsRunning(self: Dissolve)
	return self.State == "Running"
end

--[=[
	@return number -- Current animation progress in the `0..1` range.
]=]
function Dissolve.GetProgress(self: Dissolve)
	return self._progress
end

--[=[
	@return string -- Current bake progress label.
]=]
function Dissolve.GetBakeProgress(self: Dissolve)
	return self._bakingProgress
end

--[=[
	@return string -- Current lifecycle state.
]=]
function Dissolve.GetState(self: Dissolve)
	return self.State
end

--[=[
	@within Dissolve
	@type BakeMode "Full" | "Mask" | "None"

	Controls how much dissolve data is precomputed before playback.

	`"Full"` bakes finished base and emissive pixels for every frame. `"Mask"`
	bakes compact dissolve, edge, and glow masks, then recolors them at runtime.
	`"None"` skips frame baking and computes each frame during playback.
]=]
type BakeMode = "Full" | "Mask" | "None"

--[=[
	@within Dissolve
	@type YieldMode "Aggressive" | "Balanced" | "Relaxed"

	Controls how worker tasks yield while preparing bake data.

	Use `"Aggressive"` for faster preparation, `"Relaxed"` for smoother client
	frames during large bakes, and `"Balanced"` when you want a middle ground.
]=]
type YieldMode = "Aggressive" | "Balanced" | "Relaxed"

--[=[
	@within Dissolve
	@type AutoDiscoverMode "All" | "Children" | "None"

	Controls how child objects are discovered from the provided roots.

	`"All"` includes supported descendants, `"Children"` includes supported
	modifiers directly under supported roots, and `"None"` uses only the provided
	instances.
]=]
type AutoDiscoverMode = "All" | "Children" | "None"
type ScaleFn = (Vector3) -> Vector3
type SignalObject = Signal.Signal<>

--[=[
	@within Dissolve
	@interface BehaviorConfig
	* ShowProgress: boolean
	* AutoDiscover: AutoDiscoverMode

	Controls non-visual behavior for target discovery and progress display.

	`ShowProgress` creates a temporary world-space progress label while baking
	3D targets. `AutoDiscover` decides whether models and parts should include
	supported children or descendants automatically.
]=]
type BehaviorConfig = {
	ShowProgress: boolean,
	AutoDiscover: AutoDiscoverMode,
}

--[=[
	@within Dissolve
	@interface Config
	* Color: Color3
	* GlowColor: Color3
	* Speed: number
	* EdgeWidth: number
	* GlowWidth: number
	* NoiseScale: number
	* NoiseResolution: number
	* BakeFrames: number
	* Size: Vector2
	* RegionFrequency: number
	* ThicknessGain: number
	* ThicknessBias: number
	* WarpStrength: number
	* Bake: BakeMode
	* YieldMode: YieldMode
	* Behavior: BehaviorConfig
	* Blacklist: { Instance }
	* NoiseMap: number | string
	* TransformAutoUpdateEnabled: boolean
	* EmissiveStrength: number

	Full configuration used by a Dissolve instance.

	`NoiseMap` selects the image asset used as the dissolve noise source.
	`TransformAutoUpdateEnabled` keeps Base masks aligned with moving targets
	during playback. `EmissiveStrength` controls the generated SurfaceAppearance
	emissive intensity for 3D masks.
]=]
type Config = {
	Color: Color3,
	GlowColor: Color3,
	Speed: number,
	EdgeWidth: number,
	GlowWidth: number,
	NoiseScale: number,
	NoiseResolution: number,
	BakeFrames: number,
	Size: Vector2,
	RegionFrequency: number,
	ThicknessGain: number,
	ThicknessBias: number,
	WarpStrength: number,
	Bake: BakeMode,
	YieldMode: YieldMode,
	Behavior: BehaviorConfig,
	Blacklist: { Instance },
	NoiseMap: number | string,
	TransformAutoUpdateEnabled: boolean,
	EmissiveStrength: number,
}

--[=[
	@within Dissolve
	@interface PartialBehaviorConfig
	* ShowProgress: boolean?
	* AutoDiscover: AutoDiscoverMode?

	Optional behavior overrides accepted by `Dissolve.new` and `Dissolve:SetConfig`.
]=]
type PartialBehaviorConfig = {
	ShowProgress: boolean?,
	AutoDiscover: AutoDiscoverMode?,
}

--[=[
	@within Dissolve
	@interface PartialConfig
	* Color: Color3?
	* GlowColor: Color3?
	* Speed: number?
	* EdgeWidth: number?
	* GlowWidth: number?
	* NoiseScale: number?
	* NoiseResolution: number?
	* BakeFrames: number?
	* Size: Vector2?
	* RegionFrequency: number?
	* ThicknessGain: number?
	* ThicknessBias: number?
	* WarpStrength: number?
	* Bake: BakeMode?
	* YieldMode: YieldMode?
	* Behavior: PartialBehaviorConfig?
	* Blacklist: { Instance }?
	* NoiseMap: (number | string)?
	* TransformAutoUpdateEnabled: boolean?
	* EmissiveStrength: number?

	Optional configuration overrides accepted by `Dissolve.new` and
	`Dissolve:SetConfig`.
]=]
type PartialConfig = {
	Color: Color3?,
	GlowColor: Color3?,
	Speed: number?,
	EdgeWidth: number?,
	GlowWidth: number?,
	NoiseScale: number?,
	NoiseResolution: number?,
	BakeFrames: number?,
	Size: Vector2?,
	RegionFrequency: number?,
	ThicknessGain: number?,
	ThicknessBias: number?,
	WarpStrength: number?,
	Bake: BakeMode?,
	YieldMode: YieldMode?,
	Behavior: PartialBehaviorConfig?,
	Blacklist: { Instance }?,
	NoiseMap: number? | string?,
	TransformAutoUpdateEnabled: boolean?,
	EmissiveStrength: number?,
}

type RuntimeBuffers = {
	maskBuf: buffer?,
	invBuf: buffer?,
	dSolid: buffer?,
	dEmpty: buffer?,
	normBuf: buffer?,
	distBuf: buffer?,
}

type SchedulerJob = {
	Owner: Dissolve,
	Instances: { ResolvedTarget },
	ApplyFrame: (Dissolve, number, ResolvedTarget) -> boolean,
	BakeFrames: number,
	Direction: number,
	Speed: number,
	Progress: number,
	TargetIndex: number,
	Cancelled: boolean,
}

type SchedulerHandle = SchedulerJob & {
	Disconnect: () -> (),
}

type LayerClone = {
	ColorMapContent: Content?,
	ImageContent: Content?,
	CFrame: CFrame,
	Size: Vector3?,
	Parent: Instance?,
	ZIndex: number,
}

type DissolveMask = BaseMask

type BaseMask = (Part | {} | MeshPart) & {
	Mesh: SpecialMesh,
	Base: LayerClone,
	Overlay: LayerClone,
	CFrame: CFrame,
	Size: Vector3,
}

type BakeCacheEntry = {
	refCount: number,
	mode: BakeMode,
	dissolveFramesBuffer: buffer?,
	edgeFramesBuffer: buffer?,
	glowFramesBuffer: buffer?,
	pixelCount: number?,
	baseFramesBuffer: buffer?,
	emissiveFramesBuffer: buffer?,
	baseBuffer: buffer?,
	noiseBuffer: buffer?,
	noiseWidth: number?,
	noiseHeight: number?,
	totalBytes: number?,
}

type NoiseBufferEntry = {
	noiseBuffer: buffer,
	refCount: number,
}

type ResolvedTarget = {
	type: "Base" | "Overlay" | "UI",
	parent: Instance,
	textureID: string?,
	meshID: string?,
	GetColor: () -> Color3,
	Hide: () -> (),
	Show: () -> (),
	Clone: (() -> LayerClone)?,
	GetParentCframe: (() -> CFrame)?,
	GetSize: (() -> Vector3)?,
	editable: EditableImage?,
	emissiveEditable: EditableImage?,
	width: number?,
	height: number?,
	size: Vector2?,
	_cacheKey: string?,
	_noiseCacheKey: string?,
	dissolveFramesBuffer: buffer?,
	edgeFramesBuffer: buffer?,
	glowFramesBuffer: buffer?,
	pixelCount: number?,
	totalBytes: number?,
	pixelBuffer: buffer?,
	_originalPixels: buffer?,
	emissivePixelBuffer: buffer?,
	baseFramesBuffer: buffer?,
	emissiveFramesBuffer: buffer?,
	baseBuffer: buffer?,
	noiseBuffer: buffer?,
	noiseWidth: number?,
	noiseHeight: number?,
	baseOut: buffer?,
	emissiveOut: buffer?,
	BaseCFrame: CFrame?,
	BaseScale: Vector3?,
	_preparedFrame: number?,
	_writeLayer: ("Base" | "Emissive")?,
	_aliveMask: buffer?,
	_rt: RuntimeBuffers?,
	Mask: DissolveMask?,
	editableImage: EditableImage?,
}

local _Dissolve = Dissolve
return _Dissolve :: Dissolve
