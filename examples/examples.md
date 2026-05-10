# DissolveEffect examples

`DissolveEffect` is a client-side Roblox module for dissolving 3D objects,
texture overlays, and image UI through generated `EditableImage` masks.

## Requirements

This module must run on the client. Use a `LocalScript`, or a `ModuleScript`
required by a `LocalScript`. If you require it from the server, the module
returns an empty table and prints a warning.

The module also requires Roblox's `EditableImage` API. In published
experiences, enable it from Studio after your account is age and ID verified:

1. Open **Experience Settings**.
2. Go to **Security**.
3. Enable **Allow Mesh / Image APIs**.

If this setting is disabled, baking can fail and the effect may look invisible
or broken.

## Recommended folder structure

These examples assume the package is available at:

```text
ReplicatedStorage
└── Packages
    └── DissolveEffect
        ├── Signal
        ├── JobManager
        ├── RuntimeWorker
        ├── Actor
        └── Mask
```

If you move the package to another location, update the `require` path in your
setup code.

## Bloom setup

The edge and glow colors look best when a `BloomEffect` is active in
`Lighting`.

```luau
local Lighting = game:GetService("Lighting")
local bloom = Instance.new("BloomEffect")

bloom.Intensity = 3
bloom.Size = 100
bloom.Threshold = 3.5

bloom.Parent = Lighting
```

## Basic setup

Put this near the top of the `LocalScript` that runs your examples.

```luau
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer

local dissolveModule = ReplicatedStorage.Packages.DissolveEffect
local Dissolve = require(dissolveModule)

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
```

## How the module works

1. `Dissolve.new({ instances }, config?)` scans the given instances for
   supported targets and starts preparing their pixel data.
2. While preparing, the state is `"Baking"`. When preparation finishes, the
   state becomes `"Ready"` and `Ready` fires.
3. `Start(appear?)` mounts generated masks, hides the original objects, and
   animates the dissolve on `PreRender`.
4. `Start(true)` plays the same data in reverse, making the object appear.
5. `Completed` fires when playback finishes. The effect then resets to
   `"Ready"`.
6. `Reset()` restores the original objects. `Destroy()` cleans up masks,
   editable images, cached references, jobs, and signals.

## Public API

```luau
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
```

Signals:

```luau
dissolve.Ready
dissolve.StateChanged
dissolve.Completed
```

Lifecycle states:

| State | Meaning |
| --- | --- |
| `"Idle"` | Created, but targets are not resolved yet. |
| `"Baking"` | Pixel data is being prepared. |
| `"Ready"` | Preparation finished; `Start()` is safe. |
| `"Running"` | Animation is playing. |
| `"Destroyed"` | `Destroy()` was called. |

Supported instance types:

| Type | Notes |
| --- | --- |
| `Part` | Supports Block, Ball, Cylinder, Wedge, and CornerWedge. |
| `MeshPart` | Supports custom mesh assets. |
| `SurfaceAppearance` | Uses `ColorMap` only. |
| `Decal` | Face overlays on parts. |
| `Texture` | Repeating overlays on parts. |
| `ImageLabel` | 2D UI images. |
| `ImageButton` | Same as `ImageLabel`, but interactive. |

`Material` and `MaterialVariant` are not supported because of plugin security
restrictions.

Asset permissions still apply. `EditableImage` can only load texture assets
owned by, shared with, or editable by the experience owner, Studio user,
logged-in player, or an allowed group role. If an asset cannot be loaded, the
module falls back to solid color where possible.

## Example 1: Simple part dissolve

This is the smallest useful version for dissolving one part.

```luau
local simplePart = workspace:FindFirstChild("SimplePart")

local function dissolveSimplePart()
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
```

## Example 2: Character model dissolve

Use `AutoDiscover = "All"` when passing a `Model`, so every supported
descendant is included automatically.

```luau
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

Players.LocalPlayer.CharacterAdded:Connect(function(character)
	task.delay(3, function()
		dissolveCharacter(character)
	end)
end)
```

`AutoDiscover` values:

| Value | Behavior |
| --- | --- |
| `"All"` | Scans all descendants recursively. |
| `"Children"` | Scans direct children of each provided root. |
| `"None"` | Processes only the exact instances you listed. |

## Example 3: Neon presets

These presets are tuned for strong glow, especially with Bloom enabled.

```luau
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
```

## Example 4: Polling readiness

Signals are recommended, but polling can be easier for linear demo code.

```luau
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
```

## Example 5: Custom progress UI

Use `GetBakeProgress()`, `GetProgress()`, and `GetState()` when you want your
own UI instead of the built-in world-space progress label.

```luau
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
```

## Example 6: Change config after creation

`SetConfig()` updates one or more settings. Changes that affect baked data
restart preparation and return the state to `"Baking"`.

```luau
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
```

`SetConfig()` does not rediscover targets. Create a new `Dissolve` instance if
you need a different target set or blacklist.

## Example 7: Blacklist instances

`Blacklist` skips specific instances during discovery.

```luau
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
```

## Example 8: UI dissolve

Pass an `ImageLabel` or `ImageButton` directly. The original UI element is
hidden with `ImageTransparency` during playback and restored on `Reset()`.

```luau
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
```

Animations that already drive `ImageTransparency` may conflict with the effect.

## Example 9: Bake mode comparison

The `Bake` setting controls how much work happens before animation starts.

| Mode | Tradeoff |
| --- | --- |
| `"Full"` | Fully renders every frame in advance. Fastest playback, highest memory usage. |
| `"Mask"` | Bakes dissolve, edge, and glow masks. Good balance of memory and playback cost. |
| `"None"` | Skips frame baking and computes frames during playback. Fastest preparation, highest runtime cost. |

```luau
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
```

`YieldMode` controls how worker tasks yield while preparing bake data:

| Mode | Behavior |
| --- | --- |
| `"Aggressive"` | Fastest bake, but may hitch more. |
| `"Balanced"` | Middle ground. |
| `"Relaxed"` | Smoother client frames during large bakes. |

## Example 10: Full visual tuning reference

```luau
local function tunedDissolve(target: Instance)
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
```

Visual config reference:

| Key | Purpose |
| --- | --- |
| `Color` | Edge highlight color. |
| `GlowColor` | Soft glow color behind the edge. |
| `Speed` | Animation speed. Lower is slower. |
| `EdgeWidth` | Hard edge thickness in pixels. |
| `GlowWidth` | Glow spread past the edge. |
| `NoiseScale` | Frequency of the dissolve pattern. |
| `NoiseResolution` | Internal tileable noise resolution. |
| `BakeFrames` | Number of precomputed frames for `Full` or `Mask`. |
| `Size` | `EditableImage` resolution per target. |
| `RegionFrequency` | Number of dissolve regions or bands. |
| `ThicknessGain` | Amplifies edge thickness. |
| `ThicknessBias` | Offsets the edge threshold. |
| `WarpStrength` | Warps the dissolve boundary. |
| `NoiseMap` | Image asset used as the dissolve noise source. |
| `TransformAutoUpdateEnabled` | Keeps Base masks aligned with moving targets. |
| `EmissiveStrength` | SurfaceAppearance emissive intensity for 3D masks. |

## Example 11: Sequential dissolves

Baked frame data is cached internally using a key that includes the asset ID and
visual settings. Reusing the same config can make repeated effects cheaper.

```luau
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
```
