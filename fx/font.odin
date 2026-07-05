package fx

import "core:encoding/json"

Glyph :: struct {
	advance:     f32,
	atlasBounds: MSDF_Bounds,
	planeBounds: MSDF_Bounds,
}

Font :: struct {
	atlas:   Texture,
	metrics: MSDF_Metrics,
	glyphs:  map[rune]Glyph,
}

MSDF_Metrics :: struct {
	emSize:             f32,
	lineHeight:         f32,
	ascender:           f32,
	descender:          f32,
	underlineY:         f32,
	underlineThickness: f32,
}

MSDF_Bounds :: struct {
	left, bottom, right, top: f32,
}

MSDF_Glyph :: struct {
	unicode:     u32,
	advance:     f32,
	planeBounds: MSDF_Bounds,
	atlasBounds: MSDF_Bounds,
}

MSDF_File :: struct {
	metrics: MSDF_Metrics,
	glyphs:  []MSDF_Glyph,
}

load_font :: proc(json_bytes: []u8, img_bytes: []u8) -> (font: Font) {
	msdf_data: MSDF_File
	if err := json.unmarshal(json_bytes, &msdf_data, allocator = context.temp_allocator); err != nil {
		panic("[ERROR] Failed to parse MSDF JSON")
	}

	font.atlas = texture_load(img_bytes, false)
	font.metrics = msdf_data.metrics

	for glyph in msdf_data.glyphs {
		font.glyphs[cast(rune)glyph.unicode] = Glyph {
			advance     = glyph.advance,
			atlasBounds = glyph.atlasBounds,
			planeBounds = glyph.planeBounds,
		}
	}

	return font
}
