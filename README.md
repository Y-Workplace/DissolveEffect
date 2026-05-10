# Dissolve Effect

High-performance dissolve / disintegration effect system for Roblox using `EditableImage`.

Designed for:

* Characters
* Meshes
* UI Images
* Decals / Textures
* Large dissolve sequences
* Reusable baked effects

The module supports multiple bake modes, glow edges, animated dissolve masks, cached frame generation, and reversible appear/disappear playback.

---

# Important

## Client-side only

This module only works on the client.

`EditableImage` does not exist on the server, so the module must be required from a `LocalScript` or from a `ModuleScript` used by a `LocalScript`.

---

## EditableImage must be enabled

Roblox disables EditableImage APIs by default in published experiences.

To enable it:

1. Verify your Roblox account (13+ and ID verified)
2. Open `Game Settings`
3. Go to `Security`
4. Enable:

```text
Allow Mesh / Image APIs
```

If this setting is disabled:

* Baking will fail
* EditableImage creation may fail
* The dissolve effect may appear invisible or broken

This is a Roblox platform restriction.

---

# Recommended Folder Structure

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

Example require:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Dissolve = require(
    ReplicatedStorage.Packages.DissolveEffect
)
```

---

# Bloom / Lighting

The glow and edge colors look significantly better when Bloom is enabled.

Add a Bloom instance (BloomEffect) to "Lighting" with the following properties:

```luau
Intensity = 3
Size = 100
Threshold = 3.5
```

Using the Command Bar:

```luau
local Lighting = game:GetService("Lighting")
local bloom = Instance.new("BloomEffect")

bloom.Intensity = 3
bloom.Size = 100
bloom.Threshold = 3.5

bloom.Parent = Lighting
```

---

# How It Works

## 1. Create the effect

You create a dissolve object using:

```luau
local dissolve = Dissolve.new({ object }, config)
```

The module scans supported objects and prepares internal image data.

This preparation phase is called:

```text
Baking
```

---

## 2. Wait until ready

While preparing:

```text
State = "Baking"
```

After finishing:

```text
State = "Ready"
```

You can:

* Use `Ready`
* Use `StateChanged`
* Poll `IsReady()`

---

## 3. Start animation

```luau
:dissolve:Start()
```

The original object becomes hidden.

Generated dissolve masks animate frame-by-frame until the effect completes.

---

## 4. Reverse playback

```luau
:dissolve:Start(true)
```

Passing `true` plays the animation backwards.

Instead of dissolving away, the object reconstructs itself.

---

## 5. Cleanup

```luau
:dissolve:Destroy()
```

This removes:

* EditableImages
* Masks
* Signals
* Cached references
* Running jobs

Always destroy effects you no longer use.

---

# Public API

```luau
Dissolve.new({ instances }, config?)

:dissolve:Start(appear?)
:dissolve:Reset()
:dissolve:Destroy()
:dissolve:SetConfig(config)

:dissolve:IsReady()
:dissolve:IsRunning()

:dissolve:GetState()
:dissolve:GetProgress()
:dissolve:GetBakeProgress()
```

---

# Signals

```luau
:dissolve.Ready
:dissolve.StateChanged
:dissolve.Completed
```

---

# Lifecycle States

| State       | Description                   |
| ----------- | ----------------------------- |
| `Idle`      | Created but not prepared yet  |
| `Baking`    | Preparing dissolve frame data |
| `Ready`     | Safe to start                 |
| `Running`   | Animation currently playing   |
| `Destroyed` | Effect no longer usable       |

---

# Supported Types

## 3D

* Part
* MeshPart
* Decal
* Texture
* SurfaceAppearance (`ColorMap only`)

## UI

* ImageLabel
* ImageButton

---

# Unsupported Types

```text
Material
MaterialVariant
```

These are blocked by Roblox security restrictions.

---

# Asset Permission Notes

EditableImage can only load textures that Roblox allows the experience to access.

If a texture is unavailable:

* The module may fallback to solid colors
* Some effects may appear simplified

---

# Quick Start

## Minimal Example

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Dissolve = require(
    ReplicatedStorage.Packages.DissolveEffect
)

local part = workspace.Part

local dissolve = Dissolve.new({ part }, {
    Bake = "Mask",
})

if dissolve:IsReady() then
    dissolve:Start()
else
    local connection

    connection = dissolve.Ready:Connect(function()
        connection:Disconnect()
        dissolve:Start()
    end)
end
```

---

# Examples

# Helper Function

Used in multiple examples below.

```luau
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

---

## Dissolve a Character

```luau
local Players = game:GetService("Players")

local function dissolveCharacter(character: Model)
    local dissolve = Dissolve.new({ character }, {
        Speed = 0.2,
        Bake = "Mask",

        Behavior = {
            AutoDiscover = "All",
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

---

## Dissolve UI Images

```luau
local player = game:GetService("Players").LocalPlayer

local imageLabel = player.PlayerGui.ScreenGui.ImageLabel

local dissolve = Dissolve.new({ imageLabel }, {
    Speed = 0.25,
    Bake = "Mask",
})

startWhenReady(dissolve)
```

---

## Reverse Playback (Appear)

```luau
local dissolve = Dissolve.new({ workspace.Part }, {
    Bake = "Mask",
})

startWhenReady(dissolve, true)
```

---

## Polling Instead of Signals

```luau
local dissolve = Dissolve.new({ workspace.Part }, {
    Bake = "Full",
})

while not dissolve:IsReady() do
    task.wait()
end

:dissolve:Start()

while dissolve:IsRunning() do
    task.wait()
end
```

---

## Progress Tracking

```luau
RunService.RenderStepped:Connect(function()
    print(dissolve:GetProgress())
    print(dissolve:GetBakeProgress())
end)
```

---

# Bake Modes

## Full

Fully pre-renders all frames.

### Advantages

* Fastest playback
* Lowest runtime cost

### Disadvantages

* Highest memory usage
* Longer preparation time

Best for:

* Small objects
* Cinematics
* Repeated effects

---

## Mask

Precomputes dissolve masks only.

### Advantages

* Lower memory usage
* Good performance balance
* Recommended mode

### Disadvantages

* Slightly more runtime processing

Best for:

* General gameplay
* Characters
* Most projects

---

## None

No baking.

Frames are generated in real time.

### Advantages

* Instant startup
* Minimal preparation wait

### Disadvantages

* Highest runtime CPU cost

Best for:

* Quick previews
* Development tools
* Editor workflows

---

# Yield Modes

Controls how aggressively baking work yields.

| Mode         | Description                          |
| ------------ | ------------------------------------ |
| `Aggressive` | Fastest bake, may freeze frames more |
| `Balanced`   | Recommended balance                  |
| `Relaxed`    | Smoothest gameplay during baking     |

---

# AutoDiscover

Controls descendant scanning.

| Mode       | Description               |
| ---------- | ------------------------- |
| `All`      | Recursive descendant scan |
| `Children` | Direct children only      |
| `None`     | Exact instances only      |

---

# Visual Parameters

| Setting                      | Description                     |
| ---------------------------- | ------------------------------- |
| `Color`                      | Edge highlight color            |
| `GlowColor`                  | Glow behind edges               |
| `Speed`                      | Animation speed                 |
| `EdgeWidth`                  | Hard edge thickness             |
| `GlowWidth`                  | Glow size                       |
| `NoiseScale`                 | Dissolve pattern frequency      |
| `NoiseResolution`            | Internal noise texture size     |
| `BakeFrames`                 | Amount of baked frames          |
| `Size`                       | EditableImage resolution        |
| `RegionFrequency`            | Dissolve band count             |
| `ThicknessGain`              | Edge amplification              |
| `ThicknessBias`              | Edge threshold offset           |
| `WarpStrength`               | Boundary distortion amount      |
| `NoiseMap`                   | Custom dissolve texture         |
| `TransformAutoUpdateEnabled` | Updates moving targets          |
| `EmissiveStrength`           | SurfaceAppearance glow strength |

---

# Preset Example

```luau
local dissolve = Dissolve.new({ workspace.Part }, {
    Color = Color3.fromRGB(0, 255, 255),
    GlowColor = Color3.fromRGB(0, 120, 255),

    Speed = 0.15,

    EdgeWidth = 1,
    GlowWidth = 2,

    NoiseScale = 0.5,
    NoiseResolution = 64,

    BakeFrames = 60,
    Size = Vector2.new(128, 128),

    WarpStrength = 0.5,

    Bake = "Mask",
    YieldMode = "Balanced",

    Behavior = {
        AutoDiscover = "All",
    },
})
```

---

# Internal Cache Reuse

The module internally reuses baked frame data when:

* The same textures are used
* The same configuration is used

This makes repeated dissolves significantly cheaper after the first bake.

Useful for:

* Enemy waves
* Rhythm gameplay
* Repeated VFX
* Character respawns

---

# Best Practices

## Recommended Defaults

```luau
Bake = "Mask"
YieldMode = "Balanced"
BakeFrames = 60
Size = Vector2.new(128, 128)
```

---

## Large Objects

For large meshes or characters:

```luau
YieldMode = "Relaxed"
```

This reduces frame spikes while baking.

---

## UI Effects

Avoid simultaneously animating:

```luau
ImageTransparency
```

during dissolve playback.

---

## Always Destroy Effects

```luau
dissolve:Destroy()
```

Do not leave unused effects alive.

---

# Installation
## Roblox Creator Store
Add the module directly from the Creator Store:

```
Creator Store Model:
https://create.roblox.com/store/asset/126151482111558
```

---

## Wally

```
[dependencies]
DissolveEffect = "YOUR_WALLY_PACKAGE"
```

Wally Package:

```
https://wally.run/package/YOUR_WALLY_PACKAGE
```

---

# License

MIT License.
