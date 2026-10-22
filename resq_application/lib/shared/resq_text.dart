import 'package:flutter/material.dart';

/// The logo's orange, used for the "ResQ" name wherever it appears.
const resqOrange = Color(0xFFFF7A14);

/// [text] with every "ResQ" coloured [resqOrange]; the rest keeps [style].
class ResqText extends StatelessWidget {
  const ResqText(this.text, {super.key, this.style, this.textAlign, this.maxLines, this.overflow});

  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  Widget build(BuildContext context) {
    final parts = text.split('ResQ');
    final spans = <TextSpan>[];
    for (var i = 0; i < parts.length; i++) {
      if (i > 0) spans.add(const TextSpan(text: 'ResQ', style: TextStyle(color: resqOrange)));
      if (parts[i].isNotEmpty) spans.add(TextSpan(text: parts[i]));
    }
    return Text.rich(
      TextSpan(style: style, children: spans),
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: overflow,
    );
  }
}
