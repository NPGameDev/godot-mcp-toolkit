@tool
extends RefCounted
## sound.generate — procedural placeholder SFX (PCM → AudioStreamWAV → .wav).
##
## Closes the other half of the can't-produce-assets blindspot: the LLM can't
## synthesise audio (agents have reached for Python to fake it). This generates
## short sound effects — single-oscillator tones (sine/square/triangle/sawtooth)
## or noise, with an optional pitch sweep and a numeric de-click/decay envelope —
## as a mono 16-bit WAV. SFX only; music/melodies are out of scope.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const Helpers = Modules.CommandHelpers

const ALLOWED_EXTS := ["wav"]
const MIX_RATE := 44100
const MAX_DURATION := 5.0
const DEFAULT_DURATION := 0.3
const DEFAULT_DECLICK := 0.003  # 3 ms auto fade to avoid start/stop clicks
const WAVEFORMS := ["sine", "square", "triangle", "sawtooth", "noise"]


static func register(registry: MCPToolkitCommandRegistry, _server: Node) -> void:
	registry.add("sound.generate", func(parameters: Dictionary) -> Dictionary:
		return await _cmd_generate(parameters)
	, MCPToolkitCommandOptions.new()
		.mark_scene_independent()
		.guard_project_path("file_path")
		.with_timeout_ms(40000)
		.with_success_hint(
			"Assign the stream: node_set_property on "
			+ "AudioStreamPlayer/AudioStreamPlayer2D/AudioStreamPlayer3D.stream."))


static func _cmd_generate(parameters: Dictionary) -> Dictionary:
	var file_path := str(parameters.get("file_path", ""))
	if file_path == "":
		return MCPToolkitError.fail("INVALID_PARAMS",
			"file_path is required (res:// destination ending in .wav)", MCPToolkitError.HINT_FILE_PATH)

	var waveform := str(parameters.get("waveform", "sine")).to_lower()
	if waveform not in WAVEFORMS:
		return MCPToolkitError.fail("INVALID_PARAMS",
			"waveform must be one of: %s (got '%s')" % [", ".join(WAVEFORMS), waveform])

	var duration: float = clampf(float(parameters.get("duration", DEFAULT_DURATION)), 0.001, MAX_DURATION)
	var frequency: float = clampf(float(parameters.get("frequency", 440.0)), 1.0, 20000.0)
	var has_end := parameters.has("end_frequency")
	var end_frequency: float = clampf(float(parameters.get("end_frequency", frequency)), 1.0, 20000.0)
	var volume: float = clampf(float(parameters.get("volume", 0.8)), 0.0, 1.0)
	var decay: float = maxf(0.0, float(parameters.get("decay", 0.0)))

	# Envelope fades (default ~3 ms de-click; clamped so in+out <= duration).
	var fade_in: float = maxf(0.0, float(parameters.get("fade_in", DEFAULT_DECLICK)))
	var fade_out: float = maxf(0.0, float(parameters.get("fade_out", DEFAULT_DECLICK)))
	if fade_in + fade_out > duration:
		var scale := duration / (fade_in + fade_out)
		fade_in *= scale
		fade_out *= scale

	var data := _build_pcm(
		waveform, frequency, end_frequency, has_end, duration, volume, fade_in, fade_out, decay)

	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = MIX_RATE
	stream.stereo = false
	stream.data = data

	var write_fn := func(write_path: String) -> Dictionary:
		var err := stream.save_to_wav(write_path)
		if err != OK:
			return MCPToolkitError.fail("WRITE_FAILED",
				"AudioStreamWAV.save_to_wav failed for %s (err %d)" % [write_path, err])
		return {}

	var if_exists := str(parameters.get("if_exists", "return"))
	# Default 0 = no import-settle poll: a generated WAV is an AudioStreamWAV by
	# construction, so the class is reported directly (no FS round-trip). Pass an
	# explicit wait_for_scan_ms > 0 to force a settle.
	var wait_for_scan_ms := int(parameters.get("wait_for_scan_ms", 0))
	var result := await Helpers.write_asset_with_settle(
		file_path, PackedStringArray(ALLOWED_EXTS), if_exists, wait_for_scan_ms, "sound.generate", write_fn, "AudioStreamWAV")
	if not result.get("success", false):
		return result

	if result.get("status") != "returned":
		result["waveform"] = waveform
		result["duration"] = snappedf(duration, 0.001)
		result["frequency"] = snappedf(frequency, 0.01)
		if has_end:
			result["end_frequency"] = snappedf(end_frequency, 0.01)
	return result


## Synthesize mono 16-bit little-endian PCM. Pure (no editor) — unit-testable.
static func _build_pcm(
	waveform: String, frequency: float, end_frequency: float, has_end: bool,
	duration: float, volume: float, fade_in: float, fade_out: float, decay: float,
) -> PackedByteArray:
	var sample_count := maxi(1, int(duration * MIX_RATE))
	var fade_in_samples := int(fade_in * MIX_RATE)
	var fade_out_samples := int(fade_out * MIX_RATE)

	var data := PackedByteArray()
	data.resize(sample_count * 2)

	var phase := 0.0
	for i in range(sample_count):
		var t := float(i) / MIX_RATE
		var inst_freq := frequency
		if has_end:
			inst_freq = frequency + (end_frequency - frequency) * (t / duration)

		var sample := _oscillator(waveform, phase)
		phase += TAU * inst_freq / MIX_RATE

		# Envelope: volume * fade * decay.
		var env := volume
		if fade_in_samples > 0 and i < fade_in_samples:
			env *= float(i) / fade_in_samples
		if fade_out_samples > 0 and i >= sample_count - fade_out_samples:
			env *= float(sample_count - i) / fade_out_samples
		if decay > 0.0:
			env *= exp(-t / decay)

		var value := int(clampf(sample * env, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, value)
	return data


## One oscillator sample in [-1, 1] for the given accumulated phase (radians).
static func _oscillator(waveform: String, phase: float) -> float:
	match waveform:
		"sine":
			return sin(phase)
		"square":
			return 1.0 if sin(phase) >= 0.0 else -1.0
		"triangle":
			return 2.0 / PI * asin(sin(phase))
		"sawtooth":
			return 2.0 * (fposmod(phase, TAU) / TAU) - 1.0
		"noise":
			return randf_range(-1.0, 1.0)
	return 0.0
