package vega

import "core:log"
import "core:math"
import "core:math/rand"
import "core:strings"
import sdl "vendor:sdl3"

SFX_STREAMS :: 8

baked_sfx := #load_directory("sfx")

Click_Sample :: struct {
	family: int,
	data:   []u8,
}

Sfx :: struct {
	families:  [dynamic]string,
	samples:   [dynamic]Click_Sample,
	deletions: [dynamic][]u8,
	deletion_names: [dynamic]string,
	streams:   [SFX_STREAMS]^sdl.AudioStream,
	deleter:   ^sdl.AudioStream,
	noise:     ^sdl.AudioStream,
	brown:     f32,
	blocked:   f32,
	previous:  f32,
	warmth:    f32,
	next:      int,
	ready:     bool,
	logged:    bool,
}

DELETION_FAMILY :: "deletion"
NOISE_RATE :: 44100
NOISE_CHUNK :: NOISE_RATE / 4
NOISE_QUEUE :: NOISE_RATE * 2
NOISE_STEP :: 0.02
NOISE_LEAK :: 1.02
NOISE_GAIN :: 4.0
NOISE_BLOCK :: 0.9975
NOISE_DARKEST :: 50.0
NOISE_MIDDLE :: 200.0
NOISE_BRIGHTEST :: 800.0

sfx: Sfx

sample_family :: proc(name: string) -> string {
	trimmed := strings.trim_suffix(name, ".wav")
	if cut := strings.last_index_byte(trimmed, '_'); cut > 0 {
		if _, digits := parse_digits(trimmed[cut + 1:]); digits {
			trimmed = trimmed[:cut]
		}
	}
	return strings.trim_suffix(trimmed, "_keys")
}

parse_digits :: proc(text: string) -> (value: int, ok: bool) {
	if text == "" {
		return 0, false
	}
	for character in text {
		if character < '0' || character > '9' {
			return 0, false
		}
		value = value * 10 + int(character - '0')
	}
	return value, true
}

sfx_load :: proc(editor: ^Editor) {
	spec: sdl.AudioSpec
	for entry in baked_sfx {
		if !strings.has_suffix(entry.name, ".wav") {
			continue
		}
		stream := sdl.IOFromConstMem(raw_data(entry.data), uint(len(entry.data)))
		if stream == nil {
			continue
		}
		loaded: sdl.AudioSpec
		buffer: [^]u8
		length: u32
		if !sdl.LoadWAV_IO(stream, true, &loaded, &buffer, &length) {
			log.warnf("could not decode %s: %s", entry.name, sdl.GetError())
			continue
		}
		spec = loaded

		family := sample_family(entry.name)
		if family == DELETION_FAMILY {
			append(&sfx.deletions, buffer[:length])
			append(&sfx.deletion_names, strings.clone(strings.trim_suffix(entry.name, ".wav")))
			continue
		}
		index := -1
		for known, position in sfx.families {
			if known == family {
				index = position
			}
		}
		if index < 0 {
			append(&sfx.families, strings.clone(family))
			index = len(sfx.families) - 1
		}
		append(&sfx.samples, Click_Sample{index, buffer[:length]})
	}
	if len(sfx.samples) == 0 {
		log.warn("no key sounds were baked in")
		return
	}

	for position in 0 ..< SFX_STREAMS {
		sfx.streams[position] = sdl.OpenAudioDeviceStream(sdl.AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, nil, nil)
		if sfx.streams[position] == nil {
			log.errorf("no audio device: %s", sdl.GetError())
			return
		}
		sdl.ResumeAudioStreamDevice(sfx.streams[position])
	}
	sfx.deleter = sdl.OpenAudioDeviceStream(sdl.AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, nil, nil)
	if sfx.deleter != nil {
		sdl.ResumeAudioStreamDevice(sfx.deleter)
	}
	sfx.ready = true
	editor.config.click_kind = u8(clamp(int(editor.config.click_kind), 0, len(sfx.families) - 1))
	log.infof("%d key sounds in %d families at %d Hz", len(sfx.samples), len(sfx.families), spec.freq)
}

no_family := []string{"none"}

sfx_family_names :: proc() -> []string {
	return len(sfx.families) == 0 ? no_family : sfx.families[:]
}

sfx_click :: proc(editor: ^Editor) {
	if !sfx.ready || !(.KeyClicks in editor.config.options) || editor.config.click_volume <= 0 {
		return
	}
	allowed: Option
	switch editor.mode {
	case .Normal:
		allowed = .ClickNormal
	case .Insert:
		allowed = .ClickInsert
	case .Select:
		allowed = .ClickSelect
	}
	if !(allowed in editor.config.options) {
		return
	}
	family := int(editor.config.click_kind)
	choices := make([dynamic]int, 0, len(sfx.samples), context.temp_allocator)
	for sample, index in sfx.samples {
		if sample.family == family {
			append(&choices, index)
		}
	}
	if len(choices) == 0 {
		return
	}

	sample := sfx.samples[choices[rand.int_max(len(choices))]]
	sfx_play(sample.data, editor.config.click_volume, 0.88 + rand.float32() * 0.24)
	if !sfx.logged {
		sfx.logged = true
		log.debugf("first key click from %s", sfx.families[family])
	}
}

sfx_deletion_names :: proc() -> []string {
	return len(sfx.deletion_names) == 0 ? no_family : sfx.deletion_names[:]
}

sfx_delete :: proc(editor: ^Editor) {
	if !sfx.ready || sfx.deleter == nil || len(sfx.deletions) == 0 {
		return
	}
	if !(.DeleteSound in editor.config.options) || editor.config.delete_volume <= 0 {
		return
	}
	sample := sfx.deletions[clamp(int(editor.config.delete_kind), 0, len(sfx.deletions) - 1)]
	sdl.ClearAudioStream(sfx.deleter)
	sdl.SetAudioStreamGain(sfx.deleter, editor.config.delete_volume)
	sdl.PutAudioStreamData(sfx.deleter, raw_data(sample), i32(len(sample)))
}

sfx_play :: proc(data: []u8, volume, ratio: f32) {
	if volume <= 0 {
		return
	}
	stream := sfx.streams[sfx.next]
	sfx.next = (sfx.next + 1) % SFX_STREAMS
	if sdl.GetAudioStreamQueued(stream) > i32(len(data)) {
		sdl.ClearAudioStream(stream)
	}
	sdl.SetAudioStreamFrequencyRatio(stream, ratio)
	sdl.SetAudioStreamGain(stream, volume)
	sdl.PutAudioStreamData(stream, raw_data(data), i32(len(data)))
}

sfx_noise :: proc(editor: ^Editor) {
	wanted := (.BrownNoise in editor.config.options) && editor.config.noise_volume > 0
	if !wanted {
		if sfx.noise != nil {
			sdl.DestroyAudioStream(sfx.noise)
			sfx.noise = nil
			log.debug("brown noise stopped")
		}
		return
	}
	if sfx.noise == nil {
		spec := sdl.AudioSpec{format = .F32, channels = 1, freq = NOISE_RATE}
		sfx.noise = sdl.OpenAudioDeviceStream(sdl.AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, nil, nil)
		if sfx.noise == nil {
			log.errorf("no audio device for the noise: %s", sdl.GetError())
			return
		}
		sdl.ResumeAudioStreamDevice(sfx.noise)
		sfx.brown, sfx.blocked, sfx.previous, sfx.warmth = 0, 0, 0, 0
		log.debug("brown noise started")
	}
	sdl.SetAudioStreamGain(sfx.noise, editor.config.noise_volume)
	cutoff := NOISE_DARKEST * math.pow(NOISE_BRIGHTEST / NOISE_DARKEST, clamp(editor.config.noise_tone, 0, 1))
	tilt := 1 - math.exp(-2 * math.PI * cutoff / NOISE_RATE)
	gain := NOISE_GAIN * math.pow(NOISE_MIDDLE / cutoff, 0.26)
	chunk := make([]f32, NOISE_CHUNK, context.temp_allocator)
	for sdl.GetAudioStreamQueued(sfx.noise) < i32(NOISE_QUEUE * size_of(f32)) {
		for &sample in chunk {
			sfx.brown = (sfx.brown + NOISE_STEP * (rand.float32() * 2 - 1)) / NOISE_LEAK
			value := sfx.brown * gain
			sfx.blocked = NOISE_BLOCK * (sfx.blocked + value - sfx.previous)
			sfx.previous = value
			sfx.warmth += tilt * (sfx.blocked - sfx.warmth)
			sample = clamp(sfx.warmth, -1, 1)
		}
		if !sdl.PutAudioStreamData(sfx.noise, raw_data(chunk), i32(len(chunk) * size_of(f32))) {
			log.debugf("the noise could not be queued: %s", sdl.GetError())
			return
		}
	}
}
