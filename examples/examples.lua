--[=[
	DissolveEffect - Examples.luau
	==============================

	IMPORTANT - CLIENT-SIDE ONLY
	----------------------------
	This module relies on EditableImage, a Roblox API that only exists on the
	client. The module refuses to run on the server and prints a warning if you
	accidentally require it from a Script. Always place this code inside a
	LocalScript, or inside a ModuleScript required by a LocalScript.

	REQUIRED - ENABLE EDITABLEIMAGE API
	-----------------------------------
	This module depends on Roblox's EditableImage API.

	By default, EditableImage is disabled in published experiences for security
	reasons. To enable it, your account must be 13+ age verified and ID verified.

	After verification:
	1. Open Studio's Experience Settings.
	2. Go to the Security tab.
	3. Enable the Allow Mesh / Image APIs toggle.

	If this setting is disabled:
	- EditableImage creation will fail.
	- Baking will not work correctly.
	- The dissolve effect may appear invisible or broken.

	This is a platform restriction, not a limitation of the module.

	RECOMMENDED FOLDER STRUCTURE
	----------------------------
	This project currently requires the module from:

	ReplicatedStorage
	└── Packages
		└── DissolveEffect
			├── Signal
	        ├── JobManager
	        ├── RuntimeWorker
	        ├── Actor
	        └── Mask

	If you move the module to ReplicatedStorage.DissolveEffect, update the
	require path in the setup section below.

	BLOOM / LIGHTING NOTE
	---------------------
	The dissolve edge and glow colors look best when a Bloom post-process effect
	is active in Lighting.

	Add a Bloom instance (BloomEffect) to "Lighting" with the following properties:

	```luau
	Intensity = 3
	Size = 100
	Threshold = 3.5
	```

	Using the Command Bar:
]=]

local Lighting = game:GetService("Lighting")
local bloom = Instance.new("BloomEffect")

bloom.Intensity = 3
bloom.Size = 100
bloom.Threshold = 3.5

bloom.Parent = Lighting

--[=[
	HOW THE MODULE WORKS (HIGH LEVEL)
	---------------------------------
	1. You call Dissolve.new() with a list of instances and an optional config.
	   The module scans those instances for supported objects and starts
	   preparing pixel data. This preparation phase is called baking.

	2. While baking, State is "Baking". When baking finishes, State changes to
	   "Ready" and the Ready signal fires. You can listen to Ready,
	   StateChanged, or poll IsReady() before calling Start().

	3. Calling Start(appear?) mounts generated masks over the original objects,
	   hides the originals, and animates frame by frame on PreRender until
	   progress reaches 1.0.

	   Default, appear = false or nil:
	   The animation plays forward, progressively removing pixels and creating a
	   dissolve/disintegration effect.

	   Appear mode, appear = true:
	   The animation plays in reverse, reconstructing the object over time.
	   Internally, this reuses the same baked data and inverts frame direction.

	4. When animation finishes, the Completed signal fires and the effect
	   automatically resets to Ready. The current implementation does not hold a
	   separate "Completed" State value.

	5. Call Reset() to restore originals and return to Ready manually. Call
	   Destroy() when you are done; it cleans up masks, EditableImages, cache
	   references, jobs, and public signals.

	PUBLIC API
	----------
	Dissolve.new({ instances }, config?)
	dissolve:Start(appear?)
	dissolve:Reset()
	dissolve:Destroy()
	dissolve:SetConfig(config)
	dissolve:IsReady()
	dissolve:IsRunning()
	dissolve:GetState()
	dissolve:GetProgress()
	dissolve:GetBakeProgress()

	SIGNALS
	-------
	dissolve.Ready
	dissolve.StateChanged
	dissolve.Completed

	LIFECYCLE STATES
	----------------
	"Idle"      - created but targets are not yet resolved.
	"Baking"    - precomputing pixel data; cannot Start() yet.
	"Ready"     - bake finished; safe to call Start().
	"Running"   - animation is playing.
	"Destroyed" - Destroy() was called; object is no longer usable.

	SUPPORTED INSTANCE TYPES
	------------------------
	Part              - standard brick shapes: Block, Ball, Cylinder, Wedge, CornerWedge.
	MeshPart          - custom mesh assets.
	SurfaceAppearance - colorMap (Only)
	Decal             - face overlays on parts.
	Texture           - repeating overlays on parts.
	ImageLabel        - 2D UI images inside a ScreenGui or SurfaceGui.
	ImageButton       - same as ImageLabel but interactive.

	NOT SUPPORTED TYPES
	-------------------
	Material        - plugin security
	MaterialVariant - plugin security

	Note: AutoDiscover controls whether descendants are included automatically.
	Passing a Model includes all supported descendants when AutoDiscover is "All".

	ASSET PERMISSION NOTE
	---------------------
	EditableImage can load texture assets only when they are owned by, shared
	with, or editable by the experience owner, Studio user, logged-in player, or
	an allowed group role. If a texture cannot be loaded, the module falls back
	to solid color where possible.
]=]

-- Setup - run once when this LocalScript starts.
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer

-- Require the module from this project's current ReplicatedStorage path.
local dissolveModule = ReplicatedStorage.Packages.DissolveEffect
local Dissolve = require(dissolveModule)

--[=[
	Add a Bloom instance (BloomEffect) to "Lighting" with the following properties:
	```luau
	Intensity = 3
	Size = 100
	Threshold = 3.5
	```

	Using the Command Bar:
]=]

local Lighting = game:GetService("Lighting")
local bloom = Instance.new("BloomEffect")

bloom.Intensity = 3
bloom.Size = 100
bloom.Threshold = 3.5

bloom.Parent = Lighting

local function startWhenReady(dissolve, appear: boolean?)
	if dissolve:IsReady() then
		dissolve:Start(appear)
		return
	end

	local connection
	connection = dissolve.Ready:Connect(function()
		connection:Disconnect()
		dissolve:Start(appear)
	end)
end

-- EXAMPLE 1 - Simplest possible usage
--[=[
	This is the bare minimum needed to dissolve a single part.

	Defaults include:
	Color      = bright yellow edge
	GlowColor  = orange glow
	Speed      = 0.15
	Bake       = "None" in the module defaults, or set "Mask" explicitly for
	             pre-baked mask data with lower memory than "Full".
	Size       = 128x128 pixels
	BakeFrames = 60 frames
]=]
local simplePart = workspace:FindFirstChild("SimplePart")

local simpleDissolveFn = function()
	if not simplePart then
		return
	end

	local dissolve = Dissolve.new({ simplePart }, {
		Bake = "Mask",
	})

	startWhenReady(dissolve)

	dissolve.Completed:Connect(function()
		dissolve:Destroy()
	end)
end

-- EXAMPLE 2 - Dissolving an entire character model
--[=[
	Pass a Model and set AutoDiscover to "All" so every supported descendant is
	included automatically. This is the most common pattern for character death
	effects or object removal.

	AutoDiscover values:
	"All"      - scans all descendants recursively.
	"Children" - scans direct children of each provided root.
	"None"     - processes only the exact instances you listed.
]=]
local function dissolveCharacter(character: Model)
	local dissolve = Dissolve.new({ character }, {
		Speed = 0.2,
		Color = Color3.fromRGB(0, 200, 255),
		GlowColor = Color3.fromRGB(0, 80, 255),
		Bake = "Mask",
		Behavior = {
			AutoDiscover = "All",
			ShowProgress = true,
		},
	})

	startWhenReady(dissolve)

	dissolve.Completed:Connect(function()
		dissolve:Destroy()
		character:Destroy()
	end)
end

local function connectCharacterDemo()
	return Players.LocalPlayer.CharacterAdded:Connect(function(character)
		task.delay(3, function()
			dissolveCharacter(character)
		end)
	end)
end

-- VISUAL PRESETS - Neon styles
--[=[
	These presets focus on strong neon/glow aesthetics and are designed to work
	well with Bloom enabled.

	General tips:
	* GlowWidth > EdgeWidth gives a softer neon look.
	* Higher ThicknessGain gives stronger edge definition.
	* Higher WarpStrength gives a more organic dissolve boundary.
]=]
local NeonPresets = {
	Blue = {
		Color = Color3.new(0, 1, 1),
		GlowColor = Color3.new(0, 0, 1),
	},

	Red = {
		Color = Color3.new(1, 0, 0),
		GlowColor = Color3.new(1, 0, 0),
	},

	Yellow = {
		Color = Color3.new(1, 1, 0),
		GlowColor = Color3.new(1, 0.333333, 0),
	},

	Purple = {
		Color = Color3.new(0.666667, 0, 1),
		GlowColor = Color3.new(0.501961, 0, 1),
	},

	Green = {
		Color = Color3.new(0, 1, 0),
		GlowColor = Color3.new(0, 1, 0),
	},
}

local function applyNeonPreset(target: Instance, preset)
	local dissolve = Dissolve.new({ target }, preset or NeonPresets.Blue)
	startWhenReady(dissolve)
	return dissolve
end

-- EXAMPLE 3 - Polling IsReady() instead of using signals
--[=[
	If you prefer a simple loop over connecting to signals, poll IsReady() with
	task.wait(). This is slightly less efficient but can be easier to read in
	linear example code.

	IsReady()   -> true only when State == "Ready".
	IsRunning() -> true only when State == "Running".
]=]
local polledPart = workspace:FindFirstChild("PolledPart")

local function dissolveWithPolling()
	if not polledPart then
		return
	end

	local dissolve = Dissolve.new({ polledPart }, {
		Speed = 0.3,
		Bake = "Full",
	})

	while not dissolve:IsReady() do
		task.wait()
	end

	dissolve:Start()

	while dissolve:IsRunning() do
		task.wait()
	end

	dissolve:Reset()
	dissolve:Start()
end

-- EXAMPLE 4 - Getting live progress and bake status
--[=[
	GetProgress()     -> number in the 0..1 range.
	GetBakeProgress() -> string such as "30 / 60".
	GetState()        -> current lifecycle state.

	Use these for custom UI instead of the built-in world-space progress label.
]=]
local progressPart = workspace:FindFirstChild("ProgressPart")

local function dissolveWithProgressUI()
	if not progressPart then
		return
	end

	local dissolve = Dissolve.new({ progressPart }, {
		BakeFrames = 90,
		Behavior = {
			ShowProgress = false,
		},
	})

	local bakeConn
	bakeConn = RunService.RenderStepped:Connect(function()
		print("Baking:", dissolve:GetBakeProgress())
		if dissolve:IsReady() then
			bakeConn:Disconnect()
		end
	end)

	local runConn
	dissolve.StateChanged:Connect(function(state)
		if state ~= "Running" then
			return
		end

		runConn = RunService.RenderStepped:Connect(function()
			if not dissolve:IsRunning() then
				runConn:Disconnect()
				return
			end

			print(string.format("Animation progress: %.0f%%", dissolve:GetProgress() * 100))
		end)
	end)

	startWhenReady(dissolve)

	dissolve.Completed:Connect(function()
		dissolve:Destroy()
	end)
end

-- EXAMPLE 5 - Changing settings after creation with SetConfig()
--[=[
	SetConfig() lets you update one or more settings. Changes that affect baked
	data restart preparation and set State back to "Baking".

	Only include keys you want to change. Behavior is merged into the current
	Behavior table, so you can pass only ShowProgress or only AutoDiscover.

	SetConfig() does not rediscover targets. Create a new Dissolve instance if
	you need a different target set or blacklist.
]=]
local configPart = workspace:FindFirstChild("ConfigPart")

local function dissolveWithConfigChange()
	if not configPart then
		return
	end

	local dissolve = Dissolve.new({ configPart }, {
		Color = Color3.fromRGB(255, 0, 0),
		GlowColor = Color3.fromRGB(255, 128, 0),
		Speed = 0.1,
		Bake = "Mask",
	})

	startWhenReady(dissolve)

	dissolve.Completed:Connect(function()
		dissolve:Reset()
		dissolve:SetConfig({
			Color = Color3.fromRGB(0, 255, 80),
			GlowColor = Color3.fromRGB(0, 200, 0),
		})

		startWhenReady(dissolve)
	end)
end

-- EXAMPLE 6 - Blacklisting specific instances
--[=[
	Blacklist accepts an array of instances that should be skipped during target
	discovery. This is useful when a model contains accessories, decals, or
	sub-parts that should remain untouched.
]=]
local model = workspace:FindFirstChild("SomeModel")

local function dissolveModelWithBlacklist()
	if not model then
		return
	end

	local excluded = model:FindFirstChild("HumanoidRootPart")

	local dissolve = Dissolve.new({ model }, {
		Bake = "Mask",
		Blacklist = excluded and { excluded } or {},
		Behavior = {
			AutoDiscover = "All",
		},
	})

	startWhenReady(dissolve)

	dissolve.Completed:Connect(function()
		dissolve:Destroy()
	end)
end

-- EXAMPLE 7 - Dissolving UI elements (ImageLabel / ImageButton)
--[=[
	The module supports 2D UI images. Pass an ImageLabel or ImageButton
	directly. The original element is hidden with ImageTransparency during
	playback and restored on Reset().

	Animations that already drive ImageTransparency may conflict with the effect.
]=]
local screenGui = player.PlayerGui:FindFirstChild("MyGui")
local imageLabel = screenGui and screenGui:FindFirstChild("MyImage")

local function dissolveUI()
	if not imageLabel then
		return
	end

	local dissolve = Dissolve.new({ imageLabel }, {
		Speed = 0.25,
		Color = Color3.fromRGB(255, 255, 255),
		GlowColor = Color3.fromRGB(200, 200, 255),
		Bake = "Mask",
		Size = Vector2.new(64, 64),
	})

	startWhenReady(dissolve)

	dissolve.Completed:Connect(function()
		dissolve:Destroy()
	end)
end

-- EXAMPLE 8 - Bake mode comparison
--[=[
	The Bake setting controls how much work is done before animation starts.

	"Full"
	- Fully renders every frame in advance: color and glow.
	- Fastest playback.
	- Highest memory usage.
	- Best for small objects or low BakeFrames.

	"Mask"
	- Bakes dissolve, edge, and glow masks, not final colors.
	- Recolors from stored masks during playback.
	- Lower memory than Full, slightly more CPU per frame.
	- Best balance of quality and memory.

	"None"
	- Skips frame baking and computes frames at runtime.
	- Minimal preparation wait.
	- Highest per-frame CPU cost.
	- Good for quick previews or instant playback.

	YieldMode controls how worker tasks yield while preparing bake data:
	"Aggressive" - fastest bake, may hitch more.
	"Balanced"   - middle ground.
	"Relaxed"    - smoother client frames during large bakes.
]=]
local bakePart = workspace:FindFirstChild("BakePart")

local bakeExamples = {
	{
		label = "Full bake",
		config = { Bake = "Full", YieldMode = "Balanced", BakeFrames = 60 },
	},
	{
		label = "Mask bake",
		config = { Bake = "Mask", YieldMode = "Balanced", BakeFrames = 60 },
	},
	{
		label = "No bake",
		config = { Bake = "None" },
	},
}

local function runBakeExample(example)
	if not bakePart then
		return
	end

	print("Starting:", example.label)

	local dissolve = Dissolve.new({ bakePart }, example.config)
	startWhenReady(dissolve)

	dissolve.Completed:Connect(function()
		dissolve:Destroy()
	end)
end

-- EXAMPLE 9 - Visual tuning reference
--[=[
	Every visual parameter documented with its purpose:

	Color                       Edge highlight color.
	GlowColor                   Soft glow color behind the edge.
	Speed                       Animation speed. Lower is slower.
	EdgeWidth                   Hard edge thickness in pixels.
	GlowWidth                   Glow spread past the edge.
	NoiseScale                  Frequency of the dissolve pattern.
	NoiseResolution             Internal tileable noise resolution.
	BakeFrames                  Number of precomputed frames for Full/Mask.
	Size                        EditableImage resolution per target.
	RegionFrequency             Number of dissolve regions/bands.
	ThicknessGain               Amplifies edge thickness.
	ThicknessBias               Offsets the edge threshold.
	WarpStrength                Warps the dissolve boundary.
	NoiseMap                    Image asset used as the dissolve noise source.
	TransformAutoUpdateEnabled  Keeps Base masks aligned with moving targets.
	EmissiveStrength            SurfaceAppearance emissive intensity for 3D masks.
]=]
local tunedDissolveFn = function(target: Instance)
	local dissolve = Dissolve.new({ target }, {
		Color = Color3.fromRGB(247, 249, 18),
		GlowColor = Color3.fromRGB(255, 85, 0),
		Speed = 0.15,
		EdgeWidth = 1,
		GlowWidth = 1,
		NoiseScale = 0.5,
		NoiseResolution = 64,
		BakeFrames = 60,
		Size = Vector2.new(128, 128),
		RegionFrequency = 3,
		ThicknessGain = 6,
		ThicknessBias = 0,
		WarpStrength = 0.5,
		Bake = "Mask",
		YieldMode = "Balanced",
		NoiseMap = 78956512312605,
		TransformAutoUpdateEnabled = true,
		EmissiveStrength = 5.75,
		Behavior = {
			ShowProgress = true,
			AutoDiscover = "All",
		},
		Blacklist = {},
	})

	startWhenReady(dissolve)

	dissolve.Completed:Connect(function()
		dissolve:Destroy()
	end)

	return dissolve
end

-- EXAMPLE 10 - Reusing the same effect on multiple objects in sequence
--[=[
	Baked frame data is cached internally using a key that includes the asset ID
	and visual settings. Creating another Dissolve with the same texture and
	config can reuse existing bake data, making repeated effects cheaper.
]=]
local partsFolder = workspace:FindFirstChild("Parts")
local parts = partsFolder and partsFolder:GetChildren() or {}

local function dissolveSequentially()
	for _, part in ipairs(parts) do
		local dissolve = Dissolve.new({ part }, {
			Bake = "Mask",
			Speed = 0.3,
		})

		startWhenReady(dissolve)

		local done = false
		dissolve.Completed:Connect(function()
			dissolve:Destroy()
			done = true
		end)

		while not done do
			task.wait()
		end
	end
end
