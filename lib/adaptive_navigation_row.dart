import 'dart:math' as math;

import 'package:flutter/material.dart';

class AdaptiveNavigationRow extends StatelessWidget {
  const AdaptiveNavigationRow({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = math.max(constraints.maxWidth, children.length * 48.0);
      final row = SizedBox(
        width: width,
        child: Row(children: children),
      );
      if (width <= constraints.maxWidth) return row;
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: row,
      );
    },
  );
}
