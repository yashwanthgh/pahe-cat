import 'package:flutter/material.dart';

/// The active colour palette.
///
/// Kept in its own file of plain `const`s so a palette can be swapped without
/// touching any call site, and so all of them stay usable inside `const`
/// widget constructors.
///
/// Palette: White Cat — a white app in warm greys, the colours of cat fur and
/// paw pads. Everything is warm-tinted rather than blue-grey; a neutral grey
/// on white reads clinical, which is the opposite of the intent. Pink survives
/// only as a whisper for the dub badge, at roughly the saturation of a cat's
/// nose.
const kPaletteName = 'White Cat';
const kIsLight = true;

const kRadius = 20.0;
const kFontFamily = 'Quicksand';

const kBg = Color(0xFFFCFBF9); // warm white
const kSurface = Color(0xFFFFFFFF);
const kCard = Color(0xFFF7F5F2);
const kCardHover = Color(0xFFF0EDE8);
const kBorder = Color(0xFFE8E3DC);

const kAccent = Color(0xFF6B615A); // deep warm grey, like dark fur
const kAccentLight = Color(0xFF9A8E85);
const kAccent2 = Color(0xFFE2A0AE); // paw-pad pink, for dub badges
const kAccent2Light = Color(0xFFEFC4CD);
const kInfo = Color(0xFF8FB3A8); // muted sage, for sub badges

const kOnAccent = Color(0xFFFFFFFF);

const kTextPrimary = Color(0xFF3A342F);
const kTextSecondary = Color(0xFF7A716A);
const kTextMuted = Color(0xFFAAA29A);

const kGreen = Color(0xFF7FB88E);
const kAmber = Color(0xFFE0B274);
const kRed = Color(0xFFD98C8C);
const kBlue = Color(0xFF8FA6C4);

const kGradientCardA = Color(0xFFF7F5F2);
const kGradientCardB = Color(0xFFFCFBF9);
