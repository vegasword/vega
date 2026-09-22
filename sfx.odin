package vega

import "core:log"
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
	families: [dynamic]string,
	samples:  [dynamic]Click_Sample,
	streams:  [SFX_STREAMS]^sdl.AudioStream,
	next:     int,
	ready:    bool,
	logged:   bool,
}

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
	stream := sfx.streams[sfx.next]
	sfx.next = (sfx.next + 1) % SFX_STREAMS
	if sdl.GetAudioStreamQueued(stream) > i32(len(sample.data)) {
		sdl.ClearAudioStream(stream)
	}
	sdl.SetAudioStreamFrequencyRatio(stream, 0.88 + rand.float32() * 0.24)
	sdl.SetAudioStreamGain(stream, editor.config.click_volume)
	played := sdl.PutAudioStreamData(stream, raw_data(sample.data), i32(len(sample.data)))
	if !sfx.logged {
		sfx.logged = true
		log.debugf("first key click from %s, queued %v", sfx.families[family], played)
	}
}
