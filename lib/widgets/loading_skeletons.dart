import 'package:flutter/material.dart';

class SkeletonBox extends StatelessWidget {
  final double height;
  final double? width;
  final BorderRadiusGeometry borderRadius;
  final double animationValue;

  const SkeletonBox({
    super.key,
    required this.height,
    this.width,
    required this.animationValue,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
  });

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF2A2F3A)
        : const Color(0xFFE6EAF1);
    final highlight = Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF3A4252)
        : const Color(0xFFF2F4F8);

    return Container(
      height: height,
      width: width,
      decoration: BoxDecoration(
        color: Color.lerp(base, highlight, animationValue),
        borderRadius: borderRadius,
      ),
    );
  }
}

class CardsLoadingSkeleton extends StatefulWidget {
  final int cardCount;

  const CardsLoadingSkeleton({
    super.key,
    this.cardCount = 4,
  });

  @override
  State<CardsLoadingSkeleton> createState() => _CardsLoadingSkeletonState();
}

class _CardsLoadingSkeletonState extends State<CardsLoadingSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            SkeletonBox(
              height: 48,
              animationValue: _controller.value,
              borderRadius: const BorderRadius.all(Radius.circular(10)),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: SkeletonBox(
                    height: 22,
                    animationValue: _controller.value,
                    borderRadius: const BorderRadius.all(Radius.circular(8)),
                  ),
                ),
                const SizedBox(width: 12),
                SkeletonBox(
                  height: 36,
                  width: 110,
                  animationValue: _controller.value,
                  borderRadius: const BorderRadius.all(Radius.circular(10)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            SkeletonBox(
              height: 14,
              width: 140,
              animationValue: _controller.value,
              borderRadius: const BorderRadius.all(Radius.circular(8)),
            ),
            const SizedBox(height: 16),
            ...List.generate(
              widget.cardCount,
              (_) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: SkeletonBox(
                  height: 156,
                  animationValue: _controller.value,
                  borderRadius: const BorderRadius.all(Radius.circular(14)),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class MapLoadingSkeleton extends StatefulWidget {
  const MapLoadingSkeleton({super.key});

  @override
  State<MapLoadingSkeleton> createState() => _MapLoadingSkeletonState();
}

class _MapLoadingSkeletonState extends State<MapLoadingSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            children: [
              Row(
                children: [
                  SkeletonBox(
                    height: 20,
                    width: 120,
                    animationValue: _controller.value,
                    borderRadius: const BorderRadius.all(Radius.circular(8)),
                  ),
                  const Spacer(),
                  SkeletonBox(
                    height: 20,
                    width: 78,
                    animationValue: _controller.value,
                    borderRadius: const BorderRadius.all(Radius.circular(8)),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Expanded(
                child: SkeletonBox(
                  height: double.infinity,
                  animationValue: _controller.value,
                  borderRadius: const BorderRadius.all(Radius.circular(16)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
