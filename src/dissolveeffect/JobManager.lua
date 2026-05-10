--[=[
	@class JobManager

	JobManager owns a small pool of Actor workers and processes bake requests
	one job at a time.

	Each job is split into frame ranges and sent to the available actors through
	`Actor:SendMessage`. When all chunks return, the original callback receives
	the ordered partial results.
]=]
local JobManager = {
	_queue = {},
	_isProcessing = false,
	_actors = {},
	_maxActors = 16,
	_results = {},
	_head = 1,
	_count = 1,
}

--[=[
	@param templateActor Actor -- Actor cloned to create every bake worker.
	@param parent Instance -- Parent used to store the cloned workers.

	Initializes the worker pool.

	Calling `Init` more than once is safe. Existing workers are kept and no new
	actors are cloned after the first successful initialization.
	```lua
	JobManager:Init(script.Actor, workspace.Temp)
	```
]=]
function JobManager.Init(self: JobManager, templateActor: Actor, parent: Instance)
	if #self._actors > 0 then
		return
	end
	for i = 1, self._maxActors do
		local newActor = templateActor:Clone() :: Actor
		newActor.Name = "BakeWorker_" .. i
		newActor.Parent = parent
		table.insert(self._actors, newActor)
	end
end

--[=[
	@param id any -- Caller-owned identifier stored with the queued job.
	@param data BakeJobData -- Buffers and settings required by the workers.
	@param callback BakeCallback -- Called when all worker chunks finish.
	@return JobHandle

	Queues a bake job and returns a handle that can cancel it before completion.
	```lua
	local handle = JobManager:AddJob(self, data, function(results)
		print("Chunks baked:", #results)
	end)

	handle:Cancel()
	```
]=]
function JobManager.AddJob(self: JobManager, id: any, data: BakeJobData, callback: BakeCallback): JobHandle
	local handle: JobHandle = {
		_cancelled = false,
		Cancel = function(self: JobHandle)
			self._cancelled = true
		end,
	}

	local job: Job = {
		id = id,
		data = data,
		callback = callback,
		handle = handle,
	}

	self._queue[self._count] = job
	self._count += 1

	self:ProcessNext()

	return handle
end

--[=[
	Processes the next queued bake job.

	This method is called automatically by `AddJob` and again after every job
	completes. Cancelled jobs are skipped before work is dispatched.
]=]
function JobManager.ProcessNext(self: JobManager)
	if self._isProcessing then
		return
	end
	self._isProcessing = true

	local job: Job? = nil

	while self._head < self._count do
		job = self._queue[self._head]
		self._queue[self._head] = nil
		self._head += 1

		if job and not job.handle._cancelled then
			break
		end

		job = nil
	end

	if not job then
		self._isProcessing = false
		return
	end

	-- Compact the sparse queue once enough cancelled or completed slots build up.
	if self._head > 1024 then
		local newQueue: { [number]: Job } = {}
		local j = 1

		for i = self._head, self._count - 1 do
			local v = self._queue[i]
			if v ~= nil then
				newQueue[j] = v
				j += 1
			end
		end

		self._queue = newQueue
		self._head = 1
		self._count = j
	end

	if job.handle._cancelled then
		self._isProcessing = false
		self:ProcessNext()
		return
	end

	local currentJob: Job = job
	local numFrames = currentJob.data.config.BakeFrames
	local framesPerActor = math.ceil(numFrames / #self._actors)
	local pending = 0
	local partials: { BakeChunkResult } = {}

	local tempEvent = Instance.new("BindableEvent")

	local activeActors = 0
	local workingActors = 0

	local connection: RBXScriptConnection

	connection = tempEvent.Event:Connect(function(result: BakeChunkResult)
		partials[result.id] = result
		pending -= 1
		activeActors += 1
		if currentJob.data.onProgress then
			currentJob.data.onProgress(activeActors, workingActors)
		end
		if pending == 0 then
			connection:Disconnect()
			tempEvent:Destroy()

			if currentJob.handle._cancelled then
				self._isProcessing = false
				self:ProcessNext()
				return
			end

			currentJob.callback(partials)
			self._isProcessing = false
			self:ProcessNext()
		end
	end)

	for i, actor in ipairs(self._actors) do
		local startF = (i - 1) * framesPerActor + 1
		local endF = math.min(i * framesPerActor, numFrames)
		if startF <= numFrames then
			pending += 1
			workingActors += 1

			task.defer(function()
				local message: BakeChunkMessage = {
					id = i,
					startFrame = startF,
					endFrame = endF,
					baseBuffer = currentJob.data.baseBuffer,
					noiseBuffer = currentJob.data.noiseBuffer,
					width = currentJob.data.width,
					height = currentJob.data.height,
					noiseWidth = currentJob.data.noiseWidth,
					noiseHeight = currentJob.data.noiseHeight,
					config = currentJob.data.config,
					totalBytes = currentJob.data.totalBytes,
					isBase = currentJob.data.isBase,
					rt = currentJob.data.rt,
					resultEvent = tempEvent,
				}

				actor:SendMessage("BakeChunk", message)
			end)
		end
	end
end

--[=[
	@within JobManager
	@interface BakeConfig
	* BakeFrames: number

	Minimal configuration shape required by the job scheduler.
]=]
type BakeConfig = {
	BakeFrames: number,
}

--[=[
	@within JobManager
	@interface RuntimeBuffers
	* maskBuf: buffer?
	* invBuf: buffer?
	* dSolid: buffer?
	* dEmpty: buffer?
	* normBuf: buffer?
	* distBuf: buffer?

	Reusable scratch buffers shared with the bake worker.
]=]
type RuntimeBuffers = {
	maskBuf: buffer?,
	invBuf: buffer?,
	dSolid: buffer?,
	dEmpty: buffer?,
	normBuf: buffer?,
	distBuf: buffer?,
}

--[=[
	@within JobManager
	@interface BakeJobData
	* baseBuffer: buffer
	* noiseBuffer: buffer
	* width: number
	* height: number
	* noiseWidth: number
	* noiseHeight: number
	* config: BakeConfig
	* totalBytes: number
	* rt: RuntimeBuffers
	* onProgress: ((number, number) -> ())?

	Contains the buffers and bake settings sent to each worker actor.
]=]
export type BakeJobData = {
	baseBuffer: buffer,
	noiseBuffer: buffer,
	width: number,
	height: number,
	noiseWidth: number,
	noiseHeight: number,
	config: BakeConfig,
	totalBytes: number,
	isBase: boolean,
	rt: RuntimeBuffers,
	onProgress: ((number, number) -> ())?,
}

type BakeChunkMessage = {
	id: number,
	startFrame: number,
	endFrame: number,
	baseBuffer: buffer,
	noiseBuffer: buffer,
	width: number,
	height: number,
	noiseWidth: number,
	noiseHeight: number,
	config: BakeConfig,
	totalBytes: number,
	rt: RuntimeBuffers,
	resultEvent: BindableEvent,
}

type BakeChunkResult = {
	id: number,
	startFrame: number,
	base: buffer?,
	emissive: buffer?,
	dissolve: buffer?,
	edge: buffer?,
	glow: buffer?,
}

type BakeCallback = ({ BakeChunkResult }) -> ()

--[=[
	@within JobManager
	@interface JobHandle
	* _cancelled: boolean
	* Cancel: (JobHandle) -> ()

	Represents a queued or running bake job.
]=]
export type JobHandle = {
	_cancelled: boolean,
	Cancel: (self: JobHandle) -> (),
}

type Job = {
	id: any,
	data: BakeJobData,
	callback: BakeCallback,
	handle: JobHandle,
}

export type JobManager = typeof(JobManager)

return JobManager :: JobManager
