# Bundled UI fonts

These font files are shipped with the app so English and Traditional Chinese UI text does not depend on Google Fonts at runtime. Fonts are unchanged upstream binaries, not system-installed fonts.

- Roboto Regular, Medium and Bold: copied from the Flutter SDK material_fonts cache; Apache License 2.0, reproduced in Roboto-LICENSE.txt. Family name Roboto also provides the CanvasKit default locally.
- Noto Sans TC variable (weights 100–900): Google Fonts, SIL Open Font License 1.1, reproduced in NotoSansTC-OFL.txt. Copyright 2014–2021 Adobe; reserved name Source. Full font includes Traditional Chinese, Latin and Cyrillic. No glyph subsetting or binary modification.
- Upstream binary: https://raw.githubusercontent.com/google/fonts/main/ofl/notosanstc/NotoSansTC%5Bwght%5D.ttf
- Upstream license: https://raw.githubusercontent.com/google/fonts/main/ofl/notosanstc/OFL.txt
- Upstream metadata identifies noto-cjk source commit 523d033d6cb47f4a80c58a35753646f5c3608a78.

Both license texts are included in the Flutter asset bundle. These fonts cover the supported English/Traditional Chinese interface; arbitrary user text in other scripts may still require Flutter fallback fonts.
